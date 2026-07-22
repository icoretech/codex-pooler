defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStreamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

  @epoch 1

  defp start_armed(submit_fun, opts \\ []) do
    correlation_id = "bridge-stream-#{System.unique_integer([:positive])}"
    stream = WebsocketBridgeStream.start(correlation_id, opts)
    :ok = WebsocketBridgeStream.arm(stream, @epoch, submit_fun)
    stream
  end

  defp owner_frame(stream, payload) do
    send(stream.relay, {:websocket_owner_frame, stream.correlation_id, @epoch, payload})
  end

  defp blocking_submit do
    fn ->
      receive do
        :unblock -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp registered_submit(test_pid) do
    fn ->
      send(test_pid, {:submit_task, self()})

      receive do
        {:return, value} -> value
      after
        5_000 -> :ok
      end
    end
  end

  defp lifecycle_frame(bytes) when bytes >= 40 do
    prefix = ~s({"type":"response.created","padding":")
    suffix = ~s("})
    prefix <> String.duplicate("x", bytes - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  defp connection_metadata do
    %{
      lifecycle_id: Ecto.UUID.generate(),
      generation: 2,
      reused: true,
      reconnected: false
    }
  end

  defp attach_overflow_handler(test_pid) do
    handler_id = "websocket-bridge-overflow-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :websocket_bridge, :precommit_overflow],
        fn event, measurements, metadata, pid ->
          send(pid, {:overflow, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "an abnormally exiting submit task falls back with a scrubbed reason and no log" do
    logs =
      capture_log(fn ->
        stream = start_armed(fn -> exit(:boom) end)

        ref = stream.ref
        assert_receive {^ref, {:preflight, {:fallback, :boom}}}, 2_000
      end)

    # Before the catch wrapper this crashed the task and logged the whole
    # "Task ... terminating ... :boom" report.
    refute logs =~ "boom"
  end

  test "an owner death during the submit call leaks neither payload nor authorization" do
    marker = "LEAK_PROBE_PAYLOAD_MARKER"
    authorization = "Bearer LEAK_PROBE_AUTH_TOKEN"
    owner = spawn(fn -> Process.sleep(:infinity) end)

    submit_fun = fn ->
      GenServer.call(
        owner,
        {:submit, %{payload: marker, headers: [{"authorization", authorization}]}},
        30_000
      )
    end

    logs =
      capture_log(fn ->
        stream = start_armed(submit_fun)
        ref = stream.ref

        Process.exit(owner, :kill)

        # :killed when the kill lands mid-call, :owner_not_running when the
        # owner is already gone as the call starts — both scrubbed atoms.
        assert_receive {^ref, {:preflight, {:fallback, reason}}}, 2_000
        assert reason in [:killed, :owner_not_running]
      end)

    refute logs =~ marker
    refute logs =~ "LEAK_PROBE_AUTH_TOKEN"
  end

  test "a submit task killed from outside still falls back as task_down" do
    stream = start_armed(registered_submit(self()))
    ref = stream.ref

    assert_receive {:submit_task, task_pid}, 2_000
    Process.exit(task_pid, :kill)

    assert_receive {^ref, {:preflight, {:fallback, {:task_down, :killed}}}}, 2_000
  end

  test "queued data and completion deliver the preflight commit and every part in order" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    # Both messages are already queued before the dispatcher looks: the data
    # event must still be delivered ahead of :done.
    owner_frame(stream, {:data, ~s({"type":"response.output_text.delta","delta":"answer"})})
    owner_frame(stream, :complete)

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, data}}, 2_000
    assert data =~ "response.output_text.delta"
    assert_receive {^ref, :done}, 2_000
  end

  test "lifecycle events buffer until meaningful output commits the stream" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(stream, {:data, ~s({"type":"codex.rate_limits","rate_limits":{}})})
    owner_frame(stream, {:data, ~s({"type":"response.created"})})
    owner_frame(stream, {:data, ~s({"type":"response.output_text.delta","delta":"answer"})})
    owner_frame(stream, :complete)

    assert_receive {^ref, {:preflight, :stream}}, 2_000

    assert_receive {^ref, {:data, first}}, 2_000
    assert first =~ "codex.rate_limits"
    assert_receive {^ref, {:data, second}}, 2_000
    assert second =~ "response.created"
    assert_receive {^ref, {:data, third}}, 2_000
    assert third =~ "response.output_text.delta"
    assert_receive {^ref, :done}, 2_000
  end

  test "lifecycle-only frames followed by completion fall back without committing" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(stream, {:data, ~s({"type":"response.created"})})
    owner_frame(stream, {:data, ~s({"type":"response.in_progress"})})
    owner_frame(stream, {:data, ~s({"type":"response.queued"})})
    owner_frame(stream, {:data, ~s({"type":"codex.rate_limits","rate_limits":{}})})
    owner_frame(stream, :complete)

    assert_receive {^ref, {:preflight, {:fallback, :bridge_no_first_event}}}, 2_000
    refute_receive {^ref, {:data, _data}}, 100
    refute_receive {^ref, :done}, 100
  end

  test "internal-only frames followed by an owner error fall back without committing" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(stream, {:data, ~s({"type":"codex.rate_limits","rate_limits":{}})})
    owner_frame(stream, {:error, :upstream_websocket_error, %{}})

    assert_receive {^ref, {:preflight, {:fallback, :upstream_websocket_error}}}, 2_000
    refute_receive {^ref, {:data, _data}}, 100
  end

  test "an upstream failure terminal before visible output falls back" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(stream, {:data, ~s({"type":"response.failed","response":{"status":"failed"}})})

    assert_receive {^ref, {:preflight, {:fallback, :bridge_failed_before_visible}}}, 2_000
    refute_receive {^ref, {:data, _data}}, 100
  end

  test "a failure-coded incomplete terminal before visible output falls back" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(
      stream,
      {:data,
       Jason.encode!(%{
         "type" => "response.incomplete",
         "response" => %{
           "status" => "incomplete",
           "incomplete_details" => %{"reason" => "context_length_exceeded"}
         }
       })}
    )

    assert_receive {^ref, {:preflight, {:fallback, :bridge_failed_before_visible}}}, 2_000
    refute_receive {^ref, {:data, _data}}, 100
  end

  test "an ordinary incomplete terminal remains downstream-visible" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(
      stream,
      {:data,
       Jason.encode!(%{
         "type" => "response.incomplete",
         "response" => %{
           "status" => "incomplete",
           "incomplete_details" => %{"reason" => "max_output_tokens"}
         }
       })}
    )

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, data}}, 2_000
    assert data =~ "response.incomplete"
    assert_receive {^ref, :done}, 2_000
  end

  test "conservative frames commit without waiting for later output" do
    frames = [
      ~s({"type":"codex.future_event","detail":{}}),
      ~s({"type":"response.future_event","detail":{}}),
      ~s({"detail":{"kind":"future"}}),
      ~s({not-json)
    ]

    Enum.each(frames, fn frame ->
      stream = start_armed(blocking_submit())
      ref = stream.ref
      owner_frame(stream, {:data, frame})

      assert_receive {^ref, {:preflight, :stream}}, 2_000
      assert_receive {^ref, {:data, data}}, 2_000
      assert data == WebsocketBridgeStream.sse_block(frame)
    end)
  end

  test "exact legacy typeless success commits and latches completion" do
    stream = start_armed(blocking_submit(), settle_timeout_ms: 1)
    ref = stream.ref
    frame = ~s({"id":"resp_legacy_success"})

    owner_frame(stream, {:data, frame})

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, data}}, 2_000
    assert data == WebsocketBridgeStream.sse_block(frame)
    assert_receive {^ref, :done}, 2_000
  end

  test "a structural completed frame latches the terminal before close or task settlement" do
    stream = start_armed(registered_submit(self()), settle_timeout_ms: 50)
    ref = stream.ref

    assert_receive {:submit_task, task_pid}, 2_000

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_latched", "status" => "completed"}
      })

    owner_frame(stream, {:data, completed})
    owner_frame(stream, {:error, :upstream_websocket_error, %{}})
    send(task_pid, {:return, {:error, %{reason: :upstream_websocket_error}}})

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, data}}, 2_000
    assert data == WebsocketBridgeStream.sse_block(completed)
    assert_receive {^ref, :done}, 2_000
    refute_received {^ref, {:bridge_error, _reason}}
  end

  test "a completion with no data falls back instead of committing" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(stream, :complete)

    assert_receive {^ref, {:preflight, {:fallback, :bridge_no_first_event}}}, 2_000
    refute_receive {^ref, :done}, 100
  end

  test "an owner error before data falls back with the owner error reason" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(stream, {:error, :owner_busy, %{"status" => 409}})

    assert_receive {^ref, {:preflight, {:fallback, :owner_busy}}}, 2_000
  end

  test "a submit error settling before any frame falls back immediately" do
    stream = start_armed(fn -> {:error, %{reason: :owner_not_running}} end)
    ref = stream.ref

    assert_receive {^ref, {:preflight, {:fallback, :owner_not_running}}}, 2_000
  end

  test "completed bridge hands off connection metadata exactly once" do
    connection = connection_metadata()

    stream =
      start_armed(fn ->
        {:ok, %{upstream_websocket_connection: Map.put(connection, :ignored, "sentinel")}}
      end)

    ref = stream.ref

    owner_frame(
      stream,
      {:data,
       Jason.encode!(%{
         "type" => "response.completed",
         "response" => %{"id" => "resp_metadata", "status" => "completed"}
       })}
    )

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, _data}}, 2_000
    assert_receive {^ref, :done}, 2_000

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: connection,
             transport_failure: nil
           }

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: nil
           }
  end

  test "committed terminal delivery timeout becomes a stream error without fallback" do
    connection = connection_metadata()

    stream =
      start_armed(fn ->
        {:error,
         %{
           reason: :upstream_websocket_terminal_delivery_timeout,
           upstream_websocket_connection: connection,
           transport_failure: %{
             "phase" => "terminal_delivery",
             "reason_class" => "owner_terminal_delivery_timeout",
             "reason" => "upstream_websocket_terminal_delivery_timeout",
             "pre_visible_output" => false,
             "upstream_committed" => true,
             "terminal_seen" => true,
             "terminal_forwarded" => false
           }
         }}
      end)

    ref = stream.ref

    assert_receive {^ref, {:preflight, :stream}}, 2_000

    assert_receive {^ref, {:bridge_error, :upstream_websocket_terminal_delivery_timeout}},
                   2_000

    refute_received {^ref, {:preflight, {:fallback, _reason}}}

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: connection,
             transport_failure: %{
               "phase" => "terminal_delivery",
               "reason_class" => "owner_terminal_delivery_timeout",
               "reason" => "upstream_websocket_terminal_delivery_timeout",
               "pre_visible_output" => false,
               "upstream_committed" => true,
               "terminal_seen" => true,
               "terminal_forwarded" => false
             }
           }
  end

  test "real owner terminal delivery timeout commits before its direct error can trigger fallback" do
    controls = WebsocketOwnerNodeHarness.two_sender_controls()
    terminal_frame = terminal_frame("resp_real_owner_timeout")

    upstream =
      self()
      |> WebsocketOwnerNodeHarness.two_sender_upstream_boundary(controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame)
      )
      |> Map.put(:invalidate, fn _upstream_pid -> :ok end)

    session_id = "bridge-owner-#{System.unique_integer([:positive])}"

    assert {:ok, owner} =
             WebsocketOwnerSession.start_owner(
               codex_session_id: session_id,
               owner_lease_token: "owner-token",
               owner_instance_id: Atom.to_string(node()),
               upstream: upstream,
               persistence: WebsocketOwnerNodeHarness.fake_persistence_boundary()
             )

    on_exit(fn ->
      if Process.alive?(owner), do: GenServer.stop(owner)
    end)

    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    stream = WebsocketBridgeStream.start("real-owner-timeout")

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               %{pid: stream.relay, correlation_id: stream.correlation_id},
               reject_if_busy: true
             )

    :ok =
      WebsocketBridgeStream.arm(stream, downstream.epoch, fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    task_result_barrier = await_controlled_barrier(:task_result, controls)
    nonterminal_barrier = await_controlled_barrier(:nonterminal_frames, controls)
    release_controlled(task_result_barrier, controls, :task_result)

    active_turn = await_pending_terminal_result(owner)
    {submitter_pid, _call_tag} = active_turn.reply_to
    assert :erlang.suspend_process(submitter_pid)
    assert :erlang.trace(stream.relay, true, [:receive]) == 1

    on_exit(fn ->
      if Process.alive?(submitter_pid), do: :erlang.resume_process(submitter_pid)

      try do
        :erlang.trace(stream.relay, false, [:receive])
      rescue
        ArgumentError -> false
      end
    end)

    assert Process.cancel_timer(active_turn.terminal_delivery_timer_ref) != false
    {turn_ref, timer_token} = active_turn.terminal_delivery_timeout
    send(owner, {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token})

    assert %{active_turn: nil} = :sys.get_state(owner)
    relay_pid = stream.relay

    assert_receive {:trace, ^relay_pid, :receive,
                    {:websocket_owner_frame, "real-owner-timeout", 1,
                     {:error, :upstream_websocket_terminal_delivery_timeout, _safe_payload}}},
                   1_000

    assert :erlang.resume_process(submitter_pid)

    ref = stream.ref
    assert_receive {^ref, {:preflight, :stream}}, 2_000

    assert_receive {^ref, {:bridge_error, :upstream_websocket_terminal_delivery_timeout}},
                   2_000

    refute_received {^ref, {:preflight, {:fallback, _reason}}}

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: %{
               "phase" => "terminal_delivery",
               "reason_class" => "owner_terminal_delivery_timeout",
               "reason" => "upstream_websocket_terminal_delivery_timeout",
               "pre_visible_output" => false,
               "upstream_committed" => true,
               "terminal_seen" => true,
               "terminal_forwarded" => false
             }
           }

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: nil
           }

    release_controlled(nonterminal_barrier, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
  end

  test "real owner terminal delivery timeout stays committed when its submit result arrives first" do
    controls = WebsocketOwnerNodeHarness.two_sender_controls()
    terminal_frame = terminal_frame("resp_real_owner_result_first")

    upstream =
      self()
      |> WebsocketOwnerNodeHarness.two_sender_upstream_boundary(controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame)
      )
      |> Map.put(:invalidate, fn _upstream_pid -> :ok end)

    test_pid = self()

    downstream_sender = fn pid, message ->
      case message do
        {:websocket_owner_frame, _correlation_id, _epoch,
         {:error, :upstream_websocket_terminal_delivery_timeout, _safe_payload}} ->
          WebsocketOwnerNodeHarness.controlled_result(
            test_pid,
            controls,
            :downstream_send_result,
            :ok
          )

          send(pid, message)
          :ok

        _message ->
          send(pid, message)
          :ok
      end
    end

    session_id = "bridge-owner-result-first-#{System.unique_integer([:positive])}"

    assert {:ok, owner} =
             WebsocketOwnerSession.start_owner(
               codex_session_id: session_id,
               owner_lease_token: "owner-token",
               owner_instance_id: Atom.to_string(node()),
               upstream: upstream,
               downstream_sender: downstream_sender,
               persistence: WebsocketOwnerNodeHarness.fake_persistence_boundary()
             )

    on_exit(fn ->
      if Process.alive?(owner), do: GenServer.stop(owner)
    end)

    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    stream = WebsocketBridgeStream.start("real-owner-result-first")

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               %{pid: stream.relay, correlation_id: stream.correlation_id},
               reject_if_busy: true
             )

    :ok =
      WebsocketBridgeStream.arm(stream, downstream.epoch, fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    task_result_barrier = await_controlled_barrier(:task_result, controls)
    nonterminal_barrier = await_controlled_barrier(:nonterminal_frames, controls)
    release_controlled(task_result_barrier, controls, :task_result)

    active_turn = await_pending_terminal_result(owner)
    assert Process.cancel_timer(active_turn.terminal_delivery_timer_ref) != false
    {turn_ref, timer_token} = active_turn.terminal_delivery_timeout
    send(owner, {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token})

    downstream_barrier = await_controlled_barrier(:downstream_send_result, controls)

    ref = stream.ref
    assert_receive {^ref, {:preflight, :stream}}, 2_000

    assert_receive {^ref, {:bridge_error, :upstream_websocket_terminal_delivery_timeout}},
                   2_000

    refute_received {^ref, {:preflight, {:fallback, _reason}}}
    release_controlled(downstream_barrier, controls, :downstream_send_result)
    assert %{active_turn: nil} = :sys.get_state(owner)

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: terminal_timeout_metadata()
           }

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: nil
           }

    release_controlled(nonterminal_barrier, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
  end

  test "post-commit receive failure retains only safe attempt diagnostics" do
    connection = connection_metadata()
    stream = start_armed(registered_submit(self()), settle_timeout_ms: 50)
    ref = stream.ref

    assert_receive {:submit_task, task_pid}, 2_000
    owner_frame(stream, {:data, ~s({"type":"response.output_text.delta","delta":"answer"})})
    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, _data}}, 2_000

    send(
      task_pid,
      {:return,
       {:error,
        %{
          reason: :upstream_websocket_closed_before_terminal,
          upstream_websocket_connection: Map.put(connection, :raw_identity, "sentinel-identity"),
          transport_failure: %{
            "exception" => "Mint.TransportError",
            "reason_class" => "Mint.TransportError",
            "reason" => "closed",
            "phase" => "upstream_close",
            "pre_visible_output" => true,
            "upstream_committed" => false,
            "terminal_seen" => false,
            "text_frame_count" => 1,
            "peer_close_code" => 1006,
            "peer_close_reason_present" => true,
            "peer_close_reason_bytes" => 8,
            "raw_frame" => "sentinel-frame",
            "raw_body" => "sentinel-body"
          }
        }}}
    )

    assert_receive {^ref, {:bridge_error, :upstream_websocket_closed_before_terminal}}, 2_000

    metadata = WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream)
    assert metadata.upstream_websocket_connection == connection

    assert metadata.transport_failure == %{
             "exception" => "Mint.TransportError",
             "reason_class" => "Mint.TransportError",
             "reason" => "closed",
             "phase" => "upstream_close",
             "pre_visible_output" => true,
             "upstream_committed" => true,
             "terminal_seen" => false,
             "text_frame_count" => 1,
             "peer_close_code" => 1006,
             "peer_close_reason_present" => true,
             "peer_close_reason_bytes" => 8
           }

    metadata_text = inspect(metadata)
    refute metadata_text =~ "sentinel"
    refute metadata_text =~ "raw_frame"
    refute metadata_text =~ "raw_body"
  end

  test "attempt metadata take returns nil fields after relay death" do
    stream = WebsocketBridgeStream.start("relay-death", settle_timeout_ms: 1)
    monitor_ref = Process.monitor(stream.relay)
    Process.exit(stream.relay, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :killed}, 2_000

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: nil
           }
  end

  test "attempt metadata rejects malformed connection sentinel values" do
    stream =
      start_armed(fn ->
        {:ok,
         %{
           upstream_websocket_connection: %{
             lifecycle_id: "sentinel-identity",
             generation: 0,
             reused: "sentinel-reused",
             reconnected: false
           }
         }}
      end)

    ref = stream.ref

    owner_frame(
      stream,
      {:data,
       Jason.encode!(%{
         "type" => "response.completed",
         "response" => %{"id" => "resp_invalid_metadata", "status" => "completed"}
       })}
    )

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, _data}}, 2_000
    assert_receive {^ref, :done}, 2_000

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: nil
           }
  end

  test "a post-commit task failure fails the stream instead of synthesizing done" do
    stream = start_armed(registered_submit(self()), settle_timeout_ms: 50)
    ref = stream.ref

    assert_receive {:submit_task, task_pid}, 2_000

    owner_frame(stream, {:data, ~s({"type":"response.output_text.delta","delta":"answer"})})
    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, _data}}, 2_000

    # The turn is committed and the submit settles with a failure; no terminal
    # frame ever arrives, so the stream must fail rather than emit :done.
    send(task_pid, {:return, {:error, %{reason: :upstream_websocket_error}}})

    assert_receive {^ref, {:bridge_error, :upstream_websocket_error}}, 2_000
    refute_receive {^ref, :done}, 100
  end

  test "a post-commit successful settle without a terminal frame still closes with done" do
    stream = start_armed(registered_submit(self()), settle_timeout_ms: 50)
    ref = stream.ref

    assert_receive {:submit_task, task_pid}, 2_000

    owner_frame(stream, {:data, ~s({"type":"response.output_text.delta","delta":"answer"})})
    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, _data}}, 2_000

    send(task_pid, {:return, {:ok, %{}}})

    assert_receive {^ref, :done}, 2_000
  end

  test "precommit overflow after submit success retains the successful settlement" do
    stream = start_armed(registered_submit(self()), settle_timeout_ms: 50)
    ref = stream.ref
    relay = stream.relay

    on_exit(fn ->
      try do
        :erlang.trace(relay, false, [:receive])
      rescue
        ArgumentError -> false
      end
    end)

    assert_receive {:submit_task, task_pid}, 2_000
    :erlang.trace(relay, true, [:receive])
    send(task_pid, {:return, {:ok, %{}}})

    assert_receive {:trace, ^relay, :receive, {task_ref, {:ok, %{}}}}, 2_000
    assert is_reference(task_ref)

    Enum.each(1..65, fn sequence ->
      owner_frame(
        stream,
        {:data, Jason.encode!(%{"type" => "response.created", "sequence" => sequence})}
      )
    end)

    assert_receive {^ref, {:preflight, :stream}}, 2_000

    Enum.each(1..65, fn _sequence ->
      assert_receive {^ref, {:data, _data}}, 2_000
    end)

    assert_receive {^ref, :done}, 2_000
    refute_received {^ref, {:bridge_error, _reason}}
  end

  test "precommit frame limit accepts 64 frames and overflows exactly once at 65" do
    attach_overflow_handler(self())

    within_limit = start_armed(blocking_submit(), settle_timeout_ms: 1)
    within_ref = within_limit.ref

    Enum.each(1..64, fn sequence ->
      owner_frame(
        within_limit,
        {:data, Jason.encode!(%{"type" => "response.created", "sequence" => sequence})}
      )
    end)

    owner_frame(within_limit, :complete)

    assert_receive {^within_ref, {:preflight, {:fallback, :bridge_no_first_event}}}, 2_000
    refute_received {:overflow, _event, _measurements, _metadata}

    over_limit = start_armed(blocking_submit(), settle_timeout_ms: 1)
    over_ref = over_limit.ref

    Enum.each(1..65, fn sequence ->
      owner_frame(
        over_limit,
        {:data, Jason.encode!(%{"type" => "response.created", "sequence" => sequence})}
      )
    end)

    assert_receive {^over_ref, {:preflight, :stream}}, 2_000

    Enum.each(1..65, fn _sequence ->
      assert_receive {^over_ref, {:data, _data}}, 2_000
    end)

    assert_receive {:overflow, [:codex_pooler, :gateway, :websocket_bridge, :precommit_overflow],
                    %{count: 1, frames: 65}, %{max_frames: 64, max_bytes: 1_048_576}},
                   2_000

    owner_frame(over_limit, :complete)
    assert_receive {^over_ref, :done}, 2_000
    refute_received {:overflow, _event, _measurements, _metadata}
  end

  test "precommit byte limit accepts limit minus one and limit, then overflows once above it" do
    attach_overflow_handler(self())

    Enum.each([1_048_575, 1_048_576], fn bytes ->
      stream = start_armed(blocking_submit(), settle_timeout_ms: 1)
      ref = stream.ref

      owner_frame(stream, {:data, lifecycle_frame(bytes)})
      owner_frame(stream, :complete)

      assert_receive {^ref, {:preflight, {:fallback, :bridge_no_first_event}}}, 2_000
      refute_received {:overflow, _event, _measurements, _metadata}
    end)

    stream = start_armed(blocking_submit(), settle_timeout_ms: 1)
    ref = stream.ref
    owner_frame(stream, {:data, lifecycle_frame(1_048_577)})

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, _data}}, 2_000

    assert_receive {:overflow, [:codex_pooler, :gateway, :websocket_bridge, :precommit_overflow],
                    %{bytes: 1_048_577, count: 1, frames: 1},
                    %{max_bytes: 1_048_576, max_frames: 64}},
                   2_000

    owner_frame(stream, :complete)
    assert_receive {^ref, :done}, 2_000
    refute_received {:overflow, _event, _measurements, _metadata}
  end

  defp await_controlled_barrier(stage, controls) do
    release_ref = Map.fetch!(controls, stage)

    assert_receive {:websocket_owner_harness_controlled_barrier, ^stage, barrier_pid,
                    ^release_ref},
                   1_000

    barrier_pid
  end

  defp release_controlled(barrier_pid, controls, stage) do
    WebsocketOwnerNodeHarness.release_controlled(barrier_pid, controls, stage)
  end

  defp await_pending_terminal_result(owner, attempts \\ 100)

  defp await_pending_terminal_result(owner, attempts) when attempts > 0 do
    case :sys.get_state(owner) do
      %{active_turn: %{pending_result: pending_result} = active_turn}
      when not is_nil(pending_result) ->
        active_turn

      _state ->
        :erlang.yield()
        await_pending_terminal_result(owner, attempts - 1)
    end
  end

  defp await_pending_terminal_result(_owner, 0), do: flunk("owner never retained terminal result")

  defp websocket_request do
    %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "request-frame",
      timeouts: %{},
      writer: fn _frame -> :ok end
    }
  end

  defp terminal_frame(response_id) do
    Jason.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => response_id, "status" => "completed"}
    })
  end

  defp terminal_result(terminal_frame) do
    {:ok,
     %{
       body: "data: #{terminal_frame}\n\n",
       terminal: "response.completed",
       status: 200,
       headers: [],
       websocket_frame_headers: %{}
     }}
  end

  defp terminal_timeout_metadata do
    %{
      "phase" => "terminal_delivery",
      "reason_class" => "owner_terminal_delivery_timeout",
      "reason" => "upstream_websocket_terminal_delivery_timeout",
      "pre_visible_output" => false,
      "upstream_committed" => true,
      "terminal_seen" => true,
      "terminal_forwarded" => false
    }
  end
end
