defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservations do
  @moduledoc false

  alias CodexPooler.Quotas.{AdditionalMeterIdentity, Evidence}
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.DateTimeDisplay

  @observation_limit 5

  @sources %{
    "codex_usage_api" => "Usage API",
    "codex_response_headers" => "Response headers",
    "codex_rate_limit_event" => "Rate-limit event",
    "codex_rate_limit_error" => "Rate-limit error"
  }

  @type observation :: %{
          key: String.t(),
          source: String.t(),
          used: String.t(),
          remaining: String.t(),
          remaining_value: float() | nil,
          observed_at: String.t(),
          reset_at: String.t(),
          freshness: String.t(),
          elapsed?: boolean(),
          selected?: boolean()
        }

  @spec group_key(AccountQuotaWindow.t()) :: String.t()
  def group_key(%AccountQuotaWindow{window_kind: "primary", window_minutes: 10_080} = window),
    do: group_key(%{window | window_kind: "secondary"})

  def group_key(window) do
    fingerprint({WindowSelector.logical_key(window), AdditionalMeterIdentity.token(window)})
  end

  @spec project(AccountQuotaWindow.t(), DateTimeDisplay.preferences(), DateTime.t()) ::
          observation()
  def project(window, preferences, as_of) do
    %{
      key: fingerprint({window.id, window.source, window.observed_at, window.reset_at}),
      source: Map.get(@sources, window.source, "Other source"),
      used: percent(window.used_percent),
      remaining: remaining(window.used_percent),
      remaining_value: remaining_value(window.used_percent),
      observed_at: timestamp(window.observed_at, preferences),
      reset_at: timestamp(window.reset_at, preferences),
      freshness: Evidence.current_freshness_state(window, as_of),
      elapsed?:
        match?(%DateTime{}, window.reset_at) and DateTime.compare(window.reset_at, as_of) != :gt,
      selected?: true
    }
  end

  @spec attach([map()], [AccountQuotaWindow.t()], DateTimeDisplay.preferences(), DateTime.t()) ::
          [map()]
  def attach(rows, windows, preferences, as_of) do
    groups =
      windows
      |> Enum.filter(&(DateTime.compare(&1.observed_at, as_of) != :gt))
      |> Enum.sort_by(&{-DateTime.to_unix(&1.observed_at, :microsecond), &1.source, &1.id})
      |> Enum.group_by(&group_key/1)

    Enum.map(rows, fn row ->
      case Map.get(row, :observations, []) do
        [selected] ->
          observations =
            groups
            |> Map.get(row.observation_group, [])
            |> Enum.map(&project(&1, preferences, as_of))
            |> Enum.map(&%{&1 | selected?: &1.key == selected.key})
            |> limit_observations()

          Map.put(row, :observations, observations)

        [] ->
          row
      end
    end)
  end

  defp limit_observations(observations) do
    latest = Enum.take(observations, @observation_limit)

    case Enum.find(observations, & &1.selected?) do
      nil ->
        latest

      selected ->
        if Enum.any?(latest, & &1.selected?) do
          latest
        else
          Enum.take(latest, @observation_limit - 1) ++ [selected]
        end
    end
  end

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp percent(%Decimal{} = value), do: "#{Decimal.to_string(Decimal.normalize(value), :normal)}%"
  defp percent(_value), do: "Not reported"
  defp remaining(%Decimal{} = value), do: percent(Decimal.sub(Decimal.new(100), value))
  defp remaining(_value), do: "Not reported"

  defp remaining_value(%Decimal{} = value),
    do: value |> then(&Decimal.sub(Decimal.new(100), &1)) |> Decimal.to_float()

  defp remaining_value(_value), do: nil

  defp timestamp(%DateTime{} = value, preferences),
    do: DateTimeDisplay.format_datetime(value, preferences)

  defp timestamp(_value, _preferences), do: "Not reported"
end
