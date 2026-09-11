defmodule CodexPooler.Jobs.OpenAIStatusSyncWorker do
  @moduledoc "Polls the OpenAI status feed and persists metadata-only state."

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 3,
    tags: ["openai_status_sync"],
    unique: [
      fields: [:worker, :queue],
      states: :incomplete,
      period: {5, :minutes}
    ]

  alias CodexPooler.Status.Sync

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    opts = [now: parse_now(Map.get(args, "now"))]

    opts =
      case Application.get_env(:codex_pooler, :openai_status_sync_fetcher) do
        fetcher when is_function(fetcher, 2) -> [{:fetcher, fetcher} | opts]
        _ -> opts
      end

    case Sync.sync(opts) do
      {:ok, _result} ->
        :ok

      {:not_modified, _result} ->
        :ok

      {:error, %{code: code}} ->
        if transient_code?(code),
          do: {:error, {:status_feed, code}},
          else: {:cancel, {:status_feed, code}}

      {:error, _reason} ->
        {:error, :status_feed_sync_failed}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_openai_status_sync_args}

  defp transient_code?(code) when code in [:network_error, :upstream_unavailable], do: true
  defp transient_code?(code) when code in ["network_error", "upstream_unavailable"], do: true
  defp transient_code?(_code), do: false

  defp parse_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.truncate(timestamp, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp parse_now(_value), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
