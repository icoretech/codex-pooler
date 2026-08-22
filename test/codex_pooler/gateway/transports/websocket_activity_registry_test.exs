defmodule CodexPooler.Gateway.Transports.Websocket.ActivityRegistryTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry

  setup do
    name = :"websocket-activity-registry-#{System.unique_integer([:positive])}"
    start_supervised!({ActivityRegistry, name: name})
    {:ok, registry: name}
  end

  test "register-before-gate activity is included when cutoff wins the admission race", %{
    registry: registry
  } do
    parent = self()

    task =
      Task.async(fn ->
        {:ok, token} = ActivityRegistry.register(:direct, self(), name: registry)
        send(parent, {:activity_registered, self(), token})

        receive do
          :gate -> :ok
        end

        result = ActivityRegistry.admit(token, name: registry)
        :ok = ActivityRegistry.unregister(token, :aborted, name: registry)
        result
      end)

    assert_receive {:activity_registered, task_pid, token}

    assert {epoch, [%{kind: :direct, pid: ^task_pid, token: ^token}]} =
             ActivityRegistry.begin_drain(name: registry)

    send(task.pid, :gate)
    assert Task.await(task) == {:error, :owner_drained}
    assert {:finished, :aborted} = ActivityRegistry.status(token, name: registry)
    assert :ok = ActivityRegistry.complete_drain(epoch, name: registry)
  end

  test "post-cutoff activity is rejected synchronously and never joins the drain snapshot", %{
    registry: registry
  } do
    assert {epoch, []} = ActivityRegistry.begin_drain(name: registry)
    assert {:ok, token} = ActivityRegistry.register(:proxy, self(), name: registry)
    assert {:error, :owner_drained} = ActivityRegistry.admit(token, name: registry)
    assert :ok = ActivityRegistry.unregister(token, :aborted, name: registry)
    assert :unknown = ActivityRegistry.status(token, name: registry)
    assert :ok = ActivityRegistry.complete_drain(epoch, name: registry)
  end

  test "active entries remain enumerable when the rollout coordinator restarts", %{
    registry: registry
  } do
    assert {:ok, token} = ActivityRegistry.register(:proxy, self(), name: registry)
    assert :ok = ActivityRegistry.admit(token, name: registry)

    assert {epoch, [%{token: ^token, status: :active}]} =
             ActivityRegistry.begin_drain(name: registry)

    assert {^epoch, [%{token: ^token, status: :active}]} =
             ActivityRegistry.begin_drain(name: registry)

    assert :ok = ActivityRegistry.unregister(token, :completed, name: registry)

    assert {^epoch, [%{token: ^token, status: {:finished, :completed}}]} =
             ActivityRegistry.begin_drain(name: registry)
  end

  test "task crashes are cleaned up and retained as failed drain outcomes", %{registry: registry} do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, token} = ActivityRegistry.register(:direct, self(), name: registry)
        :ok = ActivityRegistry.admit(token, name: registry)
        send(parent, {:activity_ready, self(), token})

        receive do
          :crash -> exit(:synthetic_activity_crash)
        end
      end)

    assert_receive {:activity_ready, ^pid, token}
    assert {_epoch, [%{token: ^token}]} = ActivityRegistry.begin_drain(name: registry)
    monitor = Process.monitor(pid)
    send(pid, :crash)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :synthetic_activity_crash}
    assert {:finished, :failed} = ActivityRegistry.status(token, name: registry)
  end

  test "deadline cancellation and unregister are idempotent", %{registry: registry} do
    assert {:ok, token} = ActivityRegistry.register(:direct, self(), name: registry)
    assert :ok = ActivityRegistry.admit(token, name: registry)
    assert {_epoch, [%{token: ^token}]} = ActivityRegistry.begin_drain(name: registry)

    assert :ok = ActivityRegistry.cancel(token, :owner_drained, name: registry)
    assert_receive {:websocket_activity_cancel, ^token, :owner_drained}
    assert :ok = ActivityRegistry.cancel(token, :owner_drained, name: registry)
    refute_received {:websocket_activity_cancel, ^token, :owner_drained}

    assert :ok = ActivityRegistry.unregister(token, :completed, name: registry)
    assert :ok = ActivityRegistry.unregister(token, :completed, name: registry)
    assert {:finished, :aborted} = ActivityRegistry.status(token, name: registry)
  end
end
