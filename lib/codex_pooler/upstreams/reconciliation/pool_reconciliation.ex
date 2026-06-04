defmodule CodexPooler.Upstreams.Reconciliation.PoolReconciliation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  @active UpstreamIdentity.active_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @health_active PoolUpstreamAssignment.active_health_status()
  @account_quota_key "account"
  @codex_usage_paths [
    "/api/codex/usage",
    "/backend-api/codex/usage",
    "/wham/usage",
    "/backend-api/wham/usage"
  ]

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type lifecycle_result :: {:ok, map()} | {:error, lifecycle_error()}

  @spec reconcile_pool_account(
          Pool.t() | Ecto.UUID.t() | term(),
          PoolUpstreamAssignment.t() | Ecto.UUID.t() | term(),
          keyword()
        ) ::
          lifecycle_result()
  def reconcile_pool_account(pool_or_id, assignment_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    assignment_id = assignment_id(assignment_or_id)

    case load_active_assignment_with_identity(pool_id, assignment_id) do
      {%PoolUpstreamAssignment{} = assignment, %UpstreamIdentity{} = identity} ->
        quota_step = refresh_reconciliation_quota(identity, assignment, opts)

        if identity_conflict_step?(quota_step) do
          assignment =
            record_identity_conflict!(assignment, quota_step.details["identity_conflict"])

          health_step =
            step_result(:skipped, "health_skipped", "assignment health was not refreshed")

          {:ok,
           %{
             status: :failed,
             assignment: assignment,
             identity: identity,
             health: health_step,
             quota: quota_step
           }}
        else
          health_step = record_reconciliation_health!(assignment)
          status = summarize_reconciliation_status([health_step, quota_step])

          assignment =
            assignment
            |> Repo.reload!()
            |> record_reconciliation_summary!(status, [health_step, quota_step])

          {:ok,
           %{
             status: status,
             assignment: assignment,
             identity: identity,
             health: health_step,
             quota: quota_step
           }}
        end

      nil ->
        {:error,
         lifecycle_error(
           :pool_account_not_reconcilable,
           "active pool assignment was not found for reconciliation"
         )}
    end
  end

  defp load_active_assignment_with_identity(pool_id, assignment_id)
       when is_binary(pool_id) and is_binary(assignment_id) do
    Repo.one(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where:
          assignment.id == ^assignment_id and assignment.pool_id == ^pool_id and
            assignment.status == ^@assignment_active and identity.status == ^@active,
        limit: 1,
        select: {assignment, identity}
    )
  end

  defp load_active_assignment_with_identity(_pool_id, _assignment_id), do: nil

  defp record_reconciliation_health!(%PoolUpstreamAssignment{} = assignment) do
    timestamp = now()

    assignment
    |> PoolUpstreamAssignment.changeset(%{
      health_status: @health_active,
      eligibility_status: @eligible,
      last_healthcheck_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.update!()

    step_result(:succeeded, "health_refreshed", "assignment health refreshed")
  end

  defp refresh_reconciliation_quota(identity, assignment, opts) do
    source = reconciliation_quota_source(identity, assignment, opts)

    case source do
      :auth_unavailable ->
        step_result(
          :failed,
          "quota_refresh_auth_unavailable",
          "quota refresh requires account reauthentication"
        )

      :usage_unavailable ->
        step_result(:failed, "quota_refresh_unavailable", "quota windows were not available")

      {:windows, windows, identity_attrs} ->
        upsert_reconciliation_quota(identity, windows, identity_attrs, nil)

      {:usage, %UpstreamIdentity{} = usage_identity, payload, windows} ->
        upsert_reconciliation_quota(
          usage_identity,
          windows,
          identity_attrs_from_codex_usage_payload(payload),
          payload
        )
    end
  end

  defp reconciliation_quota_source(identity, assignment, opts) do
    cond do
      Keyword.has_key?(opts, :quota_windows) ->
        {:windows, Keyword.get(opts, :quota_windows), Keyword.get(opts, :identity_attrs, %{})}

      windows = metadata_quota_windows(identity, assignment) ->
        {:windows, windows, %{}}

      true ->
        codex_usage_quota_windows(identity, assignment, opts)
    end
  end

  defp upsert_reconciliation_quota(identity, windows, identity_attrs, payload)
       when is_list(windows) do
    case Quota.Windows.upsert_quota_windows(identity, windows,
           delete_missing?: true,
           identity_attrs: identity_attrs
         ) do
      {:ok, refreshed} ->
        if is_map(payload), do: maybe_update_identity_plan(identity, payload)

        step_result(:succeeded, "quota_refreshed", "quota windows refreshed", %{
          "window_count" => length(refreshed)
        })

      {:error, {:identity_conflict, :workspace_identity_mismatch, conflict}} ->
        identity_conflict_step(conflict)

      {:error, reason} ->
        step_result(:failed, "quota_refresh_failed", safe_error_message(reason))
    end
  end

  defp upsert_reconciliation_quota(_identity, _windows, _identity_attrs, _payload),
    do: step_result(:failed, "quota_refresh_unavailable", "quota windows were not available")

  defp metadata_quota_windows(identity, assignment) do
    identity_windows = Quota.Windows.quota_windows_from_metadata(identity.metadata)
    assignment_windows = Quota.Windows.quota_windows_from_metadata(assignment.metadata)

    cond do
      assignment_windows != [] -> assignment_windows
      identity_windows != [] -> identity_windows
      true -> nil
    end
  end

  defp codex_usage_quota_windows(
         %UpstreamIdentity{} = identity,
         assignment,
         opts
       ) do
    with chatgpt_account_id when is_binary(chatgpt_account_id) and chatgpt_account_id != "" <-
           identity.chatgpt_account_id,
         {:ok, access_token} <- Secrets.decrypt_active_secret(identity, "access_token"),
         observed_at <- now() do
      case fetch_codex_usage_payload(identity, assignment, access_token, observed_at, opts) do
        {:ok, payload, _url, windows} ->
          {:usage, identity, payload, windows}

        {:error, {:upstream_status, status}} when status in [401, 403] ->
          retry_codex_usage_after_token_refresh(identity, assignment, opts)

        _error ->
          :usage_unavailable
      end
    else
      _unavailable -> :auth_unavailable
    end
  end

  defp retry_codex_usage_after_token_refresh(identity, assignment, opts) do
    with {:ok, %{status: :active, identity: refreshed_identity}} <-
           TokenRefresh.refresh_access_token(identity,
             trigger_kind: "account_reconciliation",
             receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
           ),
         {:ok, access_token} <- Secrets.decrypt_active_secret(refreshed_identity, "access_token"),
         observed_at <- now(),
         {:ok, payload, _url, windows} <-
           fetch_codex_usage_payload(
             refreshed_identity,
             assignment,
             access_token,
             observed_at,
             opts
           ) do
      {:usage, refreshed_identity, payload, windows}
    else
      _unavailable -> :auth_unavailable
    end
  end

  defp fetch_codex_usage_payload(identity, assignment, access_token, observed_at, opts) do
    base = upstream_usage_base_url(identity, assignment)
    timeout = Keyword.get(opts, :receive_timeout, 30_000)

    Enum.reduce_while(@codex_usage_paths, {:error, :not_found}, fn path, last_result ->
      url = String.trim_trailing(base, "/") <> path

      case Req.get(url,
             headers: codex_usage_headers(access_token, identity.chatgpt_account_id),
             retry: false,
             receive_timeout: timeout
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          case Quota.Windows.codex_usage_quota_windows_from_payload(body, observed_at) do
            {:ok, windows} ->
              result = {:ok, body, url, windows}

              # Reason: successful usage probes prefer account-primary quota evidence immediately.
              # credo:disable-for-next-line Credo.Check.Refactor.Nesting
              if account_primary_usage_window?(windows) do
                {:halt, prefer_current_usage_result(last_result, result)}
              else
                {:cont, accumulate_successful_usage_result(last_result, result)}
              end

            {:error, reason} ->
              {:cont, accumulate_successful_usage_result(last_result, {:error, reason})}
          end

        {:ok, %{status: 404}} ->
          {:cont, last_result}

        {:ok, %{status: status}} when status in [401, 403, 429] ->
          {:halt, {:error, {:upstream_status, status}}}

        {:ok, %{status: status}} ->
          {:halt, {:error, {:upstream_status, status}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp prefer_current_usage_result(
         {:ok, _body, _url, previous_windows},
         {:ok, body, url, windows}
       ) do
    {:ok, body, url, merge_usage_windows(previous_windows, windows)}
  end

  defp prefer_current_usage_result(_last_result, result), do: result

  defp accumulate_successful_usage_result(
         {:ok, body, url, previous_windows},
         {:ok, _new_body, _new_url, windows}
       ) do
    {:ok, body, url, merge_usage_windows(previous_windows, windows)}
  end

  defp accumulate_successful_usage_result({:ok, _body, _url, _windows} = result, _new_result),
    do: result

  defp accumulate_successful_usage_result(_last_result, new_result), do: new_result

  defp merge_usage_windows(previous_windows, current_windows) do
    previous_windows
    |> Enum.concat(current_windows)
    |> Enum.reduce(%{}, fn window, acc ->
      Map.put(acc, usage_window_identity(window), window)
    end)
    |> Map.values()
    |> Enum.sort_by(&usage_window_identity/1)
  end

  defp usage_window_identity(window) do
    {Map.get(window, :quota_key), Map.get(window, :window_kind)}
  end

  defp account_primary_usage_window?(windows) when is_list(windows) do
    Enum.any?(windows, fn window ->
      Map.get(window, :quota_key) == @account_quota_key and
        Map.get(window, :window_kind) == "primary" and Map.get(window, :window_minutes) == 300 and
        match?(%DateTime{}, Map.get(window, :reset_at))
    end)
  end

  defp codex_usage_headers(access_token, chatgpt_account_id) do
    headers = [
      {"authorization", "Bearer " <> String.trim(access_token)},
      {"accept", "application/json"}
    ]

    if send_chatgpt_account_header?(chatgpt_account_id) do
      headers ++
        [
          {"chatgpt-account-id", chatgpt_account_id}
        ]
    else
      headers
    end
  end

  defp send_chatgpt_account_header?(chatgpt_account_id) when is_binary(chatgpt_account_id) do
    chatgpt_account_id = String.trim(chatgpt_account_id)

    chatgpt_account_id != "" and not String.starts_with?(chatgpt_account_id, "email_") and
      not String.starts_with?(chatgpt_account_id, "local_")
  end

  defp send_chatgpt_account_header?(_chatgpt_account_id), do: false

  defp upstream_usage_base_url(identity, assignment) do
    EndpointMetadata.usage_base_url(identity, assignment)
  end

  defp identity_attrs_from_codex_usage_payload(%{"plan_type" => plan_type})
       when is_binary(plan_type) do
    %{plan_family: normalize_plan(plan_type), plan_label: plan_type}
  end

  defp identity_attrs_from_codex_usage_payload(_payload), do: %{}

  defp identity_conflict_step(conflict) do
    step_result(:failed, "workspace_identity_mismatch", "workspace identity mismatch", %{
      "identity_conflict" => conflict_metadata(conflict)
    })
  end

  defp identity_conflict_step?(%{code: "workspace_identity_mismatch"}), do: true
  defp identity_conflict_step?(_step), do: false

  defp record_identity_conflict!(%PoolUpstreamAssignment{} = assignment, conflict)
       when is_map(conflict) do
    timestamp = now()

    assignment
    |> PoolUpstreamAssignment.changeset(%{
      metadata: Map.put(assignment.metadata || %{}, "identity_conflict", conflict),
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp conflict_metadata(conflict) when is_map(conflict) do
    conflict
    |> Map.take([
      :path,
      :stored_workspace_ref,
      :incoming_workspace_ref,
      :stored_plan_family,
      :incoming_plan_family,
      :stored_seat_type,
      :incoming_seat_type
    ])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp maybe_update_identity_plan(identity, %{"plan_type" => plan_type})
       when is_binary(plan_type) do
    plan_type = String.trim(plan_type)

    if plan_type != "" and plan_type != identity.plan_label do
      update_identity_plan(identity, %{
        plan_family: normalize_plan(plan_type),
        plan_label: plan_type
      })
    end
  end

  defp maybe_update_identity_plan(_identity, _payload), do: :ok

  defp normalize_plan(plan) do
    plan
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp record_reconciliation_summary!(assignment, status, steps) do
    timestamp = now()
    metadata = assignment.metadata || %{}

    summary = %{
      "status" => Atom.to_string(status),
      "finished_at" => DateTime.to_iso8601(timestamp),
      "steps" => Enum.map(steps, &step_to_metadata/1)
    }

    assignment
    |> PoolUpstreamAssignment.changeset(%{
      metadata: Map.put(metadata, "last_reconciliation", summary),
      last_successful_refresh_at:
        if(status == :succeeded, do: timestamp, else: assignment.last_successful_refresh_at),
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp summarize_reconciliation_status(steps) do
    succeeded = Enum.count(steps, &(&1.status == :succeeded))
    failed = Enum.count(steps, &(&1.status == :failed))

    cond do
      failed == 0 -> :succeeded
      succeeded > 0 -> :partial
      true -> :failed
    end
  end

  defp step_result(status, code, message, details \\ %{}) do
    %{status: status, code: code, message: message, details: details}
  end

  defp step_to_metadata(step) do
    %{
      "status" => Atom.to_string(step.status),
      "code" => step.code,
      "message" => step.message,
      "details" => step.details
    }
  end

  defp safe_error_message(%{message: message}) when is_binary(message), do: message
  defp safe_error_message(%Ecto.Changeset{}), do: "quota window validation failed"
  defp safe_error_message(reason), do: reason |> inspect() |> String.slice(0, 200)

  defp pool_id(%{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp pool_id(_id), do: nil

  defp assignment_id(%PoolUpstreamAssignment{id: id}), do: id
  defp assignment_id(id) when is_binary(id), do: id
  defp assignment_id(_id), do: nil

  defp lifecycle_error(code, message), do: %{code: code, message: message}

  defp update_identity_plan(%UpstreamIdentity{} = identity, attrs) do
    attrs = Map.put(attrs, :updated_at, now())

    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
