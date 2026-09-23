defmodule CodexPooler.Accounting.RequestReplayExpirySettlementTest do
  # A turn cut before any output leaves its request `in_progress` behind an
  # armed replay entitlement (the owner's arm already failed the attempt
  # `client_disconnected`); the isolated runtime runs no background jobs, so
  # nothing settled it there (findings#206 row 206-350). Production's minute
  # job and the owner's retirement for a superseding turn (row 206-348) both
  # close that entitlement; each settles the request exactly once and neither
  # settles it again after the other.
  use CodexPooler.DataCase, async: false

  import CodexPooler.RequestReplayFixtures

  alias CodexPooler.Accounting.{Attempt, LedgerReads, Request, RequestReplay, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Jobs.RequestReplayCleanupWorker

  test "the minute expiry job settles a killed turn behind an armed entitlement exactly once" do
    fixture = replay_fixture(reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    assert_held!(fixture)

    # Not due yet: the job leaves the entitlement for its resend.
    assert %{"replay_entitlements_selected" => 0} = run_cleanup_job!()
    assert_held!(fixture)

    set_replay_db_now!(DateTime.add(armed.expires_at, 1, :microsecond))
    assert %{"replay_entitlements_selected" => 1, "replay_entitlements_closed" => 1} = run_cleanup_job!()
    assert_settled_once!(fixture, "websocket_replay_expired", "expired")

    # Later runs and the owner's retirement arriving late find nothing to settle.
    assert %{"replay_entitlements_selected" => 0} = run_cleanup_job!()
    assert {:ok, :noop} = RequestReplay.supersede(armed)
    assert_settled_once!(fixture, "websocket_replay_expired", "expired")
  end

  test "a superseded entitlement settles once and the expiry job leaves it" do
    fixture = replay_fixture(reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    assert_held!(fixture)

    assert {:ok, :closed} = RequestReplay.supersede(armed)
    assert_settled_once!(fixture, "websocket_replay_superseded", "revoked")

    set_replay_db_now!(DateTime.add(armed.expires_at, 1, :microsecond))
    assert %{"replay_entitlements_selected" => 0} = run_cleanup_job!()
    assert {:ok, :noop} = RequestReplay.supersede(armed)
    assert_settled_once!(fixture, "websocket_replay_superseded", "revoked")
  end

  defp assert_held!(fixture) do
    assert %Request{status: "in_progress", usage_status: "usage_pending", completed_at: nil} = Repo.reload!(fixture.request)
    assert %CodexTurn{status: "in_progress"} = Repo.reload!(fixture.turn)

    assert %Attempt{status: "retryable_failed", network_error_code: "client_disconnected", usage_status: "usage_unknown"} =
             Repo.reload!(fixture.attempt)

    assert %RequestReplayEntitlement{status: "armed", closed_at: nil} = Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id)
    assert terminal_ledger_count(fixture.request.id, "reservation") == 1
    assert terminal_ledger_count(fixture.request.id, "settlement") == 0
    assert LedgerReads.outstanding_reservation_count(fixture.api_key.id) == 1
  end

  defp assert_settled_once!(fixture, error_code, entitlement_status) do
    request = Repo.reload!(fixture.request)
    assert {request.status, request.response_status_code, request.last_error_code, request.usage_status} == {"failed", 499, error_code, "usage_unknown"}
    assert %CodexTurn{status: "failed", error_code: ^error_code} = Repo.reload!(fixture.turn)
    assert %RequestReplayEntitlement{status: ^entitlement_status, closed_at: %DateTime{}} = Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id)
    assert request_attempt_count(fixture.request.id) == 1

    for {kind, count} <- [{"reservation", 1}, {"settlement", 1}, {"release", 1}],
        do: assert(terminal_ledger_count(fixture.request.id, kind) == count, "#{kind} entries")

    assert LedgerReads.outstanding_reservation_count(fixture.api_key.id) == 0
  end

  # The production worker, run explicitly on an inserted job, as Oban's cron
  # would every minute; its persisted summary is what the assertions read.
  defp run_cleanup_job! do
    job = Repo.insert!(RequestReplayCleanupWorker.new(%{}))
    assert :ok = RequestReplayCleanupWorker.perform(job)
    Repo.reload!(job).meta["replay_cleanup"]
  end
end
