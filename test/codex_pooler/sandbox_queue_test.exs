defmodule CodexPooler.SandboxQueueTest do
  @moduledoc """
  A non-async test shares its sandbox owner's single connection with every process it starts,
  and DBConnection's ownership proxy drops each queued checkout that has waited longer than twice
  `queue_target` whenever its once-a-second sweep runs. A hold that spans a whole sweep period is
  therefore certain to meet one: with the default `queue_target` (50 ms) the read queued behind it
  failed "dropped from queue", which is how a response task's settlement, running after its
  terminal frame, broke the test's next read, upgrade or cleanup under load (findings#206 rows
  206-161/206-163, findings#232 row 232-222). `config/test.exs` raises `queue_target`, so the read
  waits for the connection instead.
  """
  use CodexPooler.DataCase, async: false

  # One sweep period (1 s) plus margin, and above the largest settlement hold measured under load
  # (1.1 s): the queued read has waited longer than the default 100 ms at some sweep.
  @hold_ms 1_150

  @tag slow: "holds the shared sandbox connection across one full ownership-proxy sweep (1 s) so a dropping queue policy is certain to fire"
  test "a read queued behind another process's hold of the shared connection waits for it instead of being dropped" do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.checkout(fn ->
          send(parent, {:holding, self()})

          receive do
          after
            @hold_ms -> :released
          end
        end)
      end)

    holder_pid = holder.pid
    assert_receive {:holding, ^holder_pid}, 5_000
    queued_at = System.monotonic_time(:millisecond)

    assert %Postgrex.Result{rows: [[1]]} = Repo.query!("SELECT 1")

    # The read ran only once the hold ended: it did queue behind it.
    assert System.monotonic_time(:millisecond) - queued_at >= @hold_ms - 100
    assert Task.await(holder, @hold_ms * 3) == :released
  end
end
