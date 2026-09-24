defmodule CodexPooler.Jobs.APIKeyDeletionWorker do
  @moduledoc """
  Deletes a revoked API key whose history is too large to delete from the admin page.

  Each run detaches the key's requests and ledger entries and deletes its sessions and bridge
  rows in bounded batches for about 45 seconds, then snoozes while any are left; batches already
  done stay done. When nothing is left the run deletes the key row and writes its
  `api_key.delete` audit event in one transaction (`CodexPooler.Access.continue_api_key_deletion/3`).
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 5,
    tags: ["api_key_deletion"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:api_key_id],
      states: :incomplete,
      period: :infinity
    ]

  alias CodexPooler.Access

  @run_budget_ms 45_000

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"api_key_id" => api_key_id} = args}) when is_binary(api_key_id) do
    case Access.continue_api_key_deletion(api_key_id, Map.get(args, "requested_by_user_id"), System.monotonic_time(:millisecond) + @run_budget_ms) do
      :more -> {:snooze, 1}
      :deleted -> :ok
      :gone -> :ok
      {:cancel, reason} -> {:cancel, reason}
      # A job that gives up is announced by `CodexPooler.Jobs.DeletionFailureNotifier`, once Oban
      # has written its final state.
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :api_key_deletion_target_invalid}
end
