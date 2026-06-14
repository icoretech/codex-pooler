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
  @pool_default_window :twenty_four_hours
  @pool_windows %{
    "1h" => :one_hour,
    "5h" => :five_hours,
    "24h" => :twenty_four_hours,
    "7d" => :seven_days,
    one_hour: :one_hour,
    five_hours: :five_hours,
    twenty_four_hours: :twenty_four_hours,
    seven_days: :seven_days
  }

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type pool_usage_opt ::
          {:as_of, DateTime.t()}
          | {:started_at, DateTime.t()}
          | {:weekly_started_at, DateTime.t()}
          | {:histogram_started_at, DateTime.t()}
          | {:traffic_window, String.t() | atom()}
          | {:histogram_window, String.t() | atom()}
  @type pool_usage_metrics :: %{
          required(:request_count) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil,
          required(:total_tokens) => non_neg_integer(),
          required(:latency_ms) => non_neg_integer(),
          required(:token_usage) => map(),
          required(:token_usage_weekly) => map(),
          required(:token_histogram) => [map()],
          required(:request_histogram) => [map()],
          required(:settled_cost_micros) => non_neg_integer()
        }

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
  def pool_usage_metrics_by_pool_ids(pool_ids, opts \\ [])

  def pool_usage_metrics_by_pool_ids(pool_ids, opts) when is_list(pool_ids) and is_list(opts) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    ended_at = Keyword.get_lazy(opts, :as_of, &now/0)
    window = pool_window(opts)

    started_at =
      Keyword.get(
        opts,
        :started_at,
        pool_default_started_at(ended_at, window)
      )

    weekly_started_at = Keyword.get(opts, :weekly_started_at, DateTime.add(ended_at, -7, :day))

    request_counts = GatewayReadModel.request_counts_by_pool_ids(pool_ids, started_at, ended_at)
    token_totals = AccountingReporting.token_totals_by_pool_ids(pool_ids, started_at, ended_at)
    latency_totals = GatewayReadModel.latency_totals_by_pool_ids(pool_ids, started_at, ended_at)
    token_usage = AccountingReporting.token_usage_by_pool_ids(pool_ids, started_at, ended_at)

    token_usage_weekly =
      AccountingReporting.token_usage_by_pool_ids(pool_ids, weekly_started_at, ended_at)

    histogram_started_at =
      Keyword.get(
        opts,
        :histogram_started_at,
        started_at
      )

    histogram_settlements =
      AccountingReporting.settlements_for_pool_ids(pool_ids, histogram_started_at, ended_at)

    token_histograms = pool_token_histograms(pool_ids, histogram_settlements, ended_at, window)
    cost_micros = pool_settled_cost_micros(pool_ids, histogram_settlements)

    request_histograms =
      pool_request_histograms(
        pool_ids,
        GatewayReadModel.bucketed_request_counts_by_pool_ids(
          pool_ids,
          histogram_started_at,
          ended_at,
          pool_bucket_granularity(window)
        ),
        ended_at,
        window
      )

    Enum.into(pool_ids, %{}, fn pool_id ->
      total_tokens = Map.get(token_totals, pool_id, 0)
      latency_ms = Map.get(latency_totals, pool_id, 0)

      tokens_per_second =
        pool_tokens_per_second(
          total_tokens,
          latency_ms
        )

      {pool_id,
       %{
         request_count: Map.get(request_counts, pool_id, 0),
         tokens_per_second: tokens_per_second,
         total_tokens: total_tokens,
         latency_ms: latency_ms,
         token_usage: Map.get(token_usage, pool_id, empty_token_usage()),
         token_usage_weekly: Map.get(token_usage_weekly, pool_id, empty_token_usage()),
         token_histogram: Map.fetch!(token_histograms, pool_id),
         request_histogram: Map.fetch!(request_histograms, pool_id),
         settled_cost_micros: Map.fetch!(cost_micros, pool_id)
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

    model_usage_report =
      AccountingReporting.model_usage_buckets_for_pool_ids(
        pool_ids,
        normalized.window,
        normalized.started_at,
        normalized.ended_at
      )

    model_usage = model_usage_series(model_usage_report.rows, normalized)

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
        settled_cost: settled_cost_kpi(settlements),
        average_latency_ms: average_latency_kpi(attempts),
        active_sessions: %{value: active_session_count},
        turns: turn_kpi(turns),
        quota_health: quota_summary
      },
      tables: %{
        top_api_keys: top_api_keys(settlements, pools),
        upstreams: upstream_table(settlements, quota_accounts),
        recent_failures: recent_failures(requests),
        daily_rollups: daily_rollup_table(daily_rollups),
        recent_activity: recent_activity
      },
      charts: %{
        requests: request_series(requests, normalized),
        tokens: token_series(settlements, normalized),
        settled_cost: cost_series(settlements, normalized),
        model_usage: model_usage
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
          activity_counts,
          model_usage_report.source,
          length(model_usage)
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
        settled_cost: settled_cost_kpi([]),
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
        settled_cost: [],
        model_usage: []
      },
      quota: %{
        summary: quota_summary,
        accounts: []
      },
      sources: source_summary([], [], [], [], [], %{audit_events: 0, jobs: 0}, nil, 0),
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

  defp pool_window(opts) do
    opts
    |> Keyword.get(:traffic_window, Keyword.get(opts, :histogram_window, @pool_default_window))
    |> then(&Map.get(@pool_windows, &1, @pool_default_window))
  end

  defp pool_window_seconds(:one_hour), do: 60 * 60
  defp pool_window_seconds(:five_hours), do: 5 * 60 * 60
  defp pool_window_seconds(:twenty_four_hours), do: 24 * 60 * 60

  defp pool_default_started_at(ended_at, :seven_days) do
    ended_at
    |> DateTime.to_date()
    |> Date.add(-6)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp pool_default_started_at(ended_at, window) do
    DateTime.add(ended_at, -pool_window_seconds(window), :second)
  end

  defp pool_bucket_granularity(:seven_days), do: :day
  defp pool_bucket_granularity(_window), do: :hour

  defp pool_token_histograms(pool_ids, settlements, ended_at, window) do
    labels = bucket_labels(%{window: window, ended_at: ended_at})

    entries_by_pool_bucket =
      Enum.group_by(settlements, fn settlement ->
        {settlement.pool_id, bucket_label(settlement.occurred_at, window)}
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

  defp pool_request_histograms(pool_ids, request_counts, ended_at, window) do
    labels = bucket_labels(%{window: window, ended_at: ended_at})

    requests_by_pool_bucket =
      Map.new(request_counts, fn row ->
        {{row.pool_id, bucket_label(row.bucket, window)}, row.requests}
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

  defp pool_settled_cost_micros(pool_ids, settlements) do
    entries_by_pool_id = Enum.group_by(settlements, & &1.pool_id)

    Map.new(pool_ids, fn pool_id ->
      entries = Map.get(entries_by_pool_id, pool_id, [])
      {pool_id, sum_decimal_integer(entries, :settled_cost_micros)}
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

  defp settled_cost_kpi([]), do: %{status: "unavailable", micros: 0, usd: nil}

  defp settled_cost_kpi(settlements) do
    micros = sum_decimal_integer(settlements, :settled_cost_micros)

    %{
      status: if(micros > 0, do: "settled", else: "unpriced"),
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

  defp top_api_keys([], _pools), do: []

  defp top_api_keys(settlements, pools) do
    key_ids = settlements |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    keys_by_id = AccessReporting.api_keys_by_id(key_ids)
    pool_names_by_id = Map.new(pools, &{&1.id, &1.name})

    settlements
    |> Enum.group_by(& &1.api_key_id)
    |> Enum.map(fn {api_key_id, entries} ->
      api_key = Map.get(keys_by_id, api_key_id)

      %{
        api_key_id: api_key_id,
        display_name: api_key && api_key.display_name,
        pool_name: usage_pool_name(entries, pool_names_by_id),
        requests: sum_integer(entries, :request_count),
        total_tokens: sum_integer(entries, :total_tokens),
        settled_cost_micros: sum_decimal_integer(entries, :settled_cost_micros)
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
        settled_cost_micros: sum_decimal_integer(entries, :settled_cost_micros)
      }
    end)
    |> Enum.sort_by(fn row ->
      {-row.total_tokens, -row.requests, row.assignment_label || row.upstream_label || ""}
    end)
  end

  defp usage_pool_name(entries, pool_names_by_id) do
    entries
    |> Enum.map(& &1.pool_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> case do
      [pool_id] -> Map.get(pool_names_by_id, pool_id)
      [] -> nil
      _pool_ids -> "Multiple Pools"
    end
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
        settled_cost_micros: decimal_to_integer(rollup.settled_cost_micros)
      }
    end)
  end

  defp source_summary(
         requests,
         attempts,
         settlements,
         daily_rollups,
         turns,
         activity_counts,
         model_usage_source,
         model_usage_rows
       ) do
    %{
      requests: length(requests),
      attempts: length(attempts),
      settlements: length(settlements),
      daily_rollups: length(daily_rollups),
      codex_turns: length(turns),
      audit_events: activity_counts.audit_events,
      jobs: activity_counts.jobs,
      model_usage_source: model_usage_source,
      model_usage_rows: model_usage_rows,
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

      input_tokens = sum_integer(entries, :input_tokens)
      cached_input_tokens = sum_integer(entries, :cached_input_tokens)

      %{
        bucket: label,
        input_tokens: input_tokens,
        cached_input_tokens: cached_input_tokens,
        uncached_input_tokens: max(input_tokens - cached_input_tokens, 0),
        output_tokens: sum_integer(entries, :output_tokens),
        reasoning_tokens: sum_integer(entries, :reasoning_tokens),
        total_tokens: sum_integer(entries, :total_tokens)
      }
    end)
  end

  defp cost_series(settlements, normalized) do
    buckets = bucket_labels(normalized)
    grouped = Enum.group_by(settlements, &bucket_label(&1.occurred_at, normalized.window))

    Enum.map(buckets, fn label ->
      entries = Map.get(grouped, label, [])

      %{
        bucket: label,
        settled_cost_micros: sum_decimal_integer(entries, :settled_cost_micros)
      }
    end)
  end

  defp model_usage_series(rows, normalized) do
    buckets = bucket_labels(normalized)
    bucket_set = MapSet.new(buckets)

    bucketed_rows =
      rows
      |> Enum.map(&normalize_model_usage_bucket(&1, normalized.window))
      |> Enum.filter(&(&1.bucket in bucket_set and &1.model_code != ""))
      |> aggregate_model_usage_rows()

    ranked_models =
      bucketed_rows
      |> model_usage_totals()
      |> Enum.filter(&(&1.total_tokens > 0))
      |> Enum.sort_by(fn row -> {-row.total_tokens, -row.request_count, row.model_code} end)

    top_model_codes =
      ranked_models
      |> Enum.take(5)
      |> Enum.map(& &1.model_code)

    other_model_codes =
      ranked_models
      |> Enum.drop(5)
      |> Enum.map(& &1.model_code)

    top_rows =
      Enum.flat_map(top_model_codes, fn model_code ->
        model_usage_rows_for_model(bucketed_rows, buckets, model_code)
      end)

    case other_model_codes do
      [] ->
        top_rows

      _other_model_codes ->
        top_rows ++ model_usage_rows_for_other(bucketed_rows, buckets, other_model_codes)
    end
  end

  defp normalize_model_usage_bucket(row, window) do
    %{
      bucket: model_usage_bucket_label(row.bucket, window),
      model_code: row.model_code || "",
      request_count: model_usage_integer(row, :request_count),
      input_tokens: model_usage_integer(row, :input_tokens),
      cached_input_tokens: model_usage_integer(row, :cached_input_tokens),
      output_tokens: model_usage_integer(row, :output_tokens),
      reasoning_tokens: model_usage_integer(row, :reasoning_tokens),
      total_tokens: model_usage_integer(row, :total_tokens),
      estimated_cost_micros: model_usage_integer(row, :estimated_cost_micros),
      settled_cost_micros: model_usage_integer(row, :settled_cost_micros)
    }
  end

  defp model_usage_integer(row, field), do: Map.get(row, field) || 0

  defp aggregate_model_usage_rows(rows) do
    rows
    |> Enum.group_by(&{&1.model_code, &1.bucket})
    |> Map.new(fn {{model_code, bucket}, bucket_rows} ->
      {{model_code, bucket}, aggregate_model_usage_row(model_code, bucket, bucket_rows)}
    end)
  end

  defp model_usage_totals(bucketed_rows) do
    bucketed_rows
    |> Map.values()
    |> Enum.group_by(& &1.model_code)
    |> Enum.map(fn {model_code, rows} ->
      %{
        model_code: model_code,
        request_count: sum_integer(rows, :request_count),
        total_tokens: sum_integer(rows, :total_tokens)
      }
    end)
  end

  defp model_usage_rows_for_model(bucketed_rows, buckets, model_code) do
    Enum.map(buckets, fn bucket ->
      Map.get(bucketed_rows, {model_code, bucket}, empty_model_usage_row(model_code, bucket))
    end)
  end

  defp model_usage_rows_for_other(bucketed_rows, buckets, other_model_codes) do
    other_model_codes = MapSet.new(other_model_codes)

    Enum.map(buckets, fn bucket ->
      rows =
        bucketed_rows
        |> Map.values()
        |> Enum.filter(&(&1.bucket == bucket and &1.model_code in other_model_codes))

      aggregate_model_usage_row("Other", bucket, rows)
    end)
  end

  defp aggregate_model_usage_row(model_code, bucket, rows) do
    %{
      bucket: bucket,
      model_code: model_code,
      request_count: sum_integer(rows, :request_count),
      input_tokens: sum_integer(rows, :input_tokens),
      cached_input_tokens: sum_integer(rows, :cached_input_tokens),
      output_tokens: sum_integer(rows, :output_tokens),
      reasoning_tokens: sum_integer(rows, :reasoning_tokens),
      total_tokens: sum_integer(rows, :total_tokens),
      estimated_cost_micros: sum_integer(rows, :estimated_cost_micros),
      settled_cost_micros: sum_integer(rows, :settled_cost_micros)
    }
  end

  defp empty_model_usage_row(model_code, bucket) do
    aggregate_model_usage_row(model_code, bucket, [])
  end

  defp model_usage_bucket_label(%Date{} = date, _window), do: Date.to_iso8601(date)

  defp model_usage_bucket_label(%DateTime{} = datetime, window),
    do: bucket_label(datetime, window)

  defp model_usage_bucket_label(bucket, _window) when is_binary(bucket), do: bucket
  defp model_usage_bucket_label(_bucket, _window), do: nil

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
