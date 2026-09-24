defmodule CodexPoolerWeb.WebsocketControlPathCleanupLatencyTest do
  # How long the closed socket's detach took is what a released client's retry,
  # about 200 ms after the failure, meets (findings#206 row 206-436): a cleanup
  # that outlives the socket's 100 ms wait logs its duration when it finishes,
  # under the socket's request id. Not async: it raises the Logger level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias CodexPoolerWeb.WebsocketControlPath

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  test "a cleanup that outlives the wait logs its duration under the socket's request id when it finishes" do
    parent = self()
    request_id = "cleanup-latency-#{System.unique_integer([:positive])}"

    logs =
      capture_log([level: :info], fn ->
        spawn(fn ->
          Logger.metadata(request_id: request_id)

          WebsocketControlPath.cleanup(fn ->
            send(parent, {:cleanup_started, self()})

            receive do
              :release -> :ok
            end
          end)

          send(parent, :socket_can_close)
        end)

        assert_receive {:cleanup_started, cleanup}, 5_000
        assert_receive :socket_can_close, 5_000
        monitor = Process.monitor(cleanup)
        send(cleanup, :release)
        assert_receive {:DOWN, ^monitor, :process, ^cleanup, _reason}, 5_000
      end)

    assert logs =~ ~r/request_id=#{request_id} \[warning\] websocket control path failed phase=terminate reason=cleanup_deferred/
    assert logs =~ ~r/request_id=#{request_id} \[info\] websocket control path deferred cleanup finished elapsed_ms=\d+/
  end

  test "a cleanup that finishes inside the wait logs nothing more" do
    request_id = "cleanup-latency-#{System.unique_integer([:positive])}"

    logs =
      capture_log([level: :info], fn ->
        Logger.metadata(request_id: request_id)
        assert :ok = WebsocketControlPath.cleanup(fn -> :ok end)
      end)

    refute logs =~ "deferred cleanup finished"
  end
end
