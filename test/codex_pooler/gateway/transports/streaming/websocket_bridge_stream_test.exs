defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStreamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream

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
end
