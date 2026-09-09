defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservations do
  @moduledoc false

  alias CodexPooler.Quotas.{AdditionalMeterIdentity, Evidence}
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.DateTimeDisplay

  @sources %{
    "codex_usage_api" => "Usage API",
    "codex_response_headers" => "Response headers",
    "codex_rate_limit_event" => "Rate-limit event",
    "codex_rate_limit_error" => "Rate-limit error"
  }

  @type observation :: %{
          key: String.t(),
          source: String.t(),
          slot: String.t(),
          used: String.t(),
          remaining: String.t(),
          remaining_value: float() | nil,
          observed_at: String.t(),
          reset_at: String.t(),
          freshness: String.t(),
          elapsed?: boolean(),
          selected?: boolean(),
          measurement_pending?: boolean(),
          pending_measurement: map() | nil,
          permission_facts: %{allowed: boolean() | nil, limit_reached: boolean() | nil},
          details: [{String.t(), String.t()}]
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
    pending_measurement = pending_measurement(window, preferences)
    permission_facts = permission_facts(window, pending_measurement)

    %{
      key: fingerprint({window.id, window.source, window.observed_at, window.reset_at}),
      source: Map.get(@sources, window.source, "Other source"),
      slot: allowed(window.window_kind, ~w(primary secondary)),
      used: percent(window.used_percent),
      remaining: remaining(window.used_percent),
      remaining_value: remaining_value(window.used_percent),
      observed_at: timestamp(window.observed_at, preferences),
      reset_at: timestamp(window.reset_at, preferences),
      freshness: Evidence.current_freshness_state(window, as_of),
      elapsed?:
        match?(%DateTime{}, window.reset_at) and DateTime.compare(window.reset_at, as_of) != :gt,
      selected?: true,
      measurement_pending?: not is_nil(pending_measurement),
      pending_measurement: pending_measurement,
      permission_facts: permission_facts,
      details: details(window, preferences, as_of, pending_measurement, permission_facts)
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
            |> Enum.sort_by(&(not &1.selected?))

          Map.put(row, :observations, observations)

        [] ->
          row
      end
    end)
  end

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp details(window, preferences, as_of, pending_measurement, permission_facts) do
    details =
      [
        {"Reset reported", timestamp(window.reset_at, preferences)},
        {"Last synchronized", timestamp(window.last_sync_at, preferences)},
        {"Source precision",
         allowed(window.source_precision, ~w(authoritative observed inferred unknown))},
        {"Window", window_duration(window.window_minutes)},
        {"Reported slot", allowed(window.window_kind, ~w(primary secondary))},
        {"Scope", allowed(window.quota_scope, ~w(account model upstream_model feature))},
        {"Window state", window_state(window.reset_at, as_of)}
      ]
      |> maybe_add_permission_details(pending_measurement, permission_facts)

    pending_measurement_details(pending_measurement) ++ details
  end

  defp permission_facts(_window, %{permission_facts: permission_facts}), do: permission_facts

  defp permission_facts(%{metadata: metadata}, nil) when is_map(metadata) do
    %{
      allowed: boolean_or_nil(Map.get(metadata, "rate_limit_allowed")),
      limit_reached: boolean_or_nil(Map.get(metadata, "rate_limit_reached"))
    }
  end

  defp permission_facts(_window, nil), do: %{allowed: nil, limit_reached: nil}

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil

  defp pending_measurement(
         %{
           source: "codex_usage_api",
           used_percent: %Decimal{} = retained_percent,
           metadata: metadata
         },
         preferences
       )
       when is_map(metadata) do
    with {:ok, candidate} <- EvidenceStore.parse_candidate(metadata),
         {:ok, %{allowed: true, limit_reached: false, observed_at: observed_at}} <-
           EvidenceStore.parse_candidate_provider_status(metadata),
         true <- positive_lower_percent?(candidate.used_percent, retained_percent) do
      %{
        used: percent(candidate.used_percent),
        remaining: remaining(candidate.used_percent),
        retained_remaining: remaining(retained_percent) <> " remaining",
        observed_at: timestamp(observed_at, preferences),
        permission_facts: %{allowed: true, limit_reached: false}
      }
    else
      _not_pending -> nil
    end
  end

  defp pending_measurement(_window, _preferences), do: nil

  defp positive_lower_percent?(%Decimal{} = candidate, %Decimal{} = retained) do
    Decimal.compare(candidate, Decimal.new(0)) == :gt and
      Decimal.compare(candidate, retained) == :lt
  end

  defp pending_measurement_details(nil), do: []

  defp pending_measurement_details(pending_measurement) do
    [
      {"Retained measurement", Map.get(pending_measurement, :retained_remaining, "Not reported")},
      {"Measurement status",
       "Retained measurement; newer provider measurement awaits confirmation"},
      {"Pending provider measurement", pending_measurement.remaining <> " remaining"},
      {"Provider observation", pending_measurement.observed_at}
    ]
  end

  defp maybe_add_permission_details(details, nil, _permission_facts), do: details

  defp maybe_add_permission_details(details, _pending_measurement, %{
         allowed: allowed,
         limit_reached: limit_reached
       }) do
    details
    |> maybe_add_permission_detail("Routing permission", allowed, &permission_label/1)
    |> maybe_add_permission_detail("Limit reached", limit_reached, &reached_label/1)
  end

  defp maybe_add_permission_detail(details, _label, nil, _formatter), do: details

  defp maybe_add_permission_detail(details, label, value, formatter),
    do: details ++ [{label, formatter.(value)}]

  defp permission_label(true), do: "allowed"
  defp permission_label(false), do: "not allowed"
  defp reached_label(true), do: "yes"
  defp reached_label(false), do: "no"

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

  defp allowed(value, values),
    do: if(value in values, do: String.replace(value, "_", " "), else: "Not reported")

  defp window_duration(minutes)
       when is_integer(minutes) and minutes > 0 and rem(minutes, 1440) == 0,
       do: "#{div(minutes, 1440)} days"

  defp window_duration(minutes)
       when is_integer(minutes) and minutes > 0 and rem(minutes, 60) == 0,
       do: "#{div(minutes, 60)} hours"

  defp window_duration(minutes) when is_integer(minutes) and minutes > 0, do: "#{minutes} minutes"
  defp window_duration(_minutes), do: "Not reported"

  defp window_state(%DateTime{} = reset_at, as_of),
    do: if(DateTime.compare(reset_at, as_of) == :gt, do: "not elapsed", else: "elapsed")

  defp window_state(_reset_at, _as_of), do: "Not reported"
end
