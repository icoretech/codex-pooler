defmodule CodexPooler.Accounting.RequestLifecycle.AbsentInstanceRecovery do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestReplayEntitlement}
  alias CodexPooler.Accounting.RequestLifecycle
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup
  alias CodexPooler.Gateway.Runtime.Finalization.InterruptionOutcome
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Platform.InstancePresence.Identity
  alias CodexPooler.Repo

  @open_request_statuses ~w(accepted in_progress)
  @open_attempt_statuses ~w(queued in_progress)
  @recovery_code "absent_instance_recovered"
  @recovery_source "absent_instance_recovery"
  @recovery_message "attempt recovered after its owning instance stopped reporting"

  @type summary :: %{
          required(:absent_instance_attempts_recovered) => non_neg_integer(),
          optional(:after_commit_markers) => [map()]
        }
  @type failure :: {Ecto.UUID.t(), term()}

  @spec recovery_code() :: String.t()
  def recovery_code, do: @recovery_code

  @doc """
  Finalizes open attempts whose owning instance is no longer present.

  Recovery is by ownership, not by relay stage: an attempt still waiting for
  the upstream's first byte registers with no drain, so the shutdown drain
  cannot reach it by construction, and neither can a `SIGKILL`, a VM crash, or
  a drain that exhausted its budget. What every one of those has in common is
  that the owning instance stops publishing presence.

  Ownership is the node name *and* the VM incarnation that dispatched the
  attempt. The node name on its own derives from the pod IP, so a container
  that restarts in place comes back under it and refreshes the very row that
  would otherwise have proved its predecessor gone; the incarnation is what
  keeps the two VMs apart.

  Stale presence alone settles only attempts that predate execution identity.
  An attempt that records its executor is settled only with exact proof that
  the execution is gone: a reachable owner node reporting it dead, or a
  successor incarnation publishing presence under the same node name, which
  is what an in-place restart after `SIGKILL` or an OOM kill produces and
  needs no BEAM connectivity from the cleanup role. A pod that is replaced
  under a new name without publishing terminal proofs (see dead-execution
  recovery) remains unknown and waits for the six-hour sweep; a reachable
  owner reporting the execution alive vetoes settlement (findings#207,
  findings#214).

  The pass settles through the ordinary interrupted path the drain uses,
  releasing the reservation and interrupting the turn, but with its own error
  code so triage can separate a recovered orphan from a drained stream. It
  records no upstream health: an instance disappearing says nothing about the
  provider. The six-hour stale-reservation sweep remains the backstop for
  attempts this pass cannot reach, including attempts with no recorded owner,
  attempts written before incarnations existed, and owners that never published
  presence at all.

  Fairness across passes is durable, not node-local. Every candidate the pass
  examines is stamped with `owner_execution_checked_at` before it is settled,
  and the batch is ordered by that stamp falling back to `started_at`, exactly
  like dead-execution recovery. A candidate whose settlement keeps failing is
  therefore examined once per pass and then sorts behind every candidate no
  pass has reached yet, so a persistently failing oldest row cannot occupy the
  head of every batch while healthy later rows stay stranded (findings#207).
  Failures stay visible: the pass keeps settling the rest of its batch and
  returns the collected candidate failures with the summary of what it did
  settle, which the cleanup job reports as a failed step with its evidence.
  """
  @spec recover_absent_instance_attempts(DateTime.t(), keyword()) ::
          {:ok, summary()}
          | {:error, {:absent_instance_candidates_failed, [failure()]}, summary()}
  def recover_absent_instance_attempts(now, opts \\ []) do
    presence_now = InstancePresence.database_now()
    cutoff = InstancePresence.absent_cutoff(presence_now, opts)
    limit = Keyword.get(opts, :limit, 100)
    caller_owned_transaction? = Repo.in_transaction?()

    if InstancePresence.observer_fresh?(presence_now, opts) do
      {summary, failures, markers} =
        now
        |> absent_instance_attempts(cutoff, limit, opts)
        |> Enum.reduce(
          {initial_summary(), [], []},
          &recover(&1, &2, now, opts, caller_owned_transaction?)
        )

      summary = put_after_commit_markers(summary, markers)

      if failures == [],
        do: {:ok, summary},
        else: {:error, {:absent_instance_candidates_failed, Enum.reverse(failures)}, summary}
    else
      {:ok, initial_summary()}
    end
  end

  # An attempt qualifies only when its request still holds a recorded
  # reservation with no release, no replay entitlement owns the lifecycle, the
  # attempt itself is older than the liveness window, and the owning incarnation
  # has a presence row that stopped being refreshed. A live runtime turn with a
  # current owner lease is excluded as well, so a session that moved to another
  # replica keeps its work.
  #
  # The join is on the incarnation, not the node name: an attempt with no
  # recorded boot id — every attempt written before incarnations existed — names
  # no incarnation, matches no presence row, and stays with the six-hour sweep.
  # The liveness guard is handed this pass's window and the candidate attempt,
  # and it judges a lease by the VM holding it: a lease held by an incarnation
  # already proved absent is not live work and cannot shelter the attempt
  # behind it. A successor that restarted under its predecessor's node name
  # used to renew exactly such a lease, and this rejection then skipped the
  # orphan. The candidate goes with the question because the session can
  # outlive the incarnation that dispatched this attempt: a released client
  # whose owner was killed falls back to another transport, and the live peer
  # that serves it takes the session over on the same row. Asked about the
  # session, the guard then answered for a VM that never executed this
  # attempt, and the orphan was skipped for as long as the client kept any
  # live turn on that session (findings#253).
  defp absent_instance_attempts(now, cutoff, limit, opts) do
    cutoff
    |> open_attempts_of_absent_incarnations(limit)
    |> still_holding_their_reservation()
    |> Repo.all()
    |> Enum.reject(fn {request, attempt} ->
      RuntimeCleanup.active_runtime_request?(request, attempt, now, opts)
    end)
  end

  # The ownership half: an open attempt older than the liveness window whose
  # incarnation has a presence row that stopped being refreshed.
  defp open_attempts_of_absent_incarnations(cutoff, limit) do
    from attempt in Attempt,
      join: request in Request,
      on: request.id == attempt.request_id,
      join: presence in InstancePresence.Instance,
      on:
        presence.node_name == attempt.owner_instance_id and
          presence.boot_id == attempt.owner_instance_boot_id,
      where:
        request.status in ^@open_request_statuses and
          attempt.status in ^@open_attempt_statuses and
          not is_nil(attempt.owner_instance_boot_id) and attempt.started_at <= ^cutoff and
          presence.last_seen_at <= ^cutoff,
      # Progress order: rows no pass has examined keep their dispatch time, so
      # a row stamped by an earlier pass sorts after them.
      order_by: [
        asc: fragment("COALESCE(?, ?)", attempt.owner_execution_checked_at, attempt.started_at),
        asc: attempt.id
      ],
      limit: ^limit,
      select: {request, attempt}
  end

  # The settlement half: the reservation is still recorded, nothing released
  # it, and no replay entitlement owns the lifecycle.
  defp still_holding_their_reservation(query) do
    from [_attempt, request] in query,
      join: reservation in LedgerEntry,
      on:
        reservation.request_id == request.id and reservation.entry_kind == "reservation" and
          reservation.amount_status == "recorded",
      left_join: release in LedgerEntry,
      on: release.request_id == request.id and release.entry_kind == "release",
      left_join: replay in RequestReplayEntitlement,
      on: replay.request_id == request.id,
      where: is_nil(release.id) and is_nil(replay.id)
  end

  defp recover(
         {request, attempt},
         {summary, failures, markers},
         now,
         opts,
         caller_owned_transaction?
       ) do
    stamp_examined!(attempt, now)

    case settle(request, attempt, now, opts) do
      {:ok, :recovered} ->
        marker = recovery_outcome_marker(request, attempt)

        if caller_owned_transaction? do
          {increment(summary), failures, [marker | markers]}
        else
          emit_recovery_outcome(marker)
          {increment(summary), failures, markers}
        end

      {:ok, :noop} ->
        {summary, failures, markers}

      {:error, reason} ->
        {summary, [{attempt.id, reason} | failures], markers}
    end
  rescue
    # A settlement that raises is a candidate failure like a returned error: it
    # is reported with the attempt it belongs to and the pass moves on. Nothing
    # is swallowed; the cleanup job logs the collected failures as a failed step.
    exception -> {summary, [{attempt.id, bounded_failure(exception)} | failures], markers}
  catch
    :exit, _reason ->
      {summary, [{attempt.id, :absent_instance_recovery_unavailable} | failures], markers}
  end

  # A PostgreSQL error keeps its fixed-vocabulary SQLSTATE class beside the
  # module (deadlock, lock timeout and constraint failures are different
  # operator actions); every other exception is reported by module only.
  defp bounded_failure(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code),
    do: {Postgrex.Error, code}

  defp bounded_failure(exception), do: exception.__struct__

  defp put_after_commit_markers(summary, []), do: summary

  defp put_after_commit_markers(summary, markers),
    do: Map.put(summary, :after_commit_markers, Enum.reverse(markers))

  defp recovery_outcome_marker(request, attempt) do
    %{
      kind: :stream_outcome,
      outcome: "interrupted",
      downstream_transport: bounded_transport(request.transport),
      upstream_transport: bounded_transport(attempt.transport)
    }
  end

  defp emit_recovery_outcome(marker) do
    InterruptionOutcome.emit(
      marker.downstream_transport,
      marker.upstream_transport
    )
  end

  defp bounded_transport(transport) when transport in ["http_sse", "websocket"], do: transport
  defp bounded_transport(_transport), do: "unknown"

  # Durable scheduling progress shared with dead-execution recovery. The row is
  # stamped before settlement, so a failing settlement still moves it behind
  # the rows no pass has reached yet. Only an open row is stamped: a row settled
  # between the scan and this point keeps its terminal state untouched.
  defp stamp_examined!(%Attempt{id: id}, now) do
    _stamped =
      Repo.update_all(
        from(a in Attempt, where: a.id == ^id and a.status in ^@open_attempt_statuses),
        set: [owner_execution_checked_at: now]
      )

    :ok
  end

  # The scan already proved the owner absent, but re-read presence immediately
  # before settling: an instance that started reporting again between the scan
  # and this row is serving, and its stream must keep its own outcome.
  defp settle(%Request{} = request, %Attempt{} = attempt, now, opts) do
    owner = Identity.owner(attempt.owner_instance_id, attempt.owner_instance_boot_id)

    presence_now = InstancePresence.database_now()

    cond do
      not InstancePresence.observer_fresh?(presence_now, opts) ->
        {:ok, :noop}

      not InstancePresence.absent?(owner, presence_now, opts) ->
        {:ok, :noop}

      not is_nil(attempt.owner_execution_id) or not is_nil(attempt.owner_process_id) ->
        RequestLifecycle.recover_absent_execution(request, attempt, now, opts)

      true ->
        finalize(request, attempt, now)
    end
  end

  defp finalize(%Request{} = request, %Attempt{} = attempt, now) do
    with {:ok, _result} <-
           RequestLifecycle.finalize_request(request, attempt, %{
             request_status: "failed",
             attempt_status: "failed",
             response_status_code: 499,
             last_error_code: @recovery_code,
             error_message: @recovery_message,
             usage: %{status: "usage_unknown", source: @recovery_source},
             now: now
           }) do
      RuntimeCleanup.recover_stale_request_turn(request.id, attempt.id,
        now: now,
        error_code: @recovery_code
      )

      {:ok, :recovered}
    end
  end

  defp initial_summary, do: %{absent_instance_attempts_recovered: 0}

  defp increment(summary),
    do: Map.update!(summary, :absent_instance_attempts_recovered, &(&1 + 1))
end
