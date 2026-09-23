defmodule CodexPoolerWeb.WebsocketDownstreamWriteWatchTest do
  # The failed-write signal behind the websocket delivery receipt (findings#232
  # row 232-256): ThousandIsland reports a failed write as
  # `[:thousand_island, :connection, :send_error]` in the connection process,
  # and the application-attached handler keeps the first failure of a watched
  # process only. Each case runs in its own process, as a connection does.
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Websocket.DeliveryReceipt
  alias CodexPoolerWeb.WebsocketDownstreamWriteWatch

  @event [:thousand_island, :connection, :send_error]

  test "the application attaches the handler" do
    assert Enum.any?(:telemetry.list_handlers(@event), &(&1.id == {WebsocketDownstreamWriteWatch, :send_error}))
  end

  test "a process that is not watched records nothing" do
    assert in_process(fn ->
             send_error(:timeout)
             WebsocketDownstreamWriteWatch.failure()
           end) == nil
  end

  test "a watched connection keeps the class of its first failed write" do
    assert in_process(fn ->
             :ok = WebsocketDownstreamWriteWatch.watch()
             send_error(:timeout)
             send_error(:closed)
             WebsocketDownstreamWriteWatch.failure()
           end) == "timeout"

    assert in_process(fn ->
             :ok = WebsocketDownstreamWriteWatch.watch()
             send_error(:closed)
             WebsocketDownstreamWriteWatch.failure()
           end) == "closed"

    assert in_process(fn ->
             :ok = WebsocketDownstreamWriteWatch.watch()
             send_error(:econnreset)
             WebsocketDownstreamWriteWatch.failure()
           end) == "other"
  end

  # The client-retry window of a turn cut by the failure starts when it was
  # reported (findings#232 row 232-261), so a later failure must not move it.
  test "a watched connection keeps when its first failed write was reported" do
    {before_failure, failed_at, after_second} =
      in_process(fn ->
        :ok = WebsocketDownstreamWriteWatch.watch()
        nil = WebsocketDownstreamWriteWatch.failed_at()
        before_failure = DateTime.utc_now()
        send_error(:timeout)
        failed_at = WebsocketDownstreamWriteWatch.failed_at()
        Process.sleep(2)
        send_error(:closed)
        {before_failure, failed_at, WebsocketDownstreamWriteWatch.failed_at()}
      end)

    assert %DateTime{} = failed_at
    assert DateTime.compare(failed_at, before_failure) in [:eq, :gt]
    assert after_second == failed_at

    assert in_process(fn ->
             send_error(:timeout)
             WebsocketDownstreamWriteWatch.failed_at()
           end) == nil
  end

  test "every class it records is in the receipt's write_failure vocabulary" do
    assert WebsocketDownstreamWriteWatch.failures() == DeliveryReceipt.write_failures()

    for error <- [:timeout, :closed, :enotconn, :epipe] do
      assert in_process(fn ->
               :ok = WebsocketDownstreamWriteWatch.watch()
               send_error(error)
               WebsocketDownstreamWriteWatch.failure()
             end) in DeliveryReceipt.write_failures()
    end
  end

  test "confirmed evidence stops moving at the first failed write" do
    assert in_process(fn ->
             :ok = WebsocketDownstreamWriteWatch.watch()
             :ok = WebsocketDownstreamWriteWatch.confirm(:before)
             send_error(:timeout)
             :ok = WebsocketDownstreamWriteWatch.confirm(:after)
             WebsocketDownstreamWriteWatch.confirmed()
           end) == :before
  end

  test "a failed write's frame data never reaches the recorded failure" do
    assert in_process(fn ->
             :ok = WebsocketDownstreamWriteWatch.watch()
             :telemetry.execute(@event, %{data: "synthetic frame bytes", error: {:synthetic, "synthetic frame bytes"}}, %{})
             WebsocketDownstreamWriteWatch.failure()
           end) == "other"
  end

  defp send_error(reason), do: :telemetry.execute(@event, %{data: "synthetic frame bytes", error: reason, monotonic_time: 0}, %{})

  defp in_process(fun) do
    task = Task.async(fun)
    Task.await(task)
  end
end
