defmodule CodexPooler.Accounting.RequestLifecycle.AbsentInstanceRecovery do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestReplayEntitlement}
  alias CodexPooler.Accounting.RequestLifecycle
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Platform.InstancePresence.Identity
  alias CodexPooler.Repo

  @open_request_statuses ~w(accepted in_progress)
  @open_attempt_statuses ~w(queued in_progress)
  @recovery_code "absent_instance_recovered"
  @recovery_source "absent_instance_recovery"
  @recovery_message "attempt recovered after its owning instance stopped reporting"

  @type summary :: %{required(:absent_instance_attempts_recovered) => non_neg_integer()}

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

  The pass settles through the ordinary interrupted path the drain uses,
  releasing the reservation and interrupting the turn, but with its own error
  code so triage can separate a recovered orphan from a drained stream. It
  records no upstream health: an instance disappearing says nothing about the
  provider. The six-hour stale-reservation sweep remains the backstop for
  attempts this pass cannot reach, including attempts with no recorded owner,
  attempts written before incarnations existed, and owners that never published
  presence at all.
  """
  @spec recover_absent_instance_attempts(DateTime.t(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def recover_absent_instance_attempts(now, opts \\ []) do
    cutoff = InstancePresence.absent_cutoff(now, opts)
    limit = Keyword.get(opts, :limit, 100)

    now
    |> absent_instance_attempts(cutoff, limit)
    |> Enum.reduce_while({:ok, initial_summary()}, &recover(&1, &2, now, opts))
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
  defp absent_instance_attempts(now, cutoff, limit) do
    cutoff
    |> open_attempts_of_absent_incarnations(limit)
    |> still_holding_their_reservation()
    |> Repo.all()
    |> Enum.reject(fn {request, _attempt} ->
      RuntimeCleanup.active_runtime_request?(request, now)
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
      order_by: [asc: attempt.started_at, asc: attempt.id],
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

  defp recover({request, attempt}, {:ok, summary}, now, opts) do
    case settle(request, attempt, now, opts) do
      {:ok, :recovered} -> {:cont, {:ok, increment(summary)}}
      {:ok, :noop} -> {:cont, {:ok, summary}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # The scan already proved the owner absent, but re-read presence immediately
  # before settling: an instance that started reporting again between the scan
  # and this row is serving, and its stream must keep its own outcome.
  defp settle(%Request{} = request, %Attempt{} = attempt, now, opts) do
    owner = Identity.owner(attempt.owner_instance_id, attempt.owner_instance_boot_id)

    if InstancePresence.absent?(owner, now, opts) do
      finalize(request, attempt, now)
    else
      {:ok, :noop}
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
