defmodule CodexPooler.Admin.UpstreamCockpitMetrics.PoolContribution do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitMetrics
  alias CodexPooler.Admin.UpstreamCockpitMetrics.Common
  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @spec pool_contribution(
          Scope.t(),
          UpstreamCockpitMetrics.identity_ref(),
          [UpstreamCockpitMetrics.assignment_summary()],
          DateTime.t()
        ) :: UpstreamCockpitMetrics.pool_contribution()
  def pool_contribution(%Scope{} = scope, identity_or_id, assignments, %DateTime{} = as_of)
      when is_list(assignments) do
    pool_ids = Common.visible_pool_ids(scope)
    visible_assignments = Common.filter_assignments_by_pool_ids(assignments, pool_ids)
    start_7d = Common.seven_day_window_start(as_of)

    rows =
      identity_or_id
      |> Common.identity_id()
      |> pool_contribution_rows(pool_ids, start_7d, as_of)

    quota_readiness = quota_readiness(identity_or_id, visible_assignments, as_of)

    from_rows(identity_or_id, visible_assignments, rows, quota_readiness)
  end

  @spec without_request_data([UpstreamCockpitMetrics.assignment_summary()], DateTime.t()) ::
          UpstreamCockpitMetrics.pool_contribution()
  def without_request_data(assignments, %DateTime{} = as_of) when is_list(assignments) do
    from_rows(
      nil,
      assignments,
      [],
      UpstreamQuotaReadiness.from_windows([], as_of)
    )
  end

  defp quota_readiness(_identity_or_id, [], as_of),
    do: UpstreamQuotaReadiness.from_windows([], as_of)

  defp quota_readiness(identity_or_id, _visible_assignments, as_of) do
    identity_or_id
    |> Common.identity_id()
    |> quota_readiness_for_identity(as_of)
  end

  defp from_rows(identity_or_status, assignments, rows, quota_readiness) do
    successful_requests_7d = length(rows)
    request_counts_by_pool_id = Enum.frequencies_by(rows, & &1.pool_id)

    items =
      assignments
      |> Enum.map(
        &pool_contribution_item(
          &1,
          request_counts_by_pool_id,
          successful_requests_7d,
          identity_or_status,
          quota_readiness
        )
      )
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

  defp pool_contribution_rows(identity_id, pool_ids, start_7d, as_of)
       when is_binary(identity_id) and is_list(pool_ids) do
    case pool_ids do
      [] -> []
      [_ | _] -> pool_contribution_rows_for_pools(identity_id, pool_ids, start_7d, as_of)
    end
  end

  defp pool_contribution_rows(_identity_id, _pool_ids, _start_7d, _as_of), do: []

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

  defp pool_contribution_item(
         assignment,
         request_counts_by_pool_id,
         successful_requests_7d,
         identity_or_status,
         quota_readiness
       ) do
    successful_request_count_7d = Map.get(request_counts_by_pool_id, assignment.pool_id, 0)
    share_percent_value = Common.percentage(successful_request_count_7d, successful_requests_7d)
    routing_readiness = Common.routing_readiness(identity_or_status, assignment, quota_readiness)
    assignment_state = pool_contribution_assignment_state(routing_readiness)

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
      pool_contribution_assignment_state_label(assignment_state, routing_readiness)
    )
    |> Map.put(:routing_usable?, routing_readiness.routing_ready_now?)
    |> Map.merge(Common.routing_readiness_contract(routing_readiness))
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

  defp pool_contribution_assignment_state(%{routing_ready_now?: true}), do: "active"
  defp pool_contribution_assignment_state(_routing_readiness), do: "disabled"

  defp pool_contribution_assignment_state_label("active", _routing_readiness),
    do: "Active assignment"

  defp pool_contribution_assignment_state_label("disabled", %{state: "assignment_unavailable"}),
    do: "Disabled or unusable assignment"

  defp pool_contribution_assignment_state_label("disabled", %{label: label})
       when is_binary(label),
       do: label

  defp pool_contribution_assignment_state_label("disabled", _routing_readiness),
    do: "Disabled or unusable assignment"

  defp quota_readiness_for_identity(identity_id, as_of) when is_binary(identity_id) do
    identity_id
    |> QuotaWindows.list_quota_windows()
    |> UpstreamQuotaReadiness.from_windows(as_of)
  end

  defp quota_readiness_for_identity(_identity_id, as_of),
    do: UpstreamQuotaReadiness.from_windows([], as_of)
end
