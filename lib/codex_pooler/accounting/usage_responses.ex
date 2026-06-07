defmodule CodexPooler.Accounting.UsageResponses do
  @moduledoc """
  Codex-compatible usage-limit response shaping for accounting reads.
  """

  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Upstreams.Quota

  @spec self_usage_limits([map()], integer(), integer(), integer(), DateTime.t()) :: [map()]
  def self_usage_limits(bindings, minute_requests, daily_tokens, weekly_tokens, as_of) do
    minute_reset = as_of |> DateTime.truncate(:second) |> DateTime.add(60, :second)
    daily_reset = as_of |> beginning_of_day() |> DateTime.add(1, :day)
    weekly_reset = as_of |> DateTime.truncate(:second) |> DateTime.add(7, :day)

    bindings
    |> Enum.filter(&(&1.binding_scope == "default" and is_nil(&1.model_identifier)))
    |> Enum.flat_map(fn binding ->
      []
      |> maybe_add_limit(
        binding.max_requests_per_minute,
        "request_count",
        "minute",
        minute_requests,
        minute_reset,
        "api_key_limit",
        nil
      )
      |> maybe_add_limit(
        binding.max_tokens_per_day,
        "total_tokens",
        "daily",
        daily_tokens,
        daily_reset,
        "api_key_limit",
        nil
      )
      |> maybe_add_limit(
        binding.max_tokens_per_day,
        "credits",
        "daily",
        daily_tokens,
        daily_reset,
        "api_key_compatibility",
        nil
      )
      |> maybe_add_limit(
        binding.max_tokens_per_week,
        "total_tokens",
        "weekly",
        weekly_tokens,
        weekly_reset,
        "api_key_limit",
        nil
      )
    end)
    |> Enum.sort_by(&{&1.limit_window, &1.limit_type, &1.source})
  end

  @spec account_usage_windows([Quota.AccountQuotaWindow.t()], DateTime.t()) ::
          {map() | nil, map() | nil}
  def account_usage_windows(windows, as_of) do
    primary =
      windows
      |> Enum.find(&(&1.quota_key == "account" and &1.window_kind == "primary"))
      |> codex_limit_from_quota_window(as_of)

    secondary =
      windows
      |> Enum.find(&(&1.quota_key == "account" and &1.window_kind == "secondary"))
      |> codex_limit_from_quota_window(as_of)

    {primary, secondary}
  end

  @spec codex_rate_limit(map() | nil, map() | nil) :: map()
  def codex_rate_limit(primary, secondary) do
    preferred = secondary || primary

    %{
      allowed: is_nil(preferred) or codex_limit_allowed?(preferred),
      limit_reached: not is_nil(preferred) and not codex_limit_allowed?(preferred),
      primary_window: codex_window_snapshot(primary),
      secondary_window: codex_window_snapshot(secondary)
    }
  end

  @spec codex_credits(map() | nil, map() | nil) :: map() | nil
  def codex_credits(primary, secondary) do
    preferred = secondary || primary

    cond do
      is_nil(preferred) ->
        nil

      is_integer(preferred.remaining_value) ->
        %{
          has_credits: preferred.remaining_value > 0,
          unlimited: false,
          balance: Integer.to_string(max(preferred.remaining_value, 0))
        }

      true ->
        %{
          has_credits: codex_limit_allowed?(preferred),
          unlimited: false,
          balance: nil
        }
    end
  end

  @spec additional_codex_rate_limits([Quota.AccountQuotaWindow.t()], DateTime.t()) :: [map()]
  def additional_codex_rate_limits(windows, as_of) do
    windows
    |> Enum.reject(&(&1.quota_key in [nil, "account"]))
    |> Enum.group_by(& &1.quota_key)
    |> Enum.map(fn {quota_key, quota_windows} ->
      primary =
        quota_windows
        |> Enum.find(&(&1.window_kind == "primary"))
        |> codex_limit_from_quota_window(as_of)

      secondary =
        quota_windows
        |> Enum.find(&(&1.window_kind == "secondary"))
        |> codex_limit_from_quota_window(as_of)

      representative = List.first(quota_windows)

      %{
        quota_key: quota_key,
        limit_name: representative.display_label || representative.limit_name || quota_key,
        display_label: representative.display_label || representative.limit_name || quota_key,
        metered_feature: representative.metered_feature,
        rate_limit: codex_rate_limit(primary, secondary)
      }
    end)
  end

  def codex_limit_allowed?(%{remaining_value: remaining}) when is_integer(remaining),
    do: remaining > 0

  def codex_limit_allowed?(%{used_percent: percent}) when is_integer(percent), do: percent < 100
  def codex_limit_allowed?(_limit), do: true

  defp maybe_add_limit(limits, nil, _type, _window, _current, _reset, _source, _model), do: limits

  defp maybe_add_limit(limits, max_value, type, window, current, reset, source, model) do
    max_value = decimal_to_integer(max_value)
    current = min(decimal_to_integer(current), max_value)

    limits ++
      [
        %{
          limit_type: type,
          limit_window: window,
          max_value: max_value,
          current_value: current,
          remaining_value: max(max_value - current, 0),
          model_filter: model,
          reset_at: DateTime.to_iso8601(reset),
          source: source
        }
      ]
  end

  defp codex_limit_from_quota_window(nil, _as_of), do: nil

  # Reason: quota compatibility payload depends on several optional evidence fields.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp codex_limit_from_quota_window(%Quota.AccountQuotaWindow{} = window, _as_of) do
    active_limit = window.active_limit
    limit_window = limit_window_label(window)
    used_percent = percent_integer(window.used_percent)
    reset_at = window.reset_at && DateTime.to_iso8601(window.reset_at)

    if is_nil(active_limit) || active_limit <= 0 do
      if is_nil(used_percent) do
        nil
      else
        %{
          limit_type: "percent",
          limit_window: limit_window,
          max_value: nil,
          current_value: nil,
          remaining_value: nil,
          used_percent: used_percent,
          reset_at: reset_at,
          source: window.source
        }
      end
    else
      current =
        cond do
          is_integer(window.credits) ->
            active_limit - max(window.credits, 0)

          match?(%Decimal{}, window.used_percent) ->
            Decimal.mult(
              Decimal.new(active_limit),
              Decimal.div(window.used_percent, Decimal.new(100))
            )
            |> Decimal.round(0)
            |> decimal_to_integer()

          true ->
            0
        end

      %{
        limit_type: "credits",
        limit_window: limit_window,
        max_value: active_limit,
        current_value: min(max(current, 0), active_limit),
        remaining_value: max(active_limit - min(max(current, 0), active_limit), 0),
        used_percent: used_percent,
        reset_at: reset_at,
        source: window.source
      }
    end
  end

  defp codex_window_snapshot(nil), do: nil

  defp codex_window_snapshot(limit) do
    reset_at =
      limit.reset_at &&
        DateTime.from_iso8601(limit.reset_at)
        |> case do
          {:ok, dt, _} -> dt
          _ -> nil
        end

    %{
      used_percent:
        if(is_integer(limit.max_value) and limit.max_value > 0,
          do: div(limit.current_value * 100 + div(limit.max_value, 2), limit.max_value),
          else: limit.used_percent || 0
        ),
      limit_window_seconds: window_seconds(limit.limit_window),
      reset_after_seconds:
        if(reset_at, do: max(DateTime.diff(reset_at, now(), :second), 0), else: nil),
      reset_at: if(reset_at, do: DateTime.to_unix(reset_at), else: nil)
    }
  end

  defp limit_window_label(%Quota.AccountQuotaWindow{} = window) do
    case WindowClassifier.classify(window) do
      :primary_5h -> "5h"
      :weekly_secondary -> "7d"
      :monthly_primary -> "30d"
      _descriptor -> duration_label(window.window_minutes)
    end
  end

  defp duration_label(minutes) when is_integer(minutes) and minutes > 0 do
    cond do
      rem(minutes, 1_440) == 0 -> "#{div(minutes, 1_440)}d"
      rem(minutes, 60) == 0 -> "#{div(minutes, 60)}h"
      true -> "#{minutes}m"
    end
  end

  defp duration_label(_minutes), do: "unknown"

  defp percent_integer(%Decimal{} = percent) do
    percent
    |> Decimal.round(0)
    |> decimal_to_integer()
    |> min(100)
    |> max(0)
  end

  defp percent_integer(_percent), do: nil

  defp beginning_of_day(datetime) do
    datetime |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp decimal_to_integer(nil), do: 0

  defp decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp decimal_to_integer(value) when is_integer(value), do: value

  defp decimal_to_integer(value) when is_binary(value),
    do: value |> Decimal.new() |> decimal_to_integer()

  defp window_seconds("5h"), do: 18_000
  defp window_seconds("7d"), do: 604_800
  defp window_seconds("30d"), do: 2_592_000
  defp window_seconds("daily"), do: 86_400
  defp window_seconds(window) when is_binary(window), do: duration_seconds(window)
  defp window_seconds(_), do: 0

  defp duration_seconds(window) do
    with {amount, suffix} <- Integer.parse(window),
         true <- amount > 0 do
      case suffix do
        "m" -> amount * 60
        "h" -> amount * 3_600
        "d" -> amount * 86_400
        _suffix -> 0
      end
    else
      _invalid -> 0
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
