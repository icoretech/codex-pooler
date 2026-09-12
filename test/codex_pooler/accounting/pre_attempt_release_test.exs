defmodule CodexPooler.Accounting.PreAttemptReleaseTest do
  @moduledoc """
  A reservation released with no attempt row must say so durably.

  Before the `pre_attempt_phase` detail, the six-hour backstop and the
  dispatched-attempt branch of the same sweeper wrote the identical
  `stale_reservation_recovered` code, and the release entry's `request_status`
  was always the terminal status that same write had just set. A recurring
  pre-attempt abandonment was therefore only visible by joining `attempts`
  against a backstop row six hours after the fact.
  """

  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, PreAttemptRelease, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession,
    CodexTurn,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo

  describe "six-hour sweep of an undispatched http_sse reservation" do
    test "releases exactly once, sends nothing upstream, and classifies the phase" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "max_output_tokens" => 10,
                   "stream" => true
                 },
                 %{correlation_id: "pre-attempt-sweep", now: stale_admitted_at}
               )

      assert reserved.request.transport == "http_sse"
      assert attempt_count(reserved.request) == 0

      events = attach_pre_attempt_release_telemetry!()

      assert {:ok, %{stale_reservations_released: 1, stale_reservations_settled: 0}} =
               Accounting.recover_stale_reservations(now)

      assert %Request{status: "failed", last_error_code: "stale_reservation_recovered"} =
               Repo.reload!(reserved.request)

      assert attempt_count(reserved.request) == 0
      assert [%LedgerEntry{} = release] = release_entries(reserved.request)
      assert release.attempt_id == nil
      assert release.details["release_reason"] == "stale_reservation_recovered"
      assert release.details[PreAttemptRelease.detail_key()] == PreAttemptRelease.stale_sweep()

      assert_receive {^events, %{count: 1},
                      %{phase: "stale_sweep", transport: "http_sse", release_reason: reason}}

      assert reason == "stale_reservation_recovered"

      # The backstop stays idempotent: a second pass writes no second release.
      assert {:ok, %{stale_reservations_released: 0, stale_reservations_settled: 0}} =
               Accounting.recover_stale_reservations(now)

      assert length(release_entries(reserved.request)) == 1
    end

    test "leaves a reservation whose turn is held by a live owner alone" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "max_output_tokens" => 10,
                   "stream" => true
                 },
                 %{correlation_id: "pre-attempt-live-owner", now: stale_admitted_at}
               )

      session = live_owner_session!(setup, stale_admitted_at, now)
      _lease = live_owner_lease!(setup, session, now)
      turn = in_progress_turn!(session, reserved.request, stale_admitted_at)

      assert {:ok,
              %{
                stale_reservations_released: 0,
                stale_reservations_settled: 0,
                stale_terminal_attempts_recovered: 0
              }} = Accounting.recover_stale_reservations(now)

      assert %Request{status: "in_progress", completed_at: nil, last_error_code: nil} =
               Repo.reload!(reserved.request)

      assert release_entries(reserved.request) == []
      assert Repo.reload!(turn).status == CodexTurn.in_progress_status()
    end
  end

  describe "pre_attempt_phase vocabulary" do
    test "an undeclared phase is recorded as unrecorded rather than left absent" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "max_output_tokens" => 10,
                   "stream" => true
                 },
                 %{correlation_id: "pre-attempt-undeclared"}
               )

      assert {:ok, _released} =
               Accounting.finalize_reservation_failure(reserved.request, %{
                 response_status_code: 499,
                 last_error_code: "client_disconnected",
                 usage_status: "usage_unknown"
               })

      assert [%LedgerEntry{} = release] = release_entries(reserved.request)

      assert release.details[PreAttemptRelease.detail_key()] == PreAttemptRelease.unrecorded()
      assert release.details["release_reason"] == "client_disconnected"
    end

    test "a settlement-time release carries no phase key at all" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "max_output_tokens" => 10,
                   "stream" => true
                 },
                 %{correlation_id: "pre-attempt-settled"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, _finalized} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 response_status_code: 500,
                 last_error_code: "upstream_error",
                 usage: %{status: "usage_unknown", source: "test"}
               })

      release = release_entries(reserved.request)

      Enum.each(release, fn entry ->
        refute Map.has_key?(entry.details, PreAttemptRelease.detail_key())
      end)
    end

    test "an out-of-vocabulary phase is bounded, never stored raw" do
      assert PreAttemptRelease.phase("../../etc/passwd") == PreAttemptRelease.unrecorded()
      assert PreAttemptRelease.phase(nil) == PreAttemptRelease.unrecorded()
      assert PreAttemptRelease.phase(:routing_rejected) == PreAttemptRelease.routing_rejected()
      assert PreAttemptRelease.phase("stale_sweep") == PreAttemptRelease.stale_sweep()

      assert Enum.sort(PreAttemptRelease.phases()) ==
               Enum.sort([
                 "routing_rejected",
                 "stale_sweep",
                 "task_exception",
                 "turn_interrupted",
                 "unrecorded"
               ])
    end
  end

  describe "an interrupted turn that never reached dispatch" do
    # The interruption path is the bulk of pre-attempt releases (client
    # disconnect, owner drain, expired-owner sweep), and it declared nothing
    # until icoretech/codex-pooler-findings#187. Driven through the same
    # public entry point the socket calls, not through a constructed release.
    test "records the turn-interrupted boundary, not unrecorded" do
      setup = accounting_setup()
      claim = "pre-attempt-interrupt-#{System.unique_integer([:positive])}"

      {:ok, session} =
        Gateway.start_codex_session(setup.auth, %{
          accepted_turn_state: "pre-attempt-interrupt-#{System.unique_integer([:positive])}"
        })

      assert {:ok, %{request: claimed}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: "/backend-api/codex/responses",
                 correlation_id: claim
               })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => []},
                 %{
                   endpoint: "/backend-api/codex/responses",
                   transport: "websocket",
                   correlation_id: claim,
                   turn_claim: claimed
                 }
               )

      options = RequestOptions.for_websocket(%{request_id: claim, reason: "client_disconnected"})
      assert {:ok, turn} = SessionContinuity.start_codex_turn(session, reserved.request, options)

      events = attach_pre_attempt_release_telemetry!()

      assert {:ok, %{interrupted_turn_count: 1}} =
               Interruption.interrupt_codex_turn(session, options)

      assert attempt_count(reserved.request) == 0
      assert [%LedgerEntry{attempt_id: nil} = release] = release_entries(reserved.request)
      assert release.details["release_reason"] == "client_disconnected"

      assert release.details[PreAttemptRelease.detail_key()] ==
               PreAttemptRelease.turn_interrupted()

      assert_receive {^events, %{count: 1},
                      %{
                        phase: "turn_interrupted",
                        transport: "websocket",
                        release_reason: "client_disconnected"
                      }}

      assert Repo.reload!(turn).status == "interrupted"
    end
  end

  defp attempt_count(%Request{id: request_id}) do
    Repo.aggregate(from(attempt in Attempt, where: attempt.request_id == ^request_id), :count)
  end

  defp release_entries(%Request{id: request_id}) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.request_id == ^request_id and entry.entry_kind == "release",
        order_by: [asc: entry.created_at]
    )
  end

  defp attach_pre_attempt_release_telemetry! do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      PreAttemptRelease.telemetry_event(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  defp live_owner_session!(setup, created_at, now) do
    %CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "pre-attempt-owner-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      owner_instance_id: "pre-attempt-release-test",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 5, :minute),
      last_heartbeat_at: now,
      created_at: created_at,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp live_owner_lease!(setup, session, now) do
    %BridgeOwnerLease{
      codex_session_id: session.id,
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      pool_upstream_assignment_id: setup.assignment.id,
      owner_instance_id: "pre-attempt-release-test",
      lease_token: session.owner_lease_token,
      status: BridgeOwnerLease.active_status(),
      acquired_at: now,
      renewed_at: now,
      expires_at: DateTime.add(now, 5, :minute),
      metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp in_progress_turn!(session, request, started_at) do
    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: System.unique_integer([:positive]),
      transport_kind: "http_sse",
      status: CodexTurn.in_progress_status(),
      started_at: started_at,
      created_at: started_at,
      updated_at: started_at
    }
    |> Repo.insert!()
  end
end
