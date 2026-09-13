defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.SocketLifecycleTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request,
    as: UpstreamWebsocketRequest

  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketConnectionLogger

  @large_websocket_frame_timeout 5_000
  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000
  @websocket_lifecycle_metadata_keys ~w(
    codex_session_id
    downstream_epoch
    elapsed_ms
    endpoint
    owner_instance_id
    phase
    proxy_instance_id
    reason_class
    request_id
    route_class
    transport
  )
  @websocket_lifecycle_forbidden_terms ~w(
    auth.json
    authorization
    bearer
    cookie
    header
    idempotency
    payload
    prompt
    upstream_body
    websocket_frame
    init-failure-secret-sentinel
    init-cookie-secret
    init-idempotency-secret
    init-prompt-sentinel
  )

  defmodule DeliveryReceiptLogRelay do
    @moduledoc false

    # Runs in the process that emits the log line; used to react to a
    # socket-side receipt while the test process is still inside terminate.
    def log(%{msg: {:string, chardata}}, %{config: %{needle: needle, on_match: on_match}}) do
      if IO.chardata_to_string(chardata) =~ needle, do: on_match.()
      :ok
    end

    def log(_event, _config), do: :ok
  end

  test "socket init failure before request reservation logs one bounded warning and creates no request row" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-init-failure-#{System.unique_integer([:positive])}"

    request_options =
      %{
        request_id: request_id,
        client_ip: "127.0.0.1",
        previous_response_id: "resp_missing_init_failure",
        authorization_header: "Bearer init-failure-secret-sentinel",
        idempotency_key: "init-idempotency-secret",
        forwarded_headers: [{"cookie", "init-cookie-secret"}]
      }
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_continuity(authenticated_owner_attach: true)

    logs =
      capture_websocket_lifecycle_log(:warning, fn ->
        assert {:stop, :normal, {1011, "websocket owner is unavailable"}, returned_state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts: request_options,
                   raw_frame: "init-prompt-sentinel"
                 })

        assert returned_state.opts.request_metadata.request_id == request_id
        refute Map.has_key?(returned_state, :request_response_work_started?)
        refute Map.has_key?(returned_state, :connection_started_at_monotonic_ms)
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        WebsocketConnectionLogger.init_failed_message(),
        ~w(elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(codex_session_id downstream_epoch owner_instance_id proxy_instance_id)
      )

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=_backend-api_codex_responses"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "phase=init"
    assert line =~ "reason_class=owner_unavailable"
    assert line =~ "elapsed_ms="

    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert %{items: [], total: 0} = Accounting.list_request_logs(setup.pool)
    assert FakeUpstream.count(upstream) == 0
  end

  test "socket init lifecycle warning does not cover controller auth or upgrade errors", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)

    auth_logs =
      capture_websocket_lifecycle_log(:warning, fn ->
        conn = get(conn, "/backend-api/codex/responses")
        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end)

    refute auth_logs =~ WebsocketConnectionLogger.init_failed_message()

    upgrade_logs =
      capture_websocket_lifecycle_log(:warning, fn ->
        conn =
          Phoenix.ConnTest.build_conn()
          |> auth(setup)
          |> get("/backend-api/codex/responses")

        assert json_response(conn, 400)["error"]["code"] == "websocket_upgrade_required"
      end)

    refute upgrade_logs =~ WebsocketConnectionLogger.init_failed_message()
    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert FakeUpstream.count(upstream) == 0
  end

  test "socket terminate anomalous close before request reservation logs one bounded line and creates no request row" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-pre-request-close-#{System.unique_integer([:positive])}"

    logs =
      capture_websocket_lifecycle_log(:info, fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts:
                     websocket_lifecycle_request_options(request_id,
                       authorization_header: "Bearer terminate-secret-sentinel",
                       idempotency_key: "terminate-idempotency-secret",
                       forwarded_headers: [{"cookie", "terminate-cookie-secret"}]
                     ),
                   raw_frame: "terminate-websocket-frame-sentinel"
                 })

        refute state.request_response_work_started?
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        WebsocketConnectionLogger.closed_message(),
        ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(downstream_epoch owner_instance_id proxy_instance_id)
      )

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=_backend-api_codex_responses"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "phase=terminate"
    assert line =~ "reason_class=closed"
    assert line =~ "codex_session_id="
    assert line =~ "elapsed_ms="

    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert %{items: [], total: 0} = Accounting.list_request_logs(setup.pool)
  end

  test "socket terminate clean pre-request closes stay quiet for normal and shutdown" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_websocket_lifecycle_log(:info, fn ->
        for reason <- [:normal, :shutdown] do
          request_id =
            "ws-clean-pre-request-close-#{reason}-#{System.unique_integer([:positive])}"

          assert {:ok, state} =
                   CodexResponsesSocket.init(%{
                     auth: auth,
                     opts: websocket_lifecycle_request_options(request_id)
                   })

          refute state.request_response_work_started?
          assert :ok = CodexResponsesSocket.terminate(reason, state)
        end
      end)

    refute logs =~ WebsocketConnectionLogger.closed_message()
    refute logs =~ WebsocketConnectionLogger.init_failed_message()
    assert_no_websocket_lifecycle_leaks!(logs)
    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert %{items: [], total: 0} = Accounting.list_request_logs(setup.pool)
  end

  test "socket terminate after request work starts does not emit pre-request lifecycle line" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_post_work_close",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_websocket_lifecycle_log(:info, fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts: websocket_lifecycle_request_options("ws-post-work-close")
                 })

        payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
            "stream" => true,
            "generate" => true
          })

        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
        assert state.request_response_work_started?
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    refute logs =~ WebsocketConnectionLogger.closed_message()
    refute logs =~ WebsocketConnectionLogger.init_failed_message()
    assert_no_websocket_lifecycle_leaks!(logs)

    assert [request] =
             Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
  end

  test "completed native websocket turn records a delivered downstream receipt on the attempt" do
    delta_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "receipt-prompt-sentinel"
      })

    terminal_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_ws_delivery_receipt",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        }
      })

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond: FakeUpstream.websocket_text_frames([delta_frame, terminal_frame])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-delivery-receipt",
          accepted_turn_state: "stable-ws-delivery-receipt",
          client_ip: "127.0.0.1"
        }
      })

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("delivery receipt"),
          "stream" => true,
          "generate" => true
        })

      {state, logs} =
        with_info_log(fn ->
          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, ^delta_frame}, state} = receive_socket_push(state)
          assert {:push, {:text, ^terminal_frame}, state} = receive_socket_push(state)
          settle_direct_socket_turn(state)
        end)

      assert MapSet.size(state.tasks) == 0
      assert :ok = FakeUpstream.verify!(upstream)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"

      assert %{
               "outcome" => "delivered",
               "terminal_class" => "response.completed",
               "pushed_at" => pushed_at,
               "frames_after_visible" => 2,
               "transport" => "websocket"
             } = attempt.response_metadata["downstream_delivery"]

      assert {:ok, pushed_at, 0} = DateTime.from_iso8601(pushed_at)
      assert DateTime.compare(pushed_at, attempt.started_at) in [:gt, :eq]

      assert logs =~
               "websocket downstream terminal pushed request_id=#{request.id} " <>
                 "codex_session_id=#{state.codex_session.id} outcome=delivered " <>
                 "terminal_class=response.completed frames_after_visible=2"

      metadata_text = inspect({request.request_metadata, attempt.response_metadata, logs})
      refute metadata_text =~ "receipt-prompt-sentinel"
      refute metadata_text =~ "resp_ws_delivery_receipt"
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "client disconnect before the terminal records an aborted downstream receipt" do
    release_ref = make_ref()

    created_frame =
      "data: " <>
        CodexPooler.JSON.encode!(%{
          "type" => "response.created",
          "response" => %{"id" => "resp_ws_receipt_abort", "status" => "in_progress"}
        }) <> "\n\n"

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(created_frame,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-delivery-receipt-abort",
          accepted_turn_state: "stable-ws-delivery-receipt-abort",
          client_ip: "127.0.0.1"
        }
      })

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("abort before terminal"),
        "stream" => true,
        "generate" => true
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, _upstream_pid, ^release_ref},
                   @connection_shutdown_timeout_ms

    assert {:push, {:text, created}, state} = receive_socket_push(state)
    assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)

    {state, attempt_id} = await_direct_attempt_receipt(state)
    assert is_binary(attempt_id)

    # Terminate interrupts the request, acknowledges the task through the
    # activity registry, records the receipt, and only then gives the
    # in-flight upstream caller its grace period. That caller is still
    # blocked on the upstream and its registry acknowledgement recipient is
    # the cancellation watcher, so once the receipt line has been logged the
    # test closes the fake upstream connection and hands the task the same
    # acknowledgement directly; the grace period is not the property under
    # test.
    [task_pid] = MapSet.to_list(state.tasks)
    release_task_after_receipt_log!(upstream, task_pid)

    {:ok, logs} =
      with_info_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, state) end)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "client_disconnected"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.id == attempt_id
    assert attempt.status == "failed"
    assert attempt.network_error_code == "client_disconnected"

    assert attempt.response_metadata["downstream_delivery"] == %{
             "outcome" => "aborted",
             "terminal_class" => "none",
             "pushed_at" => nil,
             "frames_after_visible" => 1,
             "transport" => "websocket"
           }

    assert logs =~
             "websocket downstream terminal pushed request_id=#{request.id} " <>
               "codex_session_id=#{state.codex_session.id} outcome=aborted " <>
               "terminal_class=none frames_after_visible=1"

    refute inspect({attempt.response_metadata, logs}) =~ "abort before terminal"
  end

  @tag :websocket_disconnect_interrupts_turn
  @tag :replay_race
  test "websocket disconnect interrupts active turn and request accounting" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-disconnect"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("disconnect me")
               },
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-disconnect-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    Gateway.interrupt_codex_session(session, %{
      reason: "client_disconnected",
      request_id: reserved.request.correlation_id,
      reconnect_window_seconds: 300
    })

    assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == attempt.id
    assert Repo.get!(Request, reserved.request.id).status == "failed"
    assert Repo.get!(Request, reserved.request.id).response_status_code == 499
    assert Repo.get!(Request, reserved.request.id).last_error_code == "client_disconnected"
    assert Repo.get!(CodexSession, session.id).status == "interrupted"
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket disconnect does not partially interrupt when accounting finalization fails" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-disconnect-failure"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("disconnect me")
               },
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-disconnect-failure-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    Repo.delete_all(
      from entry in LedgerEntry,
        where: entry.source_event_id == ^"request:#{reserved.request.id}:reservation"
    )

    assert {:error, {:interrupt_accounting_failed, %Ecto.NoResultsError{}}} =
             Gateway.interrupt_codex_session(session, %{
               reason: "client_disconnected",
               request_id: reserved.request.correlation_id,
               reconnect_window_seconds: 300
             })

    assert Repo.get!(CodexTurn, turn.id).status == "in_progress"
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == nil
    assert Repo.get!(Request, reserved.request.id).status == "in_progress"
    assert Repo.get!(Attempt, attempt.id).status == "in_progress"
    assert Repo.get!(CodexSession, session.id).status == "active"
  end

  test "websocket disconnect does not downgrade a completed turn" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-completed-disconnect"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("complete me")
               },
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-completed-disconnect-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    assert {:ok, _result} =
             AttemptSettlement.finalize_success(
               reserved.request,
               attempt,
               %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
               %{response_status_code: 200}
             )

    Gateway.interrupt_codex_session(session, %{
      reason: "client_disconnected",
      request_id: reserved.request.correlation_id,
      reconnect_window_seconds: 300
    })

    assert Repo.get!(CodexTurn, turn.id).status == "succeeded"
    assert Repo.get!(CodexTurn, turn.id).error_code == nil
    assert Repo.get!(Request, reserved.request.id).status == "succeeded"
    assert Repo.get!(Request, reserved.request.id).last_error_code == nil
    assert Repo.get!(CodexSession, session.id).status == "active"

    assert {:ok, reused_session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "stable-completed-disconnect"
             })

    assert reused_session.id == session.id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where:
                 entry.request_id == ^reserved.request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1
  end

  test "websocket response task exits are reported as structured websocket errors" do
    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => "gpt-test-model",
        "input" => native_text_input("sensitive prompt sentinel")
      })

    log =
      capture_log(fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.handle_in(
                   {payload, [opcode: :text]},
                   %{tasks: MapSet.new(), opts: %{request_id: "ws-task-crash-log"}}
                 )

        assert MapSet.size(state.tasks) == 1

        assert {:push, {:text, frame}, state} =
                 receive_socket_done(state, @large_websocket_frame_timeout)

        assert CodexPooler.JSON.decode!(frame) == %{
                 "type" => "error",
                 "status" => 500,
                 "error" => %{
                   "message" => "websocket response task failed",
                   # findings#184: a status-500 task failure is server class.
                   "type" => "server_error",
                   "code" => "websocket_response_task_failed",
                   "param" => nil
                 }
               }

        assert MapSet.size(state.tasks) == 0
      end)

    assert log =~ "websocket response task failed"
    assert log =~ "failure_kind=exception"
    assert log =~ "failure_reason=KeyError"
    assert log =~ "request_id=ws-task-crash-log"
    assert log =~ "payload_type=response.create"
    assert log =~ "payload_model=gpt-test-model"
    assert length(Regex.scan(~r/websocket response task failed/, log)) == 1
    refute log =~ "websocket native turn failed"
    refute log =~ "sensitive prompt sentinel"
  end

  test "ordinary websocket response task failures log once and reach the client without a task-crash log" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_error(
          %{"error" => %{"code" => "upgrade_rejected"}},
          status: 403
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-ordinary-task-failure-log",
          accepted_turn_state: "ws-ordinary-task-failure-log",
          client_ip: "127.0.0.1"
        }
      })

    log =
      capture_log(fn ->
        payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("ordinary failure prompt sentinel"),
            "stream" => true,
            "generate" => true
          })

        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

        assert {:push, {:text, frame}, state} =
                 receive_socket_done(state, @large_websocket_frame_timeout)

        assert CodexPooler.JSON.decode!(frame) == %{
                 "type" => "error",
                 "status" => 502,
                 "error" => %{
                   "message" => "upstream request failed",
                   # findings#184: a 502 upstream failure is server class.
                   "type" => "server_error",
                   "code" => "upstream_request_failed",
                   "param" => nil
                 }
               }

        assert MapSet.size(state.tasks) == 0
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    assert length(Regex.scan(~r/websocket native turn failed/, log)) == 1
    assert log =~ "request_id=ws-ordinary-task-failure-log"
    assert log =~ "endpoint=_backend-api_codex_responses"
    assert log =~ "transport=websocket"
    assert log =~ "route_class=proxy_websocket"
    assert log =~ "error_code=upstream_request_failed"
    assert log =~ "reason_code=upstream_request_failed"
    assert log =~ "visible_output=before_visible_output"
    refute log =~ "phase=receive"
    refute log =~ "websocket response task failed"
    refute log =~ "ordinary failure prompt sentinel"
  end

  test "direct native websocket output state resets before the next turn" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_websocket_output_reset",
          "object" => "response",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-direct-output-reset",
          accepted_turn_state: "ws-direct-output-reset",
          client_ip: "127.0.0.1"
        }
      })

    first_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [],
        "stream" => true,
        "generate" => true
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)
    assert state.native_turn_output_task_pids == MapSet.new()

    assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
    assert %{"id" => "resp_websocket_output_reset"} = CodexPooler.JSON.decode!(first_frame)
    assert state.native_turn_output_task_pids == state.tasks

    assert {:ok, state} = receive_socket_done(state, @large_websocket_frame_timeout)
    assert state.native_turn_output_task_pids == MapSet.new()

    FakeUpstream.set_mode(upstream, FakeUpstream.websocket_sse_then_close([]))

    second_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [],
        "stream" => true,
        "generate" => true
      })

    {error_frame, logs} =
      capture_native_turn_warning(fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

        assert state.native_turn_output_task_pids == MapSet.new()

        assert {:push, {:text, error_frame}, state} =
                 receive_socket_done(state, @large_websocket_frame_timeout)

        assert state.native_turn_output_task_pids == MapSet.new()
        error_frame
      end)

    assert %{"type" => "error", "error" => %{"code" => "upstream_request_failed"}} =
             CodexPooler.JSON.decode!(error_frame)

    assert_native_turn_warnings(logs, 1)
    assert logs =~ "request_id=ws-direct-output-reset"
    assert logs =~ "error_code=upstream_request_failed"
    assert logs =~ "reason_code=upstream_request_failed"
    assert logs =~ "visible_output=before_visible_output"
    refute logs =~ "phase=receive"
    refute logs =~ "resp_websocket_output_reset"
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  test "late native chunks from an untracked task are dropped and claim no output" do
    current_task = socket_test_task()
    settled_task = socket_test_task()
    on_exit(fn -> Enum.each([current_task, settled_task], &send(&1, :stop)) end)

    state = direct_socket_task_state([current_task], "ws-untagged-late-chunk")

    frame =
      CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "stale"})

    # A chunk produced by a turn the socket no longer tracks must not reach the
    # client on the current turn, and must not mark the current task as having
    # produced visible output.
    assert {:ok, state_after_chunk} =
             CodexResponsesSocket.handle_info({:codex_response_chunk, settled_task, frame}, state)

    assert state_after_chunk == state

    {_result, logs} =
      capture_native_turn_warning(fn ->
        CodexResponsesSocket.handle_info(
          {:codex_response_done, current_task,
           {:response_task_result,
            {:error,
             %{status: 502, code: "upstream_request_failed", message: "upstream request failed"}},
            false}},
          state_after_chunk
        )
      end)

    assert_native_turn_warnings(logs, 1)
    assert logs =~ "request_id=ws-untagged-late-chunk"
    assert logs =~ "visible_output=before_visible_output"
  end

  test "one direct task completion does not clear another task's pushed output" do
    output_task = socket_test_task()
    silent_task = socket_test_task()
    on_exit(fn -> send(output_task, :stop) end)
    on_exit(fn -> send(silent_task, :stop) end)

    state = direct_socket_task_state([output_task, silent_task], "ws-concurrent-direct-output")

    frame =
      CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "visible"})

    assert {:push, {:text, ^frame}, state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, output_task, frame},
               state
             )

    assert {:ok, state} =
             CodexResponsesSocket.handle_info({:codex_response_done, silent_task, :ok}, state)

    {_result, logs} =
      capture_native_turn_warning(fn ->
        CodexResponsesSocket.handle_info(
          {:codex_response_done, output_task,
           {:response_task_result,
            {:error,
             %{status: 502, code: "upstream_request_failed", message: "upstream request failed"}},
            false}},
          state
        )
      end)

    assert_native_turn_warnings(logs, 1)
    assert logs =~ "request_id=ws-concurrent-direct-output"
    assert logs =~ "visible_output=after_visible_output"
  end

  test "successful websocket response tasks do not log native turn failures" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_websocket_logging_success",
          "object" => "response",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-success-task-no-failure-log",
          accepted_turn_state: "ws-success-task-no-failure-log",
          client_ip: "127.0.0.1"
        }
      })

    log =
      capture_log(fn ->
        payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => [],
            "stream" => true,
            "generate" => true
          })

        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

        assert {:ok, state} = receive_socket_done(state, @large_websocket_frame_timeout)
        assert MapSet.size(state.tasks) == 0
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    refute log =~ "websocket native turn failed"
  end

  test "websocket response task DOWN messages remove tasks that exit before done" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(pid)
    state = %{tasks: MapSet.new([pid]), task_monitors: %{pid => monitor}}

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert {:ok, state} =
             CodexResponsesSocket.handle_info({:DOWN, monitor, :process, pid, :killed}, state)

    assert state.tasks == MapSet.new()
    assert state.task_monitors == %{}
  end

  test "late websocket success after disconnect promotes an interrupted turn" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "late-success-disconnect"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("finish after disconnect")
               },
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-late-success-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    Gateway.interrupt_codex_session(session, %{
      reason: "client_disconnected",
      request_id: reserved.request.correlation_id,
      reconnect_window_seconds: 300
    })

    assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    assert Repo.get!(Request, reserved.request.id).status == "failed"

    assert {:ok, _result} =
             AttemptSettlement.finalize_success(
               reserved.request,
               attempt,
               %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
               %{response_status_code: 200}
             )

    assert Repo.get!(CodexTurn, turn.id).status == "succeeded"
    assert Repo.get!(CodexTurn, turn.id).error_code == nil
    assert Repo.get!(Request, reserved.request.id).status == "succeeded"
    assert Repo.get!(Request, reserved.request.id).last_error_code == nil

    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    assert reloaded_attempt.status == "succeeded"
    assert reloaded_attempt.network_error_code == nil
    assert reloaded_attempt.error_message == nil

    assert %{items: [log]} =
             Accounting.list_request_logs(setup.pool, filters: %{request_id: reserved.request.id})

    assert log.status == "succeeded"
    assert log.errors == []
  end

  test "websocket terminate lets a response task released during grace finish before interrupting" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "task-drain"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("complete me")
               },
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-task-drain-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    parent = self()
    release_ref = make_ref()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:task_drain_ready, self()})

        receive do
          {:finish_during_task_drain, ^release_ref} -> :ok
        end

        AttemptSettlement.finalize_success(
          reserved.request,
          attempt,
          %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
          %{response_status_code: 200}
        )

        send(parent, {:task_drain_finalized, self()})
        send(parent, {:codex_response_done, self(), :ok})
      end)

    assert_receive {:task_drain_ready, ^pid}, 1_000

    terminator =
      Task.async(fn ->
        CodexResponsesSocket.terminate(:closed, %{
          tasks: MapSet.new([pid]),
          codex_session: session,
          opts: %{
            reason: "client_disconnected",
            request_id: reserved.request.correlation_id,
            reconnect_window_seconds: 300
          }
        })
      end)

    assert Task.yield(terminator, 25) == nil
    assert Process.alive?(pid)

    send(pid, {:finish_during_task_drain, release_ref})

    assert_receive {:task_drain_finalized, ^pid}, 1_000
    assert :ok = Task.await(terminator, @connection_shutdown_timeout_ms)

    assert Repo.get!(CodexTurn, turn.id).status == "succeeded"
    assert Repo.get!(CodexTurn, turn.id).error_code == nil
    assert Repo.get!(Request, reserved.request.id).status == "succeeded"
    assert Repo.get!(Request, reserved.request.id).last_error_code == nil
    assert Repo.get!(CodexSession, session.id).status == "active"

    assert {:ok, reused_session} =
             Gateway.start_codex_session(auth, %{accepted_turn_state: "task-drain"})

    assert reused_session.id == session.id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where:
                 entry.request_id == ^reserved.request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1
  end

  test "websocket terminate cancels an in-flight direct-native upstream caller after grace" do
    release_ref = make_ref()

    created_frame =
      "data: " <> CodexPooler.JSON.encode!(%{"type" => "response.created"}) <> "\n\n"

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(created_frame,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "direct-native-cancel"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("cancel direct native request")
               },
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-direct-native-cancel-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    {:ok, upstream_websocket_session} = UpstreamWebsocketSession.start_link()
    on_exit(fn -> UpstreamWebsocketSession.close(upstream_websocket_session) end)

    {:ok, task} =
      Task.start(fn ->
        UpstreamWebsocketSession.request(
          upstream_websocket_session,
          %UpstreamWebsocketRequest{
            url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
            headers: [],
            payload: "{}",
            timeouts: %{connect_timeout_ms: 1_000, receive_timeout_ms: 5_000},
            writer: fn _frame -> :ok end,
            message_mapper: nil
          }
        )
      end)

    task_monitor = Process.monitor(task)
    upstream_session_monitor = Process.monitor(upstream_websocket_session)

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_socket_pid,
                    ^release_ref},
                   1_000

    assert FakeUpstream.await_websocket_connection_count(upstream, 1, 1_000) == 1
    upstream_socket_monitor = Process.monitor(upstream_socket_pid)

    terminator =
      Task.async(fn ->
        CodexResponsesSocket.terminate(:closed, %{
          tasks: MapSet.new([task]),
          codex_session: session,
          upstream_websocket_session: upstream_websocket_session,
          opts: %{
            reason: "client_disconnected",
            request_id: reserved.request.correlation_id,
            reconnect_window_seconds: 300
          }
        })
      end)

    assert_receive {:DOWN, ^task_monitor, :process, ^task, {:shutdown, :websocket_terminated}},
                   1_000

    assert_receive {:DOWN, ^upstream_session_monitor, :process, ^upstream_websocket_session,
                    :normal},
                   1_000

    assert_receive {:DOWN, ^upstream_socket_monitor, :process, ^upstream_socket_pid, _reason},
                   1_000

    assert :ok = Task.await(terminator, @connection_shutdown_timeout_ms)

    assert %CodexTurn{status: "interrupted", error_code: "client_disconnected"} =
             completed_turn = Repo.get!(CodexTurn, turn.id)

    assert completed_turn.final_attempt_id == attempt.id

    assert %Request{
             status: "failed",
             response_status_code: 499,
             last_error_code: "client_disconnected"
           } = Repo.get!(Request, reserved.request.id)

    assert %Attempt{
             status: "failed",
             network_error_code: "client_disconnected",
             usage_status: "usage_unknown"
           } = Repo.get!(Attempt, attempt.id)

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where:
                 entry.request_id == ^reserved.request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.all(from(demotion in BridgeDemotion)) == []
    assert Repo.all(from(circuit in RoutingCircuitState)) == []
  end

  test "websocket terminate cancellation preserves unrelated mailbox messages" do
    unrelated = {:unrelated_websocket_mailbox_message, make_ref()}

    task =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    task_monitor = Process.monitor(task)

    send(self(), unrelated)

    assert :ok =
             CodexResponsesSocket.terminate(:closed, %{
               tasks: MapSet.new([task]),
               codex_session: nil,
               opts: %{}
             })

    assert_receive {:DOWN, ^task_monitor, :process, ^task, {:shutdown, :websocket_terminated}}

    assert_receive ^unrelated
  end

  # Drives the socket-side bookkeeping a live WebSock process would receive
  # after the provider frames: activity token, cleanup receipts, gateway
  # result, and the post-push delivery acknowledgement, until no task remains.
  defp settle_direct_socket_turn(%{tasks: tasks} = state) do
    if MapSet.size(tasks) == 0 do
      state
    else
      receive do
        {:websocket_response_activity, _pid, _token} = message ->
          {:ok, state} = CodexResponsesSocket.handle_info(message, state)
          settle_direct_socket_turn(state)

        {:direct_request_cleanup, _pid, _ref, _receipt} = message ->
          {:ok, state} = CodexResponsesSocket.handle_info(message, state)
          settle_direct_socket_turn(state)

        {:codex_response_done, _pid, _result} = message ->
          {:ok, state} = CodexResponsesSocket.handle_info(message, state)
          settle_direct_socket_turn(state)

        {:websocket_response_delivery_complete, _pid, _token} = message ->
          {:ok, state} = CodexResponsesSocket.handle_info(message, state)
          settle_direct_socket_turn(state)
      after
        @connection_shutdown_timeout_ms -> flunk("expected the websocket turn to settle")
      end
    end
  end

  defp release_task_after_receipt_log!(upstream, task_pid) do
    handler_id = :"receipt-abort-release-#{System.unique_integer([:positive])}"

    on_match = fn ->
      case ActivityRegistry.delivery_target(task_pid) do
        {:ok, token, _ack_pid, _status} ->
          :ok = FakeUpstream.close_websocket_connections(upstream)
          :ok = ResponseTask.acknowledge_delivery(task_pid, token, :aborted)

        :unknown ->
          :ok
      end
    end

    :ok =
      :logger.add_handler(handler_id, DeliveryReceiptLogRelay, %{
        level: :info,
        config: %{needle: "websocket downstream terminal pushed", on_match: on_match}
      })

    on_exit(fn -> :logger.remove_handler(handler_id) end)
    :ok
  end

  # Feeds the socket its direct-cleanup receipts until the one carrying the
  # attempt id has been accepted, so a later terminate can attribute the turn.
  defp await_direct_attempt_receipt(state) do
    receive do
      {:websocket_response_activity, _pid, _token} = message ->
        {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        await_direct_attempt_receipt(state)

      {:direct_request_cleanup, _pid, _ref, receipt} = message ->
        {:ok, state} = CodexResponsesSocket.handle_info(message, state)

        case Map.get(receipt, :attempt_id) do
          nil -> await_direct_attempt_receipt(state)
          attempt_id -> {state, attempt_id}
        end
    after
      @connection_shutdown_timeout_ms -> flunk("expected the direct cleanup attempt receipt")
    end
  end

  defp capture_websocket_lifecycle_log(level, fun) when is_atom(level) and is_function(fun, 0) do
    previous_level = Logger.level()
    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: level)

    try do
      capture_log(
        [
          level: level,
          format: "$metadata$message\n",
          metadata: @websocket_lifecycle_metadata_keys,
          colors: [enabled: false]
        ],
        fun
      )
    after
      Logger.configure(level: previous_level)
    end
  end

  defp direct_socket_task_state(tasks, request_id) do
    %{
      opts: websocket_lifecycle_request_options(request_id),
      tasks: MapSet.new(tasks),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      native_turn_output_task_pids: MapSet.new()
    }
  end

  defp socket_test_task do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp websocket_lifecycle_request_options(request_id, attrs \\ []) when is_binary(request_id) do
    %{
      request_id: request_id,
      accepted_turn_state: "#{request_id}-turn",
      client_ip: "127.0.0.1"
    }
    |> Map.merge(Map.new(attrs))
    |> RequestOptions.for_websocket()
  end

  defp assert_websocket_lifecycle_line!(logs, message, required_keys, optional_keys) do
    lifecycle_lines =
      logs
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, message))

    assert [line] = lifecycle_lines

    metadata_text =
      line
      |> String.replace_prefix(message, "")
      |> String.trim_leading()

    metadata_keys =
      metadata_text
      |> String.split(" ", trim: true)
      |> Enum.map(fn token -> token |> String.split("=", parts: 2) |> hd() end)

    assert Enum.all?(metadata_keys, &(&1 in @websocket_lifecycle_metadata_keys))
    assert Enum.all?(required_keys, &(&1 in metadata_keys))
    assert Enum.all?(metadata_keys, &(&1 in (required_keys ++ optional_keys)))
    assert_no_websocket_lifecycle_leaks!(logs)

    line
  end

  defp assert_no_websocket_lifecycle_leaks!(logs) do
    downcased_logs = String.downcase(logs)

    for forbidden_term <- @websocket_lifecycle_forbidden_terms do
      refute downcased_logs =~ forbidden_term
    end
  end
end
