defmodule CodexPooler.Admin.Stats do
  @moduledoc """
  Read-only aggregate dashboard data for authenticated admin statistics.

  This module is intentionally a query boundary. It does not write rows,
  broadcast events, enqueue jobs, or expose raw request/upstream metadata.
  """

  alias CodexPooler.Accounting.Reporting, as: AccountingReporting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.ActivityReadModel
  alias CodexPooler.Admin.GatewayReadModel

  alias CodexPooler.Admin.Stats.{
    Charts,
    EmptyStates,
    Filters,
    Kpis,
    PoolUsage,
    SourceSummary,
    Tables
  }

  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.Quota

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type pool_usage_opt :: PoolUsage.pool_usage_opt()
  @type pool_usage_metrics :: PoolUsage.pool_usage_metrics()

  @spec build_dashboard(Scope.t(), map() | keyword()) ::
          {:ok, map()} | {:error, access_error()}
  def build_dashboard(scope, filters \\ %{})

  def build_dashboard(%Scope{} = scope, filters) when is_map(filters) or is_list(filters) do
    do_build_dashboard(scope, filters)
  end

  def build_dashboard(_scope, _filters),
    do:
      {:error,
       Filters.access_error(:unauthorized, "admin statistics require an authenticated operator")}

  @spec pool_usage_metrics_by_pool_ids([Ecto.UUID.t()], [pool_usage_opt()]) :: %{
          optional(Ecto.UUID.t()) => pool_usage_metrics()
        }
  def pool_usage_metrics_by_pool_ids(pool_ids, opts \\ []) do
    PoolUsage.metrics_by_pool_ids(pool_ids, opts)
  end

  defp do_build_dashboard(scope, filters) do
    with {:ok, pools} <- Pools.list_reporting_pools(scope),
         {:ok, normalized} <- Filters.normalize(filters, pools) do
      pool_ids = Filters.dashboard_pool_ids(normalized, pools)

      if pool_ids == [] do
        {:ok, empty_dashboard(normalized, pools)}
      else
        build_dashboard_for_pool_ids(normalized, pools, pool_ids)
      end
    else
      {:error, %{code: code}} when code in [:capability_denied, :invalid_request] ->
        {:error,
         Filters.access_error(:unauthorized, "admin statistics require an authenticated operator")}

      {:error, _reason} = error ->
        error
    end
  end

  defp build_dashboard_for_pool_ids(normalized, pools, pool_ids) do
    requests =
      GatewayReadModel.requests_for_pool_ids(
        pool_ids,
        normalized.started_at,
        normalized.ended_at
      )

    attempts =
      GatewayReadModel.attempts_for_pool_ids(
        pool_ids,
        normalized.started_at,
        normalized.ended_at
      )

    settlements =
      AccountingReporting.settlements_for_pool_ids(
        pool_ids,
        normalized.started_at,
        normalized.ended_at
      )

    daily_rollups =
      AccountingReporting.daily_rollups_for_pool_ids(
        pool_ids,
        normalized.started_at,
        normalized.ended_at
      )

    model_usage_report =
      AccountingReporting.model_usage_buckets_for_pool_ids(
        pool_ids,
        normalized.window,
        normalized.started_at,
        normalized.ended_at
      )

    model_usage = Charts.model_usage_series(model_usage_report.rows, normalized)
    active_session_count = GatewayReadModel.active_session_count_for_pool_ids(pool_ids)

    turns =
      GatewayReadModel.turns_for_pool_ids(pool_ids, normalized.started_at, normalized.ended_at)

    activity_summary =
      ActivityReadModel.activity_summary_for_pool_ids(
        pool_ids,
        normalized.started_at,
        normalized.ended_at
      )

    recent_activity = activity_summary.recent_activity
    activity_counts = activity_summary.source_counts

    quota_accounts =
      Quota.ReadModel.account_summaries_for_pool_ids(pool_ids, normalized.ended_at)

    quota_summary = Quota.ReadModel.summary(quota_accounts)

    dashboard = %{
      filters: Filters.public(normalized, pools),
      selected_pool: Filters.pool_summary(normalized.selected_pool),
      kpis: %{
        requests: Kpis.request_kpi(requests),
        success_rate: Kpis.success_rate_kpi(requests),
        tokens: Kpis.token_kpi(settlements),
        tokens_per_second: Kpis.tokens_per_second_kpi(settlements, attempts),
        settled_cost: Kpis.settled_cost_kpi(settlements),
        average_latency_ms: Kpis.average_latency_kpi(attempts),
        active_sessions: %{value: active_session_count},
        turns: Kpis.turn_kpi(turns),
        quota_health: quota_summary
      },
      tables: %{
        top_api_keys: Tables.top_api_keys(settlements, pools),
        upstreams: Tables.upstream_table(settlements, quota_accounts),
        recent_failures: Tables.recent_failures(requests),
        daily_rollups: Tables.daily_rollup_table(daily_rollups),
        recent_activity: recent_activity
      },
      charts: %{
        requests: Charts.request_series(requests, normalized),
        tokens: Charts.token_series(settlements, normalized),
        settled_cost: Charts.cost_series(settlements, normalized),
        model_usage: model_usage
      },
      quota: %{
        summary: quota_summary,
        accounts: quota_accounts
      },
      sources:
        SourceSummary.build(
          requests,
          attempts,
          settlements,
          daily_rollups,
          turns,
          activity_counts,
          model_usage_report.source,
          length(model_usage)
        ),
      empty_states: EmptyStates.build(requests, settlements, quota_accounts)
    }

    {:ok, dashboard}
  end

  defp empty_dashboard(normalized, pools) do
    quota_summary = Quota.ReadModel.summary([])

    %{
      filters: Filters.public(normalized, pools),
      selected_pool: nil,
      kpis: %{
        requests: Kpis.request_kpi([]),
        success_rate: Kpis.success_rate_kpi([]),
        tokens: Kpis.token_kpi([]),
        tokens_per_second: Kpis.tokens_per_second_kpi([], []),
        settled_cost: Kpis.settled_cost_kpi([]),
        average_latency_ms: Kpis.average_latency_kpi([]),
        active_sessions: %{value: 0},
        turns: Kpis.turn_kpi([]),
        quota_health: quota_summary
      },
      tables: %{
        top_api_keys: [],
        upstreams: [],
        recent_failures: [],
        daily_rollups: [],
        recent_activity: []
      },
      charts: %{
        requests: [],
        tokens: [],
        settled_cost: [],
        model_usage: []
      },
      quota: %{
        summary: quota_summary,
        accounts: []
      },
      sources: SourceSummary.build([], [], [], [], [], %{audit_events: 0, jobs: 0}, nil, 0),
      empty_states: [
        %{
          code: :no_reporting_pools,
          message: "No Pools are available for this stats scope"
        }
      ]
    }
  end
end
