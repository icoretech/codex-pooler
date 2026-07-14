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
    owner_frame(stream, {:data, ~s({"type":"response.created"})})
    owner_frame(stream, :complete)

    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, data}}, 2_000
    assert data =~ "response.created"
    assert_receive {^ref, :done}, 2_000
  end

  test "internal codex events buffer until a visible event commits the stream" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

    owner_frame(stream, {:data, ~s({"type":"codex.rate_limits","rate_limits":{}})})
    owner_frame(stream, {:data, ~s({"type":"response.created"})})
    owner_frame(stream, :complete)

    assert_receive {^ref, {:preflight, :stream}}, 2_000

    # The buffered internal frame is flushed first so rate-limit accounting
    # still sees it, then the committing visible event, then the terminal.
    assert_receive {^ref, {:data, first}}, 2_000
    assert first =~ "codex.rate_limits"
    assert_receive {^ref, {:data, second}}, 2_000
    assert second =~ "response.created"
    assert_receive {^ref, :done}, 2_000
  end

  test "internal-only frames followed by completion fall back without committing" do
    stream = start_armed(blocking_submit())
    ref = stream.ref

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

    owner_frame(stream, {:data, ~s({"type":"response.created"})})
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

    owner_frame(stream, {:data, ~s({"type":"response.created"})})
    assert_receive {^ref, {:preflight, :stream}}, 2_000
    assert_receive {^ref, {:data, _data}}, 2_000

    send(task_pid, {:return, {:ok, %{}}})

    assert_receive {^ref, :done}, 2_000
  end
end
