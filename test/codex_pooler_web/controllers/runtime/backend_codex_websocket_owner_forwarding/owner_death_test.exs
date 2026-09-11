defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.OwnerDeathTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestClientRetryLink
  alias CodexPooler.Accounting.RequestLogFact
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
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

  test "remote owner loss before visible output recovers without re-resolving the turn mode" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_mode_loss_recovered",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "full")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-mode-loss", "owner-mode-loss")
    remote_node = :"codex_pooler@lost-mode-owner.example"

    base_node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(state, remote_node, base_node_opts)
    release_ref = make_ref()
    parent = self()

    try do
      lost_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [
              calls: %{
                remote_node =>
                  {:barrier_return, parent, release_ref, {:error, :owner_unavailable}}
              },
              notify: parent,
              capture_request_to: parent
            ],
            fn node_opts ->
              Gateway.run_websocket_response(
                auth,
                model_serving_owner_payload(setup, "remote-owner-loss", "client-true"),
                owner_response_options(remote_state, node_opts),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert_receive {:websocket_owner_harness_call_barrier, rpc_pid, ^release_ref,
                      :remote_submit_request_v1},
                     1_000

      try do
        _revision = set_model_serving_mode!(scope, setup, "lite", revision)
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})

        assert :ok = Task.await(lost_turn, 3_000)
      after
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})
      end

      original_downstream = remote_state.websocket_owner_downstream

      assert_receive {:websocket_owner_frame, correlation_id, recovered_epoch,
                      {:data, recovered_metadata_frame}},
                     1_000

      assert correlation_id == original_downstream.correlation_id
      assert recovered_epoch > original_downstream.epoch

      assert %{
               "type" => "codex.response.metadata",
               "headers" => %{"x-models-etag" => _models_etag}
             } = CodexPooler.JSON.decode!(recovered_metadata_frame)

      assert_receive {:websocket_owner_frame, ^correlation_id, ^recovered_epoch,
                      {:data, recovered_frame}},
                     1_000

      assert owner_response_id(recovered_frame) == "resp_owner_mode_loss_recovered"

      assert_receive {:websocket_owner_frame, ^correlation_id, ^recovered_epoch, :complete},
                     1_000

      assert [recovered_upstream_request] = FakeUpstream.requests(upstream)
      assert_canonical_full_owner_request!(recovered_upstream_request)

      assert [request] = request_logs(setup.pool.id)
      assert request.retry_count == 0
      assert request.last_error_code == nil
      assert_owner_mode_accounting!(request, "full", "succeeded", remote_node)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :owner_crash_recovery
  test "replacement owner preserves the active proxy epoch after pre-visible owner death" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: the first send is held pre-visible until the
        # owner is killed and the connection then closes without a terminal, the
        # replacement owner replays exactly one lite turn, and the next socket
        # sends exactly one full turn.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: release_ref,
                code: 1001,
                reason: "synthetic pre-visible owner death close"
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_mode_kill_recovered",
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
                  "id" => "resp_owner_mode_kill_next_turn",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "lite")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-mode-kill", "owner-mode-kill")
    remote_node = :"codex_pooler@killed-mode-owner.example"

    base_node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    stale_downstream = state.websocket_owner_downstream
    {:ok, old_owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

    assert {:ok, active_downstream} =
             WebsocketOwnerSession.attach_downstream(old_owner_pid, %{
               pid: self(),
               correlation_id: stale_downstream.correlation_id
             })

    assert stale_downstream.epoch == 1
    assert active_downstream.epoch == 2

    active_state = %{state | websocket_owner_downstream: active_downstream}
    remote_state = remote_owner_state(active_state, remote_node, base_node_opts)
    old_lease = active_owner_lease(state.codex_session.id)
    old_owner_ref = Process.monitor(old_owner_pid)
    parent = self()

    stale_frame = CodexPooler.JSON.encode!(%{"id" => "resp_stale_owner_attachment"})

    assert {:ok, ^remote_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, stale_downstream.correlation_id, stale_downstream.epoch,
                {:data, stale_frame}},
               remote_state
             )

    try do
      interrupted_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [
              calls: %{remote_node => :success},
              notify: parent,
              capture_request_to: parent
            ],
            fn node_opts ->
              Gateway.run_websocket_response(
                auth,
                model_serving_owner_payload(setup, "remote-owner-kill", "client-false"),
                owner_response_options(remote_state, node_opts),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid,
                      ^release_ref},
                     1_000

      try do
        assert [projected_lite_request] = await_upstream_requests(upstream, 1)
        assert_canonical_lite_owner_request!(projected_lite_request)

        assert [in_progress_request] = request_logs(setup.pool.id)
        assert in_progress_request.status == "in_progress"
        assert in_progress_request.retry_count == 0

        assert [in_progress_attempt] =
                 Repo.all(from(a in Attempt, where: a.request_id == ^in_progress_request.id))

        assert in_progress_attempt.status == "in_progress"

        assert in_progress_turn =
                 Repo.one!(from(t in CodexTurn, where: t.request_id == ^in_progress_request.id))

        assert in_progress_turn.status == "in_progress"
        assert is_nil(in_progress_turn.first_visible_output_at)
        assert active_owner_lease(state.codex_session.id).lease_token == old_lease.lease_token

        _revision = set_model_serving_mode!(scope, setup, "full", revision)

        Process.exit(old_owner_pid, :kill)
        assert_receive {:DOWN, ^old_owner_ref, :process, ^old_owner_pid, :killed}, 1_000
        send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

        assert :ok = Task.await(interrupted_turn, 3_000)

        assert_receive {:websocket_owner_runtime_recovered, correlation_id, epoch, runtime},
                       1_000

        assert correlation_id == active_downstream.correlation_id
        assert epoch == active_downstream.epoch

        assert {:ok, recovered_remote_state} =
                 CodexResponsesSocket.handle_info(
                   {:websocket_owner_runtime_recovered, correlation_id, epoch, runtime},
                   remote_state
                 )

        refute recovered_remote_state.websocket_owner_lease_token ==
                 remote_state.websocket_owner_lease_token

        assert FakeUpstream.count(upstream) == 2
        assert [recovered_request] = request_logs(setup.pool.id)
        assert_owner_mode_accounting!(recovered_request, "lite", "succeeded", remote_node)

        assert recovered_turn =
                 Repo.one!(from(t in CodexTurn, where: t.request_id == ^recovered_request.id))

        assert recovered_turn.status == "succeeded"
        refute is_nil(recovered_turn.first_visible_output_at)

        assert {:push, {:text, recovered_frame}, recovered_remote_state} =
                 receive_owner_socket_push(recovered_remote_state)

        assert owner_response_id(recovered_frame) == "resp_owner_mode_kill_recovered"

        assert {:ok, recovered_remote_state} =
                 receive_owner_socket_complete(recovered_remote_state)

        active_correlation_id = active_downstream.correlation_id
        active_epoch = active_downstream.epoch

        refute_receive {:websocket_owner_frame, ^active_correlation_id, ^active_epoch, _payload},
                       100

        replacement_session = Repo.get!(CodexSession, state.codex_session.id)
        replacement_lease = active_owner_lease(state.codex_session.id)
        released_lease = Repo.get!(BridgeOwnerLease, old_lease.id)

        assert released_lease.status == "released"
        assert released_lease.metadata["release_reason"] == "owner_unavailable_takeover"
        assert replacement_lease.lease_token != old_lease.lease_token
        assert replacement_lease.lease_token == replacement_session.owner_lease_token

        assert recovered_remote_state.websocket_owner_lease_token ==
                 replacement_session.owner_lease_token

        assert recovered_remote_state.codex_session.owner_lease_token ==
                 replacement_session.owner_lease_token

        assert replacement_lease.owner_instance_id == replacement_session.owner_instance_id

        assert {:ok, replacement_owner_pid} =
                 WebsocketOwnerSession.lookup(state.codex_session.id)

        assert replacement_owner_pid != old_owner_pid

        replacement_owner_state = :sys.get_state(replacement_owner_pid)
        assert replacement_owner_state.owner_lease_token == replacement_lease.lease_token
        assert replacement_owner_state.downstream == active_downstream

        {:ok, next_state} =
          owner_socket(auth, "ws-owner-mode-kill-next", "owner-mode-kill")

        next_remote_state = remote_owner_state(next_state, remote_node, base_node_opts)

        try do
          assert :ok =
                   WebsocketOwnerNodeHarness.with_node_client(
                     [remote_node],
                     [
                       calls: %{remote_node => :success},
                       notify: self(),
                       capture_request_to: self()
                     ],
                     fn node_opts ->
                       Gateway.run_websocket_response(
                         auth,
                         model_serving_owner_payload(
                           setup,
                           "remote-owner-kill-next",
                           "client-true"
                         ),
                         owner_response_options(next_remote_state, node_opts),
                         fn _data -> :ok end
                       )
                     end
                   )

          assert_remote_submit_request_v1!(next_remote_state, remote_node, nil, 1_000)

          assert {:push, {:text, next_frame}, next_remote_state} =
                   receive_owner_socket_push(next_remote_state)

          assert owner_response_id(next_frame) == "resp_owner_mode_kill_next_turn"
          assert {:ok, _next_remote_state} = receive_owner_socket_complete(next_remote_state)
        after
          CodexResponsesSocket.terminate(:closed, next_remote_state)
        end

        assert [killed_lite_request, recovered_lite_request, full_request] =
                 await_upstream_requests(upstream, 3)

        assert_canonical_lite_owner_request!(killed_lite_request)
        assert_canonical_lite_owner_request!(recovered_lite_request)
        assert_canonical_full_owner_request!(full_request)

        assert [lite_request, full_request] = request_logs(setup.pool.id)
        assert lite_request.retry_count == 0
        assert_owner_mode_accounting!(lite_request, "lite", "succeeded", remote_node)
        assert_owner_mode_accounting!(full_request, "full", "succeeded", remote_node)

        assert active_owner_lease(state.codex_session.id).lease_token ==
                 replacement_lease.lease_token

        assert :ok = FakeUpstream.verify!(upstream)
      after
        send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

        if Process.alive?(interrupted_turn.pid) do
          Task.shutdown(interrupted_turn, :brutal_kill)
        end
      end
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :owner_crash_recovery
  @tag :replay_cleanup
  @tag :replay_topology
  test "remote owner process death after visible output remains terminal" do
    release_ref = make_ref()
    upstream_boundary = visible_blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-visible-kill", "owner-visible-kill",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    remote_node = :"codex_pooler@visible-killed-owner.example"

    node_opts =
      [upstream: upstream_boundary] ++
        WebsocketOwnerNodeHarness.node_client_opts([remote_node],
          calls: %{remote_node => :success}
        )

    remote_state = remote_owner_state(state, remote_node, node_opts)
    old_lease = active_owner_lease(state.codex_session.id)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    parent = self()

    try do
      visible_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [calls: %{remote_node => :success}, notify: parent],
            fn harness_opts ->
              Gateway.run_websocket_response(
                auth,
                websocket_payload(setup, "visible owner crash"),
                owner_response_options(
                  remote_state,
                  [upstream: upstream_boundary] ++ harness_opts
                ),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_receive {:visible_blocking_owner_upstream, worker_pid, ^release_ref}, 1_000

      try do
        assert {:push, {:text, visible_frame}, _remote_state} =
                 receive_owner_socket_push(remote_state)

        assert owner_response_id(visible_frame) == "resp_owner_visible_before_crash"

        Process.exit(owner_pid, :kill)
        assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 1_000
        send(worker_pid, {:visible_blocking_owner_release, release_ref})

        assert {:error, %{code: "owner_crashed", status: 502}} =
                 Task.await(visible_turn, 3_000)

        assert {:error, :owner_unavailable} =
                 WebsocketOwnerSession.lookup(state.codex_session.id)

        assert active_owner_lease(state.codex_session.id).lease_token == old_lease.lease_token
        assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "active"
        assert FakeUpstream.count(upstream) == 0
      after
        send(worker_pid, {:visible_blocking_owner_release, release_ref})

        if Process.alive?(visible_turn.pid) do
          Task.shutdown(visible_turn, :brutal_kill)
        end
      end
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  test "malformed remote owner reply settles once as owner_crashed" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-malformed-reply", "owner-malformed-reply")
    remote_node = :"codex_pooler@malformed-reply-owner.example"
    private_owner_body = "private owner reply body"

    malformed_reply =
      {:ok,
       %{
         body: private_owner_body,
         terminal: "response.failed",
         status: 502,
         headers: %{}
       }}

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, malformed_reply}},
        capture_request_to: self()
      )

    remote_state = remote_owner_state(state, remote_node, node_opts)

    alias_ids_before =
      Repo.all(
        from(alias_record in BridgeSessionAlias,
          where: alias_record.codex_session_id == ^remote_state.codex_session.id,
          select: alias_record.id,
          order_by: [asc: alias_record.id]
        )
      )

    logs =
      capture_stream_outcome_telemetry(fn ->
        logs =
          capture_log(fn ->
            try do
              assert {:error, %{code: "owner_crashed", status: 502}} =
                       Gateway.run_websocket_response(
                         auth,
                         websocket_payload(setup, "malformed owner reply"),
                         owner_response_options(remote_state, node_opts),
                         fn _data -> :ok end
                       )
            after
              # The forced malformed reply also reaches the remote detach call, so
              # terminate doubles as the detach-containment regression.
              assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
            end
          end)

        assert_receive {:stream_outcome,
                        %{
                          outcome: "failed",
                          downstream_transport: "websocket",
                          upstream_transport: "websocket"
                        }}

        refute_received {:stream_outcome, _metadata}
        logs
      end)

    refute logs =~ private_owner_body
    refute logs =~ "websocket response task failed"

    # Both containment boundaries announce themselves under the same classifying
    # key instead of silently masquerading as a real owner crash, so one query
    # finds both.
    assert logs =~
             "websocket owner reply malformed boundary=submit " <>
               "reply_shape=map_invalid_fields invalid=status,headers"

    assert logs =~
             "websocket owner reply malformed boundary=detach " <>
               "reply_shape=ok_tuple_with_value canonical_error=owner_crashed"

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.response_status_code == 502
    assert request.last_error_code == "owner_crashed"

    # The submit-boundary line must carry the same upgrade request id the rest
    # of the websocket log family uses, so the two can be joined.
    assert logs =~ "canonical_error=owner_crashed request_id=ws-owner-malformed-reply"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"

    assert [turn] =
             Repo.all(
               from(t in CodexTurn, where: t.codex_session_id == ^remote_state.codex_session.id)
             )

    assert turn.status == "failed"

    assert Repo.all(
             from(alias_record in BridgeSessionAlias,
               where: alias_record.codex_session_id == ^remote_state.codex_session.id,
               select: alias_record.id,
               order_by: [asc: alias_record.id]
             )
           ) == alias_ids_before

    assert FakeUpstream.count(upstream) == 0

    assert_remote_submit_request_v1!(remote_state, remote_node)
  end

  test "local owner crash interrupts active turn without waiting for lease expiry" do
    # The owner is killed with `:kill` while it may hold a database query. On
    # the shared sandbox connection that kill takes the test's own connection
    # down with it (seen on a loaded CI runner as `DBConnection.OwnershipError`
    # at terminate), so this test gives every process its own connection, like
    # the peer-owner crash tests above.
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_crash"}))
    setup = gateway_setup(upstream)
    # Auto mode commits; the rows this test owns are purged so table-wide
    # assertions elsewhere in the file keep an empty baseline.
    pool_id = setup.pool.id
    identity_id = setup.identity.id
    on_exit(fn -> purge_committed_pool_rows!(pool_id, identity_id) end)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-crash",
          accepted_turn_state: "stable-ws-owner-crash",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    release_task = suspend_cleanup_task!(state)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}

    owner_monitor = state.websocket_owner_monitor
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :killed} = owner_down

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, state) end)

    assert {:stop, :normal, {1011, "websocket owner crashed"}, stopped_state} =
             handle_result

    refute Map.has_key?(stopped_state, :websocket_owner_monitor)
    refute Map.has_key?(stopped_state, :websocket_owner_pid)
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "pinned_continuation_reauth_required"
    refute logs =~ "owner_drained"
    refute logs =~ "client_disconnected"
    assert_no_leak!("local owner crash monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_crashed"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_crashed"

    release_task.()
    stop_parked_response_tasks!(stopped_state)

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(stopped_state, :websocket_owner_downstream)
    )
  end

  test "unexpected owner monitor exit still crashes active turn" do
    assert_abnormal_owner_monitor_down_crashes_active_turn!(
      {:unexpected_owner_exit, :boom},
      "unexpected-exit"
    )
  end

  test "owner monitor normal exit drains active turn without closing websocket" do
    assert_graceful_owner_monitor_down_drains_active_turn!(:normal, "normal")
  end

  test "owner monitor shutdown exit drains active turn and finalizes request attempt turn" do
    assert_graceful_owner_monitor_down_drains_active_turn!(:shutdown, "shutdown")
  end

  test "owner monitor rolling restart exit drains active turn and releases lease" do
    assert_graceful_owner_monitor_down_drains_active_turn!(
      {:shutdown, :rolling_restart},
      "rolling-restart"
    )
  end

  test "idle owner monitor shutdown exit drains lease without warning or finalization" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_idle_owner_shutdown"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-idle-shutdown",
          accepted_turn_state: "stable-ws-owner-monitor-idle-shutdown",
          client_ip: "127.0.0.1"
        }
      })

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(:shutdown)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, warning_logs} =
      with_log([level: :warning], fn ->
        CodexResponsesSocket.handle_info(owner_down, monitored_state)
      end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    assert warning_logs == ""
    assert_no_leak!("idle owner shutdown monitor logs", warning_logs)

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    assert Repo.aggregate(
             from(r in Request, where: r.pool_id == ^setup.pool.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(a in Attempt,
               join: r in Request,
               on: a.request_id == r.id,
               where: r.pool_id == ^setup.pool.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id),
             :count
           ) == 0

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  test "intentional stale owner replacement does not close monitored socket as crashed" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_down"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-down",
          accepted_turn_state: "stable-ws-owner-stale-down",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    release_task = suspend_cleanup_task!(state)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    owner_monitor = state.websocket_owner_monitor

    :ok = GenServer.stop(owner_pid, {:shutdown, :stale_owner})
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, {:shutdown, :stale_owner}}

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, {:shutdown, :stale_owner}} =
                     owner_down

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, state) end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    refute logs =~ "owner_crashed"
    refute logs =~ "owner_drained"
    refute logs =~ "pinned_continuation_reauth_required"
    assert_no_leak!("stale owner monitor logs", logs)

    assert Repo.get!(Request, request.id).status == "in_progress"
    assert Repo.get!(Attempt, attempt.id).status == "in_progress"
    assert Repo.get!(CodexTurn, turn.id).status == "in_progress"

    refute released_owner_lease_optional(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           )

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.codex_session.owner_lease_token

    assert kept_state.codex_session.owner_lease_token == state.codex_session.owner_lease_token

    release_task.()

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  # Removes every row an auto-mode test committed for its Pool, children first.
  defp purge_committed_pool_rows!(pool_id, identity_id) do
    Sandbox.unboxed_run(Repo, fn ->
      request_ids = Repo.all(from(r in Request, where: r.pool_id == ^pool_id, select: r.id))
      session_ids = Repo.all(from(s in CodexSession, where: s.pool_id == ^pool_id, select: s.id))

      Repo.delete_all(from(l in BridgeOwnerLease, where: l.codex_session_id in ^session_ids))
      Repo.delete_all(from(t in CodexTurn, where: t.codex_session_id in ^session_ids))
      Repo.delete_all(from(e in RequestReplayEntitlement, where: e.request_id in ^request_ids))

      Repo.delete_all(
        from(l in RequestClientRetryLink,
          where:
            l.predecessor_request_id in ^request_ids or l.successor_request_id in ^request_ids
        )
      )

      Repo.delete_all(from(l in LedgerEntry, where: l.request_id in ^request_ids))
      Repo.delete_all(from(a in Attempt, where: a.request_id in ^request_ids))
      Repo.delete_all(from(f in RequestLogFact, where: f.request_id in ^request_ids))
      Repo.delete_all(from(r in Request, where: r.pool_id == ^pool_id))
      Repo.delete_all(from(s in CodexSession, where: s.pool_id == ^pool_id))
      Repo.delete_all(from(k in APIKey, where: k.pool_id == ^pool_id))

      Repo.delete_all(
        from(a in CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment,
          where: a.pool_id == ^pool_id
        )
      )

      Repo.delete_all(from(p in CodexPooler.Pools.Pool, where: p.id == ^pool_id))

      Repo.delete_all(
        from(s in CodexPooler.Upstreams.Schemas.EncryptedSecret,
          where: s.upstream_identity_id == ^identity_id
        )
      )

      Repo.delete_all(from(i in UpstreamIdentity, where: i.id == ^identity_id))
    end)

    :ok
  end

  defp assert_abnormal_owner_monitor_down_crashes_active_turn!(owner_reason, suffix) do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_#{suffix}"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-#{suffix}",
          accepted_turn_state: "stable-ws-owner-monitor-#{suffix}",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(owner_reason)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, monitored_state) end)

    assert {:stop, :normal, {1011, "websocket owner crashed"}, stopped_state} =
             handle_result

    refute Map.has_key?(stopped_state, :websocket_owner_monitor)
    refute Map.has_key?(stopped_state, :websocket_owner_pid)
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "owner_drained"
    refute logs =~ "client_disconnected"
    assert_no_leak!("owner #{suffix} abnormal monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_crashed"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_crashed"

    stop_parked_response_tasks!(stopped_state)

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(stopped_state, :websocket_owner_downstream)
    )
  end

  defp assert_graceful_owner_monitor_down_drains_active_turn!(owner_reason, suffix) do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_#{suffix}"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-#{suffix}",
          accepted_turn_state: "stable-ws-owner-monitor-#{suffix}",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(owner_reason)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, monitored_state) end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    refute logs =~ "owner_crashed"
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "client_disconnected"
    assert_no_leak!("owner #{suffix} monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_drained"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    stop_parked_response_tasks!(kept_state)

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  defp owner_monitor_down(owner_reason) do
    owner_pid =
      spawn(fn ->
        receive do
          {:finish_owner, :normal} -> :ok
          {:finish_owner, reason} -> exit(reason)
        end
      end)

    owner_monitor = Process.monitor(owner_pid)
    send(owner_pid, {:finish_owner, owner_reason})
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, ^owner_reason} = owner_down
    {owner_pid, owner_monitor, owner_down}
  end

  test "missing cleanup witness for an accepted owner task remains observable and preserves work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "owner-missing-witness", "owner-missing-witness")
    %{state: state, request: request} = active_socket_turn_fixture(setup, upstream, state)
    release_task = suspend_cleanup_task!(state)

    incomplete =
      state
      |> Map.delete(:websocket_owner_cleanup_witness)
      |> Map.delete(:websocket_owner_cleanup_task)

    {_result, logs} =
      with_log(fn ->
        Adapter.handle_monitor_down(incomplete, state.websocket_owner_pid, :shutdown)
      end)

    assert logs =~ "failure_reason=stale_owner_cleanup"
    assert Repo.reload!(request).status == "in_progress"

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.websocket_owner_lease_token

    assert Process.alive?(state.websocket_owner_pid)
    release_task.()
    CodexResponsesSocket.terminate(:closed, state)
  end

  defp visible_blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, request, writer ->
        frame =
          CodexPooler.JSON.encode!(%{
            "id" => "resp_owner_visible_before_crash",
            "object" => "response"
          })

        decoded = CodexPooler.JSON.decode!(frame)

        cond do
          is_function(request.frame_observer, 2) -> request.frame_observer.(frame, decoded)
          is_function(request.frame_observer, 1) -> request.frame_observer.(frame)
          true -> :ok
        end

        writer.(frame, TerminalDiscriminator.classify(frame))
        send(test_pid, {:visible_blocking_owner_upstream, self(), release_ref})

        receive do
          {:visible_blocking_owner_release, ^release_ref} -> :ok
        after
          5_000 -> exit(:visible_blocking_owner_timeout)
        end
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp released_owner_lease_optional(session_id, lease_token) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^session_id and lease.lease_token == ^lease_token and
            lease.status == "released",
        limit: 1
    )
  end
end
