defmodule CodexPooler.Alerts.Delivery.PendingRecovery do
  @moduledoc false

  import Ecto.Query
  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, Execution}
  alias CodexPooler.Alerts.Schemas.AlertDeliveryAttempt
  alias CodexPooler.Repo

  @batch_size 100
  @worker "CodexPooler.Jobs.AlertDeliveryWorker"
  @states ~w(available scheduled executing retryable completed cancelled discarded)

  @spec recover(keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def recover(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    candidates = Repo.all(candidates(now, opts))

    summary =
      Enum.reduce(candidates, %{alert_deliveries_recovered: 0, alert_deliveries_unresolved: 0, alert_delivery_recovery_errors: 0}, fn attempt, counts ->
        case recover_one(attempt, now) do
          {:ok, :unchanged} -> counts
          {:ok, %{status: "pending"}} -> Map.update!(counts, :alert_deliveries_unresolved, &(&1 + 1))
          {:ok, _} -> Map.update!(counts, :alert_deliveries_recovered, &(&1 + 1))
          {:error, _} -> Map.update!(counts, :alert_delivery_recovery_errors, &(&1 + 1))
        end
      end)

    if summary.alert_delivery_recovery_errors == 0, do: {:ok, summary}, else: {:error, :alert_delivery_recovery_failed, summary}
  end

  @doc false
  @spec candidates(DateTime.t(), keyword()) :: Ecto.Query.t()
  def candidates(now, opts \\ []) do
    cutoff = DateTime.add(now, -15, :second)
    # JSON values are compared as text, never cast to bigint/timestamp. Exact
    # current executions are excluded before LIMIT. Other rows rotate by a
    # durable checked-at marker, so unresolved/pruned/legacy heads cannot starve
    # receipts whose job later changed state. This bounds results, not DB work.
    current =
      from j in Oban.Job,
        where: fragment("?::text = ? #>> '{delivery_execution,job_id}'", j.id, parent_as(:receipt).response_metadata),
        where: j.worker == ^@worker and j.state == "executing",
        where: fragment("?->>'alert_incident_id' = ?::text AND ?->>'alert_channel_id' = ?::text", j.args, parent_as(:receipt).incident_id, j.args, parent_as(:receipt).channel_id),
        where: fragment(~S|?->'delivery_execution' = jsonb_build_object('version', 1, 'job_id', ?, 'job_attempt', ?, 'job_attempted_at', to_char(?, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))|, parent_as(:receipt).response_metadata, j.id, j.attempt, j.attempted_at),
        select: 1

    query =
      from a in AlertDeliveryAttempt,
        as: :receipt,
        where: a.status == "pending" and not exists(subquery(current)),
        order_by: [asc: fragment("coalesce(? #>> '{delivery_recovery,checked_at}', '')", a.response_metadata), asc: a.created_at, asc: a.id],
        limit: ^@batch_size

    case Keyword.get(opts, :job_id) do
      id when is_integer(id) and id > 0 -> from a in query, where: fragment("? #>> '{delivery_execution,job_id}' = ?", a.response_metadata, ^Integer.to_string(id))
      _ -> from a in query, where: a.created_at <= ^cutoff
    end
  end

  @spec recover_one(AlertDeliveryAttempt.t(), DateTime.t()) :: AttemptLifecycle.lifecycle_result() | {:ok, :unchanged}
  def recover_one(attempt, now) do
    AttemptLifecycle.transition_pending(
      attempt,
      fn job, current ->
        case disposition(job, current) do
          :current ->
            :unchanged

          {:unresolved, reason} ->
            %{response_metadata: Map.put(current.response_metadata, "delivery_recovery", %{"state" => "unresolved", "reason" => reason, "checked_at" => DateTime.to_iso8601(now)}), updated_at: now}

          {:revoked, retryable, reason} ->
            {adapter, code, message} = interruption(current.response_metadata, reason)
            metadata = current.response_metadata |> Map.put("delivery_outcome", "unknown") |> Map.put("delivery_recovery", %{"state" => "recovered", "reason" => reason, "checked_at" => DateTime.to_iso8601(now)})
            %{status: if(retryable, do: "retryable", else: "failed"), completed_at: now, retryable: retryable, next_retry_at: if(retryable and job.state in ~w(available scheduled retryable), do: job.scheduled_at), failure_code: code, failure_message: message, response_metadata: metadata, failure_metadata: %{"delivery_adapter" => adapter, "failure_code" => code, "retryable" => retryable}, updated_at: now}
        end
      end,
      on_terminal: :unchanged,
      report_unchanged: true
    )
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :storage_unavailable}
  end

  defp interruption(%{"delivery_adapter" => "email"}, "channel_deleted"),
    do: {"email", "alert_delivery_channel_deleted", "alert channel was deleted before delivery completed"}

  defp interruption(_metadata, "channel_deleted"),
    do: {"webhook", "alert_delivery_channel_deleted", "alert channel was deleted before delivery completed"}

  defp interruption(%{"delivery_adapter" => "email"}, _reason),
    do: {"email", "alert_email_execution_interrupted", "email execution ended; delivery outcome unknown"}

  # Existing pending receipts without adapter metadata came from webhook delivery.
  defp interruption(_metadata, _reason),
    do: {"webhook", "alert_webhook_execution_interrupted", "webhook execution ended; delivery outcome unknown"}

  defp disposition(job, attempt) do
    if is_nil(attempt.channel_id) do
      {:revoked, false, "channel_deleted"}
    else
      case Execution.decode(attempt.response_metadata) do
        :unlinked -> {:unresolved, "legacy_unlinked"}
        :invalid -> {:unresolved, "invalid_execution"}
        {:ok, binding} -> linked_disposition(job, binding, attempt)
      end
    end
  end

  defp linked_disposition(nil, _binding, _attempt), do: {:unresolved, "job_unavailable"}

  defp linked_disposition(job, binding, attempt) do
    cond do
      not Execution.related?(job, attempt.incident_id, attempt.channel_id) -> {:unresolved, "job_mismatch"}
      Execution.matches?(job, binding, attempt.incident_id, attempt.channel_id) -> :current
      revoked?(job, binding) -> {:revoked, binding["job_attempt"] < job.max_attempts and job.state not in ~w(completed cancelled discarded), "execution_revoked"}
      true -> {:unresolved, "execution_unknown"}
    end
  end

  defp revoked?(%{attempted_at: %DateTime{} = at, attempt: attempt, state: state}, binding) when state in @states do
    {:ok, old_at, 0} = DateTime.from_iso8601(binding["job_attempted_at"])
    comparison = DateTime.compare(at, old_at)

    (attempt > binding["job_attempt"] and comparison in [:eq, :gt]) or
      (attempt == binding["job_attempt"] and comparison == :eq and state != "executing")
  end

  defp revoked?(_job, _binding), do: false

  @spec unresolved?(map()) :: boolean()
  def unresolved?(%{status: "pending", response_metadata: %{"delivery_recovery" => %{"state" => "unresolved"}}}), do: true
  def unresolved?(_), do: false
end
