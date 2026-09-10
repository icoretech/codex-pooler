defmodule CodexPooler.Upstreams.Quota.Windows.Coherence do
  @moduledoc """
  Shared bookkeeping for consecutive coherent observations of one quota window
  from one evidence surface.

  A surface-specific module (`UsageCoherence`, `RuntimeCoherence`) supplies a
  spec: the metadata key, the sources it counts, how a coherent reading is
  recognised and how much older than the contradicted row a confirmation may
  be. This module maintains the metadata-only marker on the merged window
  attributes, decides when a window is confirmed (at least two coherent
  readings of the same running cycle, still fresh and unexhausted), and when a
  confirmed window supersedes a fresh exhausted row from another surface.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @version 1
  @same_cycle_tolerance_seconds 5 * 60
  @required_observations 2

  @type spec :: %{
          required(:metadata_key) => String.t(),
          required(:sources) => [String.t()],
          required(:coherent_reading?) => (Evidence.t() -> boolean()),
          required(:override_tolerance_seconds) => non_neg_integer()
        }

  @spec required_observations() :: pos_integer()
  def required_observations, do: @required_observations

  @spec observe(spec(), map(), Evidence.t(), DateTime.t()) :: map()
  def observe(spec, attrs, %Evidence{source: source} = evidence, %DateTime{})
      when is_map(attrs) do
    metadata = Map.get(attrs, :metadata) || %{}
    key = spec.metadata_key

    cond do
      source not in spec.sources ->
        attrs

      not adopted?(attrs, evidence) ->
        attrs

      not spec.coherent_reading?.(evidence) ->
        Map.put(attrs, :metadata, Map.delete(metadata, key))

      true ->
        marker = next_marker(Map.get(metadata, key), evidence)
        Map.put(attrs, :metadata, Map.put(metadata, key, marker))
    end
  end

  def observe(_spec, attrs, _evidence, _timestamp), do: attrs

  @spec confirmed?(spec(), AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def confirmed?(spec, %AccountQuotaWindow{source: source} = window, %DateTime{} = as_of) do
    with true <- source in spec.sources,
         {:ok, marker} <- parse_marker(window.metadata, spec.metadata_key),
         true <- marker.count >= @required_observations,
         true <- not_exhausted?(window.used_percent),
         true <- Evidence.current_freshness_state(window, as_of) == "fresh",
         true <- same_cycle?(marker.reset_at, window.reset_at),
         true <- DateTime.compare(marker.last_observed_at, as_of) != :gt,
         true <-
           DateTime.diff(as_of, marker.last_observed_at, :second) <=
             Evidence.freshness_ttl_seconds() do
      true
    else
      _not_confirmed -> false
    end
  end

  def confirmed?(_spec, _window, _as_of), do: false

  @doc """
  True when `confirmed` is a confirmed window of the spec's surface that
  supersedes `window`, a fresh exhausted row from another surface describing
  the same cycle and observed no later than the confirming readings plus the
  spec's override tolerance.
  """
  @spec overrides?(spec(), AccountQuotaWindow.t(), AccountQuotaWindow.t(), DateTime.t()) ::
          boolean()
  def overrides?(
        spec,
        %AccountQuotaWindow{source: confirmed_source} = confirmed,
        %AccountQuotaWindow{source: source} = window,
        %DateTime{} = as_of
      ) do
    confirmed_source in spec.sources and source not in spec.sources and
      exhausted?(window.used_percent) and confirmed?(spec, confirmed, as_of) and
      same_cycle?(confirmed.reset_at, window.reset_at) and
      newer?(confirmed.observed_at, window.observed_at, spec.override_tolerance_seconds)
  end

  def overrides?(_spec, _confirmed, _window, _as_of), do: false

  @spec parse_marker(map() | nil, String.t()) :: {:ok, map()} | :none
  def parse_marker(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      %{"version" => @version} = marker -> parse_marker_fields(marker)
      _missing -> :none
    end
  end

  def parse_marker(_metadata, _key), do: :none

  defp parse_marker_fields(marker) do
    with count when is_integer(count) and count > 0 <- marker["count"],
         {:ok, reset_at} <- parse_datetime(marker["reset_at"]),
         {:ok, first_observed_at} <- parse_datetime(marker["first_observed_at"]),
         {:ok, last_observed_at} <- parse_datetime(marker["last_observed_at"]),
         true <- marker["allowed"] == true and marker["limit_reached"] == false do
      {:ok,
       %{
         count: count,
         reset_at: reset_at,
         first_observed_at: first_observed_at,
         last_observed_at: last_observed_at
       }}
    else
      _invalid -> :none
    end
  end

  defp next_marker(previous, %Evidence{} = evidence) do
    {count, first_observed_at} =
      case parse_marker_fields(previous || %{}) do
        {:ok, marker} ->
          if same_cycle?(marker.reset_at, evidence.reset_at) and
               newer?(evidence.observed_at, marker.last_observed_at, 0),
             do: {marker.count + 1, marker.first_observed_at},
             else: {1, evidence.observed_at}

        :none ->
          {1, evidence.observed_at}
      end

    %{
      "version" => @version,
      "count" => count,
      "used_percent" =>
        evidence.used_percent |> Decimal.normalize() |> Decimal.to_string(:normal),
      "reset_at" => DateTime.to_iso8601(evidence.reset_at),
      "first_observed_at" => DateTime.to_iso8601(first_observed_at),
      "last_observed_at" => DateTime.to_iso8601(evidence.observed_at),
      "allowed" => true,
      "limit_reached" => false
    }
  end

  defp adopted?(attrs, %Evidence{observed_at: %DateTime{} = observed_at}) do
    case Map.get(attrs, :observed_at) do
      %DateTime{} = adopted -> DateTime.compare(adopted, observed_at) == :eq
      _missing -> false
    end
  end

  @spec not_exhausted?(term()) :: boolean()
  def not_exhausted?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(100)) == :lt

  def not_exhausted?(_used_percent), do: false

  defp exhausted?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(100)) != :lt

  defp exhausted?(_used_percent), do: false

  defp same_cycle?(%DateTime{} = left, %DateTime{} = right),
    do: abs(DateTime.diff(left, right, :second)) <= @same_cycle_tolerance_seconds

  defp same_cycle?(_left, _right), do: false

  # `incoming` counts as newer when it is strictly later than `previous`
  # moved back by the tolerance.
  defp newer?(%DateTime{} = incoming, %DateTime{} = previous, tolerance_seconds),
    do: DateTime.compare(incoming, DateTime.add(previous, -tolerance_seconds, :second)) == :gt

  defp newer?(_incoming, _previous, _tolerance), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp parse_datetime(_value), do: :error
end
