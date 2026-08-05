defmodule CodexPooler.Admin.UpstreamCockpitMetrics.RequestHealth do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitMetrics
  alias CodexPooler.Admin.UpstreamCockpitMetrics.Common
  alias CodexPooler.Repo

  @request_failed_statuses ~w(failed rejected interrupted cancelled)
  @request_terminal_statuses ["succeeded" | @request_failed_statuses]
  # A share of failed upstream calls is expected in normal operation; request
  # posture only escalates to degraded above this 24h failure-rate percentage.
  @degraded_failure_rate_percent 5.0
  @error_breakdown_limit 5

  @spec request_health(Scope.t(), UpstreamCockpitMetrics.identity_ref(), DateTime.t()) ::
          UpstreamCockpitMetrics.request_health()
  def request_health(%Scope{} = scope, identity_or_id, %DateTime{} = as_of) do
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = Common.seven_day_window_start(as_of)

    identity_or_id
    |> Common.identity_id()
    |> request_health_summary(scope, start_7d, start_24h, as_of)
  end

  @spec without_request_data(DateTime.t()) :: UpstreamCockpitMetrics.request_health()
  def without_request_data(%DateTime{} = as_of) do
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = Common.seven_day_window_start(as_of)

    request_health_from_summary(%{}, start_7d, start_24h)
  end

  @spec recent_request_event_rows(
          Scope.t(),
          UpstreamCockpitMetrics.identity_ref(),
          non_neg_integer()
        ) ::
          [UpstreamCockpitMetrics.recent_request_event_row()]
  def recent_request_event_rows(%Scope{} = scope, identity_or_id, limit)
      when is_integer(limit) and limit > 0 do
    identity_or_id
    |> Common.identity_id()
    |> recent_request_event_rows_for_identity(scope, limit)
  end

  def recent_request_event_rows(_scope, _identity_or_id, _limit), do: []

  defp request_health_summary(identity_id, %Scope{} = scope, start_7d, start_24h, as_of)
       when is_binary(identity_id) do
    case Common.visible_pool_ids(scope) do
      [] ->
        request_health_from_summary(%{}, start_7d, start_24h)

      pool_ids ->
        request_health_summary_for_pools(identity_id, pool_ids, start_7d, start_24h, as_of)
    end
  end

  defp request_health_summary(_identity_id, _scope, start_7d, start_24h, _as_of),
    do: request_health_from_summary(%{}, start_7d, start_24h)

  defp request_health_summary_for_pools(identity_id, pool_ids, start_7d, start_24h, as_of) do
    base_query = terminal_requests_query(identity_id, pool_ids, start_7d, as_of)

    %{
      daily_counts: daily_counts(base_query),
      recent_status_counts: recent_status_counts(base_query, start_24h),
      p50_latency_ms: p50_latency_ms(base_query, start_24h),
      error_breakdown: error_breakdown(base_query, start_24h)
    }
    |> request_health_from_summary(start_7d, start_24h)
  end

  defp terminal_requests_query(identity_id, pool_ids, start_7d, as_of) do
    target_request_ids =
      from attempt in Attempt,
        where: attempt.upstream_identity_id == ^identity_id,
        group_by: attempt.request_id,
        select: attempt.request_id

    Request
    |> join(:inner, [request], target in subquery(target_request_ids),
      on: target.request_id == request.id
    )
    |> where([request], request.pool_id in ^pool_ids)
    |> where([request], request.status in ^@request_terminal_statuses)
    |> where([request], request.admitted_at >= ^start_7d and request.admitted_at <= ^as_of)
  end

  defp daily_counts(base_query) do
    base_query
    |> group_by([request], [fragment("DATE(?)", request.admitted_at), request.status])
    |> select([request], %{
      date: type(fragment("DATE(?)", request.admitted_at), :date),
      status: request.status,
      count: count(request.id)
    })
    |> Repo.all()
  end

  defp recent_status_counts(base_query, start_24h) do
    base_query
    |> where([request], request.admitted_at >= ^start_24h)
    |> group_by([request], request.status)
    |> select([request], %{status: request.status, count: count(request.id)})
    |> Repo.all()
  end

  defp p50_latency_ms(base_query, start_24h) do
    base_query
    |> where([request], request.admitted_at >= ^start_24h and request.status == "succeeded")
    |> where(
      [request],
      not is_nil(request.completed_at) and request.completed_at >= request.admitted_at
    )
    |> select(
      [request],
      fragment(
        "percentile_disc(0.5) within group (order by floor(extract(epoch from (? - ?)) * 1000)::bigint)",
        request.completed_at,
        request.admitted_at
      )
    )
    |> Repo.one()
    |> normalize_latency_percentile()
  end

  defp normalize_latency_percentile(nil), do: nil

  defp normalize_latency_percentile(value) when is_integer(value), do: value

  defp error_breakdown(base_query, start_24h) do
    base_query
    |> where(
      [request],
      request.admitted_at >= ^start_24h and request.status in ^@request_failed_statuses
    )
    |> group_by([request], [request.response_status_code, request.last_error_code])
    |> order_by([request], desc: count(request.id))
    |> limit(^@error_breakdown_limit)
    |> select([request], %{
      status_code: request.response_status_code,
      error_code: request.last_error_code,
      count: count(request.id)
    })
    |> Repo.all()
  end

  defp request_health_from_summary(summary, start_7d, _start_24h) do
    daily_counts = Map.get(summary, :daily_counts, [])
    recent_status_counts = Map.get(summary, :recent_status_counts, [])
    items = request_health_items(daily_counts, start_7d)
    kpis = request_health_kpis(daily_counts, recent_status_counts, summary)

    %{
      key: :request_health,
      title: "Request health",
      items: items,
      kpis: kpis,
      empty?: kpis.total_requests_7d == 0,
      degraded?: request_health_state(kpis) in ["degraded", "failed"],
      missing?: false,
      state: request_health_state(kpis)
    }
  end

  defp request_health_items(rows, start_7d) do
    start_date = DateTime.to_date(start_7d)
    rows_by_date = Enum.group_by(rows, & &1.date)

    for offset <- 0..6 do
      date = Date.add(start_date, offset)
      bucket_rows = Map.get(rows_by_date, date, [])

      success_count =
        bucket_rows |> Enum.filter(&(&1.status == "succeeded")) |> Enum.sum_by(& &1.count)

      failure_count =
        bucket_rows |> Enum.filter(&failed_request_status?(&1.status)) |> Enum.sum_by(& &1.count)

      %{
        date: Date.to_iso8601(date),
        success_count: success_count,
        failure_count: failure_count,
        total_count: success_count + failure_count
      }
    end
  end

  defp request_health_kpis(daily_counts, recent_status_counts, summary) do
    total_requests_24h = Enum.sum_by(recent_status_counts, & &1.count)

    failed_requests_24h =
      recent_status_counts
      |> Enum.filter(&failed_request_status?(&1.status))
      |> Enum.sum_by(& &1.count)

    total_requests_7d = Enum.sum_by(daily_counts, & &1.count)

    %{
      total_requests_24h: total_requests_24h,
      failed_requests_24h: failed_requests_24h,
      failure_rate_24h: failure_rate(failed_requests_24h, total_requests_24h),
      total_requests_7d: total_requests_7d,
      p50_latency_ms_24h: Map.get(summary, :p50_latency_ms),
      error_breakdown_24h: Map.get(summary, :error_breakdown, [])
    }
  end

  defp request_health_state(%{total_requests_7d: 0}), do: "empty"

  defp request_health_state(%{total_requests_24h: total, failed_requests_24h: failed})
       when total > 0 and failed == total,
       do: "failed"

  defp request_health_state(%{failure_rate_24h: rate})
       when rate > @degraded_failure_rate_percent,
       do: "degraded"

  defp request_health_state(_kpis), do: "healthy"

  defp recent_request_event_rows_for_identity(identity_id, %Scope{} = scope, limit)
       when is_binary(identity_id) do
    case Common.visible_pool_ids(scope) do
      [] -> []
      pool_ids -> recent_request_event_rows_for_pools(identity_id, pool_ids, limit)
    end
  end

  defp recent_request_event_rows_for_identity(_identity_id, _scope, _limit), do: []

  defp recent_request_event_rows_for_pools(identity_id, pool_ids, limit) do
    target_requests_query =
      from attempt in Attempt,
        where: attempt.upstream_identity_id == ^identity_id,
        group_by: attempt.request_id,
        select: %{request_id: attempt.request_id}

    attempt_counts_query =
      from attempt in Attempt,
        group_by: attempt.request_id,
        select: %{request_id: attempt.request_id, attempt_count: count(attempt.id)}

    Request
    |> join(:inner, [request], target in subquery(target_requests_query),
      on: target.request_id == request.id
    )
    |> join(:inner, [request], attempts in subquery(attempt_counts_query),
      on: attempts.request_id == request.id
    )
    |> where([request], request.pool_id in ^pool_ids)
    |> where(
      [request, _target, attempts],
      request.status in ^@request_failed_statuses or attempts.attempt_count > 1
    )
    |> order_by([request], desc: request.admitted_at, desc: request.id)
    |> limit(^limit)
    |> select([request, _target, attempts], %{
      id: request.id,
      status: request.status,
      admitted_at: request.admitted_at,
      completed_at: request.completed_at,
      response_status_code: request.response_status_code,
      last_error_code: request.last_error_code,
      attempt_count: attempts.attempt_count
    })
    |> Repo.all()
  end

  defp failed_request_status?(status), do: status in @request_failed_statuses

  defp failure_rate(_failed, 0), do: 0.0
  defp failure_rate(failed, total), do: Common.percentage(failed, total)
end
