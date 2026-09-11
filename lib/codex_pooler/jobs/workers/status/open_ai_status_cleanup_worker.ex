defmodule CodexPooler.Jobs.OpenAIStatusCleanupWorker do
  @moduledoc "Removes old terminal OpenAI status incidents in bounded batches."

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 3,
    tags: ["openai_status_cleanup"],
    unique: [
      fields: [:worker, :queue],
      states: :incomplete,
      period: {1, :day}
    ]

  alias CodexPooler.Status.Sync

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    now = parse_now(Map.get(args, "now"))

    opts = [
      retention_days: parse_positive_int(Map.get(args, "retention_days"), 90),
      batch_size: 100
    ]

    case Sync.cleanup(now, opts) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_openai_status_cleanup_args}

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0,
    do: min(value, 3650)

  defp parse_positive_int(_value, default), do: default

  defp parse_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.truncate(timestamp, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp parse_now(_value), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
