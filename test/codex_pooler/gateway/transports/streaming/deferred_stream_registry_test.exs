defmodule CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistryTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistry

  @receive_timeout 5_000

  setup do
    name = :"deferred-stream-registry-#{System.unique_integer([:positive])}"
    start_supervised!({DeferredStreamRegistry, name: name})
    {:ok, registry: name}
  end

  test "a registered stream joins the drain snapshot with its request and attempt ids", %{
    registry: registry
  } do
    parent = self()
    request_id = Ecto.UUID.generate()
    attempt_id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        token =
          DeferredStreamRegistry.register(%{request_id: request_id, attempt_id: attempt_id},
            name: registry
          )

        send(parent, {:registered, self(), token})

        receive do
          {:gateway_stream_drain, ^token, reason} ->
            DeferredStreamRegistry.finish(token, :completed, name: registry)
            reason
        end
      end)

    assert_receive {:registered, stream_pid, token}, @receive_timeout

    assert {epoch,
            [
              %{
                token: ^token,
                pid: ^stream_pid,
                request_id: ^request_id,
                attempt_id: ^attempt_id,
                status: :active
              }
            ]} = DeferredStreamRegistry.begin_drain(name: registry)

    assert :ok = DeferredStreamRegistry.interrupt(token, :owner_drained, name: registry)
    assert Task.await(task, @receive_timeout) == :owner_drained
    assert {:finished, :completed} = DeferredStreamRegistry.status(token, name: registry)
    assert :ok = DeferredStreamRegistry.complete_drain(epoch, name: registry)
  end

  test "a stream registering after the cutoff is signalled immediately", %{registry: registry} do
    assert {epoch, []} = DeferredStreamRegistry.begin_drain(name: registry)

    token = DeferredStreamRegistry.register(%{request_id: nil, attempt_id: nil}, name: registry)

    assert_receive {:gateway_stream_drain, ^token, :owner_drained}, @receive_timeout
    assert :ok = DeferredStreamRegistry.finish(token, :completed, name: registry)
    assert :ok = DeferredStreamRegistry.complete_drain(epoch, name: registry)
  end

  test "registration is refcounted so a nested retry stream keeps one token", %{
    registry: registry
  } do
    first =
      DeferredStreamRegistry.register(%{request_id: "request", attempt_id: "first"},
        name: registry
      )

    second =
      DeferredStreamRegistry.register(%{request_id: "request", attempt_id: "second"},
        name: registry
      )

    assert second == first

    assert [%{token: ^first, attempt_id: "second"}] =
             DeferredStreamRegistry.streams(name: registry)

    assert :ok = DeferredStreamRegistry.finish(first, :completed, name: registry)
    assert [%{token: ^first}] = DeferredStreamRegistry.streams(name: registry)

    assert :ok = DeferredStreamRegistry.finish(first, :completed, name: registry)
    assert DeferredStreamRegistry.streams(name: registry) == []
  end

  test "a stream process that dies without finishing is recorded as failed", %{
    registry: registry
  } do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        token =
          DeferredStreamRegistry.register(%{request_id: nil, attempt_id: nil}, name: registry)

        send(parent, {:registered, token})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, token}, @receive_timeout

    assert {epoch, [%{token: ^token, status: :active}]} =
             DeferredStreamRegistry.begin_drain(name: registry)

    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @receive_timeout

    # The registry observes the exit through its own monitor, so read the
    # status through a synchronous call rather than racing the DOWN delivery.
    assert {:finished, :failed} = eventually_finished(registry, token)
    assert :ok = DeferredStreamRegistry.complete_drain(epoch, name: registry)
  end

  test "register returns nil when no registry is running so streams never fail on bookkeeping" do
    assert DeferredStreamRegistry.register(%{request_id: nil, attempt_id: nil},
             name: :deferred_stream_registry_not_started
           ) == nil

    assert DeferredStreamRegistry.finish(nil, :completed,
             name: :deferred_stream_registry_not_started
           ) == :ok
  end

  defp eventually_finished(registry, token, attempts_left \\ 100)

  defp eventually_finished(_registry, _token, 0), do: flunk("stream never finished")

  defp eventually_finished(registry, token, attempts_left) do
    case DeferredStreamRegistry.status(token, name: registry) do
      {:finished, _outcome} = finished -> finished
      _pending -> eventually_finished(registry, token, attempts_left - 1)
    end
  end
end
