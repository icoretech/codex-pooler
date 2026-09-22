defmodule CodexPooler.Jobs.RuntimeStateCleanup do
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup
  alias CodexPooler.Platform.ExecutionTerminalProofs
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation

  @type orchestration_result :: {:ok, map()} | {:error, term()}

  # Each step is independent work on a different kind of runtime state, so one
  # failing must not cancel the rest. They used to run in a single `with` chain,
  # which made every later step conditional on every earlier one: a fault in
  # file expiry or reservation recovery silently skipped ownership recovery and
  # presence pruning, and nothing distinguished "recovery ran and found nothing"
  # from "recovery never ran". Ownership recovery in particular exists for the
  # case where something has already gone wrong on a replica, so it is the worst
  # possible thing to make contingent on unrelated cleanup succeeding.
  #
  # Every step still runs, the summaries of those that succeeded are merged, and
  # a pass with any failure reports one so the job is retried as before.
  @spec run(DateTime.t()) :: orchestration_result()
  def run(now \\ DateTime.utc_now()) do
    steps(now)
    |> Enum.map(fn {name, step} -> {name, run_step(name, step)} end)
    |> summarize()
  end

  defp steps(now) do
    [
      {:files, fn -> Files.cleanup_expired(now) end},
      {:stale_reservations, fn -> Accounting.recover_stale_reservations(now) end},
      # Ownership recovery runs on the liveness window, not the six-hour stale
      # window, so an attempt orphaned by a kill, a crash, or a drain that could
      # not reach it stops holding its reservation in minutes. It must precede
      # gateway runtime cleanup: expired-owner interruption opens a reconnect
      # window, and running it first can shelter the same orphan from this pass.
      {:absent_instances, fn -> Accounting.recover_absent_instance_attempts(now) end},
      {:gateway_runtime, fn -> RuntimeCleanup.cleanup_expired_runtime_state(now) end},
      {:dead_executions, fn -> Accounting.recover_dead_execution_attempts(now) end},
      {:execution_proofs, fn -> ExecutionTerminalProofs.prune(now) end},
      {:instance_presence, fn -> InstancePresence.prune(now) end},
      {:catalog_sync_runs, fn -> Catalog.cleanup_stale_sync_runs(now) end},
      {:account_reconciliation, fn -> AccountReconciliation.cleanup_stale_state(now) end},
      {:expired_quota_windows, fn -> QuotaWindows.prune_expired_windows(now) end}
    ]
  end

  # A raising step is contained the same way a returned error is: the pass keeps
  # going and reports a failure at the end.
  defp run_step(name, step) do
    step.()
  rescue
    exception -> {:error, {:raised, name, Exception.message(exception)}}
  end

  defp summarize(results) do
    summary =
      Enum.reduce(results, %{}, fn
        {_name, {:ok, step_summary}}, acc when is_map(step_summary) ->
          Map.merge(acc, step_summary)

        {_name, {:error, _reason, step_summary}}, acc when is_map(step_summary) ->
          Map.merge(acc, step_summary)

        {_name, _result}, acc ->
          acc
      end)

    case Enum.filter(results, &failed_step?/1) do
      [] ->
        {:ok, summary}

      failures ->
        Enum.each(failures, &log_failed_step/1)
        # The work the surviving steps did is reported even though the pass
        # failed, so a failed run still says what ran rather than only what did
        # not: the whole point of not short-circuiting is lost if the evidence
        # is discarded with the error.
        Logger.warning(
          "runtime state cleanup completed with failures " <>
            "#{inspect(Enum.map(failures, &elem(&1, 0)))}, summary #{inspect(summary)}"
        )

        {:error, {:runtime_state_cleanup_steps_failed, Enum.map(failures, &elem(&1, 0)), summary}}
    end
  end

  defp failed_step?({_name, {:ok, _summary}}), do: false
  defp failed_step?({_name, _result}), do: true

  # The step name and its reason go in the message rather than in Logger
  # metadata: the configured metadata allowlist is deliberately small, and two
  # bookkeeping log lines are not a reason to widen it.
  defp log_failed_step({name, result}) do
    Logger.warning("runtime state cleanup step #{name} failed: #{inspect(bounded_failure(result))}")
  end

  # Failure payloads are bounded before they reach the log: a step returns
  # atoms, ids and module names, but an accounting error can carry an
  # `Ecto.Changeset`, whose changes must never be logged. Structs are reduced
  # to their module name; everything else is already bounded.
  defp bounded_failure(%{__struct__: module}), do: module
  defp bounded_failure(list) when is_list(list), do: Enum.map(list, &bounded_failure/1)

  defp bounded_failure(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&bounded_failure/1) |> List.to_tuple()

  defp bounded_failure(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, bounded_failure(v)} end)

  defp bounded_failure(other), do: other
end
