defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarderTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway

  @epmd_ready_timeout_ms 2_000
  @epmd_ready_poll_ms 10
  @frame "synthetic-frame"

  setup_all do
    started_epmd? = ensure_epmd_started!()
    on_exit(fn -> if started_epmd?, do: stop_epmd!() end)
    :ok
  end

  setup do
    reset_bootstrap_state_fixture!()
    auth = auth_fixture()
    on_exit(&cleanup_local_owner_sessions/0)
    {:ok, auth: auth}
  end

  test "local owner resolution submits to local WebsocketOwnerSession", %{auth: auth} do
    %{session: session, token: token} = owner_session_fixture(auth, Atom.to_string(node()))
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), messages: ["local-delta"])
    {:ok, _owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    downstream = attach_downstream(session.id, "corr-local")

    assert :ok = WebsocketOwnerForwarder.submit_frame(session, token, downstream, @frame)

    assert WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid) == [@frame]
    assert_receive {:websocket_owner_frame, "corr-local", 1, {:data, "local-delta"}}
    assert_receive {:websocket_owner_frame, "corr-local", 1, :complete}
  end

  test "remote success reaches simulated owner and returns owner result", %{auth: auth} do
    remote_node = :"codex_pooler@owner-app.example"
    remote_node_string = Atom.to_string(remote_node)
    %{session: session, token: token} = owner_session_fixture(auth, remote_node_string)

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), messages: ["remote-delta"])

    {:ok, _owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    downstream = attach_downstream(session.id, "corr-remote")

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    assert :ok =
             WebsocketOwnerForwarder.submit_frame(session, token, downstream, @frame, opts)

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_frame}}

    assert WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid) == [@frame]
    assert_receive {:websocket_owner_frame, "corr-remote", 1, {:data, "remote-delta"}}
    assert_receive {:websocket_owner_frame, "corr-remote", 1, :complete}
  end

  test "remote request recovers missing owner on the owner node", %{auth: auth} do
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings)
    idle_shutdown_ms = 120

    on_exit(fn -> restore_operational_settings(previous_operational_settings) end)
    put_owner_idle_timeout(idle_shutdown_ms)

    remote_node = :"codex_pooler@recover-owner-app.example"
    remote_node_string = Atom.to_string(remote_node)
    %{session: session, token: token} = owner_session_fixture(auth, remote_node_string)

    terminal_frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_recovered_owner",
          "usage" => %{"input_tokens" => 7, "output_tokens" => 5, "total_tokens" => 12}
        }
      })

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true
      )

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )
      |> Keyword.put(:local_node_string, remote_node_string)
      |> Keyword.put(:upstream, upstream)

    request = %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "request-frame",
      timeouts: %{}
    }

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               downstream("corr-recovered-owner"),
               request,
               opts
             )

    assert body =~ "resp_recovered_owner"

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request, arity: 4}}

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert [%UpstreamWebsocketSession.Request{payload: "request-frame"}] =
             WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid)

    assert_receive {:websocket_owner_frame, "corr-recovered-owner", 1, {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "corr-recovered-owner", 1, :complete}

    assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(session.id)
    assert %{idle_shutdown_ms: ^idle_shutdown_ms} = :sys.get_state(recovered_owner)

    new_idle_shutdown_ms = 240
    put_owner_idle_timeout(new_idle_shutdown_ms)

    assert {:ok, existing_owner} = WebsocketOwnerSession.lookup(session.id)
    assert existing_owner == recovered_owner
    assert %{idle_shutdown_ms: ^idle_shutdown_ms} = :sys.get_state(existing_owner)

    %{session: new_session, token: new_token} =
      owner_session_fixture(auth, remote_node_string, "recover-owner-new")

    assert {:ok, %{body: new_body, terminal: "response.completed", status: 200}} =
             WebsocketOwnerForwarder.submit_request(
               new_session,
               new_token,
               downstream("corr-recovered-owner-new"),
               request,
               opts
             )

    assert new_body =~ "resp_recovered_owner"

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request, arity: 4}}

    assert_receive {:websocket_owner_harness_upstream_started, new_upstream_pid}

    assert [%UpstreamWebsocketSession.Request{payload: "request-frame"}] =
             WebsocketOwnerNodeHarness.fake_upstream_frames(new_upstream_pid)

    assert {:ok, new_owner} = WebsocketOwnerSession.lookup(new_session.id)
    assert new_owner != recovered_owner
    assert %{idle_shutdown_ms: ^new_idle_shutdown_ms} = :sys.get_state(new_owner)
  end

  test "guarded bridge attach and request traverse the remote owner boundary", %{auth: auth} do
    remote_node = :"codex_pooler@bridge-owner-app.example"
    remote_node_string = Atom.to_string(remote_node)
    %{session: session, token: token} = owner_session_fixture(auth, remote_node_string)

    terminal_frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_remote_bridge", "status" => "completed"}
      })

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true
      )

    {:ok, _owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    attach_args =
      WebsocketOwnerForwarder.remote_attach_args(
        session.id,
        downstream("corr-remote-bridge"),
        reject_if_busy: true
      )

    assert {:ok, %{correlation_id: "corr-remote-bridge", epoch: epoch} = attached} =
             WebsocketOwnerForwarder.call_remote(
               remote_node,
               :remote_attach_downstream,
               attach_args,
               opts
             )

    assert is_integer(epoch)

    request = %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "bridge-request-frame",
      timeouts: %{}
    }

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             WebsocketOwnerForwarder.submit_request(session, token, attached, request, opts)

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_attach_downstream, arity: 3}}

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request, arity: 4}}

    assert [%UpstreamWebsocketSession.Request{payload: "bridge-request-frame"}] =
             WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid)

    assert_receive {:websocket_owner_frame, "corr-remote-bridge", ^epoch,
                    {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "corr-remote-bridge", ^epoch, :complete}
  end

  test "remote request preserves structured upstream failure maps", %{auth: auth} do
    remote_node = :"codex_pooler@structured-error-app.example"
    remote_node_string = Atom.to_string(remote_node)

    %{session: session, token: token} =
      owner_session_fixture(auth, remote_node_string, "structured")

    structured_error = %{
      body: Jason.encode!(%{"type" => "response.failed"}),
      reason: {:auth_refresh_first_event, %{code: "invalid_api_key"}},
      headers: [],
      upstream_error_param: "reasoning.effort",
      websocket_frame_headers: %{}
    }

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, {:error, structured_error}}}
      )

    request = %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "request-frame",
      timeouts: %{}
    }

    assert {:error, ^structured_error} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               downstream("corr-structured-error"),
               request,
               opts
             )
  end

  test "remote timeout maps to owner_forward_timeout within configured timeout", %{auth: auth} do
    remote_node = :"codex_pooler@timeout-app.example"
    remote_node_string = Atom.to_string(remote_node)
    %{session: session, token: token} = owner_session_fixture(auth, remote_node_string)
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {:ok, _owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    downstream = attach_downstream(session.id, "corr-timeout")

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :timeout}
      )

    started = System.monotonic_time(:millisecond)

    assert {:error, :owner_forward_timeout} =
             WebsocketOwnerForwarder.submit_frame(
               session,
               token,
               downstream,
               @frame,
               Keyword.put(opts, :timeout, 25)
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 250
    refute_receive {:websocket_owner_frame, "corr-timeout", 1, _payload}
  end

  test "nodedown and crash map to safe owner errors", %{auth: auth} do
    nodedown_node = :"codex_pooler@nodedown-app.example"
    crash_node = :"codex_pooler@crash-app.example"

    %{session: nodedown_session, token: nodedown_token} =
      owner_session_fixture(auth, Atom.to_string(nodedown_node), "nodedown")

    %{session: crash_session, token: crash_token} =
      owner_session_fixture(auth, Atom.to_string(crash_node), "crash")

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([nodedown_node, crash_node],
        calls: %{nodedown_node => :nodedown, crash_node => :crash}
      )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               nodedown_session,
               nodedown_token,
               downstream("corr-nodedown"),
               @frame,
               opts
             )

    assert {:error, :owner_crashed} =
             WebsocketOwnerForwarder.submit_frame(
               crash_session,
               crash_token,
               downstream("corr-crash"),
               @frame,
               opts
             )
  end

  test "call_remote normalizes raw erpc timeout and connection failures", %{auth: auth} do
    timeout_node = :"codex_pooler@raw-timeout.example"
    noconnection_node = :"codex_pooler@raw-noconnection.example"
    noproc_node = :"codex_pooler@raw-noproc.example"
    nodedown_node = :"codex_pooler@raw-nodedown.example"

    %{session: session} = owner_session_fixture(auth, Atom.to_string(timeout_node), "raw")

    opts =
      WebsocketOwnerNodeHarness.node_client_opts(
        [timeout_node, noconnection_node, noproc_node, nodedown_node],
        calls: %{
          timeout_node => :raw_timeout,
          noconnection_node => :raw_noconnection,
          noproc_node => :raw_noproc,
          nodedown_node => :raw_nodedown
        }
      )

    assert {:error, :owner_forward_timeout} =
             WebsocketOwnerForwarder.call_remote(
               timeout_node,
               :remote_attach_downstream,
               [session.id, downstream("corr-raw-timeout")],
               Keyword.put(opts, :timeout, 25)
             )

    for {node, correlation_id} <- [
          {noconnection_node, "corr-raw-noconnection"},
          {noproc_node, "corr-raw-noproc"},
          {nodedown_node, "corr-raw-nodedown"}
        ] do
      assert {:error, :owner_unavailable} =
               WebsocketOwnerForwarder.call_remote(
                 node,
                 :remote_attach_downstream,
                 [session.id, downstream(correlation_id)],
                 opts
               )
    end
  end

  test "gateway remote detach treats stale downstream as caller safe", %{auth: auth} do
    remote_node = :"codex_pooler@detach-stale-app.example"
    remote_node_string = Atom.to_string(remote_node)

    %{session: session, token: token} =
      owner_session_fixture(auth, remote_node_string, "detach-stale")

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), messages: ["after-stale-detach"])

    {:ok, _owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    assert {:ok, stale_downstream} =
             WebsocketOwnerForwarder.call_remote(
               remote_node,
               :remote_attach_downstream,
               [session.id, downstream("corr-stale-detach")],
               opts
             )

    assert {:ok, current_downstream} =
             WebsocketOwnerForwarder.call_remote(
               remote_node,
               :remote_attach_downstream,
               [session.id, downstream("corr-current-detach")],
               opts
             )

    gateway_opts = %{websocket_owner_forwarder_opts: opts}

    assert :detached_stale_downstream =
             Gateway.detach_websocket_owner_downstream(
               session,
               token,
               stale_downstream,
               gateway_opts
             )

    assert :detached_stale_downstream =
             Gateway.detach_websocket_owner_downstream(
               session,
               token,
               stale_downstream,
               gateway_opts
             )

    assert :ok =
             WebsocketOwnerForwarder.submit_frame(
               session,
               token,
               current_downstream,
               @frame,
               opts
             )

    assert_receive {:websocket_owner_frame, "corr-current-detach", 2,
                    {:data, "after-stale-detach"}}
  end

  test "unknown malicious owner_instance_id does not create atoms", %{auth: auth} do
    malicious_owner =
      "malicious-owner-#{System.unique_integer([:positive])}@not-connected.example"

    %{session: session, token: token} = owner_session_fixture(auth, malicious_owner)
    refute existing_atom?(malicious_owner)

    opts = WebsocketOwnerNodeHarness.node_client_opts([])

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               session,
               token,
               downstream("corr-malicious"),
               @frame,
               opts
             )

    refute existing_atom?(malicious_owner)
  end

  test "worker scheduler and migration node strings are rejected even when connected", %{
    auth: auth
  } do
    role_nodes = [
      :"codex_pooler@sample-worker-0.cluster.local",
      :"codex_pooler@sample-scheduler-0.cluster.local",
      :"codex_pooler@sample-migration-0.cluster.local"
    ]

    opts = WebsocketOwnerNodeHarness.node_client_opts(role_nodes)

    for {node, suffix} <- Enum.with_index(role_nodes) do
      %{session: session, token: token} =
        owner_session_fixture(auth, Atom.to_string(node), "role-#{suffix}")

      assert {:error, :owner_unavailable} =
               WebsocketOwnerForwarder.submit_frame(
                 session,
                 token,
                 downstream("corr-role-#{suffix}"),
                 @frame,
                 opts
               )
    end

    refute_received {:websocket_owner_harness_node_call, _call}
  end

  test "remote attach args keep the two-argument shape for option-less attaches" do
    downstream = %{pid: self(), correlation_id: "corr-rolling-deploy"}

    # Rolling-deploy compatibility: an owner node on the previous release only
    # exports remote_attach_downstream/2, so native attaches must not grow a
    # third argument. Only option-carrying (bridge) attaches use arity 3.
    assert WebsocketOwnerForwarder.remote_attach_args("session-a", downstream, []) ==
             ["session-a", downstream]

    assert WebsocketOwnerForwarder.remote_attach_args("session-a", downstream,
             reject_if_busy: true
           ) ==
             ["session-a", downstream, [reject_if_busy: true]]

    Code.ensure_loaded!(WebsocketOwnerForwarder)
    assert function_exported?(WebsocketOwnerForwarder, :remote_attach_downstream, 2)
    assert function_exported?(WebsocketOwnerForwarder, :remote_attach_downstream, 3)
  end

  test "real peer owner captures its node-local timeout and recovery captures the recovering node timeout",
       %{auth: auth} do
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings)
    on_exit(fn -> restore_operational_settings(previous_operational_settings) end)

    peer_node = start_current_peer!("settings_owner")
    owner_timeout = 180_001
    proxy_timeout = 240_002
    changed_owner_timeout = 300_003
    recovery_timeout = 360_004

    assert :ok =
             :erpc.call(
               peer_node,
               WebsocketOwnerNodeHarness,
               :put_owner_idle_timeout,
               [owner_timeout]
             )

    put_owner_idle_timeout(proxy_timeout)
    assert OperationalSettings.current().websocket_owner_idle_timeout_ms == proxy_timeout

    upstream =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_upstream_boundary, [
        self(),
        []
      ])

    persistence =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    session_id = "real-peer-node-local-owner"

    assert {:ok, owner_pid} =
             :erpc.call(
               peer_node,
               WebsocketOwnerNodeHarness,
               :start_owner_with_local_idle_timeout,
               [
                 [
                   codex_session_id: session_id,
                   owner_lease_token: "synthetic-owner-token",
                   owner_instance_id: Atom.to_string(peer_node),
                   owner_renewal_ms: 60_000,
                   upstream: upstream,
                   persistence: persistence
                 ]
               ]
             )

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}
    assert node(owner_pid) == peer_node

    assert owner_timeout ==
             :erpc.call(
               peer_node,
               WebsocketOwnerNodeHarness,
               :owner_idle_timeout,
               [owner_pid]
             )

    client = WebsocketOwnerForwarder.ERPCNodeClient

    assert {:ok, attached} =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_attach_downstream,
               [session_id, downstream("corr-node-local-owner")],
               2_000
             )

    proxy_args = [session_id, attached, @frame, []]
    assert [^session_id, ^attached, @frame, []] = proxy_args

    assert :ok =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_submit_frame,
               proxy_args,
               2_000
             )

    assert_receive {:websocket_owner_harness_upstream_sent, ^upstream_pid}

    assert :ok =
             :erpc.call(
               peer_node,
               WebsocketOwnerNodeHarness,
               :put_owner_idle_timeout,
               [changed_owner_timeout]
             )

    put_owner_idle_timeout(recovery_timeout)

    assert %{websocket_owner_idle_timeout_ms: ^changed_owner_timeout} =
             :erpc.call(peer_node, OperationalSettings, :current, [])

    assert OperationalSettings.current().websocket_owner_idle_timeout_ms == recovery_timeout

    assert owner_timeout ==
             :erpc.call(
               peer_node,
               WebsocketOwnerNodeHarness,
               :owner_idle_timeout,
               [owner_pid]
             )

    %{session: recovered_session} =
      owner_session_fixture(auth, Atom.to_string(node()), "real-peer-recovery")

    recovery_frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_recovery_setting"}
      })

    recovery_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [recovery_frame],
        return_request_result?: true
      )

    request = request("real-peer-recovery-request")

    assert {:ok, %{status: 200, terminal: "response.completed"}} =
             WebsocketOwnerForwarder.remote_submit_request(
               recovered_session.id,
               downstream("corr-real-peer-recovery"),
               request,
               upstream: recovery_upstream,
               local_node_string: Atom.to_string(node())
             )

    assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(recovered_session.id)
    assert %{idle_shutdown_ms: ^recovery_timeout} = :sys.get_state(recovered_owner)
  end

  test "a real peer running the previous attach API accepts native arity and rejects bridge arity" do
    ensure_test_distribution_started!()

    peer_name = String.to_atom("old_owner_#{System.unique_integer([:positive])}")
    assert {:ok, peer_pid, peer_node} = :peer.start_link(%{name: peer_name})
    Process.unlink(peer_pid)

    on_exit(fn -> stop_peer(peer_pid) end)

    module = WebsocketOwnerForwarder
    {:ok, ^module, beam} = previous_release_forwarder_beam(module)

    assert {:module, ^module} =
             :erpc.call(peer_node, :code, :load_binary, [module, ~c"previous_release.ex", beam])

    client = WebsocketOwnerForwarder.ERPCNodeClient
    downstream = downstream("corr-real-peer")

    assert {:ok, :old_release_attach_ok} =
             client.call_owner(
               peer_node,
               module,
               :remote_attach_downstream,
               ["session-real-peer", downstream],
               2_000
             )

    assert {:error, :owner_crashed} =
             client.call_owner(
               peer_node,
               module,
               :remote_attach_downstream,
               ["session-real-peer", downstream, [reject_if_busy: true]],
               2_000
             )
  end

  test "guarded bridge attach and request relay across a real current-release peer" do
    ensure_test_distribution_started!()

    peer_name = String.to_atom("current_owner_#{System.unique_integer([:positive])}")
    assert {:ok, peer_pid, peer_node} = :peer.start_link(%{name: peer_name})
    Process.unlink(peer_pid)

    on_exit(fn -> stop_peer(peer_pid) end)

    assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    assert {:ok, runtime_pid} =
             :erpc.call(peer_node, WebsocketOwnerNodeHarness, :start_owner_runtime, [])

    assert node(runtime_pid) == peer_node

    terminal_frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_real_peer_bridge", "status" => "completed"}
      })

    upstream =
      :erpc.call(
        peer_node,
        WebsocketOwnerNodeHarness,
        :fake_upstream_boundary,
        [self(), [messages: [terminal_frame], return_request_result?: true]]
      )

    persistence =
      :erpc.call(
        peer_node,
        WebsocketOwnerNodeHarness,
        :fake_persistence_boundary,
        []
      )

    session_id = "real-peer-bridge-session"

    assert {:ok, owner_pid} =
             :erpc.call(peer_node, WebsocketOwnerSession, :start_owner, [
               [
                 codex_session_id: session_id,
                 owner_lease_token: "real-peer-owner-token",
                 owner_instance_id: Atom.to_string(peer_node),
                 owner_renewal_ms: 60_000,
                 upstream: upstream,
                 persistence: persistence
               ]
             ])

    assert node(owner_pid) == peer_node
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}
    assert node(upstream_pid) == peer_node

    downstream = downstream("corr-real-peer-bridge")
    client = WebsocketOwnerForwarder.ERPCNodeClient

    assert {:ok, %{epoch: epoch} = attached} =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_attach_downstream,
               [session_id, downstream, [reject_if_busy: true]],
               2_000
             )

    request = %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "real-peer-bridge-request",
      timeouts: %{}
    }

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_submit_request,
               [session_id, attached, request, []],
               2_000
             )

    assert_receive {:websocket_owner_harness_upstream_sent, ^upstream_pid}

    assert_receive {:websocket_owner_frame, "corr-real-peer-bridge", ^epoch,
                    {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "corr-real-peer-bridge", ^epoch, :complete}
  end

  test "attaching through an old-release owner node fails closed for the bridge and still serves native attaches",
       %{auth: auth} do
    remote_node = :"codex_pooler@old-release-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    %{session: session} = owner_session_fixture(auth, remote_node_string)

    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), messages: [])
    {:ok, _owner} = start_owner(session, upstream)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :old_release}
      )

    # This is verbatim the proxy-side remote attach: websocket.ex calls
    # call_remote(:remote_attach_downstream, remote_attach_args(...)). The
    # option-carrying bridge attach hits the missing /3 on the old node and
    # must map the :erpc undef to a fail-closed owner error so the bridge
    # falls back to HTTP instead of committing.
    bridge_args =
      WebsocketOwnerForwarder.remote_attach_args(
        session.id,
        downstream("corr-old-release-bridge"),
        reject_if_busy: true
      )

    assert {:error, :owner_crashed} =
             WebsocketOwnerForwarder.call_remote(
               remote_node,
               :remote_attach_downstream,
               bridge_args,
               opts
             )

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_attach_downstream, arity: 3}}

    # The option-less native attach keeps the two-argument shape the old
    # release exports and reaches the real owner process end to end.
    native_args =
      WebsocketOwnerForwarder.remote_attach_args(
        session.id,
        downstream("corr-old-release-native"),
        []
      )

    assert {:ok, %{correlation_id: "corr-old-release-native", epoch: epoch}} =
             WebsocketOwnerForwarder.call_remote(
               remote_node,
               :remote_attach_downstream,
               native_args,
               opts
             )

    assert is_integer(epoch)

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_attach_downstream, arity: 2}}
  end

  test "disconnected remote owner string maps to owner_unavailable", %{auth: auth} do
    remote_node = :"codex_pooler@known-app.example"
    disconnected_node = :"codex_pooler@disconnected-app.example"

    %{session: session, token: token} =
      owner_session_fixture(auth, Atom.to_string(disconnected_node))

    opts = WebsocketOwnerNodeHarness.node_client_opts([remote_node])

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               session,
               token,
               downstream("corr-disconnected"),
               @frame,
               opts
             )
  end

  test "delayed owner completion after proxy timeout produces no late downstream frames", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@delayed-app.example"
    remote_node_string = Atom.to_string(remote_node)
    %{session: session, token: token} = owner_session_fixture(auth, remote_node_string)
    release_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: ["late-delta"]
      )

    {:ok, _owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:delayed_success, self(), release_ref}}
      )

    assert {:error, :owner_forward_timeout} =
             WebsocketOwnerForwarder.submit_frame(
               session,
               token,
               downstream("corr-late"),
               @frame,
               Keyword.put(opts, :timeout, 25)
             )

    assert_receive {:websocket_owner_harness_delayed_started, delayed_pid, ^release_ref}
    send(delayed_pid, {:websocket_owner_harness_release_delayed, release_ref})

    assert_receive {:websocket_owner_harness_delayed_result, ^release_ref,
                    {:error, :stale_downstream}}

    refute_receive {:websocket_owner_frame, "corr-late", 1, _payload}
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp owner_session_fixture(auth, owner_instance_id, suffix \\ "owner") do
    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "forwarder-#{suffix}-#{System.unique_integer([:positive])}",
               owner_instance_id: owner_instance_id
             })

    session = Repo.get!(CodexSession, session.id)
    %{session: session, token: session.owner_lease_token}
  end

  defp start_owner(session, upstream) do
    WebsocketOwnerSession.start_owner(
      codex_session_id: session.id,
      owner_lease_token: session.owner_lease_token,
      owner_instance_id: session.owner_instance_id,
      upstream: upstream
    )
  end

  defp attach_downstream(codex_session_id, correlation_id) do
    {:ok, owner} = WebsocketOwnerSession.lookup(codex_session_id)
    {:ok, downstream} = WebsocketOwnerSession.attach_downstream(owner, downstream(correlation_id))
    downstream
  end

  defp downstream(correlation_id), do: %{pid: self(), epoch: 1, correlation_id: correlation_id}

  defp request(payload) do
    %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: payload,
      timeouts: %{}
    }
  end

  defp put_owner_idle_timeout(timeout) do
    settings = OperationalSettings.current()

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %{settings | websocket_owner_idle_timeout_ms: timeout}
    )
  end

  defp restore_operational_settings(nil),
    do: Application.delete_env(:codex_pooler, OperationalSettings)

  defp restore_operational_settings(previous_settings),
    do: Application.put_env(:codex_pooler, OperationalSettings, previous_settings)

  defp existing_atom?(value) do
    _atom = :erlang.binary_to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end

  defp ensure_test_distribution_started!, do: start_test_distribution!(node())

  defp start_test_distribution!(:nonode@nohost) do
    node_name = String.to_atom("codex_pooler_test_#{System.unique_integer([:positive])}")
    assert {:ok, _pid} = :net_kernel.start([node_name, :shortnames])

    on_exit(fn -> assert :ok = :net_kernel.stop() end)
  end

  defp start_test_distribution!(_distributed_node), do: :ok

  defp start_current_peer!(prefix) do
    {_peer_pid, peer_node} = start_current_peer_process!(prefix)
    peer_node
  end

  defp start_current_peer_process!(prefix) do
    ensure_test_distribution_started!()

    peer_name = String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
    assert {:ok, peer_pid, peer_node} = :peer.start_link(%{name: peer_name})
    Process.unlink(peer_pid)
    on_exit(fn -> stop_peer(peer_pid) end)

    assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    assert {:ok, runtime_pid} =
             :erpc.call(peer_node, WebsocketOwnerNodeHarness, :start_owner_runtime, [])

    assert node(runtime_pid) == peer_node
    {peer_pid, peer_node}
  end

  defp ensure_epmd_started! do
    case :erl_epmd.names() do
      {:ok, _names} ->
        false

      {:error, _reason} ->
        assert {_output, 0} = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
        await_epmd!(System.monotonic_time(:millisecond) + @epmd_ready_timeout_ms)
        true
    end
  end

  defp await_epmd!(deadline) do
    case :erl_epmd.names() do
      {:ok, _names} -> :ok
      {:error, _reason} = error -> retry_epmd_readiness!(error, deadline)
    end
  end

  defp retry_epmd_readiness!(error, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        @epmd_ready_poll_ms -> await_epmd!(deadline)
      end
    else
      flunk("EPMD did not become ready: #{inspect(error)}")
    end
  end

  defp stop_epmd! do
    assert {_output, 0} = System.cmd("epmd", ["-kill"], stderr_to_stdout: true)
    :ok
  end

  defp previous_release_forwarder_beam(module) do
    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [remote_attach_downstream: 2]},
      {:function, 1, :remote_attach_downstream, 2,
       [
         {:clause, 1, [{:var, 1, :_Session}, {:var, 1, :_Downstream}], [],
          [{:tuple, 1, [{:atom, 1, :ok}, {:atom, 1, :old_release_attach_ok}]}]}
       ]}
    ]

    :compile.forms(forms, [:binary])
  end

  defp stop_peer(peer_pid) do
    if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp cleanup_local_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn codex_session_id ->
        try do
          with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
            _result = GenServer.stop(owner_pid, :shutdown, 1_000)
          end
        catch
          :exit, _reason -> :ok
        end
      end)
    end)

    :ok
  end
end
