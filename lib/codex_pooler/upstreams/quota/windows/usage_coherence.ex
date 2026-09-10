defmodule CodexPooler.Upstreams.Quota.Windows.UsageCoherence do
  @moduledoc """
  Counts consecutive coherent Usage API observations of one quota window.

  A coherent observation is a `codex_usage_api` reading the window row actually
  adopted (the row's `observed_at` is the incoming observation), whose provider
  permission facts say allowed and not limit-reached, that is not exhausted,
  and that describes the same running cycle as the previous coherent
  observation. The count lets logical window selection drop a fresh exhausted
  row from another surface (response headers, rate-limit events, runtime) once
  the provider itself reported usable capacity twice: one lower reading stays a
  suspicion that the exhausted row keeps winning, two coherent readings are a
  recovery. Any exhausted or permission-denied reading clears the count.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @metadata_key "__quota_usage_coherence_v1"
  @version 1
  @provider_source "codex_usage_api"
  @same_cycle_tolerance_seconds 5 * 60
  @required_observations 2

  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @spec required_observations() :: pos_integer()
  def required_observations, do: @required_observations

  @doc """
  Maintains the coherence marker on the merged window attributes.

  Runs on every persisted Usage API observation. Readings the merge did not
  adopt (rejected or retained as a candidate) leave the marker untouched;
  exhausted or permission-denied readings clear it; adopted coherent readings
  extend the count within the same cycle or restart it at one.
  """
  @spec observe(map(), Evidence.t(), DateTime.t()) :: map()
  def observe(attrs, %Evidence{source: @provider_source} = evidence, %DateTime{})
      when is_map(attrs) do
    metadata = Map.get(attrs, :metadata) || %{}

    cond do
      not adopted?(attrs, evidence) ->
        attrs

      not coherent_reading?(evidence) ->
        Map.put(attrs, :metadata, Map.delete(metadata, @metadata_key))

      true ->
        marker = next_marker(Map.get(metadata, @metadata_key), evidence)
        Map.put(attrs, :metadata, Map.put(metadata, @metadata_key, marker))
    end
  end

  def observe(attrs, _evidence, _timestamp), do: attrs

  @doc """
  True when the window carries at least two coherent Usage API observations
  of its current cycle and is still fresh, allowed and not exhausted at `as_of`.
  """
  @spec confirmed?(AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def confirmed?(%AccountQuotaWindow{source: @provider_source} = window, %DateTime{} = as_of) do
    with {:ok, marker} <- parse_marker(window.metadata),
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

  def confirmed?(_window, _as_of), do: false

  @doc """
  True when `usage` is a confirmed Usage API window that supersedes `window`,
  a fresh exhausted row from another evidence surface describing the same
  cycle and observed before the confirming readings.
  """
  @spec overrides?(AccountQuotaWindow.t(), AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def overrides?(
        %AccountQuotaWindow{source: @provider_source} = usage,
        %AccountQuotaWindow{source: source} = window,
        %DateTime{} = as_of
      )
      when source != @provider_source do
    exhausted?(window.used_percent) and confirmed?(usage, as_of) and
      same_cycle?(usage.reset_at, window.reset_at) and
      newer?(usage.observed_at, window.observed_at)
  end

  def overrides?(_usage, _window, _as_of), do: false

  @doc false
  @spec parse_marker(map() | nil) :: {:ok, map()} | :none
  def parse_marker(%{@metadata_key => %{"version" => @version} = marker}) do
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

  def parse_marker(_metadata), do: :none

  defp next_marker(previous, %Evidence{} = evidence) do
    {count, first_observed_at} =
      case parse_marker(%{@metadata_key => previous}) do
        {:ok, marker} ->
          if same_cycle?(marker.reset_at, evidence.reset_at) and
               newer?(evidence.observed_at, marker.last_observed_at),
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

  defp coherent_reading?(%Evidence{
         reset_at: %DateTime{},
         observed_at: %DateTime{},
         used_percent: %Decimal{} = used_percent,
         metadata: metadata
       })
       when is_map(metadata) do
    metadata["rate_limit_allowed"] == true and metadata["rate_limit_reached"] == false and
      not_exhausted?(used_percent)
  end

  defp coherent_reading?(_evidence), do: false

  defp not_exhausted?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(100)) == :lt

  defp not_exhausted?(_used_percent), do: false

  defp exhausted?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(100)) != :lt

  defp exhausted?(_used_percent), do: false

  defp same_cycle?(%DateTime{} = left, %DateTime{} = right),
    do: abs(DateTime.diff(left, right, :second)) <= @same_cycle_tolerance_seconds

  defp same_cycle?(_left, _right), do: false

  defp newer?(%DateTime{} = incoming, %DateTime{} = previous),
    do: DateTime.compare(incoming, previous) == :gt

  defp newer?(_incoming, _previous), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp parse_datetime(_value), do: :error
end
