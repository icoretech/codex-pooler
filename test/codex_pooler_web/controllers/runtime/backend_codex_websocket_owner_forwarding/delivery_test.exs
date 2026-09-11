defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.DeliveryTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient

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

  test "owner-forwarded native turn records a delivered downstream receipt on the proxy side" do
    delta_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "owner-receipt-prompt-sentinel"
      })

    terminal_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_owner_delivery_receipt",
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
            websocket_connection_ordinal: 1,
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
          request_id: "ws-owner-delivery-receipt",
          accepted_turn_state: "stable-ws-owner-delivery-receipt",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert state.codex_session.owner_instance_id == Atom.to_string(node())

      {state, logs} =
        with_info_log(fn ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in(
                     {websocket_payload(setup, "owner receipt"), [opcode: :text]},
                     state
                   )

          assert {:push, {:text, ^delta_frame}, state} = receive_owner_socket_push(state)
          assert {:push, {:text, ^terminal_frame}, state} = receive_owner_socket_push(state)
          settle_owner_socket_turn(state)
        end)

      assert MapSet.size(state.tasks) == 0
      assert :ok = FakeUpstream.verify!(upstream)

      assert [request_log] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request_log.status == "succeeded"
      assert request_log.transport == "websocket"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_log.id))
      assert attempt.status == "succeeded"

      assert %{
               "outcome" => "delivered",
               "terminal_class" => "response.completed",
               "pushed_at" => pushed_at,
               "frames_after_visible" => 2,
               "transport" => "websocket"
             } = attempt.response_metadata["downstream_delivery"]

      assert {:ok, _pushed_at, 0} = DateTime.from_iso8601(pushed_at)
      assert attempt.response_metadata["upstream_websocket_connection"]["generation"] == 1

      assert logs =~
               "websocket downstream terminal pushed request_id=#{request_log.id} " <>
                 "codex_session_id=#{state.codex_session.id} outcome=delivered " <>
                 "terminal_class=response.completed frames_after_visible=2"

      assert_no_leak!(
        "owner delivery receipt",
        inspect({request_log.request_metadata, attempt.response_metadata, logs})
      )

      refute inspect(attempt.response_metadata) =~ "owner-receipt-prompt-sentinel"
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded native failure after accepted data logs visible output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-output-after-data")
    downstream = state.websocket_owner_downstream

    frame =
      CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "visible"})

    assert {:push, {:text, ^frame}, state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, frame}),
               state
             )

    assert state.native_turn_output_task_pids == MapSet.new([task_pid])

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, error_frame}, failed_state} = result

    assert %{"type" => "error", "error" => %{"code" => "owner_drained"}} =
             CodexPooler.JSON.decode!(error_frame)

    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-after-data", "after_visible_output")
  end

  test "owner-forwarded native failure before data logs no visible output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-output-before-data")
    downstream = state.websocket_owner_downstream

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, error_frame}, failed_state} = result

    assert %{"type" => "error", "error" => %{"code" => "owner_drained"}} =
             CodexPooler.JSON.decode!(error_frame)

    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-before-data", "before_visible_output")
  end

  test "owner-forwarded metadata-only data remains pre-visible while unknown controls commit output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-metadata-pre-visible")
    downstream = state.websocket_owner_downstream

    metadata_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "codex.response.metadata",
        "headers" => %{"x-models-etag" => ~s(W/"owner-turn-etag")}
      })

    assert {:push, {:text, ^metadata_frame}, state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, metadata_frame}),
               state
             )

    assert state.native_turn_output_task_pids == MapSet.new()

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-metadata-pre-visible", "before_visible_output")

    unknown_frame = CodexPooler.JSON.encode!(%{"type" => "codex.future_control"})

    assert {:push, {:text, ^unknown_frame}, visible_state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, unknown_frame}),
               state
             )

    assert visible_state.native_turn_output_task_pids == MapSet.new([task_pid])
  end

  test "owner-forwarded native output state resets before a second turn" do
    first_task_pid = socket_test_task()
    second_task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(first_task_pid) end)
    on_exit(fn -> stop_socket_test_task(second_task_pid) end)

    state = owner_output_state(first_task_pid, "ws-owner-output-second-turn")
    downstream = state.websocket_owner_downstream

    frame =
      CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "first"})

    assert {:push, {:text, ^frame}, state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, frame}),
               state
             )

    assert {:ok, state} =
             CodexResponsesSocket.handle_info(owner_frame(downstream, :complete), state)

    assert state.native_turn_output_task_pids == MapSet.new()

    state = replace_owner_output_task(state, first_task_pid, second_task_pid)

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-second-turn", "before_visible_output")
  end

  test "owner-forwarded public rate-limit-only data does not commit output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = public_owner_output_state(task_pid, "ws-owner-public-rate-only")
    downstream = state.websocket_owner_downstream

    rate_limit_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "codex.rate_limits",
        "rate_limits" => %{"primary" => %{"used_percent" => 42}}
      })

    assert {:push, {:text, normalized_frame}, state} =
             CodexResponsesSocket.handle_info(
               public_owner_frame(downstream, task_pid, {:data, rate_limit_frame}),
               state
             )

    assert %{"type" => "codex.rate_limits"} = CodexPooler.JSON.decode!(normalized_frame)
    refute state.public_turn_output_committed?

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          public_owner_frame(
            downstream,
            task_pid,
            owner_error_payload(:upstream_stream_error)
          ),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    refute failed_state.public_turn_output_committed?
    assert_native_owner_turn_log!(logs, "ws-owner-public-rate-only", "before_visible_output")
  end

  test "owner-forwarded public metadata-only data does not commit output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = public_owner_output_state(task_pid, "ws-owner-public-metadata-only")
    downstream = state.websocket_owner_downstream

    metadata_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "codex.response.metadata",
        "headers" => %{"x-models-etag" => ~s(W/"owner-public-etag")}
      })

    assert {:push, {:text, normalized_frame}, state} =
             CodexResponsesSocket.handle_info(
               public_owner_frame(downstream, task_pid, {:data, metadata_frame}),
               state
             )

    assert CodexPooler.JSON.decode!(normalized_frame) == %{
             "headers" => %{"x-models-etag" => ~s(W/"owner-public-etag")},
             "sequence_number" => 0,
             "type" => "codex.response.metadata"
           }

    refute state.public_turn_output_committed?
  end

  test "late stale owner epoch data cannot commit the active native turn" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-output-stale-epoch", 2)
    active_downstream = state.websocket_owner_downstream
    stale_downstream = %{active_downstream | epoch: 1}

    stale_frame =
      CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "stale"})

    assert {:ok, ^state} =
             CodexResponsesSocket.handle_info(
               owner_frame(stale_downstream, {:data, stale_frame}),
               state
             )

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(active_downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-stale-epoch", "before_visible_output")
    refute logs =~ "delta=stale"
  end

  @tag :native_observer_failure
  test "owner-forwarded frame observer failure still delivers one terminal" do
    marker = "synthetic-owner-observer-marker-#{System.unique_integer([:positive])}"
    input_marker = "synthetic-owner-observer-input-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_observer_failure",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    upstream_boundary = frame_observer_failure_upstream_boundary(self(), marker)

    {:ok, state} =
      owner_socket(auth, "ws-owner-observer-failure", "owner-observer-failure",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, input_marker)

          assert {:ok, state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

          assert {:push, {:text, terminal}, state} = receive_owner_socket_push(state)

          assert %{"id" => "resp_owner_observer_failure"} = CodexPooler.JSON.decode!(terminal)
          assert {:ok, state} = receive_owner_socket_complete(state)
          flush_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_receive {:owner_frame_observer_failed, observer_pid}
    assert is_pid(observer_pid)
    refute_received {:owner_frame_observer_failed, _duplicate}
    refute_received {:websocket_owner_frame, _, _, _duplicate_terminal}
    assert logs =~ "upstream websocket frame observer failed operation=observe_frame"
    refute logs =~ marker
    refute logs =~ setup.authorization
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0

    assert [request] = request_logs(setup.pool.id)
    assert request.transport == "websocket"
    rows = assert_forwarding_cardinality!(request, state.codex_session.id, "succeeded")
    assert_no_markers_persisted!(rows, setup.pool.id, [marker, input_marker])
    refute logs =~ input_marker
    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
  end

  @tag receiver_delivery_gap: :pin
  test "direct receiver accepts provider frames before response delivery cleanup" do
    assert_receiver_delivery_gap(:frames_first)
  end

  @tag receiver_delivery_gap: :cleanup_first
  test "direct receiver keeps terminal delivery coupled to provider frame acceptance" do
    assert_receiver_delivery_gap(:cleanup_first)
  end

  defp assert_receiver_delivery_gap(order) when order in [:frames_first, :cleanup_first] do
    response_id = "resp_receiver_delivery_gap_#{order}_#{System.unique_integer([:positive])}"

    frames = [
      CodexPooler.JSON.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => response_id, "status" => "in_progress"}
      }),
      CodexPooler.JSON.encode!(%{
        "type" => "response.output_item.done",
        "item" => %{"id" => "item_receiver_delivery_gap", "type" => "message"}
      }),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        }
      })
    ]

    upstream = start_upstream(FakeUpstream.websocket_text_frames(frames))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    parent = self()

    receiver = spawn(fn -> receiver_delivery_gap_process(parent, order, auth, setup) end)

    receiver_monitor = Process.monitor(receiver)

    try do
      send(receiver, {:receiver_delivery_gap_start, order})

      assert_receive {:receiver_delivery_gap_result, ^order, events, cleanup_snapshot},
                     @handoff_detection_timeout_ms

      assert events == ["response.created", "response.output_item.done", "response.completed"]
      refute_received {:stale_prepared_writer, _data}
      assert cleanup_snapshot == %{monitor_tracked?: false, task_tracked?: false}
      assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, :normal}

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert_forwarding_cardinality!(request, nil, "succeeded")
    after
      if Process.alive?(receiver), do: Process.exit(receiver, :kill)

      case previous do
        :error ->
          Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)

        {:ok, value} ->
          Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end
  end

  defp receiver_delivery_gap_process(parent, order, auth, setup) do
    receive do
      {:receiver_delivery_gap_start, ^order} ->
        {:ok, state} =
          CodexResponsesSocket.init(%{
            auth: auth,
            opts: %{
              request_id: "ws-receiver-delivery-gap-#{order}",
              accepted_turn_state: "receiver-delivery-gap-#{order}",
              client_ip: "127.0.0.1"
            }
          })

        payload = websocket_payload(setup, "receiver delivery gap #{order}")

        opts =
          Gateway.websocket_response_options(
            state.opts,
            state.codex_session,
            state.upstream_websocket_session,
            true
          )

        receiver_pid = self()
        stale_writer = fn data -> send(receiver_pid, {:stale_prepared_writer, data}) end
        {:ok, prepared} = Gateway.prepare_websocket_response(payload, opts, stale_writer)

        {:ok, task_pid} =
          ResponseTask.start(
            receiver_pid,
            :direct,
            fn task_pid ->
              Gateway.run_prepared_websocket_response_for_socket(
                auth,
                prepared,
                fn data -> send(receiver_pid, {:codex_response_chunk, task_pid, data}) end
              )
            end,
            fn _task_pid, :owner_drained -> :ok end
          )

        monitor = Process.monitor(task_pid)

        state = %{
          state
          | tasks: MapSet.new([task_pid]),
            task_monitors: %{task_pid => monitor},
            request_response_work_started?: true
        }

        run_receiver_delivery_gap(parent, order, task_pid, state)
    end
  end

  defp run_receiver_delivery_gap(parent, :frames_first, task_pid, state) do
    {state, events} = receive_receiver_delivery_gap_frames(task_pid, state)
    state = receive_receiver_delivery_gap_result(task_pid, state)
    {:completed, state} = receive_receiver_delivery_gap_completion(task_pid, state)

    send(parent, {
      :receiver_delivery_gap_result,
      :frames_first,
      events,
      receiver_delivery_gap_snapshot(state)
    })

    CodexResponsesSocket.terminate(:closed, state)
  end

  defp run_receiver_delivery_gap(parent, :cleanup_first, task_pid, state) do
    state = receive_receiver_delivery_gap_result(task_pid, state)

    state =
      case receive_receiver_delivery_gap_completion(task_pid, state, 0) do
        {:completed, state} -> state
        {:pending, state} -> state
      end

    {state, events} = receive_receiver_delivery_gap_frames(task_pid, state)
    {:completed, state} = receive_receiver_delivery_gap_completion(task_pid, state)

    send(
      parent,
      {:receiver_delivery_gap_result, :cleanup_first, events,
       receiver_delivery_gap_snapshot(state)}
    )
  end

  defp receive_receiver_delivery_gap_frames(task_pid, state) do
    receive_receiver_delivery_gap_frames(task_pid, state, [])
  end

  defp receive_receiver_delivery_gap_frames(_task_pid, state, events)
       when length(events) == 3,
       do: {state, events}

  defp receive_receiver_delivery_gap_frames(task_pid, state, events) do
    receive do
      {:codex_response_chunk, ^task_pid, data} = message ->
        assert {:push, {:text, pushed}, state} = CodexResponsesSocket.handle_info(message, state)
        assert CodexPooler.JSON.decode!(pushed) == CodexPooler.JSON.decode!(data)
        event = CodexPooler.JSON.decode!(pushed)["type"]

        events =
          if event in ["response.created", "response.output_item.done", "response.completed"],
            do: events ++ [event],
            else: events

        receive_receiver_delivery_gap_frames(task_pid, state, events)
    after
      @handoff_detection_timeout_ms ->
        flunk("expected queued provider frame at the direct receiver")
    end
  end

  defp receive_receiver_delivery_gap_completion(
         task_pid,
         state,
         timeout \\ @handoff_detection_timeout_ms
       ) do
    receive do
      {:websocket_response_delivery_complete, ^task_pid, _activity_token} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        {:completed, state}
    after
      timeout -> {:pending, state}
    end
  end

  defp receiver_delivery_gap_snapshot(state) do
    %{
      task_tracked?: MapSet.size(state.tasks) > 0,
      monitor_tracked?: map_size(state.task_monitors) > 0
    }
  end

  defp owner_output_state(task_pid, request_id, epoch \\ 1) when is_pid(task_pid) do
    downstream = %{pid: self(), epoch: epoch, correlation_id: "correlation-#{request_id}"}

    %{
      opts: %{request_id: request_id},
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      native_turn_output_task_pids: MapSet.new(),
      websocket_owner_downstream: downstream,
      websocket_owner_drain_observed?: false,
      websocket_owner_active_turn_reconnect?: false,
      connection_started_at_monotonic_ms: System.monotonic_time(:millisecond)
    }
  end

  defp public_owner_output_state(task_pid, request_id) when is_pid(task_pid) do
    task_pid
    |> owner_output_state(request_id)
    |> Map.put(:opts, public_owner_request_options(request_id))
    |> Map.put(:public_response_task_pid, task_pid)
    |> Map.put(
      :public_responses_websocket_state,
      Adapter.public_responses_turn_state()
    )
    |> Map.put(:public_turn_task_done?, false)
    |> Map.put(:public_turn_owner_complete?, false)
    |> Map.put(:public_turn_aborted?, false)
    |> Map.put(:public_turn_output_committed?, false)
  end

  defp public_owner_request_options(request_id) do
    %{request_id: request_id}
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
  end

  defp replace_owner_output_task(state, previous_task_pid, next_task_pid) do
    state
    |> Map.put(:tasks, MapSet.new([next_task_pid]))
    |> Map.put(:task_monitors, %{})
    |> Map.update!(:native_turn_output_task_pids, &MapSet.delete(&1, previous_task_pid))
  end

  defp owner_frame(downstream, payload) do
    {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, payload}
  end

  defp public_owner_frame(downstream, owner_turn_id, payload) do
    {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, owner_turn_id, payload}
  end

  defp owner_error_payload(reason) do
    assert {:ok, payload} =
             WebsocketOwnerContract.safe_error_payload(reason, nil)

    {:error, reason, payload}
  end

  defp assert_native_owner_turn_log!(logs, request_id, visible_output) do
    assert length(Regex.scan(~r/websocket native turn failed/, logs)) == 1
    assert logs =~ "request_id=#{request_id}"
    assert logs =~ "visible_output=#{visible_output}"
    refute logs =~ "phase=receive"
  end

  # Drives the owner-forwarded socket bookkeeping a live WebSock process would
  # receive after the provider frames (owner completion, activity token,
  # cleanup receipts, gateway result, post-push delivery acknowledgement)
  # until the turn has no tracked task left.
  defp settle_owner_socket_turn(%{tasks: tasks} = state) do
    if MapSet.size(tasks) == 0 do
      state
    else
      receive do
        {:websocket_owner_cleanup_witness, _, _, _, _} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))

        {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))

        {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))

        {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))

        {:websocket_response_activity, _, _} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))

        {:direct_request_cleanup, _, _, _} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))

        {:codex_response_done, _, _} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))

        {:websocket_response_delivery_complete, _, _} = message ->
          settle_owner_socket_turn(settle_owner_socket_message(message, state))
      after
        @handoff_detection_timeout_ms -> flunk("expected the owner websocket turn to settle")
      end
    end
  end

  defp settle_owner_socket_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:ok, state} -> state
      {:push, {:text, _frame}, state} -> state
    end
  end

  defp frame_observer_failure_upstream_boundary(test_pid, marker) do
    %{
      start: fn -> UpstreamWebsocketSession.start_link([]) end,
      send: fn upstream_pid, request, writer ->
        original_observer = request.frame_observer

        observer = fn frame, decoded ->
          send(test_pid, {:owner_frame_observer_failed, self()})
          invoke_frame_observer(original_observer, frame, decoded)
          raise marker
        end

        request = %{request | writer: writer, frame_observer: observer}
        UpstreamWebsocketSession.request(upstream_pid, request)
      end,
      close: &UpstreamWebsocketSession.close/1
    }
  end

  defp invoke_frame_observer(observer, frame, decoded) when is_function(observer, 2),
    do: observer.(frame, decoded)

  defp invoke_frame_observer(observer, frame, _decoded) when is_function(observer, 1),
    do: observer.(frame)

  defp invoke_frame_observer(_observer, _frame, _decoded), do: :ok
end
