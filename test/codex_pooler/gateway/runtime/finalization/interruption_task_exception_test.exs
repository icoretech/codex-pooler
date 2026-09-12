defmodule CodexPooler.Gateway.Runtime.Finalization.InterruptionTaskExceptionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, PreAttemptRelease, Request}
  alias CodexPooler.Gateway.Payloads.{RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.{RoutingCircuitState, SessionContinuity}
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket, as: Gateway

  @reason "owner_task_exception"

  test "a task exception fails its own request, attempt, and turn without touching health or the session" do
    fixture = fixture()
    session_before = Repo.reload!(fixture.session)

    assert :ok = Interruption.finalize_task_exception_request(fixture.receipt, @reason)

    assert %Request{
             status: "failed",
             usage_status: "usage_unknown",
             response_status_code: 500,
             last_error_code: @reason,
             completed_at: %DateTime{}
           } = Repo.get!(Request, fixture.request.id)

    assert %Attempt{
             status: "failed",
             network_error_code: @reason,
             usage_status: "usage_unknown",
             completed_at: %DateTime{}
           } = Repo.get!(Attempt, fixture.attempt.id)

    assert %CodexTurn{
             status: "failed",
             error_code: @reason,
             final_attempt_id: final_attempt_id,
             completed_at: %DateTime{}
           } = Repo.get!(CodexTurn, fixture.turn.id)

    assert final_attempt_id == fixture.attempt.id

    assert Enum.sort(
             Repo.all(
               from e in LedgerEntry,
                 where: e.request_id == ^fixture.request.id,
                 select: e.entry_kind
             )
           ) == ["release", "reservation", "settlement"]

    # Health neutral and lease neutral: no circuit, no demotion, and the
    # session row (status, lease token, expiry) is exactly as before.
    assert Repo.all(BridgeDemotion) == []
    assert Repo.all(RoutingCircuitState) == []
    session_after = Repo.reload!(fixture.session)

    assert Map.take(session_after, [:status, :owner_lease_token, :owner_lease_expires_at]) ==
             Map.take(session_before, [:status, :owner_lease_token, :owner_lease_expires_at])

    # Idempotent: a second finalization changes nothing.
    request_after = Repo.get!(Request, fixture.request.id)
    assert :ok = Interruption.finalize_task_exception_request(fixture.receipt, @reason)
    assert Repo.get!(Request, fixture.request.id) == request_after

    assert Repo.aggregate(
             from(e in LedgerEntry, where: e.request_id == ^fixture.request.id),
             :count
           ) ==
             3
  end

  test "a receipt that does not match the request is a no-op" do
    fixture = fixture()

    for receipt <- [
          %{fixture.receipt | api_key_id: Ecto.UUID.generate()},
          %{fixture.receipt | correlation_id: Ecto.UUID.generate()},
          %{fixture.receipt | request_id: Ecto.UUID.generate()}
        ] do
      assert :ok = Interruption.finalize_task_exception_request(receipt, @reason)
    end

    assert Repo.get!(Request, fixture.request.id).status == "in_progress"
    assert Repo.get!(Attempt, fixture.attempt.id).status == "in_progress"
    assert Repo.get!(CodexTurn, fixture.turn.id).status == "in_progress"
  end

  test "a request without an attempt yet fails through the reservation path" do
    fixture = fixture()
    Repo.delete!(fixture.attempt)

    assert :ok = Interruption.finalize_task_exception_request(fixture.receipt, @reason)

    assert %Request{status: "failed", last_error_code: @reason, usage_status: "usage_unknown"} =
             Repo.get!(Request, fixture.request.id)

    assert %CodexTurn{status: "failed", error_code: @reason, final_attempt_id: nil} =
             Repo.get!(CodexTurn, fixture.turn.id)

    # Its own boundary, not the interruption one: nothing outside the turn
    # went away, the process carrying it toward dispatch died inside the
    # pre-attempt window (icoretech/codex-pooler-findings#187).
    assert [%LedgerEntry{entry_kind: "release", attempt_id: nil} = release] =
             Repo.all(
               from e in LedgerEntry,
                 where: e.request_id == ^fixture.request.id and e.entry_kind == "release"
             )

    assert release.details["release_reason"] == @reason

    assert release.details[PreAttemptRelease.detail_key()] == PreAttemptRelease.task_exception()
  end

  test "the byte-identical resend is admitted as one successor after a task exception" do
    fixture = fixture()
    assert :ok = Interruption.finalize_task_exception_request(fixture.receipt, @reason)

    assert {:ok, %ClientRetry.SuccessorClaim{request: successor}} = claim(fixture)
    assert successor.id != fixture.request.id
    assert ClientRetry.reserved_successor_claim?(successor.correlation_id)

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^fixture.session.id),
             :count
           ) == 2

    # The successor is the one retry; the predecessor cannot be claimed twice.
    assert {:error, _reason} = claim(fixture)
  end

  test "only the exact task-exception shape admits a successor" do
    fixture = fixture()
    assert :ok = Interruption.finalize_task_exception_request(fixture.receipt, @reason)

    for mutate <- [
          fn -> update!(Request, fixture.request.id, response_status_code: 499) end,
          fn -> update!(Request, fixture.request.id, last_error_code: "client_disconnected") end,
          fn -> update!(CodexTurn, fixture.turn.id, error_code: "client_disconnected") end,
          fn -> update!(CodexTurn, fixture.turn.id, final_attempt_id: nil) end,
          fn -> update!(Attempt, fixture.attempt.id, status: "in_progress") end,
          fn -> update!(Attempt, fixture.attempt.id, replay_generation: 1) end
        ] do
      snapshot = snapshot(fixture)
      mutate.()
      assert {:error, _reason} = claim(fixture)
      restore!(snapshot)
    end

    assert {:ok, %ClientRetry.SuccessorClaim{}} = claim(fixture)
  end

  defp fixture do
    setup = accounting_setup()

    {:ok, session} =
      Gateway.start_codex_session(setup.auth, %{
        accepted_turn_state: "task-exception-#{System.unique_integer([:positive])}"
      })

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [],
      "client_metadata" => %{"turn_id" => "task-exception-turn"}
    }

    {:ok, identity} = WebsocketTurnIdentity.resolve(payload, session.id)
    claim = identity.turn_claim_key
    replay_claim_digest = :crypto.strong_rand_bytes(32)

    witness =
      ClientRetry.original_witness!(replay_claim_digest, setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: claimed}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: claim,
        native_client_retry_witness: witness
      })

    {:ok, reserved} =
      Accounting.reserve(setup.auth, setup.model, payload, %{
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        correlation_id: claim,
        turn_claim: claimed
      })

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    options =
      RequestOptions.for_websocket(%{request_id: claim})
      |> RequestOptions.put_continuity(semantic_turn_key: identity.semantic_turn_key)

    {:ok, turn} = SessionContinuity.start_codex_turn(session, reserved.request, options)
    :ok = SessionContinuity.mark_codex_turn_visible(reserved.request)

    receipt = %{
      session_id: session.id,
      request_id: reserved.request.id,
      correlation_id: claim,
      api_key_id: setup.api_key.id,
      owner_binding: nil,
      attempt_id: attempt.id,
      replay_generation: attempt.replay_generation
    }

    session = Repo.get!(CodexSession, session.id)

    %{
      setup: setup,
      session: session,
      request: reserved.request,
      attempt: attempt,
      turn: turn,
      payload: payload,
      receipt: receipt,
      # The successor claim carries the owner-idle validation the gateway
      # performs against the live owner before claiming.
      opts: %{
        endpoint: "/backend-api/codex/responses",
        requested_model: setup.model.exposed_model_id,
        runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
        codex_session: session,
        semantic_turn_digest: identity.semantic_turn_key,
        original_request_claim: claim,
        replay_claim_digest: replay_claim_digest,
        owner_idle_validated?: true,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id
      }
    }
  end

  defp claim(fixture) do
    Accounting.claim_client_retry_successor(
      fixture.setup.auth,
      fixture.setup.model,
      fixture.payload,
      fixture.opts
    )
  end

  defp update!(schema, id, attrs),
    do: schema |> Repo.get!(id) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp snapshot(fixture) do
    %{
      request: Repo.get!(Request, fixture.request.id),
      attempt: Repo.get!(Attempt, fixture.attempt.id),
      turn: Repo.get!(CodexTurn, fixture.turn.id)
    }
  end

  defp restore!(snapshot) do
    for %schema{id: id} = row <- [snapshot.request, snapshot.attempt, snapshot.turn] do
      fields = schema.__schema__(:fields) -- [:id]

      schema
      |> Repo.get!(id)
      |> Ecto.Changeset.change(Map.take(row, fields))
      |> Repo.update!()
    end

    :ok
  end
end
