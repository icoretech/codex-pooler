defmodule CodexPooler.Gateway.Websocket.DirectCleanupRegistryTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Websocket.DirectCleanup

  test "cancellation before claim fences later mutation" do
    {context, task} = coordinator()
    assert :none = ActivityRegistry.await_direct_cleanup(context)
    send(task, {:begin, self()})
    assert_receive {:began, {:error, :cancelled}}
    send(task, :stop)
  end

  test "cancellation waits committed identity publication and prevents dispatch" do
    {context, task} = coordinator()
    send(task, {:begin, self()})
    assert_receive {:began, :ok}
    waiter = Task.async(fn -> ActivityRegistry.await_direct_cleanup(context) end)
    :sys.get_state(context.registry)
    assert Task.yield(waiter, 0) == nil
    receipt = receipt(context)
    send(task, {:bind, receipt, self()})
    assert_receive :bound
    assert_receive {:direct_request_cleanup, ^task, _, ^receipt}
    assert Task.yield(waiter, 0) == nil
    send(task, {:ready, self()})
    assert_receive {:ready_result, {:error, :cancelled}}
    assert {:ok, ^receipt} = Task.await(waiter)
    send(task, :stop)
  end

  test "coordinator death preserves exact bound identity and releases pending waiter" do
    {context, task} = coordinator()
    send(task, {:begin, self()})
    assert_receive {:began, :ok}
    receipt = receipt(context)
    send(task, {:bind, receipt, self()})
    assert_receive :bound
    waiter = Task.async(fn -> ActivityRegistry.await_direct_cleanup(context) end)
    Process.exit(task, :kill)
    assert {:ok, ^receipt} = Task.await(waiter)
    assert {:ok, ^receipt} = ActivityRegistry.await_direct_cleanup(context)
    assert :none = ActivityRegistry.await_direct_cleanup(context)
  end

  test "forged task reference cannot cancel or publish another task" do
    {context, task} = coordinator()
    forged = %{context | ref: make_ref()}
    assert :none = ActivityRegistry.await_direct_cleanup(forged)
    assert :ok = ActivityRegistry.bind_direct_cleanup(forged, receipt(context))
    send(task, {:begin, self()})
    assert_receive {:began, :ok}
    send(task, :stop)
  end

  test "finished receipt rejects a forged context without erasing its authority" do
    {context, task} = coordinator()
    send(task, {:begin, self()})
    assert_receive {:began, :ok}
    expected = receipt(context)
    send(task, {:bind, expected, self()})
    assert_receive :bound
    monitor = Process.monitor(task)
    send(task, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}

    assert :none =
             ActivityRegistry.await_direct_cleanup(%{context | session_id: Ecto.UUID.generate()})

    assert {:ok, ^expected} = ActivityRegistry.await_direct_cleanup(context)
    assert :sys.get_state(context.registry).finished_direct == %{}
  end

  test "finished receipt is removed when its socket parent exits" do
    parent =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {context, task} = coordinator(parent)
    send(task, {:begin, self()})
    assert_receive {:began, :ok}
    send(task, {:bind, receipt(context), self()})
    assert_receive :bound
    monitor = Process.monitor(task)
    send(task, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
    registry_state = :sys.get_state(context.registry)
    assert Map.has_key?(registry_state.finished_direct, context.ref)
    parent_monitor = Process.monitor(parent)
    send(parent, :stop)
    assert_receive {:DOWN, ^parent_monitor, :process, ^parent, :normal}
    await_empty_archive(context.registry, System.monotonic_time(:millisecond) + 15_000)
    assert ActivityRegistry.await_direct_cleanup(context) == :none
  end

  defp coordinator(parent \\ self()) do
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({ActivityRegistry, name: name})
    starter = self()
    ref = make_ref()

    task =
      spawn(fn ->
        {:ok, token} =
          ActivityRegistry.register(:direct, self(),
            name: name,
            direct_cleanup_ref: ref,
            direct_cleanup_parent: parent
          )

        :ok = ActivityRegistry.admit(token, name: name)

        context = %DirectCleanup{
          registry: name,
          task: self(),
          ref: ref,
          parent: parent,
          session_id: Ecto.UUID.generate()
        }

        send(starter, {:coordinator, context})
        loop(context)
      end)

    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert_receive {:coordinator, context}
    {context, task}
  end

  defp loop(context) do
    receive do
      {:begin, parent} ->
        send(parent, {:began, ActivityRegistry.begin_direct_cleanup(context)})
        loop(context)

      {:bind, receipt, parent} ->
        :ok = ActivityRegistry.bind_direct_cleanup(context, receipt)
        send(parent, :bound)
        loop(context)

      {:ready, parent} ->
        send(parent, {:ready_result, ActivityRegistry.ready_direct_cleanup(context)})
        loop(context)

      :stop ->
        :ok
    end
  end

  defp receipt(context),
    do: %{
      session_id: context.session_id,
      request_id: Ecto.UUID.generate(),
      correlation_id: Ecto.UUID.generate(),
      api_key_id: Ecto.UUID.generate()
    }

  defp await_empty_archive(registry, deadline) do
    if :sys.get_state(registry).finished_direct != %{} do
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        10 -> await_empty_archive(registry, deadline)
      end
    end
  end
end
