defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.OwnerDetachTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient
  alias CodexPoolerWeb.WebsocketConnectionLogger

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

  test "owner-forwarded response.processed reports owner unavailable when the local owner is gone" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-unavailable",
          accepted_turn_state: "stable-ws-owner-unavailable",
          client_ip: "127.0.0.1"
        }
      })

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    GenServer.stop(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    try do
      processed_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_unavailable"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)

      assert %{
               "type" => "error",
               "error" => %{"code" => "upstream_websocket_forward_failed", "message" => message}
             } = CodexPooler.JSON.decode!(error_frame)

      assert message =~ "owner_unavailable"
      refute error_frame =~ "pinned_continuation_reauth_required"
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner transport session mismatch rejects response.create before request admission" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-guard-create", "owner-guard-create")
    {:ok, other_state} = owner_socket(auth, "ws-owner-guard-create-other", "owner-guard-other")

    stale_state = %{state | codex_session: other_state.codex_session}

    try do
      payload = websocket_payload(setup, "owner transport guard create")

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{
               "status" => 409,
               "error" => %{
                 "code" => "stale_owner",
                 "message" => "websocket owner lease is stale"
               }
             } = CodexPooler.JSON.decode!(error_frame)

      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0

      assert request_logs(setup.pool.id) == []

      refute Repo.exists?(
               from a in Attempt,
                 join: r in Request,
                 on: r.id == a.request_id,
                 where: r.pool_id == ^setup.pool.id
             )
    after
      CodexResponsesSocket.terminate(:closed, state)
      CodexResponsesSocket.terminate(:closed, other_state)
    end
  end

  test "owner transport session mismatch rejects response.processed without local fallback" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-guard-processed", "owner-guard-processed")
    {:ok, other_state} = owner_socket(auth, "ws-owner-guard-processed-other", "owner-guard-other")

    stale_state = %{state | codex_session: other_state.codex_session}

    try do
      processed_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_guard_processed"
        })

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{
               "status" => 502,
               "error" => %{"code" => "upstream_websocket_forward_failed", "message" => message}
             } = CodexPooler.JSON.decode!(error_frame)

      assert message =~ "stale_owner"
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0
      assert [] = request_logs(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
      CodexResponsesSocket.terminate(:closed, other_state)
    end
  end

  test "owner-forwarded anomalous close before request reservation logs bounded lifecycle metadata only" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-pre-request-close-#{System.unique_integer([:positive])}"
    turn_state = "stable-owner-pre-request-close-#{System.unique_integer([:positive])}"

    logs =
      capture_websocket_lifecycle_log(fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts:
                     owner_lifecycle_request_options(request_id, turn_state,
                       authorization_header: "Bearer owner-close-secret-sentinel",
                       idempotency_key: "owner-close-idempotency-secret",
                       forwarded_headers: [{"cookie", "owner-close-cookie-secret"}]
                     ),
                   raw_frame: @sentinel
                 })

        refute state.request_response_work_started?
        assert is_map(state.websocket_owner_downstream)
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        WebsocketConnectionLogger.closed_message(),
        ~w(codex_session_id downstream_epoch elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(owner_instance_id proxy_instance_id)
      )

    owner_instance_id = String.replace(Atom.to_string(node()), ~r/[^a-zA-Z0-9_.:-]+/, "_")

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=_backend-api_codex_responses"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "phase=terminate"
    assert line =~ "reason_class=closed"
    assert line =~ "codex_session_id="
    assert line =~ "downstream_epoch=1"
    assert line =~ "owner_instance_id=#{owner_instance_id}"
    refute logs =~ "websocket owner detach failed"
    refute logs =~ "owner_unavailable"
    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner-forwarded cleanup-only remote detach failure stays quiet without active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-cleanup-only-detach"
    turn_state = "stable-ws-owner-cleanup-only-detach"

    assert {:ok, state} =
             CodexResponsesSocket.init(%{
               auth: auth,
               opts: owner_lifecycle_request_options(request_id, turn_state)
             })

    remote_node = :"codex_pooler@nodedown-cleanup-only-detach.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          RequestOptions.put_transport(state.opts,
            websocket_owner_forwarder_opts:
              WebsocketOwnerNodeHarness.node_client_opts([remote_node],
                calls: %{remote_node => :nodedown}
              )
          )
    }

    try do
      logs =
        capture_log([level: :warning], fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
        end)

      assert logs == ""
      assert_no_leak!("cleanup-only remote detach logs", logs)
      assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  @tag :owner_detach_failure_recovery
  test "owner detach unavailable during socket terminate is observable and interrupts active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_detach"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-detach-unavailable",
          accepted_turn_state: "stable-ws-owner-detach-unavailable",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    suspend_cleanup_task!(state)
    owner = state.websocket_owner_pid
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, @handoff_detection_timeout_ms
    remote_node = :"codex_pooler@nodedown-detach.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :nodedown}
            )
          )
    }

    stop_parked_response_tasks!(remote_state)

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      assert logs =~ "websocket owner detach failed"
      assert logs =~ "owner_unavailable"
      assert_no_leak!("owner detach failure logs", logs)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "owner_unavailable"
      })

      reloaded_session = Repo.get!(CodexSession, state.codex_session.id)
      assert reloaded_session.owner_lease_expires_at

      assert DateTime.diff(
               reloaded_session.owner_lease_expires_at,
               reloaded_session.disconnected_at,
               :second
             ) == 300
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner detach unavailable during socket terminate with typed request options is observable and interrupts active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_detach_typed"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-detach-unavailable-typed",
          accepted_turn_state: "stable-ws-owner-detach-unavailable-typed",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    remote_node = :"codex_pooler@nodedown-detach-typed.example"

    typed_opts =
      RequestOptions.for_websocket(%{})
      |> RequestOptions.put_continuity(
        accepted_turn_state: "stable-ws-owner-detach-unavailable-typed",
        previous_response_id: nil,
        response_id: nil,
        session_header: nil,
        session_key: nil,
        conversation_key: nil,
        owner_instance_id: nil,
        bridge_owner_lease_ttl_seconds: nil,
        reconnect_window_seconds: nil,
        codex_session: nil,
        codex_turn_id: nil,
        authenticated_owner_attach: false
      )
      |> RequestOptions.put_runtime_context(
        now: nil,
        interrupt_reason: nil,
        gateway_debug_payload: nil
      )
      |> RequestOptions.put_transport(
        websocket_owner_forwarder_opts:
          WebsocketOwnerNodeHarness.node_client_opts([remote_node],
            calls: %{remote_node => :nodedown}
          )
      )

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts: typed_opts
    }

    stop_parked_response_tasks!(remote_state)

    try do
      assert %RequestOptions{} = remote_state.opts
      assert is_nil(remote_state.opts.continuity.previous_response_id)
      assert is_nil(remote_state.opts.runtime.interrupt_reason)

      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      assert logs =~ "websocket owner detach failed"
      assert logs =~ "owner_unavailable"
      refute logs =~ "Protocol.UndefinedError"
      assert_no_leak!("typed owner detach failure logs", logs)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "owner_unavailable"
      })
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  @tag :owner_interruption_terminal_state
  test "owner interruption preserves a turn after disconnect accounting wins the race" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_disconnect_race"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-disconnect-accounting-race",
          accepted_turn_state: "stable-ws-owner-disconnect-accounting-race",
          client_ip: "127.0.0.1"
        }
      })

    try do
      %{request: request, attempt: attempt, turn: turn, state: state} =
        active_socket_turn_fixture(setup, upstream, state)

      suspend_cleanup_task!(state)

      assert {:ok, %{request: failed_request, attempt: failed_attempt}} =
               Accounting.finalize_request(request, attempt, %{
                 request_status: "failed",
                 attempt_status: "failed",
                 response_status_code: 499,
                 last_error_code: "client_disconnected",
                 error_message: "websocket client disconnected before the turn completed",
                 usage: %{status: "usage_unknown", source: "client_disconnected"}
               })

      assert failed_request.status == "failed"
      assert failed_attempt.status == "failed"
      assert Repo.get!(CodexTurn, turn.id).status == "in_progress"

      interrupt_opts =
        %{
          interrupt_reason: "client_disconnected",
          request_id: request.correlation_id,
          reconnect_window_seconds: 300
        }
        |> RequestOptions.for_websocket()

      assert {:ok, %{interrupted_turn_count: 1}} =
               Interruption.interrupt_codex_session(state.codex_session, interrupt_opts)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "client_disconnected"
      })
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :owner_recovery_preserves_success
  test "owner detach recovery preserves already succeeded request attempt and turn" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_recovery_success"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-recovery-success",
          accepted_turn_state: "stable-ws-owner-recovery-success",
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
               usage: %{status: "usage_unknown", source: "owner_recovery_success_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    remote_node = :"codex_pooler@nodedown-recovery-success.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :nodedown}
            )
          )
    }

    stop_parked_response_tasks!(remote_state)

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      refute logs =~ "websocket owner detach failed"
      refute logs =~ "owner_unavailable"
      assert_no_leak!("owner recovery success logs", logs)
      assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner detach recovery cleanup remains idempotent after success preservation" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_cleanup_idempotent"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-recovery-cleanup",
          accepted_turn_state: "stable-ws-owner-recovery-cleanup",
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
               usage: %{status: "usage_unknown", source: "owner_recovery_cleanup_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    remote_node = :"codex_pooler@nodedown-recovery-cleanup.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          RequestOptions.for_websocket(%{})
          |> RequestOptions.put_continuity(
            accepted_turn_state: "stable-ws-owner-recovery-cleanup",
            previous_response_id: nil,
            response_id: nil,
            session_header: nil,
            session_key: nil,
            conversation_key: nil,
            owner_instance_id: nil,
            bridge_owner_lease_ttl_seconds: nil,
            reconnect_window_seconds: nil,
            codex_session: nil,
            codex_turn_id: nil,
            authenticated_owner_attach: false
          )
          |> RequestOptions.put_runtime_context(
            now: nil,
            interrupt_reason: nil,
            gateway_debug_payload: nil
          )
          |> RequestOptions.put_transport(
            websocket_owner_forwarder_opts:
              WebsocketOwnerNodeHarness.node_client_opts([remote_node],
                calls: %{remote_node => :nodedown}
              )
          )
    }

    stop_parked_response_tasks!(remote_state)

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      refute logs =~ "websocket owner detach failed"
      refute logs =~ "owner_unavailable"
      refute logs =~ "Protocol.UndefinedError"
      assert_no_leak!("owner recovery cleanup logs", logs)
      assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

      assert :ok =
               CodexResponsesSocket.terminate(
                 :closed,
                 Map.delete(state, :websocket_owner_downstream)
               )
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "stale owner downstream detach does not remove the newer downstream" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-first",
          accepted_turn_state: "stable-ws-owner-stale",
          client_ip: "127.0.0.1"
        }
      })

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-second",
          accepted_turn_state: "stable-ws-owner-stale",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert first_state.websocket_owner_downstream.epoch == 1
      assert second_state.websocket_owner_downstream.epoch == 2

      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

      payload = websocket_payload(setup, "after stale detach")

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

      assert {:push, {:text, frame}, second_state} = receive_owner_socket_push(second_state)
      assert %{"id" => "resp_owner_stale"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  defp owner_lifecycle_request_options(request_id, turn_state, extra_opts \\ []) do
    %{
      request_id: request_id,
      accepted_turn_state: turn_state,
      client_ip: "127.0.0.1"
    }
    |> Map.merge(Map.new(extra_opts))
    |> RequestOptions.for_websocket()
  end
end
