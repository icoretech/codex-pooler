defmodule CodexPooler.Jobs.PoolDeletionWorker do
  @moduledoc """
  Deletes an archived Pool whose history is too large to delete from the admin page.

  Each run deletes the Pool's history in bounded batches for about 45 seconds and snoozes while
  history is left, so no run holds a transaction or the queue for long and a deploy interrupts at
  most one short batch; batches already deleted stay deleted and the next run continues. When the
  history is gone the run deletes the Pool row and writes its `pool.delete` audit event in one
  transaction (`CodexPooler.Pools.finish_pool_deletion/2`).
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 5,
    tags: ["pool_deletion"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:pool_id],
      states: :incomplete,
      period: :infinity
    ]

  alias CodexPooler.Pools

  @run_budget_ms 45_000

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pool_id" => pool_id} = args}) when is_binary(pool_id) do
    case Pools.continue_pool_deletion(pool_id, Map.get(args, "requested_by_user_id"), System.monotonic_time(:millisecond) + @run_budget_ms) do
      :more -> {:snooze, 1}
      :deleted -> :ok
      :gone -> :ok
      {:cancel, reason} -> {:cancel, reason}
      # A job that gives up is announced by `CodexPooler.Jobs.DeletionFailureNotifier`, once Oban
      # has written its final state.
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :pool_deletion_target_invalid}
end
