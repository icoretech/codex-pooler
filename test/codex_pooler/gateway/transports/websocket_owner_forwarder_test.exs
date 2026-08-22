defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarderTest do
  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.{ResetProbe, TimeoutConfig}
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Transports.WebsocketOwnerPreviousReleaseCaller
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPoolerWeb.CodexResponsesSocket

  @epmd_ready_timeout_ms 2_000
  @epmd_ready_poll_ms 10
  @frame "synthetic-frame"
  @peer_detection_timeout_ms 10_000
  @timeouts %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}

  setup_all do
    ensure_epmd_started!()
    :ok
  end

  setup do
    reset_bootstrap_state_fixture!()
    auth = auth_fixture()
    Process.put({__MODULE__, :upstream_identity}, active_upstream_identity_fixture())
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

  test "local missing-owner recovery receives the caller options", %{auth: auth} do
    local_node_string = Atom.to_string(node())
    %{session: session, token: token} = owner_session_fixture(auth, local_node_string)

    terminal_frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_local_recovery_options"}
      })

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true
      )

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               downstream("corr-local-recovery-options"),
               request("local-recovery-options"),
               upstream: upstream,
               request_id: "local-recovery-options"
             )

    assert body =~ "resp_local_recovery_options"
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}
  end

  @tag :rollout_drain_t3
  test "T3 marker refuses target-side missing-owner resurrection", %{auth: auth} do
    local_node_string = Atom.to_string(node())
    %{session: session, token: token} = owner_session_fixture(auth, local_node_string)
    original_lease = Repo.get_by!(BridgeOwnerLease, lease_token: token)

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame("resp_marker_must_not_run")],
        return_request_result?: true
      )

    _marker_path = WebsocketRolloutDrainSupport.configure_drain_marker!()

    assert {:error, :owner_drained} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               downstream("corr-marker-resurrection"),
               request("marker-resurrection"),
               upstream: upstream,
               request_id: "marker-resurrection"
             )

    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(session.id)
    refute_received {:websocket_owner_harness_upstream_started, _upstream_pid}
    assert Repo.get!(CodexSession, session.id).owner_lease_token == token
    assert Repo.get!(BridgeOwnerLease, original_lease.id).status == "active"
  end

  @tag :rollout_drain_t3
  test "T3 marker refuses crashed-owner takeover before visible output", %{auth: auth} do
    local_node_string = Atom.to_string(node())
    %{session: session, token: token} = owner_session_fixture(auth, local_node_string)
    original_lease = Repo.get_by!(BridgeOwnerLease, lease_token: token)
    parent = self()
    release_ref = make_ref()

    first_upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:marker_takeover_submit_started, self(), release_ref})

        receive do
          {:release_marker_takeover_submit, ^release_ref} -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      end
    }

    {:ok, first_owner} = start_owner(session, first_upstream)

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(
               first_owner,
               downstream("corr-marker-takeover")
             )

    recovery_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame("resp_marker_takeover_must_not_run")],
        return_request_result?: true
      )

    submitter =
      Task.async(fn ->
        WebsocketOwnerForwarder.submit_request(
          session,
          token,
          stable_downstream,
          request("marker-takeover"),
          upstream: recovery_upstream,
          local_node_string: local_node_string,
          request_id: "marker-takeover"
        )
      end)

    assert_receive {:marker_takeover_submit_started, first_worker, ^release_ref}
    _marker_path = WebsocketRolloutDrainSupport.configure_drain_marker!()

    first_owner_ref = Process.monitor(first_owner)
    Process.exit(first_owner, :kill)
    assert_receive {:DOWN, ^first_owner_ref, :process, ^first_owner, :killed}
    send(first_worker, {:release_marker_takeover_submit, release_ref})

    assert Task.await(submitter, 2_000) == {:error, :owner_drained}
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(session.id)
    refute_received {:websocket_owner_runtime_recovered, _, _, _}
    refute_received {:websocket_owner_harness_upstream_started, _recovery_upstream_pid}
    assert Repo.get!(CodexSession, session.id).owner_lease_token == token
    assert Repo.get!(BridgeOwnerLease, original_lease.id).status == "active"

    assert Repo.aggregate(
             from(lease in BridgeOwnerLease,
               where: lease.codex_session_id == ^session.id and lease.status == "active"
             ),
             :count
           ) == 1
  end

  test "bound reset probe does not recover a missing local owner", %{auth: auth} do
    local_node_string = Atom.to_string(node())
    %{session: session} = owner_session_fixture(auth, local_node_string)

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame("resp_bound_missing_owner")],
        return_request_result?: true
      )

    bound_request = %{request("bound-missing-owner") | reset_probe: bound_reset_probe()}

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.remote_submit_request(
               session.id,
               downstream("corr-bound-missing-owner"),
               bound_request,
               upstream: upstream,
               local_node_string: local_node_string,
               request_id: "bound-missing-owner"
             )

    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(session.id)
    refute_received {:websocket_owner_harness_upstream_started, _upstream_pid}
  end

  @tag :task_1_red
  test "RED-R05 owner-unavailable response option recovery preserves per-call owner turn id", %{
    auth: auth
  } do
    %{session: session, token: token} = owner_session_fixture(auth, Atom.to_string(node()))
    owner_turn_id = self()

    downstream =
      downstream("corr-red-response-options")
      |> Map.put(:active_turn_reconnect?, false)
      |> Map.put(:owner_turn_id, owner_turn_id)

    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
      |> Gateway.websocket_owner_response_options(session, token, downstream)

    assert {:ok, recovered_opts} = Gateway.recover_websocket_owner_response_options(opts)

    recovered_downstream = recovered_opts.transport.websocket_owner.downstream
    assert Map.get(recovered_downstream, :owner_turn_id) == owner_turn_id

    assert MapSet.new(Map.keys(recovered_downstream)) ==
             MapSet.new([
               :pid,
               :epoch,
               :correlation_id,
               :active_turn_reconnect?,
               :owner_turn_id
             ])
  end

  test "public response option recovery fails closed for missing mutated or extra turn identity",
       %{
         auth: auth
       } do
    %{session: session, token: token} = owner_session_fixture(auth, Atom.to_string(node()))

    stable_downstream =
      downstream("corr-invalid-response-options")
      |> Map.put(:active_turn_reconnect?, false)

    mutated_owner_turn_id = spawn(fn -> :ok end)

    invalid_downstreams = [
      stable_downstream,
      Map.put(stable_downstream, :owner_turn_id, mutated_owner_turn_id),
      stable_downstream
      |> Map.put(:owner_turn_id, self())
      |> Map.put(:unexpected, true)
    ]

    for invalid_downstream <- invalid_downstreams do
      opts =
        %{}
        |> RequestOptions.for_websocket()
        |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
        |> Gateway.websocket_owner_response_options(session, token, invalid_downstream)

      assert Gateway.recover_websocket_owner_response_options(opts) ==
               {:error, :owner_unavailable}
    end
  end

  @tag :task_1_red
  test "RED-R06 direct recovery keeps per-call owner turn id out of stable restore state", %{
    auth: auth
  } do
    local_node_string = Atom.to_string(node())
    %{session: session, token: token} = owner_session_fixture(auth, local_node_string)
    owner_turn_id = self()
    frame = terminal_frame("resp_red_stable_restore")

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [frame],
        return_request_result?: true
      )

    per_call_downstream =
      downstream("corr-red-stable-restore")
      |> Map.put(:active_turn_reconnect?, false)
      |> Map.put(:owner_turn_id, owner_turn_id)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               per_call_downstream,
               request("red-stable-restore"),
               upstream: upstream,
               local_node_string: local_node_string,
               request_id: "red-stable-restore"
             )

    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    assert_receive {:websocket_owner_frame, "corr-red-stable-restore", 1, ^owner_turn_id,
                    {:data, ^frame}}

    assert_receive {:websocket_owner_frame, "corr-red-stable-restore", 1, ^owner_turn_id,
                    :complete}

    refute_received {:websocket_owner_frame, "corr-red-stable-restore", 1, _legacy_payload}
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session.id)
    stable_downstream = :sys.get_state(owner).downstream

    assert MapSet.new(Map.keys(stable_downstream)) ==
             MapSet.new([:pid, :epoch, :correlation_id, :active_turn_reconnect?])

    assert is_boolean(stable_downstream.active_turn_reconnect?)
  end

  test "exit-after-first-submit recovery retries with the original public owner turn id", %{
    auth: auth
  } do
    local_node_string = Atom.to_string(node())
    %{session: session, token: token} = owner_session_fixture(auth, local_node_string)
    parent = self()
    release_ref = make_ref()

    first_upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:first_public_owner_submit_started, self(), release_ref})

        receive do
          {:release_first_public_owner_submit, ^release_ref} -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      end
    }

    {:ok, first_owner} = start_owner(session, first_upstream)

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(
               first_owner,
               downstream("corr-exit-after-submit")
             )

    terminal_frame = terminal_frame("resp_exit_after_submit")

    recovery_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true
      )

    submitter =
      spawn(fn ->
        receive do
          {:submit_public_owner_request, downstream} ->
            result =
              WebsocketOwnerForwarder.submit_request(
                session,
                token,
                downstream,
                request("exit-after-submit"),
                upstream: recovery_upstream,
                local_node_string: local_node_string,
                request_id: "exit-after-submit"
              )

            send(parent, {:public_owner_retry_result, self(), result})
        end
      end)

    per_call_downstream = Map.put(stable_downstream, :owner_turn_id, submitter)
    send(submitter, {:submit_public_owner_request, per_call_downstream})

    assert_receive {:first_public_owner_submit_started, first_worker, ^release_ref}

    first_owner_ref = Process.monitor(first_owner)
    Process.exit(first_owner, :kill)
    assert_receive {:DOWN, ^first_owner_ref, :process, ^first_owner, :killed}
    send(first_worker, {:release_first_public_owner_submit, release_ref})

    assert_receive {:websocket_owner_runtime_recovered, "corr-exit-after-submit", 1,
                    %{websocket_owner_downstream: recovered_stable}}

    assert MapSet.new(Map.keys(recovered_stable)) ==
             MapSet.new([:pid, :epoch, :correlation_id, :active_turn_reconnect?])

    refute Map.has_key?(recovered_stable, :owner_turn_id)

    assert_receive {:websocket_owner_harness_upstream_started, _recovery_upstream_pid}

    assert_receive {:websocket_owner_frame, "corr-exit-after-submit", 1, ^submitter,
                    {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "corr-exit-after-submit", 1, ^submitter, :complete}

    assert_receive {:public_owner_retry_result, ^submitter,
                    {:ok, %{terminal: "response.completed", status: 200}}}

    assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(session.id)
    recovered_owner_state = :sys.get_state(recovered_owner)
    assert recovered_owner_state.downstream == recovered_stable
    refute Map.has_key?(recovered_owner_state.downstream, :owner_turn_id)
  end

  test "bound reset probe does not replace a crashed pre-visible owner", %{auth: auth} do
    local_node_string = Atom.to_string(node())
    %{session: session, token: token} = owner_session_fixture(auth, local_node_string)
    parent = self()
    release_ref = make_ref()

    first_upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:bound_owner_submit_started, self(), release_ref})

        receive do
          {:release_bound_owner_submit, ^release_ref} -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      end
    }

    {:ok, first_owner} = start_owner(session, first_upstream)

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(
               first_owner,
               downstream("corr-bound-owner-crash")
             )

    recovery_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame("resp_bound_owner_crash")],
        return_request_result?: true
      )

    bound_request = %{request("bound-owner-crash") | reset_probe: bound_reset_probe()}

    submitter =
      Task.async(fn ->
        WebsocketOwnerForwarder.submit_request(
          session,
          token,
          stable_downstream,
          bound_request,
          upstream: recovery_upstream,
          local_node_string: local_node_string,
          request_id: "bound-owner-crash"
        )
      end)

    assert_receive {:bound_owner_submit_started, first_worker, ^release_ref}

    first_owner_ref = Process.monitor(first_owner)
    Process.exit(first_owner, :kill)
    assert_receive {:DOWN, ^first_owner_ref, :process, ^first_owner, :killed}
    send(first_worker, {:release_bound_owner_submit, release_ref})

    assert Task.await(submitter, 2_000) == {:error, :owner_crashed}
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(session.id)
    refute_received {:websocket_owner_runtime_recovered, _, _, _}
    refute_received {:websocket_owner_harness_upstream_started, _upstream_pid}
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

  test "remote request submits to the owner node with owner-local settings", %{auth: auth} do
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

    request =
      %UpstreamWebsocketSession.Request{
        url: "https://example.com/backend-api/codex/responses",
        headers: [],
        payload: "request-frame",
        timeouts: %{}
      }
      |> owner_request()

    {:ok, recovered_owner} =
      start_owner(session, upstream, idle_shutdown_ms: idle_shutdown_ms)

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    {:ok, recovered_downstream} =
      WebsocketOwnerSession.attach_downstream(
        recovered_owner,
        downstream("corr-recovered-owner")
      )

    assert {:websocket_owner_submission_accepted,
            {:ok, %{body: body, terminal: "response.completed", status: 200}}} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               recovered_downstream,
               request,
               opts
             )

    assert body =~ "resp_recovered_owner"

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request_v1, arity: 3}}

    assert [%UpstreamWebsocketSession.Request{payload: "request-frame"}] =
             WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid)

    assert_receive {:websocket_owner_frame, "corr-recovered-owner", 1, {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "corr-recovered-owner", 1, :complete}

    assert %{idle_shutdown_ms: ^idle_shutdown_ms} = :sys.get_state(recovered_owner)

    new_idle_shutdown_ms = 240
    put_owner_idle_timeout(new_idle_shutdown_ms)

    assert {:ok, existing_owner} = WebsocketOwnerSession.lookup(session.id)
    assert existing_owner == recovered_owner
    assert %{idle_shutdown_ms: ^idle_shutdown_ms} = :sys.get_state(existing_owner)

    %{session: new_session, token: new_token} =
      owner_session_fixture(auth, remote_node_string, "recover-owner-new")

    {:ok, new_owner} =
      start_owner(new_session, upstream, idle_shutdown_ms: new_idle_shutdown_ms)

    assert_receive {:websocket_owner_harness_upstream_started, new_upstream_pid}

    {:ok, new_downstream} =
      WebsocketOwnerSession.attach_downstream(
        new_owner,
        downstream("corr-recovered-owner-new")
      )

    assert {:websocket_owner_submission_accepted,
            {:ok, %{body: new_body, terminal: "response.completed", status: 200}}} =
             WebsocketOwnerForwarder.submit_request(
               new_session,
               new_token,
               new_downstream,
               request,
               opts
             )

    assert new_body =~ "resp_recovered_owner"

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request_v1, arity: 3}}

    assert [%UpstreamWebsocketSession.Request{payload: "request-frame"}] =
             WebsocketOwnerNodeHarness.fake_upstream_frames(new_upstream_pid)

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

    reset_probe = bound_reset_probe()

    request =
      %UpstreamWebsocketSession.Request{
        url: "https://example.com/backend-api/codex/responses",
        headers: [],
        payload: "bridge-request-frame",
        timeouts: %{},
        reset_probe: reset_probe
      }
      |> owner_request()

    assert {:websocket_owner_submission_accepted,
            {:ok, %{terminal: "response.completed", status: 200}}} =
             WebsocketOwnerForwarder.submit_request(session, token, attached, request, opts)

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_attach_downstream, arity: 3}}

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request_v1, arity: 3}}

    assert [
             %UpstreamWebsocketSession.Request{
               payload: "bridge-request-frame",
               reset_probe: ^reset_probe
             }
           ] =
             WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid)

    assert_receive {:websocket_owner_frame, "corr-remote-bridge", ^epoch,
                    {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "corr-remote-bridge", ^epoch, :complete}
  end

  test "remote owner acceptance remains causally attached to the RPC result", %{auth: auth} do
    remote_node = :"codex_pooler@acceptance-owner-app.example"
    remote_node_string = Atom.to_string(remote_node)
    %{session: session, token: token} = owner_session_fixture(auth, remote_node_string)
    terminal_frame = terminal_frame("resp_remote_acceptance")

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true
      )

    {:ok, _owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}
    attached = attach_downstream(session.id, "corr-remote-acceptance")

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    request = owner_request(request("remote-acceptance"), submission_notification?: true)

    assert {:websocket_owner_submission_accepted,
            {:ok, %{terminal: "response.completed", status: 200}}} =
             WebsocketOwnerForwarder.submit_request(session, token, attached, request, opts)

    refute_received {:remote_submission_observer_ran, _observer_pid}

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request_v1, arity: 3}}
  end

  test "remote v1 submission sends only the data envelope", %{auth: auth} do
    remote_node = :"codex_pooler@data-envelope-owner-app.example"
    remote_node_string = Atom.to_string(remote_node)

    %{session: session, token: token} =
      owner_session_fixture(auth, remote_node_string, "data-envelope")

    owner_request = owner_request(request("data-envelope"), submission_notification?: true)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, {:websocket_owner_submission_accepted, :ok}}},
        capture_request_to: self()
      )

    assert {:websocket_owner_submission_accepted, :ok} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               downstream("corr-data-envelope"),
               owner_request,
               opts
             )

    assert_receive {:websocket_owner_harness_request, captured_request}
    assert captured_request == owner_request
    refute contains_function?(captured_request)

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request_v1, arity: 3}}
  end

  test "legacy remote request rejects before owner submission", %{auth: auth} do
    local_node_string = Atom.to_string(node())
    %{session: session} = owner_session_fixture(auth, local_node_string, "legacy-reject")
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {:ok, owner} = start_owner(session, upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.remote_submit_request(
               session.id,
               downstream("corr-legacy-reject"),
               request("legacy-reject"),
               upstream: upstream
             )

    assert Process.alive?(owner)
    assert WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid) == []
  end

  test "only an exact top-frame missing v1 entrypoint maps to owner unavailable", %{auth: auth} do
    remote_node = :"codex_pooler@protocol-mismatch-owner-app.example"
    remote_node_string = Atom.to_string(remote_node)

    %{session: session, token: token} =
      owner_session_fixture(auth, remote_node_string, "protocol-mismatch")

    owner_request = owner_request(request("protocol-mismatch"))
    downstream = downstream("corr-protocol-mismatch")
    args = [session.id, downstream, owner_request]

    exact_undef =
      {:exception, :undef, [{WebsocketOwnerForwarder, :remote_submit_request_v1, args, []}]}

    exact_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, {:error, exact_undef}}}
      )

    log =
      capture_log(fn ->
        assert {:error, :owner_unavailable} =
                 WebsocketOwnerForwarder.submit_request(
                   session,
                   token,
                   downstream,
                   owner_request,
                   exact_opts
                 )
      end)

    assert log =~ "event=owner_protocol_incompatible"

    inner_undef =
      {:exception, :undef,
       [
         {WebsocketOwnerRequest, :nested_missing_function, [], []},
         {WebsocketOwnerForwarder, :remote_submit_request_v1, args, []}
       ]}

    inner_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, {:error, inner_undef}}}
      )

    inner_log =
      capture_log(fn ->
        assert {:error, :owner_crashed} =
                 WebsocketOwnerForwarder.submit_request(
                   session,
                   token,
                   downstream,
                   owner_request,
                   inner_opts
                 )
      end)

    refute inner_log =~ "event=owner_protocol_incompatible"
  end

  test "legacy remote owner success remains causally marked as an accepted submission", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@legacy-acceptance-owner-app.example"
    remote_node_string = Atom.to_string(remote_node)

    for {suffix, legacy_result} <- [ok: :ok, structured: {:ok, %{status: 200}}] do
      %{session: session, token: token} =
        owner_session_fixture(auth, remote_node_string, "legacy-acceptance-#{suffix}")

      opts =
        WebsocketOwnerNodeHarness.node_client_opts([remote_node],
          calls: %{remote_node => {:return, legacy_result}}
        )

      assert {:websocket_owner_submission_accepted, ^legacy_result} =
               WebsocketOwnerForwarder.submit_request(
                 session,
                 token,
                 downstream("corr-legacy-acceptance-#{suffix}"),
                 owner_request(request("legacy-acceptance-#{suffix}")),
                 opts
               )
    end
  end

  test "accepted malformed remote owner results retain submission causality", %{auth: auth} do
    remote_node = :"codex_pooler@malformed-acceptance-owner-app.example"
    remote_node_string = Atom.to_string(remote_node)

    for {suffix, malformed_result} <-
          [unknown: :unexpected, unknown_error: {:error, :unexpected_owner_error}] do
      %{session: session, token: token} =
        owner_session_fixture(auth, remote_node_string, "malformed-acceptance-#{suffix}")

      opts =
        WebsocketOwnerNodeHarness.node_client_opts([remote_node],
          calls: %{
            remote_node => {:return, {:websocket_owner_submission_accepted, malformed_result}}
          }
        )

      assert {:websocket_owner_submission_accepted, {:error, :owner_crashed}} =
               WebsocketOwnerForwarder.submit_request(
                 session,
                 token,
                 downstream("corr-malformed-acceptance-#{suffix}"),
                 owner_request(request("malformed-acceptance-#{suffix}")),
                 opts
               )
    end
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

    request =
      %UpstreamWebsocketSession.Request{
        url: "https://example.com/backend-api/codex/responses",
        headers: [],
        payload: "request-frame",
        timeouts: %{}
      }
      |> owner_request()

    assert {:error, ^structured_error} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               downstream("corr-structured-error"),
               request,
               opts
             )
  end

  test "in-process remote owner forwarding preserves a structured response identity", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@structured-success-app.example"
    remote_node_string = Atom.to_string(remote_node)

    %{session: session, token: token} =
      owner_session_fixture(auth, remote_node_string, "identity")

    response_id = "resp_remote_harness_identity"

    structured_result = %{
      body: "",
      terminal: "response.completed",
      status: 200,
      headers: [],
      websocket_frame_headers: %{},
      response_id: response_id
    }

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, {:ok, structured_result}}}
      )

    assert {:websocket_owner_submission_accepted, {:ok, ^structured_result}} =
             WebsocketOwnerForwarder.submit_request(
               session,
               token,
               downstream("corr-structured-success"),
               owner_request(request("structured-success-request")),
               opts
             )

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request_v1, arity: 3}}
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

  @tag :continuation_generation_boundary
  test "real peer owner guards a replacement generation before proxy settlement" do
    peer_node = start_current_peer!("continuation_guard_owner")
    terminal = native_retry_terminal()
    release_ref = make_ref()

    upstream =
      start_fake_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           websocket_success_without_id()
         ]}
      )

    persistence =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    downstream_sender =
      :erpc.call(
        peer_node,
        WebsocketOwnerNodeHarness,
        :terminal_barrier_downstream_sender,
        [self(), terminal, release_ref]
      )

    session_id = "real-peer-continuation-guard"

    assert {:ok, owner_pid} =
             :erpc.call(peer_node, WebsocketOwnerSession, :start_owner, [
               [
                 codex_session_id: session_id,
                 owner_lease_token: "synthetic-continuation-owner-token",
                 owner_instance_id: Atom.to_string(peer_node),
                 owner_renewal_ms: 60_000,
                 downstream_sender: downstream_sender,
                 persistence: persistence
               ]
             ])

    assert node(owner_pid) == peer_node

    client = WebsocketOwnerForwarder.ERPCNodeClient

    assert {:ok, attached} =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_attach_downstream,
               [session_id, downstream("corr-peer-continuation-guard")],
               @peer_detection_timeout_ms
             )

    warmup = request("warmup-request", FakeUpstream.url(upstream))

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             client.call_owner(
               peer_node,
               WebsocketOwnerSession,
               :submit_request,
               [owner_pid, attached, warmup],
               @peer_detection_timeout_ms
             )

    assert_receive {:websocket_owner_frame, "corr-peer-continuation-guard", 1,
                    {:data, _warmup_terminal}}

    assert_receive {:websocket_owner_frame, "corr-peer-continuation-guard", 1, :complete}

    upstream_pid =
      :erpc.call(peer_node, :erlang, :map_get, [:upstream_pid, :sys.get_state(owner_pid)])

    assert :ok =
             :erpc.call(peer_node, UpstreamWebsocketSession, :invalidate_connection, [
               upstream_pid
             ])

    guarded_request = %{warmup | connection_bound_continuation?: true}

    guarded_submit =
      Task.async(fn ->
        client.call_owner(
          peer_node,
          WebsocketOwnerSession,
          :submit_request,
          [owner_pid, attached, guarded_request],
          @peer_detection_timeout_ms
        )
      end)

    assert_receive {:websocket_owner_harness_terminal_delivery_barrier, barrier_pid, ^release_ref}
    assert Task.yield(guarded_submit, 0) == nil

    refute_received {:websocket_owner_frame, "corr-peer-continuation-guard", 1,
                     {:data, ^terminal}}

    assert length(FakeUpstream.requests(upstream)) == 1

    send(barrier_pid, {:websocket_owner_harness_release_terminal_delivery, release_ref})

    assert_receive {:websocket_owner_frame, "corr-peer-continuation-guard", 1, {:data, ^terminal}}

    assert_receive {:websocket_owner_harness_terminal_delivered, ^release_ref}

    assert {:ok, guarded_result} = Task.await(guarded_submit, @peer_detection_timeout_ms)
    assert guarded_result.terminal == "error"
    assert guarded_result.upstream_error_code == "previous_response_not_found"
    assert guarded_result.upstream_websocket_connection.reconnected
    assert_receive {:websocket_owner_frame, "corr-peer-continuation-guard", 1, :complete}

    refute_received {:websocket_owner_frame, "corr-peer-continuation-guard", 1,
                     {:data, ^terminal}}

    refute_received {:websocket_owner_frame, "corr-peer-continuation-guard", 1, :complete}
    assert length(FakeUpstream.requests(upstream)) == 1

    assert {:ok, retry_result} =
             client.call_owner(
               peer_node,
               WebsocketOwnerSession,
               :submit_request,
               [owner_pid, attached, warmup],
               @peer_detection_timeout_ms
             )

    assert retry_result.terminal == "response.completed"
    assert retry_result.upstream_websocket_connection.reused
    assert_receive {:websocket_owner_frame, "corr-peer-continuation-guard", 1, {:data, _retry}}
    assert_receive {:websocket_owner_frame, "corr-peer-continuation-guard", 1, :complete}

    assert [warmup_request, retry_request] = FakeUpstream.requests(upstream)
    assert warmup_request.websocket_connection_id != retry_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "remote owner cancels an active turn when the local forwarding proxy dies", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@cancel-owner-app.example"

    %{session: session, token: token} =
      owner_session_fixture(auth, Atom.to_string(remote_node), "remote-cancel")

    parent = self()
    release_ref = make_ref()

    upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:remote_cancel_turn_started, self(), release_ref})

        receive do
          {:release_remote_cancel_turn, ^release_ref} -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      end
    }

    assert {:ok, owner_pid} =
             start_owner(session, upstream)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    assert {:ok, attached} =
             WebsocketOwnerForwarder.call_remote(
               remote_node,
               :remote_attach_downstream,
               [session.id, downstream("corr-real-peer-cancel")],
               opts
             )

    remote_cancel_request =
      request("remote-cancel") |> owner_request()

    submitter =
      Task.async(fn ->
        WebsocketOwnerNodeHarness.with_node_client(
          [remote_node],
          [calls: %{remote_node => :success}],
          fn task_opts ->
            WebsocketOwnerForwarder.submit_request(
              session,
              token,
              attached,
              remote_cancel_request,
              task_opts
            )
          end
        )
      end)

    assert_receive {:remote_cancel_turn_started, remote_turn_task, ^release_ref}

    assert %{active_turn: %{task_pid: ^remote_turn_task}} = :sys.get_state(owner_pid)

    remote_turn_monitor = Process.monitor(remote_turn_task)

    Task.shutdown(submitter, :brutal_kill)

    assert_receive {:DOWN, ^remote_turn_monitor, :process, ^remote_turn_task, :shutdown},
                   @peer_detection_timeout_ms

    await_owner_cancellation!(owner_pid)
  end

  test "owner_drained remote cancellation stops only the matching turn and preserves owner reuse",
       %{
         auth: auth
       } do
    remote_node = :"codex_pooler@drain-cancel-owner-app.example"

    %{session: session} =
      owner_session_fixture(auth, Atom.to_string(remote_node), "remote-drain-cancel")

    parent = self()
    release_ref = make_ref()

    upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, request, _writer ->
        send(parent, {:remote_drain_turn_started, self(), request})

        receive do
          {:release_remote_drain_turn, ^release_ref} -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      end
    }

    assert {:ok, owner_pid} = start_owner(session, upstream)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node], calls: %{remote_node => :success})

    assert {:ok, stable_downstream} =
             WebsocketOwnerForwarder.call_remote(
               remote_node,
               :remote_attach_downstream,
               [session.id, downstream("corr-drain-cancel")],
               opts
             )

    owner_turn_id = spawn(fn -> receive do: (:stop -> :ok) end)
    downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)

    submitter =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(
          owner_pid,
          downstream,
          request("remote-drain-cancel"),
          true
        )
      end)

    assert_receive {:remote_drain_turn_started, remote_turn_task, _request}

    wrong_turn_id = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:error, :stale_downstream} =
             WebsocketOwnerSession.cancel_downstream(
               owner_pid,
               Map.put(downstream, :owner_turn_id, wrong_turn_id),
               :owner_drained
             )

    assert %{active_turn: %{task_pid: ^remote_turn_task}, downstream: ^stable_downstream} =
             :sys.get_state(owner_pid)

    send(wrong_turn_id, :stop)

    assert :ok =
             WebsocketOwnerForwarder.cancel_remote_downstream(
               remote_node,
               session.id,
               downstream,
               :owner_drained,
               opts
             )

    assert {:websocket_owner_submission_accepted, {:error, :owner_drained}} =
             Task.await(submitter, @peer_detection_timeout_ms)

    assert Process.alive?(owner_pid)
    assert %{active_turn: nil, draining?: false} = :sys.get_state(owner_pid)

    assert {:ok, replacement_downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner_pid,
               downstream("corr-drain-cancel-reuse")
             )

    retry =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner_pid, replacement_downstream, request("retry"))
      end)

    assert_receive {:remote_drain_turn_started, retry_task, _request}
    send(retry_task, {:release_remote_drain_turn, release_ref})
    assert :ok = Task.await(retry, @peer_detection_timeout_ms)
    assert Process.alive?(owner_pid)

    send(owner_turn_id, :stop)
    refute_received {:websocket_owner_frame, "corr-drain-cancel", 1, :complete}
    refute Process.alive?(remote_turn_task)
  end

  @tag :rollout_drain_peer_qa
  test "real peer owner stays reusable while rollout drain waits for its proxy-local task" do
    peer_node = start_current_peer!("rollout_proxy_owner")
    parent = self()
    release_ref = make_ref()
    session_id = "real-peer-rollout-proxy"

    terminal = terminal_frame("resp_real_peer_rollout_proxy")

    upstream =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_upstream_boundary, [
        parent,
        [block_ref: release_ref, messages: [terminal], return_request_result?: true]
      ])

    persistence = :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    assert {:ok, owner_pid} =
             :erpc.call(peer_node, WebsocketOwnerSession, :start_owner, [
               [
                 codex_session_id: session_id,
                 owner_lease_token: "synthetic-rollout-proxy-token",
                 owner_instance_id: Atom.to_string(peer_node),
                 owner_renewal_ms: 60_000,
                 upstream: upstream,
                 persistence: persistence
               ]
             ])

    client = WebsocketOwnerForwarder.ERPCNodeClient

    assert {:ok, stable_downstream} =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_attach_downstream,
               [session_id, downstream("corr-real-peer-rollout-proxy")],
               @peer_detection_timeout_ms
             )

    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    response_task_parent = self()

    {:ok, response_task} =
      ResponseTask.start(
        response_task_parent,
        :proxy,
        fn task_pid ->
          send(parent, {:real_peer_proxy_dispatch_identity, self(), task_pid})
          per_call_downstream = Map.put(stable_downstream, :owner_turn_id, task_pid)

          client.call_owner(
            peer_node,
            WebsocketOwnerSession,
            :submit_request,
            [owner_pid, per_call_downstream, request("real-peer-rollout-proxy")],
            @peer_detection_timeout_ms
          )
        end,
        fn task_pid, :owner_drained ->
          per_call_downstream = Map.put(stable_downstream, :owner_turn_id, task_pid)

          assert :ok =
                   client.call_owner(
                     peer_node,
                     WebsocketOwnerForwarder,
                     :remote_cancel_downstream_v1,
                     [session_id, per_call_downstream, :owner_drained],
                     @peer_detection_timeout_ms
                   )

          :await_worker
        end,
        activity_registry: harness.activity_registry
      )

    assert_receive {:real_peer_proxy_dispatch_identity, ^response_task, ^response_task}
    assert_receive {:websocket_owner_harness_barrier, peer_turn_task, ^release_ref}

    assert_receive {:websocket_owner_frame, "corr-real-peer-rollout-proxy", 1, ^response_task,
                    {:data, ^terminal}} = terminal_message

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, _deadline, _wait_ms}
    refute_received {:codex_response_done, ^response_task, _result}
    send(peer_turn_task, {:websocket_owner_harness_release, release_ref})

    assert_receive {:websocket_response_activity, ^response_task, activity_token}

    assert_receive {:codex_response_done, ^response_task,
                    {:ok, %{terminal: "response.completed"}}} = done_message

    assert_receive {:websocket_owner_frame, "corr-real-peer-rollout-proxy", 1, ^response_task,
                    :complete} = complete_message

    task_monitor = Process.monitor(response_task)

    socket_state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([response_task]),
      task_monitors: %{response_task => task_monitor},
      queued_response_payloads: :queue.new(),
      websocket_owner_downstream: stable_downstream,
      native_turn_output_task_pids: MapSet.new()
    }

    assert {:ok, activity_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_activity, response_task, activity_token},
               socket_state
             )

    assert {:ok, result_state} = CodexResponsesSocket.handle_info(done_message, activity_state)

    assert Process.alive?(drain_task.pid)

    assert {:push, {:text, ^terminal}, terminal_state} =
             CodexResponsesSocket.handle_info(terminal_message, result_state)

    assert Process.alive?(drain_task.pid)

    assert {:ok, completed_state} =
             CodexResponsesSocket.handle_info(complete_message, terminal_state)

    assert_receive {:websocket_response_delivery_complete, ^response_task, ^activity_token} =
                     delivery_ack

    assert {:ok, _final_state} = CodexResponsesSocket.handle_info(delivery_ack, completed_state)

    assert %{proxy_turns_seen: 1, proxy_turns_completed: 1, proxy_turns_aborted: 0} =
             Task.await(drain_task, @peer_detection_timeout_ms)

    assert :erpc.call(peer_node, Process, :alive?, [owner_pid])

    assert %{active_turn: nil, draining?: false} =
             :erpc.call(peer_node, :sys, :get_state, [owner_pid])
  end

  test "versioned remote cancellation falls back to the legacy /2 entrypoint" do
    remote_node = :"codex_pooler@legacy-cancel-owner-app.example"
    session_id = "legacy-cancel-session"

    assert {:ok, _owner_pid} =
             WebsocketOwnerSession.start_owner(
               codex_session_id: session_id,
               owner_lease_token: "synthetic-legacy-cancel-token",
               owner_instance_id: Atom.to_string(node()),
               owner_renewal_ms: 60_000,
               upstream: WebsocketOwnerNodeHarness.fake_upstream_boundary(self()),
               persistence: WebsocketOwnerNodeHarness.fake_persistence_boundary()
             )

    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}
    downstream = attach_downstream(session_id, "corr-legacy-cancel")

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :old_release}
      )

    assert :ok =
             WebsocketOwnerForwarder.cancel_remote_downstream(
               remote_node,
               session_id,
               downstream,
               :client_disconnected,
               opts
             )
  end

  @tag :continuation_generation_boundary
  test "real peer owner defaults a missing forwarded continuation marker to false" do
    peer_node = start_current_peer!("legacy_continuation_owner")
    upstream = start_fake_upstream(websocket_success_without_id())

    persistence =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    session_id = "real-peer-legacy-continuation"

    assert {:ok, owner_pid} =
             :erpc.call(peer_node, WebsocketOwnerSession, :start_owner, [
               [
                 codex_session_id: session_id,
                 owner_lease_token: "synthetic-legacy-owner-token",
                 owner_instance_id: Atom.to_string(peer_node),
                 owner_renewal_ms: 60_000,
                 persistence: persistence
               ]
             ])

    client = WebsocketOwnerForwarder.ERPCNodeClient

    assert {:ok, attached} =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_attach_downstream,
               [session_id, downstream("corr-peer-legacy-continuation")],
               @peer_detection_timeout_ms
             )

    private_marker = "synthetic-private-previous-response"

    legacy_request =
      Jason.encode!(%{"previous_response_id" => private_marker})
      |> request(FakeUpstream.url(upstream))
      |> Map.delete(:connection_bound_continuation?)

    assert is_struct(legacy_request, UpstreamWebsocketSession.Request)
    refute Map.has_key?(legacy_request, :connection_bound_continuation?)

    assert {:ok, result} =
             client.call_owner(
               peer_node,
               WebsocketOwnerSession,
               :submit_request,
               [owner_pid, attached, legacy_request],
               @peer_detection_timeout_ms
             )

    assert result.terminal == "response.completed"
    refute Map.has_key?(result, :transport_failure)
    refute inspect(result) =~ private_marker

    assert [%{json: %{"previous_response_id" => ^private_marker}}] =
             FakeUpstream.requests(upstream)

    assert_receive {:websocket_owner_frame, "corr-peer-legacy-continuation", 1,
                    {:data, _terminal}}

    assert_receive {:websocket_owner_frame, "corr-peer-legacy-continuation", 1, :complete}
  end

  test "real peer owner preserves a structured response identity" do
    peer_node = start_current_peer!("response_identity_owner")
    response_id = "resp_real_peer_identity"

    upstream =
      start_fake_upstream(FakeUpstream.websocket_text_frames([terminal_frame(response_id)]))

    persistence =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    session_id = "real-peer-response-identity"

    assert {:ok, owner_pid} =
             :erpc.call(peer_node, WebsocketOwnerSession, :start_owner, [
               [
                 codex_session_id: session_id,
                 owner_lease_token: "synthetic-response-identity-owner-token",
                 owner_instance_id: Atom.to_string(peer_node),
                 owner_renewal_ms: 60_000,
                 persistence: persistence
               ]
             ])

    assert node(owner_pid) == peer_node

    client = WebsocketOwnerForwarder.ERPCNodeClient

    assert {:ok, attached} =
             client.call_owner(
               peer_node,
               WebsocketOwnerForwarder,
               :remote_attach_downstream,
               [session_id, downstream("corr-real-peer-response-identity")],
               @peer_detection_timeout_ms
             )

    assert {:ok, %{response_id: ^response_id} = result} =
             client.call_owner(
               peer_node,
               WebsocketOwnerSession,
               :submit_request,
               [
                 owner_pid,
                 attached,
                 request("real-peer-response-identity", FakeUpstream.url(upstream))
               ],
               @peer_detection_timeout_ms
             )

    assert %{terminal: "response.completed", status: 200} = result

    assert_receive {:websocket_owner_frame, "corr-real-peer-response-identity", 1,
                    {:data, _terminal}}

    assert_receive {:websocket_owner_frame, "corr-real-peer-response-identity", 1, :complete}
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
             WebsocketOwnerForwarder.submit_request(
               recovered_session,
               recovered_session.owner_lease_token,
               downstream("corr-real-peer-recovery"),
               request,
               upstream: recovery_upstream,
               local_node_string: Atom.to_string(node())
             )

    assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(recovered_session.id)
    assert %{idle_shutdown_ms: ^recovery_timeout} = :sys.get_state(recovered_owner)
  end

  test "current proxy serves a native turn from a real previous-release owner and bridge attach fails closed" do
    peer_node = start_current_peer!("previous_owner")
    terminal_frame = terminal_frame("resp_previous_owner")

    upstream =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_upstream_boundary, [
        self(),
        [messages: [terminal_frame], return_request_result?: true]
      ])

    persistence =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    session_id = "real-peer-previous-owner"

    assert {:ok, owner_pid} =
             :erpc.call(peer_node, WebsocketOwnerSession, :start_owner, [
               [
                 codex_session_id: session_id,
                 owner_lease_token: "synthetic-previous-owner-token",
                 owner_instance_id: Atom.to_string(peer_node),
                 owner_renewal_ms: 60_000,
                 upstream: upstream,
                 persistence: persistence
               ]
             ])

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert 300_000 ==
             :erpc.call(
               peer_node,
               WebsocketOwnerNodeHarness,
               :owner_idle_timeout,
               [owner_pid]
             )

    module = WebsocketOwnerForwarder
    {:ok, ^module, beam} = previous_release_forwarder_beam(module)

    assert {:module, ^module} =
             :erpc.call(peer_node, :code, :load_binary, [module, ~c"previous_release.ex", beam])

    assert :erpc.call(peer_node, :erlang, :function_exported, [
             module,
             :remote_attach_downstream,
             2
           ])

    refute :erpc.call(peer_node, :erlang, :function_exported, [
             module,
             :remote_attach_downstream,
             3
           ])

    opts = [node_client: WebsocketOwnerForwarder.ERPCNodeClient]

    assert {:ok, %{epoch: epoch} = attached} =
             WebsocketOwnerForwarder.call_remote(
               peer_node,
               :remote_attach_downstream,
               [session_id, downstream("corr-previous-owner")],
               opts
             )

    assert {:ok, old_result} =
             WebsocketOwnerForwarder.call_remote(
               peer_node,
               :remote_submit_request,
               [session_id, attached, request("previous-owner-request"), []],
               opts
             )

    assert %{status: 200, terminal: "response.completed"} = old_result

    assert Map.keys(old_result) |> Enum.sort() ==
             [:body, :headers, :status, :terminal, :websocket_frame_headers]

    refute Map.has_key?(old_result, :upstream_websocket_connection)

    assert %{} ==
             Metadata.upstream_websocket_connection_attempt_metadata(
               Map.get(old_result, :upstream_websocket_connection)
             )

    assert_receive {:websocket_owner_harness_upstream_sent, ^upstream_pid}

    assert_receive {:websocket_owner_frame, "corr-previous-owner", ^epoch, {:data, _data}}

    assert_receive {:websocket_owner_frame, "corr-previous-owner", ^epoch, :complete}

    bridge_args =
      WebsocketOwnerForwarder.remote_attach_args(
        session_id,
        downstream("corr-previous-owner-bridge"),
        reject_if_busy: true
      )

    assert [_session_id, _downstream, [reject_if_busy: true]] = bridge_args

    assert {:error, :owner_crashed} =
             WebsocketOwnerForwarder.call_remote(
               peer_node,
               :remote_attach_downstream,
               bridge_args,
               opts
             )
  end

  test "real previous-release peer caller fails closed before current owner submission" do
    caller_node = start_current_peer!("previous_caller")

    connection = %{
      lifecycle_id: "11111111-1111-4111-8111-111111111111",
      generation: 2,
      reused: true,
      reconnected: false
    }

    terminal_frame = terminal_frame("resp_previous_caller")

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true,
        upstream_websocket_connection: connection
      )

    session_id = "real-peer-current-owner"

    assert {:ok, _owner_pid} =
             WebsocketOwnerSession.start_owner(
               codex_session_id: session_id,
               owner_lease_token: "synthetic-current-owner-token",
               owner_instance_id: Atom.to_string(node()),
               owner_renewal_ms: 60_000,
               upstream: upstream,
               persistence: WebsocketOwnerNodeHarness.fake_persistence_boundary()
             )

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    Code.ensure_loaded!(WebsocketOwnerForwarder)
    assert function_exported?(WebsocketOwnerForwarder, :remote_attach_downstream, 2)
    assert function_exported?(WebsocketOwnerForwarder, :remote_submit_request, 4)

    assert {:error, :owner_unavailable} =
             :erpc.call(
               caller_node,
               WebsocketOwnerPreviousReleaseCaller,
               :attach_and_submit,
               [
                 node(),
                 session_id,
                 downstream("corr-previous-caller"),
                 request("previous-caller-request")
               ]
             )

    refute_received {:websocket_owner_previous_release_caller, ^caller_node, _keys}
    refute_received {:websocket_owner_harness_upstream_sent, ^upstream_pid}
  end

  test "current proxy relays exact private-safe connection metadata from a real current peer" do
    peer_node = start_current_peer!("current_owner")

    connection = %{
      lifecycle_id: "22222222-2222-4222-8222-222222222222",
      generation: 3,
      reused: false,
      reconnected: true
    }

    terminal_frame = terminal_frame("resp_current_peer")

    upstream =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_upstream_boundary, [
        self(),
        [
          messages: [terminal_frame],
          return_request_result?: true,
          upstream_websocket_connection: connection
        ]
      ])

    persistence =
      :erpc.call(peer_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    session_id = "real-peer-current-relay"

    assert {:ok, owner_pid} =
             :erpc.call(peer_node, WebsocketOwnerSession, :start_owner, [
               [
                 codex_session_id: session_id,
                 owner_lease_token: "synthetic-current-relay-token",
                 owner_instance_id: Atom.to_string(peer_node),
                 owner_renewal_ms: 60_000,
                 upstream: upstream,
                 persistence: persistence
               ]
             ])

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}
    opts = [node_client: WebsocketOwnerForwarder.ERPCNodeClient]

    assert {:ok, attached} =
             WebsocketOwnerForwarder.call_remote(
               peer_node,
               :remote_attach_downstream,
               [
                 session_id,
                 downstream("corr-current-relay"),
                 [reject_if_busy: true]
               ],
               opts
             )

    assert {:ok, %{upstream_websocket_connection: relayed_connection}} =
             WebsocketOwnerForwarder.ERPCNodeClient.call_owner(
               peer_node,
               WebsocketOwnerSession,
               :submit_request,
               [owner_pid, attached, request("current-relay-request")],
               @peer_detection_timeout_ms
             )

    assert relayed_connection == connection

    assert Map.keys(relayed_connection) |> Enum.sort() == [
             :generation,
             :lifecycle_id,
             :reconnected,
             :reused
           ]

    for forbidden <- [:pid, :node, :socket, :header, :headers, :payload] do
      refute Map.has_key?(relayed_connection, forbidden)
    end

    assert_receive {:websocket_owner_harness_upstream_sent, ^upstream_pid}
  end

  test "real current peers replace a nodedown owner and converge on one recovered owner lease",
       %{auth: auth} do
    {peer_a_pid, peer_a} = start_current_peer_process!("replacement_owner_a")
    {peer_b_pid, peer_b} = start_current_peer_process!("replacement_owner_b")
    owner_a_timeout = 300_101
    owner_b_timeout = 420_202

    assert :ok =
             :erpc.call(peer_a, WebsocketOwnerNodeHarness, :put_owner_idle_timeout, [
               owner_a_timeout
             ])

    assert :ok =
             :erpc.call(peer_b, WebsocketOwnerNodeHarness, :put_owner_idle_timeout, [
               owner_b_timeout
             ])

    %{session: session} =
      owner_session_fixture(auth, Atom.to_string(peer_a), "real-peer-replacement")

    lifecycle_a = Ecto.UUID.generate()

    connection_a = %{
      lifecycle_id: lifecycle_a,
      generation: 1,
      reused: false,
      reconnected: false
    }

    upstream_a =
      :erpc.call(peer_a, WebsocketOwnerNodeHarness, :fake_upstream_boundary, [
        self(),
        [
          messages: [terminal_frame("resp_replacement_a")],
          return_request_result?: true,
          upstream_websocket_connection: connection_a
        ]
      ])

    persistence_a =
      :erpc.call(peer_a, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    assert {:ok, owner_a} =
             :erpc.call(
               peer_a,
               WebsocketOwnerNodeHarness,
               :start_owner_with_local_idle_timeout,
               [
                 [
                   codex_session_id: session.id,
                   owner_lease_token: session.owner_lease_token,
                   owner_instance_id: Atom.to_string(peer_a),
                   owner_renewal_ms: 60_000,
                   upstream: upstream_a,
                   persistence: persistence_a
                 ]
               ]
             )

    assert_receive {:websocket_owner_harness_upstream_started, upstream_a_pid}

    assert owner_a_timeout ==
             :erpc.call(peer_a, WebsocketOwnerNodeHarness, :owner_idle_timeout, [owner_a])

    opts = [node_client: WebsocketOwnerForwarder.ERPCNodeClient]

    assert {:ok, %{epoch: epoch_a} = attached_a} =
             WebsocketOwnerForwarder.call_remote(
               peer_a,
               :remote_attach_downstream,
               [session.id, downstream("corr-replacement-a")],
               opts
             )

    assert {:ok, %{upstream_websocket_connection: ^connection_a}} =
             WebsocketOwnerForwarder.ERPCNodeClient.call_owner(
               peer_a,
               WebsocketOwnerSession,
               :submit_request,
               [owner_a, attached_a, request("replacement-a-request")],
               @peer_detection_timeout_ms
             )

    assert_receive {:websocket_owner_harness_upstream_sent, ^upstream_a_pid}
    assert_receive {:websocket_owner_frame, "corr-replacement-a", ^epoch_a, :complete}

    peer_a_monitor = Process.monitor(peer_a_pid)
    assert :ok = :peer.stop(peer_a_pid)
    assert_receive {:DOWN, ^peer_a_monitor, :process, ^peer_a_pid, _reason}, 2_000

    assert {:error, :owner_unavailable} =
             :erpc.call(
               peer_b,
               WebsocketOwnerForwarder.ERPCNodeClient,
               :call_owner,
               [
                 peer_a,
                 WebsocketOwnerForwarder,
                 :remote_attach_downstream,
                 [session.id, downstream("corr-replacement-detect")],
                 2_000
               ]
             )

    replacement_options =
      RequestOptions.for_websocket(%{owner_instance_id: Atom.to_string(peer_b)})

    assert {:ok, replacement_session} =
             SessionContinuity.replace_unavailable_owner_lease(
               session,
               replacement_options
             )

    refute replacement_session.owner_lease_token == session.owner_lease_token

    lifecycle_b = Ecto.UUID.generate()

    connection_b = %{
      lifecycle_id: lifecycle_b,
      generation: 1,
      reused: false,
      reconnected: false
    }

    upstream_b =
      :erpc.call(peer_b, WebsocketOwnerNodeHarness, :fake_upstream_boundary, [
        self(),
        [
          messages: [terminal_frame("resp_replacement_b")],
          return_request_result?: true,
          upstream_websocket_connection: connection_b
        ]
      ])

    persistence_b =
      :erpc.call(peer_b, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

    assert {:ok, owner_b} =
             :erpc.call(
               peer_b,
               WebsocketOwnerNodeHarness,
               :start_owner_with_local_idle_timeout,
               [
                 [
                   codex_session_id: replacement_session.id,
                   owner_lease_token: replacement_session.owner_lease_token,
                   owner_instance_id: Atom.to_string(peer_b),
                   owner_renewal_ms: 60_000,
                   upstream: upstream_b,
                   persistence: persistence_b
                 ]
               ]
             )

    assert_receive {:websocket_owner_harness_upstream_started, upstream_b_pid}

    assert owner_b_timeout ==
             :erpc.call(peer_b, WebsocketOwnerNodeHarness, :owner_idle_timeout, [owner_b])

    assert {:ok, %{epoch: epoch_b} = attached_b} =
             WebsocketOwnerForwarder.call_remote(
               peer_b,
               :remote_attach_downstream,
               [replacement_session.id, downstream("corr-replacement-b")],
               opts
             )

    assert {:ok, %{upstream_websocket_connection: recovered_connection}} =
             WebsocketOwnerForwarder.ERPCNodeClient.call_owner(
               peer_b,
               WebsocketOwnerSession,
               :submit_request,
               [owner_b, attached_b, request("replacement-b-request")],
               @peer_detection_timeout_ms
             )

    assert recovered_connection == connection_b
    assert lifecycle_b != lifecycle_a
    assert {:ok, ^lifecycle_a} = Ecto.UUID.cast(lifecycle_a)
    assert {:ok, ^lifecycle_b} = Ecto.UUID.cast(lifecycle_b)

    assert Map.keys(recovered_connection) |> Enum.sort() == [
             :generation,
             :lifecycle_id,
             :reconnected,
             :reused
           ]

    assert_receive {:websocket_owner_harness_upstream_sent, ^upstream_b_pid}
    assert_receive {:websocket_owner_frame, "corr-replacement-b", ^epoch_b, :complete}

    assert 1 ==
             :erpc.call(peer_b, WebsocketOwnerNodeHarness, :owner_count, [
               replacement_session.id
             ])

    active_status = BridgeOwnerLease.active_status()

    active_lease_query =
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^replacement_session.id and
            lease.status == ^active_status

    assert Repo.aggregate(active_lease_query, :count, :id) == 1

    assert Repo.exists?(
             from lease in active_lease_query,
               where:
                 lease.owner_instance_id == ^Atom.to_string(peer_b) and
                   lease.lease_token == ^replacement_session.owner_lease_token
           )

    peer_b_monitor = Process.monitor(peer_b_pid)
    assert :ok = :peer.stop(peer_b_pid)
    assert_receive {:DOWN, ^peer_b_monitor, :process, ^peer_b_pid, _reason}, 2_000
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

  defp start_owner(session, upstream, opts \\ []) do
    owner_opts =
      [
        codex_session_id: session.id,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id,
        upstream: upstream
      ]
      |> Keyword.merge(opts)

    WebsocketOwnerSession.start_owner(owner_opts)
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

  defp request(payload, base_url) do
    %UpstreamWebsocketSession.Request{
      url: base_url <> "/backend-api/codex/responses",
      headers: [],
      payload: payload,
      timeouts: @timeouts
    }
  end

  defp owner_request(%UpstreamWebsocketSession.Request{} = request, opts \\ []) do
    identity = Process.get({__MODULE__, :upstream_identity})

    {:ok, owner_request} =
      WebsocketOwnerRequest.new(%{
        version: 1,
        url: request.url,
        headers: request.headers,
        payload: request.payload,
        timeouts: normalize_timeouts(request.timeouts),
        mapper: Keyword.get(opts, :mapper, :codex_responses),
        upstream_identity_id: identity.id,
        observation: %{
          request_id: nil,
          client_request_id: nil,
          attempt_id: nil,
          mode: "full"
        },
        reset_probe: request.reset_probe,
        native_codex_response_control: request.native_codex_response_control,
        assignment_advertised?: request.assignment_advertised?,
        connection_bound_continuation?: request.connection_bound_continuation?,
        forward_error_body?: request.forward_error_body?,
        submission_notification?: Keyword.get(opts, :submission_notification?, false)
      })

    owner_request
  end

  defp normalize_timeouts(%TimeoutConfig{} = timeouts), do: timeouts
  defp normalize_timeouts(timeouts), do: TimeoutConfig.build(timeouts)

  defp contains_function?(value) when is_function(value), do: true

  defp contains_function?(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> contains_function?()
  end

  defp contains_function?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested_value} ->
      contains_function?(key) or contains_function?(nested_value)
    end)
  end

  defp contains_function?(value) when is_list(value) or is_tuple(value) do
    value
    |> Enum.to_list()
    |> Enum.any?(&contains_function?/1)
  end

  defp contains_function?(_value), do: false

  defp start_fake_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp websocket_success_without_id do
    FakeUpstream.websocket_text_frames([
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed"}
      })
    ])
  end

  defp native_retry_terminal do
    Jason.encode!(%{
      "type" => "error",
      "status" => 400,
      "error" => %{
        "type" => "invalid_request_error",
        "code" => "previous_response_not_found",
        "message" => "Previous response was not found. Retrying the full request."
      }
    })
  end

  defp bound_reset_probe do
    probe = ResetProbe.new()

    assert {:ok, bound_probe} =
             ResetProbe.bind(
               probe,
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               "gpt-reset-probe-owner",
               "proxy_websocket"
             )

    bound_probe
  end

  defp terminal_frame(response_id) do
    Jason.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => response_id, "status" => "completed"}
    })
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
    # This throwaway single-host mesh does not use global names; global's
    # overlapping-partition guard only adds nondeterministic teardown
    # disconnects that print WARNING REPORTs into the suite output on slow
    # CI machines. Disable it on every node involved (peers get the same
    # flag at boot) and restore the previous setting afterwards.
    previous_partition_guard =
      Application.fetch_env(:kernel, :prevent_overlapping_partitions)

    Application.put_env(:kernel, :prevent_overlapping_partitions, false)

    node_name = String.to_atom("codex_pooler_test_#{System.unique_integer([:positive])}")
    assert {:ok, _pid} = :net_kernel.start([node_name, :shortnames])

    on_exit(fn ->
      assert :ok = :net_kernel.stop()

      case previous_partition_guard do
        {:ok, value} -> Application.put_env(:kernel, :prevent_overlapping_partitions, value)
        :error -> Application.delete_env(:kernel, :prevent_overlapping_partitions)
      end
    end)
  end

  defp start_test_distribution!(_distributed_node), do: :ok

  defp start_current_peer!(prefix) do
    {_peer_pid, peer_node} = start_current_peer_process!(prefix)
    peer_node
  end

  defp start_current_peer_process!(prefix) do
    ensure_test_distribution_started!()

    peer_name = String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

    assert {:ok, peer_pid, peer_node} =
             :peer.start_link(%{
               name: peer_name,
               args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
             })

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

  defp await_owner_cancellation!(owner_pid, attempts \\ 100)

  defp await_owner_cancellation!(owner_pid, attempts) when attempts > 0 do
    case :sys.get_state(owner_pid) do
      %{active_turn: nil, downstream: nil} ->
        :ok

      _state ->
        yield_once({:await_owner_cancellation, owner_pid, attempts})
        await_owner_cancellation!(owner_pid, attempts - 1)
    end
  end

  defp await_owner_cancellation!(owner_pid, 0) do
    assert %{active_turn: nil, downstream: nil} = :sys.get_state(owner_pid)
  end

  defp yield_once(message) do
    send(self(), message)

    receive do
      ^message -> :ok
    end
  end

  defp previous_release_forwarder_beam(module) do
    harness = WebsocketOwnerNodeHarness

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [remote_attach_downstream: 2, remote_submit_request: 4]},
      {:function, 1, :remote_attach_downstream, 2,
       [
         {:clause, 1, [{:var, 1, :Session}, {:var, 1, :Downstream}], [],
          [
            {:call, 1, {:remote, 1, {:atom, 1, harness}, {:atom, 1, :previous_release_attach}},
             [{:var, 1, :Session}, {:var, 1, :Downstream}]}
          ]}
       ]},
      {:function, 1, :remote_submit_request, 4,
       [
         {:clause, 1,
          [
            {:var, 1, :Session},
            {:var, 1, :Downstream},
            {:var, 1, :Request},
            {:var, 1, :Opts}
          ], [],
          [
            {:call, 1,
             {:remote, 1, {:atom, 1, harness}, {:atom, 1, :previous_release_submit_request}},
             [
               {:var, 1, :Session},
               {:var, 1, :Downstream},
               {:var, 1, :Request},
               {:var, 1, :Opts}
             ]}
          ]}
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
