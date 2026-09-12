defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ResendTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, CodexTurn, RoutingCircuitState}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000
  @large_websocket_frame_timeout 5_000
  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000

  @tag :replay_race
  test "mid-stream upstream death after visible output authors exactly one error frame" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close([
          %{
            "type" => "response.created",
            "response" => %{"id" => "resp_visible_then_death", "status" => "in_progress"}
          },
          %{"type" => "response.output_text.delta", "delta" => "partial visible output"}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-visible-then-death",
          accepted_turn_state: "ws-visible-then-death",
          client_ip: "127.0.0.1"
        }
      })

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [],
        "stream" => true,
        "generate" => true
      })

    {{error_frame, state}, logs} =
      capture_native_turn_warning(fn ->
        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

        assert {:push, {:text, created_frame}, state} = receive_socket_push(state)
        assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created_frame)

        assert {:push, {:text, delta_frame}, state} = receive_socket_push(state)
        assert %{"type" => "response.output_text.delta"} = CodexPooler.JSON.decode!(delta_frame)

        assert {:push, {:text, error_frame}, state} =
                 receive_socket_turn_done(state, @large_websocket_frame_timeout)

        assert MapSet.size(state.tasks) == 0
        {error_frame, state}
      end)

    assert error_frame ==
             ~s({"error":{"code":"upstream_request_failed",) <>
               ~s("message":"upstream request failed","param":null,) <>
               ~s("type":"server_error"},"status":502,"type":"error"})

    # Exactly one authored frame: nothing else is queued for the client. The
    # chunk pattern must carry the task pid, which is the arity production
    # actually sends.
    refute_received {:codex_response_chunk, _task_pid, _chunk}
    refute_received {:codex_response_done, _pid, _result}

    assert_native_turn_warnings(logs, 1)
    assert logs =~ "request_id=ws-visible-then-death"
    assert logs =~ "error_code=upstream_request_failed"
    assert logs =~ "visible_output=after_visible_output"
    refute logs =~ "partial visible output"

    # The socket is not closed by the failure and still serves the next turn.
    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.json_response(%{
        "id" => "resp_after_visible_death",
        "object" => "response",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      })
    )

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert {:push, {:text, recovered_frame}, state} = receive_socket_push(state)
    assert %{"id" => "resp_after_visible_death"} = CodexPooler.JSON.decode!(recovered_frame)
    assert {:ok, state} = receive_socket_turn_done(state, @large_websocket_frame_timeout)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert_socket_response_tasks_released!()
  end

  @tag :owner_task_exception
  test "response task exception after visible output fails the turn and admits the byte-identical resend" do
    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()
      Application.delete_env(:codex_pooler, :settlement_pricing_test_fault)

      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    # Strict finite scenario: the first turn streams visible output and its
    # terminal on the single physical connection, then the response task dies
    # by exception inside settlement; the client's byte-identical resend is a
    # fresh turn on the same connection. Any further send fails the fixture.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "response.created",
                "response" => %{"id" => "resp_task_exception_visible", "status" => "in_progress"}
              }),
              CodexPooler.JSON.encode!(%{
                "type" => "response.output_text.delta",
                "delta" => "visible before task exception"
              }),
              CodexPooler.JSON.encode!(%{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_task_exception_visible",
                  "status" => "completed",
                  "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
                }
              })
            ])
          ),
          strict_native_request(
            1,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_after_task_exception",
                  "status" => "completed",
                  "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
                }
              })
            ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()
    thread_id = Ecto.UUID.generate()

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => thread_id,
              "thread_id" => thread_id,
              "turn_id" => "task-exception-turn",
              "request_kind" => "turn"
            })
        },
        "input" => native_text_input("task exception prompt sentinel"),
        "stream" => true,
        "generate" => true
      })

    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    Application.put_env(
      :codex_pooler,
      :settlement_pricing_test_fault,
      {setup.pool.id, %DBConnection.ConnectionError{message: "synthetic pool exhaustion"}}
    )

    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

    {conn, _websocket, seen_types, failure_frame} =
      receive_public_websocket_until_error(conn, websocket, ref, [])

    assert "response.output_text.delta" in seen_types

    assert %{
             "type" => "error",
             "status" => 500,
             "error" => %{"code" => "websocket_response_task_failed"}
           } = failure_frame

    Application.delete_env(:codex_pooler, :settlement_pricing_test_fault)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    refute is_nil(turn.first_visible_output_at)

    # The client disconnects; the old socket's cleanup completes before the
    # byte-identical resend, as in the incident's reconnect sequence.
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    assert %{downstream: %{pid: downstream_pid}} = :sys.get_state(owner_pid)
    downstream_monitor = Process.monitor(downstream_pid)

    {resend_outcome, log} =
      with_log(fn ->
        Mint.HTTP.close(conn)

        assert_receive {:DOWN, ^downstream_monitor, :process, ^downstream_pid, _reason},
                       @connection_shutdown_timeout_ms

        {retry_conn, retry_websocket, retry_ref} =
          public_websocket_connect!(port, setup, turn_state)

        {retry_conn, retry_websocket} =
          public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, payload)

        {retry_conn, _retry_websocket, retry_frame} =
          public_websocket_receive_text!(retry_conn, retry_websocket, retry_ref)

        Mint.HTTP.close(retry_conn)

        case CodexPooler.JSON.decode!(retry_frame) do
          %{"type" => "response.completed", "response" => %{"id" => id}} ->
            {:completed, id}

          %{"type" => "error", "status" => status, "error" => %{"code" => code}} ->
            {:error, status, code}
        end
      end)

    refute log =~ "stale_owner_cleanup"
    refute log =~ "websocket replay rejection"
    refute log =~ "task exception prompt sentinel"

    assert %{
             request_status: request.status,
             request_error: request.last_error_code,
             request_usage: request.usage_status,
             attempt_status: attempt.status,
             turn_status: turn.status,
             turn_error: turn.error_code,
             turn_final_attempt: turn.final_attempt_id,
             resend: resend_outcome
           } == %{
             request_status: "failed",
             request_error: "owner_task_exception",
             request_usage: "usage_unknown",
             attempt_status: "failed",
             turn_status: "failed",
             turn_error: "owner_task_exception",
             turn_final_attempt: attempt.id,
             resend: {:completed, "resp_after_task_exception"}
           }

    assert [_failed, resend] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at]
               )
             )

    assert resend.id != request.id
    resend_id = resend.id

    # The completed frame reaches the client before the successor settles.
    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => ^resend_id, "status" => "succeeded"}
                    }},
                   @websocket_frame_timeout

    assert Repo.get!(Request, resend.id).status == "succeeded"

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
             :count
           ) == 2

    # Health neutral: a task exception is not backend evidence.
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :provider_terminal_resend
  test "provider terminal failure on a text-only turn admits the byte-identical resend as one successor" do
    scenario =
      provider_terminal_resend_scenario(
        native_text_input("text only provider failure prompt sentinel"),
        "text_only"
      )

    %{request: request, resend: resend} = scenario

    assert String.starts_with?(request.correlation_id, "codex-turn:")
    assert String.starts_with?(resend.correlation_id, "client-retry-v1:")

    assert Repo.one!(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id,
               select: link.successor_request_id
             )
           ) == resend.id
  end

  @tag :provider_terminal_resend
  test "provider terminal failure on a tool-continuation turn admits the byte-identical resend with a derived request claim" do
    scenario =
      provider_terminal_resend_scenario(
        tool_continuation_input("tool continuation provider failure prompt sentinel"),
        "tool_continuation"
      )

    %{request: request, resend: resend, log: log} = scenario

    assert String.starts_with?(request.correlation_id, "codex-request:")
    assert String.starts_with?(resend.correlation_id, "codex-request-retry:")

    assert resend.request_metadata["client_resend"] == %{
             "predecessor_request_id" => request.id,
             "reason" => "failed_predecessor"
           }

    assert log =~ "reason_code=failed_predecessor_retry"
    assert log =~ "predecessor_request_id=#{request.id}"

    refute Repo.exists?(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id
             )
           )
  end

  @tag :stream_cut_resend
  test "lifecycle-only stream cut persists the native client retry observation with a null first_visible_at" do
    enable_owner_forwarding!()

    upstream =
      start_upstream(
        # provenance: observed findings issue 124 (lifecycle frames then a transport close without a terminal)
        FakeUpstream.strict_sequence([
          strict_native_request(1, stream_cut_frames("persisted", []))
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()

    payload =
      stream_cut_payload(
        setup,
        tool_continuation_input("persisted lifecycle cut prompt sentinel"),
        "persisted"
      )

    {_server, port} = start_public_endpoint_with_server!()

    %{conn: conn, request: request, attempt: attempt, turn: turn} =
      stream_cut_first_turn!(setup, port, turn_state, payload, "response.in_progress")

    Mint.HTTP.close(conn)

    assert request.native_client_retry_version == 1

    assert attempt.response_metadata["native_client_retry_observation"] == %{
             "version" => 1,
             "authority_complete" => true,
             "output_item_done_count" => 0,
             "output_item_done_count_saturated" => false,
             "partial_reasoning_seen" => false,
             "first_visible_at" => nil,
             "terminal_seen" => false,
             "terminal_candidate_seen" => false
           }

    assert ClientRetry.verified_lifecycle_cut?(turn, request, attempt)
    refute inspect(attempt.response_metadata) =~ "prompt sentinel"
    assert FakeUpstream.count(upstream) == 1
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :stream_cut_resend
  test "lifecycle-only stream cut on a tool-continuation turn admits the byte-identical resend with a derived request claim" do
    %{request: request, resend: resend, log: log} =
      stream_cut_resend_scenario(
        tool_continuation_input("tool continuation lifecycle cut prompt sentinel"),
        "tool_continuation",
        expect: :admitted
      )

    assert String.starts_with?(request.correlation_id, "codex-request:")

    assert {:ok, resend.correlation_id} ==
             ClientRetry.deterministic_failed_predecessor_claim(
               request.correlation_id,
               request.id
             )

    assert resend.request_metadata["client_resend"] == %{
             "predecessor_request_id" => request.id,
             "reason" => "failed_predecessor"
           }

    assert log =~ "websocket client resend admitted stage=websocket_turn_claim"
    assert log =~ "reason_code=failed_predecessor_retry"
    assert log =~ "predecessor_request_id=#{request.id}"
    assert log =~ "predecessor_shape=lifecycle_cut"

    refute Repo.exists?(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id
             )
           )
  end

  @tag :stream_cut_resend
  test "stream cut after one completed output item keeps the duplicate turn fence for the byte-identical resend" do
    completed_item =
      CodexPooler.JSON.encode!(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "synthetic completed item"}]
        }
      })

    %{request: request, attempt: attempt, log: log} =
      stream_cut_resend_scenario(
        tool_continuation_input("completed item cut prompt sentinel"),
        "completed_item",
        expect: :rejected,
        pre_close_frames: [completed_item],
        last_upstream_event_type: "response.output_item"
      )

    assert %{"output_item_done_count" => 1, "first_visible_at" => first_visible_at} =
             attempt.response_metadata["native_client_retry_observation"]

    assert is_binary(first_visible_at)
    assert String.starts_with?(request.correlation_id, "codex-request:")

    assert log =~
             "websocket replay rejection stage=websocket_turn_claim reason_code=reservation_duplicate"

    assert log =~ "resend_disposition=terminal_predecessor"
    refute log =~ "websocket client resend admitted"
  end

  @tag :stream_cut_resend
  test "lifecycle-only stream cut on a text-only turn admits the byte-identical resend as one client-retry successor" do
    %{request: request, resend: resend} =
      stream_cut_resend_scenario(
        native_text_input("text only lifecycle cut prompt sentinel"),
        "text_only",
        expect: :admitted
      )

    assert String.starts_with?(request.correlation_id, "codex-turn:")
    assert String.starts_with?(resend.correlation_id, "client-retry-v1:")

    assert Repo.one!(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id,
               select: link.successor_request_id
             )
           ) == resend.id
  end

  @tag :provider_terminal_resend
  test "byte-identical tool-continuation resends after a provider terminal failure admit exactly one lifecycle" do
    # Strict finite scenario: the first turn ends with the provider terminal,
    # then two concurrent byte-identical resends race for the derived claim.
    # Exactly one reaches the second upstream response; a third send fails the
    # fixture.
    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (2026-09-09 23:43 UTC response.failed server_error)
        FakeUpstream.strict_sequence([
          strict_native_request_any_connection(provider_terminal_failure_frames("concurrent")),
          strict_native_request_any_connection(
            completed_response_frames("resp_after_concurrent_resend", 3, 1)
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "provider-failure-concurrent"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      tool_continuation_payload(
        setup.model.exposed_model_id,
        "provider-failure-concurrent-turn",
        "concurrent resend prompt sentinel"
      )

    assert :ok =
             execute_websocket_response(auth, payload, opts, fn frame ->
               send(self(), {:websocket_frame, :first, frame})
             end)

    assert "response.failed" in received_frame_types(:first)
    assert [failed] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert failed.status == "failed"
    failed_id = failed.id

    parent = self()

    tasks =
      for label <- [:first, :second] do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:resend_task_ready, label, self()})

          receive do
            :run_resend -> :ok
          after
            5_000 -> flunk("resend task #{label} was not released")
          end

          execute_websocket_response(auth, payload, opts, fn frame ->
            send(parent, {:websocket_frame, label, frame})
          end)
        end)
      end

    task_pids =
      for _label <- [:first, :second] do
        assert_receive {:resend_task_ready, _label, pid}, 5_000
        pid
      end

    Enum.each(task_pids, &send(&1, :run_resend))
    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &match?(:ok, &1)) == 1
    assert Enum.count(results, &match?({:error, %{status: 409, code: "duplicate_turn"}}, &1)) == 1

    [{admitted_label, :ok}] =
      Enum.filter(Enum.zip([:first, :second], results), &match?({_label, :ok}, &1))

    assert "response.completed" in received_frame_types(admitted_label)
    refute_received {:websocket_frame, _label, _frame}

    assert [%Request{id: ^failed_id}, admitted] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at]
               )
             )

    assert String.starts_with?(admitted.correlation_id, "codex-request-retry:")
    assert admitted.request_metadata["client_resend"]["predecessor_request_id"] == failed_id
    assert admitted.status == "succeeded"

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             2

    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :provider_terminal_resend
  test "byte-identical resend while the first turn is still in progress keeps the duplicate turn fence" do
    release_ref = make_ref()

    # Strict finite scenario: the only upstream connection sends no terminal
    # until released, so the first turn stays in progress while the resend is
    # fenced; the fixture refuses any second send.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request_any_connection(
            FakeUpstream.websocket_close_without_terminal_barrier(
              notify: self(),
              release_ref: release_ref,
              code: 1001,
              reason: "synthetic close after the fenced resend"
            )
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "provider-failure-in-progress"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      tool_continuation_payload(
        setup.model.exposed_model_id,
        "in-progress-fence-turn",
        "in progress resend prompt sentinel"
      )

    parent = self()

    first =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        execute_websocket_response(auth, payload, opts, fn frame ->
          send(parent, {:websocket_frame, :first, frame})
        end)
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   5_000

    {result, log} =
      with_info_log(fn ->
        execute_websocket_response(auth, payload, opts, fn frame ->
          send(parent, {:websocket_frame, :resend, frame})
        end)
      end)

    assert {:error, %{status: 409, code: "duplicate_turn"}} = result
    refute_received {:websocket_frame, :resend, _frame}
    assert log =~ "reason_code=reservation_duplicate"
    assert log =~ "resend_disposition=active_predecessor"
    refute log =~ "in progress resend prompt sentinel"

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    first_result = Task.await(first, 10_000)
    assert match?(:ok, first_result) or match?({:error, %{status: _status}}, first_result)

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1

    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :provider_terminal_resend
  test "byte-identical resend after the client retry window keeps the duplicate turn fence" do
    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (2026-09-09 23:43 UTC response.failed server_error)
        FakeUpstream.strict_sequence([
          strict_native_request_any_connection(provider_terminal_failure_frames("expired"))
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "provider-failure-expired"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      tool_continuation_payload(
        setup.model.exposed_model_id,
        "expired-resend-turn",
        "expired resend prompt sentinel"
      )

    assert :ok = execute_websocket_response(auth, payload, opts, fn _frame -> :ok end)
    assert [failed] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert failed.status == "failed"

    # The retry window is measured from the predecessor's completion; move it
    # just past the 30 s client retry window instead of waiting.
    expired_at = DateTime.add(failed.completed_at, -31, :second)

    Repo.update_all(from(r in Request, where: r.id == ^failed.id),
      set: [completed_at: expired_at]
    )

    {result, log} =
      with_info_log(fn ->
        execute_websocket_response(auth, payload, opts, fn frame ->
          send(self(), {:websocket_frame, :resend, frame})
        end)
      end)

    assert {:error, %{status: 409, code: "duplicate_turn"}} = result
    refute_received {:websocket_frame, :resend, _frame}
    assert log =~ "reason_code=reservation_duplicate"
    assert log =~ "resend_disposition=retry_expired"
    refute log =~ "expired resend prompt sentinel"

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # Strict finite scenario shared by both resend paths: the first turn ends
  # with the provider's own `response.failed` terminal on the single physical
  # upstream connection, then the client's byte-identical resend after a
  # reconnect is admitted as one fresh turn on that connection. Any further
  # send fails the fixture.
  defp provider_terminal_resend_scenario(input, label) do
    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()

      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    completed_response_id = "resp_after_provider_failure_#{label}"

    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (2026-09-09 23:43 UTC response.failed server_error)
        FakeUpstream.strict_sequence([
          strict_native_request(1, provider_terminal_failure_frames(label)),
          strict_native_request(1, completed_response_frames(completed_response_id, 3, 1))
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()
    thread_id = Ecto.UUID.generate()

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => thread_id,
              "thread_id" => thread_id,
              "turn_id" => "provider-failure-#{label}-turn",
              "request_kind" => "turn"
            })
        },
        "input" => input,
        "stream" => true,
        "generate" => true
      })

    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

    {conn, _websocket, _seen_types, failure_frame} =
      receive_public_websocket_until_terminal(conn, websocket, ref, [])

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "server_error"}}
           } = failure_frame

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => failed_request_id, "status" => "failed"}
                    }},
                   @websocket_frame_timeout

    request = Repo.get!(Request, failed_request_id)
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    turn = await_turn_completed!(request.id)

    # The predecessor shape the resend policy verifies: every row is failed
    # with the provider code and the turn points at the failed attempt.
    assert %{
             request_status: request.status,
             request_error: request.last_error_code,
             attempt_status: attempt.status,
             attempt_error: attempt.network_error_code,
             attempt_generation: attempt.replay_generation,
             turn_status: turn.status,
             turn_error: turn.error_code,
             turn_final_attempt: turn.final_attempt_id
           } == %{
             request_status: "failed",
             request_error: "server_error",
             attempt_status: "failed",
             attempt_error: "server_error",
             attempt_generation: 0,
             turn_status: "failed",
             turn_error: "server_error",
             turn_final_attempt: attempt.id
           }

    refute is_nil(request.completed_at)
    refute is_nil(turn.completed_at)

    # The client disconnects; the old socket's cleanup completes before the
    # byte-identical resend, as in the incident's reconnect sequence.
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    assert %{downstream: %{pid: downstream_pid}} = :sys.get_state(owner_pid)
    downstream_monitor = Process.monitor(downstream_pid)

    {resend_outcome, log} =
      with_info_log(fn ->
        Mint.HTTP.close(conn)

        assert_receive {:DOWN, ^downstream_monitor, :process, ^downstream_pid, _reason},
                       @connection_shutdown_timeout_ms

        {retry_conn, retry_websocket, retry_ref} =
          public_websocket_connect!(port, setup, turn_state)

        {retry_conn, retry_websocket} =
          public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, payload)

        {retry_conn, _retry_websocket, _types, terminal} =
          receive_public_websocket_until_terminal(retry_conn, retry_websocket, retry_ref, [])

        Mint.HTTP.close(retry_conn)

        case terminal do
          %{"type" => "response.completed", "response" => %{"id" => id}} ->
            {:completed, id}

          %{"type" => "error", "status" => status, "error" => %{"code" => code}} ->
            {:error, status, code}

          %{"type" => "response.failed"} = failed ->
            {:failed, get_in(failed, ["response", "error", "code"])}
        end
      end)

    assert resend_outcome == {:completed, completed_response_id}
    refute log =~ "websocket replay rejection"
    refute log =~ "prompt sentinel"

    assert [%Request{id: ^failed_request_id}, resend] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at]
               )
             )

    resend_id = resend.id

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => ^resend_id, "status" => "succeeded"}
                    }},
                   @websocket_frame_timeout

    resend = Repo.get!(Request, resend_id)
    assert resend.status == "succeeded"

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
             :count
           ) == 2

    # Health neutral: the client's resend is not backend evidence.
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)

    %{setup: setup, request: request, attempt: attempt, turn: turn, resend: resend, log: log}
  end

  # Strict finite scenario for a stream cut: the first turn receives
  # `response.created`, `response.in_progress`, and any `pre_close_frames`, then
  # the upstream drops the TCP connection without a terminal or a close frame
  # (findings issue 124). An admitted byte-identical resend after the client
  # reconnects is the only other send and arrives on a replacement connection.
  defp stream_cut_resend_scenario(input, label, opts) do
    expect = Keyword.fetch!(opts, :expect)
    pre_close_frames = Keyword.get(opts, :pre_close_frames, [])
    enable_owner_forwarding!()

    completed_response_id = "resp_after_stream_cut_#{label}"

    replies =
      case expect do
        :admitted ->
          [
            strict_native_request(1, stream_cut_frames(label, pre_close_frames)),
            strict_native_request(2, completed_response_frames(completed_response_id, 3, 1))
          ]

        :rejected ->
          [strict_native_request(1, stream_cut_frames(label, pre_close_frames))]
      end

    upstream =
      start_upstream(
        # provenance: observed findings issue 124 (lifecycle frames, transport close; items and resend reply synthetic)
        FakeUpstream.strict_sequence(replies)
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()
    payload = stream_cut_payload(setup, input, label)

    # The attempt records the bounded event family, not the raw frame type.
    last_event_type = Keyword.get(opts, :last_upstream_event_type, "response.in_progress")

    {_server, port} = start_public_endpoint_with_server!()

    %{conn: conn, request: request, attempt: attempt, turn: turn} =
      stream_cut_first_turn!(setup, port, turn_state, payload, last_event_type)

    failed_request_id = request.id

    # The client disconnects; the old socket's cleanup completes before the
    # byte-identical resend, as in the incident's reconnect sequence.
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    assert %{downstream: %{pid: downstream_pid}} = :sys.get_state(owner_pid)
    downstream_monitor = Process.monitor(downstream_pid)

    {resend_outcome, log} =
      with_info_log(fn ->
        Mint.HTTP.close(conn)

        assert_receive {:DOWN, ^downstream_monitor, :process, ^downstream_pid, _reason},
                       @connection_shutdown_timeout_ms

        {retry_conn, retry_websocket, retry_ref} =
          public_websocket_connect!(port, setup, turn_state)

        {retry_conn, retry_websocket} =
          public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, payload)

        {retry_conn, _retry_websocket, _types, terminal} =
          receive_public_websocket_until_terminal(retry_conn, retry_websocket, retry_ref, [])

        Mint.HTTP.close(retry_conn)

        case terminal do
          %{"type" => "response.completed", "response" => %{"id" => id}} ->
            {:completed, id}

          %{"type" => "error", "status" => status, "error" => %{"code" => code}} ->
            {:error, status, code}

          %{"type" => "response.failed"} = failed ->
            {:failed, get_in(failed, ["response", "error", "code"])}
        end
      end)

    refute log =~ "prompt sentinel"

    resend =
      case expect do
        :admitted ->
          assert resend_outcome == {:completed, completed_response_id}
          refute log =~ "websocket replay rejection"

          assert [%Request{id: ^failed_request_id}, resend] =
                   Repo.all(
                     from(r in Request,
                       where: r.pool_id == ^setup.pool.id,
                       order_by: [asc: r.admitted_at]
                     )
                   )

          resend_id = resend.id

          assert_receive {Events,
                          %{
                            reason: "request_finalized",
                            payload: %{"request_id" => ^resend_id, "status" => "succeeded"}
                          }},
                         @websocket_frame_timeout

          assert Repo.aggregate(
                   from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
                   :count
                 ) == 2

          assert FakeUpstream.count(upstream) == 2
          Repo.get!(Request, resend_id)

        :rejected ->
          assert resend_outcome == {:error, 409, "duplicate_turn"}

          assert [%Request{id: ^failed_request_id}] =
                   Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

          assert Repo.aggregate(
                   from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
                   :count
                 ) == 1

          assert FakeUpstream.count(upstream) == 1
          nil
      end

    assert :ok = FakeUpstream.verify!(upstream)

    %{setup: setup, request: request, attempt: attempt, turn: turn, resend: resend, log: log}
  end

  # Runs the cut turn over the public endpoint and returns the finalized rows.
  # The predecessor shape both resend paths judge: every row failed with
  # `upstream_stream_error`, the turn counted `response.created` as visible,
  # and the attempt carries the exact Mint closed evidence with no terminal.
  defp stream_cut_first_turn!(setup, port, turn_state, payload, last_event_type) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

    {conn, _websocket, seen_types, failure_frame} =
      receive_public_websocket_until_terminal(conn, websocket, ref, [])

    assert %{"type" => "error", "status" => 502} = failure_frame
    assert ["response.created", "response.in_progress" | _rest] = seen_types

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => failed_request_id, "status" => "failed"}
                    }},
                   @websocket_frame_timeout

    request = Repo.get!(Request, failed_request_id)
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    turn = await_turn_completed!(request.id)

    assert %{
             request: {request.status, request.last_error_code},
             attempt: {attempt.status, attempt.network_error_code, attempt.replay_generation},
             turn: {turn.status, turn.error_code, turn.final_attempt_id}
           } == %{
             request: {"failed", "upstream_stream_error"},
             attempt: {"failed", "upstream_stream_error", 0},
             turn: {"failed", "upstream_stream_error", attempt.id}
           }

    refute is_nil(turn.first_visible_output_at)

    assert Map.take(
             attempt.response_metadata["transport_failure"],
             ~w(phase termination_source exception reason transport_signal terminal_seen terminal_candidate_seen last_upstream_event_type)
           ) == %{
             "phase" => "receive",
             "termination_source" => "mint_transport_error",
             "exception" => "Mint.TransportError",
             "reason" => "closed",
             "transport_signal" => "tcp_closed",
             "terminal_seen" => false,
             "terminal_candidate_seen" => false,
             "last_upstream_event_type" => last_event_type
           }

    %{conn: conn, request: request, attempt: attempt, turn: turn}
  end

  defp stream_cut_frames(label, pre_close_frames) do
    response_id = "resp_stream_cut_#{label}"

    FakeUpstream.websocket_text_frames_then_abrupt_close(
      [
        CodexPooler.JSON.encode!(%{
          "type" => "response.created",
          "response" => %{"id" => response_id, "status" => "in_progress"}
        }),
        CodexPooler.JSON.encode!(%{
          "type" => "response.in_progress",
          "response" => %{"id" => response_id, "status" => "in_progress"}
        })
      ] ++ pre_close_frames
    )
  end

  defp stream_cut_payload(setup, input, label) do
    thread_id = Ecto.UUID.generate()

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "session_id" => thread_id,
            "thread_id" => thread_id,
            "turn_id" => "stream-cut-#{label}-turn",
            "request_kind" => "turn"
          })
      },
      "input" => input,
      "stream" => true,
      "generate" => true
    })
  end

  defp enable_owner_forwarding! do
    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()

      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp provider_terminal_failure_frames(label) do
    response_id = "resp_provider_failure_#{label}"

    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => response_id, "status" => "in_progress"}
      }),
      CodexPooler.JSON.encode!(%{
        "type" => "response.failed",
        "response" => %{
          "id" => response_id,
          "status" => "failed",
          "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}
        }
      })
    ])
  end

  defp completed_response_frames(response_id, input_tokens, output_tokens) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "usage" => %{
            "input_tokens" => input_tokens,
            "output_tokens" => output_tokens,
            "total_tokens" => input_tokens + output_tokens
          }
        }
      })
    ])
  end

  defp strict_native_request_any_connection(respond) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      json: [valid: true, equals: %{"type" => "response.create"}],
      respond: respond
    )
  end

  defp tool_continuation_input(text) do
    native_text_input(text) ++
      [
        %{
          "type" => "function_call",
          "call_id" => "call_provider_failure_resend",
          "name" => "shell",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_provider_failure_resend",
          "output" => "synthetic tool output sentinel"
        }
      ]
  end

  defp tool_continuation_payload(model, turn_id, text) do
    thread_id = Ecto.UUID.generate()

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model,
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "session_id" => thread_id,
            "thread_id" => thread_id,
            "turn_id" => turn_id,
            "request_kind" => "turn"
          })
      },
      "input" => tool_continuation_input(text),
      "stream" => true,
      "generate" => true
    })
  end

  defp await_turn_completed!(request_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    case Repo.all(from(t in CodexTurn, where: t.request_id == ^request_id)) do
      [%CodexTurn{status: status} = turn] when status != "in_progress" ->
        turn

      turns ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            5 -> await_turn_completed!(request_id, deadline)
          end
        else
          flunk(
            "expected the failed turn to complete, got #{inspect(Enum.map(turns, & &1.status))}"
          )
        end
    end
  end

  defp received_frame_types(label, acc \\ []) do
    receive do
      {:websocket_frame, ^label, frame} ->
        received_frame_types(label, [CodexPooler.JSON.decode!(frame)["type"] | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp receive_public_websocket_until_terminal(conn, websocket, ref, seen_types) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal
      when type in ["response.completed", "response.failed", "error"] ->
        {conn, websocket, Enum.reverse(seen_types), terminal}

      %{"type" => type} ->
        receive_public_websocket_until_terminal(conn, websocket, ref, [type | seen_types])
    end
  end

  defp receive_public_websocket_until_error(conn, websocket, ref, seen_types) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => "error"} = error ->
        {conn, websocket, Enum.reverse(seen_types), error}

      %{"type" => type} ->
        receive_public_websocket_until_error(conn, websocket, ref, [type | seen_types])
    end
  end
end
