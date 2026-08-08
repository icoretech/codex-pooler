defmodule CodexPooler.Upstreams.SavedResets.ConvergenceTelemetry do
  @moduledoc false

  alias CodexPooler.Upstreams.SavedResets.ConfirmationMetadata

  @event [:codex_pooler, :saved_reset, :convergence]

  @type tags :: %{source: String.t(), outcome: String.t()}

  @spec emit(map()) :: :ok
  def emit(redemption), do: emit(redemption, DateTime.utc_now())

  @spec emit(map(), DateTime.t()) :: :ok
  def emit(redemption, %DateTime{} = observed_at) when is_map(redemption) do
    confirmation = ConfirmationMetadata.read(redemption)
    consumed_at = parse_datetime(redemption["consumed_at"])
    finished_at = parse_datetime(redemption["finished_at"])

    measurements =
      %{count: 1}
      |> put_duration(
        :applied_to_canonical_ms,
        consumed_at,
        confirmation.canonical_confirmed_at,
        observed_at
      )
      |> put_duration(
        :canonical_to_lifecycle_ms,
        confirmation.canonical_confirmed_at,
        finished_at,
        observed_at
      )
      |> put_duration(:applied_to_lifecycle_ms, consumed_at, finished_at, observed_at)

    :telemetry.execute(@event, measurements, %{
      source: confirmation.source,
      outcome: confirmation.outcome
    })
  end

  @spec tag_values(map()) :: tags()
  def tag_values(metadata) when is_map(metadata) do
    confirmation =
      ConfirmationMetadata.read(%{
        "convergence_source" => metadata[:source] || metadata["source"],
        "convergence_outcome" => metadata[:outcome] || metadata["outcome"]
      })

    %{source: confirmation.source, outcome: confirmation.outcome}
  end

  defp put_duration(measurements, _key, nil, _to, _observed_at), do: measurements
  defp put_duration(measurements, _key, _from, nil, _observed_at), do: measurements

  defp put_duration(measurements, key, %DateTime{} = from, %DateTime{} = to, observed_at) do
    if DateTime.compare(from, to) != :gt and DateTime.compare(to, observed_at) != :gt do
      Map.put(measurements, key, DateTime.diff(to, from, :millisecond))
    else
      measurements
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
