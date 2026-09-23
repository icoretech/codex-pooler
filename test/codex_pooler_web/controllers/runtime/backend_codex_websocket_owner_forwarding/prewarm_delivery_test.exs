defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.PrewarmDeliveryTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  for topology <- [:local_owner, :proxy] do
    if topology == :proxy do
      @tag slow: "boots a real peer owner and verifies prewarm acknowledgement releases the queued generation"
    end

    test "#{topology} prewarm acknowledges its local terminal and releases the next generation" do
      topology = unquote(topology)
      prepare_database(topology)

      upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame()]))
      fixture = gateway_setup(upstream)
      register_fixture_cleanup(fixture, topology)
      {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
      state = prepare_socket(auth, fixture, topology)

      prewarm = websocket_payload(fixture, "synthetic prewarm", %{"generate" => false})
      assert {:ok, state} = CodexResponsesSocket.handle_in({prewarm, [opcode: :text]}, state)
      [prewarm_task] = MapSet.to_list(state.tasks)

      assert {:push, {:text, created}, state} = receive_native_collect_socket_push(state)
      assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)
      assert {:push, {:text, completed}, state} = receive_native_collect_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed)
      assert FakeUpstream.requests(upstream) == []

      generation = websocket_payload(fixture, "synthetic generation")
      assert {:ok, state} = CodexResponsesSocket.handle_in({generation, [opcode: :text]}, state)
      assert :queue.len(state.queued_response_payloads) == 1

      state = complete_prewarm(state, prewarm_task, topology)
      refute MapSet.member?(state.tasks, prewarm_task)
      assert :queue.is_empty(state.queued_response_payloads)
      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(frame)
      state = settle_owner_socket_turn(state)
      assert Enum.map(request_logs(fixture.pool.id), & &1.status) == ["succeeded"]
      assert FakeUpstream.count(upstream) == 1
      assert :ok = FakeUpstream.verify!(upstream)
      assert :ok = CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp register_fixture_cleanup(_fixture, :local_owner), do: :ok
  defp register_fixture_cleanup(fixture, :proxy), do: register_unboxed_pool_cleanup!(fixture)

  defp prepare_database(:local_owner), do: :ok

  defp prepare_database(:proxy) do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
  end

  defp prepare_socket(auth, _fixture, :local_owner) do
    {:ok, state} = owner_socket(auth, "prewarm-local", "prewarm-state-local")
    state
  end

  defp prepare_socket(auth, fixture, :proxy) do
    remote_node = start_bridge_peer!(:current, fixture.identity, repo: :real)
    session_header = "prewarm-proxy-#{System.unique_integer([:positive])}"
    {_session, owner} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)
    assert node(owner) == remote_node

    {:ok, state} =
      owner_socket(auth, "prewarm-proxy", "prewarm-state-proxy",
        session_header: session_header,
        session_header_source: "x-session-id"
      )

    assert state.codex_session.owner_instance_id == Atom.to_string(remote_node)
    state
  end

  defp complete_prewarm(state, task, :local_owner) do
    assert_receive {:codex_response_done, ^task, {:socket_response_result, :local_complete, :ok}} =
                     done,
                   @detection_timeout

    assert {:ok, state} = CodexResponsesSocket.handle_info(done, state)
    state
  end

  defp complete_prewarm(state, task, :proxy) do
    assert_receive {:websocket_response_activity, ^task, token} = activity, @detection_timeout
    assert {:ok, state} = CodexResponsesSocket.handle_info(activity, state)

    assert_receive {:codex_response_done, ^task, {:socket_response_result, :local_complete, :ok}} =
                     done,
                   @detection_timeout

    assert {:ok, state} = CodexResponsesSocket.handle_info(done, state)

    assert_receive {:websocket_response_delivery_complete, ^task, ^token} = delivery,
                   @detection_timeout

    assert {:ok, state} = CodexResponsesSocket.handle_info(delivery, state)
    state
  end

  defp settle_owner_socket_turn(state) do
    if MapSet.size(state.tasks) == 0 do
      state
    else
      receive do
        message
        when is_tuple(message) and
               elem(message, 0) in [
                 :websocket_owner_cleanup_witness,
                 :websocket_owner_frame,
                 :websocket_owner_output_commit_probe,
                 :websocket_response_activity,
                 :direct_request_cleanup,
                 :codex_response_done,
                 :websocket_response_delivery_complete
               ] ->
          assert {:ok, next_state} = CodexResponsesSocket.handle_info(message, state)
          settle_owner_socket_turn(next_state)
      after
        @detection_timeout -> flunk("generation did not settle after prewarm")
      end
    end
  end

  defp completed_frame do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_synthetic_prewarm_followup",
        "status" => "completed",
        "output" => [],
        "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
      }
    })
  end
end
