defmodule CodexPooler.Gateway.Websocket.DownstreamSessionMessageTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Websocket.DownstreamSession

  test "accepts the exact native per-call task when other tasks are tracked" do
    owner_turn_id = self()
    other_task = task_pid()
    state = state_with_tasks([owner_turn_id, other_task])

    assert DownstreamSession.accept_downstream_message(
             frame(owner_turn_id, {:data, "terminal"}),
             state
           ) == {:ok, {:data, "terminal"}}

    assert DownstreamSession.accept_downstream_message(frame(owner_turn_id, :complete), state) ==
             {:ok, :complete}

    stop_task(other_task)
  end

  test "rejects a stale native per-call task while another task is tracked" do
    tracked_task = self()
    stale_task = task_pid()

    assert DownstreamSession.accept_downstream_message(
             frame(stale_task, {:data, "stale"}),
             state_with_tasks([tracked_task])
           ) == :drop

    stop_task(stale_task)
  end

  test "rejects a native per-call task that is no longer tracked" do
    owner_turn_id = self()

    assert DownstreamSession.accept_downstream_message(
             frame(owner_turn_id, :complete),
             state_with_tasks([])
           ) == :drop
  end

  test "accepts only the bound carried task for an active reconnect" do
    owner_turn_id = self()
    stale_task = task_pid()

    state =
      state_with_tasks([])
      |> Map.put(:websocket_owner_active_turn_reconnect?, true)
      |> Map.put(:websocket_owner_reconnect_turn_pid, owner_turn_id)

    assert DownstreamSession.accept_downstream_message(frame(owner_turn_id, :complete), state) ==
             {:ok, :complete}

    assert DownstreamSession.accept_downstream_message(frame(stale_task, :complete), state) ==
             :drop

    stop_task(stale_task)
  end

  defp state_with_tasks(tasks) do
    %{
      tasks: MapSet.new(tasks),
      websocket_owner_downstream: %{correlation_id: "corr-native-task", epoch: 3}
    }
  end

  defp frame(owner_turn_id, payload) do
    {:websocket_owner_frame, "corr-native-task", 3, owner_turn_id, payload}
  end

  defp task_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_task(pid) do
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end
end
