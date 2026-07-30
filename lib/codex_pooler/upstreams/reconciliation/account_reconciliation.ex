defmodule CodexPooler.Upstreams.Reconciliation.AccountReconciliation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPooler.Events
  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @stale_after_seconds 25 * 60
  @successful_partial_codes ~w(catalog_sync_failed catalog_sync_in_progress)
  @catalog_sync_skipped_triggers ~w(scheduled gateway)
  @active IdentityStatus.active_status()
  @paused IdentityStatus.paused_status()
  @refresh_failed IdentityStatus.refresh_failed_status()
  @reauth_required IdentityStatus.reauth_required_status()
  @assignment_active AssignmentStatus.active_status()
  @assignment_paused AssignmentStatus.paused_status()
  @assignment_reauth_required AssignmentStatus.reauth_required_status()

  @type orchestration_result :: {:ok, map()} | {:error, term()}
  @type operation_clock :: (-> DateTime.t())
  @type run_option :: {:operation_clock, operation_clock()}
  @type run_options :: [run_option()]

  @spec run(term(), term(), term()) :: orchestration_result()
  def run(pool_id, assignment_id, trigger_kind) do
    run(pool_id, assignment_id, trigger_kind, [])
  end

  @doc false
  @spec run(term(), term(), term(), run_options()) :: orchestration_result()
  def run(pool_id, assignment_id, trigger_kind, opts) when is_list(opts) do
    operation_clock = operation_clock!(opts)
    trigger_kind = normalize_trigger_kind(trigger_kind)

    if reason = skipped_reconciliation_target(pool_id, assignment_id) do
      result = %{
        status: :skipped,
        trigger_kind: trigger_kind,
        reason: reason
      }

      broadcast_job_result(pool_id, "account_reconciliation", {:ok, result})
      {:ok, result}
    else
      run_reconciliation(pool_id, assignment_id, trigger_kind, operation_clock)
    end
  end

  defp run_reconciliation(pool_id, assignment_id, trigger_kind, operation_clock) do
    priming_fence = priming_fence(pool_id, assignment_id)
    mark_refreshing(pool_id, assignment_id, trigger_kind, priming_fence)

    case PoolReconciliation.reconcile_pool_account(pool_id, assignment_id, record_summary?: false) do
      {:ok, result} ->
        catalog_step = reconcile_catalog(pool_id, trigger_kind)
        status = summarize_status([result.health, result.quota, catalog_step])
        operation_timestamp = operation_timestamp!(operation_clock)

        case finalize_terminal_result(
               result,
               catalog_step,
               status,
               trigger_kind,
               operation_timestamp
             ) do
          {:ok, finalized_result} ->
            broadcast_job_result(pool_id, "account_reconciliation", {:ok, finalized_result})
            {:ok, finalized_result}

          {:error, reason} ->
            mark_failed(pool_id, assignment_id, trigger_kind, reason, priming_fence)
            broadcast_job_result(pool_id, "account_reconciliation", {:error, reason})
            {:error, reason}
        end

      {:error, reason} ->
        mark_failed(pool_id, assignment_id, trigger_kind, reason, priming_fence)
        broadcast_job_result(pool_id, "account_reconciliation", {:error, reason})
        {:error, reason}
    end
  end

  @spec successful_status?(term()) :: boolean()
  def successful_status?(%{status: :succeeded}), do: true
  def successful_status?(%{status: :skipped}), do: true

  def successful_status?(%{status: :partial} = result) do
    failed_codes = failed_codes(result)

    failed_codes != [] and Enum.all?(failed_codes, &(&1 in @successful_partial_codes))
  end

  def successful_status?(_result), do: false

  @spec cleanup_stale_state(DateTime.t()) ::
          {:ok, %{required(:stale_account_reconciliations_failed) => non_neg_integer()}}
  def cleanup_stale_state(now) do
    now = DateTime.truncate(now, :microsecond)
    cutoff = DateTime.add(now, -@stale_after_seconds, :second)

    failed_count =
      PoolUpstreamAssignment
      |> where(
        [assignment],
        fragment("?->'quota_priming'->>'status' = ?", assignment.metadata, "refreshing")
      )
      |> Repo.all()
      |> Enum.filter(&stale_quota_priming?(&1, cutoff))
      |> Enum.reduce(0, fn assignment, count ->
        if fail_stale_priming(assignment, now, cutoff), do: count + 1, else: count
      end)

    {:ok, %{stale_account_reconciliations_failed: failed_count}}
  end

  defp fail_stale_priming(assignment, now, cutoff) do
    result =
      CredentialFencing.guard_active_reconciliation(
        assignment.upstream_identity_id,
        :auth_failure,
        fn locked_identity ->
          case Repo.get(PoolUpstreamAssignment, assignment.id) do
            %PoolUpstreamAssignment{} = current_assignment ->
              persist_stale_priming_failure(
                current_assignment,
                locked_identity,
                now,
                cutoff
              )

            nil ->
              {:ok, :unchanged}
          end
        end
      )

    case result do
      {:ok, :applied, _identity, %PoolUpstreamAssignment{} = failed_assignment} ->
        broadcast_priming_state(failed_assignment)
        true

      _result ->
        false
    end
  end

  defp persist_stale_priming_failure(assignment, identity, now, cutoff) do
    if assignment.status == @assignment_active and stale_quota_priming?(assignment, cutoff) and
         stale_priming_epoch_current?(assignment, identity) do
      priming = assignment.metadata["quota_priming"] || %{}

      assignment
      |> PoolUpstreamAssignment.changeset(%{
        metadata:
          Map.put(assignment.metadata, "quota_priming", %{
            "status" => "failed",
            "trigger_kind" => Map.get(priming, "trigger_kind", "unknown"),
            "started_at" => Map.get(priming, "started_at"),
            "finished_at" => timestamp_iso(now),
            "reason" => %{
              "code" => "runtime_timeout",
              "message" => "account reconciliation timed out before completion"
            }
          })
      })
      |> Repo.update()
    else
      {:ok, :unchanged}
    end
  end

  @spec discard_stale_jobs(DateTime.t(), String.t()) :: {non_neg_integer(), nil | [term()]}
  def discard_stale_jobs(now, worker) when is_binary(worker) do
    now = DateTime.truncate(now, :microsecond)
    cutoff = DateTime.add(now, -@stale_after_seconds, :second)

    Oban.Job
    |> where(
      [job],
      job.worker == ^worker and job.state == "executing" and
        job.attempt >= job.max_attempts and job.attempted_at <= ^cutoff
    )
    |> Repo.update_all(set: [state: "discarded", discarded_at: now])
  end

  defp maybe_record_result!(
         %{quota: %{code: "quota_refresh_superseded"}} = result,
         _operation_timestamp
       ) do
    %{result | assignment: Repo.reload!(result.assignment)}
  end

  defp maybe_record_result!(result, operation_timestamp) do
    assignment = result.assignment
    metadata = assignment.metadata || %{}

    summary = %{
      "status" => Atom.to_string(result.status),
      "finished_at" => DateTime.to_iso8601(operation_timestamp),
      "steps" => Enum.map([result.health, result.quota, result.catalog], &step_to_metadata/1)
    }

    {:ok, assignment} =
      PoolAssignments.update_pool_assignment(assignment, %{
        metadata: Map.put(metadata, "last_reconciliation", summary),
        last_successful_refresh_at:
          if(result.status == :succeeded,
            do: operation_timestamp,
            else: assignment.last_successful_refresh_at
          )
      })

    %{result | assignment: assignment}
  end

  defp finalize_terminal_result(
         result,
         catalog_step,
         status,
         trigger_kind,
         operation_timestamp
       ) do
    apply = fn locked_identity ->
      finalize_locked_terminal_result(
        result,
        locked_identity,
        catalog_step,
        status,
        trigger_kind,
        operation_timestamp
      )
    end

    result.identity
    |> guard_terminal_result(result.quota, apply)
    |> normalize_terminal_result(result, catalog_step, trigger_kind)
  end

  defp guard_terminal_result(
         identity,
         %{code: "quota_refresh_auth_unavailable", credential_fence: fence},
         apply
       ) do
    CredentialFencing.guard_current_usage_probe_completion(identity, fence, :auth_failure, apply)
  end

  defp guard_terminal_result(identity, %{credential_fence: fence}, apply) do
    CredentialFencing.guard_current_usage_probe_completion(identity, fence, :active_only, apply)
  end

  defp guard_terminal_result(
         identity,
         %{expected_credential_epoch: expected_credential_epoch},
         apply
       ) do
    CredentialFencing.guard_active_reconciliation_epoch(
      identity,
      expected_credential_epoch,
      apply
    )
  end

  defp guard_terminal_result(identity, _quota_step, apply) do
    CredentialFencing.guard_active_reconciliation(identity, apply)
  end

  defp finalize_locked_terminal_result(
         result,
         identity,
         catalog_step,
         status,
         trigger_kind,
         operation_timestamp
       ) do
    case Repo.get(PoolUpstreamAssignment, result.assignment.id) do
      %PoolUpstreamAssignment{status: @assignment_active} = assignment ->
        result = %{
          status: status,
          trigger_kind: trigger_kind,
          assignment: assignment,
          identity: identity,
          health: result.health,
          quota: Map.put(result.quota, :identity, identity),
          catalog: catalog_step
        }

        assignment =
          record_quota_priming_result!(
            assignment,
            identity,
            status,
            trigger_kind,
            result.quota,
            operation_timestamp
          )

        {:ok,
         {:finalized,
          result
          |> Map.put(:assignment, assignment)
          |> maybe_record_result!(operation_timestamp)}}

      %PoolUpstreamAssignment{} = assignment ->
        {:ok, {:assignment_superseded, assignment}}

      nil ->
        {:ok, {:assignment_superseded, nil}}
    end
  end

  defp normalize_terminal_result(
         {:ok, :applied, _identity, {:finalized, result}},
         _initial_result,
         _catalog_step,
         _trigger_kind
       ) do
    broadcast_priming_state(result.assignment)
    {:ok, result}
  end

  defp normalize_terminal_result(
         {:ok, :applied, identity, {:assignment_superseded, assignment}},
         result,
         catalog_step,
         trigger_kind
       ) do
    {:ok,
     superseded_terminal_result(
       result,
       assignment || result.assignment,
       identity,
       catalog_step,
       trigger_kind
     )}
  end

  defp normalize_terminal_result(
         {:ok, :superseded, identity, nil},
         result,
         catalog_step,
         trigger_kind
       ) do
    assignment = Repo.get(PoolUpstreamAssignment, result.assignment.id) || result.assignment
    {:ok, superseded_terminal_result(result, assignment, identity, catalog_step, trigger_kind)}
  end

  defp normalize_terminal_result(
         {:error, reason},
         _result,
         _catalog_step,
         _trigger_kind
       ),
       do: {:error, reason}

  defp superseded_terminal_result(result, assignment, identity, catalog_step, trigger_kind) do
    quota_step = superseded_terminal_quota_step(result.quota, identity)
    status = summarize_status([result.health, quota_step, catalog_step])

    %{
      status: status,
      trigger_kind: trigger_kind,
      assignment: assignment,
      identity: identity,
      health: result.health,
      quota: quota_step,
      catalog: catalog_step
    }
  end

  defp superseded_terminal_quota_step(
         %{
           code: "quota_refresh_auth_unavailable",
           credential_fence: %{credential_epoch: credential_epoch}
         } = quota_step,
         %UpstreamIdentity{status: status} = identity
       )
       when status in [@reauth_required, @refresh_failed] do
    if CredentialFencing.current_credential_epoch?(identity, credential_epoch) do
      Map.put(quota_step, :identity, identity)
    else
      superseded_quota_step(identity)
    end
  end

  defp superseded_terminal_quota_step(_quota_step, identity) do
    superseded_quota_step(identity)
  end

  defp superseded_quota_step(identity) do
    step(:skipped, "quota_refresh_superseded", "quota refresh was superseded")
    |> Map.put(:identity, identity)
  end

  defp mark_refreshing(
         pool_id,
         assignment_id,
         trigger_kind,
         priming_fence
       ) do
    # This pre-operation lifecycle marker is intentionally outside the terminal
    # quota-priming summary cycle.
    timestamp = now()

    record_active_priming_state(
      pool_id,
      assignment_id,
      priming_fence,
      :active_only,
      %{
        "status" => "refreshing",
        "trigger_kind" => trigger_kind,
        "started_at" => timestamp_iso(timestamp)
      }
    )
  end

  defp mark_failed(
         pool_id,
         assignment_id,
         trigger_kind,
         reason,
         priming_fence
       ) do
    # This failure path has no persisted-window summary read.
    timestamp = now()

    record_active_priming_state(
      pool_id,
      assignment_id,
      priming_fence,
      :auth_failure,
      %{
        "status" => "failed",
        "trigger_kind" => trigger_kind,
        "finished_at" => timestamp_iso(timestamp),
        "reason" => sanitized_reason(reason)
      }
    )
  end

  defp priming_fence(pool_id, assignment_id) do
    Repo.one(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where:
          assignment.id == ^assignment_id and assignment.pool_id == ^pool_id and
            assignment.status == ^@assignment_active and
            identity.status == ^UpstreamIdentity.active_status(),
        limit: 1,
        select: identity
    )
    |> case do
      %UpstreamIdentity{} = identity ->
        %{
          identity_id: identity.id,
          credential_epoch: CredentialFencing.credential_epoch(identity)
        }

      nil ->
        nil
    end
  end

  defp record_active_priming_state(
         pool_id,
         assignment_id,
         %{identity_id: identity_id, credential_epoch: credential_epoch},
         mode,
         attrs
       ) do
    attrs = Map.put(attrs, "credential_epoch", credential_epoch)

    result =
      CredentialFencing.guard_active_reconciliation(identity_id, mode, fn locked_identity ->
        persist_active_priming_state(
          pool_id,
          assignment_id,
          locked_identity,
          credential_epoch,
          attrs
        )
      end)

    broadcast_active_priming_state(result, pool_id)
  end

  defp record_active_priming_state(
         _pool_id,
         _assignment_id,
         _priming_fence,
         _mode,
         _attrs
       ),
       do: {:ok, :superseded}

  defp persist_active_priming_state(
         pool_id,
         assignment_id,
         locked_identity,
         credential_epoch,
         attrs
       ) do
    assignment =
      Repo.one(
        from assignment in PoolUpstreamAssignment,
          where:
            assignment.id == ^assignment_id and assignment.pool_id == ^pool_id and
              assignment.upstream_identity_id == ^locked_identity.id and
              assignment.status == ^@assignment_active,
          limit: 1
      )

    persist_current_priming_state(assignment, locked_identity, credential_epoch, attrs)
  end

  defp persist_current_priming_state(
         %PoolUpstreamAssignment{} = assignment,
         locked_identity,
         credential_epoch,
         attrs
       ) do
    if CredentialFencing.current_credential_epoch?(locked_identity, credential_epoch) do
      assignment
      |> PoolUpstreamAssignment.changeset(%{
        metadata: Map.put(assignment.metadata || %{}, "quota_priming", attrs)
      })
      |> Repo.update()
    else
      {:ok, :superseded}
    end
  end

  defp persist_current_priming_state(_assignment, _identity, _credential_epoch, _attrs),
    do: {:ok, :superseded}

  defp broadcast_active_priming_state(
         {:ok, :applied, _identity, %PoolUpstreamAssignment{} = assignment} = result,
         _pool_id
       ) do
    broadcast_priming_state(assignment)
    result
  end

  defp broadcast_active_priming_state(result, _pool_id), do: result

  defp broadcast_priming_state(%PoolUpstreamAssignment{} = assignment) do
    Events.broadcast_upstreams_after_commit(assignment.pool_id, "quota_priming_updated", %{
      assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      assignment_status: assignment.status,
      quota_priming_status: get_in(assignment.metadata || %{}, ["quota_priming", "status"])
    })
  end

  defp skipped_reconciliation_target(pool_id, assignment_id)
       when is_binary(pool_id) and is_binary(assignment_id) do
    case Repo.one(
           from assignment in PoolUpstreamAssignment,
             join: identity in UpstreamIdentity,
             on: identity.id == assignment.upstream_identity_id,
             where: assignment.id == ^assignment_id and assignment.pool_id == ^pool_id,
             limit: 1,
             select: {assignment.status, identity.status}
         ) do
      {@assignment_paused, _identity_status} ->
        skipped_reconciliation_reason(
          :upstream_account_paused,
          "paused upstream accounts are skipped by account reconciliation"
        )

      {_assignment_status, @paused} ->
        skipped_reconciliation_reason(
          :upstream_account_paused,
          "paused upstream accounts are skipped by account reconciliation"
        )

      {@assignment_reauth_required, _identity_status} ->
        skipped_reconciliation_reason(
          :upstream_account_reauth_required,
          "upstream accounts requiring reauthentication are skipped by account reconciliation"
        )

      {_assignment_status, @reauth_required} ->
        skipped_reconciliation_reason(
          :upstream_account_reauth_required,
          "upstream accounts requiring reauthentication are skipped by account reconciliation"
        )

      statuses ->
        inactive_reconciliation_reason(statuses)
    end
  end

  defp skipped_reconciliation_target(_pool_id, _assignment_id), do: nil

  defp inactive_reconciliation_reason({@assignment_active, @active}), do: nil

  defp inactive_reconciliation_reason({_assignment_status, _identity_status}) do
    skipped_reconciliation_reason(
      :upstream_account_inactive,
      "inactive upstream accounts are skipped by account reconciliation"
    )
  end

  defp inactive_reconciliation_reason(_statuses), do: nil

  defp skipped_reconciliation_reason(code, message), do: %{code: code, message: message}

  defp normalize_trigger_kind(trigger_kind) when is_binary(trigger_kind), do: trigger_kind
  defp normalize_trigger_kind(_trigger_kind), do: "manual"

  defp broadcast_job_result(pool_id, worker, {:ok, %{status: status}}) do
    Events.broadcast_job_status(pool_id, "job_status_updated", %{
      id: worker,
      worker: worker,
      status: Atom.to_string(status)
    })
  end

  defp broadcast_job_result(pool_id, worker, {:error, reason}) do
    Events.broadcast_job_status(pool_id, "job_status_updated", %{
      id: worker,
      worker: worker,
      status: "failed",
      code: inspect(reason)
    })
  end

  defp reconcile_catalog(_pool_id, trigger_kind)
       when trigger_kind in @catalog_sync_skipped_triggers do
    step(:succeeded, "catalog_sync_skipped", "catalog sync is owned by catalog scheduler")
  end

  defp reconcile_catalog(pool_id, _trigger_kind) do
    case Catalog.sync_pool_catalog(pool_id, trigger_kind: "reconcile") do
      {:ok, %{partial?: true}} ->
        step(
          :succeeded,
          "catalog_sync_partial",
          "catalog sync completed with unreachable sources"
        )

      {:ok, _result} ->
        step(:succeeded, "catalog_refreshed", "catalog sync completed")

      {:error, %{code: code, message: message}} ->
        step(:failed, to_string(code), message)

      {:error, _sync_run, %{code: code, message: message}} ->
        step(:failed, to_string(code), message)

      {:error, reason} ->
        step(:failed, "catalog_sync_failed", inspect(reason))
    end
  end

  defp record_quota_priming_result!(
         assignment,
         identity,
         reconciliation_status,
         trigger_kind,
         quota_step,
         operation_timestamp
       ) do
    summary = quota_priming_summary(identity, operation_timestamp)
    status = quota_priming_status(reconciliation_status, quota_step, summary)

    details =
      status
      |> quota_priming_details(trigger_kind, summary)
      |> maybe_put_failure_reason(quota_step)

    {:ok, assignment} =
      assignment
      |> PoolUpstreamAssignment.changeset(%{
        metadata: Map.put(assignment.metadata || %{}, "quota_priming", details)
      })
      |> Repo.update()

    assignment
  end

  defp quota_priming_summary(identity, timestamp) do
    persisted_windows = QuotaWindows.list_evidence(identity)
    effective_windows = QuotaWindows.effective_quota_windows(persisted_windows, timestamp)

    %{
      timestamp: timestamp,
      windows: persisted_windows,
      account_primary_usable_count:
        Enum.count(effective_windows, &account_primary_usable_window?(&1, timestamp)),
      usable_count: Enum.count(effective_windows, &QuotaWindows.usable_window?(&1, timestamp)),
      reset_bearing_count: Enum.count(persisted_windows, &Evidence.reset_bearing?/1),
      stale_count:
        Enum.count(
          persisted_windows,
          &(Evidence.reset_bearing?(&1) and
              not QuotaWindows.fresh_window?(&1, timestamp))
        ),
      expired_count:
        Enum.count(
          persisted_windows,
          &(Evidence.reset_bearing?(&1) and Evidence.expired?(&1, timestamp))
        )
    }
  end

  defp quota_priming_details(status, trigger_kind, summary) do
    %{
      "status" => status,
      "trigger_kind" => trigger_kind,
      "finished_at" => DateTime.to_iso8601(summary.timestamp),
      "window_count" => length(summary.windows),
      "account_primary_usable_window_count" => summary.account_primary_usable_count,
      "usable_window_count" => summary.usable_count,
      "reset_bearing_window_count" => summary.reset_bearing_count,
      "stale_window_count" => summary.stale_count,
      "expired_window_count" => summary.expired_count
    }
  end

  defp quota_priming_status(_status, %{status: :failed}, _summary),
    do: "failed"

  defp quota_priming_status(:failed, _quota_step, _summary),
    do: "failed"

  defp quota_priming_status(_status, _quota_step, %{account_primary_usable_count: count})
       when count > 0,
       do: "known"

  defp quota_priming_status(_status, _quota_step, %{expired_count: count})
       when count > 0,
       do: "expired"

  defp quota_priming_status(_status, _quota_step, %{stale_count: count})
       when count > 0,
       do: "stale"

  defp quota_priming_status(_status, _quota_step, %{reset_bearing_count: count} = summary)
       when count > 0 do
    if Enum.any?(summary.windows, &account_weekly_usable_window?(&1, summary.timestamp)) do
      "weekly_only_probe"
    else
      "unprimed"
    end
  end

  defp quota_priming_status(_status, _quota_step, %{windows: [_ | _]}),
    do: "resetless_unprimed"

  defp quota_priming_status(_status, _quota_step, %{windows: []}),
    do: "unprimed"

  defp account_primary_usable_window?(window, timestamp) do
    (WindowClassifier.primary_5h?(window) or WindowClassifier.monthly_primary?(window)) and
      QuotaWindows.usable_window?(window, timestamp)
  end

  defp account_weekly_usable_window?(window, timestamp) do
    quota_scope = window.quota_scope || "account"
    quota_family = window.quota_family || "account"

    window.quota_key == "account" and quota_scope == "account" and
      quota_family in ["account", "secondary"] and window.window_kind == "secondary" and
      window.window_minutes == 10_080 and
      QuotaWindows.usable_window?(window, timestamp)
  end

  defp maybe_put_failure_reason(details, %{status: :failed, code: code, message: message}) do
    Map.put(details, "reason", %{
      "code" => to_string(code),
      "message" => sanitized_message(message)
    })
  end

  defp maybe_put_failure_reason(details, _quota_step), do: details

  defp stale_quota_priming?(
         %{
           metadata: %{
             "quota_priming" => %{"status" => "refreshing", "started_at" => started_at}
           }
         },
         cutoff
       )
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, started_at, _offset} -> DateTime.compare(started_at, cutoff) != :gt
      _error -> false
    end
  end

  defp stale_quota_priming?(_assignment, _cutoff), do: false

  defp stale_priming_epoch_current?(assignment, identity) do
    priming_epoch = get_in(assignment.metadata || %{}, ["quota_priming", "credential_epoch"])
    current_epoch = CredentialFencing.credential_epoch(identity)

    priming_epoch == current_epoch or (is_nil(priming_epoch) and current_epoch == 1)
  end

  defp sanitized_reason(%{code: code, message: message}) when is_binary(message),
    do: %{"code" => to_string(code), "message" => sanitized_message(message)}

  defp sanitized_message(message) do
    message
    |> String.slice(0, 200)
    |> then(&Accounting.sanitize_metadata(%{"message" => &1}))
    |> Map.fetch!("message")
  end

  defp summarize_status(steps) do
    succeeded = Enum.count(steps, &(&1.status == :succeeded))
    failed = Enum.count(steps, &(&1.status == :failed))

    cond do
      failed == 0 -> :succeeded
      succeeded > 0 -> :partial
      true -> :failed
    end
  end

  defp failed_codes(result) do
    [result.health, result.quota, result.catalog]
    |> Enum.filter(&match?(%{status: :failed}, &1))
    |> Enum.map(&to_string(&1.code))
  end

  defp step(status, code, message),
    do: %{status: status, code: code, message: message, details: %{}}

  defp step_to_metadata(step) do
    %{
      "status" => Atom.to_string(step.status),
      "code" => step.code,
      "message" => step.message,
      "details" => step.details
    }
  end

  defp timestamp_iso(%DateTime{} = timestamp),
    do: timestamp |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp operation_clock!(opts) do
    case Keyword.get(opts, :operation_clock, &now/0) do
      clock when is_function(clock, 0) ->
        clock

      _invalid_clock ->
        raise ArgumentError, "operation_clock must be a zero-arity function"
    end
  end

  defp operation_timestamp!(operation_clock) do
    case operation_clock.() do
      %DateTime{} = timestamp ->
        DateTime.truncate(timestamp, :microsecond)

      _invalid_timestamp ->
        raise ArgumentError, "operation_clock must return a DateTime"
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
