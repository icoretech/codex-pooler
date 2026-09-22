defmodule CodexPooler.Gateway.Runtime.Finalization.InterruptionSupersededRequestTest do
  # The stop/edit/resubmit shape: a turn is interrupted, the client submits the
  # next turn on the same session, and only then does the interrupted turn's
  # socket close. The cleanup receipt for the first request therefore arrives
  # while a later turn of the same session is already `in_progress`
  # (icoretech/codex-pooler-findings#252).
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @codex_responses_endpoint "/backend-api/codex/responses"

  test "settles an interrupted request whose cleanup lands after the next turn is admitted" do
    fixture = interrupted_turn_fixture!(successor: true)

    assert :ok = Interruption.interrupt_direct_request(fixture.receipt, "client_disconnected")

    assert %Request{
             status: "failed",
             response_status_code: 499,
             last_error_code: "client_disconnected",
             usage_status: "usage_unknown"
           } = Repo.reload!(fixture.request)

    assert %CodexTurn{status: "interrupted", error_code: "client_disconnected"} =
             Repo.reload!(fixture.turn)

    assert %Attempt{status: "failed"} = Repo.reload!(fixture.attempt)

    # What the refusal was protecting: the successor keeps its turn, its request
    # and the session row it is being served on.
    assert %CodexTurn{status: "in_progress"} = Repo.reload!(fixture.successor.turn)
    assert %Request{status: "in_progress"} = Repo.reload!(fixture.successor.request)
    assert Repo.reload!(fixture.session) == fixture.session
  end

  test "closes the session turn as before when no successor is in progress" do
    fixture = interrupted_turn_fixture!(successor: false)

    assert :ok = Interruption.interrupt_direct_request(fixture.receipt, "client_disconnected")

    assert %Request{status: "failed", last_error_code: "client_disconnected"} =
             Repo.reload!(fixture.request)

    assert %CodexTurn{status: "interrupted"} = Repo.reload!(fixture.turn)
    assert %CodexSession{status: "interrupted"} = Repo.reload!(fixture.session)
  end

  defp interrupted_turn_fixture!(opts) do
    setup = accounting_setup()
    session = insert_session!(setup)
    interrupted = admit_turn!(setup, session, 1)

    successor =
      if Keyword.fetch!(opts, :successor), do: admit_turn!(setup, session, 2), else: nil

    %{
      session: Repo.reload!(session),
      request: interrupted.request,
      attempt: interrupted.attempt,
      turn: interrupted.turn,
      successor: successor,
      receipt: %{
        session_id: session.id,
        request_id: interrupted.request.id,
        correlation_id: interrupted.request.correlation_id,
        api_key_id: interrupted.request.api_key_id,
        attempt_id: interrupted.attempt.id,
        replay_generation: interrupted.attempt.replay_generation
      }
    }
  end

  defp admit_turn!(setup, session, turn_sequence) do
    claim = "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:ok, %{request: claimed}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: @codex_responses_endpoint,
               correlation_id: claim,
               codex_session: session
             })

    assert {:ok, %{request: request}} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => []},
               %{
                 endpoint: @codex_responses_endpoint,
                 transport: "websocket",
                 correlation_id: claim,
                 turn_claim: claimed
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(request, setup.assignment)

    %{request: request, attempt: attempt, turn: insert_turn!(session, request, attempt, turn_sequence)}
  end

  defp insert_session!(setup) do
    now = db_now()

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "superseded-interrupt-#{System.unique_integer([:positive, :monotonic])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      # The owner columns are an all-or-nothing group (`codex_sessions_check`),
      # and a session serving a live turn always carries them.
      owner_instance_id: "owner-node@example",
      owner_instance_boot_id: "owner-boot",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 300, :second),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp insert_turn!(session, request, attempt, turn_sequence) do
    now = db_now()

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: turn_sequence,
      transport_kind: "websocket",
      semantic_turn_digest: :crypto.strong_rand_bytes(32),
      status: "in_progress",
      final_attempt_id: attempt.id,
      started_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp db_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
