defmodule CodexPooler.Gateway.Runtime.Finalization.InterruptionCorrelationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Payloads.{RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.{CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket, as: Gateway

  for claim_kind <- [:turn, :request, :stored_hash] do
    test "preserves #{claim_kind} correlation storage and interruption lookup" do
      fixture = fixture(unquote(claim_kind))
      stored_correlation = Repo.get!(Request, fixture.request.id).correlation_id
      assert fixture.request.correlation_id == fixture.claim

      assert stored_correlation == fixture.claim
      assert_interrupted(fixture, fixture.claim)
    end
  end

  test "ordinary correlation ids remain unchanged and select only their own turn" do
    fixture = fixture(:ordinary)
    assert Repo.get!(Request, fixture.request.id).correlation_id == fixture.claim
    assert_interrupted(fixture, fixture.claim)
  end

  defp fixture(claim_kind) do
    setup = accounting_setup()

    {:ok, session} =
      Gateway.start_codex_session(setup.auth, %{
        accepted_turn_state: "correlation-#{System.unique_integer([:positive])}"
      })

    payload = %{
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{"turn_id" => "synthetic-turn"}
    }

    {:ok, identity} = WebsocketTurnIdentity.resolve(payload, session.id)

    claim =
      case claim_kind do
        :turn -> identity.turn_claim_key
        :request -> WebsocketTurnIdentity.request_claim_key(identity.semantic_turn_key, payload)
        :stored_hash -> "sha256:" <> Base.encode16(identity.semantic_turn_key, case: :lower)
        :ordinary -> Ecto.UUID.generate()
      end

    {:ok, reserved} =
      Accounting.reserve(setup.auth, setup.model, payload, %{
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        correlation_id: claim
      })

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    options = RequestOptions.for_websocket(%{request_id: claim})
    {:ok, turn} = SessionContinuity.start_codex_turn(session, reserved.request, options)

    %{session: session, request: reserved.request, attempt: attempt, turn: turn, claim: claim}
  end

  defp assert_interrupted(fixture, selector) do
    options = RequestOptions.for_websocket(%{request_id: selector})

    assert {:ok, %{interrupted_turn_count: 1}} =
             Interruption.interrupt_codex_turn(fixture.session, options)

    assert Repo.get!(Request, fixture.request.id).status == "failed"
    assert Repo.get!(Attempt, fixture.attempt.id).status == "failed"
    assert Repo.get!(CodexTurn, fixture.turn.id).status == "interrupted"

    assert {:ok, %{interrupted_turn_count: 0}} =
             Interruption.interrupt_codex_turn(fixture.session, options)
  end
end
