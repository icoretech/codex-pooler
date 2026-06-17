defmodule CodexPooler.Admin.UpstreamCockpitReadModel do
  @moduledoc """
  Scoped admin-domain projections for upstream cockpit request activity.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @request_failed_statuses ~w(failed rejected interrupted cancelled)
  @request_terminal_statuses ["succeeded" | @request_failed_statuses]

  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type assignment_summary :: %{
          required(:id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:pool_label) => String.t(),
          required(:assignment_label) => String.t(),
          required(:status) => String.t(),
          required(:health_status) => String.t(),
          required(:eligibility_status) => String.t()
        }
  @type request_health_item :: %{
          required(:date) => String.t(),
          required(:success_count) => non_neg_integer(),
          required(:failure_count) => non_neg_integer(),
          required(:total_count) => non_neg_integer()
        }
  @type request_health_kpis :: %{
          required(:total_requests_24h) => non_neg_integer(),
          required(:failed_requests_24h) => non_neg_integer(),
          required(:failure_rate_24h) => float(),
          required(:total_requests_7d) => non_neg_integer()
        }
  @type request_health :: %{
          required(:key) => :request_health,
          required(:title) => String.t(),
          required(:items) => [request_health_item()],
          required(:kpis) => request_health_kpis(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean(),
          required(:missing?) => boolean(),
          required(:state) => String.t()
        }
  @type pool_contribution_item :: %{
          required(:assignment_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:pool_label) => String.t(),
          required(:assignment_label) => String.t(),
          required(:assignment_status) => String.t(),
          required(:health_status) => String.t(),
          required(:eligibility_status) => String.t(),
          required(:assignment_state) => String.t(),
          required(:assignment_state_label) => String.t(),
          required(:routing_usable?) => boolean(),
          required(:successful_request_count_7d) => non_neg_integer(),
          required(:share_percent_value) => float(),
          required(:bar_value) => float()
        }
  @type pool_contribution_kpis :: %{
          required(:assignment_count) => non_neg_integer(),
          required(:active_assignment_count) => non_neg_integer(),
          required(:disabled_assignment_count) => non_neg_integer(),
          required(:successful_requests_7d) => non_neg_integer()
        }
  @type pool_contribution :: %{
          required(:key) => :pool_contribution,
          required(:title) => String.t(),
          required(:items) => [pool_contribution_item()],
          required(:kpis) => pool_contribution_kpis(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean(),
          required(:missing?) => boolean(),
          required(:state) => String.t()
        }
  @type recent_request_event_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:status) => String.t(),
          required(:admitted_at) => DateTime.t() | nil,
          required(:completed_at) => DateTime.t() | nil,
          required(:response_status_code) => integer() | nil,
          required(:last_error_code) => String.t() | nil,
          required(:attempt_count) => non_neg_integer()
        }

  @spec request_health(Scope.t(), identity_ref()) :: request_health()
  def request_health(%Scope{} = scope, identity_or_id) do
    request_health(scope, identity_or_id, now())
  end

  @spec request_health(Scope.t(), identity_ref(), DateTime.t()) :: request_health()
  def request_health(%Scope{} = scope, identity_or_id, %DateTime{} = as_of) do
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = seven_day_window_start(as_of)

    identity_or_id
    |> identity_id()
    |> request_health_rows(scope, start_7d, as_of)
    |> request_health_from_rows(start_7d, start_24h)
  end

  @spec request_health_without_request_data() :: request_health()
  def request_health_without_request_data do
    request_health_without_request_data(now())
  end

  @spec request_health_without_request_data(DateTime.t()) :: request_health()
  def request_health_without_request_data(%DateTime{} = as_of) do
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = seven_day_window_start(as_of)

    request_health_from_rows([], start_7d, start_24h)
  end

  @spec pool_contribution(Scope.t(), identity_ref(), [assignment_summary()]) ::
          pool_contribution()
  def pool_contribution(%Scope{} = scope, identity_or_id, assignments)
      when is_list(assignments) do
    as_of = now()
    start_7d = seven_day_window_start(as_of)

    rows =
      identity_or_id
      |> identity_id()
      |> pool_contribution_rows(scope, start_7d, as_of)

    pool_contribution_from_rows(assignments, rows)
  end

  @spec pool_contribution_without_request_data([assignment_summary()]) :: pool_contribution()
  def pool_contribution_without_request_data(assignments) when is_list(assignments) do
    pool_contribution_from_rows(assignments, [])
  end

  @spec recent_request_event_rows(Scope.t(), identity_ref(), pos_integer()) :: [
          recent_request_event_row()
        ]
  def recent_request_event_rows(%Scope{} = scope, identity_or_id, limit) when is_integer(limit) do
    identity_or_id
    |> identity_id()
    |> recent_request_event_rows_for_identity(scope, max(limit, 0))
  end

  def recent_request_event_rows(_scope, _identity_or_id, _limit), do: []

  defp pool_contribution_from_rows(assignments, rows) do
    successful_requests_7d = length(rows)
    request_counts_by_pool_id = Enum.frequencies_by(rows, & &1.pool_id)

    items =
      assignments
      |> Enum.map(&pool_contribution_item(&1, request_counts_by_pool_id, successful_requests_7d))
      |> Enum.sort_by(&{&1.pool_label, &1.assignment_label, &1.assignment_id})

    kpis = pool_contribution_kpis(items, successful_requests_7d)

    %{
      key: :pool_contribution,
      title: "Pool contribution",
      items: items,
      kpis: kpis,
      empty?: items == [],
      degraded?: kpis.disabled_assignment_count > 0,
      missing?: false,
      state: pool_contribution_state(items, kpis)
    }
  end

  defp pool_contribution_rows(identity_id, %Scope{} = scope, start_7d, as_of)
       when is_binary(identity_id) do
    case visible_pool_ids(scope) do
      [] -> []
      pool_ids -> pool_contribution_rows_for_pools(identity_id, pool_ids, start_7d, as_of)
    end
  end

  defp pool_contribution_rows(_identity_id, _scope, _start_7d, _as_of), do: []

  defp pool_contribution_rows_for_pools(identity_id, pool_ids, start_7d, as_of) do
    Request
    |> join(:inner, [request], attempt in Attempt, on: attempt.request_id == request.id)
    |> where([request], request.pool_id in ^pool_ids)
    |> where([request, attempt], attempt.upstream_identity_id == ^identity_id)
    |> where([request], request.status == "succeeded")
    |> where([request], request.admitted_at >= ^start_7d and request.admitted_at <= ^as_of)
    |> group_by([request], [request.id, request.pool_id])
    |> select([request], %{pool_id: request.pool_id})
    |> Repo.all()
  end

  defp pool_contribution_item(assignment, request_counts_by_pool_id, successful_requests_7d) do
    successful_request_count_7d = Map.get(request_counts_by_pool_id, assignment.pool_id, 0)
    share_percent_value = percentage(successful_request_count_7d, successful_requests_7d)
    assignment_state = pool_contribution_assignment_state(assignment)

    assignment
    |> Map.take([
      :upstream_identity_id,
      :pool_id,
      :pool_label,
      :assignment_label,
      :health_status,
      :eligibility_status
    ])
    |> Map.put(:assignment_id, assignment.id)
    |> Map.put(:assignment_status, assignment.status)
    |> Map.put(:assignment_state, assignment_state)
    |> Map.put(
      :assignment_state_label,
      pool_contribution_assignment_state_label(assignment_state)
    )
    |> Map.put(:routing_usable?, pool_contribution_routing_usable?(assignment))
    |> Map.put(:successful_request_count_7d, successful_request_count_7d)
    |> Map.put(:share_percent_value, share_percent_value)
    |> Map.put(:bar_value, share_percent_value)
  end

  defp pool_contribution_kpis(items, successful_requests_7d) do
    %{
      assignment_count: length(items),
      active_assignment_count: Enum.count(items, & &1.routing_usable?),
      disabled_assignment_count: Enum.count(items, &(not &1.routing_usable?)),
      successful_requests_7d: successful_requests_7d
    }
  end

  defp pool_contribution_state([], _kpis), do: "empty"
  defp pool_contribution_state(_items, %{successful_requests_7d: 0}), do: "no_successful_requests"

  defp pool_contribution_state(_items, %{disabled_assignment_count: disabled}) when disabled > 0,
    do: "degraded"

  defp pool_contribution_state(_items, _kpis), do: "contributing"

  defp pool_contribution_assignment_state(assignment) do
    if pool_contribution_routing_usable?(assignment), do: "active", else: "disabled"
  end

  defp pool_contribution_assignment_state_label("active"), do: "Active assignment"
  defp pool_contribution_assignment_state_label("disabled"), do: "Disabled or unusable assignment"

  defp pool_contribution_routing_usable?(assignment) do
    assignment.status == "active" and assignment.health_status == "active" and
      assignment.eligibility_status == "eligible"
  end

  defp request_health_rows(identity_id, %Scope{} = scope, start_7d, as_of)
       when is_binary(identity_id) do
    case visible_pool_ids(scope) do
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
    |> group_by([request], [request.id, request.status, request.admitted_at])
    |> select([request], %{status: request.status, admitted_at: request.admitted_at})
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
      degraded?: kpis.failed_requests_24h > 0,
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
      total_requests_7d: total_requests_7d
    }
  end

  defp request_health_state(%{total_requests_7d: 0}), do: "empty"

  defp request_health_state(%{total_requests_24h: total, failed_requests_24h: failed})
       when total > 0 and failed == total,
       do: "failed"

  defp request_health_state(%{failed_requests_24h: failed}) when failed > 0, do: "degraded"
  defp request_health_state(_kpis), do: "healthy"

  defp request_health_date(%{admitted_at: %DateTime{} = admitted_at}),
    do: DateTime.to_date(admitted_at)

  defp recent_request_event_rows_for_identity(identity_id, %Scope{} = scope, limit)
       when is_binary(identity_id) and limit > 0 do
    case visible_pool_ids(scope) do
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

  defp visible_pool_ids(%Scope{} = scope) do
    scope
    |> Pools.list_visible_pools()
    |> Enum.map(& &1.id)
  end

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_identity_or_id), do: nil

  defp failed_request_status?(status), do: status in @request_failed_statuses

  defp failure_rate(_failed, 0), do: 0.0

  defp failure_rate(failed, total), do: percentage(failed, total)

  defp percentage(_count, 0), do: 0.0

  defp percentage(count, total), do: Float.round(count / total * 100.0, 1)

  defp seven_day_window_start(%DateTime{} = as_of) do
    as_of
    |> DateTime.to_date()
    |> Date.add(-6)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
