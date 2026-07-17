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
    |> request_health_rows(scope, start_7d, as_of)
    |> request_health_from_rows(start_7d, start_24h)
  end

  @spec without_request_data(DateTime.t()) :: UpstreamCockpitMetrics.request_health()
  def without_request_data(%DateTime{} = as_of) do
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = Common.seven_day_window_start(as_of)

    request_health_from_rows([], start_7d, start_24h)
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

  defp request_health_rows(identity_id, %Scope{} = scope, start_7d, as_of)
       when is_binary(identity_id) do
    case Common.visible_pool_ids(scope) do
      [] -> []
      pool_ids -> request_health_rows_for_pools(identity_id, pool_ids, start_7d, as_of)
    end
  end

  defp request_health_rows(_identity_id, _scope, _start_7d, _as_of), do: []

  defp request_health_rows_for_pools(identity_id, pool_ids, start_7d, as_of) do
    Request
    |> join(:inner, [request], attempt in Attempt, on: attempt.request_id == request.id)
    |> where([request], request.pool_id in ^pool_ids)
    |> where([request, attempt], attempt.upstream_identity_id == ^identity_id)
    |> where([request], request.status in ^@request_terminal_statuses)
    |> where([request], request.admitted_at >= ^start_7d and request.admitted_at <= ^as_of)
    |> group_by([request], [
      request.id,
      request.status,
      request.admitted_at,
      request.completed_at,
      request.response_status_code,
      request.last_error_code
    ])
    |> select([request], %{
      status: request.status,
      admitted_at: request.admitted_at,
      completed_at: request.completed_at,
      response_status_code: request.response_status_code,
      last_error_code: request.last_error_code
    })
    |> Repo.all()
  end

  defp request_health_from_rows(rows, start_7d, start_24h) do
    items = request_health_items(rows, start_7d)
    kpis = request_health_kpis(rows, start_24h)

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
    rows_by_date = Enum.group_by(rows, &request_health_date/1)

    for offset <- 0..6 do
      date = Date.add(start_date, offset)
      bucket_rows = Map.get(rows_by_date, date, [])
      success_count = Enum.count(bucket_rows, &(&1.status == "succeeded"))
      failure_count = Enum.count(bucket_rows, &failed_request_status?(&1.status))

      %{
        date: Date.to_iso8601(date),
        success_count: success_count,
        failure_count: failure_count,
        total_count: success_count + failure_count
      }
    end
  end

  defp request_health_kpis(rows, start_24h) do
    rows_24h = Enum.filter(rows, &(DateTime.compare(&1.admitted_at, start_24h) != :lt))
    total_requests_24h = length(rows_24h)
    failed_requests_24h = Enum.count(rows_24h, &failed_request_status?(&1.status))
    total_requests_7d = length(rows)

    %{
      total_requests_24h: total_requests_24h,
      failed_requests_24h: failed_requests_24h,
      failure_rate_24h: failure_rate(failed_requests_24h, total_requests_24h),
      total_requests_7d: total_requests_7d,
      p50_latency_ms_24h: p50_latency_ms(rows_24h),
      error_breakdown_24h: error_breakdown(rows_24h)
    }
  end

  defp p50_latency_ms(rows) do
    rows
    |> Enum.filter(&(&1.status == "succeeded"))
    |> Enum.flat_map(fn
      %{admitted_at: %DateTime{} = admitted_at, completed_at: %DateTime{} = completed_at} ->
        [DateTime.diff(completed_at, admitted_at, :millisecond)]

      _row ->
        []
    end)
    |> Enum.filter(&(&1 >= 0))
    |> median()
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted) - 1, 2))
  end

  defp error_breakdown(rows) do
    rows
    |> Enum.filter(&failed_request_status?(&1.status))
    |> Enum.frequencies_by(&{&1.response_status_code, &1.last_error_code})
    |> Enum.map(fn {{status_code, error_code}, count} ->
      %{status_code: status_code, error_code: error_code, count: count}
    end)
    |> Enum.sort_by(&(-&1.count))
    |> Enum.take(@error_breakdown_limit)
  end

  defp request_health_state(%{total_requests_7d: 0}), do: "empty"

  defp request_health_state(%{total_requests_24h: total, failed_requests_24h: failed})
       when total > 0 and failed == total,
       do: "failed"

  defp request_health_state(%{failure_rate_24h: rate})
       when rate > @degraded_failure_rate_percent,
       do: "degraded"

  defp request_health_state(_kpis), do: "healthy"

  defp request_health_date(%{admitted_at: %DateTime{} = admitted_at}),
    do: DateTime.to_date(admitted_at)

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
