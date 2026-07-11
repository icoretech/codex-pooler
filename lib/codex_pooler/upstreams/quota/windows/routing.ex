defmodule CodexPooler.Upstreams.Quota.Windows.Routing do
  @moduledoc false

  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.WindowSelector

  @fresh "fresh"
  @account_quota_key "account"

  @spec selection_data_from_windows([Quota.AccountQuotaWindow.t()], keyword()) :: map()
  def selection_data_from_windows(windows, opts \\ []) when is_list(windows) do
    timestamp = Keyword.get(opts, :at, now())

    routing_windows =
      windows
      |> Enum.filter(&window_in_model_scope?(&1, opts))
      |> WindowSelector.logical_windows(timestamp)
      |> select_current_account_primary_variant(timestamp)

    %{
      windows: windows,
      routing_windows: routing_windows,
      primary: WindowSelector.best_account_primary_variant(routing_windows, timestamp),
      secondary:
        WindowSelector.best_account_window(routing_windows, :weekly_secondary, timestamp),
      fresh_windows: Enum.filter(routing_windows, &fresh_window?(&1, timestamp)),
      blocked_windows: Enum.reject(routing_windows, &usable_window?(&1, timestamp)),
      usable?: Enum.any?(routing_windows, &usable_window?(&1, timestamp))
    }
  end

  @spec eligibility_from_windows([Quota.AccountQuotaWindow.t()], keyword()) :: map()
  def eligibility_from_windows(windows, opts \\ []) when is_list(windows) do
    windows
    |> selection_data_from_windows(opts)
    |> eligibility_from_selection(opts)
  end

  @spec eligibility_from_selection(map(), keyword()) :: map()
  def eligibility_from_selection(selection, opts) when is_map(selection) and is_list(opts) do
    timestamp = Keyword.get(opts, :at, now())
    routing_state = routing_quota_state(selection, timestamp)

    eligible? = routing_quota_eligible?(routing_state)

    %{
      eligible?: eligible?,
      routing_state: routing_state,
      warnings: quota_routing_warnings(selection, timestamp, routing_state),
      selection: selection,
      exclusions: quota_routing_exclusions(selection, timestamp, eligible?)
    }
  end

  @spec fresh_window?(Quota.AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def fresh_window?(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    Evidence.current_freshness_state(window, timestamp) == @fresh
  end

  @spec usable_window?(Quota.AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    fresh_window?(window, timestamp) and not exhausted?(window) and
      Evidence.reset_bearing?(window) and
      not Evidence.expired?(window, timestamp)
  end

  @spec usable_window?(Quota.AccountQuotaWindow.t(), DateTime.t(), keyword()) :: boolean()
  def usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp, opts) when is_list(opts) do
    usable_window?(window, timestamp) and window_in_model_scope?(window, opts)
  end

  @spec window_exclusion(Quota.AccountQuotaWindow.t(), DateTime.t()) :: map()
  def window_exclusion(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    %{
      code: "quota_window_unusable",
      reason_codes: window_reason_codes(window, timestamp),
      quota_key: window.quota_key,
      window_kind: window.window_kind,
      quota_scope: window.quota_scope,
      quota_family: window.quota_family,
      model: window.model,
      upstream_model: window.upstream_model,
      source: window.source,
      source_precision: window.source_precision,
      freshness_state: Evidence.current_freshness_state(window, timestamp),
      reset_at: iso8601_or_nil(window.reset_at)
    }
  end

  @spec window_reason_codes(Quota.AccountQuotaWindow.t(), DateTime.t()) :: [String.t()]
  def window_reason_codes(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    []
    |> maybe_add_reason(not Evidence.reset_bearing?(window), "reset_missing")
    |> maybe_add_reason(Evidence.expired?(window, timestamp), "expired")
    |> maybe_add_reason(
      Evidence.current_freshness_state(window, timestamp) != @fresh,
      "not_fresh"
    )
    |> maybe_add_reason(exhausted?(window), "exhausted")
    |> case do
      [] -> ["unknown_unusable"]
      reasons -> Enum.reverse(reasons)
    end
  end

  defp routing_quota_state(
         %{primary: %Quota.AccountQuotaWindow{}, blocked_windows: []},
         _timestamp
       ),
       do: :precise

  defp routing_quota_state(selection, timestamp) do
    cond do
      credit_backed_probe_selection?(selection, timestamp) -> :credit_backed_probe
      weekly_only_probe_selection?(selection, timestamp) -> :weekly_only_probe
      true -> :blocked
    end
  end

  defp routing_quota_eligible?(state)
       when state in [:precise, :credit_backed_probe, :weekly_only_probe],
       do: true

  defp routing_quota_eligible?(_state), do: false

  defp credit_backed_probe_selection?(
         %{secondary: %Quota.AccountQuotaWindow{} = secondary, blocked_windows: blocked_windows},
         timestamp
       ) do
    credit_backed_secondary_window?(secondary, timestamp) and
      Enum.any?(blocked_windows, &credit_backed_secondary_window?(&1, timestamp)) and
      Enum.all?(blocked_windows, &credit_backed_secondary_window?(&1, timestamp))
  end

  defp credit_backed_probe_selection?(_selection, _timestamp), do: false

  defp weekly_only_probe_selection?(
         %{primary: nil, secondary: %Quota.AccountQuotaWindow{} = secondary} = selection,
         timestamp
       ) do
    not Enum.any?(selection.blocked_windows, &weekly_probe_blocking_window?/1) and
      account_weekly_window?(secondary) and
      weekly_probe_usable_window?(secondary, timestamp)
  end

  defp weekly_only_probe_selection?(_selection, _timestamp), do: false

  defp weekly_probe_blocking_window?(%Quota.AccountQuotaWindow{quota_scope: scope} = window)
       when scope in ["model", "upstream_model"] do
    window.window_kind == "primary"
  end

  defp weekly_probe_blocking_window?(%Quota.AccountQuotaWindow{} = window),
    do: account_primary_window?(window)

  defp account_weekly_window?(%Quota.AccountQuotaWindow{} = window) do
    quota_scope = window.quota_scope || "account"
    quota_family = window.quota_family || "account"

    window.quota_key == @account_quota_key and quota_scope == "account" and
      quota_family in ["account", "secondary"] and window.window_kind == "secondary" and
      window.window_minutes == 10_080
  end

  defp weekly_probe_usable_window?(
         %Quota.AccountQuotaWindow{source_precision: source_precision} = window,
         timestamp
       )
       when source_precision in ["observed", "authoritative"] do
    Evidence.reset_bearing?(window) and not exhausted?(window) and
      not Evidence.expired?(window, timestamp)
  end

  defp weekly_probe_usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp),
    do: usable_window?(window, timestamp)

  defp credit_backed_secondary_window?(%Quota.AccountQuotaWindow{} = window, timestamp) do
    account_weekly_window?(window) and fresh_window?(window, timestamp) and
      Evidence.reset_bearing?(window) and not Evidence.expired?(window, timestamp) and
      exhausted_by_used_percent?(window) and positive_credits?(window)
  end

  defp account_primary_window?(%Quota.AccountQuotaWindow{} = window) do
    WindowClassifier.primary_5h?(window) or WindowClassifier.monthly_primary?(window)
  end

  defp select_current_account_primary_variant(routing_windows, timestamp) do
    case routing_windows
         |> Enum.filter(&(account_primary_window?(&1) and usable_window?(&1, timestamp))) do
      [] ->
        routing_windows

      usable_primary_windows ->
        current_primary =
          WindowSelector.best_account_primary_variant(usable_primary_windows, timestamp)

        Enum.reject(routing_windows, fn window ->
          account_primary_window?(window) and window != current_primary
        end)
    end
  end

  defp quota_routing_warnings(selection, _timestamp, :weekly_only_probe) do
    secondary = selection.secondary

    [
      %{
        code: "quota_account_primary_unknown",
        message:
          "weekly quota is usable, but upstream has not supplied account primary 5h quota evidence",
        quota_key: secondary.quota_key,
        window_kind: secondary.window_kind,
        quota_scope: secondary.quota_scope,
        quota_family: secondary.quota_family,
        source: secondary.source,
        source_precision: secondary.source_precision,
        freshness_state: secondary.freshness_state,
        reset_at: secondary.reset_at
      }
    ]
  end

  defp quota_routing_warnings(_selection, _timestamp, _state), do: []

  defp quota_routing_exclusions(_selection, _timestamp, true), do: []

  defp quota_routing_exclusions(%{windows: []}, _timestamp, false) do
    [
      %{
        code: "quota_evidence_missing",
        message: "no quota evidence has been recorded for this upstream identity"
      }
    ]
  end

  defp quota_routing_exclusions(%{routing_windows: []}, _timestamp, false) do
    [
      %{
        code: "quota_evidence_out_of_scope",
        message: "recorded quota evidence does not match the requested model scope"
      }
    ]
  end

  defp quota_routing_exclusions(
         %{primary: nil, secondary: %Quota.AccountQuotaWindow{} = secondary},
         timestamp,
         false
       ) do
    if exhausted?(secondary) do
      [quota_exhausted_exclusion(secondary, timestamp)]
    else
      quota_primary_missing_exclusion()
    end
  end

  defp quota_routing_exclusions(%{primary: nil, routing_windows: [_ | _]}, _timestamp, false) do
    quota_primary_missing_exclusion()
  end

  defp quota_routing_exclusions(%{blocked_windows: blocked_windows}, timestamp, false)
       when is_list(blocked_windows) do
    case blocked_windows do
      [] ->
        [
          %{
            code: "quota_evidence_unusable",
            message: "recorded quota evidence is not usable for routing"
          }
        ]

      windows ->
        Enum.map(windows, &window_exclusion(&1, timestamp))
    end
  end

  defp quota_primary_missing_exclusion do
    [
      %{
        code: "quota_account_primary_missing",
        message: "account primary quota evidence is required for routing"
      }
    ]
  end

  defp quota_exhausted_exclusion(%Quota.AccountQuotaWindow{} = window, timestamp) do
    window
    |> window_exclusion(timestamp)
    |> Map.merge(%{
      code: "quota_weekly_exhausted",
      message: "weekly quota is exhausted until reset"
    })
  end

  defp window_in_model_scope?(%Quota.AccountQuotaWindow{quota_scope: "model"} = window, opts) do
    case model_candidates(opts) do
      [] ->
        true

      candidates ->
        Enum.any?(candidates, fn candidate ->
          same_optional_token?(candidate, window.model) or
            same_optional_token?(candidate, window.upstream_model)
        end)
    end
  end

  defp window_in_model_scope?(
         %Quota.AccountQuotaWindow{quota_scope: "upstream_model"} = window,
         opts
       ) do
    case upstream_model_candidates(opts) do
      [] -> true
      candidates -> Enum.any?(candidates, &same_optional_token?(&1, window.upstream_model))
    end
  end

  defp window_in_model_scope?(%Quota.AccountQuotaWindow{}, _opts), do: true

  defp model_candidates(opts) do
    opts
    |> Keyword.take([:model, :requested_model, :catalog_model, :exposed_model_id])
    |> Keyword.values()
    |> Kernel.++(upstream_model_candidates(opts))
    |> Enum.map(&normalize_optional_quota_scope_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp upstream_model_candidates(opts) do
    opts
    |> Keyword.take([:upstream_model, :upstream_model_id])
    |> Keyword.values()
    |> Enum.map(&normalize_optional_quota_scope_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp same_optional_token?(left, right) do
    not is_nil(left) and left == normalize_optional_quota_scope_value(right)
  end

  defp normalize_optional_quota_scope_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.downcase(value)
    end
  end

  defp normalize_optional_quota_scope_value(_value), do: nil

  defp exhausted_by_used_percent?(%Quota.AccountQuotaWindow{
         used_percent: %Decimal{} = used_percent
       }) do
    Decimal.compare(used_percent, Decimal.new(100)) != :lt
  end

  defp exhausted_by_used_percent?(_window), do: false

  defp positive_credits?(%Quota.AccountQuotaWindow{credits: credits}) when is_integer(credits),
    do: credits > 0

  defp positive_credits?(_window), do: false

  defp exhausted?(%Quota.AccountQuotaWindow{credits: credits} = window)
       when is_integer(credits) and credits > 0 do
    if WindowClassifier.monthly_primary?(window),
      do: false,
      else: exhausted_by_used_percent?(window)
  end

  defp exhausted?(%Quota.AccountQuotaWindow{used_percent: %Decimal{}} = window) do
    exhausted_by_used_percent?(window)
  end

  defp exhausted?(%Quota.AccountQuotaWindow{active_limit: 0}), do: true
  defp exhausted?(%Quota.AccountQuotaWindow{credits: 0}), do: true
  defp exhausted?(_window), do: false

  defp maybe_add_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp iso8601_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601_or_nil(_datetime), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
