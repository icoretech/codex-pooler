defmodule CodexPooler.Admin.Stats do
  @moduledoc """
  Read-only aggregate dashboard data for authenticated admin statistics.

  This module is intentionally a query boundary. It does not write rows,
  broadcast events, enqueue jobs, or expose raw request/upstream metadata.
  """

  alias CodexPooler.Access.Reporting, as: AccessReporting
  alias CodexPooler.Accounting.Reporting, as: AccountingReporting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.ActivityReadModel
  alias CodexPooler.Admin.GatewayReadModel
  alias CodexPooler.Admin.Stats.Filters
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.Quota

  @succeeded "succeeded"
  @failed_statuses ~w(failed rejected interrupted cancelled)
  @pool_usage_window_seconds 5 * 60 * 60
  @pool_histogram_window_seconds 24 * 60 * 60

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}

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

  @spec pool_usage_metrics_by_pool_ids([Ecto.UUID.t()], keyword()) :: %{
          optional(Ecto.UUID.t()) => map()
        }
  def pool_usage_metrics_by_pool_ids(pool_ids, opts \\ [])

  def pool_usage_metrics_by_pool_ids(pool_ids, opts) when is_list(pool_ids) and is_list(opts) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    ended_at = Keyword.get_lazy(opts, :as_of, &now/0)

    started_at =
      Keyword.get(opts, :started_at, DateTime.add(ended_at, -@pool_usage_window_seconds, :second))

    weekly_started_at = Keyword.get(opts, :weekly_started_at, DateTime.add(ended_at, -7, :day))

    request_counts = GatewayReadModel.request_counts_by_pool_ids(pool_ids, started_at, ended_at)
    token_totals = AccountingReporting.token_totals_by_pool_ids(pool_ids, started_at, ended_at)
    latency_totals = GatewayReadModel.latency_totals_by_pool_ids(pool_ids, started_at, ended_at)
    token_usage_5h = AccountingReporting.token_usage_by_pool_ids(pool_ids, started_at, ended_at)

    token_usage_weekly =
      AccountingReporting.token_usage_by_pool_ids(pool_ids, weekly_started_at, ended_at)

    histogram_started_at =
      Keyword.get(
        opts,
        :histogram_started_at,
        DateTime.add(ended_at, -@pool_histogram_window_seconds, :second)
      )

    token_histograms =
      pool_token_histograms(
        pool_ids,
        AccountingReporting.settlements_for_pool_ids(pool_ids, histogram_started_at, ended_at),
        ended_at
      )

    request_histograms =
      pool_request_histograms(
        pool_ids,
        GatewayReadModel.hourly_request_counts_by_pool_ids(
          pool_ids,
          histogram_started_at,
          ended_at
        ),
        ended_at
      )

    Enum.into(pool_ids, %{}, fn pool_id ->
      tokens_per_second =
        pool_tokens_per_second(
          Map.get(token_totals, pool_id, 0),
          Map.get(latency_totals, pool_id, 0)
        )

      {pool_id,
       %{
         request_count_5h: Map.get(request_counts, pool_id, 0),
         tokens_per_second: tokens_per_second,
         token_usage_5h: Map.get(token_usage_5h, pool_id, empty_token_usage()),
         token_usage_weekly: Map.get(token_usage_weekly, pool_id, empty_token_usage()),
         token_histogram_24h: Map.fetch!(token_histograms, pool_id),
         request_histogram_24h: Map.fetch!(request_histograms, pool_id)
       }}
    end)
  end

  def pool_usage_metrics_by_pool_ids(_pool_ids, _opts), do: %{}

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
        requests: request_kpi(requests),
        success_rate: success_rate_kpi(requests),
        tokens: token_kpi(settlements),
        tokens_per_second: tokens_per_second_kpi(settlements, attempts),
        estimated_cost: estimated_cost_kpi(settlements),
        average_latency_ms: average_latency_kpi(attempts),
        active_sessions: %{value: active_session_count},
        turns: turn_kpi(turns),
        quota_health: quota_summary
      },
      tables: %{
        top_api_keys: top_api_keys(settlements),
        upstreams: upstream_table(settlements, quota_accounts),
        recent_failures: recent_failures(requests),
        daily_rollups: daily_rollup_table(daily_rollups),
        recent_activity: recent_activity
      },
      charts: %{
        requests: request_series(requests, normalized),
        tokens: token_series(settlements, normalized),
        estimated_cost: cost_series(settlements, normalized)
      },
      quota: %{
        summary: quota_summary,
        accounts: quota_accounts
      },
      sources:
        source_summary(
          requests,
          attempts,
          settlements,
          daily_rollups,
          turns,
          activity_counts
        ),
      empty_states: empty_states(requests, settlements, quota_accounts)
    }

    {:ok, dashboard}
  end

  defp empty_dashboard(normalized, pools) do
    quota_summary = Quota.ReadModel.summary([])

    %{
      filters: Filters.public(normalized, pools),
      selected_pool: nil,
      kpis: %{
        requests: request_kpi([]),
        success_rate: success_rate_kpi([]),
        tokens: token_kpi([]),
        tokens_per_second: tokens_per_second_kpi([], []),
        estimated_cost: estimated_cost_kpi([]),
        average_latency_ms: average_latency_kpi([]),
        active_sessions: %{value: 0},
        turns: turn_kpi([]),
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
        estimated_cost: []
      },
      quota: %{
        summary: quota_summary,
        accounts: []
      },
      sources: source_summary([], [], [], [], [], %{audit_events: 0, jobs: 0}),
      empty_states: [
        %{
          code: :no_reporting_pools,
          message: "No Pools are available for this stats scope"
        }
      ]
    }
  end

  defp pool_tokens_per_second(total_tokens, latency_ms) when total_tokens > 0 and latency_ms > 0,
    do: Float.round(total_tokens / (latency_ms / 1000), 2)

  defp pool_tokens_per_second(_total_tokens, _latency_ms), do: nil

  defp pool_token_histograms(pool_ids, settlements, ended_at) do
    labels = bucket_labels(%{window: :twenty_four_hours, ended_at: ended_at})

    entries_by_pool_bucket =
      Enum.group_by(settlements, fn settlement ->
        {settlement.pool_id, bucket_label(settlement.occurred_at, :twenty_four_hours)}
      end)

    Map.new(pool_ids, fn pool_id ->
      rows =
        Enum.map(labels, fn label ->
          entries = Map.get(entries_by_pool_bucket, {pool_id, label}, [])

          %{
            bucket: label,
            total_tokens: sum_integer(entries, :total_tokens)
          }
        end)

      {pool_id, rows}
    end)
  end

  defp pool_request_histograms(pool_ids, request_counts, ended_at) do
    labels = bucket_labels(%{window: :twenty_four_hours, ended_at: ended_at})

    requests_by_pool_bucket =
      Map.new(request_counts, fn row ->
        {{row.pool_id, bucket_label(row.bucket, :twenty_four_hours)}, row.requests}
      end)

    Map.new(pool_ids, fn pool_id ->
      rows =
        Enum.map(labels, fn label ->
          %{
            bucket: label,
            requests: Map.get(requests_by_pool_bucket, {pool_id, label}, 0)
          }
        end)

      {pool_id, rows}
    end)
  end

  defp request_kpi(requests) do
    %{
      value: length(requests),
      succeeded: Enum.count(requests, &(&1.status == @succeeded)),
      failed: Enum.count(requests, &(&1.status in @failed_statuses)),
      in_progress: Enum.count(requests, &(&1.status == "in_progress"))
    }
  end

  defp success_rate_kpi([]), do: %{value: nil, unit: "percent"}

  defp success_rate_kpi(requests) do
    succeeded = Enum.count(requests, &(&1.status == @succeeded))
    %{value: percentage(succeeded, length(requests)), unit: "percent"}
  end

  defp token_kpi(settlements) do
    %{
      input_tokens: sum_integer(settlements, :input_tokens),
      cached_input_tokens: sum_integer(settlements, :cached_input_tokens),
      output_tokens: sum_integer(settlements, :output_tokens),
      reasoning_tokens: sum_integer(settlements, :reasoning_tokens),
      total_tokens: sum_integer(settlements, :total_tokens)
    }
  end

  defp tokens_per_second_kpi(settlements, attempts) do
    total_tokens = sum_integer(settlements, :total_tokens)
    latency_ms = sum_integer(Enum.filter(attempts, & &1.latency_ms), :latency_ms)

    value =
      if total_tokens > 0 and latency_ms > 0 do
        Float.round(total_tokens / (latency_ms / 1000), 2)
      end

    %{value: value, unit: "tokens/second"}
  end

  defp estimated_cost_kpi([]), do: %{status: "unavailable", micros: 0, usd: nil}

  defp estimated_cost_kpi(settlements) do
    micros = sum_decimal_integer(settlements, :estimated_cost_micros)

    %{
      status: if(micros > 0, do: "estimated", else: "unpriced"),
      micros: micros,
      usd: micros_to_usd_decimal(micros)
    }
  end

  defp average_latency_kpi(attempts) do
    latencies = attempts |> Enum.map(& &1.latency_ms) |> Enum.filter(&is_integer/1)

    value =
      case latencies do
        [] -> nil
        _latencies -> round(Enum.sum(latencies) / length(latencies))
      end

    %{value: value, unit: "ms"}
  end

  defp turn_kpi(turns) do
    %{
      value: length(turns),
      succeeded: Enum.count(turns, &(&1.status == @succeeded)),
      failed: Enum.count(turns, &(&1.status in @failed_statuses)),
      in_progress: Enum.count(turns, &(&1.status == "in_progress"))
    }
  end

  defp top_api_keys([]), do: []

  defp top_api_keys(settlements) do
    key_ids = settlements |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    keys_by_id = AccessReporting.api_keys_by_id(key_ids)

    settlements
    |> Enum.group_by(& &1.api_key_id)
    |> Enum.map(fn {api_key_id, entries} ->
      api_key = Map.get(keys_by_id, api_key_id)

      %{
        api_key_id: api_key_id,
        display_name: api_key && api_key.display_name,
        requests: sum_integer(entries, :request_count),
        total_tokens: sum_integer(entries, :total_tokens),
        estimated_cost_micros: sum_decimal_integer(entries, :estimated_cost_micros)
      }
    end)
    |> Enum.sort_by(&{&1.total_tokens, &1.requests}, :desc)
    |> Enum.take(5)
  end

  defp upstream_table(settlements, quota_accounts) do
    entries_by_identity = Enum.group_by(settlements, & &1.upstream_identity_id)

    quota_accounts
    |> Enum.map(fn account ->
      entries = Map.get(entries_by_identity, account.upstream_identity_id, [])

      %{
        pool_upstream_assignment_id: account.pool_upstream_assignment_id,
        upstream_identity_id: account.upstream_identity_id,
        assignment_label: account.assignment_label,
        upstream_label: account.upstream_label,
        status: account.assignment_status,
        health_status: account.health_status,
        quota_state: account.state,
        requests: sum_integer(entries, :request_count),
        total_tokens: sum_integer(entries, :total_tokens),
        estimated_cost_micros: sum_decimal_integer(entries, :estimated_cost_micros)
      }
    end)
  end

  defp recent_failures(requests) do
    requests
    |> Enum.filter(&(&1.status in @failed_statuses))
    |> Enum.take(5)
    |> Enum.map(fn request ->
      %{
        id: request.id,
        pool_id: request.pool_id,
        requested_model: request.requested_model,
        endpoint: request.endpoint,
        transport: request.transport,
        status: request.status,
        error_code: request.last_error_code,
        response_status_code: request.response_status_code,
        admitted_at: request.admitted_at
      }
    end)
  end

  defp daily_rollup_table(rollups) do
    rollups
    |> Enum.take(10)
    |> Enum.map(fn rollup ->
      %{
        rollup_date: rollup.rollup_date,
        dimension_kind: rollup.dimension_kind,
        pool_id: rollup.pool_id,
        request_count: rollup.request_count || 0,
        success_count: rollup.success_count || 0,
        failure_count: rollup.failure_count || 0,
        total_tokens: rollup.total_tokens || 0,
        estimated_cost_micros: decimal_to_integer(rollup.estimated_cost_micros)
      }
    end)
  end

  defp source_summary(requests, attempts, settlements, daily_rollups, turns, activity_counts) do
    %{
      requests: length(requests),
      attempts: length(attempts),
      settlements: length(settlements),
      daily_rollups: length(daily_rollups),
      codex_turns: length(turns),
      audit_events: activity_counts.audit_events,
      jobs: activity_counts.jobs,
      usage_source:
        if(daily_rollups == [], do: :raw_ledger_fallback, else: :raw_ledger_with_rollup_context)
    }
  end

  defp request_series(requests, normalized) do
    buckets = bucket_labels(normalized)
    grouped = Enum.group_by(requests, &bucket_label(&1.admitted_at, normalized.window))

    Enum.map(buckets, fn label ->
      rows = Map.get(grouped, label, [])

      %{
        bucket: label,
        requests: length(rows),
        succeeded: Enum.count(rows, &(&1.status == @succeeded)),
        failed: Enum.count(rows, &(&1.status in @failed_statuses))
      }
    end)
  end

  defp token_series(settlements, normalized) do
    buckets = bucket_labels(normalized)
    grouped = Enum.group_by(settlements, &bucket_label(&1.occurred_at, normalized.window))

    Enum.map(buckets, fn label ->
      entries = Map.get(grouped, label, [])

      %{bucket: label, total_tokens: sum_integer(entries, :total_tokens)}
    end)
  end

  defp cost_series(settlements, normalized) do
    buckets = bucket_labels(normalized)
    grouped = Enum.group_by(settlements, &bucket_label(&1.occurred_at, normalized.window))

    Enum.map(buckets, fn label ->
      entries = Map.get(grouped, label, [])

      %{
        bucket: label,
        estimated_cost_micros: sum_decimal_integer(entries, :estimated_cost_micros)
      }
    end)
  end

  defp bucket_labels(%{window: :seven_days, ended_at: ended_at}) do
    today = DateTime.to_date(ended_at)

    6..0//-1
    |> Enum.map(&Date.add(today, -&1))
    |> Enum.map(&Date.to_iso8601/1)
  end

  defp bucket_labels(%{window: window, ended_at: ended_at}) do
    count = if window == :one_hour, do: 1, else: if(window == :five_hours, do: 5, else: 24)
    current_hour = truncate_to_hour(ended_at)

    (count - 1)..0//-1
    |> Enum.map(&DateTime.add(current_hour, -&1, :hour))
    |> Enum.map(&bucket_label(&1, window))
  end

  defp bucket_label(nil, _window), do: nil

  defp bucket_label(datetime, :seven_days),
    do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp bucket_label(datetime, _window) do
    datetime = truncate_to_hour(datetime)
    date = datetime |> DateTime.to_date() |> Date.to_iso8601()
    hour = datetime.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    date <> "T" <> hour <> ":00:00Z"
  end

  defp truncate_to_hour(datetime) do
    %{datetime | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp empty_states(requests, settlements, assignments) do
    []
    |> maybe_empty(requests == [], :no_requests, "No requests in this range")
    |> maybe_empty(
      settlements == [],
      :no_usage,
      "No settled usage in this range"
    )
    |> maybe_empty(
      assignments == [],
      :no_upstreams,
      "No upstream assignments in this scope"
    )
    |> Enum.reverse()
  end

  defp maybe_empty(states, true, code, message), do: [%{code: code, message: message} | states]
  defp maybe_empty(states, false, _code, _message), do: states

  defp sum_integer(rows, field) do
    Enum.reduce(rows, 0, fn row, acc -> acc + (Map.get(row, field) || 0) end)
  end

  defp sum_decimal_integer(rows, field) do
    Enum.reduce(rows, 0, fn row, acc -> acc + decimal_to_integer(Map.get(row, field)) end)
  end

  defp empty_token_usage do
    %{
      cached_input_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0
    }
  end

  defp decimal_to_integer(nil), do: 0

  defp decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp decimal_to_integer(value) when is_integer(value), do: value

  defp micros_to_usd_decimal(0), do: nil

  defp micros_to_usd_decimal(micros) do
    micros
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
    |> Decimal.round(6)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp percentage(_numerator, 0), do: nil
  defp percentage(numerator, denominator), do: Float.round(numerator / denominator * 100, 1)
end
