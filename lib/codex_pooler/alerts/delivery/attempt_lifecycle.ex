defmodule CodexPooler.Alerts.Delivery.AttemptLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Alerts.Delivery.Execution

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Alerts.StatusVocabulary.Rule, as: RuleStatus
  alias CodexPooler.Repo

  @default_cooldown_minutes RuleStatus.default_cooldown_minutes()

  @type delivery_adapter :: String.t()
  @type failure_code :: String.t()
  @type failure_message :: String.t()
  @type lifecycle_result ::
          {:ok, AlertDeliveryAttempt.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, %{required(:code) => String.t(), optional(:retryable) => boolean()}}

  @spec ensure_not_suppressed(
          AlertIncident.t(),
          AlertChannel.t(),
          DateTime.t(),
          delivery_adapter()
        ) ::
          :ok | {:discard, failure_code(), failure_message()}
  def ensure_not_suppressed(
        %AlertIncident{} = incident,
        %AlertChannel{} = channel,
        %DateTime{} = timestamp,
        delivery_adapter
      )
      when is_binary(delivery_adapter) do
    cooldown_minutes = cooldown_minutes(incident, channel)

    if sent_attempt_within_cooldown?(incident.id, channel.id, cooldown_minutes, timestamp) do
      {:discard, "alert_delivery_cooldown_suppressed", "alert #{delivery_adapter} delivery is inside the cooldown window"}
    else
      :ok
    end
  end

  @spec sent_attempt_within_cooldown?(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer() | nil,
          DateTime.t()
        ) :: boolean()
  def sent_attempt_within_cooldown?(
        incident_id,
        channel_id,
        cooldown_minutes,
        %DateTime{} = timestamp
      )
      when is_binary(incident_id) and is_binary(channel_id) do
    minutes =
      case cooldown_minutes do
        value when is_integer(value) and value > 0 -> value
        _value -> @default_cooldown_minutes
      end

    since = DateTime.add(timestamp, -minutes * 60, :second)
    recent_sent_attempt?(incident_id, channel_id, since)
  end

  @spec insert_pending_attempt(
          AlertIncident.t(),
          AlertChannel.t(),
          pos_integer(),
          DateTime.t(),
          map(),
          Execution.t() | nil
        ) :: lifecycle_result()
  def insert_pending_attempt(incident, channel, attempt_number, timestamp, response_metadata, execution \\ nil)

  def insert_pending_attempt(
        %AlertIncident{} = incident,
        %AlertChannel{} = channel,
        attempt_number,
        %DateTime{} = timestamp,
        response_metadata,
        execution
      )
      when is_integer(attempt_number) and is_map(response_metadata) do
    metadata = Map.delete(response_metadata, "delivery_execution")
    metadata = if execution, do: Execution.metadata(execution, metadata), else: metadata

    attrs = %{incident_id: incident.id, channel_id: channel.id, attempt_number: attempt_number, status: "pending", scheduled_at: timestamp, attempted_at: timestamp, retryable: false, response_metadata: metadata, failure_metadata: %{}, created_at: timestamp, updated_at: timestamp}

    Execution.storage(execution, fn -> insert_attempt(attrs) end)
  end

  defp authorize_insert(%{status: "pending", incident_id: incident_id, channel_id: channel_id, response_metadata: metadata}) do
    case Execution.decode(metadata) do
      :unlinked -> :ok
      {:ok, binding} -> authorize_current!(Execution.lock_job(binding), binding, incident_id, channel_id)
      :invalid -> Repo.rollback(execution_error())
    end
  end

  defp authorize_insert(_attrs), do: :ok

  defp authorize_current!(job, binding, incident_id, channel_id) do
    unless Execution.matches?(job, binding, incident_id, channel_id), do: Repo.rollback(execution_error())
    :ok
  end

  @spec insert_sent_attempt(
          AlertIncident.t(),
          AlertChannel.t(),
          pos_integer(),
          DateTime.t(),
          map()
        ) :: lifecycle_result()
  def insert_sent_attempt(
        %AlertIncident{} = incident,
        %AlertChannel{} = channel,
        attempt_number,
        %DateTime{} = timestamp,
        response_metadata
      )
      when is_integer(attempt_number) and is_map(response_metadata) do
    insert_attempt(%{
      incident_id: incident.id,
      channel_id: channel.id,
      attempt_number: attempt_number,
      status: AlertDeliveryAttempt.sent_status(),
      scheduled_at: timestamp,
      attempted_at: timestamp,
      completed_at: timestamp,
      retryable: false,
      response_metadata: response_metadata,
      failure_metadata: %{},
      created_at: timestamp,
      updated_at: timestamp
    })
  end

  @spec record_discarded_attempt(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer(),
          DateTime.t(),
          delivery_adapter(),
          failure_code(),
          failure_message()
        ) :: lifecycle_result()
  def record_discarded_attempt(
        incident_id,
        channel_id,
        attempt_number,
        %DateTime{} = timestamp,
        delivery_adapter,
        code,
        message
      )
      when is_binary(incident_id) and is_binary(channel_id) and is_integer(attempt_number) and
             is_binary(delivery_adapter) and is_binary(code) and is_binary(message) do
    insert_attempt(%{
      incident_id: incident_id,
      channel_id: channel_id,
      attempt_number: attempt_number,
      status: AlertDeliveryAttempt.discarded_status(),
      scheduled_at: timestamp,
      attempted_at: timestamp,
      completed_at: timestamp,
      retryable: false,
      failure_code: code,
      failure_message: message,
      response_metadata: %{"delivery_adapter" => delivery_adapter},
      failure_metadata: failure_metadata(delivery_adapter, code, message, false),
      created_at: timestamp,
      updated_at: timestamp
    })
  end

  @spec record_failed_attempt(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer(),
          DateTime.t(),
          delivery_adapter(),
          failure_code(),
          failure_message(),
          keyword()
        ) :: lifecycle_result()
  def record_failed_attempt(
        incident_id,
        channel_id,
        attempt_number,
        %DateTime{} = timestamp,
        delivery_adapter,
        code,
        message,
        opts \\ []
      )
      when is_binary(incident_id) and is_binary(channel_id) and is_integer(attempt_number) and
             is_binary(delivery_adapter) and is_binary(code) and is_binary(message) and
             is_list(opts) do
    retryable = Keyword.get(opts, :retryable, false)

    attrs = %{
      incident_id: incident_id,
      channel_id: channel_id,
      attempt_number: attempt_number,
      status: failed_status(retryable),
      scheduled_at: timestamp,
      attempted_at: timestamp,
      completed_at: timestamp,
      next_retry_at: Keyword.get(opts, :next_retry_at),
      response_status_code: Keyword.get(opts, :response_status_code),
      retryable: retryable,
      failure_code: code,
      failure_message: message,
      response_metadata: Keyword.get(opts, :response_metadata, %{"delivery_adapter" => delivery_adapter}),
      failure_metadata: failure_metadata(delivery_adapter, code, message, retryable),
      created_at: timestamp,
      updated_at: timestamp
    }

    insert_attempt(attrs)
    |> retryable_result(code, retryable)
  end

  @spec mark_sent_attempt(AlertDeliveryAttempt.t(), DateTime.t(), map(), integer() | nil) ::
          lifecycle_result()
  def mark_sent_attempt(
        %AlertDeliveryAttempt{} = attempt,
        %DateTime{} = timestamp,
        response_metadata,
        response_status_code \\ nil
      )
      when is_map(response_metadata) do
    update_attempt(attempt, %{
      status: AlertDeliveryAttempt.sent_status(),
      completed_at: timestamp,
      response_status_code: response_status_code,
      retryable: false,
      response_metadata: response_metadata,
      failure_metadata: %{},
      updated_at: timestamp
    })
  end

  @spec finalize_failed_attempt(
          AlertDeliveryAttempt.t(),
          DateTime.t(),
          delivery_adapter(),
          failure_code(),
          failure_message(),
          keyword()
        ) :: lifecycle_result()
  def finalize_failed_attempt(
        %AlertDeliveryAttempt{} = attempt,
        %DateTime{} = timestamp,
        delivery_adapter,
        code,
        message,
        opts \\ []
      )
      when is_binary(delivery_adapter) and is_binary(code) and is_binary(message) and
             is_list(opts) do
    retryable = Keyword.get(opts, :retryable, false)

    attrs = %{
      status: failed_status(retryable),
      completed_at: timestamp,
      next_retry_at: Keyword.get(opts, :next_retry_at),
      response_status_code: Keyword.get(opts, :response_status_code),
      retryable: retryable,
      failure_code: code,
      failure_message: message,
      response_metadata: Keyword.get(opts, :response_metadata, attempt.response_metadata),
      failure_metadata: failure_metadata(delivery_adapter, code, message, retryable),
      updated_at: timestamp
    }

    update_attempt(attempt, attrs)
    |> retryable_result(code, retryable)
  end

  @doc false
  @spec channel_deleted_error() :: %{code: String.t(), retryable: false}
  def channel_deleted_error, do: %{code: "alert_delivery_channel_deleted", retryable: false}

  @doc false
  @spec channel_deleted_attributes(delivery_adapter(), DateTime.t()) :: map()
  def channel_deleted_attributes(adapter, timestamp) do
    code = "alert_delivery_channel_deleted"
    message = "alert channel was deleted before delivery completed"

    %{status: "failed", completed_at: timestamp, retryable: false, next_retry_at: nil, failure_code: code, failure_message: message, failure_metadata: failure_metadata(adapter, code, message, false), updated_at: timestamp}
  end

  @doc false
  @spec terminalize_channel_attempts(AlertChannel.t(), DateTime.t()) :: :ok
  def terminalize_channel_attempts(%AlertChannel{} = channel, timestamp) do
    from(attempt in AlertDeliveryAttempt, where: attempt.channel_id == ^channel.id and attempt.status in ~w(pending retryable))
    |> Repo.update_all(set: Map.to_list(channel_deleted_attributes(channel.channel_type, timestamp)))

    :ok
  end

  defp recent_sent_attempt?(incident_id, channel_id, since) do
    Repo.exists?(
      from attempt in AlertDeliveryAttempt,
        where:
          attempt.incident_id == ^incident_id and attempt.channel_id == ^channel_id and
            attempt.status == "sent" and
            ((not is_nil(attempt.completed_at) and attempt.completed_at >= ^since) or
               (is_nil(attempt.completed_at) and not is_nil(attempt.attempted_at) and
                  attempt.attempted_at >= ^since))
    )
  end

  defp cooldown_minutes(%AlertIncident{id: incident_id}, %AlertChannel{id: channel_id}) do
    value =
      Repo.one(
        from target in AlertIncidentTarget,
          join: rule in AlertRule,
          on: rule.id == target.rule_id,
          join: link in AlertRuleChannel,
          on: link.alert_rule_id == rule.id and link.alert_channel_id == ^channel_id,
          where: target.incident_id == ^incident_id and rule.state == "active",
          select: max(rule.cooldown_minutes)
      )

    case value do
      minutes when is_integer(minutes) and minutes > 0 -> minutes
      _value -> @default_cooldown_minutes
    end
  end

  defp insert_attempt(attrs) do
    Repo.transact(fn ->
      # Deletion locks channel -> queued jobs -> receipts. Take the channel
      # before the execution job so registration cannot deadlock with deletion.
      case Repo.one(from channel in AlertChannel, where: channel.id == ^attrs.channel_id, lock: "FOR KEY SHARE") do
        %AlertChannel{} = channel ->
          :ok = authorize_insert(attrs)

          attrs = Map.merge(attrs, %{channel_created_by_user_id: channel.created_by_user_id, channel_display_name: channel.display_name, channel_type: channel.channel_type})

          %AlertDeliveryAttempt{}
          |> AlertDeliveryAttempt.changeset(sanitize_attempt_attrs(attrs))
          |> Repo.insert()

        nil ->
          {:error, channel_deleted_error()}
      end
    end)
  end

  defp update_attempt(%AlertDeliveryAttempt{} = attempt, attrs) do
    transition_attempt(attempt, fn job, current -> authorized_attributes(job, current, attrs) end, on_terminal: :error)
  end

  defp authorized_attributes(job, current, attrs) do
    case Execution.decode(current.response_metadata) do
      :unlinked ->
        attrs

      {:ok, binding} ->
        authorize_current!(job, binding, current.incident_id, current.channel_id)
        attrs

      :invalid ->
        Repo.rollback(execution_error())
    end
  end

  @doc false
  @spec transition_attempt(AlertDeliveryAttempt.t(), (Oban.Job.t() | nil, AlertDeliveryAttempt.t() -> map() | :unchanged), keyword()) :: lifecycle_result() | {:ok, :unchanged}
  def transition_attempt(%AlertDeliveryAttempt{} = expected, transition, opts \\ []) do
    Repo.transaction(fn -> transition_locked(expected, transition, opts) end)
  end

  defp transition_locked(expected, transition, opts) do
    job =
      case Execution.decode(expected.response_metadata) do
        {:ok, binding} -> Execution.lock_job(binding)
        _ -> nil
      end

    current = Repo.one(from a in AlertDeliveryAttempt, where: a.id == ^expected.id, lock: "FOR UPDATE")

    cond do
      is_nil(current) -> terminal_result(:unchanged, opts)
      current.status not in Keyword.get(opts, :statuses, ["pending"]) -> terminal_result(current, opts)
      Map.get(current.response_metadata, "delivery_execution") != Map.get(expected.response_metadata, "delivery_execution") -> Repo.rollback(execution_error())
      true -> apply_transition(current, transition.(job, current), opts)
    end
  end

  defp apply_transition(current, :unchanged, opts), do: if(Keyword.get(opts, :report_unchanged), do: :unchanged, else: current)
  defp apply_transition(current, attrs, _opts), do: update_attempt_locked(current, attrs)

  defp terminal_result(current, opts) do
    case Keyword.get(opts, :on_terminal) do
      :error -> Repo.rollback(execution_error())
      :unchanged -> :unchanged
      _ -> current
    end
  end

  defp update_attempt_locked(current, attrs) do
    metadata = Map.get(attrs, :response_metadata, current.response_metadata)

    metadata =
      case Map.fetch(current.response_metadata, "delivery_execution") do
        {:ok, binding} -> Map.put(metadata, "delivery_execution", binding)
        :error -> metadata
      end

    attrs = sanitize_attempt_attrs(Map.put(attrs, :response_metadata, metadata))
    changeset = AlertDeliveryAttempt.changeset(current, attrs)
    unless changeset.valid?, do: Repo.rollback(changeset)
    query = from a in AlertDeliveryAttempt, where: a.id == ^current.id and a.status == ^current.status and a.response_metadata == ^current.response_metadata, select: a

    case Repo.update_all(query, set: Map.to_list(changeset.changes)) do
      {1, [updated]} -> updated
      _ -> Repo.rollback(execution_error())
    end
  end

  defp execution_error, do: %{code: "alert_delivery_execution_superseded", retryable: false}

  defp sanitize_attempt_attrs(attrs) do
    attrs
    |> Map.update(:response_metadata, %{}, &safe_metadata/1)
    |> Map.update(:failure_metadata, %{}, &safe_metadata/1)
  end

  defp failure_metadata(delivery_adapter, code, message, retryable) do
    %{
      "delivery_adapter" => delivery_adapter,
      "failure_code" => code,
      "failure_message" => message,
      "retryable" => retryable
    }
    |> safe_metadata()
  end

  defp retryable_result({:ok, %{retryable: true} = attempt}, code, true) do
    {:error, %{code: code, retryable: true, attempt_id: attempt.id}}
  end

  defp retryable_result(result, _code, _retryable), do: result

  defp failed_status(true), do: AlertDeliveryAttempt.retryable_status()
  defp failed_status(false), do: AlertDeliveryAttempt.failed_status()

  defp safe_metadata(metadata), do: Accounting.sanitize_metadata(metadata || %{})
end
