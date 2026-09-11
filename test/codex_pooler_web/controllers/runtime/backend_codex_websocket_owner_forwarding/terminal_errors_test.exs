defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.TerminalErrorsTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient

  @sentinel "SECRET_SENTINEL_DO_NOT_STORE_123"

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()
      TurnBudgetNodeClient.reset()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  @tag :f2_owner_terminal_error_param
  test "owner-forwarded terminal failure persists only its safe upstream error param" do
    message_sentinel = "owner-terminal-message-sentinel"
    value_sentinel = "owner-terminal-value-sentinel"
    frame_sentinel = "owner-terminal-frame-sentinel"
    header_sentinel = "owner-terminal-header-sentinel"
    token_sentinel = "owner-terminal-token-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "raw_frame" => frame_sentinel,
               "response" => %{
                 "id" => "resp_owner_safe_error_param",
                 "error" => %{
                   "code" => "upstream_terminal_failure",
                   "param" => "reasoning.effort",
                   "message" => message_sentinel,
                   "value" => value_sentinel,
                   "token" => token_sentinel
                 },
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
               }
             }}
          ],
          done: false,
          headers: [{"x-owner-raw-header", header_sentinel}]
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-safe-error-param", "owner-safe-error-param")

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, "owner forwarded terminal failure")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, terminal_frame}, state} = receive_owner_socket_push(state)
          assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(terminal_frame)
          assert {:ok, completed_state} = receive_socket_done(state)
          assert :ok = CodexResponsesSocket.terminate(:closed, completed_state)
          assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.response_status_code == 200
    assert request.last_error_code == "upstream_terminal_failure"
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.response_metadata["upstream_error_param"] == "reasoning.effort"

    assert [turn] =
             Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id))

    assert turn.status == "failed"
    assert turn.error_code == "upstream_terminal_failure"
    assert Repo.get!(CodexSession, state.codex_session.id).status == "active"

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.websocket_owner_lease_token

    assert {:ok, _owner} = WebsocketOwnerSession.lookup(state.codex_session.id)

    assert Repo.aggregate(
             from(e in LedgerEntry,
               where: e.request_id == ^request.id and e.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert [demotion] = Repo.all(from(d in BridgeDemotion))
    assert demotion.reason_code == "upstream_terminal_failure"

    assert [circuit] =
             Repo.all(from(c in RoutingCircuitState, where: c.route_class == "proxy_websocket"))

    assert circuit.reason_code == "upstream_terminal_failure"

    persisted = inspect({request.request_metadata, attempt.response_metadata})

    for raw_sentinel <- [
          message_sentinel,
          value_sentinel,
          frame_sentinel,
          header_sentinel,
          token_sentinel,
          setup.authorization,
          setup.raw_key,
          "upstream-token"
        ] do
      refute persisted =~ raw_sentinel
      refute logs =~ raw_sentinel
    end
  end

  @tag :f2_owner_terminal_error_param
  test "owner-forwarded invalid first error param does not fall back or persist raw diagnostics" do
    message_sentinel = "owner-invalid-message-sentinel"
    value_sentinel = "owner-invalid-value-sentinel"
    frame_sentinel = "owner-invalid-frame-sentinel"
    header_sentinel = "owner-invalid-header-sentinel"
    token_sentinel = "owner-invalid-token-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "raw_frame" => frame_sentinel,
               "response" => %{
                 "id" => "resp_owner_invalid_error_param",
                 "error" => %{
                   "code" => "unsupported_value",
                   "param" => "invalid param #{value_sentinel}",
                   "message" => message_sentinel,
                   "value" => value_sentinel,
                   "token" => token_sentinel
                 }
               },
               "error" => %{"param" => "reasoning.effort"}
             }}
          ],
          done: false,
          headers: [{"x-owner-raw-header", header_sentinel}]
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-invalid-error-param", "owner-invalid-error-param")

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, "owner forwarded invalid terminal parameter")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, terminal_frame}, state} = receive_owner_socket_push(state)
          assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(terminal_frame)
          assert {:ok, completed_state} = receive_socket_done(state)
          assert :ok = CodexResponsesSocket.terminate(:closed, completed_state)
          assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.response_status_code == 200
    assert request.last_error_code == "unsupported_value"
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    refute Map.has_key?(attempt.response_metadata, "upstream_error_param")

    assert [turn] =
             Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id))

    assert turn.status == "failed"
    assert turn.error_code == "unsupported_value"
    assert Repo.get!(CodexSession, state.codex_session.id).status == "active"

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.websocket_owner_lease_token

    assert {:ok, _owner} = WebsocketOwnerSession.lookup(state.codex_session.id)

    assert Repo.aggregate(
             from(e in LedgerEntry,
               where: e.request_id == ^request.id and e.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    persisted = inspect({request.request_metadata, attempt.response_metadata})

    for raw_sentinel <- [
          message_sentinel,
          value_sentinel,
          frame_sentinel,
          header_sentinel,
          token_sentinel,
          setup.authorization,
          setup.raw_key,
          "upstream-token"
        ] do
      refute persisted =~ raw_sentinel
      refute logs =~ raw_sentinel
    end
  end

  test "owner-forwarded upstream close before terminal persists safe transport metadata" do
    raw_event_type = "response.private_event_sentinel_deadbeef"

    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close(
          [
            {raw_event_type,
             %{
               "type" => raw_event_type,
               "response_id" => "resp_owner_transport_failure",
               "output_index" => 0,
               "content_index" => 0,
               "delta" => @sentinel
             }}
          ],
          reason: "owner upstream close reason sentinel"
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-transport-failure", "owner-transport-failure")

    payload =
      websocket_payload(setup, "owner forwarded transport failure", %{
        "request_id" => "ws-owner-transport-failure"
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert {:push, {:text, partial_frame}, state} = receive_owner_socket_push(state)

    assert %{"type" => ^raw_event_type, "delta" => @sentinel} =
             CodexPooler.JSON.decode!(partial_frame)

    assert {:push, {:text, owner_error_frame}, state} = receive_owner_socket_push(state)

    assert %{"type" => "error", "error" => %{"code" => "server_error"}} =
             CodexPooler.JSON.decode!(owner_error_frame)

    assert {:push, {:text, error_frame}, failed_state} = receive_socket_done(state)

    assert_receive {:websocket_owner_frame, _, _, _, :complete} = owner_complete
    assert {:ok, failed_state} = CodexResponsesSocket.handle_info(owner_complete, failed_state)

    assert %{"type" => "error", "error" => %{"code" => "upstream_request_failed"}} =
             CodexPooler.JSON.decode!(error_frame)

    assert failed_state.websocket_owner_active_turn_reconnect? == false
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0

    assert [request_log] = request_logs(setup.pool.id)
    assert request_log.status == "failed"
    assert request_log.transport == "websocket"
    assert request_log.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_log.id))
    assert attempt.status == "failed"
    assert_forwarding_cardinality!(request_log, state.codex_session.id, "failed")

    connection = attempt.response_metadata["upstream_websocket_connection"]

    assert %{"lifecycle_id" => lifecycle_id} = connection
    assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

    assert connection == %{
             "lifecycle_id" => lifecycle_id,
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           }

    assert attempt.response_metadata["transport_failure"] == %{
             "connection_age_bucket" => "under_1m",
             "connection_idle_bucket" => "first_request",
             "connection_request_bucket" => "first",
             "connection_use" => "fresh",
             "last_upstream_event_class" => "response_unknown_event",
             "last_upstream_event_type" => "response.unknown",
             "peer_close_code" => 1001,
             "peer_close_reason_bytes" => 36,
             "peer_close_reason_present" => true,
             "phase" => "upstream_close",
             "pre_visible_output" => false,
             "reason" => "upstream_websocket_closed_before_terminal",
             "reason_class" => "upstream_websocket_closed_before_terminal",
             "terminal_candidate_seen" => false,
             "terminal_seen" => false,
             "termination_source" => "peer_close_frame",
             "text_frame_count" => 1,
             "transport_signal" => "tcp_data",
             "upstream_committed" => true,
             "websocket_buffer_bucket" => "empty",
             "websocket_fragment_open" => false
           }

    metadata_text = inspect(attempt.response_metadata)
    refute metadata_text =~ raw_event_type
    refute metadata_text =~ @sentinel
    refute metadata_text =~ "owner upstream close reason sentinel"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
    await_owner_cleanup!(failed_state.codex_session.id)
  end

  test "owner-forwarded websocket overloads keep internal causes off the Codex wire" do
    for {internal_reason, queue_limit, queue_timeout_ms} <- [
          {"bulkhead_rejected", 0, 1_000},
          {"bulkhead_queue_timeout", 1, 25}
        ] do
      with_proxy_websocket_bulkhead(queue_limit, queue_timeout_ms, fn ->
        upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
        setup = gateway_setup(upstream)
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

        {:ok, state} =
          owner_socket(
            auth,
            "ws-owner-overload-#{internal_reason}",
            "owner-overload-#{internal_reason}"
          )

        assert {:ok, lease} =
                 Admission.acquire("proxy_websocket", %{request_id: "held-#{internal_reason}"})

        try do
          payload = websocket_payload(setup, "synthetic owner overload")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)

          assert %{
                   "type" => "error",
                   "status" => 503,
                   "error" => %{
                     "code" => "server_is_overloaded",
                     "message" => "gateway route class is temporarily overloaded",
                     "param" => nil,
                     "type" => "server_error"
                   }
                 } = CodexPooler.JSON.decode!(error_frame)

          refute error_frame =~ internal_reason
          assert FakeUpstream.requests(upstream) == []
          assert request_logs(setup.pool.id) == []
          assert pool_attempts(setup.pool.id) == []
          assert pool_ledger_entries(setup.pool.id) == []
        after
          Admission.release(lease)
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)
    end
  end
end
