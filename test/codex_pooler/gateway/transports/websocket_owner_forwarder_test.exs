defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarderTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

  @frame "synthetic-frame"

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

    request = %UpstreamWebSocketSession.Request{
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

    assert [%UpstreamWebSocketSession.Request{payload: "request-frame"}] =
             WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid)

    assert_receive {:websocket_owner_frame, "corr-recovered-owner", 1, {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "corr-recovered-owner", 1, :complete}
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
      websocket_frame_headers: %{}
    }

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, {:error, structured_error}}}
      )

    request = %UpstreamWebSocketSession.Request{
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

    assert :ok =
             Gateway.detach_websocket_owner_downstream(
               session,
               token,
               stale_downstream,
               gateway_opts
             )

    assert :ok =
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

  defp existing_atom?(value) do
    _atom = :erlang.binary_to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
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
