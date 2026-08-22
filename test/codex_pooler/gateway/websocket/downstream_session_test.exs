defmodule CodexPooler.Gateway.Websocket.DownstreamSessionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.DownstreamSession
  alias CodexPooler.Repo

  @remote_node :"codex_pooler@remote-detach-owner.example"

  setup do
    setup = accounting_setup()

    assert {:ok, session} =
             Gateway.start_codex_session(setup.auth, %{
               accepted_turn_state:
                 "remote-detach-#{System.unique_integer([:positive, :monotonic])}"
             })

    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:ok, owner_pid} =
             WebsocketOwnerSession.start_owner(
               codex_session_id: session.id,
               owner_lease_token: session.owner_lease_token,
               owner_instance_id: session.owner_instance_id,
               owner_renewal_ms: 60_000,
               upstream: upstream
             )

    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner_pid, %{
               pid: self(),
               correlation_id: "remote-detach-correlation",
               epoch: 0
             })

    on_exit(fn ->
      if Process.alive?(owner_pid), do: GenServer.stop(owner_pid)
    end)

    {:ok,
     setup: setup,
     session: session,
     owner_pid: owner_pid,
     owner_lease: active_owner_lease(session.id),
     state: remote_downstream_state(session, downstream)}
  end

  test "successful detach interrupts a genuinely in-progress websocket turn", fixture do
    turn = active_turn_fixture(fixture, "websocket")

    assert :ok = DownstreamSession.cleanup(fixture.state)

    assert %Request{
             status: "failed",
             response_status_code: 499,
             last_error_code: "client_disconnected"
           } = Repo.get!(Request, turn.request.id)

    assert %Attempt{
             status: "failed",
             upstream_status_code: 499,
             network_error_code: "client_disconnected"
           } = Repo.get!(Attempt, turn.attempt.id)

    assert %CodexTurn{
             status: "interrupted",
             final_attempt_id: final_attempt_id,
             error_code: "client_disconnected"
           } = Repo.get!(CodexTurn, turn.turn.id)

    assert final_attempt_id == turn.attempt.id
    assert Repo.get!(CodexSession, fixture.session.id).status == "interrupted"
    assert_lease_preserved!(fixture)
  end

  test "successful detach preserves accounting success that wins before turn completion",
       fixture do
    turn = active_turn_fixture(fixture, "websocket")
    finalize_turn(turn, "succeeded", nil, complete_turn?: false)
    assert Repo.get!(CodexTurn, turn.turn.id).status == "in_progress"

    assert :ok = DownstreamSession.cleanup(fixture.state)

    assert Repo.get!(CodexSession, fixture.session.id).status == "active"
    assert Repo.get!(Request, turn.request.id).status == "succeeded"
    assert Repo.get!(Attempt, turn.attempt.id).status == "succeeded"

    assert %CodexTurn{status: "succeeded", final_attempt_id: final_attempt_id, error_code: nil} =
             Repo.get!(CodexTurn, turn.turn.id)

    assert final_attempt_id == turn.attempt.id
    assert_lease_preserved!(fixture)
  end

  test "successful detach ignores a newer in-progress HTTP fallback turn", fixture do
    websocket_turn = active_turn_fixture(fixture, "websocket")
    finalize_turn(websocket_turn, "succeeded", nil)
    http_turn = active_turn_fixture(fixture, "http_sse")

    assert :ok = DownstreamSession.cleanup(fixture.state)

    assert Repo.get!(CodexSession, fixture.session.id).status == "active"
    assert Repo.get!(CodexTurn, websocket_turn.turn.id).status == "succeeded"
    assert Repo.get!(Request, http_turn.request.id).status == "in_progress"
    assert Repo.get!(Attempt, http_turn.attempt.id).status == "in_progress"
    assert Repo.get!(CodexTurn, http_turn.turn.id).status == "in_progress"
    assert_lease_preserved!(fixture)
  end

  test "successful detach preserves a failed terminal winner and its single settlement",
       fixture do
    turn = active_turn_fixture(fixture, "websocket")
    finalize_turn(turn, "failed", "upstream_error")

    assert :ok = DownstreamSession.cleanup(fixture.state)

    assert Repo.get!(CodexSession, fixture.session.id).status == "interrupted"
    assert Repo.get!(Request, turn.request.id).status == "failed"
    assert Repo.get!(Request, turn.request.id).last_error_code == "upstream_error"
    assert Repo.get!(Attempt, turn.attempt.id).status == "failed"
    assert Repo.get!(Attempt, turn.attempt.id).network_error_code == "upstream_error"
    assert Repo.get!(CodexTurn, turn.turn.id).status == "failed"
    assert Repo.get!(CodexTurn, turn.turn.id).error_code == "upstream_error"

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^turn.request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert_lease_preserved!(fixture)
  end

  defp active_turn_fixture(fixture, transport) do
    correlation_id = "remote-detach-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, reserved} =
             Accounting.reserve(
               fixture.setup.auth,
               fixture.setup.model,
               %{"model" => fixture.setup.model.exposed_model_id},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: transport,
                 correlation_id: correlation_id,
                 request_metadata: %{"codex_session_id" => fixture.session.id}
               }
             )

    assert {:ok, attempt} =
             Accounting.create_attempt(reserved.request, fixture.setup.assignment)

    assert {:ok, turn} = Gateway.start_codex_turn(fixture.session, reserved.request)
    %{request: reserved.request, attempt: attempt, turn: turn}
  end

  defp finalize_turn(turn, status, error_code, opts \\ []) do
    response_status_code = if status == "succeeded", do: 200, else: 502

    assert {:ok, %{request: request, attempt: attempt}} =
             Accounting.finalize_request(turn.request, turn.attempt, %{
               request_status: status,
               attempt_status: status,
               response_status_code: response_status_code,
               last_error_code: error_code,
               usage: %{status: "usage_unknown", source: error_code || "remote_detach_success"}
             })

    if Keyword.get(opts, :complete_turn?, true) do
      CodexPooler.Gateway.Persistence.SessionContinuity.complete_codex_turn(
        {:ok, %{request: request, attempt: attempt}},
        status,
        error_code
      )
    end

    :ok
  end

  defp remote_downstream_state(session, downstream) do
    %{
      codex_session: %{session | owner_instance_id: Atom.to_string(@remote_node)},
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_downstream: downstream,
      opts:
        RequestOptions.for_websocket(%{
          request_id: "remote-detach-connection",
          websocket_owner_forwarder_opts:
            WebsocketOwnerNodeHarness.node_client_opts([@remote_node],
              calls: %{@remote_node => :success}
            )
        })
    }
  end

  defp active_owner_lease(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active"
    )
  end

  defp assert_lease_preserved!(fixture) do
    assert Repo.get!(BridgeOwnerLease, fixture.owner_lease.id).status == "active"

    assert Repo.get!(CodexSession, fixture.session.id).owner_lease_token ==
             fixture.owner_lease.lease_token

    assert Process.alive?(fixture.owner_pid)
  end
end
