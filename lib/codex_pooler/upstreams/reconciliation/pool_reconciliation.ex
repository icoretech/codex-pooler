defmodule CodexPooler.Upstreams.Reconciliation.PoolReconciliation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.Convergence
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @active UpstreamIdentity.active_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @assignment_ineligible PoolUpstreamAssignment.ineligible_status()
  @health_active PoolUpstreamAssignment.active_health_status()
  @fallback_denied_usage_statuses [401, 403, 429, :auth_rejected]

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
          health_step = record_reconciliation_health!(assignment, quota_step)
          status = summarize_reconciliation_status([health_step, quota_step])

          assignment =
            assignment
            |> Repo.reload!()
            |> maybe_record_reconciliation_summary(status, [health_step, quota_step], opts)

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

  defp maybe_record_reconciliation_summary(assignment, status, steps, opts) do
    if Keyword.get(opts, :record_summary?, true) and not superseded_quota_step?(steps) do
      record_reconciliation_summary!(assignment, status, steps)
    else
      assignment
    end
  end

  defp superseded_quota_step?(steps) do
    Enum.any?(steps, &(&1.code == "quota_refresh_superseded"))
  end

  defp record_reconciliation_health!(
         %PoolUpstreamAssignment{},
         %{
           code: "quota_refresh_auth_unavailable",
           identity: %UpstreamIdentity{status: "reauth_required"}
         }
       ) do
    step_result(
      :succeeded,
      "health_preserved",
      "assignment health was preserved for reauthentication"
    )
  end

  defp record_reconciliation_health!(%PoolUpstreamAssignment{}, %{
         code: "quota_refresh_superseded"
       }) do
    step_result(
      :succeeded,
      "health_preserved",
      "assignment health was preserved for a superseded quota refresh"
    )
  end

  defp record_reconciliation_health!(%PoolUpstreamAssignment{} = assignment, quota_step) do
    timestamp = now()

    assignment
    |> PoolUpstreamAssignment.changeset(%{
      health_status: @health_active,
      eligibility_status: eligibility_after_reconciliation(assignment, quota_step),
      last_healthcheck_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.update!()

    step_result(:succeeded, "health_refreshed", "assignment health refreshed")
  end

  defp eligibility_after_reconciliation(_assignment, %{
         status: :succeeded,
         code: "quota_refreshed",
         identity: %UpstreamIdentity{} = identity
       }) do
    if CredentialFencing.awaiting_provider_auth_recovery?(identity),
      do: @assignment_ineligible,
      else: @eligible
  end

  defp eligibility_after_reconciliation(assignment, _quota_step),
    do: assignment.eligibility_status

  defp refresh_reconciliation_quota(identity, assignment, opts) do
    source = reconciliation_quota_source(identity, assignment, opts)

    case source do
      :auth_unavailable ->
        step_result(
          :failed,
          "quota_refresh_auth_unavailable",
          "quota refresh requires account reauthentication"
        )

      {:definitive_provider_auth_rejected, fence} ->
        promote_definitive_provider_auth_rejection(identity, fence)

      :usage_unavailable ->
        step_result(:failed, "quota_refresh_unavailable", "quota windows were not available")

      {:persisted_windows, windows} ->
        step_result(:succeeded, "quota_reused_fresh", "fresh quota windows reused", %{
          "window_count" => length(windows)
        })

      {:windows, windows, identity_attrs} ->
        upsert_reconciliation_quota(identity, windows, identity_attrs, nil, nil, MapSet.new())

      {:usage, %UpstreamIdentity{} = usage_identity, %UsageProbe.Result{} = probe} ->
        upsert_reconciliation_quota(
          usage_identity,
          probe.windows,
          identity_attrs_from_codex_usage_payload(probe.payload),
          probe.payload,
          probe.usage_url,
          probe.covered_descriptors,
          probe.credential_fence
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

  defp promote_definitive_provider_auth_rejection(%UpstreamIdentity{} = identity, fence) do
    case CredentialFencing.mark_definitive_rejection(identity, fence) do
      {:ok, :applied, reauth_identity} ->
        step_result(
          :failed,
          "quota_refresh_auth_unavailable",
          "quota refresh requires account reauthentication"
        )
        |> Map.put(:identity, reauth_identity)

      {:ok, :superseded, current_identity} ->
        step_result(:skipped, "quota_refresh_superseded", "quota refresh was superseded")
        |> Map.put(:identity, current_identity)

      {:error, reason} ->
        step_result(:failed, "quota_refresh_failed", safe_error_message(reason))
    end
  end

  defp upsert_reconciliation_quota(
         identity,
         windows,
         identity_attrs,
         payload,
         usage_url,
         covered_descriptors,
         credential_fence \\ nil
       )

  defp upsert_reconciliation_quota(
         identity,
         windows,
         identity_attrs,
         payload,
         usage_url,
         covered_descriptors,
         credential_fence
       )
       when is_list(windows) do
    observed_at = now()

    result =
      if credential_fence do
        CredentialFencing.apply_usage_success(identity, credential_fence, fn locked_identity ->
          persist_reconciliation_quota(
            locked_identity,
            windows,
            identity_attrs,
            payload,
            observed_at,
            usage_url,
            covered_descriptors,
            false
          )
        end)
        |> case do
          {:ok, :applied, updated_identity, persisted} ->
            {:ok, %{persisted | identity: updated_identity}}

          {:ok, :superseded, current_identity, nil} ->
            {:superseded, current_identity}

          {:error, reason} ->
            {:error, reason}
        end
      else
        persist_reconciliation_quota(
          identity,
          windows,
          identity_attrs,
          payload,
          observed_at,
          usage_url,
          covered_descriptors,
          true
        )
      end

    case result do
      {:ok, %{windows: refreshed, identity: updated_identity}} ->
        # Fresh quota is now persisted: converge any pending saved-reset
        # redemption on this identity from that evidence (self-healing). Best
        # effort and a no-op for identities without a pending lifecycle.
        Convergence.converge(updated_identity, observed_at)

        step_result(:succeeded, "quota_refreshed", "quota windows refreshed", %{
          "window_count" => length(refreshed)
        })
        |> Map.put(:identity, updated_identity)

      {:error, {:identity_conflict, :workspace_identity_mismatch, conflict}} ->
        identity_conflict_step(conflict)

      {:error, reason} ->
        step_result(:failed, "quota_refresh_failed", safe_error_message(reason))

      {:superseded, current_identity} ->
        step_result(:skipped, "quota_refresh_superseded", "quota refresh was superseded")
        |> Map.put(:identity, current_identity)
    end
  end

  defp upsert_reconciliation_quota(
         _identity,
         _windows,
         _identity_attrs,
         _payload,
         _usage_url,
         _covered_descriptors,
         _credential_fence
       ),
       do: step_result(:failed, "quota_refresh_unavailable", "quota windows were not available")

  @doc false
  @spec refresh_quota_from_usage(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), keyword()) ::
          {:ok, UpstreamIdentity.t()} | {:error, term()}
  def refresh_quota_from_usage(
        %UpstreamIdentity{} = identity,
        %PoolUpstreamAssignment{} = assignment,
        opts \\ []
      ) do
    observed_at = now()

    case UsageProbe.fetch_from_identity(identity, assignment, observed_at, opts) do
      {:ok, %UsageProbe.Result{credential_fence: fence} = probe} when not is_nil(fence) ->
        apply_refresh_usage_success(identity, probe, observed_at, fence)

      {:error, {:definitive_provider_auth_rejected, fence}} ->
        apply_refresh_usage_rejection(identity, fence)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_refresh_usage_success(identity, probe, observed_at, fence) do
    CredentialFencing.apply_usage_success(identity, fence, fn locked_identity ->
      persist_reconciliation_quota(
        locked_identity,
        probe.windows,
        identity_attrs_from_codex_usage_payload(probe.payload),
        probe.payload,
        observed_at,
        probe.usage_url,
        probe.covered_descriptors,
        false
      )
    end)
    |> case do
      {:ok, :applied, updated_identity, _persisted} -> {:ok, updated_identity}
      {:ok, :superseded, _current_identity, nil} -> {:error, :quota_refresh_superseded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_refresh_usage_rejection(identity, fence) do
    case CredentialFencing.mark_definitive_rejection(identity, fence) do
      {:ok, :applied, _reauth_identity} -> {:error, :definitive_provider_auth_rejected}
      {:ok, :superseded, _current_identity} -> {:error, :quota_refresh_superseded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_reconciliation_quota(
         identity,
         windows,
         identity_attrs,
         payload,
         observed_at,
         usage_url,
         covered_descriptors,
         broadcast?
       ) do
    case Quota.Windows.upsert_quota_windows(identity, windows,
           delete_missing?: true,
           covered_descriptors: covered_descriptors,
           identity_attrs: identity_attrs,
           broadcast?: broadcast?
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
        |> Map.put(
          "saved_resets",
          SavedResets.usage_snapshot(payload, observed_at, usage_url, identity)
        ),
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

  defp codex_usage_quota_windows(%UpstreamIdentity{} = identity, assignment, opts) do
    case UsageProbe.reconciliation_source(identity, assignment, opts) do
      {:usage_rejected, _identity, fence} ->
        {:definitive_provider_auth_rejected, fence}

      result ->
        result
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
