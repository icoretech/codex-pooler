defmodule CodexPooler.Upstreams.Reconciliation.AccountReconciliation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPooler.Events
  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @stale_after_seconds 25 * 60
  @successful_partial_codes ~w(catalog_sync_failed catalog_sync_in_progress)
  @paused UpstreamIdentity.paused_status()
  @reauth_required UpstreamIdentity.reauth_required_status()
  @assignment_paused PoolUpstreamAssignment.paused_status()
  @assignment_reauth_required PoolUpstreamAssignment.reauth_required_status()

  @type orchestration_result :: {:ok, map()} | {:error, term()}

  @spec run(term(), term(), term()) :: orchestration_result()
  def run(pool_id, assignment_id, trigger_kind) do
    if reason = skipped_reconciliation_target(pool_id, assignment_id) do
      result = %{
        status: :skipped,
        trigger_kind: trigger_kind,
        reason: reason
      }

      broadcast_job_result(pool_id, "account_reconciliation", {:ok, result})
      {:ok, result}
    else
      run_reconciliation(pool_id, assignment_id, trigger_kind)
    end
  end

  defp run_reconciliation(pool_id, assignment_id, trigger_kind) do
    mark_refreshing(pool_id, assignment_id, trigger_kind)

    case PoolReconciliation.reconcile_pool_account(pool_id, assignment_id) do
      {:ok, result} ->
        catalog_step = reconcile_catalog(pool_id)
        status = summarize_status([result.health, result.quota, catalog_step])

        assignment =
          record_quota_priming_result!(
            result.assignment,
            result.identity,
            status,
            trigger_kind,
            result.quota
          )

        result =
          %{
            status: status,
            trigger_kind: trigger_kind,
            assignment: assignment,
            identity: result.identity,
            health: result.health,
            quota: result.quota,
            catalog: catalog_step
          }

        result = record_result!(result)
        broadcast_job_result(pool_id, "account_reconciliation", {:ok, result})
        {:ok, result}

      {:error, reason} ->
        mark_failed(pool_id, assignment_id, trigger_kind, reason)
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
        priming = assignment.metadata["quota_priming"] || %{}

        {:ok, _assignment} =
          Quota.PrimingState.record(assignment.pool_id, assignment, %{
            "status" => "failed",
            "trigger_kind" => Map.get(priming, "trigger_kind", "unknown"),
            "started_at" => Map.get(priming, "started_at"),
            "finished_at" => timestamp_iso(now),
            "reason" => %{
              "code" => "runtime_timeout",
              "message" => "account reconciliation timed out before completion"
            }
          })

        count + 1
      end)

    {:ok, %{stale_account_reconciliations_failed: failed_count}}
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

  defp record_result!(result) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assignment = result.assignment
    metadata = assignment.metadata || %{}

    summary = %{
      "status" => Atom.to_string(result.status),
      "finished_at" => DateTime.to_iso8601(timestamp),
      "steps" => Enum.map([result.health, result.quota, result.catalog], &step_to_metadata/1)
    }

    {:ok, assignment} =
      PoolAssignments.update_pool_assignment(assignment, %{
        metadata: Map.put(metadata, "last_reconciliation", summary),
        last_successful_refresh_at:
          if(result.status == :succeeded,
            do: timestamp,
            else: assignment.last_successful_refresh_at
          )
      })

    %{result | assignment: assignment}
  end

  defp mark_refreshing(pool_id, assignment_id, trigger_kind) do
    Quota.PrimingState.record(pool_id, assignment_id, %{
      "status" => "refreshing",
      "trigger_kind" => trigger_kind,
      "started_at" => timestamp_iso()
    })
  end

  defp mark_failed(pool_id, assignment_id, trigger_kind, reason) do
    Quota.PrimingState.record(pool_id, assignment_id, %{
      "status" => "failed",
      "trigger_kind" => trigger_kind,
      "finished_at" => timestamp_iso(),
      "reason" => sanitized_reason(reason)
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

      _other ->
        nil
    end
  end

  defp skipped_reconciliation_target(_pool_id, _assignment_id), do: nil

  defp skipped_reconciliation_reason(code, message), do: %{code: code, message: message}

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

  defp reconcile_catalog(pool_id) do
    case Catalog.sync_pool_catalog(pool_id, trigger_kind: "reconcile") do
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
         quota_step
       ) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    summary = quota_priming_summary(identity, timestamp)
    status = quota_priming_status(reconciliation_status, quota_step, summary)

    details =
      status
      |> quota_priming_details(trigger_kind, summary)
      |> maybe_put_failure_reason(quota_step)

    {:ok, assignment} = Quota.PrimingState.record(assignment.pool_id, assignment, details)

    assignment
  end

  defp quota_priming_summary(identity, timestamp) do
    windows = QuotaWindows.list_quota_windows(identity)

    %{
      timestamp: timestamp,
      windows: windows,
      account_primary_usable_count:
        Enum.count(windows, &account_primary_usable_window?(&1, timestamp)),
      usable_count: Enum.count(windows, &QuotaWindows.usable_window?(&1, timestamp)),
      reset_bearing_count: Enum.count(windows, &Evidence.reset_bearing?/1),
      stale_count:
        Enum.count(
          windows,
          &(Evidence.reset_bearing?(&1) and
              not QuotaWindows.fresh_window?(&1, timestamp))
        ),
      expired_count:
        Enum.count(windows, &(Evidence.reset_bearing?(&1) and Evidence.expired?(&1, timestamp)))
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
         %{metadata: %{"quota_priming" => %{"started_at" => started_at}}},
         cutoff
       )
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, started_at, _offset} -> DateTime.compare(started_at, cutoff) != :gt
      _error -> false
    end
  end

  defp stale_quota_priming?(_assignment, _cutoff), do: false

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

  defp timestamp_iso,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp timestamp_iso(%DateTime{} = timestamp),
    do: timestamp |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
end
