defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.LeakageTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
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

  @tag :leakage
  test "owner-forwarded success processed and tool continuation keep sentinel out of persisted logs and process state" do
    upstream =
      start_upstream(
        # Strict finite scenario: the first turn, the processed ack, and the
        # tool continuation are the only three sends, all on the owner's single
        # connection; the sentinel may appear only in the captured requests.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{"id" => "resp_owner_leak_first"})
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.processed"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{"id" => "resp_owner_leak_processed"})
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_leak_first",
                "input.0.type" => "function_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{"id" => "resp_owner_leak_tool"})
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_log(fn ->
        {:ok, first_state} = owner_socket(auth, "ws-owner-leak-success", "leak-success")

        first_state =
          try do
            first_payload = websocket_payload(setup, @sentinel)

            assert {:ok, first_state} =
                     CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

            assert {:push, {:text, first_frame}, first_state} =
                     receive_owner_socket_push(first_state)

            assert %{"id" => "resp_owner_leak_first"} = CodexPooler.JSON.decode!(first_frame)
            assert {:ok, first_state} = receive_socket_done(first_state)
            first_state
          after
            CodexResponsesSocket.terminate(:closed, first_state)
          end

        {:ok, processed_state} = owner_socket(auth, "ws-owner-leak-processed", "leak-success")

        try do
          processed_payload =
            CodexPooler.JSON.encode!(%{
              "type" => "response.processed",
              "response_id" => "resp_owner_leak_first",
              "client_context" => @sentinel
            })

          assert {:ok, processed_state} =
                   CodexResponsesSocket.handle_in(
                     {processed_payload, [opcode: :text]},
                     processed_state
                   )

          assert {:ok, processed_state} = receive_owner_socket_complete(processed_state)
          assert {:ok, _processed_state} = receive_socket_done(processed_state)
        after
          CodexResponsesSocket.terminate(:closed, processed_state)
        end

        {:ok, tool_state} = owner_socket(auth, "ws-owner-leak-tool", "leak-success")

        try do
          tool_payload =
            CodexPooler.JSON.encode!(%{
              "type" => "response.create",
              "model" => setup.model.exposed_model_id,
              "input" => [
                %{
                  "type" => "function_call_output",
                  "call_id" => "call_owner_leak_tool",
                  "output" => @sentinel
                }
              ],
              "stream" => true,
              "generate" => true,
              "previous_response_id" => "resp_owner_leak_first"
            })

          assert {:ok, tool_state} =
                   CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, tool_state)

          assert {:push, {:text, tool_frame}, tool_state} = receive_owner_socket_push(tool_state)
          assert %{"id" => "resp_owner_leak_tool"} = CodexPooler.JSON.decode!(tool_frame)
          assert {:ok, _tool_state} = receive_socket_done(tool_state)
        after
          CodexResponsesSocket.terminate(:closed, tool_state)
        end

        assert first_state.codex_session.id
      end)

    assert_no_leak!("success logs", logs)

    assert [first_request, processed_request, tool_request] = await_upstream_requests(upstream, 3)
    assert_leak_allowed_only_in_fake_upstream!(first_request)
    assert_leak_allowed_only_in_fake_upstream!(processed_request)
    assert_leak_allowed_only_in_fake_upstream!(tool_request)
    assert tool_request.json["previous_response_id"] == "resp_owner_leak_first"

    assert tool_request.json["input"] |> List.first() |> Map.get("call_id") ==
             "call_owner_leak_tool"

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert_no_leak_in_persistence!(setup.pool.id)

    {:ok, owner_pid} =
      WebsocketOwnerSession.lookup(
        Repo.get_by!(CodexSession, session_key: turn_state_session_key("leak-success")).id
      )

    assert_no_leak!("owner state after success", :sys.get_state(owner_pid))
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :leakage
  test "owner-forwarded upstream failure keeps sentinel out of logs and accounting rows" do
    upstream =
      start_upstream(
        {:json_error, 500,
         %{
           "error" => %{"code" => "synthetic_upstream_failure", "message" => "synthetic failure"}
         }}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-leak-failure", "leak-failure")

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, error_frame}, _state} = receive_owner_socket_push(state)

          assert %{
                   "type" => "response.failed",
                   "error" => %{"code" => "synthetic_upstream_failure"}
                 } = CodexPooler.JSON.decode!(error_frame)

          assert {:ok, _state} = receive_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("failure logs", logs)
    assert [request] = FakeUpstream.requests(upstream)
    assert_leak_allowed_only_in_fake_upstream!(request)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  @tag :leakage
  test "owner raw-frame workers and per-turn response tasks are sensitive while holding sentinel payloads" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-leak-sensitive", "leak-sensitive",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
          assert_sensitive_process_hides_mailbox!(owner_worker_pid)
          assert_sensitive_tracked_response_task!(state)

          send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
          assert {:ok, state} = receive_owner_socket_complete(state)
          assert {:ok, _state} = receive_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("sensitive worker logs", logs)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  @tag :leakage
  test "owner remote wrapper and process crash paths sanitize sentinel-bearing frames" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_timeout = :"codex_pooler@timeout-leak.example"
    remote_crash = :"codex_pooler@crash-leak.example"

    {:ok, timeout_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "leak-remote-timeout",
        owner_instance_id: Atom.to_string(remote_timeout)
      })

    {:ok, crash_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "leak-remote-crash",
        owner_instance_id: Atom.to_string(remote_crash)
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_timeout, remote_crash],
        calls: %{remote_timeout => :timeout, remote_crash => :crash}
      )

    logs =
      capture_log(fn ->
        timeout_result =
          WebsocketOwnerForwarder.submit_frame(
            timeout_session,
            timeout_session.owner_lease_token,
            downstream_target("corr-timeout-leak"),
            @sentinel,
            Keyword.put(opts, :timeout, 25)
          )

        crash_result =
          WebsocketOwnerForwarder.submit_frame(
            crash_session,
            crash_session.owner_lease_token,
            downstream_target("corr-crash-leak"),
            @sentinel,
            opts
          )

        assert timeout_result == {:error, :owner_forward_timeout}
        assert crash_result == {:error, :owner_crashed}
        assert_no_leak!("remote timeout result", timeout_result)
        assert_no_leak!("remote crash result", crash_result)
      end)

    assert_no_leak!("remote wrapper logs", logs)

    Enum.each([:remote_submit_frame, :remote_submit_frame], fn function ->
      assert_receive {:websocket_owner_harness_node_call, %{function: ^function} = call}
      assert_no_leak!("remote call observation", call)
    end)

    owner_crash_logs =
      capture_log(fn ->
        upstream_boundary = crashing_owner_upstream_boundary(self())

        {:ok, owner_pid} =
          WebsocketOwnerSession.start_owner(
            codex_session_id: "synthetic-leak-owner-#{System.unique_integer([:positive])}",
            owner_lease_token: Ecto.UUID.generate(),
            owner_instance_id: Atom.to_string(node()),
            upstream: upstream_boundary
          )

        {:ok, downstream} =
          WebsocketOwnerSession.attach_downstream(
            owner_pid,
            downstream_target("corr-owner-crash")
          )

        assert WebsocketOwnerSession.submit_frame(owner_pid, downstream, @sentinel) ==
                 {:error, :owner_crashed}

        assert_receive {:crashing_owner_upstream_received, upstream_pid}

        assert_receive {:websocket_owner_frame, "corr-owner-crash", 1,
                        {:error, :owner_crashed, safe_payload}}

        assert safe_payload.metadata.reason == "owner_crashed"
        assert_no_leak!("owner crash payload", safe_payload)
        assert_no_leak!("owner state after crash", :sys.get_state(owner_pid))
        assert_no_leak!("crashing owner upstream state", crashing_owner_safe_state(upstream_pid))
      end)

    assert_no_leak!("owner crash logs", owner_crash_logs)

    per_turn_logs =
      capture_log(fn ->
        {:ok, state} = owner_socket(auth, "ws-owner-leak-worker-crash", "leak-worker-crash")

        try do
          crash_state = %{state | auth: %{}}
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, crash_state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, crash_state)

          assert {:push, {:text, error_frame}, _state} = receive_socket_done(crash_state)

          assert %{
                   "type" => "error",
                   "error" => %{"code" => "websocket_response_task_failed"}
                 } = CodexPooler.JSON.decode!(error_frame)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("per-turn worker crash logs", per_turn_logs)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  defp assert_leak_allowed_only_in_fake_upstream!(request) do
    assert inspect(%{body: request.body, json: request.json}) =~ @sentinel
    assert_no_leak!("fake upstream metadata", Map.drop(request, [:body, :json]))
  end

  defp assert_sensitive_tracked_response_task!(state) do
    [pid] = MapSet.to_list(state.tasks)
    assert_sensitive_process_hides_mailbox!(pid)
  end

  defp assert_sensitive_process_hides_mailbox!(pid) when is_pid(pid) do
    marker = {:sensitive_probe, make_ref(), @sentinel}
    send(pid, marker)
    assert_process_messages_hidden!(pid, 100)
  end

  defp assert_process_messages_hidden!(pid, attempts) when attempts > 0 do
    case :erlang.process_info(pid, :messages) do
      {:messages, []} ->
        :ok

      nil ->
        flunk("sensitive process exited before introspection check")

      _messages ->
        yield_once({:assert_process_messages_hidden, pid, attempts})
        assert_process_messages_hidden!(pid, attempts - 1)
    end
  end

  defp assert_process_messages_hidden!(_pid, 0), do: flunk("sensitive process exposed mailbox")

  defp crashing_owner_upstream_boundary(test_pid) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false} end) end,
      send: fn upstream_pid, _payload, _writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:crashing_owner_upstream_received, upstream_pid})
        exit(:simulated_owner_worker_crash)
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp crashing_owner_safe_state(upstream_pid) do
    Agent.get(upstream_pid, fn state -> state end)
  catch
    :exit, _reason -> %{closed?: true}
  end
end
