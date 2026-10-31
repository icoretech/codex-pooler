defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservations do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Quotas.{AdditionalMeterIdentity, Evidence, WindowClassifier}
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetConfirmationProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @type saved_reset_context :: %{
          role: :last_verified,
          label: String.t(),
          detail: String.t(),
          candidate?: boolean(),
          candidate_label: String.t() | nil,
          candidate_role: :unconfirmed_report | nil
        }

  @type observation :: %{
          optional(:saved_reset_context) => saved_reset_context(),
          required(:key) => String.t(),
          required(:source) => String.t(),
          required(:slot) => String.t(),
          required(:used) => String.t(),
          required(:remaining) => String.t(),
          required(:remaining_value) => float() | nil,
          required(:observed_at) => String.t(),
          required(:reset_at) => String.t(),
          required(:freshness) => String.t(),
          required(:elapsed?) => boolean(),
          required(:selected?) => boolean(),
          required(:measurement_pending?) => boolean(),
          required(:pending_measurement) => map() | nil,
          required(:permission_facts) => %{allowed: boolean() | nil, limit_reached: boolean() | nil},
          required(:details) => [{String.t(), String.t()}]
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
    pending_measurement = pending_measurement(window, preferences, as_of)
    permission_facts = permission_facts(window, pending_measurement)

    %{
      key: fingerprint({window.id, window.source, group_key(window)}),
      source: source_label(window.source),
      slot: allowed(window.window_kind, ~w(primary secondary)),
      used: percent(window.used_percent),
      remaining: remaining(window.used_percent),
      remaining_value: remaining_value(window.used_percent),
      observed_at: timestamp(window.observed_at, preferences),
      reset_at: timestamp(window.reset_at, preferences),
      freshness: Evidence.current_freshness_state(window, as_of),
      elapsed?: match?(%DateTime{}, window.reset_at) and DateTime.compare(window.reset_at, as_of) != :gt,
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
      |> Enum.filter(&nonfuture_observation?(&1, as_of))
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

  @spec attach_saved_reset_context([map()], [AccountQuotaWindow.t()], map(), DateTime.t()) :: [map()]
  def attach_saved_reset_context(rows, windows, redemption, %DateTime{} = as_of) when is_map(redemption) do
    with true <- redemption["phase"] in ["consumed_pending_probe", "reblocked", "confirmed_by_upstream", "expired"],
         {:ok, consumed_at, 0} <- parse_consumed_at(redemption["consumed_at"]),
         true <- DateTime.compare(consumed_at, as_of) != :gt do
      contexts =
        windows
        |> Enum.filter(&WindowClassifier.saved_reset_window?/1)
        |> Enum.group_by(&group_key/1)
        |> Map.new(fn {key, grouped_windows} ->
          candidate? = Enum.any?(grouped_windows, &(not is_nil(SavedResetConfirmationProjection.candidate_observed_at(&1, consumed_at, as_of))))

          {key,
           %{
             role: :last_verified,
             label: gettext("Last verified quota"),
             detail: gettext("Source freshness does not mean the new quota cycle has been accepted."),
             candidate?: candidate?,
             candidate_label: if(candidate?, do: gettext("New quota report awaiting verification")),
             candidate_role: if(candidate?, do: :unconfirmed_report)
           }}
        end)

      Enum.map(rows, &attach_row_context(&1, contexts))
    else
      _invalid -> rows
    end
  end

  def attach_saved_reset_context(rows, _windows, _redemption, _as_of), do: rows

  defp attach_row_context(row, contexts) do
    case Map.get(contexts, Map.get(row, :observation_group)) do
      nil ->
        row

      context ->
        row
        |> Map.put(:saved_reset_context, context)
        |> Map.update!(:observations, &Enum.map(&1, fn observation -> put_selected_context(observation, context) end))
    end
  end

  defp put_selected_context(%{selected?: true} = observation, context),
    do: put_saved_reset_context(observation, context)

  defp put_selected_context(observation, _context), do: observation

  defp put_saved_reset_context(observation, context) do
    details = observation.details ++ [{gettext("Quota role"), context.label}, {gettext("Recovery verification"), context.detail}]
    details = if context.candidate?, do: details ++ [{gettext("Incoming quota report"), context.candidate_label}], else: details

    observation
    |> Map.put(:saved_reset_context, context)
    |> Map.put(:details, details)
  end

  defp nonfuture_observation?(%{observed_at: %DateTime{} = observed_at}, as_of),
    do: DateTime.compare(observed_at, as_of) != :gt

  defp nonfuture_observation?(_window, _as_of), do: false

  defp parse_consumed_at(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_consumed_at(_value), do: :error

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp details(window, preferences, as_of, pending_measurement, permission_facts) do
    details =
      [
        {gettext("Reset reported"), timestamp(window.reset_at, preferences)},
        {gettext("Last synchronized"), timestamp(window.last_sync_at, preferences)},
        {gettext("Source precision"), allowed(window.source_precision, ~w(authoritative observed inferred unknown))},
        {gettext("Window"), window_duration(window.window_minutes)},
        {gettext("Reported slot"), allowed(window.window_kind, ~w(primary secondary))},
        {gettext("Scope"), allowed(window.quota_scope, ~w(account model upstream_model feature))},
        {gettext("Window state"), window_state(window.reset_at, as_of)}
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
         preferences,
         as_of
       )
       when is_map(metadata) do
    with {:ok, candidate} <- EvidenceStore.parse_candidate(metadata),
         true <- EvidenceStore.candidate_valid?(candidate, as_of),
         true <- DateTime.compare(candidate.observed_at, as_of) != :gt,
         {:ok, %{allowed: true, limit_reached: false, observed_at: observed_at}} <-
           EvidenceStore.parse_candidate_provider_status(metadata),
         true <- positive_lower_percent?(candidate.used_percent, retained_percent) do
      %{
        role: :unconfirmed_report,
        used: percent(candidate.used_percent),
        remaining: remaining(candidate.used_percent),
        retained_remaining: gettext("%{remaining} remaining", remaining: remaining(retained_percent)),
        observed_at: timestamp(observed_at, preferences),
        permission_facts: %{allowed: true, limit_reached: false}
      }
    else
      _not_pending -> nil
    end
  end

  defp pending_measurement(_window, _preferences, _as_of), do: nil

  defp positive_lower_percent?(%Decimal{} = candidate, %Decimal{} = retained) do
    Decimal.compare(candidate, Decimal.new(0)) == :gt and
      Decimal.compare(candidate, retained) == :lt
  end

  defp pending_measurement_details(nil), do: []

  defp pending_measurement_details(pending_measurement) do
    [
      {gettext("Retained measurement"), Map.get(pending_measurement, :retained_remaining, gettext("Not reported"))},
      {gettext("Measurement status"), gettext("Retained measurement; newer provider measurement awaits confirmation")},
      {gettext("Pending provider measurement"), gettext("%{remaining} remaining", remaining: pending_measurement.remaining)},
      {gettext("Provider observation"), pending_measurement.observed_at}
    ]
  end

  defp maybe_add_permission_details(details, nil, _permission_facts), do: details

  defp maybe_add_permission_details(details, _pending_measurement, %{
         allowed: allowed,
         limit_reached: limit_reached
       }) do
    details
    |> maybe_add_permission_detail(gettext("Routing permission"), allowed, &permission_label/1)
    |> maybe_add_permission_detail(gettext("Limit reached"), limit_reached, &reached_label/1)
  end

  defp maybe_add_permission_detail(details, _label, nil, _formatter), do: details

  defp maybe_add_permission_detail(details, label, value, formatter),
    do: details ++ [{label, formatter.(value)}]

  defp permission_label(true), do: gettext("allowed")
  defp permission_label(false), do: gettext("not allowed")
  defp reached_label(true), do: gettext("yes")
  defp reached_label(false), do: gettext("no")

  defp percent(%Decimal{} = value), do: "#{Decimal.to_string(Decimal.normalize(value), :normal)}%"
  defp percent(_value), do: gettext("Not reported")
  defp remaining(%Decimal{} = value), do: percent(Decimal.sub(Decimal.new(100), value))
  defp remaining(_value), do: gettext("Not reported")

  defp remaining_value(%Decimal{} = value),
    do: value |> then(&Decimal.sub(Decimal.new(100), &1)) |> Decimal.to_float()

  defp remaining_value(_value), do: nil

  defp timestamp(%DateTime{} = value, preferences),
    do: DateTimeDisplay.format_datetime(value, preferences)

  defp timestamp(_value, _preferences), do: gettext("Not reported")

  defp allowed(value, values),
    do: if(value in values, do: allowed_label(value), else: gettext("Not reported"))

  defp allowed_label("primary"), do: gettext("primary")
  defp allowed_label("secondary"), do: gettext("secondary")
  defp allowed_label("authoritative"), do: gettext("authoritative")
  defp allowed_label("observed"), do: gettext("observed")
  defp allowed_label("inferred"), do: gettext("inferred")
  defp allowed_label("unknown"), do: gettext("unknown")
  defp allowed_label("account"), do: gettext("account")
  defp allowed_label("model"), do: gettext("model")
  defp allowed_label("upstream_model"), do: gettext("upstream model")
  defp allowed_label("feature"), do: gettext("feature")

  defp source_label("codex_usage_api"), do: gettext("Usage API")
  defp source_label("codex_response_headers"), do: gettext("Response headers")
  defp source_label("codex_rate_limit_event"), do: gettext("Rate-limit event")
  defp source_label("codex_rate_limit_error"), do: gettext("Rate-limit error")
  defp source_label(_source), do: gettext("Other source")

  defp window_duration(minutes)
       when is_integer(minutes) and minutes > 0 and rem(minutes, 1440) == 0,
       do: ngettext("%{count} day", "%{count} days", div(minutes, 1440))

  defp window_duration(minutes)
       when is_integer(minutes) and minutes > 0 and rem(minutes, 60) == 0,
       do: ngettext("%{count} hour", "%{count} hours", div(minutes, 60))

  defp window_duration(minutes) when is_integer(minutes) and minutes > 0, do: ngettext("%{count} minute", "%{count} minutes", minutes)
  defp window_duration(_minutes), do: gettext("Not reported")

  defp window_state(%DateTime{} = reset_at, as_of),
    do: if(DateTime.compare(reset_at, as_of) == :gt, do: gettext("not elapsed"), else: gettext("elapsed"))

  defp window_state(_reset_at, _as_of), do: gettext("Not reported")
end
