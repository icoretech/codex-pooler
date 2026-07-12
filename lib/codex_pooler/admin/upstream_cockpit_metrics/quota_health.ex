defmodule CodexPooler.Admin.UpstreamCockpitMetrics.QuotaHealth do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitMetrics
  alias CodexPooler.Admin.UpstreamCockpitMetrics.Common
  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Charts.Measurements
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @spec quota_health(
          Scope.t(),
          UpstreamCockpitMetrics.identity_ref(),
          [UpstreamCockpitMetrics.assignment_summary()],
          DateTime.t()
        ) :: UpstreamCockpitMetrics.quota_health()
  def quota_health(%Scope{} = scope, identity_or_id, assignments, %DateTime{} = as_of)
      when is_list(assignments) do
    pool_ids = Common.visible_pool_ids(scope)
    visible_assignments = Common.filter_assignments_by_pool_ids(assignments, pool_ids)

    windows = quota_windows(identity_or_id, visible_assignments, as_of)

    from_windows(identity_or_id, visible_assignments, windows, as_of)
  end

  @spec without_quota_data([UpstreamCockpitMetrics.assignment_summary()], DateTime.t()) ::
          UpstreamCockpitMetrics.quota_health()
  def without_quota_data(assignments, %DateTime{} = as_of) when is_list(assignments) do
    from_windows(nil, assignments, [], as_of)
  end

  defp quota_windows(_identity_or_id, [], _as_of), do: []

  defp quota_windows(identity_or_id, _visible_assignments, as_of) do
    identity_or_id
    |> Common.identity_id()
    |> QuotaWindows.list_quota_windows(as_of)
  end

  defp from_windows(identity_or_status, assignments, windows, as_of) do
    readiness = UpstreamQuotaReadiness.from_windows(windows, as_of)

    items =
      assignments
      |> Enum.map(&quota_health_item(&1, readiness, identity_or_status, as_of))
      |> Enum.sort_by(&{&1.pool_label, &1.assignment_label, &1.assignment_id})

    kpis = quota_health_kpis(items)

    %{
      key: :quota_health,
      title: "Quota health",
      items: items,
      kpis: kpis,
      empty?: items == [],
      degraded?: quota_health_degraded?(kpis),
      missing?:
        kpis.assignment_count > 0 and kpis.missing_evidence_count == kpis.assignment_count,
      state: quota_health_state(kpis)
    }
  end

  defp quota_health_item(assignment, readiness, identity_or_status, as_of) do
    routing_readiness = Common.routing_readiness(identity_or_status, assignment, readiness)
    primary_5h = classified_window(readiness.primary_window, :primary_5h)
    primary_30d = readiness.primary_30d_window
    weekly = readiness.weekly_window
    state = quota_assignment_state(readiness)
    display_window = primary_5h || primary_30d || weekly
    measurements = quota_measurements(display_window)

    %{}
    |> Map.merge(
      Map.take(assignment, [:upstream_identity_id, :pool_id, :pool_label, :assignment_label])
    )
    |> Map.put(:assignment_id, assignment.id)
    |> Map.put(:state, state)
    |> Map.put(:state_label, quota_state_label(state))
    |> Map.put(:routing_usable?, routing_readiness.routing_ready_now?)
    |> Map.merge(Common.routing_readiness_contract(routing_readiness))
    |> Map.put(:window_kind, display_window && display_window.window_kind)
    |> Map.put(:window_minutes, display_window && display_window.window_minutes)
    |> Map.put(:reset_at, display_window && display_window.reset_at)
    |> Map.put(:freshness_state, quota_freshness_state(display_window, as_of))
    |> Map.put(:reason_codes, quota_reason_codes(readiness.reason_codes, routing_readiness))
    |> Map.put(:remaining, measurements.remaining)
    |> Map.put(:capacity, measurements.capacity)
    |> Map.put(:used, measurements.used)
    |> Map.put(:used_percent, measurements.used_percent)
    |> Map.put(:used_percent_value, Common.decimal_to_float(measurements.used_percent))
    |> Map.put(:remaining_percent, measurements.remaining_percent)
    |> Map.put(:remaining_percent_value, Common.decimal_to_float(measurements.remaining_percent))
    |> Map.put(:bar_value, Common.decimal_to_float(measurements.remaining_percent) || 0.0)
    |> Map.put(:primary_5h, quota_window_contract(primary_5h, as_of))
    |> Map.put(:primary_30d, quota_window_contract(primary_30d, as_of))
    |> Map.put(:weekly, quota_window_contract(weekly, as_of))
  end

  defp classified_window(%Quota.AccountQuotaWindow{} = window, descriptor) do
    if WindowClassifier.classify(window) == descriptor, do: window, else: nil
  end

  defp classified_window(_window, _descriptor), do: nil

  defp quota_health_kpis(items) do
    counts = Enum.frequencies_by(items, & &1.state)

    %{}
    |> Map.put(:assignment_count, length(items))
    |> Map.put(:routing_usable_count, Enum.count(items, & &1.routing_usable?))
    |> Map.put(:fresh_count, Map.get(counts, "fresh", 0))
    |> Map.put(:stale_count, Map.get(counts, "stale", 0))
    |> Map.put(:missing_evidence_count, Map.get(counts, "missing_evidence", 0))
    |> Map.put(:exhausted_count, Map.get(counts, "exhausted", 0))
    |> Map.put(:blocked_count, Map.get(counts, "blocked", 0))
    |> Map.put(:weekly_only_count, Map.get(counts, "weekly_only", 0))
    |> then(fn kpis ->
      Map.put(
        kpis,
        :stale_or_missing_count,
        kpis.stale_count + kpis.missing_evidence_count
      )
    end)
  end

  defp quota_health_degraded?(kpis) do
    kpis.stale_or_missing_count > 0 or kpis.exhausted_count > 0 or kpis.blocked_count > 0 or
      kpis.routing_usable_count < kpis.assignment_count
  end

  defp quota_health_state(%{assignment_count: 0}), do: "empty"

  defp quota_health_state(%{blocked_count: blocked}) when blocked > 0, do: "blocked"

  defp quota_health_state(%{exhausted_count: exhausted}) when exhausted > 0, do: "exhausted"

  defp quota_health_state(%{stale_count: stale}) when stale > 0, do: "stale"

  defp quota_health_state(%{missing_evidence_count: missing}) when missing > 0,
    do: "missing_evidence"

  defp quota_health_state(%{assignment_count: count, fresh_count: count, weekly_only_count: 0}),
    do: "fresh"

  defp quota_health_state(%{assignment_count: count, weekly_only_count: count}), do: "weekly_only"
  defp quota_health_state(%{routing_usable_count: usable}) when usable > 0, do: "partial"

  defp quota_health_state(_kpis), do: "unknown"

  defp quota_assignment_state(%{state: "ready"}), do: "fresh"
  defp quota_assignment_state(%{state: "weekly_only_probe"}), do: "weekly_only"
  defp quota_assignment_state(%{state: state}), do: state

  defp quota_measurements(%Quota.AccountQuotaWindow{} = window),
    do: Measurements.for_window(window)

  defp quota_measurements(_window),
    do: %{remaining: nil, capacity: nil, used: nil, used_percent: nil, remaining_percent: nil}

  defp quota_window_contract(nil, _as_of), do: nil

  defp quota_window_contract(%Quota.AccountQuotaWindow{} = window, as_of) do
    measurements = Measurements.for_window(window)

    %{
      window_kind: window.window_kind,
      window_minutes: window.window_minutes,
      reset_at: window.reset_at,
      freshness_state: quota_freshness_state(window, as_of),
      routing_usable?: QuotaWindows.usable_window?(window, as_of),
      remaining_percent_value: Common.decimal_to_float(measurements.remaining_percent),
      used_percent_value: Common.decimal_to_float(measurements.used_percent),
      reason_codes: QuotaWindows.routing_window_reason_codes(window, as_of)
    }
  end

  defp quota_freshness_state(%Quota.AccountQuotaWindow{} = window, as_of),
    do: Evidence.current_freshness_state(window, as_of)

  defp quota_freshness_state(_window, _as_of), do: "missing"

  defp quota_state_label("fresh"), do: "Fresh"
  defp quota_state_label("stale"), do: "Stale"
  defp quota_state_label("exhausted"), do: "Exhausted"
  defp quota_state_label("blocked"), do: "Blocked"
  defp quota_state_label("weekly_only"), do: "Weekly-only"
  defp quota_state_label("missing_evidence"), do: "Missing evidence"
  defp quota_state_label(state), do: String.replace(state, "_", " ")

  defp quota_reason_codes(quota_reason_codes, %{routing_ready_now?: true}), do: quota_reason_codes
  defp quota_reason_codes(quota_reason_codes, %{state: "quota_blocked"}), do: quota_reason_codes

  defp quota_reason_codes(quota_reason_codes, %{reason_code: reason_code})
       when is_binary(reason_code) do
    [reason_code | quota_reason_codes]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
