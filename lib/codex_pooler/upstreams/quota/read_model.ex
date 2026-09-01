defmodule CodexPooler.Upstreams.Quota.ReadModel do
  @moduledoc """
  Read-only upstream quota projections for admin/reporting surfaces.
  """

  import Ecto.Query

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @spec account_summaries_for_pool_ids([Ecto.UUID.t()], DateTime.t()) :: [map()]
  def account_summaries_for_pool_ids([], _as_of), do: []

  def account_summaries_for_pool_ids(pool_ids, as_of) do
    assignments = assignments_for_pool_ids(pool_ids)

    snapshots_by_identity_id =
      assignments
      |> Enum.map(& &1.upstream_identity_id)
      |> RoutingQuotaSnapshot.load_by_identity_ids(as_of)

    Enum.map(assignments, fn assignment ->
      snapshot = Map.fetch!(snapshots_by_identity_id, assignment.upstream_identity_id)
      windows = RoutingQuotaSnapshot.effective_windows(snapshot)
      primary = find_primary_5h_window(windows, as_of)
      monthly_primary = find_primary_30d_window(windows, as_of)
      secondary = find_secondary_window(windows, as_of)

      state =
        snapshot
        |> Quota.Windows.routing_quota_eligibility_from_snapshot(account_only: true)
        |> quota_state_from_snapshot(primary || monthly_primary, secondary, windows, as_of)

      %{
        pool_id: assignment.pool_id,
        pool_upstream_assignment_id: assignment.pool_upstream_assignment_id,
        assignment_label: assignment.assignment_label,
        assignment_status: assignment.assignment_status,
        health_status: assignment.health_status,
        upstream_identity_id: assignment.upstream_identity_id,
        upstream_label: assignment.upstream_label,
        plan_family: assignment.plan_family,
        state: state,
        primary_5h: quota_window_summary(primary, as_of),
        primary_30d: quota_window_summary(monthly_primary, as_of),
        secondary: quota_window_summary(secondary, as_of),
        evidence_count: length(windows)
      }
    end)
  end

  @spec summary([map()]) :: map()
  def summary([]),
    do: %{
      state: :empty,
      available: 0,
      exhausted: 0,
      missing_evidence: 0,
      weekly_only_evidence: 0,
      unknown: 0,
      total: 0
    }

  def summary(accounts) do
    counts = Enum.frequencies_by(accounts, & &1.state)

    %{
      state: overall_quota_state(counts),
      available: Map.get(counts, :available, 0),
      exhausted: Map.get(counts, :exhausted, 0),
      missing_evidence: Map.get(counts, :missing_evidence, 0),
      weekly_only_evidence: Map.get(counts, :weekly_only_evidence, 0),
      unknown: Map.get(counts, :unknown, 0),
      total: length(accounts)
    }
  end

  defp assignments_for_pool_ids(pool_ids) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where: assignment.pool_id in ^pool_ids,
        order_by: [asc: assignment.assignment_label],
        select: %{
          pool_id: assignment.pool_id,
          pool_upstream_assignment_id: assignment.id,
          assignment_label: assignment.assignment_label,
          assignment_status: assignment.status,
          health_status: assignment.health_status,
          upstream_identity_id: identity.id,
          upstream_label: identity.account_label,
          plan_family: identity.plan_family
        }
    )
  end

  defp quota_state_from_snapshot(
         %{eligible?: true, routing_state: :windowless_provider_available},
         _primary,
         _secondary,
         _windows,
         _as_of
       ),
       do: :available

  defp quota_state_from_snapshot(
         %{eligible?: true, routing_state: :weekly_only_probe},
         _primary,
         _secondary,
         _windows,
         _as_of
       ),
       do: :weekly_only_evidence

  defp quota_state_from_snapshot(%{eligible?: true}, _primary, _secondary, _windows, _as_of),
    do: :available

  defp quota_state_from_snapshot(
         %{routing_state: :blocked, exclusions: exclusions},
         _primary,
         _secondary,
         windows,
         _as_of
       ) do
    cond do
      Enum.any?(exclusions, &("exhausted" in Map.get(&1, :reason_codes, []))) -> :exhausted
      windows == [] -> :unknown
      true -> :missing_evidence
    end
  end

  defp quota_state_from_snapshot(_eligibility, nil, nil, [], _as_of), do: :unknown

  defp quota_state_from_snapshot(_eligibility, primary, secondary, windows, as_of),
    do: quota_state(primary, secondary, windows, as_of)

  defp find_primary_5h_window(windows, as_of) do
    WindowSelector.best_account_window(windows, :primary_5h, as_of)
  end

  defp find_primary_30d_window(windows, as_of) do
    WindowSelector.best_account_window(windows, :monthly_primary, as_of)
  end

  defp find_secondary_window(windows, as_of) do
    WindowSelector.best_account_window(windows, :weekly_secondary, as_of)
  end

  defp quota_state(%Quota.AccountQuotaWindow{} = primary, _secondary, _windows, as_of) do
    cond do
      Evidence.current_freshness_state(primary, as_of) != "fresh" ->
        :missing_evidence

      is_nil(primary.reset_at) ->
        :missing_evidence

      DateTime.compare(primary.reset_at, as_of) != :gt ->
        :missing_evidence

      Decimal.compare(primary.used_percent || Decimal.new(0), Decimal.new(100)) != :lt ->
        :exhausted

      true ->
        :available
    end
  end

  defp quota_state(nil, %Quota.AccountQuotaWindow{}, _windows, _as_of), do: :weekly_only_evidence
  defp quota_state(nil, nil, [], _as_of), do: :unknown
  defp quota_state(nil, nil, _windows, _as_of), do: :missing_evidence

  defp quota_window_summary(nil, _as_of), do: nil

  defp quota_window_summary(%Quota.AccountQuotaWindow{} = window, as_of) do
    %{
      quota_key: window.quota_key,
      window_kind: window.window_kind,
      window_minutes: window.window_minutes,
      used_percent: decimal_to_float(window.used_percent),
      reset_at: window.reset_at,
      freshness_state: Evidence.current_freshness_state(window, as_of),
      source: window.source,
      source_precision: window.source_precision,
      routing_usable?: Quota.Windows.usable_window?(window, as_of)
    }
  end

  defp overall_quota_state(counts) do
    cond do
      Map.get(counts, :available, 0) > 0 and map_size(Map.drop(counts, [:available])) == 0 ->
        :available

      Map.get(counts, :available, 0) > 0 ->
        :partial

      Map.get(counts, :exhausted, 0) > 0 ->
        :exhausted

      Map.get(counts, :missing_evidence, 0) > 0 ->
        :missing_evidence

      Map.get(counts, :weekly_only_evidence, 0) > 0 ->
        :weekly_only_evidence

      true ->
        :unknown
    end
  end

  defp decimal_to_float(nil), do: nil
  defp decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_to_float(value) when is_integer(value), do: value * 1.0
end
