defmodule CodexPooler.Gateway.Transports.Websocket.OwnerTurnIdleBudgetTest do
  # A remote turn submission is answered when the turn ends, while the owner
  # relays the turn's frames to the proxy's socket, so its budget counts from
  # the latest frames the socket delivered (findings#302): the socket's
  # keepalive tick notifies the waiting task and each notice restarts the
  # budget. The tests drive the production erpc client against this node (an
  # erpc call to the local node runs in a process of its own, as on a peer) and
  # send the notices the way the socket sends them. The budgets are real timers,
  # so the tests spend a few hundred milliseconds of real time.
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.DownstreamProgress
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.ERPCNodeClient

  # Detection budget for a message the test only observes.
  @detection_timeout_ms 15_000

  defmodule HeldTurn do
    @moduledoc false

    # Stands for the owner-node submission: it answers once released.
    def hold(observer, result \\ :answered) do
      monitor = Process.monitor(observer)
      send(observer, {:held_turn, self()})

      receive do
        :release ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^observer, _reason} ->
          exit(:observer_down)
      end
    end

    def fail, do: raise(ArgumentError, "synthetic owner failure")
  end

  describe "DownstreamProgress" do
    test "drain takes every pending notice and leaves other messages in place" do
      refute DownstreamProgress.drain()

      :ok = DownstreamProgress.notify(self())
      send(self(), :unrelated)
      :ok = DownstreamProgress.notify(self())

      assert DownstreamProgress.drain()
      refute DownstreamProgress.drain()
      assert_received :unrelated
    end
  end

  describe "ERPCNodeClient.call_owner_turn/5" do
    @tag slow: "the idle budget is a real timer: the held turn must outlast it several times while notices arrive"
    test "notices keep a turn alive past its budget and the turn's answer comes back" do
      budget_ms = 400
      caller = self()
      pacer = start_notice_pacer(caller, notices: 15, every_ms: 50)
      started = System.monotonic_time(:millisecond)

      assert ERPCNodeClient.call_owner_turn(node(), HeldTurn, :hold, [pacer], budget_ms) == :answered

      # Fifteen notices 50 ms apart release the turn after about 750 ms, past
      # the 400 ms budget a total bound would have spent.
      assert System.monotonic_time(:millisecond) - started >= 700
      assert_receive {:pacer_done, ^pacer, 15}, @detection_timeout_ms
    end

    test "a turn without notices is abandoned at its budget exactly as call_owner/5 abandons it" do
      budget_ms = 150

      started = System.monotonic_time(:millisecond)
      idle_bound = ERPCNodeClient.call_owner_turn(node(), HeldTurn, :hold, [self()], budget_ms)
      elapsed_ms = System.monotonic_time(:millisecond) - started
      total_bound = ERPCNodeClient.call_owner(node(), HeldTurn, :hold, [self()], budget_ms)

      assert idle_bound == {:error, :owner_forward_timeout}
      assert total_bound == idle_bound
      assert elapsed_ms >= budget_ms
      release_held_turns!(2)
    end

    test "a notice that came before the submission started still restarts the budget once" do
      budget_ms = 200
      :ok = DownstreamProgress.notify(self())
      started = System.monotonic_time(:millisecond)

      assert ERPCNodeClient.call_owner_turn(node(), HeldTurn, :hold, [self()], budget_ms) == {:error, :owner_forward_timeout}

      # The early notice is drained at the first poll (a quarter of the budget)
      # and restarts the budget there; nothing renews it afterwards.
      assert System.monotonic_time(:millisecond) - started >= budget_ms + div(budget_ms, 4)
      refute DownstreamProgress.drain()
      release_held_turns!(1)
    end

    @tag slow: "a renewed source deadline and delayed timeout reply must outlast the original remote idle window"
    test "pending controls preserve a renewed source timeout beyond the original forwarder window" do
      budget_ms = 1_500
      source_timeout_ms = 500
      pacer = start_pending_source(self(), budget_ms, source_timeout_ms)
      source_timeout = {:error, :upstream_websocket_receive_timeout}

      assert ERPCNodeClient.call_owner_turn(node(), HeldTurn, :hold, [pacer, source_timeout], budget_ms) == source_timeout
      assert_receive {:pending_source_timed_out, ^pacer}, @detection_timeout_ms
      assert_receive {:pending_pacer_done, ^pacer}, @detection_timeout_ms
      assert DownstreamProgress.drain_budget(budget_ms) == nil
    end

    @tag slow: "a late owner answer distinguishes the configured idle cap from an added one-second window"
    test "one pending notice cannot exceed the configured idle budget after its source stops" do
      budget_ms = 400
      pacer = start_capped_pending_pacer(self(), budget_ms)

      assert ERPCNodeClient.call_owner_turn(node(), HeldTurn, :hold, [pacer], budget_ms) == {:error, :owner_forward_timeout}
      assert_receive {:pending_pacer_done, ^pacer}, @detection_timeout_ms
      assert DownstreamProgress.drain_budget(budget_ms) == nil
    end

    test "an owner failure comes back as call_owner/5 returns it" do
      assert ERPCNodeClient.call_owner_turn(node(), HeldTurn, :fail, [], 1_000) ==
               ERPCNodeClient.call_owner(node(), HeldTurn, :fail, [], 1_000)

      assert {:error, _reason} = ERPCNodeClient.call_owner_turn(node(), HeldTurn, :fail, [], 1_000)
    end
  end

  # Waits for the held turn, notifies `caller` every `every_ms` for `notices`
  # rounds, as the socket's keepalive tick does while a turn delivers frames,
  # then releases the turn.
  defp start_notice_pacer(caller, notices: notices, every_ms: every_ms) do
    test_pid = self()

    spawn_link(fn ->
      receive do
        {:held_turn, turn} ->
          :ok = pace_notices(caller, notices, every_ms)
          send(turn, :release)
          send(test_pid, {:pacer_done, self(), notices})
      after
        @detection_timeout_ms -> exit(:held_turn_never_started)
      end
    end)
  end

  defp pace_notices(_caller, 0, _every_ms), do: :ok

  defp pace_notices(caller, remaining, every_ms) do
    :ok = DownstreamProgress.notify(caller)
    _timer = Process.send_after(self(), :next_notice, every_ms)

    receive do
      :next_notice -> pace_notices(caller, remaining - 1, every_ms)
    end
  end

  defp start_pending_source(caller, budget_ms, source_timeout_ms) do
    start_supervised!({Task,
     fn ->
       receive do
         {:held_turn, turn} ->
           # Each synthetic collected provider frame renews the source receive
           # deadline but emits only pending controls downstream. Keep that
           # source progressing through the original forwarder window.
           renew_pending_source(caller, System.monotonic_time(:millisecond) + budget_ms, source_timeout_ms)
           send(caller, {:pending_source_timed_out, self()})

           # Model reply delivery after the source deadline, still inside the
           # one-second margin. A max-only renewal expires before this reply.
           receive do
           after
             250 -> release_pending_turn(caller, turn)
           end
       after
         @detection_timeout_ms -> exit(:held_turn_never_started)
       end
     end})
  end

  defp renew_pending_source(caller, deadline, source_timeout_ms) do
    :ok = DownstreamProgress.notify_pending(caller, source_timeout_ms)

    if System.monotonic_time(:millisecond) >= deadline do
      receive do
      after
        source_timeout_ms -> :ok
      end
    else
      receive do
      after
        div(source_timeout_ms, 4) -> renew_pending_source(caller, deadline, source_timeout_ms)
      end
    end
  end

  defp start_capped_pending_pacer(caller, budget_ms) do
    start_supervised!({Task,
     fn ->
       receive do
         {:held_turn, turn} ->
           :ok = DownstreamProgress.notify_pending(caller, budget_ms * 10)

           # This one notice must not add a second to a short explicit budget.
           # The abandoned owner's reply arrives well after the capped window
           # and before the uncapped margin would expire.
           receive do
           after
             budget_ms * 3 -> release_pending_turn(caller, turn)
           end
       after
         @detection_timeout_ms -> exit(:held_turn_never_started)
       end
     end})
  end

  defp release_pending_turn(caller, turn) do
    monitor = Process.monitor(turn)
    send(turn, :release)
    assert_receive {:DOWN, ^monitor, :process, ^turn, _reason}, @detection_timeout_ms
    send(caller, {:pending_pacer_done, self()})
  end

  # The abandoned submissions are still running on this node: release them and
  # wait for their exit so none outlives the test.
  defp release_held_turns!(count) do
    for _turn <- 1..count do
      assert_receive {:held_turn, turn}, @detection_timeout_ms
      monitor = Process.monitor(turn)
      send(turn, :release)
      assert_receive {:DOWN, ^monitor, :process, ^turn, _reason}, @detection_timeout_ms
    end

    :ok
  end
end
