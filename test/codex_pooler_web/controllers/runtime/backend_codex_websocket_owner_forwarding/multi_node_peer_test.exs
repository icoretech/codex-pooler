defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.MultiNodePeerTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.AgentV2ContractFixture
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalStatus
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient
  alias Ecto.Adapters.SQL.Sandbox

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

  test "successful remote owner detach preserves the active session lease and accounting" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_remote_node_success",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-remote-success", "owner-remote-success")
    owner_lease = active_owner_lease(state.codex_session.id)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-owner-success.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :success},
              capture_request_to: self()
            )
          )
    }

    try do
      opts =
        Gateway.websocket_owner_response_options(
          remote_state.opts,
          remote_state.codex_session,
          remote_state.websocket_owner_lease_token,
          remote_state.websocket_owner_downstream
        )

      handoff = AgentV2ContractFixture.handoff!(:send_message)

      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_input_payload(setup, [handoff]),
                 opts,
                 fn _data -> :ok end
               )

      assert {:push, {:text, frame}, remote_state} = receive_owner_socket_push(remote_state)
      assert %{"id" => "resp_owner_remote_node_success"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _state} = receive_owner_socket_complete(remote_state)

      assert_remote_submit_request_v1!(remote_state, remote_node, :success)

      assert FakeUpstream.count(upstream) == 1
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == [handoff]
      assert [opaque_connection_id] = FakeUpstream.websocket_connection_ids(upstream)
      assert is_reference(opaque_connection_id)
      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.transport == "websocket"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"
      assert attempt.transport == "websocket"

      connection = attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id} = connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

      assert connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 1,
               "reused" => false,
               "reconnected" => false
             }

      assert [settlement] =
               Repo.all(
                 from(entry in LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 )
               )

      assert settlement.attempt_id == attempt.id
      assert settlement.transport == "websocket"
      assert_forwarding_cardinality!(request, state.codex_session.id, "succeeded")
      refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
      assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
      assert Repo.get!(CodexSession, state.codex_session.id).status == "active"
      assert Repo.get!(BridgeOwnerLease, owner_lease.id).status == "active"
      assert active_owner_lease(state.codex_session.id).lease_token == owner_lease.lease_token
      assert Repo.get!(Request, request.id).status == "succeeded"
      assert Repo.get!(Attempt, attempt.id).status == "succeeded"

      assert Repo.get_by!(CodexTurn, request_id: request.id).status == "succeeded"
      assert Process.alive?(owner_pid)
      assert WebsocketOwnerSession.lookup(state.codex_session.id) == {:ok, owner_pid}

      assert {:ok, reuse_state} =
               owner_socket(
                 auth,
                 "ws-owner-remote-success-reuse",
                 "owner-remote-success"
               )

      assert reuse_state.codex_session.id == state.codex_session.id
      assert reuse_state.websocket_owner_lease_token == owner_lease.lease_token
      assert :ok = CodexResponsesSocket.terminate(:closed, reuse_state)
      assert Repo.get!(CodexSession, state.codex_session.id).status == "active"
      assert Repo.get!(BridgeOwnerLease, owner_lease.id).status == "active"
    after
      CodexResponsesSocket.terminate(
        :closed,
        Map.delete(remote_state, :websocket_owner_downstream)
      )
    end
  end

  @tag :public_remote_success
  test "public responses bridge remote v1 success settles and delivers one terminal", %{
    conn: conn
  } do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
    response_id = "resp_owner_public_remote_#{System.unique_integer([:positive])}"
    marker = "synthetic-public-remote-marker-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => response_id,
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    session_header = "public-owner-success-#{System.unique_integer([:positive])}"
    {_session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)

    {response, logs} =
      with_log(fn ->
        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_header)
        |> post("/v1/responses", public_stream_payload(setup, marker))
      end)

    assert response.status == 200

    assert [
             %{
               "event" => "response.created",
               "data" => %{
                 "type" => "response.created",
                 "response" => %{"id" => ^response_id, "status" => "in_progress"}
               }
             },
             %{"event" => "response.completed", "data" => terminal}
           ] = public_stream_events(response.resp_body)

    assert terminal["type"] == "response.completed"
    assert get_in(terminal, ["response", "id"]) == response_id
    refute response.resp_body =~ marker
    refute logs =~ marker
    refute logs =~ setup.authorization
    assert_bridge_v1_submission!(remote_node)
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert inspect(%{body: upstream_request.body, json: upstream_request.json}) =~ marker

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    rows = assert_forwarding_cardinality!(request, nil, "succeeded")
    assert_no_markers_persisted!(rows, setup.pool.id, [marker])

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
    assert node(owner_pid) == remote_node
    assert :erpc.call(remote_node, Process, :alive?, [owner_pid])
  end

  test "admitted native proxy starts a real peer upstream before terminal delivery acknowledgement" do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
    use_fresh_rollout_drain!()
    release_ref = make_ref()
    response_id = "resp_native_proxy_predispatch_#{System.unique_integer([:positive])}"

    terminal =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed"}
      })

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(
          terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    refute OperationalStatus.draining?()
    refute :erpc.call(remote_node, OperationalStatus, :draining?, [])
    session_header = "native-proxy-predispatch-#{System.unique_integer([:positive])}"
    {_session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)

    {:ok, state} =
      owner_socket(auth, "ws-native-proxy-predispatch", "native-proxy-predispatch",
        session_header: session_header,
        session_header_source: "x-session-id"
      )

    try do
      payload = websocket_payload(setup, "native proxy predispatch")
      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid,
                      ^release_ref},
                     5_000

      assert MapSet.size(state.tasks) == 1
      [task_pid] = MapSet.to_list(state.tasks)
      refute_received {:websocket_response_activity, _task_pid, _activity_token}
      send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

      assert_receive {:websocket_owner_frame, correlation_id, epoch, _owner_turn_id,
                      {:data, ^terminal}} =
                       terminal_message,
                     5_000

      assert {:push, {:text, ^terminal}, state} =
               CodexResponsesSocket.handle_info(terminal_message, state)

      assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, _owner_turn_id, :complete} =
                       complete_message,
                     5_000

      assert {:ok, state} = CodexResponsesSocket.handle_info(complete_message, state)
      assert_receive {:websocket_response_activity, ^task_pid, activity_token} = activity_message
      assert {:ok, state} = CodexResponsesSocket.handle_info(activity_message, state)
      assert_receive {:codex_response_done, ^task_pid, _result} = done_message
      assert {:ok, state} = CodexResponsesSocket.handle_info(done_message, state)

      assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token} =
                       delivery_message

      assert {:ok, _state} = CodexResponsesSocket.handle_info(delivery_message, state)
      assert FakeUpstream.count(upstream) == 1
      assert :erpc.call(remote_node, Process, :alive?, [owner_pid])

      assert_receive {:fake_upstream_websocket_barrier, :before_close, close_pid, ^release_ref}
      send(close_pid, {:fake_upstream_release_websocket, release_ref})
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "native proxy turn replaces the attach timeout with the full request budget" do
    terminal =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_owner_turn_budget", "status" => "completed"}
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-turn-budget", "owner-turn-budget")
    remote_node = :"codex_pooler@turn-budget-owner.example"
    TurnBudgetNodeClient.configure(remote_node, self(), 15_000)

    node_opts = [
      node_client: TurnBudgetNodeClient,
      timeout: WebsocketOwnerContract.default_forward_timeout_ms()
    ]

    remote_state = remote_owner_state(state, remote_node, node_opts)

    try do
      payload = websocket_payload(setup, "owner turn budget")

      :sys.replace_state(
        state.websocket_owner_pid,
        &%{&1 | owner_instance_id: Atom.to_string(remote_node)}
      )

      assert {:ok, remote_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, remote_state)

      [task_pid] = MapSet.to_list(remote_state.tasks)

      assert_receive {:turn_budget_remote_call, :remote_submit_request_v1, 1_801_000}

      assert_receive {:websocket_owner_frame, correlation_id, epoch, _owner_turn_id,
                      {:data, ^terminal}} =
                       terminal_message

      assert {:push, {:text, ^terminal}, remote_state} =
               CodexResponsesSocket.handle_info(terminal_message, remote_state)

      assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, _owner_turn_id, :complete} =
                       complete_message

      assert {:ok, remote_state} =
               CodexResponsesSocket.handle_info(complete_message, remote_state)

      assert_receive {:websocket_response_activity, ^task_pid, activity_token} = activity_message

      assert {:ok, remote_state} =
               CodexResponsesSocket.handle_info(activity_message, remote_state)

      assert_receive {:codex_response_done, ^task_pid, _result} = done_message
      assert {:ok, remote_state} = CodexResponsesSocket.handle_info(done_message, remote_state)

      assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token} =
                       delivery_message

      assert {:ok, _state} = CodexResponsesSocket.handle_info(delivery_message, remote_state)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :public_protocol_fallback
  test "public responses bridge protocol incompatibility fails without upstream submission", %{
    conn: conn
  } do
    ensure_test_distribution_started!()
    marker = "synthetic-public-protocol-marker-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "unused_protocol_incompatible_response",
               "status" => "completed",
               "output" => []
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:previous, setup.identity)
    session_header = "public-owner-old-release-#{System.unique_integer([:positive])}"
    {_session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node)

    logs =
      capture_log(fn ->
        response =
          conn
          |> auth(setup)
          |> put_req_header("x-session-id", session_header)
          |> post("/v1/responses", public_stream_payload(setup, marker))

        assert response.status == 200

        assert [%{"event" => "error", "data" => %{"code" => "server_error"}}] =
                 public_stream_events(response.resp_body)

        refute response.resp_body =~ marker
      end)

    refute :erpc.call(remote_node, :erlang, :function_exported, [
             WebsocketOwnerForwarder,
             :remote_submit_request_v1,
             3
           ])

    assert logs =~ "event=owner_protocol_incompatible"
    refute logs =~ marker
    refute logs =~ setup.authorization

    assert FakeUpstream.count(upstream) == 0
    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert FakeUpstream.http_request_count(upstream) == 0
    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "http_sse"
    rows = assert_forwarding_cardinality!(request, nil, "failed")
    assert_no_markers_persisted!(rows, setup.pool.id, [marker])
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
    assert node(owner_pid) == remote_node
    assert :erpc.call(remote_node, Process, :alive?, [owner_pid])
  end

  test "local and remote owners emit identical native metadata bytes for one turn snapshot" do
    upstream =
      start_upstream(
        # Strict finite scenario: the local and the remote owner each forward
        # exactly one native turn upstream and nothing else is sent.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_local_metadata_parity",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_remote_metadata_parity",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, local_state} = owner_socket(auth, "ws-local-metadata-parity", "local-metadata-parity")

    {:ok, remote_state} =
      owner_socket(auth, "ws-remote-metadata-parity", "remote-metadata-parity")

    remote_node = :"codex_pooler@remote-metadata-parity.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(remote_state, remote_node, node_opts)

    models_conn = build_conn() |> auth(setup) |> get("/backend-api/codex/models")
    assert [models_etag] = get_resp_header(models_conn, "etag")

    try do
      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "local metadata parity"),
                 owner_response_options(local_state, []),
                 fn _data -> :ok end
               )

      assert {:push, {:text, local_metadata}, local_state} =
               receive_owner_socket_raw_push(local_state)

      assert %{
               "type" => "codex.response.metadata",
               "headers" => %{"x-models-etag" => ^models_etag}
             } = CodexPooler.JSON.decode!(local_metadata)

      assert {:push, {:text, local_response}, local_state} =
               receive_owner_socket_raw_push(local_state)

      assert owner_response_id(local_response) == "resp_local_metadata_parity"
      assert {:ok, _local_state} = receive_owner_socket_complete(local_state)

      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "remote metadata parity"),
                 owner_response_options(remote_state, node_opts),
                 fn _data -> :ok end
               )

      assert {:push, {:text, remote_metadata}, remote_state} =
               receive_owner_socket_raw_push(remote_state)

      assert remote_metadata == local_metadata

      assert {:push, {:text, remote_response}, remote_state} =
               receive_owner_socket_raw_push(remote_state)

      assert owner_response_id(remote_response) == "resp_remote_metadata_parity"
      assert {:ok, _remote_state} = receive_owner_socket_complete(remote_state)
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, local_state)
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  defp public_stream_payload(setup, input) do
    %{"model" => setup.model.exposed_model_id, "input" => input, "stream" => true}
  end

  defp public_stream_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      assert [event] = Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first)
      assert [data] = Regex.run(~r/^data: (.+)$/m, block, capture: :all_but_first)
      %{"event" => event, "data" => CodexPooler.JSON.decode!(data)}
    end)
  end

  defp assert_bridge_v1_submission!(remote_node) do
    assert_receive {:remote_forwarder_v1_call, remote_pid,
                    [codex_session_id, downstream, %WebsocketOwnerRequest{version: 1} = request]}

    assert node(remote_pid) == remote_node
    assert is_binary(codex_session_id)
    assert %{pid: pid, correlation_id: correlation_id, epoch: epoch} = downstream
    assert is_pid(pid)
    assert is_binary(correlation_id)
    assert is_integer(epoch) and epoch > 0
    assert :ok = WebsocketOwnerRequest.validate(request)
    refute contains_function?(request)
    request
  end

  defp use_fresh_rollout_drain! do
    previous_config = Application.get_env(:codex_pooler, RolloutDrain)

    previous_status_config =
      Application.get_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

    activity_registry = :"predispatch-activity-#{System.unique_integer([:positive])}"
    drain_name = :"predispatch-drain-#{System.unique_integer([:positive])}"
    start_supervised!({ActivityRegistry, name: activity_registry})
    start_supervised!({RolloutDrain, name: drain_name, activity_registry: activity_registry})
    Application.put_env(:codex_pooler, RolloutDrain, server_name: drain_name)
    Application.delete_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

    on_exit(fn ->
      case previous_config do
        nil -> Application.delete_env(:codex_pooler, RolloutDrain)
        config -> Application.put_env(:codex_pooler, RolloutDrain, config)
      end

      case previous_status_config do
        nil ->
          Application.delete_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

        config ->
          Application.put_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus, config)
      end
    end)
  end
end
