defmodule CodexPooler.Admin.UpstreamCockpitMetrics.RequestHealth do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitMetrics
  alias CodexPooler.Admin.UpstreamCockpitMetrics.Common
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @request_failed_statuses ~w(failed rejected interrupted cancelled)
  @request_terminal_statuses ["succeeded" | @request_failed_statuses]
  # A share of failed upstream calls is expected in normal operation; request
  # posture only escalates to degraded above this 24h failure-rate percentage.
  @degraded_failure_rate_percent 5.0
  @error_breakdown_limit 5
  @event_walk_clock_margin_seconds 60
  # The second walk is capped too: without a limit the planner, which cannot
  # tell how few of one assignment's attempts are that recent, estimates
  # thousands of rows and pays about 125 ms of JIT compilation for a 4 ms read
  # (`jit_above_cost` is at its default in production). Only a burst of more
  # than this many failed or retried requests within about two minutes could
  # push an event out of the list.
  @second_walk_factor 16
  # Every walk reads at most this many of an assignment's newest attempts. An
  # account whose failed or retried requests are rarer than one in about 300
  # would otherwise have its whole history walked, with one retry probe per
  # attempt, on every cockpit load. When a walk runs out with older attempts
  # left behind, the result says so instead of implying a clean history
  # (findings#206 row 206-441).
  @event_walk_depth 10_000

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

  @spec event_walk_depth() :: pos_integer()
  def event_walk_depth, do: @event_walk_depth

  @spec recent_request_events(
          Scope.t(),
          UpstreamCockpitMetrics.identity_ref(),
          non_neg_integer()
        ) ::
          UpstreamCockpitMetrics.recent_request_events()
  def recent_request_events(%Scope{} = scope, identity_or_id, limit)
      when is_integer(limit) and limit > 0 do
    identity_or_id
    |> Common.identity_id()
    |> recent_request_events_for_identity(scope, limit)
  end

  def recent_request_events(_scope, _identity_or_id, _limit), do: no_recent_request_events()

  defp no_recent_request_events, do: %{rows: [], searched_attempt_limit: nil}

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
    Request
    |> from(as: :request)
    |> join(:inner_lateral, [], target in subquery(target_attempt_query(identity_id)), on: true)
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

  defp recent_request_events_for_identity(identity_id, %Scope{} = scope, limit)
       when is_binary(identity_id) do
    case Common.visible_pool_ids(scope) do
      [] -> no_recent_request_events()
      pool_ids -> recent_request_events_for_pools(identity_id, pool_ids, limit)
    end
  end

  defp recent_request_events_for_identity(_identity_id, _scope, _limit), do: no_recent_request_events()

  defp target_attempt_query(identity_id) do
    from attempt in Attempt,
      where: attempt.request_id == parent_as(:request).id,
      where: attempt.upstream_identity_id == ^identity_id,
      limit: 1,
      select: %{id: attempt.id}
  end

  # The identity's recent failed or retried requests, walked from the identity's
  # own attempts newest first through `attempts_assignment_started_idx`, one
  # walk per assignment in a visible Pool. Walking `requests` newest first and
  # probing each for the identity read every request admitted after the
  # identity's last event: for a busy account that went quiet that is all the
  # traffic since, 1.2M buffers and over a second for 30 quiet days on a
  # 1M-request rehearsal (findings#206 row 206-385).
  #
  # An attempt never starts before its request is admitted (production: none of
  # 51,623 in 14 days, 18 ms minimum), so every request admitted at or after a
  # time has an identity attempt started at or after it. The first walk takes
  # `limit` candidates per assignment; the second takes the events with an
  # attempt started since the `limit`-th newest candidate's admission, less a
  # minute for clocks of other nodes, which contain the exact newest `limit`.
  #
  # The first walk (and its doublings) stays inside the assignment's newest
  # `@event_walk_depth` attempts (findings#206 row 206-441). A first walk that
  # reads its whole window also meets the first attempt behind it, if one
  # exists, and returns it as a marker instead of an event: the result then
  # sets `searched_attempt_limit`, which the cockpit shows instead of implying
  # that nothing older failed. The second walk runs only after a first walk
  # stopped at its limit inside the window, and its floor keeps it there
  # within the clock margin; it keeps the plain attempt walk, since a window
  # subquery under its range condition lets the planner hash-join all of
  # `requests` instead.
  defp recent_request_events_for_pools(identity_id, pool_ids, limit) do
    case identity_assignment_ids(identity_id, pool_ids) do
      [] ->
        no_recent_request_events()

      assignment_ids ->
        {candidates, window_cut?} = recent_event_rows(assignment_ids, pool_ids, limit, limit)

        %{
          rows: candidates |> newest_events(limit) |> with_attempt_counts(),
          searched_attempt_limit: if(window_cut?, do: @event_walk_depth)
        }
    end
  end

  # A walk that stopped at its limit may have left events behind it. With
  # `limit` distinct requests in hand, the second walk from the `limit`-th
  # newest admission finds every event that can still rank; with fewer (the
  # identity attempted some request twice) the walk goes twice as far. Whether
  # a walk ran out of its window with older attempts behind it is returned
  # alongside the rows.
  defp recent_event_rows(assignment_ids, pool_ids, limit, walk) do
    walks = Enum.map(assignment_ids, &window_event_candidates(&1, pool_ids, walk))
    candidates = Enum.flat_map(walks, &elem(&1, 0))
    window_cut? = Enum.any?(walks, &elem(&1, 1))
    stopped_early? = Enum.any?(walks, &(length(elem(&1, 0)) == walk))

    case {stopped_early?, candidates |> newest_events(limit) |> Enum.drop(limit - 1)} do
      {false, _all_found} ->
        {candidates, window_cut?}

      {true, [%{admitted_at: %DateTime{} = boundary}]} ->
        floor = DateTime.add(boundary, -@event_walk_clock_margin_seconds, :second)
        rows = Enum.flat_map(assignment_ids, &event_candidates_since(&1, pool_ids, floor, limit * @second_walk_factor))
        {rows, window_cut?}

      {true, _fewer_than_limit} ->
        recent_event_rows(assignment_ids, pool_ids, limit, walk * 2)
    end
  end

  defp identity_assignment_ids(identity_id, pool_ids) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where: assignment.upstream_identity_id == ^identity_id and assignment.pool_id in ^pool_ids,
        select: assignment.id
    )
  end

  # The first walk reads the assignment's newest `@event_walk_depth` attempts
  # and the first one behind them, through `attempts_assignment_started_idx` in
  # start order, and stops as soon as it has `walk` events. It returns the
  # events and whether it met that attempt behind the window, which is the
  # window's last row, so a walk that stopped at its limit never reaches it.
  defp window_event_candidates(assignment_id, pool_ids, walk) do
    window =
      from attempt in Attempt,
        where: attempt.pool_upstream_assignment_id == ^assignment_id,
        windows: [newest_first: [order_by: [desc: attempt.started_at]]],
        order_by: [desc: attempt.started_at],
        limit: ^(@event_walk_depth + 1),
        select: %{request_id: attempt.request_id, started_at: attempt.started_at, position: over(row_number(), :newest_first)}

    retry_probe = retry_probe()

    {events, behind_window} =
      window
      |> subquery()
      |> event_walk(walk)
      |> where(
        [attempt, request: request],
        attempt.position > ^@event_walk_depth or
          (request.pool_id in ^pool_ids and (request.status in ^@request_failed_statuses or exists(subquery(retry_probe))))
      )
      |> select_merge([attempt], %{behind_window?: attempt.position > ^@event_walk_depth})
      |> Repo.all()
      |> Enum.split_with(&(not &1.behind_window?))

    {Enum.map(events, &Map.delete(&1, :behind_window?)), behind_window != []}
  end

  # The second walk reads only the attempts started since `floor`, which lie
  # within about a minute of events the first walk found inside its window.
  defp event_candidates_since(assignment_id, pool_ids, floor, limit) do
    from(attempt in Attempt, where: attempt.pool_upstream_assignment_id == ^assignment_id and attempt.started_at >= ^floor)
    |> event_walk(limit)
    |> where([request: request], request.pool_id in ^pool_ids)
    |> where([request: request], request.status in ^@request_failed_statuses or exists(subquery(retry_probe())))
    |> Repo.all()
  end

  defp event_walk(attempts, limit) do
    from(attempt in attempts,
      join: request in Request,
      as: :request,
      on: request.id == attempt.request_id,
      order_by: [desc: attempt.started_at],
      limit: ^limit,
      select: %{
        id: request.id,
        status: request.status,
        admitted_at: request.admitted_at,
        completed_at: request.completed_at,
        response_status_code: request.response_status_code,
        last_error_code: request.last_error_code
      }
    )
  end

  # Both walks keep a request that failed or has a second attempt.
  defp retry_probe do
    from attempt in Attempt,
      where: attempt.request_id == parent_as(:request).id,
      offset: 1,
      limit: 1,
      select: 1
  end

  # Newest admission first, ties by id descending, one row per request (an
  # identity can make several attempts at one request).
  defp newest_events(rows, limit) do
    rows
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{DateTime.to_unix(&1.admitted_at, :microsecond), &1.id}, :desc)
    |> Enum.take(limit)
  end

  # Every attempt of the selected requests counts, whichever upstream made it.
  defp with_attempt_counts([]), do: []

  defp with_attempt_counts(rows) do
    counts =
      Repo.all(
        from attempt in Attempt,
          where: attempt.request_id in ^Enum.map(rows, & &1.id),
          group_by: attempt.request_id,
          select: {attempt.request_id, count(attempt.id)}
      )
      |> Map.new()

    Enum.map(rows, &Map.put(&1, :attempt_count, Map.get(counts, &1.id, 0)))
  end

  defp failed_request_status?(status), do: status in @request_failed_statuses

  defp failure_rate(_failed, 0), do: 0.0
  defp failure_rate(failed, total), do: Common.percentage(failed, total)
end
