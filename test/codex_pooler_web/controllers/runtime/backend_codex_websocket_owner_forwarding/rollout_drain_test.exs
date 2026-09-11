defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.RolloutDrainTest do
  @moduledoc """
  owner lifecycle terminal-state matrix

  This module is the nearest implementation-facing contract for owner-forwarded
  websocket failures. Keep these terminal states stable so later regression
  tests can grep the matrix before changing behavior.

  - `owner_unavailable` during downstream detach: cleanup-only, sanitized
    failure, triggers bounded recovery/interruption when an active turn may
    exist, and does not create a client-visible request by itself.
  - `owner_unavailable` during request/processed forwarding before upstream
    I/O: request and attempt finalize failed, turn finalizes failed, HTTP/status
    503, code `owner_unavailable`. An unresolved `previous_response_id` alias
    is instead a retarget cache miss: it retains the current authenticated
    runtime without an owner-outage error; the unchanged generation guard may
    later reject that continuation with `previous_response_not_found`.
  - `owner_drained` after the rollout deadline: request and attempt failed,
    response status 499, turn interrupted, session interrupted, lease release
    reason `owner_drained`; before that deadline, active turns remain alive.
  - late owner drain after request success: request and attempt remain
    succeeded; turn remains or becomes succeeded; no owner error overwrite.
  - persistence failure during owner exit: sanitized observability event plus
    the same synchronous inline recovery helper to be implemented later; no
    Oban/supervised async recovery and no silent swallow.
  """

  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias Ecto.Adapters.SQL.Sandbox

  @sentinel "SECRET_SENTINEL_DO_NOT_STORE_123"
  @handoff_detection_timeout_ms 15_000

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

  @tag :rollout_drain_deadline_contract
  test "local owner deadline expiry releases lease interrupts active turn and permits fresh owner reconnect" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_death"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-clean-exit", "stable-ws-owner-clean-exit",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "deadline expiry while owner turn is active")
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    assert [turn] =
             Repo.all(
               from turn in CodexTurn,
                 where: turn.codex_session_id == ^state.codex_session.id
             )

    request = Repo.get!(Request, turn.request_id)
    attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^request.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    old_token = state.codex_session.owner_lease_token
    owner_ref = Process.monitor(owner_pid)

    harness = start_rollout_drain_harness()
    deadline = harness.deadline

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 25, deadline_margin_ms: 20, deadline_floor_ms: 10] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, 10}
    assert Repo.get!(CodexTurn, turn.id).status == "in_progress"
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(harness.deadline, 10)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}
    assert_response_task_stopped!(state)
    assert %{turns_completed: 0, turns_aborted: 1} = Task.await(drain_task, 1_000)

    assert released_lease = released_owner_lease(state.codex_session.id, old_token)
    assert released_lease.metadata["release_reason"] == "owner_drained"
    refute released_lease.metadata["release_reason"] == "pinned_continuation_reauth_required"
    refute released_lease.metadata["release_reason"] == "owner_crashed"
    assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, turn.id).error_code == "owner_drained"
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == attempt.id
    assert Repo.get!(Request, request.id).status == "failed"
    assert Repo.get!(Request, request.id).response_status_code == 499
    assert Repo.get!(Request, request.id).last_error_code == "owner_drained"
    refute Repo.get!(Request, request.id).last_error_code == "pinned_continuation_reauth_required"
    assert Repo.get!(Attempt, attempt.id).network_error_code == "owner_drained"

    {:ok, reconnect_state} =
      owner_socket(
        auth,
        "ws-owner-clean-exit-reconnect",
        "stable-ws-owner-clean-exit"
      )

    try do
      assert reconnect_state.codex_session.id == state.codex_session.id
      assert reconnect_state.codex_session.owner_lease_token != old_token
      assert {:ok, fresh_owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      assert fresh_owner_pid != owner_pid

      assert active_owner_lease(reconnect_state.codex_session.id).lease_token ==
               reconnect_state.codex_session.owner_lease_token
    after
      CodexResponsesSocket.terminate(:closed, reconnect_state)
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  @tag :owner_drained_terminal_state
  @tag :replay_cleanup
  @tag :findings116
  test "owner drain sends safe interruption releases lease and suppresses later stale downstream terminate" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_drain"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-drain-first",
          accepted_turn_state: "stable-ws-owner-drain",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: first_state} =
      active_socket_turn_fixture(setup, upstream, first_state)

    release_task = suspend_cleanup_task!(first_state)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    assert :ok = WebsocketOwnerSession.drain_owner(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    assert_receive {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.metadata.reason == "owner_drained"

    assert released_owner_lease(
             first_state.codex_session.id,
             first_state.codex_session.owner_lease_token
           )

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: first_state.codex_session,
      error_code: "owner_drained"
    })

    release_task.()

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-drain-second",
          accepted_turn_state: "stable-ws-owner-drain",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert second_state.websocket_owner_downstream.epoch == 1
      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(second_state.codex_session.id)
      assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  @tag :owner_drained_terminal_state
  test "late owner drain preserves already succeeded request attempt and turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_late_drain"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-late-drain",
          accepted_turn_state: "stable-ws-owner-late-drain",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "owner_late_drain_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    assert :ok = WebsocketOwnerSession.drain_owner(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    assert_receive {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.metadata.reason == "owner_drained"

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    assert Repo.get!(CodexSession, state.codex_session.id).status == state.codex_session.status

    logs = capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, state) end)

    refute logs =~ "websocket owner detach failed"
    refute logs =~ "owner_unavailable"
    assert_no_leak!("late owner drain detach logs", logs)

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
  end

  @tag :rollout_drain_t5
  test "T5 socket terminate aborts an active owner while rollout drain waits" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-rollout-wait-disconnect", "rollout-wait-disconnect",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "disconnect while rollout drain waits")
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    owner_pid = state.websocket_owner_pid
    owner_ref = Process.monitor(owner_pid)

    session =
      Repo.get_by!(CodexSession, session_key: turn_state_session_key("rollout-wait-disconnect"))

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    request = Repo.get!(Request, turn.request_id)
    attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

    previous_drain_config = Application.get_env(:codex_pooler, RolloutDrain)
    harness = start_rollout_drain_harness()
    deadline = harness.deadline
    WebsocketRolloutDrainSupport.configure_rollout_drain_server(harness.name)

    on_exit(fn ->
      if previous_drain_config do
        Application.put_env(:codex_pooler, RolloutDrain, previous_drain_config)
      else
        Application.delete_env(:codex_pooler, RolloutDrain)
      end
    end)

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    try do
      assert_receive {:rollout_drain_deadline_wait, ^deadline, _wait_ms}
      assert Process.alive?(owner_pid)

      terminate_task =
        Task.async(fn -> CodexResponsesSocket.terminate({:shutdown, :rollout}, state) end)

      assert :ok = Task.await(terminate_task, 1_000)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}
      assert_response_task_stopped!(state)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: session,
        error_code: "owner_drained"
      })

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert %{
               owners_seen: 1,
               owners_drained: 0,
               owners_failed: 1,
               turns_completed: 0,
               turns_aborted: 0
             } = Task.await(drain_task, 1_000)

      refute_received {:rollout_drain_deadline_wait, ^deadline, _wait_ms}
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  @tag :rollout_drain_t1
  @tag :rollout_drain_t7
  test "T1/T7 real terminal succeeds before owner stop and precedes the reconnect close" do
    release_ref = make_ref()

    terminal = %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_rollout_terminal_order", "status" => "completed"}
    }

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-rollout-terminal-order"
    turn_state = "stable-ws-owner-rollout-terminal-order"
    {:ok, state} = owner_socket(auth, request_id, turn_state)
    owner_pid = state.websocket_owner_pid
    owner_ref = Process.monitor(owner_pid)

    payload = websocket_payload(setup, "synthetic rollout terminal ordering")
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid,
                    ^release_ref},
                   1_000

    harness = start_rollout_drain_harness()
    deadline = harness.deadline

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, wait_ms}
    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

    assert {:push, {:text, terminal_frame}, state} = receive_owner_socket_push(state)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(terminal_frame)
    assert {:ok, state} = receive_owner_socket_complete(state)
    assert {:ok, state} = receive_socket_done(state)

    turn =
      Repo.one!(
        from turn in CodexTurn,
          where: turn.codex_session_id == ^state.codex_session.id
      )

    request = Repo.get!(Request, turn.request_id)
    attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

    reconnect_logs =
      capture_log([level: :warning], fn ->
        assert {:stop, :normal, {1001, "websocket owner is draining"}, _reconnect_state} =
                 owner_socket(auth, "ws-owner-rollout-terminal-order-reconnect", turn_state)
      end)

    assert reconnect_logs =~ WebsocketConnectionLogger.init_failed_message()
    assert reconnect_logs =~ "phase=init"
    assert reconnect_logs =~ "reason_class=owner_drained"
    refute reconnect_logs =~ turn_state
    refute reconnect_logs =~ "resp_rollout_terminal_order"
    refute reconnect_logs =~ @sentinel
    refute reconnect_logs =~ "authorization"
    refute reconnect_logs =~ "bearer"

    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, wait_ms)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}
    assert %{turns_completed: 1, turns_aborted: 0} = Task.await(drain_task, 1_000)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, close_barrier_pid,
                    ^release_ref},
                   1_000

    send(close_barrier_pid, {:fake_upstream_release_websocket, release_ref})
    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

    CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
  end

  @tag :rollout_drain_t8
  @tag :findings116
  test "T8 delayed old-owner termination preserves replacement ownership and turn state" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, old_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-delayed-terminate",
        owner_instance_id: "old-owner.example"
      })

    old_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    {:ok, old_owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: old_session.id,
        owner_lease_token: old_session.owner_lease_token,
        owner_instance_id: old_session.owner_instance_id,
        upstream: old_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _old_upstream_pid}

    on_exit(fn ->
      if Process.alive?(old_owner), do: GenServer.stop(old_owner)
    end)

    old_owner_ref = Process.monitor(old_owner)
    old_lease = active_owner_lease(old_session.id)

    replacement_owner_instance = "replacement-owner.example"

    replacement_opts =
      %{owner_instance_id: replacement_owner_instance}
      |> RequestOptions.for_websocket()

    assert {:ok, replacement_session} =
             SessionContinuity.replace_unavailable_owner_lease(old_session, replacement_opts)

    replacement_lease = active_owner_lease(old_session.id)
    assert replacement_lease.lease_token == replacement_session.owner_lease_token
    assert replacement_lease.lease_token != old_lease.lease_token
    assert replacement_lease.owner_instance_id == replacement_owner_instance

    replacement_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    {:ok, replacement_owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: replacement_session.id,
        owner_lease_token: replacement_session.owner_lease_token,
        owner_instance_id: replacement_session.owner_instance_id,
        upstream: replacement_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _replacement_upstream_pid}

    on_exit(fn ->
      if Process.alive?(replacement_owner), do: GenServer.stop(replacement_owner)
    end)

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, replacement_session)

    assert :ok = GenServer.stop(old_owner)
    assert_receive {:DOWN, ^old_owner_ref, :process, ^old_owner, :normal}

    assert Process.alive?(replacement_owner)
    replacement_request = Repo.get!(Request, request.id)
    replacement_attempt = Repo.get!(Attempt, attempt.id)
    replacement_turn = Repo.get!(CodexTurn, turn.id)
    replacement_session = Repo.get!(CodexSession, replacement_session.id)

    assert replacement_request.status == "in_progress"
    assert is_nil(replacement_request.last_error_code)
    assert replacement_attempt.status == "in_progress"
    assert is_nil(replacement_attempt.network_error_code)
    assert replacement_turn.status == "in_progress"
    assert replacement_turn.request_id == replacement_request.id
    assert replacement_turn.codex_session_id == replacement_session.id
    assert is_nil(replacement_turn.error_code)
    assert replacement_session.status == "active"

    assert replacement_session.owner_lease_token == replacement_lease.lease_token

    assert Repo.get!(BridgeOwnerLease, replacement_lease.id).status == "active"
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "replacement_owner_turn"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
    assert :ok = GenServer.stop(replacement_owner)
    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
  end

  @tag :rollout_drain_t8
  @tag :findings116
  test "T8 current-owner termination releases its lease and interrupts its active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-current-owner-terminate",
        owner_instance_id: "current-owner.example"
      })

    block_ref = make_ref()

    owner_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), block_ref: block_ref)

    {:ok, owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: session.id,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id,
        upstream: owner_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _owner_upstream_pid}
    owner_ref = Process.monitor(owner)
    lease = active_owner_lease(session.id)
    %{request: request, attempt: attempt, turn: turn} = active_turn_fixture(setup, auth, session)
    accept_fixture_owner_request!(owner, session, request, attempt, block_ref)

    assert :ok = GenServer.stop(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert released_owner_lease(session.id, lease.lease_token).metadata["release_reason"] ==
             "owner_drained"

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: session,
      error_code: "owner_drained"
    })
  end

  test "T8 delayed same-token owner cleanup preserves replacement and predecessor rows" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-fallback-turn-survives-terminate",
        owner_instance_id: "fallback-owner.example"
      })

    block_ref = make_ref()

    owner_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), block_ref: block_ref)

    {:ok, owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: session.id,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id,
        upstream: owner_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _owner_upstream_pid}
    owner_ref = Process.monitor(owner)

    %{request: ws_request, attempt: ws_attempt, turn: ws_turn} =
      active_turn_fixture(setup, auth, session)

    accept_fixture_owner_request!(owner, session, ws_request, ws_attempt, block_ref)

    %{request: fallback_request, attempt: fallback_attempt, turn: fallback_turn} =
      active_turn_fixture(setup, auth, session, "http_sse")

    assert :ok = GenServer.stop(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert Repo.reload!(ws_request).status == "in_progress"
    assert Repo.reload!(ws_attempt).status == "in_progress"
    assert Repo.reload!(ws_turn).status == "in_progress"

    surviving_request = Repo.get!(Request, fallback_request.id)
    surviving_attempt = Repo.get!(Attempt, fallback_attempt.id)
    surviving_turn = Repo.get!(CodexTurn, fallback_turn.id)

    assert surviving_request.status == "in_progress"
    assert is_nil(surviving_request.last_error_code)
    assert surviving_attempt.status == "in_progress"
    assert is_nil(surviving_attempt.network_error_code)
    assert surviving_turn.status == "in_progress"
    assert is_nil(surviving_turn.error_code)
  end

  @tag :owner_drained_terminal_state
  test "planned rollout drain during active owner request records owner drained instead of owner crashed" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-rollout-drain-active-request", "rollout-drain-active-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "rollout drain while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate({:shutdown, :rollout}, state)
        end)

      refute logs =~ "owner_crashed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("rollout-drain-active-request")
        )

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "owner_drained"
      refute request.last_error_code == "owner_crashed"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "owner_drained"
      refute attempt.network_error_code == "owner_crashed"
      assert turn.status == "interrupted"
      assert turn.error_code == "owner_drained"
      refute turn.error_code == "owner_crashed"

      assert released_owner_lease(
               session.id,
               state.websocket_owner_lease_token
             ).metadata["release_reason"] == "owner_drained"
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  @tag :owner_drained_terminal_state
  test "owner drain persists its exact interruption before replying to the response task" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-rollout-drain-active-request", "rollout-drain-active-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "rollout drain while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    parent = self()
    owner = state.websocket_owner_pid
    original_persistence = :sys.get_state(owner).persistence

    :sys.replace_state(owner, fn current ->
      put_in(current.persistence.interrupt_codex_session, fn session_id, opts ->
        unless Process.get(release_ref, false) do
          Process.put(release_ref, true)
          send(parent, {:owner_interruption_barrier, self(), release_ref})

          receive do
            {:release_owner_interruption, ^release_ref} -> :ok
          after
            15_000 -> raise "owner interruption barrier timed out"
          end
        end

        original_persistence.interrupt_codex_session.(session_id, opts)
      end)
    end)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          drain =
            Task.async(fn ->
              Sandbox.allow(Repo, parent, self())
              CodexResponsesSocket.terminate({:shutdown, :rollout}, state)
            end)

          assert_receive {:owner_interruption_barrier, ^owner, ^release_ref}, 15_000
          assert [%{status: "in_progress", completed_at: nil}] = request_logs(setup.pool.id)

          assert Repo.aggregate(
                   from(l in LedgerEntry,
                     join: r in Request,
                     on: l.request_id == r.id,
                     where: r.pool_id == ^setup.pool.id and l.entry_kind == "settlement"
                   ),
                   :count
                 ) == 0

          send(owner, {:release_owner_interruption, release_ref})
          assert :ok = Task.await(drain, 15_000)
        end)

      refute logs =~ "owner_crashed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("rollout-drain-active-request")
        )

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "owner_drained"
      refute request.last_error_code == "owner_crashed"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "owner_drained"
      refute attempt.network_error_code == "owner_crashed"
      assert turn.status == "interrupted"
      assert turn.error_code == "owner_drained"
      refute turn.error_code == "owner_crashed"

      assert released_owner_lease(
               session.id,
               state.websocket_owner_lease_token
             ).metadata["release_reason"] == "owner_drained"
    after
      send(owner, {:release_owner_interruption, release_ref})
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  test "owner rollout timeline preserves interrupted and recovered websocket rows" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: the interrupted turn is held pre-visible until
        # the client has disconnected and then closes without a terminal; the
        # takeover owner sends exactly one recovered turn and nothing else.
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
                reason: "synthetic interrupted timeline close"
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_timeline_recovered",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-rollout-timeline"
    interrupted_request_id = "ws-owner-timeline-interrupted"
    recovered_request_id = "ws-owner-timeline-recovered"

    {:ok, state} = owner_socket(auth, interrupted_request_id, turn_state)

    payload =
      websocket_payload(setup, "owner timeline interrupted", %{
        "request_id" => interrupted_request_id
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   1_000

    assert_receive {:websocket_owner_cleanup_witness, _, _, _, _} = cleanup_message,
                   @handoff_detection_timeout_ms

    assert {:ok, state} = CodexResponsesSocket.handle_info(cleanup_message, state)

    assert [interrupted_upstream_request] = await_upstream_requests(upstream, 1)

    assert interrupted_upstream_request.json["input"] |> List.first() |> Map.get("content") ==
             "owner timeline interrupted"

    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

    interrupted_request =
      Repo.one!(
        from r in Request,
          where: r.pool_id == ^setup.pool.id
      )

    assert_native_turn_correlation!(interrupted_request.correlation_id)

    interrupted_attempt =
      Repo.one!(from a in Attempt, where: a.request_id == ^interrupted_request.id)

    interrupted_turn =
      Repo.one!(from t in CodexTurn, where: t.request_id == ^interrupted_request.id)

    session = Repo.get_by!(CodexSession, session_key: turn_state_session_key(turn_state))
    refute_raw_turn_state_session_key!(setup.pool.id, turn_state)

    assert_owner_interruption_state!(%{
      request: interrupted_request,
      attempt: interrupted_attempt,
      turn: interrupted_turn,
      session: session,
      error_code: "client_disconnected"
    })

    remote_node = :"codex_pooler@timeline-unavailable-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    old_lease = active_owner_lease(session.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session
    |> Ecto.Changeset.change(%{owner_instance_id: remote_node_string, updated_at: now})
    |> Repo.update!()

    old_lease
    |> Ecto.Changeset.change(%{owner_instance_id: remote_node_string, updated_at: now})
    |> Repo.update!()

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    logs =
      capture_info_log(fn ->
        {:ok, recovered_state} =
          owner_socket(auth, recovered_request_id, turn_state,
            websocket_owner_forwarder_opts: forwarder_opts
          )

        try do
          recovered_payload =
            websocket_payload(setup, "owner timeline recovered", %{
              "request_id" => recovered_request_id
            })

          assert {:ok, recovered_state} =
                   CodexResponsesSocket.handle_in(
                     {recovered_payload, [opcode: :text]},
                     recovered_state
                   )

          assert {:push, {:text, recovered_frame}, recovered_state} =
                   receive_owner_socket_push(recovered_state)

          assert %{"id" => "resp_owner_timeline_recovered"} =
                   CodexPooler.JSON.decode!(recovered_frame)

          assert {:ok, _recovered_state} = receive_socket_done(recovered_state)
        after
          CodexResponsesSocket.terminate(:closed, recovered_state)
        end
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=#{recovered_request_id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    assert_no_leak!("owner rollout timeline takeover logs", logs)

    released_lease = Repo.get!(BridgeOwnerLease, old_lease.id)
    assert released_lease.status == "released"
    assert released_lease.metadata["release_reason"] == "owner_unavailable_takeover"

    active_lease = active_owner_lease(session.id)
    assert active_lease.owner_instance_id == Atom.to_string(node())
    assert active_lease.metadata["source"] == "owner_unavailable_takeover"

    recovered_request =
      Repo.one!(
        from r in Request,
          where: r.pool_id == ^setup.pool.id and r.id != ^interrupted_request.id
      )

    assert_native_turn_correlation!(recovered_request.correlation_id)

    recovered_attempt = Repo.one!(from a in Attempt, where: a.request_id == ^recovered_request.id)
    recovered_turn = Repo.one!(from t in CodexTurn, where: t.request_id == ^recovered_request.id)

    assert Repo.get!(Request, interrupted_request.id).status == "failed"
    assert Repo.get!(Request, interrupted_request.id).response_status_code == 499
    assert Repo.get!(Request, interrupted_request.id).last_error_code == "client_disconnected"
    assert Repo.get!(Attempt, interrupted_attempt.id).status == "failed"
    assert Repo.get!(Attempt, interrupted_attempt.id).network_error_code == "client_disconnected"
    assert Repo.get!(CodexTurn, interrupted_turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, interrupted_turn.id).error_code == "client_disconnected"

    assert recovered_request.status == "succeeded"
    assert recovered_request.response_status_code == 200
    assert is_nil(recovered_request.last_error_code)
    assert recovered_attempt.status == "succeeded"
    assert recovered_attempt.upstream_status_code == 200
    assert is_nil(recovered_attempt.network_error_code)
    assert recovered_turn.status == "succeeded"
    assert is_nil(recovered_turn.error_code)
    assert recovered_turn.final_attempt_id == recovered_attempt.id

    assert [first_upstream_request, second_upstream_request] =
             await_upstream_requests(upstream, 2)

    assert Enum.map([first_upstream_request, second_upstream_request], fn request ->
             request.json["input"] |> List.first() |> Map.get("content")
           end) == ["owner timeline interrupted", "owner timeline recovered"]

    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp accept_fixture_owner_request!(owner, session, request, attempt, block_ref) do
    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: self(),
               correlation_id: Ecto.UUID.generate()
             })

    request
    |> Ecto.Changeset.change(
      request_metadata: %{
        "codex_session_id" => session.id,
        "websocket_owner_forwarding" => %{
          "owner_instance_id" => session.owner_instance_id,
          "downstream_epoch" => downstream.epoch
        }
      }
    )
    |> Repo.update!()

    submission = %UpstreamWebsocketSession.Request{
      request_id: request.id,
      attempt_id: attempt.id,
      url: "http://127.0.0.1/unused",
      headers: [],
      payload: "{}"
    }

    caller = self()

    submitter =
      spawn(fn ->
        result = WebsocketOwnerSession.submit_request(owner, downstream, submission)
        send(caller, {:fixture_owner_submission_finished, self(), result})
      end)

    monitor = Process.monitor(submitter)

    on_exit(fn ->
      if Process.alive?(submitter), do: Process.exit(submitter, :shutdown)
    end)

    assert_receive {:websocket_owner_harness_barrier, _worker, ^block_ref},
                   @handoff_detection_timeout_ms

    assert_receive {:websocket_owner_cleanup_witness, _correlation, _epoch, _task, witness},
                   @handoff_detection_timeout_ms

    assert witness.request_id == request.id
    assert witness.attempt_id == attempt.id
    {submitter, monitor}
  end

  defp active_turn_fixture(setup, auth, session, transport \\ "websocket") do
    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "owner lifecycle"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: transport,
                 correlation_id: "ws-owner-lifecycle-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)
    %{request: reserved.request, attempt: attempt, turn: turn}
  end
end
