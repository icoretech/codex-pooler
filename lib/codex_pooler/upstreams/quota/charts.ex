defmodule CodexPooler.Upstreams.Quota.Charts do
  @moduledoc """
  Read-only quota chart and capacity summaries for admin surfaces.
  """

  import Ecto.Query

  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.{
    Quota,
    Quota.Charts.Measurements
  }

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @account_quota_key "account"
  @deleted "deleted"
  @fresh "fresh"

  @spec quota_capacity_summary_by_pool_ids([term()] | term()) :: %{
          optional(Ecto.UUID.t()) => map()
        }
  def quota_capacity_summary_by_pool_ids(pool_ids) when is_list(pool_ids) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    memberships =
      case pool_ids do
        [] ->
          []

        _ ->
          Repo.all(
            from assignment in PoolUpstreamAssignment,
              where: assignment.pool_id in ^pool_ids and assignment.status != ^@deleted,
              select: {assignment.pool_id, assignment.upstream_identity_id}
          )
      end

    windows_by_identity =
      memberships
      |> Enum.map(fn {_pool_id, identity_id} -> identity_id end)
      |> QuotaWindows.list_quota_windows_by_identity_ids()

    rows =
      for {pool_id, identity_id} <- memberships,
          window <- Map.get(windows_by_identity, identity_id, []) do
        {pool_id, window.used_percent, window.reset_at, window.freshness_state}
      end

    summaries =
      rows
      |> Enum.group_by(fn {pool_id, _used_percent, _reset_at, _freshness_state} -> pool_id end)
      |> Map.new(fn {pool_id, window_rows} -> {pool_id, quota_capacity_summary(window_rows)} end)

    Enum.into(pool_ids, %{}, fn pool_id ->
      {pool_id, Map.get(summaries, pool_id, quota_capacity_summary([]))}
    end)
  end

  def quota_capacity_summary_by_pool_ids(_pool_ids), do: %{}

  @spec quota_remaining_charts_by_pool_ids([term()] | term(), keyword()) ::
          %{optional(Ecto.UUID.t()) => map()}
  def quota_remaining_charts_by_pool_ids(pool_ids, opts \\ [])

  def quota_remaining_charts_by_pool_ids(pool_ids, opts) when is_list(pool_ids) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    timestamp = Keyword.get(opts, :at, now())

    rows = quota_remaining_chart_rows(pool_ids, timestamp)

    charts_by_pool_id =
      rows
      |> Enum.group_by(fn {assignment, _identity, _window} -> assignment.pool_id end)
      |> Map.new(fn {pool_id, pool_rows} ->
        chart_rows =
          pool_rows
          |> Enum.map(&quota_remaining_chart_row(&1, timestamp))
          |> Enum.reject(&is_nil/1)

        {pool_id, quota_remaining_pool_charts(chart_rows, quota_assignment_count(pool_rows))}
      end)

    Enum.into(pool_ids, %{}, fn pool_id ->
      {pool_id, Map.get(charts_by_pool_id, pool_id, quota_remaining_empty_pool_charts(pool_id))}
    end)
  end

  def quota_remaining_charts_by_pool_ids(_pool_ids, _opts), do: %{}

  defp quota_remaining_chart_rows([], _timestamp), do: []

  # Charts consume effective windows (logical fold plus superseded-primary
  # rejection at the chart timestamp) instead of raw persisted rows, so a
  # frozen 5h primary whose quota group kept syncing cannot resurface as a
  # blocked chart entry or a "quota refresh needed" cockpit state that
  # routing itself no longer sees.
  defp quota_remaining_chart_rows(pool_ids, timestamp) do
    membership_rows =
      Repo.all(
        from assignment in PoolUpstreamAssignment,
          join: identity in UpstreamIdentity,
          on: identity.id == assignment.upstream_identity_id,
          where: assignment.pool_id in ^pool_ids and assignment.status != ^@deleted,
          order_by: [asc: assignment.pool_id, asc: assignment.created_at, asc: assignment.id],
          select: {assignment, identity}
      )

    windows_by_identity =
      membership_rows
      |> Enum.map(fn {_assignment, identity} -> identity.id end)
      |> QuotaWindows.list_quota_windows_by_identity_ids(timestamp)

    Enum.flat_map(membership_rows, fn {assignment, identity} ->
      windows_by_identity
      |> Map.get(identity.id, [])
      |> Enum.filter(&account_chart_window?/1)
      |> case do
        [] -> [{assignment, identity, nil}]
        windows -> Enum.map(windows, &{assignment, identity, &1})
      end
    end)
  end

  defp account_chart_window?(%Quota.AccountQuotaWindow{} = window) do
    window.quota_scope == "account" and window.quota_key == @account_quota_key and
      ((window.window_kind == "primary" and window.window_minutes in [300, 43_200]) or
         window.window_kind == "secondary")
  end

  defp quota_remaining_chart_row(
         {%PoolUpstreamAssignment{} = assignment, %UpstreamIdentity{} = identity,
          %Quota.AccountQuotaWindow{} = window},
         timestamp
       ) do
    chart_key = quota_remaining_chart_key(window)

    if chart_key do
      usable? = QuotaWindows.usable_window?(window, timestamp)

      measurements = Measurements.for_window(window)

      %{
        chart_key: chart_key,
        pool_id: assignment.pool_id,
        assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        window_assignment_id: quota_window_assignment_id(window),
        label: quota_remaining_label(assignment, identity, window),
        plan_family: identity.plan_family,
        plan_label: quota_remaining_plan_label(identity),
        reset_at: window.reset_at,
        freshness_state: Evidence.current_freshness_state(window, timestamp),
        routing_usable?: usable?,
        remaining: measurements.remaining,
        capacity: measurements.capacity,
        used: measurements.used,
        used_percent: measurements.used_percent,
        remaining_percent: measurements.remaining_percent,
        merge_precedence: window.merge_precedence || 0,
        observed_at: window.observed_at,
        updated_at: window.updated_at,
        excluded_reasons:
          if(usable?, do: [], else: Quota.Windows.routing_window_reason_codes(window, timestamp))
      }
    end
  end

  defp quota_remaining_chart_row(_row, _timestamp), do: nil

  defp quota_remaining_chart_key(%Quota.AccountQuotaWindow{} = window) do
    case WindowClassifier.classify(window) do
      :primary_5h -> :primary_5h
      :monthly_primary -> :primary_30d
      :weekly_secondary -> :weekly
      _descriptor -> nil
    end
  end

  defp quota_remaining_plan_label(%UpstreamIdentity{plan_label: label})
       when is_binary(label) and label != "",
       do: label

  defp quota_remaining_plan_label(%UpstreamIdentity{plan_family: family})
       when is_binary(family) and family != "",
       do: family

  defp quota_remaining_plan_label(%UpstreamIdentity{}), do: nil

  defp quota_remaining_pool_charts(rows, assignment_count) do
    weekly_rows = Enum.filter(rows, &(&1.chart_key == :weekly))
    weekly_winners = quota_remaining_winners(weekly_rows)

    weekly =
      quota_remaining_chart(
        :weekly,
        "Weekly quota",
        weekly_rows,
        weekly_winners,
        assignment_count
      )

    primary_5h_chart_rows = Enum.filter(rows, &(&1.chart_key == :primary_5h))
    primary_30d_chart_rows = Enum.filter(rows, &(&1.chart_key == :primary_30d))

    primary_5h_rows =
      primary_5h_chart_rows
      |> quota_remaining_winners()
      |> Enum.map(
        &Measurements.apply_weekly_cap(
          &1,
          Enum.filter(weekly_winners, fn weekly -> weekly.routing_usable? end)
        )
      )

    %{
      primary_5h:
        quota_remaining_chart(
          :primary_5h,
          "5h quota",
          primary_5h_chart_rows,
          primary_5h_rows,
          assignment_count
        ),
      primary_30d:
        quota_remaining_chart(
          :primary_30d,
          "30d quota",
          primary_30d_chart_rows,
          quota_remaining_winners(primary_30d_chart_rows),
          assignment_count
        ),
      weekly: weekly
    }
  end

  defp quota_remaining_empty_pool_charts(_pool_id) do
    %{
      primary_5h: quota_remaining_chart(:primary_5h, "5h quota", [], [], 0),
      primary_30d: quota_remaining_chart(:primary_30d, "30d quota", [], [], 0),
      weekly: quota_remaining_chart(:weekly, "Weekly quota", [], [], 0)
    }
  end

  defp quota_assignment_count(rows) do
    rows
    |> Enum.map(fn {assignment, _identity, _window} -> assignment.id end)
    |> Enum.uniq()
    |> length()
  end

  defp quota_remaining_chart(chart_key, title, rows, winners, assignment_count) do
    items =
      winners
      |> Enum.filter(& &1.routing_usable?)
      |> Enum.sort(&quota_remaining_item_before?/2)
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        item
        |> Map.take([
          :assignment_id,
          :upstream_identity_id,
          :label,
          :plan_family,
          :plan_label,
          :remaining,
          :capacity,
          :used,
          :used_percent,
          :remaining_percent,
          :reset_at,
          :freshness_state,
          :routing_usable?
        ])
        |> Map.put(:color_index, index)
      end)

    excluded = Enum.reject(winners, & &1.routing_usable?)
    evidence_count = length(winners)
    usable_count = length(items)
    blocked_count = length(excluded)
    missing_count = max(assignment_count - evidence_count, 0)

    %{
      key: chart_key,
      title: title,
      account_count: assignment_count,
      evidence_count: evidence_count,
      usable_count: usable_count,
      blocked_count: blocked_count,
      missing_count: missing_count,
      remaining_total: Measurements.sum(items, :remaining),
      capacity_total: Measurements.sum_known(items, :capacity),
      used_total: Measurements.sum_known(items, :used),
      used_percent: Measurements.items_used_percent(items),
      lowest_remaining_percent: quota_lowest_remaining_percent(items, excluded),
      next_reset_at: quota_next_reset_at(items),
      items: items,
      excluded_count: blocked_count,
      excluded_reasons: quota_excluded_reasons(excluded),
      state: quota_chart_state(items, excluded, rows, assignment_count)
    }
  end

  defp quota_remaining_winners(rows) do
    rows
    |> Enum.group_by(&{&1.assignment_id, &1.upstream_identity_id, &1.chart_key})
    |> Enum.map(fn {_key, bucket} ->
      Enum.min_by(bucket, &quota_remaining_winner_sort_key/1)
    end)
  end

  defp quota_remaining_winner_sort_key(row) do
    {
      if(row.routing_usable?, do: 0, else: 1),
      -(row.merge_precedence || 0),
      -datetime_sort_value(row.observed_at),
      -datetime_sort_value(row.updated_at),
      -datetime_sort_value(row.reset_at)
    }
  end

  defp quota_remaining_item_before?(left, right) do
    case decimal_compare_for_sort(left.remaining, right.remaining) do
      :gt -> true
      :lt -> false
      :eq -> quota_remaining_item_tiebreaker(left) <= quota_remaining_item_tiebreaker(right)
    end
  end

  defp quota_remaining_item_tiebreaker(item) do
    {sanitize_chart_sort_value(item.label), item.assignment_id, item.upstream_identity_id}
  end

  defp sanitize_chart_sort_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp sanitize_chart_sort_value(_value), do: ""

  defp decimal_compare_for_sort(%Decimal{} = left, %Decimal{} = right),
    do: Decimal.compare(left, right)

  defp decimal_compare_for_sort(%Decimal{}, _right), do: :gt
  defp decimal_compare_for_sort(_left, %Decimal{}), do: :lt
  defp decimal_compare_for_sort(_left, _right), do: :eq

  defp quota_excluded_reasons(excluded) do
    excluded
    |> Enum.flat_map(& &1.excluded_reasons)
    |> Enum.frequencies()
  end

  defp quota_lowest_remaining_percent(items, excluded) do
    remaining_percents =
      items
      |> Enum.map(& &1.remaining_percent)
      |> Enum.reject(&is_nil/1)

    cond do
      remaining_percents != [] ->
        Enum.min_by(remaining_percents, &Decimal.to_float/1)

      quota_excluded_reasons(excluded)["exhausted"] &&
          quota_excluded_reasons(excluded)["exhausted"] > 0 ->
        Decimal.new(0)

      true ->
        nil
    end
  end

  defp quota_next_reset_at(items) do
    items
    |> Enum.map(& &1.reset_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp quota_chart_state([_ | _], _excluded, _rows, _assignment_count), do: "usable"
  defp quota_chart_state([], [_ | _], _rows, _assignment_count), do: "blocked"
  defp quota_chart_state([], [], [], 0), do: "empty"
  defp quota_chart_state([], [], _rows, _assignment_count), do: "missing"

  defp quota_remaining_label(assignment, identity, window) do
    assignment.assignment_label || identity.account_label || window.display_label ||
      "Upstream account"
  end

  defp quota_window_assignment_id(%Quota.AccountQuotaWindow{metadata: metadata})
       when is_map(metadata) do
    case metadata["assignment_id"] || metadata["pool_upstream_assignment_id"] do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp quota_window_assignment_id(%Quota.AccountQuotaWindow{}), do: nil

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_value(_datetime), do: 0

  defp quota_capacity_summary(window_rows) do
    used_percents =
      window_rows
      |> Enum.map(fn {_pool_id, used_percent, _reset_at, _freshness_state} ->
        percent_to_float(used_percent)
      end)
      |> Enum.reject(&is_nil/1)

    best_remaining_percent =
      used_percents
      |> Enum.map(&(100.0 - &1))
      |> Enum.max(fn -> nil end)

    next_reset_at =
      window_rows
      |> Enum.map(fn {_pool_id, _used_percent, reset_at, _freshness_state} -> reset_at end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)

    %{
      window_count: length(window_rows),
      fresh_window_count:
        Enum.count(window_rows, fn {_pool_id, _used_percent, _reset_at, freshness_state} ->
          freshness_state == @fresh
        end),
      known_percent_count: length(used_percents),
      best_remaining_percent: best_remaining_percent && clamp_percent(best_remaining_percent),
      next_reset_at: next_reset_at
    }
  end

  defp percent_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp percent_to_float(value) when is_integer(value), do: value * 1.0
  defp percent_to_float(value) when is_float(value), do: value
  defp percent_to_float(_value), do: nil

  defp clamp_percent(value) when value < 0.0, do: 0.0
  defp clamp_percent(value) when value > 100.0, do: 100.0
  defp clamp_percent(value), do: value

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
