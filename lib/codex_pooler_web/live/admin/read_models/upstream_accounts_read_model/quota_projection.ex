defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection do
  @moduledoc false

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Upstreams.Quota
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting
  alias CodexPoolerWeb.DateTimeDisplay

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

  @type quota_limit_row :: %{
          required(:key) => atom() | String.t(),
          required(:label) => String.t(),
          required(:percent) => Decimal.t() | nil,
          required(:percent_value) => number(),
          required(:percent_label) => String.t(),
          required(:count_label) => String.t() | nil,
          required(:reset_label) => String.t() | nil,
          required(:reset_title) => String.t() | nil
        }

  @spec readiness([Quota.AccountQuotaWindow.t()]) :: UpstreamQuotaReadiness.t()
  def readiness(windows) when is_list(windows) do
    UpstreamQuotaReadiness.from_windows(windows)
  end

  @spec assignment_priming_status(map()) :: String.t()
  def assignment_priming_status(%{metadata: %{"quota_priming" => %{"status" => status}}})
      when is_binary(status),
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
  def put_current_quota_priming(assignment, %{state: "ready"}) do
    put_quota_priming(assignment, "known")
  end

  def put_current_quota_priming(assignment, %{state: "weekly_only_probe"}) do
    put_quota_priming(assignment, "weekly_only_probe")
  end

  def put_current_quota_priming(assignment, _quota_readiness), do: assignment

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

  @spec quota_limit_rows([Quota.AccountQuotaWindow.t()], DateTimeDisplay.preferences()) :: [
          quota_limit_row()
        ]
  def quota_limit_rows(windows, datetime_preferences) when is_list(windows) do
    additional_limits =
      windows
      |> Enum.reject(&account_quota_window?/1)
      |> Enum.sort_by(&quota_limit_sort_key/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {window, index} ->
        quota_limit_row(
          quota_limit_key(window, index),
          quota_limit_label(window),
          window,
          datetime_preferences
        )
      end)

    [
      quota_limit_row(
        :primary_5h,
        "5h",
        quota_account_window(windows, :primary_5h),
        datetime_preferences
      ),
      quota_limit_row(
        :primary_30d,
        "30d",
        quota_account_window(windows, :monthly_primary),
        datetime_preferences
      ),
      quota_limit_row(
        :weekly,
        "Weekly",
        quota_account_window(windows, "secondary", nil),
        datetime_preferences
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

  defp quota_account_window(windows, descriptor) do
    Enum.find(windows, &(WindowClassifier.classify(&1) == descriptor))
  end

  defp quota_account_window(windows, "secondary", nil) do
    Enum.find(windows, fn
      %Quota.AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        window_kind: "secondary"
      } ->
        true

      _window ->
        false
    end)
  end

  defp quota_limit_sort_key(%Quota.AccountQuotaWindow{} = window) do
    {
      quota_scope_sort_value(window.quota_scope),
      quota_limit_label(window),
      window.window_kind,
      window.window_minutes || 0,
      window.quota_key
    }
  end

  defp quota_scope_sort_value("model"), do: 0
  defp quota_scope_sort_value("upstream_model"), do: 1
  defp quota_scope_sort_value("feature"), do: 2
  defp quota_scope_sort_value(_scope), do: 3

  defp quota_limit_key(%Quota.AccountQuotaWindow{} = window, index) do
    [window.quota_scope, window.quota_key, window.window_kind, window.window_minutes || index]
    |> Enum.join("-")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
  end

  defp quota_limit_label(%Quota.AccountQuotaWindow{} = window) do
    base_label =
      [
        window.display_label,
        window.model,
        window.upstream_model,
        window.limit_name,
        window.raw_limit_name,
        window.metered_feature,
        window.quota_key
      ]
      |> Enum.find(&Formatting.present_string?/1)
      |> humanize_quota_label()

    "#{base_label} #{quota_window_label(window)}"
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

  defp quota_limit_row(key, label, %Quota.AccountQuotaWindow{} = window, datetime_preferences) do
    remaining_percent = quota_remaining_percent(window)

    %{
      key: key,
      label: label,
      percent: remaining_percent,
      percent_value: quota_percent_value(remaining_percent),
      percent_label: quota_percent_label(remaining_percent),
      count_label: quota_count_label(window),
      reset_label: quota_reset_label(window.reset_at),
      reset_title: quota_reset_title(window.reset_at, datetime_preferences)
    }
  end

  defp quota_limit_row(key, label, nil, _datetime_preferences) do
    %{
      key: key,
      label: label,
      percent: nil,
      percent_value: 0,
      percent_label: "not reported",
      count_label: nil,
      reset_label: nil,
      reset_title: nil
    }
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{
         credits: credits,
         active_limit: active_limit
       })
       when is_integer(credits) and is_integer(active_limit) and active_limit > 0 do
    credits
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.div(Decimal.new(active_limit))
    |> decimal_clamp_percent()
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{
         used_percent: %Decimal{} = used_percent
       }) do
    Decimal.new(100)
    |> Decimal.sub(used_percent)
    |> decimal_clamp_percent()
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{}), do: nil

  defp quota_percent_value(%Decimal{} = percent) do
    percent
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp quota_percent_value(_percent), do: 0

  defp quota_percent_label(%Decimal{} = percent), do: "#{quota_percent_value(percent)}%"
  defp quota_percent_label(_percent), do: "not reported"

  defp quota_count_label(%Quota.AccountQuotaWindow{credits: credits, active_limit: active_limit})
       when is_integer(credits) and is_integer(active_limit) and active_limit > 0 do
    "#{Formatting.format_integer(credits)} / #{Formatting.format_integer(active_limit)} credits"
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

  defp quota_reset_label(%DateTime{} = reset_at) do
    seconds_until_reset = DateTime.diff(reset_at, DateTime.utc_now(), :second)

    if seconds_until_reset > 0 do
      "in #{Formatting.format_reset_duration(seconds_until_reset)}"
    else
      "due"
    end
  end

  defp quota_reset_label(_reset_at), do: nil

  defp quota_reset_title(%DateTime{} = reset_at, datetime_preferences) do
    "resets #{DateTimeDisplay.format_datetime(reset_at, datetime_preferences)}"
  end

  defp quota_reset_title(_reset_at, _datetime_preferences), do: nil

  defp decimal_clamp_percent(%Decimal{} = value) do
    value
    |> decimal_non_negative()
    |> Decimal.min(Decimal.new(100))
  end

  defp decimal_non_negative(%Decimal{} = value), do: Decimal.max(value, Decimal.new(0))
end
