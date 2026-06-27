defmodule CodexPooler.Upstreams.Reconciliation.PoolReconciliation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Jobs
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  @active UpstreamIdentity.active_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @health_active PoolUpstreamAssignment.active_health_status()
  @account_quota_key "account"
  @fallback_denied_usage_statuses [401, 403, 429, :auth_rejected]
  @usage_auth_refresh_skew_seconds 5 * 60
  @codex_usage_paths [
    "/api/codex/usage",
    "/backend-api/codex/usage",
    "/wham/usage",
    "/backend-api/wham/usage"
  ]

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type lifecycle_result :: {:ok, map()} | {:error, lifecycle_error()}
  @type usage_fetch_result :: {:ok, term(), String.t(), [map()]} | {:error, term()}
  @type usage_probe_result ::
          {:ok, term(), String.t(), [map()]}
          | :not_found
          | {:continue_error, term()}
          | {:halt_error, term()}

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
        result_identity = step_identity(quota_step, identity)

        if identity_conflict_step?(quota_step) do
          assignment =
            record_identity_conflict!(assignment, quota_step.details["identity_conflict"])

          health_step =
            step_result(:skipped, "health_skipped", "assignment health was not refreshed")

          {:ok,
           %{
             status: :failed,
             assignment: assignment,
             identity: result_identity,
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
             identity: result_identity,
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

      {:persisted_windows, windows} ->
        step_result(:succeeded, "quota_reused_fresh", "fresh quota windows reused", %{
          "window_count" => length(windows)
        })

      {:windows, windows, identity_attrs} ->
        upsert_reconciliation_quota(identity, windows, identity_attrs, nil, nil)

      {:usage, %UpstreamIdentity{} = usage_identity, payload, windows, usage_url} ->
        upsert_reconciliation_quota(
          usage_identity,
          windows,
          identity_attrs_from_codex_usage_payload(payload),
          payload,
          usage_url
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
        identity
        |> codex_usage_quota_windows(assignment, opts)
        |> maybe_reuse_persisted_quota_windows(identity)
    end
  end

  defp upsert_reconciliation_quota(identity, windows, identity_attrs, payload, usage_url)
       when is_list(windows) do
    observed_at = now()

    case persist_reconciliation_quota(
           identity,
           windows,
           identity_attrs,
           payload,
           observed_at,
           usage_url
         ) do
      {:ok, %{windows: refreshed, identity: updated_identity}} ->
        step_result(:succeeded, "quota_refreshed", "quota windows refreshed", %{
          "window_count" => length(refreshed)
        })
        |> Map.put(:identity, updated_identity)

      {:error, {:identity_conflict, :workspace_identity_mismatch, conflict}} ->
        identity_conflict_step(conflict)

      {:error, reason} ->
        step_result(:failed, "quota_refresh_failed", safe_error_message(reason))
    end
  end

  defp upsert_reconciliation_quota(_identity, _windows, _identity_attrs, _payload, _usage_url),
    do: step_result(:failed, "quota_refresh_unavailable", "quota windows were not available")

  @doc false
  @spec refresh_quota_from_usage(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), keyword()) ::
          {:ok, UpstreamIdentity.t()} | {:error, term()}
  def refresh_quota_from_usage(
        %UpstreamIdentity{} = identity,
        %PoolUpstreamAssignment{} = assignment,
        opts \\ []
      ) do
    with {:ok, access_token} <- Secrets.decrypt_active_secret(identity, "access_token"),
         observed_at <- now(),
         {:ok, payload, usage_url, windows} <-
           fetch_codex_usage_payload(identity, assignment, access_token, observed_at, opts),
         {:ok, %{identity: updated_identity}} <-
           persist_reconciliation_quota(
             identity,
             windows,
             identity_attrs_from_codex_usage_payload(payload),
             payload,
             observed_at,
             usage_url
           ) do
      {:ok, updated_identity}
    end
  end

  defp persist_reconciliation_quota(
         identity,
         windows,
         identity_attrs,
         payload,
         observed_at,
         usage_url
       ) do
    case Quota.Windows.upsert_quota_windows(identity, windows,
           delete_missing?: true,
           identity_attrs: identity_attrs
         ) do
      {:ok, refreshed} ->
        if is_map(payload), do: maybe_update_identity_plan(identity, payload)

        {:ok,
         %{
           windows: refreshed,
           identity: maybe_update_saved_reset_snapshot(identity, payload, observed_at, usage_url)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_update_saved_reset_snapshot(identity, payload, observed_at, usage_url)
       when is_map(payload) do
    identity
    |> UpstreamIdentity.changeset(%{
      metadata:
        identity.metadata
        |> Kernel.||(%{})
        |> Map.put("saved_resets", SavedResets.usage_snapshot(payload, observed_at, usage_url)),
      updated_at: observed_at
    })
    |> Repo.update!()
    |> Repo.reload!()
  end

  defp maybe_update_saved_reset_snapshot(identity, _payload, _observed_at, _usage_url),
    do: identity

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
        {:ok, payload, usage_url, windows} ->
          {:usage, identity, payload, windows, usage_url}

        {:error, {:upstream_status, status}} when status in [401, 403] ->
          maybe_retry_codex_usage_after_token_refresh(identity, assignment, observed_at, opts)

        {:error, reason} ->
          {:usage_unavailable, reason}
      end
    else
      _unavailable -> :auth_unavailable
    end
  end

  defp maybe_retry_codex_usage_after_token_refresh(identity, assignment, observed_at, opts) do
    if access_token_refresh_due_after_usage_auth_failure?(identity, observed_at) do
      retry_codex_usage_after_token_refresh(identity, assignment, opts)
    else
      {:usage_unavailable, {:upstream_status, :auth_rejected}}
    end
  end

  defp maybe_reuse_persisted_quota_windows(
         {:usage_unavailable, {:upstream_status, status}},
         _identity
       )
       when status in @fallback_denied_usage_statuses,
       do: :usage_unavailable

  defp maybe_reuse_persisted_quota_windows({:usage_unavailable, _reason}, identity) do
    timestamp = now()

    windows =
      identity
      |> Quota.Windows.list_quota_windows()
      |> Enum.filter(&reusable_persisted_quota_window?(&1, timestamp))

    if windows != [] do
      {:persisted_windows, windows}
    else
      :usage_unavailable
    end
  end

  defp maybe_reuse_persisted_quota_windows(result, _identity), do: result

  defp reusable_persisted_quota_window?(window, timestamp) do
    (WindowClassifier.primary_5h?(window) or WindowClassifier.monthly_primary?(window)) and
      Quota.Windows.usable_window?(window, timestamp)
  end

  defp access_token_refresh_due_after_usage_auth_failure?(
         %UpstreamIdentity{} = identity,
         %DateTime{} = observed_at
       ) do
    case access_token_expires_at(identity.metadata) do
      {:ok, expires_at} ->
        refresh_at = DateTime.add(observed_at, @usage_auth_refresh_skew_seconds, :second)
        DateTime.compare(expires_at, refresh_at) in [:lt, :eq]

      :unknown ->
        true
    end
  end

  defp access_token_expires_at(%{} = metadata) do
    case metadata["access_token_expires_at"] do
      expires_at when is_binary(expires_at) ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, parsed, _offset} -> {:ok, DateTime.truncate(parsed, :microsecond)}
          _invalid -> :unknown
        end

      _value ->
        :unknown
    end
  end

  defp access_token_expires_at(_metadata), do: :unknown

  defp retry_codex_usage_after_token_refresh(identity, assignment, opts) do
    case TokenRefresh.refresh_access_token(identity,
           trigger_kind: "account_reconciliation",
           receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
         ) do
      {:ok, %{status: :active, identity: refreshed_identity}} ->
        fetch_codex_usage_after_successful_token_refresh(refreshed_identity, assignment, opts)

      {:ok, %{status: :refresh_failed, retryable?: true, identity: failed_identity}} ->
        maybe_enqueue_account_reconciliation_token_refresh_recovery(failed_identity)
        :auth_unavailable

      _unavailable ->
        :auth_unavailable
    end
  end

  defp fetch_codex_usage_after_successful_token_refresh(refreshed_identity, assignment, opts) do
    with {:ok, access_token} <- Secrets.decrypt_active_secret(refreshed_identity, "access_token"),
         observed_at <- now(),
         {:ok, payload, usage_url, windows} <-
           fetch_codex_usage_payload(
             refreshed_identity,
             assignment,
             access_token,
             observed_at,
             opts
           ) do
      {:usage, refreshed_identity, payload, windows, usage_url}
    else
      _unavailable -> :auth_unavailable
    end
  end

  defp maybe_enqueue_account_reconciliation_token_refresh_recovery(
         %UpstreamIdentity{} = failed_identity
       ) do
    if account_reconciliation_refresh_failure?(failed_identity) do
      case Jobs.enqueue_token_refresh(failed_identity,
             trigger_kind: "account_reconciliation_recovery"
           ) do
        {:ok, %Oban.Job{}} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  defp account_reconciliation_refresh_failure?(%UpstreamIdentity{} = identity) do
    case identity.metadata["token_refresh"] do
      %{"status" => "failed", "trigger_kind" => "account_reconciliation"} -> true
      _metadata -> false
    end
  end

  defp fetch_codex_usage_payload(identity, assignment, access_token, observed_at, opts) do
    base = upstream_usage_base_url(identity, assignment)
    timeout = Keyword.get(opts, :receive_timeout, 30_000)
    headers = codex_usage_headers(access_token, identity.chatgpt_account_id)

    Enum.reduce_while(@codex_usage_paths, {:error, :not_found}, fn path, last_result ->
      base
      |> codex_usage_url(path)
      |> probe_usage_url(identity, access_token, headers, observed_at, timeout)
      |> reduce_usage_probe_result(last_result)
    end)
  end

  @spec codex_usage_url(String.t(), String.t()) :: String.t()
  defp codex_usage_url(base, path), do: String.trim_trailing(base, "/") <> path

  @spec probe_usage_url(
          String.t(),
          UpstreamIdentity.t(),
          String.t(),
          [{String.t(), String.t()}],
          DateTime.t(),
          timeout()
        ) :: usage_probe_result()
  defp probe_usage_url(url, identity, access_token, headers, observed_at, timeout) do
    case Req.get(url, headers: headers, retry: false, receive_timeout: timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        usage_probe_success(body, identity, access_token, url, observed_at, timeout)

      {:ok, %{status: 404}} ->
        :not_found

      {:ok, %{status: status}} when status in [401, 403, 429] ->
        {:halt_error, {:upstream_status, status}}

      {:ok, %{status: status}} ->
        {:halt_error, {:upstream_status, status}}

      {:error, reason} ->
        {:halt_error, reason}
    end
  end

  @spec usage_probe_success(
          term(),
          UpstreamIdentity.t(),
          String.t(),
          String.t(),
          DateTime.t(),
          timeout()
        ) :: usage_probe_result()
  defp usage_probe_success(body, identity, access_token, url, observed_at, timeout) do
    case Quota.Windows.codex_usage_quota_windows_from_payload(body, observed_at) do
      {:ok, windows} ->
        body =
          maybe_enrich_saved_reset_payload(
            identity,
            access_token,
            body,
            url,
            observed_at,
            timeout
          )

        {:ok, body, url, windows}

      {:error, reason} ->
        {:continue_error, reason}
    end
  end

  @spec reduce_usage_probe_result(usage_probe_result(), usage_fetch_result()) ::
          {:cont, usage_fetch_result()} | {:halt, usage_fetch_result()}
  defp reduce_usage_probe_result(:not_found, last_result), do: {:cont, last_result}

  defp reduce_usage_probe_result({:halt_error, reason}, _last_result),
    do: {:halt, {:error, reason}}

  defp reduce_usage_probe_result({:continue_error, reason}, last_result),
    do: {:cont, accumulate_successful_usage_result(last_result, {:error, reason})}

  defp reduce_usage_probe_result({:ok, _body, _url, windows} = result, last_result) do
    if account_primary_usage_window?(windows) do
      {:halt, prefer_current_usage_result(last_result, result)}
    else
      {:cont, accumulate_successful_usage_result(last_result, result)}
    end
  end

  defp maybe_enrich_saved_reset_payload(
         identity,
         access_token,
         payload,
         usage_url,
         observed_at,
         timeout
       )
       when is_map(payload) do
    case SavedResets.count_from_usage_payload(payload) do
      {:reported, count} when count > 0 ->
        maybe_refresh_reset_credit_expirations(
          identity,
          access_token,
          payload,
          usage_url,
          observed_at,
          timeout,
          count
        )

      _unreported_or_empty ->
        payload
    end
  end

  defp maybe_enrich_saved_reset_payload(
         _identity,
         _access_token,
         payload,
         _usage_url,
         _observed_at,
         _timeout
       ),
       do: payload

  defp maybe_refresh_reset_credit_expirations(
         identity,
         access_token,
         payload,
         usage_url,
         observed_at,
         timeout,
         count
       ) do
    if SavedResets.reset_credit_list_refresh_due?(identity, count, observed_at) do
      refresh_reset_credit_expirations(
        identity,
        access_token,
        payload,
        usage_url,
        observed_at,
        timeout
      )
    else
      SavedResets.reuse_expiration_metadata(payload, identity)
    end
  end

  defp refresh_reset_credit_expirations(
         identity,
         access_token,
         payload,
         usage_url,
         observed_at,
         timeout
       ) do
    case fetch_reset_credits_payload(identity, access_token, usage_url, observed_at, timeout) do
      {:ok, reset_credits} -> merge_reset_credit_snapshot(payload, reset_credits)
      :error -> SavedResets.reuse_expiration_metadata(payload, identity, observed_at)
    end
  end

  defp fetch_reset_credits_payload(identity, access_token, usage_url, observed_at, timeout) do
    usage_url
    |> reset_credits_urls()
    |> Enum.reduce_while(:error, fn url, _last_result ->
      case Req.get(url,
             headers: codex_usage_headers(access_token, identity.chatgpt_account_id),
             retry: false,
             receive_timeout: timeout
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:halt, {:ok, Map.put(body, "expires_observed_at", DateTime.to_iso8601(observed_at))}}

        _unavailable ->
          {:cont, :error}
      end
    end)
  end

  defp reset_credits_urls(usage_url) do
    parsed = URI.parse(usage_url)
    base = %{parsed | query: nil, fragment: nil}

    case parsed.path do
      "/backend-api/wham/usage" ->
        [uri_with_path(base, "/backend-api/wham/rate-limit-reset-credits")]

      "/wham/usage" ->
        [uri_with_path(base, "/wham/rate-limit-reset-credits")]

      path when path in ["/api/codex/usage", "/backend-api/codex/usage"] ->
        [
          uri_with_path(base, "/backend-api/wham/rate-limit-reset-credits"),
          uri_with_path(base, "/wham/rate-limit-reset-credits")
        ]

      _path ->
        []
    end
  end

  defp uri_with_path(%URI{} = uri, path), do: %{uri | path: path} |> URI.to_string()

  defp merge_reset_credit_snapshot(payload, reset_credits) do
    reset_credit_summary = Map.get(payload, "rate_limit_reset_credits") || %{}

    reset_credit_summary =
      reset_credit_summary
      |> put_if_present("available_count", Map.get(reset_credits, "available_count"))
      |> put_if_present("total_earned_count", Map.get(reset_credits, "total_earned_count"))
      |> put_reset_credit_list(reset_credits)

    Map.put(payload, "rate_limit_reset_credits", reset_credit_summary)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_reset_credit_list(map, %{"credits" => credits}) when is_list(credits),
    do: Map.put(map, "credits", credits)

  defp put_reset_credit_list(map, _reset_credits), do: map

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

  defp step_identity(%{identity: %UpstreamIdentity{} = identity}, _fallback), do: identity
  defp step_identity(_step, fallback), do: fallback

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
