defmodule CodexPooler.Gateway.Transports.Streaming.DeferredStreamDrainTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistry
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, RolloutDrain}

  # The drain's own budget is the behavior under test; these waits only detect
  # failure and stay well above it.
  @drain_timeout_ms 2_000
  @await_timeout_ms 15_000
  # Left at the default, `RolloutDrain` reserves a full owner call budget before
  # the poll deadline and a test-sized budget collapses to the deadline floor.
  # Production's 85 s budget absorbs that margin; these tests reserve a small
  # one so the drain's own wait is what the test measures.
  @drain_options [deadline_margin_ms: 100, deadline_floor_ms: 50]

  setup do
    stream_registry = :"deferred-stream-registry-#{System.unique_integer([:positive])}"
    activity_registry = :"rollout-drain-activity-#{System.unique_integer([:positive])}"
    drain_name = :"rollout-drain-#{System.unique_integer([:positive])}"

    start_supervised!({DeferredStreamRegistry, name: stream_registry})
    start_supervised!({ActivityRegistry, name: activity_registry})

    start_supervised!(
      Supervisor.child_spec(
        {RolloutDrain,
         [
           name: drain_name,
           activity_registry: activity_registry,
           stream_registry: stream_registry
         ]},
        id: {RolloutDrain, drain_name}
      )
    )

    {:ok, drain_name: drain_name, stream_registry: stream_registry}
  end

  test "a drained deferred stream is signalled and counted once it settles", %{
    drain_name: drain_name,
    stream_registry: stream_registry
  } do
    parent = self()

    stream =
      spawn(fn ->
        token =
          DeferredStreamRegistry.register(%{request_id: "request", attempt_id: "attempt"},
            name: stream_registry
          )

        send(parent, {:stream_registered, token})

        receive do
          {:gateway_stream_drain, ^token, :owner_drained} ->
            send(parent, {:stream_drained, token})
            DeferredStreamRegistry.finish(token, :completed, name: stream_registry)
        end
      end)

    assert_receive {:stream_registered, token}, @await_timeout_ms
    monitor = Process.monitor(stream)

    assert %{
             result: :ok,
             http_streams_seen: 1,
             http_streams_completed: 1,
             http_streams_aborted: 0,
             http_streams_failed: 0
           } = RolloutDrain.start_drain(drain_options(drain_name))

    assert_received {:stream_drained, ^token}
    assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}, @await_timeout_ms
  end

  test "a stream that ignores the signal is aborted and the drain still returns in budget", %{
    drain_name: drain_name,
    stream_registry: stream_registry
  } do
    parent = self()

    stream =
      spawn(fn ->
        token =
          DeferredStreamRegistry.register(%{request_id: "request", attempt_id: "attempt"},
            name: stream_registry
          )

        send(parent, {:stream_registered, token})

        # Never consumes the drain signal: the drain must give the budget back
        # rather than wait on it, and must not kill the connection process.
        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:stream_registered, _token}, @await_timeout_ms

    assert %{
             result: :ok,
             http_streams_seen: 1,
             http_streams_completed: 0,
             http_streams_aborted: 1,
             http_streams_failed: 0,
             elapsed_ms: elapsed_ms
           } = RolloutDrain.start_drain(drain_options(drain_name))

    # The unresponsive stream must not hold the drain past its own budget.
    assert elapsed_ms <= @drain_timeout_ms + 1_000
    assert Process.alive?(stream)
    send(stream, :stop)
  end

  test "a stream that settled before the drain contributes no new work", %{
    drain_name: drain_name,
    stream_registry: stream_registry
  } do
    token =
      DeferredStreamRegistry.register(%{request_id: "request", attempt_id: "attempt"},
        name: stream_registry
      )

    :ok = DeferredStreamRegistry.finish(token, :completed, name: stream_registry)

    assert %{
             result: :ok,
             http_streams_seen: 0,
             http_streams_completed: 0,
             http_streams_aborted: 0,
             http_streams_failed: 0
           } = RolloutDrain.start_drain(drain_options(drain_name))
  end

  defp drain_options(drain_name) do
    [name: drain_name, timeout_ms: @drain_timeout_ms] ++ @drain_options
  end

  test "websocket owner drain counters are unchanged by deferred stream draining", %{
    drain_name: drain_name
  } do
    assert %{
             result: :ok,
             owners_seen: 0,
             owners_drained: 0,
             turns_completed: 0,
             turns_aborted: 0,
             direct_turns_seen: 0,
             proxy_turns_seen: 0,
             http_streams_seen: 0
           } = RolloutDrain.start_drain(drain_options(drain_name))
  end
end
