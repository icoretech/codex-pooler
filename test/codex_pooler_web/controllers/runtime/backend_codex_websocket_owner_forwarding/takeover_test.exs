defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.TakeoverTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.StaleOwnerNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient
  alias CodexPoolerWeb.WebsocketConnectionLogger

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

  @tag :replay_topology
  @tag :findings116
  test "stale owner token rejects before upstream send" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-token",
          accepted_turn_state: "stable-ws-owner-stale-token",
          client_ip: "127.0.0.1"
        }
      })

    stale_state = state
    takeover_token = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    state.codex_session
    |> Ecto.Changeset.change(%{owner_lease_token: takeover_token, updated_at: now})
    |> Repo.update!()

    active_owner_lease(state.codex_session.id)
    |> Ecto.Changeset.change(%{lease_token: takeover_token, renewed_at: now, updated_at: now})
    |> Repo.update!()

    try do
      payload = websocket_payload(setup, "stale token should not reach upstream")

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{"error" => %{"code" => "stale_owner", "message" => message}} =
               CodexPooler.JSON.decode!(error_frame)

      assert message == "websocket owner lease is stale"
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(
        :closed,
        Map.delete(stale_state, :websocket_owner_downstream)
      )
    end

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    logs =
      capture_info_log(fn ->
        assert :ok = GenServer.stop(owner_pid, {:shutdown, :stale_owner})
        assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, {:shutdown, :stale_owner}}
      end)

    refute logs =~ "websocket owner exit persistence failed"
    assert logs =~ "owner_exit_reason=stale_owner"
    assert active_owner_lease(state.codex_session.id).lease_token == takeover_token
    assert_no_leak!("stale owner cleanup logs", logs)
  end

  test "remote owner nodedown fails closed without mutating active lease" do
    remote_node = :"codex_pooler@nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-nodedown",
        owner_instance_id: remote_node_string
      })

    lease = active_owner_lease(session.id)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               session,
               session.owner_lease_token,
               %{pid: self(), epoch: 1, correlation_id: "corr-nodedown"},
               CodexPooler.JSON.encode!(%{
                 "type" => "response.processed",
                 "response_id" => "resp_nodedown"
               }),
               opts
             )

    reloaded_lease = Repo.get!(BridgeOwnerLease, lease.id)
    assert reloaded_lease.status == "active"
    assert reloaded_lease.lease_token == lease.lease_token
    assert reloaded_lease.owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner socket init takes over an unavailable remote owner lease" do
    remote_node = :"codex_pooler@init-nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-nodedown",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    state = %{
      auth: auth,
      opts: %{
        request_id: "ws-owner-init-nodedown",
        accepted_turn_state: "stable-ws-owner-init-nodedown",
        client_ip: "127.0.0.1",
        websocket_owner_forwarder_opts: forwarder_opts
      }
    }

    logs =
      capture_info_log(fn ->
        assert {:ok, returned_state} = CodexResponsesSocket.init(state)
        assert returned_state.auth == auth
        assert returned_state.opts.request_id == state.opts.request_id
        assert returned_state.opts.accepted_turn_state == state.opts.accepted_turn_state
        assert returned_state.opts.client_ip == state.opts.client_ip
        assert returned_state.opts.websocket_owner_forwarder_opts == forwarder_opts

        assert returned_state.codex_session.id == session.id
        assert returned_state.codex_session.owner_lease_token != old_lease.lease_token
        assert returned_state.codex_session.owner_instance_id == Atom.to_string(node())

        assert returned_state.websocket_owner_lease_token ==
                 returned_state.codex_session.owner_lease_token

        assert returned_state.websocket_owner_downstream.epoch == 1

        CodexResponsesSocket.terminate(:closed, returned_state)
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    refute logs =~ "pinned_continuation_reauth_required"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=ws-owner-init-nodedown"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_forward_timeout"
    refute logs =~ "owner_crashed"
    assert_no_leak!("owner init nodedown takeover logs", logs)
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
             "owner_unavailable_takeover"

    assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
    assert FakeUpstream.count(upstream) == 0
  end

  test "successful owner socket init takeover stays below warning" do
    remote_node = :"codex_pooler@init-nodedown-warning-owner.example"
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, _session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-warning",
        owner_instance_id: Atom.to_string(remote_node)
      })

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    warning_logs =
      capture_log([level: :warning], fn ->
        assert {:ok, returned_state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts: %{
                     request_id: "ws-owner-init-warning",
                     accepted_turn_state: "stable-ws-owner-init-warning",
                     client_ip: "127.0.0.1",
                     websocket_owner_forwarder_opts: forwarder_opts
                   }
                 })

        CodexResponsesSocket.terminate(:closed, returned_state)
      end)

    assert warning_logs == ""
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :owner_forward_timeout
  test "remote owner attach timeout preserves owner_forward_timeout" do
    remote_node = :"codex_pooler@attach-timeout-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-attach-timeout",
        owner_instance_id: remote_node_string
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :timeout}
      )

    assert {:error, :owner_forward_timeout} =
             Gateway.prepare_websocket_session(auth, %{
               accepted_turn_state: "stable-ws-owner-attach-timeout",
               client_ip: "127.0.0.1",
               websocket_owner_forwarder_opts: Keyword.put(opts, :timeout, 25)
             })

    assert_receive {:websocket_owner_harness_node_call,
                    %{function: :remote_attach_downstream, timeout: 25}}

    assert active_owner_lease(session.id).owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :owner_forward_timeout
  test "owner socket init timeout closes normally while preserving owner error detail" do
    remote_node = :"codex_pooler@init-timeout-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-timeout",
        owner_instance_id: remote_node_string
      })

    request_id = "ws-owner-init-timeout"

    logs =
      capture_websocket_lifecycle_log(fn ->
        assert :ok =
                 WebsocketConnectionLogger.log_init_failed_before_request_reservation(
                   %{
                     request_id: request_id,
                     endpoint: "/backend-api/codex/responses",
                     transport: "websocket",
                     route_class: "proxy_websocket",
                     phase: "init",
                     elapsed_ms: 17,
                     codex_session_id: session.id,
                     owner_instance_id: remote_node_string,
                     proxy_instance_id: Atom.to_string(node())
                   },
                   :timeout
                 )
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        "websocket init failed before request reservation",
        ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(owner_instance_id proxy_instance_id)
      )

    expected_endpoint = String.replace("/backend-api/codex/responses", ~r/[^a-zA-Z0-9_.:-]+/, "_")
    expected_owner_instance_id = String.replace(remote_node_string, ~r/[^a-zA-Z0-9_.:-]+/, "_")

    expected_proxy_instance_id =
      String.replace(Atom.to_string(node()), ~r/[^a-zA-Z0-9_.:-]+/, "_")

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=#{expected_endpoint}"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "codex_session_id=#{session.id}"
    assert line =~ "owner_instance_id=#{expected_owner_instance_id}"
    assert line =~ "proxy_instance_id=#{expected_proxy_instance_id}"

    assert [] = request_logs(setup.pool.id)

    assert active_owner_lease(session.id).owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :owner_forward_nodedown
  test "remote owner attach nodedown takes over lease without leaking erpc details" do
    remote_node = :"codex_pooler@attach-nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-attach-nodedown",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :raw_nodedown}
      )

    logs =
      capture_info_log(fn ->
        assert {:ok, runtime} =
                 Gateway.prepare_websocket_session(auth, %{
                   accepted_turn_state: "stable-ws-owner-attach-nodedown",
                   client_ip: "127.0.0.1",
                   websocket_owner_forwarder_opts: opts
                 })

        assert runtime.codex_session.id == session.id
        assert runtime.codex_session.owner_lease_token != old_lease.lease_token
        assert runtime.codex_session.owner_instance_id == Atom.to_string(node())
        assert runtime.websocket_owner_downstream.epoch == 1

        Gateway.detach_websocket_owner_downstream(
          runtime.codex_session,
          runtime.websocket_owner_lease_token,
          runtime.websocket_owner_downstream,
          %{websocket_owner_forwarder_opts: opts}
        )
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_forward_timeout"
    refute logs =~ "owner_crashed"
    assert_no_leak!("owner attach nodedown takeover logs", logs)
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
             "owner_unavailable_takeover"

    assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner takeover failure remains warning and actionable without leaking lease token" do
    remote_node = :"codex_pooler@takeover-failure-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-takeover-failure",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)
    opts = stale_owner_node_client_opts([remote_node])

    logs =
      capture_log([level: :warning], fn ->
        assert {:error, :stale_owner} =
                 Gateway.prepare_websocket_session(auth, %{
                   accepted_turn_state: "stable-ws-owner-takeover-failure",
                   client_ip: "127.0.0.1",
                   websocket_owner_forwarder_opts: opts
                 })
      end)

    assert logs =~ "websocket owner takeover failed"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=investigate"
    assert logs =~ "outcome=failed"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "failure_reason=stale_owner"
    refute logs =~ old_lease.lease_token
    refute logs =~ "operator_action=none"
    assert_no_leak!("owner takeover failure logs", logs)
    assert FakeUpstream.count(upstream) == 0
  end

  test "role-neutral worker and scheduler nodes are not selected as owner targets" do
    remote_worker = :"codex_pooler@10.42.0.20"
    remote_scheduler = :"codex_pooler@10.42.0.21"
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, worker_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-role-worker",
        owner_instance_id: Atom.to_string(remote_worker)
      })

    {:ok, scheduler_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-role-scheduler",
        owner_instance_id: Atom.to_string(remote_scheduler)
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_worker, remote_scheduler],
        roles: %{remote_worker => "worker", remote_scheduler => "scheduler"}
      )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               worker_session,
               worker_session.owner_lease_token,
               downstream_target("corr-role-worker"),
               CodexPooler.JSON.encode!(%{
                 "type" => "response.processed",
                 "response_id" => "resp_role_worker"
               }),
               opts
             )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               scheduler_session,
               scheduler_session.owner_lease_token,
               downstream_target("corr-role-scheduler"),
               CodexPooler.JSON.encode!(%{
                 "type" => "response.processed",
                 "response_id" => "resp_role_scheduler"
               }),
               opts
             )

    assert_receive {:websocket_owner_harness_app_node_check,
                    %{node: ^remote_worker, role: "worker", app_node?: false}}

    assert_receive {:websocket_owner_harness_app_node_check,
                    %{node: ^remote_scheduler, role: "scheduler", app_node?: false}}

    refute_received {:websocket_owner_harness_node_call, %{node: ^remote_worker}}
    refute_received {:websocket_owner_harness_node_call, %{node: ^remote_scheduler}}
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner-forwarded turn takes over when the local owner disappears after socket init" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_dispatch_takeover"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-dispatch-takeover", "dispatch-takeover",
        forwarded_headers: [
          {"session-id", "owner-takeover-session"},
          {"thread-id", "owner-takeover-thread"},
          {"x-client-request-id", "owner-takeover-thread"}
        ]
      )

    session = state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}

    try do
      {{:ok, _handled_state, frame}, warning_logs} =
        with_log([level: :warning], fn ->
          payload = websocket_payload(setup, "dispatch takeover")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
          assert {:ok, state} = receive_socket_done(state)

          {:ok, state, frame}
        end)

      assert warning_logs == ""
      assert %{"id" => "resp_owner_dispatch_takeover"} = CodexPooler.JSON.decode!(frame)
      assert active_owner_lease(session.id).lease_token == old_lease.lease_token
      assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
      assert [request] = await_upstream_requests(upstream, 1)
      assert request.json["input"] |> List.first() |> Map.get("content") == "dispatch takeover"

      assert Map.new(request.headers)["x-codex-routing-hint"] ==
               "model=#{setup.model.upstream_model_id}"

      assert %{
               "session-id" => "owner-takeover-session",
               "thread-id" => "owner-takeover-thread",
               "x-client-request-id" => "owner-takeover-thread"
             } =
               Map.take(Map.new(request.headers), [
                 "session-id",
                 "thread-id",
                 "x-client-request-id"
               ])

      assert [request_log] = request_logs(setup.pool.id)
      assert request_log.status == "succeeded"
      assert request_log.response_status_code == 200
      assert is_nil(request_log.last_error_code)

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_log.id))
      assert attempt.status == "succeeded"
      assert attempt.upstream_status_code == 200
      assert is_nil(attempt.network_error_code)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded turn takes over when local owner drained after socket init" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_dispatch_drain_takeover"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-dispatch-drain-takeover", "dispatch-drain")
    session = state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    :ok = GenServer.stop(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    logs =
      capture_info_log(fn ->
        try do
          payload = websocket_payload(setup, "dispatch drain takeover")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
          assert %{"id" => "resp_owner_dispatch_drain_takeover"} = CodexPooler.JSON.decode!(frame)
          assert {:ok, _state} = receive_socket_done(state)

          active_lease = active_owner_lease(session.id)
          assert active_lease.lease_token != old_lease.lease_token
          assert active_lease.owner_instance_id == Atom.to_string(node())

          assert [request] = await_upstream_requests(upstream, 1)

          assert request.json["input"] |> List.first() |> Map.get("content") ==
                   "dispatch drain takeover"

          assert [request_log] = request_logs(setup.pool.id)
          assert request_log.status == "succeeded"
          assert request_log.response_status_code == 200
          assert is_nil(request_log.last_error_code)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=ws-owner-dispatch-drain-takeover"
    assert logs =~ "previous_owner_instance_id=#{Atom.to_string(node())}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_crashed"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] == "owner_drained"

    assert_no_leak!("local drain dispatch takeover logs", logs)
  end

  test "owner-forwarded socket replaces a local owner with a dead upstream before first dispatch" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_upstream"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} = owner_socket(auth, "ws-owner-stale-upstream-first", "stale-upstream")
    session = first_state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    %{upstream_pid: upstream_pid} = :sys.get_state(owner_pid)
    upstream_ref = Process.monitor(upstream_pid)
    Process.exit(upstream_pid, :kill)
    assert_receive {:DOWN, ^upstream_ref, :process, ^upstream_pid, :killed}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, _owner_reason}

    {:ok, second_state} = owner_socket(auth, "ws-owner-stale-upstream-second", "stale-upstream")

    try do
      {:ok, replacement_owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert replacement_owner_pid != owner_pid
      replacement_lease = active_owner_lease(session.id)
      assert replacement_lease.lease_token != old_lease.lease_token
      assert replacement_lease.lease_token == second_state.websocket_owner_lease_token
      assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

      assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
               "owner_crashed"

      assert second_state.websocket_owner_downstream.epoch == 1

      payload = websocket_payload(setup, "after stale upstream")

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

      assert {:push, {:text, frame}, second_state} = receive_owner_socket_push(second_state)
      assert %{"id" => "resp_owner_stale_upstream"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [request] = await_upstream_requests(upstream, 1)
      assert request.json["input"] |> List.first() |> Map.get("content") == "after stale upstream"
      assert FakeUpstream.count(upstream) == 1

      assert [request_log] = request_logs(setup.pool.id)
      assert request_log.status == "succeeded"
      assert_forwarding_cardinality!(request_log, session.id, "succeeded")
      refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
    after
      CodexResponsesSocket.terminate(:closed, first_state)
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  defp stale_owner_node_client_opts(nodes) when is_list(nodes) do
    previous = Process.get(StaleOwnerNodeClient)
    Process.put(StaleOwnerNodeClient, %{nodes: nodes})

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Process.delete(StaleOwnerNodeClient)
        value -> Process.put(StaleOwnerNodeClient, value)
      end
    end)

    [node_client: StaleOwnerNodeClient]
  end
end
