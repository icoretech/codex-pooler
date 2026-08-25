defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection do
  @moduledoc false

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.ModelWeeklyResetSemantics
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Charts.Measurements
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetConfirmationProjection
  alias CodexPoolerWeb.DateTimeDisplay
  alias CodexPoolerWeb.RelativeTime

  @quota_priming_labels %{
    "unknown" => "Priming pending",
    "refreshing" => "Reconciling quota",
    "known" => "Quota known",
    "weekly_only_probe" => "Weekly-only probe",
    "stale" => "Quota stale",
    "expired" => "Quota expired",
    "failed" => "Quota failed",
    "blocked" => "Priming blocked",
    "resetless_unprimed" => "Quota reset missing",
    "unprimed" => "Quota unprimed"
  }

  @observed_zero_use_sources ~w(
    codex_usage_api
    codex_rate_limit_event
    codex_response_headers
    codex_rate_limit_error
  )

  @additional_meter_fingerprint_prefix "meter-"
  @additional_meter_fingerprint_hex_length 24
  @additional_meter_fingerprint_domain "quota-additional-meter-dom-v1:"

  @type evidence_state :: :fresh | :stale | :unknown
  @type meter_state :: :current | :historical | :historical_exhausted | :unknown
  @type reset_display_state :: :countdown | :static | :unconfirmed | :absent

  @type quota_limit_row :: %{
          required(:key) => atom() | String.t(),
          required(:label) => String.t(),
          required(:percent) => Decimal.t() | nil,
          required(:percent_value) => number(),
          required(:percent_label) => String.t(),
          required(:count_label) => String.t() | nil,
          required(:count_title) => String.t() | nil,
          required(:burning_credits) => boolean(),
          required(:evidence_state) => evidence_state(),
          required(:meter_state) => meter_state(),
          required(:freshness_label) => String.t(),
          required(:freshness_title) => String.t(),
          required(:observed_label) => String.t(),
          required(:observed_title) => String.t() | nil,
          required(:reset_semantics) => :anchored | :floating | :unknown,
          required(:reset_display_state) => reset_display_state(),
          required(:reset_at) => DateTime.t() | nil,
          required(:reset_label) => String.t() | nil,
          required(:reset_title) => String.t() | nil
        }

  @type saved_reset_confirmation :: SavedResetConfirmationProjection.t()

  @spec saved_reset_confirmation(
          map(),
          [Quota.AccountQuotaWindow.t()],
          [Quota.AccountQuotaWindow.t()],
          DateTime.t()
        ) ::
          saved_reset_confirmation() | nil
  def saved_reset_confirmation(redemption, raw_windows, effective_windows, snapshot_at) do
    SavedResetConfirmationProjection.project(
      redemption,
      raw_windows,
      effective_windows,
      snapshot_at
    )
  end

  @spec readiness([Quota.AccountQuotaWindow.t()], DateTime.t()) :: UpstreamQuotaReadiness.t()
  def readiness(windows, %DateTime{} = snapshot_at) when is_list(windows) do
    UpstreamQuotaReadiness.from_windows(windows, snapshot_at)
  end

  @spec assignment_priming_status(map()) :: String.t()
  def assignment_priming_status(%{metadata: %{"quota_priming" => %{"status" => status}}})
      when is_binary(status),
      do: status

  def assignment_priming_status(%{quota_priming_status: status}) when is_binary(status),
    do: status

  def assignment_priming_status(_assignment), do: "unknown"

  @spec assignment_priming_label(map() | String.t()) :: String.t()
  def assignment_priming_label(%{} = assignment) do
    assignment
    |> assignment_priming_status()
    |> assignment_priming_label()
  end

  def assignment_priming_label(status) when is_binary(status) do
    Map.get(@quota_priming_labels, status, String.replace(status, "_", " "))
  end

  @spec put_current_quota_priming(map(), map()) :: map()
  def put_current_quota_priming(assignment, quota_readiness) do
    case assignment_priming_status(assignment) do
      status when status in ["failed", "blocked"] ->
        put_quota_priming(assignment, status)

      _status ->
        put_derived_quota_priming(assignment, quota_readiness)
    end
  end

  defp put_derived_quota_priming(assignment, %{state: "ready"}) do
    put_quota_priming(assignment, "known")
  end

  defp put_derived_quota_priming(assignment, %{state: "weekly_only_probe"}) do
    put_quota_priming(assignment, "weekly_only_probe")
  end

  defp put_derived_quota_priming(assignment, _quota_readiness), do: assignment

  @spec quota_refresh_status([map()], DateTimeDisplay.preferences()) :: String.t()
  def quota_refresh_status(assignments, datetime_preferences) do
    assignments
    |> Enum.map(& &1.last_successful_refresh_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
    |> case do
      %DateTime{} = refreshed_at ->
        DateTimeDisplay.format_datetime(refreshed_at, datetime_preferences)

      nil ->
        "not run"
    end
  end

  @spec quota_limit_rows(
          [Quota.AccountQuotaWindow.t()],
          DateTimeDisplay.preferences(),
          DateTime.t()
        ) :: [quota_limit_row()]
  def quota_limit_rows(windows, datetime_preferences, %DateTime{} = snapshot_at)
      when is_list(windows) do
    additional_limits =
      windows
      |> Enum.reject(
        &(account_quota_window?(&1) or
            Evidence.current_freshness_state(&1, snapshot_at) == "stale")
      )
      |> Enum.filter(&informative_additional_quota_window?/1)
      |> Enum.sort_by(&quota_limit_sort_key/1)
      |> quota_limit_presentations()
      |> Enum.map(fn {window, key, label} ->
        quota_limit_row(
          key,
          label,
          window,
          datetime_preferences,
          snapshot_at
        )
      end)

    [
      quota_limit_row(
        :primary_5h,
        "5h",
        quota_account_window(windows, :primary_5h, snapshot_at),
        datetime_preferences,
        snapshot_at
      ),
      quota_limit_row(
        :primary_30d,
        "30d",
        quota_account_window(windows, :monthly_primary, snapshot_at),
        datetime_preferences,
        snapshot_at
      ),
      quota_limit_row(
        :weekly,
        "Weekly",
        quota_account_window(windows, "secondary", snapshot_at),
        datetime_preferences,
        snapshot_at
      )
    ] ++ additional_limits
  end

  defp put_quota_priming(assignment, status) do
    assignment
    |> Map.put(:quota_priming_status, status)
    |> Map.put(:quota_priming_label, assignment_priming_label(status))
  end

  defp account_quota_window?(%Quota.AccountQuotaWindow{
         quota_key: "account",
         quota_scope: "account"
       }),
       do: true

  defp account_quota_window?(%Quota.AccountQuotaWindow{}), do: false

  defp informative_additional_quota_window?(%Quota.AccountQuotaWindow{} = window) do
    not is_nil(quota_remaining_percent(window)) or not is_nil(quota_count_label(window))
  end

  defp quota_account_window(windows, "secondary", snapshot_at) do
    WindowSelector.best_account_window(windows, :weekly_secondary, snapshot_at)
  end

  defp quota_account_window(windows, descriptor, snapshot_at) do
    WindowSelector.best_account_window(windows, descriptor, snapshot_at)
  end

  defp quota_limit_sort_key(%Quota.AccountQuotaWindow{} = window) do
    {
      quota_scope_sort_value(window.quota_scope),
      quota_limit_label(window),
      window.window_kind,
      window.window_minutes || 0,
      window.quota_key,
      window.quota_family || "",
      window.model || "",
      window.upstream_model || ""
    }
  end

  defp quota_scope_sort_value("model"), do: 0
  defp quota_scope_sort_value("upstream_model"), do: 1
  defp quota_scope_sort_value("feature"), do: 2
  defp quota_scope_sort_value(_scope), do: 3

  defp quota_limit_key(%Quota.AccountQuotaWindow{} = window) do
    {scope, family, model, upstream_model, quota_key, window_kind, window_minutes} =
      WindowSelector.logical_key(window)

    identity = [scope, family, model, upstream_model, quota_key, window_kind, window_minutes]

    identity
    |> Enum.map(&quota_identity_token/1)
    |> then(&"#{quota_limit_key_prefix(window)}-identity-#{Enum.join(&1, "-")}")
    |> Kernel.<>(quota_additional_meter_fingerprint(window))
  end

  defp quota_additional_meter_fingerprint(%Quota.AccountQuotaWindow{} = window) do
    case Evidence.additional_meter_token(window) do
      nil -> ""
      meter_token -> "-#{additional_meter_fingerprint(meter_token)}"
    end
  end

  defp additional_meter_fingerprint(meter_token) do
    (@additional_meter_fingerprint_domain <> meter_token)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @additional_meter_fingerprint_hex_length)
    |> then(&(@additional_meter_fingerprint_prefix <> &1))
  end

  defp quota_limit_key_prefix(%Quota.AccountQuotaWindow{} = window) do
    [window.quota_scope, window.quota_key, window.window_kind, window.window_minutes]
    |> Enum.map_join("-", &quota_key_prefix_component/1)
  end

  defp quota_key_prefix_component(nil), do: "none"
  defp quota_key_prefix_component(value) when is_integer(value), do: Integer.to_string(value)

  defp quota_key_prefix_component(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
  end

  defp quota_identity_token(nil), do: "n"
  defp quota_identity_token(value) when is_integer(value), do: "i#{value}"

  defp quota_identity_token(value) when is_binary(value) do
    "s#{value |> Base.encode32(padding: false) |> String.downcase()}"
  end

  defp quota_limit_presentations(windows) do
    windows_by_legacy_key = Enum.group_by(windows, &quota_limit_key_prefix/1)
    labels_by_base = Enum.group_by(windows, &quota_limit_label/1)

    Enum.map(windows, fn window ->
      base_label = quota_limit_label(window)
      legacy_key = quota_limit_key_prefix(window)

      key =
        case Map.fetch!(windows_by_legacy_key, legacy_key) do
          [_window] -> legacy_key
          _colliding_windows -> quota_limit_key(window)
        end

      label =
        case Map.fetch!(labels_by_base, base_label) do
          [_window] -> base_label
          _colliding_windows -> "#{base_label} (#{quota_identity_label(window)})"
        end

      {window, key, label}
    end)
  end

  defp quota_limit_label(%Quota.AccountQuotaWindow{} = window) do
    window
    |> quota_limit_base_label()
    |> then(&"#{&1} #{quota_window_label(window)}")
  end

  defp quota_limit_base_label(%Quota.AccountQuotaWindow{} = window) do
    [
      window.display_label,
      window.model,
      window.upstream_model,
      window.limit_name
    ]
    |> Enum.find(&Formatting.present_string?/1)
    |> then(&(&1 || "Additional limit"))
    |> humanize_quota_label()
  end

  defp quota_identity_label(%Quota.AccountQuotaWindow{} = window) do
    {scope, family, model, upstream_model, _quota_key, _window_kind, _window_minutes} =
      WindowSelector.logical_key(window)

    ([quota_scope_label(scope), identity_dimension_label("Family", family)] ++
       scope_identity_dimension_labels(scope, model, upstream_model))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp quota_scope_label("model"), do: "Model scope"
  defp quota_scope_label("upstream_model"), do: "Upstream model scope"
  defp quota_scope_label("feature"), do: "Feature scope"
  defp quota_scope_label(scope), do: identity_dimension_label("Scope", scope)

  defp scope_identity_dimension_labels("model", model, _upstream_model),
    do: [identity_dimension_label("Model", model)]

  defp scope_identity_dimension_labels("upstream_model", _model, upstream_model),
    do: [identity_dimension_label("Upstream model", upstream_model)]

  defp scope_identity_dimension_labels(_scope, model, upstream_model) do
    [
      identity_dimension_label("Model", model),
      identity_dimension_label("Upstream model", upstream_model)
    ]
  end

  defp identity_dimension_label(_name, value) when not is_binary(value), do: nil

  defp identity_dimension_label(name, value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      "#{name} #{String.replace(value, ~r/[_-]+/u, " ")}"
    end
  end

  defp quota_window_label(%Quota.AccountQuotaWindow{window_kind: "primary", window_minutes: 300}),
    do: "5h"

  defp quota_window_label(%Quota.AccountQuotaWindow{
         window_kind: "primary",
         window_minutes: minutes
       })
       when is_integer(minutes),
       do: format_window_minutes(minutes)

  defp quota_window_label(%Quota.AccountQuotaWindow{window_kind: "primary"}), do: "Primary"

  defp quota_window_label(%Quota.AccountQuotaWindow{
         window_kind: "secondary",
         window_minutes: minutes
       })
       when minutes in [nil, 10_080],
       do: "Weekly"

  defp quota_window_label(%Quota.AccountQuotaWindow{
         window_kind: "secondary",
         window_minutes: minutes
       })
       when is_integer(minutes),
       do: format_window_minutes(minutes)

  defp quota_window_label(%Quota.AccountQuotaWindow{window_kind: window_kind})
       when is_binary(window_kind) do
    window_kind
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp quota_window_label(%Quota.AccountQuotaWindow{}), do: "Window"

  defp format_window_minutes(minutes) when rem(minutes, 1_440) == 0,
    do: "#{div(minutes, 1_440)}d"

  defp format_window_minutes(minutes) when rem(minutes, 60) == 0,
    do: "#{div(minutes, 60)}h"

  defp format_window_minutes(minutes), do: "#{minutes}m"

  defp humanize_quota_label("codex_spark"), do: "GPT-5.3-Codex-Spark"
  defp humanize_quota_label("codex_other"), do: "GPT-5.3-Codex-Spark"
  defp humanize_quota_label("gpt_5_3_codex_spark"), do: "GPT-5.3-Codex-Spark"
  defp humanize_quota_label("gpt-5.3-codex-spark"), do: "GPT-5.3-Codex-Spark"

  defp humanize_quota_label(label) when is_binary(label) do
    label
    |> String.replace("_", " ")
    |> String.trim()
  end

  defp humanize_quota_label(_label), do: "Additional limit"

  defp quota_limit_row(
         key,
         label,
         %Quota.AccountQuotaWindow{} = window,
         datetime_preferences,
         snapshot_at
       ) do
    remaining_percent = quota_remaining_percent(window)
    evidence_state = quota_evidence_state(window, snapshot_at)

    {reset_semantics, reset_display_state, reset_at, reset_label, reset_title} =
      quota_reset_presentation(window, evidence_state, datetime_preferences, snapshot_at)

    count_label = quota_count_label(window)
    burning_credits = burning_credits?(window)
    {freshness_label, freshness_title} = freshness_presentation(evidence_state)

    {observed_label, observed_title} =
      observed_presentation(window.observed_at, evidence_state, datetime_preferences, snapshot_at)

    %{
      key: key,
      label: label,
      percent: remaining_percent,
      percent_value: quota_percent_value(remaining_percent),
      percent_label: quota_percent_label(remaining_percent),
      count_label: count_label,
      count_title: quota_count_title(window, count_label, burning_credits),
      burning_credits: burning_credits,
      evidence_state: evidence_state,
      meter_state: quota_meter_state(evidence_state, remaining_percent),
      freshness_label: freshness_label,
      freshness_title: freshness_title,
      observed_label: observed_label,
      observed_title: observed_title,
      reset_semantics: reset_semantics,
      reset_display_state: reset_display_state,
      reset_at: reset_at,
      reset_label: reset_label,
      reset_title: reset_title
    }
  end

  defp quota_limit_row(key, label, nil, _datetime_preferences, _snapshot_at) do
    %{
      key: key,
      label: label,
      percent: nil,
      percent_value: 0,
      percent_label: "not reported",
      count_label: nil,
      count_title: nil,
      burning_credits: false,
      evidence_state: :unknown,
      meter_state: :unknown,
      freshness_label: "freshness unknown",
      freshness_title: "quota evidence was not reported",
      observed_label: "observed time not reported",
      observed_title: nil,
      reset_semantics: :unknown,
      reset_display_state: :absent,
      reset_at: nil,
      reset_label: nil,
      reset_title: nil
    }
  end

  defp quota_remaining_percent(
         %Quota.AccountQuotaWindow{
           quota_key: "account",
           quota_scope: "account",
           source: "codex_usage_api"
         } = window
       ),
       do: Measurements.meter_remaining_percent(window)

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{
         quota_scope: scope,
         active_limit: active_limit,
         credits: credits,
         reset_at: %DateTime{},
         used_percent: %Decimal{} = used_percent,
         source: source,
         source_precision: source_precision
       })
       when scope in ["account", "model", "upstream_model"] and active_limit in [nil, 0] and
              credits in [nil, 0] and source in @observed_zero_use_sources and
              source_precision in ["observed", "authoritative"] do
    used_percent |> remaining_percent_from_used() |> decimal_clamp_percent()
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{
         quota_scope: scope,
         active_limit: active_limit,
         credits: credits,
         used_percent: %Decimal{} = used_percent
       })
       when scope in ["model", "upstream_model"] and active_limit in [nil, 0] and
              credits in [nil, 0] do
    if Decimal.compare(used_percent, Decimal.new(0)) == :gt do
      used_percent |> remaining_percent_from_used() |> decimal_clamp_percent()
    end
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{} = window) do
    window
    |> Measurements.for_window()
    |> Map.get(:remaining_percent)
  end

  defp quota_percent_value(%Decimal{} = percent) do
    percent
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp quota_percent_value(_percent), do: 0

  defp quota_percent_label(%Decimal{} = percent), do: "#{quota_percent_value(percent)}%"
  defp quota_percent_label(_percent), do: "not reported"

  defp quota_count_label(%Quota.AccountQuotaWindow{
         quota_key: "account",
         quota_scope: "account",
         source: "codex_usage_api",
         credits: credits
       })
       when is_integer(credits) and credits >= 0 do
    "#{Formatting.format_integer(credits)} credits"
  end

  defp quota_count_label(%Quota.AccountQuotaWindow{
         quota_key: "account",
         quota_scope: "account",
         source: "codex_usage_api",
         credits: nil
       }),
       do: "credits not reported"

  defp quota_count_label(%Quota.AccountQuotaWindow{credits: credits, active_limit: active_limit})
       when is_integer(credits) and is_integer(active_limit) and active_limit > 0 do
    "#{Formatting.format_integer(credits)} / #{Formatting.format_integer(active_limit)} credits"
  end

  defp quota_count_label(%Quota.AccountQuotaWindow{credits: credits, active_limit: active_limit})
       when is_integer(credits) and credits > 0 and active_limit in [nil, 0] do
    "#{Formatting.format_integer(credits)} credits"
  end

  defp quota_count_label(%Quota.AccountQuotaWindow{
         active_limit: active_limit,
         used_percent: %Decimal{} = used_percent
       })
       when is_integer(active_limit) and active_limit > 0 do
    remaining =
      active_limit
      |> Decimal.new()
      |> Decimal.mult(Decimal.sub(Decimal.new(100), used_percent))
      |> Decimal.div(Decimal.new(100))
      |> decimal_non_negative()
      |> Decimal.round(0)
      |> Decimal.to_integer()

    "#{Formatting.format_integer(remaining)} / #{Formatting.format_integer(active_limit)} credits"
  end

  defp quota_count_label(%Quota.AccountQuotaWindow{used_percent: %Decimal{}}), do: nil

  defp quota_count_label(%Quota.AccountQuotaWindow{}), do: nil

  defp quota_count_title(
         %Quota.AccountQuotaWindow{
           quota_key: "account",
           quota_scope: "account",
           source: "codex_usage_api",
           credits: nil
         },
         "credits not reported",
         false
       ),
       do: "Credit balance was not reported for this quota sample."

  defp quota_count_title(
         %Quota.AccountQuotaWindow{
           quota_key: "account",
           quota_scope: "account",
           source: "codex_usage_api",
           credits: credits
         },
         count_label,
         burning_credits
       )
       when is_integer(credits) and is_binary(count_label) do
    cond do
      burning_credits ->
        "#{count_label}. Credit balance currently being consumed because included Codex quota is exhausted; it is not a currency amount."

      credits == 0 ->
        "#{count_label}. Credit balance is depleted; it is not a currency amount or a total capacity."

      true ->
        "#{count_label}. Credit balance is separate from included Codex quota remaining; it is not a currency amount."
    end
  end

  defp quota_count_title(_window, _count_label, _burning_credits), do: nil

  defp burning_credits?(%Quota.AccountQuotaWindow{
         quota_key: "account",
         quota_scope: "account",
         source: "codex_usage_api",
         credits: credits,
         used_percent: %Decimal{} = used_percent
       })
       when is_integer(credits) and credits > 0,
       do: Decimal.compare(used_percent, Decimal.new(100)) != :lt

  defp burning_credits?(_window), do: false

  defp quota_reset_presentation(window, evidence_state, datetime_preferences, snapshot_at) do
    {reset_semantics, reset_at, reset_label, reset_title} =
      case ModelWeeklyResetSemantics.classify(window) do
        :anchored ->
          anchored_reset_presentation(window.reset_at, datetime_preferences, snapshot_at)

        :floating ->
          {:floating, nil, "starts on use",
           "provider reports a rolling seven-day window until use starts"}

        :unknown ->
          {:unknown, nil, nil, nil}

        :not_applicable ->
          legacy_quota_reset_presentation(window, datetime_preferences, snapshot_at)
      end

    reset_display_presentation(
      reset_semantics,
      reset_at,
      reset_label,
      reset_title,
      evidence_state
    )
  end

  defp reset_display_presentation(:anchored, _reset_at, _reset_label, _reset_title, :stale) do
    {:anchored, :unconfirmed, nil, "reset unconfirmed",
     "last reported reset is unconfirmed because quota evidence is stale"}
  end

  defp reset_display_presentation(:anchored, reset_at, reset_label, reset_title, _evidence_state),
    do: {:anchored, :countdown, reset_at, reset_label, reset_title}

  defp reset_display_presentation(:floating, reset_at, reset_label, reset_title, _evidence_state),
    do: {:floating, :static, reset_at, reset_label, reset_title}

  defp reset_display_presentation(
         :unknown,
         _reset_at,
         _reset_label,
         _reset_title,
         _evidence_state
       ),
       do: {:unknown, :absent, nil, nil, nil}

  defp legacy_quota_reset_presentation(
         %Quota.AccountQuotaWindow{metadata: metadata, reset_at: reset_at},
         datetime_preferences,
         snapshot_at
       )
       when is_map(metadata) do
    case Map.fetch(metadata, "reset_state") do
      {:ok, "floating"} ->
        {:floating, reset_at, "starts on use",
         "provider reports a rolling seven-day window until use starts"}

      {:ok, "anchored"} ->
        anchored_reset_presentation(reset_at, datetime_preferences, snapshot_at)

      {:ok, _reset_state} ->
        {:unknown, reset_at, nil, nil}

      :error ->
        anchored_reset_presentation(reset_at, datetime_preferences, snapshot_at)
    end
  end

  defp legacy_quota_reset_presentation(
         %Quota.AccountQuotaWindow{reset_at: reset_at},
         datetime_preferences,
         snapshot_at
       ) do
    anchored_reset_presentation(reset_at, datetime_preferences, snapshot_at)
  end

  defp anchored_reset_presentation(
         %DateTime{} = reset_at,
         datetime_preferences,
         snapshot_at
       ) do
    {:anchored, reset_at, quota_reset_label(reset_at, snapshot_at),
     quota_reset_title(reset_at, datetime_preferences)}
  end

  defp anchored_reset_presentation(_reset_at, _datetime_preferences, _snapshot_at),
    do: {:unknown, nil, nil, nil}

  defp quota_reset_label(%DateTime{} = reset_at, %DateTime{} = snapshot_at) do
    seconds_until_reset = RelativeTime.seconds_until(reset_at, snapshot_at)

    if DateTime.compare(reset_at, snapshot_at) == :gt do
      "in #{Formatting.format_reset_duration(seconds_until_reset)}"
    else
      "due"
    end
  end

  defp quota_reset_title(%DateTime{} = reset_at, datetime_preferences) do
    "resets #{DateTimeDisplay.format_datetime(reset_at, datetime_preferences)}"
  end

  defp quota_evidence_state(%Quota.AccountQuotaWindow{} = window, snapshot_at) do
    case Evidence.current_freshness_state(window, snapshot_at) do
      "fresh" -> :fresh
      "stale" -> :stale
      _other -> :unknown
    end
  end

  defp quota_meter_state(:stale, %Decimal{} = remaining_percent) do
    if Decimal.compare(remaining_percent, Decimal.new(0)) == :gt do
      :historical
    else
      :historical_exhausted
    end
  end

  defp quota_meter_state(:stale, _remaining_percent), do: :historical
  defp quota_meter_state(:fresh, _remaining_percent), do: :current
  defp quota_meter_state(:unknown, _remaining_percent), do: :unknown

  defp freshness_presentation(:fresh), do: {"current", "evidence current"}

  defp freshness_presentation(:stale),
    do: {"last reported", "evidence stale; showing the last reported value"}

  defp freshness_presentation(:unknown),
    do: {"freshness unknown", "quota evidence freshness was not reported"}

  defp observed_presentation(
         %DateTime{} = observed_at,
         evidence_state,
         datetime_preferences,
         snapshot_at
       ) do
    prefix = if evidence_state == :stale, do: "last reported", else: "observed"

    {
      "#{prefix} #{Formatting.relative_time_label(observed_at, snapshot_at)}",
      "observed #{DateTimeDisplay.format_datetime(observed_at, datetime_preferences)}"
    }
  end

  defp observed_presentation(_observed_at, _evidence_state, _datetime_preferences, _snapshot_at),
    do: {"observed time not reported", nil}

  defp remaining_percent_from_used(%Decimal{} = used_percent) do
    Decimal.sub(Decimal.new(100), used_percent)
  end

  defp decimal_clamp_percent(%Decimal{} = value) do
    value
    |> decimal_non_negative()
    |> Decimal.min(Decimal.new(100))
  end

  defp decimal_non_negative(%Decimal{} = value), do: Decimal.max(value, Decimal.new(0))
end
