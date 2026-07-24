defmodule CodexPooler.Upstreams.Reconciliation.PoolReconciliation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Repo
  alias CodexPooler.TransportFailureReason
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.Convergence
  alias CodexPooler.Upstreams.SavedResets.FirstSeenLedger
  alias CodexPooler.Upstreams.SavedResets.ObservationOrdering
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @active UpstreamIdentity.active_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @assignment_ineligible PoolUpstreamAssignment.ineligible_status()
  @health_active PoolUpstreamAssignment.active_health_status()
  @refresh_failed UpstreamIdentity.refresh_failed_status()
  @reauth_required UpstreamIdentity.reauth_required_status()
  # Auth-shaped rejections must surface instead of silently reusing
  # persisted windows. A 429 is deliberately absent: being told to slow
  # down does not invalidate a snapshot refreshed within its usable window,
  # and the minute-aligned reconciliation fan-out makes transient 429s
  # expected.
  @fallback_denied_usage_statuses [401, 403, :auth_rejected]

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type lifecycle_result :: {:ok, map()} | {:error, lifecycle_error()}
  @typep quota_refresh_context :: %{
           required(:identity) => UpstreamIdentity.t(),
           required(:assignment) => PoolUpstreamAssignment.t(),
           required(:quota) => %{
             required(:windows) => list(),
             required(:identity_attrs) => map(),
             required(:payload) => map() | nil,
             required(:usage_url) => String.t() | nil,
             required(:covered_descriptors) => MapSet.t()
           },
           required(:credential_fence) => map() | nil,
           required(:expected_credential_epoch) => pos_integer() | nil
         }

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
        finalize_reconciliation(assignment, identity, quota_step, opts)

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

  defp finalize_reconciliation(
         assignment,
         identity,
         %{credential_fence: fence} = quota_step,
         opts
       ) do
    identity
    |> CredentialFencing.guard_active_usage_probe_completion(
      fence,
      probe_completion_mode(quota_step),
      fn locked_identity ->
        finalize_locked_assignment(assignment.id, locked_identity, quota_step, opts)
      end
    )
    |> finish_fenced_reconciliation(assignment, identity, quota_step)
  end

  defp finalize_reconciliation(
         assignment,
         identity,
         %{expected_credential_epoch: expected_credential_epoch} = quota_step,
         opts
       ) do
    identity
    |> CredentialFencing.guard_active_reconciliation_epoch(
      expected_credential_epoch,
      fn locked_identity ->
        finalize_locked_assignment(assignment.id, locked_identity, quota_step, opts)
      end
    )
    |> finish_unfenced_reconciliation(assignment, identity)
  end

  defp finalize_reconciliation(assignment, identity, quota_step, opts) do
    identity
    |> CredentialFencing.guard_active_reconciliation(fn locked_identity ->
      finalize_locked_assignment(assignment.id, locked_identity, quota_step, opts)
    end)
    |> finish_unfenced_reconciliation(assignment, identity)
  end

  defp finalize_locked_assignment(assignment_id, identity, quota_step, opts) do
    case Repo.get(PoolUpstreamAssignment, assignment_id) do
      %PoolUpstreamAssignment{status: @assignment_active} = assignment ->
        {:ok, {:finalized, finalize_active_assignment(assignment, identity, quota_step, opts)}}

      %PoolUpstreamAssignment{} = assignment ->
        {:ok, {:assignment_superseded, assignment}}

      nil ->
        {:ok, {:assignment_superseded, nil}}
    end
  end

  defp finish_fenced_reconciliation(
         {:ok, :applied, identity, {:finalized, result}},
         _assignment,
         _initial_identity,
         _quota_step
       ) do
    {:ok, put_result_identity(result, identity)}
  end

  defp finish_fenced_reconciliation(
         {:ok, :applied, identity, {:assignment_superseded, current_assignment}},
         assignment,
         _initial_identity,
         _quota_step
       ) do
    {:ok, superseded_reconciliation_result(current_assignment || assignment, identity)}
  end

  defp finish_fenced_reconciliation(
         {:ok, :superseded, identity, nil},
         assignment,
         _initial_identity,
         %{code: "quota_refresh_auth_unavailable"} = quota_step
       ) do
    current_assignment = Repo.get(PoolUpstreamAssignment, assignment.id) || assignment

    if current_auth_failure?(identity, quota_step) do
      {:ok, preserved_rejection_result(current_assignment, identity, quota_step)}
    else
      {:ok, superseded_reconciliation_result(current_assignment, identity)}
    end
  end

  defp finish_fenced_reconciliation(
         {:ok, :superseded, identity, nil},
         assignment,
         _initial_identity,
         _quota_step
       ) do
    current_assignment = Repo.get(PoolUpstreamAssignment, assignment.id) || assignment
    {:ok, superseded_reconciliation_result(current_assignment, identity)}
  end

  defp finish_fenced_reconciliation({:error, reason}, assignment, identity, _quota_step) do
    health_step = step_result(:skipped, "health_skipped", "assignment health was not refreshed")
    failed_quota_step = step_result(:failed, "quota_refresh_failed", safe_error_message(reason))

    {:ok,
     %{
       status: :failed,
       assignment: Repo.get(PoolUpstreamAssignment, assignment.id) || assignment,
       identity: Repo.get(UpstreamIdentity, identity.id) || identity,
       health: health_step,
       quota: failed_quota_step
     }}
  end

  defp finish_unfenced_reconciliation(
         {:ok, :applied, current_identity, {:finalized, result}},
         _assignment,
         _identity
       ) do
    {:ok, put_result_identity(result, current_identity)}
  end

  defp finish_unfenced_reconciliation(
         {:ok, :applied, current_identity, {:assignment_superseded, current_assignment}},
         assignment,
         _identity
       ) do
    {:ok, superseded_reconciliation_result(current_assignment || assignment, current_identity)}
  end

  defp finish_unfenced_reconciliation(
         {:ok, :superseded, current_identity, nil},
         assignment,
         _identity
       ) do
    current_assignment = Repo.get(PoolUpstreamAssignment, assignment.id) || assignment
    {:ok, superseded_reconciliation_result(current_assignment, current_identity)}
  end

  defp finish_unfenced_reconciliation({:error, reason}, assignment, identity) do
    finish_fenced_reconciliation({:error, reason}, assignment, identity, %{})
  end

  defp finalize_active_assignment(assignment, identity, quota_step, opts) do
    if identity_conflict_step?(quota_step) do
      assignment =
        record_identity_conflict!(assignment, quota_step.details["identity_conflict"])

      health_step =
        step_result(:skipped, "health_skipped", "assignment health was not refreshed")

      %{
        status: :failed,
        assignment: assignment,
        identity: step_identity(quota_step, identity),
        health: health_step,
        quota: quota_step
      }
    else
      health_step = record_reconciliation_health!(assignment, quota_step)
      status = summarize_reconciliation_status([health_step, quota_step])

      assignment =
        assignment
        |> Repo.reload!()
        |> maybe_record_reconciliation_summary(status, [health_step, quota_step], opts)

      %{
        status: status,
        assignment: assignment,
        identity: step_identity(quota_step, identity),
        health: health_step,
        quota: quota_step
      }
    end
  end

  defp superseded_reconciliation_result(assignment, identity) do
    quota_step =
      step_result(:skipped, "quota_refresh_superseded", "quota refresh was superseded")
      |> Map.put(:identity, identity)

    health_step = record_reconciliation_health!(assignment, quota_step)

    %{
      status: summarize_reconciliation_status([health_step, quota_step]),
      assignment: assignment,
      identity: identity,
      health: health_step,
      quota: quota_step
    }
  end

  defp preserved_rejection_result(assignment, identity, quota_step) do
    quota_step = Map.put(quota_step, :identity, identity)
    health_step = record_reconciliation_health!(assignment, quota_step)

    %{
      status: summarize_reconciliation_status([health_step, quota_step]),
      assignment: assignment,
      identity: identity,
      health: health_step,
      quota: quota_step
    }
  end

  defp current_auth_failure?(
         %UpstreamIdentity{status: status} = identity,
         %{credential_fence: %{credential_epoch: credential_epoch}}
       )
       when status in [@refresh_failed, @reauth_required],
       do: CredentialFencing.current_credential_epoch?(identity, credential_epoch)

  defp current_auth_failure?(_identity, _quota_step), do: false

  defp put_result_identity(result, identity) do
    %{result | identity: identity, quota: Map.put(result.quota, :identity, identity)}
  end

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

  defp record_reconciliation_health!(%PoolUpstreamAssignment{}, %{
         code: "quota_refresh_auth_unavailable"
       }) do
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

      {:auth_unavailable, fence} ->
        step_result(
          :failed,
          "quota_refresh_auth_unavailable",
          "quota refresh requires account reauthentication"
        )
        |> put_credential_fence(fence)

      {:definitive_provider_auth_rejected, fence} ->
        promote_definitive_provider_auth_rejection(identity, fence)

      {:usage_unavailable, reason, fence} ->
        step_result(
          :failed,
          "quota_refresh_unavailable",
          "quota windows were not available (#{safe_unavailable_reason(reason)})"
        )
        |> put_credential_fence(fence)

      {:persisted_windows, windows, fence} ->
        step_result(:succeeded, "quota_reused_fresh", "fresh quota windows reused", %{
          "window_count" => length(windows)
        })
        |> put_credential_fence(fence)

      {:windows, windows, identity_attrs, expected_credential_epoch} ->
        upsert_reconciliation_quota(%{
          identity: identity,
          assignment: assignment,
          quota: %{
            windows: windows,
            identity_attrs: identity_attrs,
            payload: nil,
            usage_url: nil,
            covered_descriptors: MapSet.new()
          },
          credential_fence: nil,
          expected_credential_epoch: expected_credential_epoch
        })

      {:usage, %UpstreamIdentity{} = usage_identity, %UsageProbe.Result{} = probe} ->
        upsert_reconciliation_quota(%{
          identity: usage_identity,
          assignment: assignment,
          quota: %{
            windows: probe.windows,
            identity_attrs: identity_attrs_from_codex_usage_payload(probe.payload),
            payload: probe.payload,
            usage_url: probe.usage_url,
            covered_descriptors: probe.covered_descriptors
          },
          credential_fence: probe.credential_fence,
          expected_credential_epoch: nil
        })
    end
  end

  defp reconciliation_quota_source(identity, assignment, opts) do
    cond do
      Keyword.has_key?(opts, :quota_windows) ->
        {:windows, Keyword.get(opts, :quota_windows), Keyword.get(opts, :identity_attrs, %{}),
         CredentialFencing.credential_epoch(identity)}

      windows = metadata_quota_windows(identity, assignment) ->
        {:windows, windows, %{}, CredentialFencing.credential_epoch(identity)}

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
        |> put_credential_fence(fence)

      {:ok, :superseded, current_identity} ->
        step_result(:skipped, "quota_refresh_superseded", "quota refresh was superseded")
        |> Map.put(:identity, current_identity)

      {:error, reason} ->
        step_result(:failed, "quota_refresh_failed", safe_error_message(reason))
    end
  end

  @spec upsert_reconciliation_quota(quota_refresh_context()) :: map()
  defp upsert_reconciliation_quota(
         %{
           identity: identity,
           quota: %{
             windows: windows,
             identity_attrs: identity_attrs,
             payload: payload,
             usage_url: usage_url,
             covered_descriptors: covered_descriptors
           },
           credential_fence: credential_fence
         } = context
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
        persist_unfenced_reconciliation_quota(context, observed_at)
      end

    result =
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
          |> put_credential_fence(credential_fence)

        {:error, {:identity_conflict, :workspace_identity_mismatch, conflict}} ->
          conflict
          |> identity_conflict_step()
          |> put_credential_fence(credential_fence)

        {:error, reason} ->
          step_result(:failed, "quota_refresh_failed", safe_error_message(reason))
          |> put_credential_fence(credential_fence)

        {:superseded, current_identity} ->
          step_result(:skipped, "quota_refresh_superseded", "quota refresh was superseded")
          |> Map.put(:identity, current_identity)
      end

    put_expected_credential_epoch(result, context.expected_credential_epoch)
  end

  defp upsert_reconciliation_quota(%{
         credential_fence: credential_fence,
         expected_credential_epoch: expected_credential_epoch
       }),
       do:
         step_result(:failed, "quota_refresh_unavailable", "quota windows were not available")
         |> put_credential_fence(credential_fence)
         |> put_expected_credential_epoch(expected_credential_epoch)

  @spec persist_unfenced_reconciliation_quota(quota_refresh_context(), DateTime.t()) ::
          {:ok, map()} | {:superseded, UpstreamIdentity.t()} | {:error, term()}
  defp persist_unfenced_reconciliation_quota(
         %{
           identity: identity,
           assignment: assignment,
           quota: %{
             windows: windows,
             identity_attrs: identity_attrs,
             payload: payload,
             usage_url: usage_url,
             covered_descriptors: covered_descriptors
           },
           expected_credential_epoch: expected_credential_epoch
         },
         observed_at
       ) do
    identity
    |> CredentialFencing.guard_active_reconciliation(fn locked_identity ->
      case {CredentialFencing.current_credential_epoch?(
              locked_identity,
              expected_credential_epoch
            ), Repo.get(PoolUpstreamAssignment, assignment.id)} do
        {true, %PoolUpstreamAssignment{status: @assignment_active}} ->
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

        {false, _assignment} ->
          {:ok, :credential_superseded}

        {_current_epoch, _assignment} ->
          {:ok, :assignment_superseded}
      end
    end)
    |> case do
      {:ok, :applied, updated_identity, %{windows: _windows} = persisted} ->
        Quota.Windows.broadcast_quota_update(updated_identity)
        {:ok, %{persisted | identity: updated_identity}}

      {:ok, :applied, current_identity, superseded}
      when superseded in [:assignment_superseded, :credential_superseded] ->
        {:superseded, current_identity}

      {:ok, :superseded, current_identity, nil} ->
        {:superseded, current_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
    persisted_observed_at = get_in(identity.metadata || %{}, ["saved_resets", "observed_at"])

    case ObservationOrdering.authorize(observed_at, persisted_observed_at) do
      {:apply, _canonical_observed_at} ->
        snapshot = SavedResets.usage_snapshot(payload, observed_at, usage_url, identity)
        {snapshot, ledger_change} = compose_saved_reset_state(identity, snapshot, observed_at)

        attrs = %{
          metadata: Map.put(identity.metadata || %{}, "saved_resets", snapshot),
          updated_at: observed_at
        }

        attrs =
          case ledger_change do
            {:put, ledger} -> Map.put(attrs, :saved_reset_first_seen_ledger, ledger)
            :omit -> attrs
          end

        identity
        |> Ecto.Changeset.change(attrs)
        |> Repo.update!()
        |> Repo.reload!()

      :skip ->
        identity
    end
  end

  defp maybe_update_saved_reset_snapshot(identity, _payload, _observed_at, _usage_url),
    do: identity

  defp compose_saved_reset_state(
         _identity,
         %{"expires_detail_status" => "incomplete"} = snapshot,
         _observed_at
       ) do
    {snapshot, :omit}
  end

  defp compose_saved_reset_state(identity, snapshot, observed_at) do
    candidate_rows = saved_reset_expiration_rows(snapshot)
    current_expirations = Enum.map(candidate_rows, &Map.get(&1, "expires_at"))
    ledger = identity.saved_reset_first_seen_ledger || FirstSeenLedger.empty()

    if oversized_legacy_seed_source?(identity, ledger) do
      case Map.get(snapshot, "expires_detail_status") do
        status when status in ["authoritative_zero", "authoritative_rows"] ->
          merge_saved_reset_state(
            snapshot,
            ledger,
            candidate_rows,
            current_expirations,
            observed_at
          )

        _reused_or_incomplete ->
          {Map.get(identity.metadata || %{}, "saved_resets", snapshot), :omit}
      end
    else
      merge_saved_reset_state(
        snapshot,
        ledger,
        saved_reset_expiration_rows(identity.metadata) ++ candidate_rows,
        current_expirations,
        observed_at
      )
    end
  end

  defp oversized_legacy_seed_source?(identity, ledger) do
    ledger == FirstSeenLedger.empty() and
      saved_reset_expiration_rows(identity.metadata) != [] and
      not persisted_expiration_seed_source_within_bound?(identity.id)
  end

  defp persisted_expiration_seed_source_within_bound?(identity_id) do
    Repo.one(
      from identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        select:
          fragment(
            "COALESCE(pg_column_size(?->'saved_resets'->'available_expirations') <= ?, TRUE)",
            identity.metadata,
            ^SavedResets.detail_payload_max_bytes()
          )
    )
  end

  defp merge_saved_reset_state(
         snapshot,
         ledger,
         incoming_rows,
         current_expirations,
         observed_at
       ) do
    case FirstSeenLedger.merge(
           ledger,
           incoming_rows,
           current_expirations,
           observed_at
         ) do
      {:ok, merged_ledger} ->
        {materialize_first_seen(snapshot, merged_ledger), {:put, merged_ledger}}

      {:opaque, _original} ->
        {snapshot, :omit}
    end
  end

  defp saved_reset_expiration_rows(%{"saved_resets" => saved_resets}),
    do: saved_reset_expiration_rows(saved_resets)

  defp saved_reset_expiration_rows(%{"available_expirations" => rows}) when is_list(rows),
    do: rows

  defp saved_reset_expiration_rows(_metadata), do: []

  defp materialize_first_seen(snapshot, ledger) do
    rows =
      snapshot
      |> saved_reset_expiration_rows()
      |> Enum.map(fn row ->
        case FirstSeenLedger.lookup(ledger, Map.get(row, "expires_at")) do
          {:ok, first_seen_at} -> Map.put(row, "first_seen_at", first_seen_at)
          :error -> row
          {:opaque, _original} -> row
        end
      end)

    Map.put(snapshot, "available_expirations", rows)
  end

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
         {:usage_unavailable, {:upstream_status, status}, _fence} = unavailable,
         _identity
       )
       when status in @fallback_denied_usage_statuses,
       do: unavailable

  defp maybe_reuse_persisted_quota_windows(
         {:usage_unavailable, {:mixed_auth_rejection, _reason}, _fence} = unavailable,
         _identity
       ),
       do: unavailable

  defp maybe_reuse_persisted_quota_windows(
         {:usage_unavailable, _reason, fence} = unavailable,
         identity
       ) do
    timestamp = now()

    windows =
      identity
      |> Quota.Windows.list_quota_windows()
      |> Enum.filter(&reusable_persisted_quota_window?(&1, timestamp))

    if windows != [] do
      {:persisted_windows, windows, fence}
    else
      unavailable
    end
  end

  defp maybe_reuse_persisted_quota_windows(result, _identity), do: result

  # The weekly account window counts as reusable: since the provider
  # suspended the anchored 5h windows (announced as temporary), it is the
  # primary quota signal, and a transient probe failure must not fail the
  # cycle while a usable snapshot exists.
  defp reusable_persisted_quota_window?(window, timestamp) do
    (WindowClassifier.primary_5h?(window) or WindowClassifier.monthly_primary?(window) or
       WindowClassifier.weekly_secondary?(window)) and
      Quota.Windows.usable_window?(window, timestamp)
  end

  defp safe_unavailable_reason({:upstream_status, status})
       when is_integer(status) or is_atom(status),
       do: "upstream_status_#{status}"

  defp safe_unavailable_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_unavailable_reason(%{__struct__: _module, reason: reason}),
    do: safe_unavailable_reason(reason)

  defp safe_unavailable_reason(reason) when is_tuple(reason),
    do: TransportFailureReason.safe_reason(reason) || "unknown"

  defp safe_unavailable_reason(_reason), do: "unknown"

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

  defp put_credential_fence(step, nil), do: step
  defp put_credential_fence(step, fence), do: Map.put(step, :credential_fence, fence)

  defp put_expected_credential_epoch(step, nil), do: step

  defp put_expected_credential_epoch(step, expected_credential_epoch),
    do: Map.put(step, :expected_credential_epoch, expected_credential_epoch)

  defp probe_completion_mode(%{code: "quota_refresh_auth_unavailable"}), do: :auth_failure
  defp probe_completion_mode(_quota_step), do: :active_only

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
