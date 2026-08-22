defmodule CodexPooler.Gateway.Websocket.ResponseTaskTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Websocket.ResponseTask

  setup do
    registry = :"websocket-response-task-registry-#{System.unique_integer([:positive])}"
    start_supervised!({ActivityRegistry, name: registry})
    {:ok, registry: registry}
  end

  test "registers and gates before invoking upstream work", %{registry: registry} do
    parent = self()

    {:ok, pid} =
      ResponseTask.start(
        parent,
        :direct,
        fn task_pid ->
          send(parent, {:upstream_started, task_pid, ActivityRegistry.activities(name: registry)})
          :ok
        end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry
      )

    assert_receive {:upstream_started, ^pid, [%{kind: :direct, pid: ^pid, status: :admitted}]}
    monitor = Process.monitor(pid)
    assert_receive {:websocket_response_activity, ^pid, token}
    assert_receive {:codex_response_done, ^pid, :ok}
    assert {:active, :admitted} = ActivityRegistry.status(token, name: registry)
    assert :ok = ResponseTask.acknowledge_delivery(pid, token)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert ActivityRegistry.activities(name: registry) == []
  end

  test "admitted proxy dispatch runs in the registered response task before delivery ack", %{
    registry: registry
  } do
    parent = self()

    {:ok, pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn task_pid ->
          send(parent, {:proxy_dispatch_started, self(), task_pid})
          :ok
        end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry
      )

    monitor = Process.monitor(pid)
    assert_receive {:proxy_dispatch_started, ^pid, ^pid}
    assert_receive {:websocket_response_activity, ^pid, token}
    assert_receive {:codex_response_done, ^pid, :ok}
    assert Process.alive?(pid)
    assert :ok = ResponseTask.acknowledge_delivery(pid, token)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "queued or new work after cutoff returns owner_drained without upstream work", %{
    registry: registry
  } do
    assert {_epoch, []} = ActivityRegistry.begin_drain(name: registry)
    parent = self()

    {:ok, pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid ->
          send(parent, :forbidden_upstream_dispatch)
          :ok
        end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry
      )

    assert_receive {:codex_response_done, ^pid, {:error, :owner_drained}}
    refute_received :forbidden_upstream_dispatch
  end

  test "deadline cancellation invokes the reason-preserving cleanup once and reports owner_drained",
       %{
         registry: registry
       } do
    parent = self()

    {:ok, pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid ->
          send(parent, :proxy_upstream_started)

          receive do
            :release_proxy_work -> :ok
          end
        end,
        fn task_pid, reason -> send(parent, {:proxy_cancelled, task_pid, reason}) end,
        activity_registry: registry
      )

    assert_receive :proxy_upstream_started
    assert {_epoch, [%{token: token, pid: ^pid}]} = ActivityRegistry.begin_drain(name: registry)
    monitor = Process.monitor(pid)
    assert :ok = ActivityRegistry.cancel(token, :owner_drained, name: registry)
    assert_receive {:proxy_cancelled, ^pid, :owner_drained}
    assert_receive {:websocket_response_activity, ^pid, ^token}

    assert_receive {:websocket_response_activity_cancelled, ^pid, ^token, ack_pid, :owner_drained}

    assert :ok = ResponseTask.acknowledge_delivery(ack_pid, token)
    assert_receive {:codex_response_done, ^pid, {:error, :owner_drained}}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:finished, :aborted} = ActivityRegistry.status(token, name: registry)
    refute_received {:proxy_cancelled, ^pid, :owner_drained}
    refute_received {:codex_response_done, ^pid, {:error, :owner_drained}}
  end

  test "cancellation accepted before completion handoff cannot be lost to the old watcher", %{
    registry: registry
  } do
    parent = self()

    {:ok, pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid -> :ok end,
        fn task_pid, reason -> send(parent, {:handoff_cancelled, task_pid, reason}) end,
        activity_registry: registry,
        before_completion_handoff: fn token, watcher ->
          send(parent, {:before_completion_handoff, self(), token, watcher})

          receive do
            :release_completion_handoff -> :ok
          end
        end
      )

    monitor = Process.monitor(pid)
    assert_receive {:before_completion_handoff, ^pid, token, watcher}
    watcher_monitor = Process.monitor(watcher)
    assert {_epoch, [%{token: ^token, pid: ^pid}]} = ActivityRegistry.begin_drain(name: registry)
    assert :ok = ActivityRegistry.cancel(token, :owner_drained, name: registry)
    assert_receive {:handoff_cancelled, ^pid, :owner_drained}
    send(pid, :release_completion_handoff)

    assert_receive {:websocket_response_activity, ^pid, ^token}

    assert_receive {:websocket_response_activity_cancelled, ^pid, ^token, ^watcher,
                    :owner_drained}

    assert :ok = ResponseTask.acknowledge_delivery(watcher, token)
    assert_receive {:codex_response_done, ^pid, {:error, :owner_drained}}
    assert_receive {:DOWN, ^watcher_monitor, :process, ^watcher, :normal}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:finished, :aborted} = ActivityRegistry.status(token, name: registry)
    refute_received {:codex_response_done, ^pid, :ok}
    refute_received {:handoff_cancelled, ^pid, :owner_drained}
    assert ActivityRegistry.activities(name: registry) == []
  end

  test "untracked local-owner work is not double-counted", %{registry: registry} do
    parent = self()

    {:ok, pid} =
      ResponseTask.start(
        parent,
        :local_owner,
        fn _task_pid -> :ok end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry
      )

    assert_receive {:codex_response_done, ^pid, :ok}
    assert {_epoch, []} = ActivityRegistry.begin_drain(name: registry)
  end
end
