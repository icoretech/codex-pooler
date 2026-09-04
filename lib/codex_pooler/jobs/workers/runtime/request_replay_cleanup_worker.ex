defmodule CodexPooler.Jobs.RequestReplayCleanupWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["request_replay_cleanup"],
    unique: [fields: [:worker, :queue], states: :incomplete, period: 60]

  alias CodexPooler.Accounting
  alias CodexPooler.Repo

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(45)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    started_at = System.monotonic_time(:millisecond)

    case Accounting.cleanup_request_replays() do
      {:ok, summary} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at
        persist_summary(job, Map.put(summary, :duration_ms, duration_ms))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_summary(%Oban.Job{__meta__: %{state: :built}}, _summary), do: :ok

  defp persist_summary(%Oban.Job{} = job, summary) do
    job
    |> Ecto.Changeset.change(meta: Map.put(job.meta || %{}, "replay_cleanup", summary))
    |> Repo.update()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
