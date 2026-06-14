defmodule CodexPooler.Admin.StatsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.DailyRollup
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.Stats
  alias CodexPooler.Audit
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Repo

  test "build_dashboard/2 returns pool-scoped KPI, table, chart, session, and quota aggregates" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-primary", name: "Stats Primary"})
    other_pool = pool_fixture(%{slug: "stats-other", name: "Stats Other"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Stats key"})
    %{api_key: other_api_key} = active_api_key_fixture(other_pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    now = now()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-stats-mini",
        correlation_id: "stats-success",
        request_metadata: %{"safe_request" => "req-safe"}
      })

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(%{latency_ms: 500})
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      input_tokens: 60,
      output_tokens: 30,
      total_tokens: 100,
      estimated_cost_micros: 1_500_000,
      settled_cost_micros: 750_000
    })
    |> Ecto.Changeset.change(%{cached_input_tokens: 10, reasoning_tokens: 10})
    |> Repo.update!()

    failed_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-stats-mini",
        status: "failed",
        correlation_id: "stats-failed",
        response_status_code: 429
      })
      |> Ecto.Changeset.change(%{last_error_code: "upstream_rate_limited"})
      |> Repo.update!()

    _failed_attempt =
      failed_request
      |> attempt_fixture(assignment, %{status: "failed"})
      |> Ecto.Changeset.change(%{latency_ms: 1500, network_error_code: "upstream_rate_limited"})
      |> Repo.update!()

    _other_request =
      request_fixture(%{pool: other_pool, api_key: other_api_key}, %{
        requested_model: "gpt-other",
        correlation_id: "stats-other"
      })

    session = insert_active_session!(pool, api_key, now)
    insert_turn!(session, request, now, %{status: "succeeded"})
    insert_daily_rollup!(pool, api_key, now)
    upsert_primary_5h!(identity, now)

    assert {:ok, _audit_event} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "operator.update",
               target_type: "pool",
               target_id: pool.id,
               outcome: "success",
               occurred_at: now,
               details: %{"authorization" => "Bearer hidden", "safe" => "visible"}
             })

    assert {:ok, _job} = Jobs.enqueue_account_reconciliation(pool, assignment)

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{
               "pool_id" => pool.id,
               "window" => "24h",
               as_of: DateTime.add(now, 60, :second)
             })

    assert dashboard.selected_pool.name == "Stats Primary"
    assert dashboard.filters.pool_id == pool.id
    assert dashboard.kpis.requests.value == 2
    assert dashboard.kpis.requests.succeeded == 1
    assert dashboard.kpis.requests.failed == 1
    assert dashboard.kpis.success_rate.value == 50.0
    assert dashboard.kpis.tokens.total_tokens == 100
    assert dashboard.kpis.tokens.input_tokens == 60
    assert dashboard.kpis.tokens.cached_input_tokens == 10
    assert dashboard.kpis.tokens.output_tokens == 30
    assert dashboard.kpis.tokens.reasoning_tokens == 10
    assert dashboard.kpis.tokens_per_second.value == 50.0
    assert dashboard.kpis.settled_cost.status == "settled"
    assert dashboard.kpis.settled_cost.micros == 750_000
    assert Decimal.equal?(dashboard.kpis.settled_cost.usd, Decimal.new("0.750000"))
    assert dashboard.kpis.average_latency_ms.value == 1000
    assert dashboard.kpis.active_sessions.value == 1
    assert dashboard.kpis.turns.value == 1
    assert dashboard.kpis.quota_health.state == :available

    assert [
             %{
               display_name: "Stats key",
               pool_name: "Stats Primary",
               requests: 1,
               total_tokens: 100
             }
           ] =
             dashboard.tables.top_api_keys

    assert [%{quota_state: :available, requests: 1, total_tokens: 100}] =
             dashboard.tables.upstreams

    assert [%{error_code: "upstream_rate_limited", status: "failed"}] =
             dashboard.tables.recent_failures

    assert Enum.count(dashboard.charts.requests) == 24

    assert Enum.any?(
             dashboard.charts.tokens,
             &match?(
               %{
                 cached_input_tokens: 10,
                 input_tokens: 60,
                 output_tokens: 30,
                 reasoning_tokens: 10,
                 total_tokens: 100,
                 uncached_input_tokens: 50
               },
               &1
             )
           )

    assert Enum.any?(dashboard.charts.settled_cost, &(&1.settled_cost_micros == 750_000))
    assert [%{request_count: 1, total_tokens: 100}] = dashboard.tables.daily_rollups

    assert %{requests: 2, attempts: 2, settlements: 1, daily_rollups: 1, codex_turns: 1} =
             dashboard.sources

    assert Enum.any?(dashboard.tables.recent_activity, &(&1.type == :audit_event))
    assert Enum.any?(dashboard.tables.recent_activity, &(&1.type == :job))
    refute inspect(dashboard.tables.recent_activity) =~ "Bearer hidden"
  end

  test "build_dashboard/2 sorts upstream usage by tokens descending" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-upstream-sort", name: "Stats Upstream Sort"})
    %{api_key: api_key} = active_api_key_fixture(pool)

    %{identity: low_identity, assignment: low_assignment} =
      upstream_assignment_fixture(pool, %{assignment_label: "Low upstream"})

    %{identity: high_identity, assignment: high_assignment} =
      upstream_assignment_fixture(pool, %{assignment_label: "High upstream"})

    as_of = ~U[2026-01-10 12:00:00.000000Z]
    occurred_at = ~U[2026-01-10 11:30:00.000000Z]

    insert_timed_usage!(pool, api_key, low_assignment, low_identity, occurred_at, 10)
    insert_timed_usage!(pool, api_key, high_assignment, high_identity, occurred_at, 90)

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "1h", as_of: as_of})

    assert [
             %{assignment_label: "High upstream", total_tokens: 90},
             %{assignment_label: "Low upstream", total_tokens: 10}
           ] = dashboard.tables.upstreams
  end

  test "build_dashboard/2 returns hourly model usage top five plus Other for sub-day windows" do
    %{user: owner} = bootstrap_owner_fixture()
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    scope = Scope.for_user(admin)

    pool = pool_fixture(%{slug: "stats-model-usage", name: "Stats Model Usage"})
    hidden_pool = pool_fixture(%{slug: "stats-model-hidden", name: "Stats Model Hidden"})
    operator_pool_assignment_fixture(admin, pool, created_by_user_id: owner.id)

    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    %{api_key: hidden_api_key} = active_api_key_fixture(hidden_pool)

    %{identity: hidden_identity, assignment: hidden_assignment} =
      upstream_assignment_fixture(hidden_pool)

    as_of = ~U[2026-01-10 12:34:56.000000Z]
    current_bucket = truncate_to_hour(as_of)
    previous_bucket = DateTime.add(current_bucket, -1, :hour)
    before_window_bucket = DateTime.add(current_bucket, -5, :hour)
    after_window_bucket = DateTime.add(current_bucket, 1, :hour)

    m55 =
      model_fixture(pool, %{
        exposed_model_id: "gpt-5.5",
        display_name: "Display name must not label gpt-5.5"
      })

    m54 =
      model_fixture(pool, %{
        exposed_model_id: "gpt-5.4",
        display_name: "Display name must not label gpt-5.4"
      })

    m53 = model_fixture(pool, %{exposed_model_id: "gpt-5.3"})
    m50 = model_fixture(pool, %{exposed_model_id: "gpt-5.0"})
    m51 = model_fixture(pool, %{exposed_model_id: "gpt-5.1"})
    m41 = model_fixture(pool, %{exposed_model_id: "gpt-4.1"})
    zero = model_fixture(pool, %{exposed_model_id: "gpt-zero"})

    hidden_model =
      model_fixture(hidden_pool, %{
        exposed_model_id: "gpt-hidden-internal",
        display_name: "Hidden display name must not leak"
      })

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      m55,
      current_bucket,
      total_tokens: 900,
      input_tokens: 600,
      cached_input_tokens: 100,
      output_tokens: 200,
      reasoning_tokens: 100,
      request_count: 1,
      estimated_cost_micros: 901_000,
      settled_cost_micros: 899_000,
      ledger_total_tokens: 9
    )

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      m54,
      current_bucket,
      total_tokens: 700,
      request_count: 7,
      ledger_total_tokens: 7
    )

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      m53,
      previous_bucket,
      total_tokens: 700,
      request_count: 3,
      ledger_total_tokens: 7
    )

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      m50,
      current_bucket,
      total_tokens: 400,
      request_count: 5,
      ledger_total_tokens: 4
    )

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      m51,
      current_bucket,
      total_tokens: 400,
      request_count: 5,
      ledger_total_tokens: 4
    )

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      m41,
      current_bucket,
      total_tokens: 50,
      request_count: 1,
      ledger_total_tokens: 1
    )

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      zero,
      current_bucket,
      total_tokens: 0,
      request_count: 1,
      ledger_total_tokens: 0
    )

    insert_hourly_model_usage_rollup!(
      pool,
      m55,
      before_window_bucket,
      total_tokens: 999,
      request_count: 9
    )

    insert_hourly_model_usage_rollup!(
      pool,
      m55,
      after_window_bucket,
      total_tokens: 888,
      request_count: 8
    )

    insert_hourly_model_usage!(
      hidden_pool,
      hidden_api_key,
      hidden_assignment,
      hidden_identity,
      hidden_model,
      current_bucket,
      total_tokens: 10_000,
      request_count: 10,
      ledger_total_tokens: 10_000
    )

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{window: "5h", as_of: as_of})

    model_usage = Map.fetch!(dashboard.charts, :model_usage)

    assert model_usage_series_order(model_usage) == [
             "gpt-5.5",
             "gpt-5.4",
             "gpt-5.3",
             "gpt-5.0",
             "gpt-5.1",
             "Other"
           ]

    assert model_usage_total(model_usage, "gpt-5.5") == 900
    assert model_usage_total(model_usage, "Other") == 50
    assert model_usage_bucket_labels(model_usage) == hourly_bucket_labels(as_of, 5)
    assert length(model_usage) <= 6 * 5

    assert_model_usage_point!(model_usage, "gpt-5.5", hourly_bucket(current_bucket), %{
      request_count: 1,
      input_tokens: 600,
      cached_input_tokens: 100,
      output_tokens: 200,
      reasoning_tokens: 100,
      total_tokens: 900,
      estimated_cost_micros: 901_000,
      settled_cost_micros: 899_000
    })

    rendered = inspect(model_usage)

    refute rendered =~ "Display name must not label"
    refute rendered =~ "gpt-hidden-internal"
    refute rendered =~ "Hidden display name must not leak"
    refute rendered =~ "gpt-zero"
    refute rendered =~ hourly_bucket(before_window_bucket)
    refute rendered =~ hourly_bucket(after_window_bucket)

    assert dashboard.sources.model_usage_source == :hourly_model_usage_rollups
    assert dashboard.sources.model_usage_rows == length(model_usage)
  end

  test "build_dashboard/2 omits Other when non-top model rows have no positive tokens" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-model-no-other", name: "Stats Model No Other"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    as_of = ~U[2026-01-10 12:00:00.000000Z]
    bucket = truncate_to_hour(as_of)

    positive_models =
      for {code, tokens} <- [
            {"gpt-no-other-5", 500},
            {"gpt-no-other-4", 400},
            {"gpt-no-other-3", 300},
            {"gpt-no-other-2", 200},
            {"gpt-no-other-1", 100}
          ] do
        {model_fixture(pool, %{exposed_model_id: code}), tokens}
      end

    zero_model = model_fixture(pool, %{exposed_model_id: "gpt-no-other-zero"})

    for {model, tokens} <- positive_models do
      insert_hourly_model_usage!(
        pool,
        api_key,
        assignment,
        identity,
        model,
        bucket,
        total_tokens: tokens,
        request_count: 1,
        ledger_total_tokens: 1
      )
    end

    insert_hourly_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      zero_model,
      bucket,
      total_tokens: 0,
      request_count: 1,
      ledger_total_tokens: 0
    )

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "1h", as_of: as_of})

    model_usage = Map.fetch!(dashboard.charts, :model_usage)

    refute "Other" in model_usage_series_order(model_usage)
    refute inspect(model_usage) =~ "gpt-no-other-zero"
  end

  test "build_dashboard/2 returns daily model usage for seven day windows" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-model-daily", name: "Stats Model Daily"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    as_of = ~U[2026-01-10 12:00:00.000000Z]
    today = DateTime.to_date(as_of)
    first_visible_date = Date.add(today, -6)
    in_range_date = Date.add(today, -2)
    out_of_range_date = Date.add(today, -7)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-5.5-daily",
        display_name: "Daily display name must not label"
      })

    other_model = model_fixture(pool, %{exposed_model_id: "gpt-4.1-daily"})

    insert_daily_model_rollup!(
      pool,
      model,
      first_visible_date,
      total_tokens: 111,
      input_tokens: 70,
      cached_input_tokens: 10,
      output_tokens: 25,
      reasoning_tokens: 16,
      request_count: 2,
      estimated_cost_micros: 45_000,
      settled_cost_micros: 40_000
    )

    insert_daily_model_rollup!(
      pool,
      model,
      in_range_date,
      total_tokens: 321,
      input_tokens: 200,
      cached_input_tokens: 20,
      output_tokens: 80,
      reasoning_tokens: 41,
      request_count: 3,
      estimated_cost_micros: 123_000,
      settled_cost_micros: 120_000
    )

    insert_daily_model_rollup!(
      pool,
      other_model,
      out_of_range_date,
      total_tokens: 999,
      request_count: 9
    )

    insert_model_request_and_settlement!(
      pool,
      api_key,
      assignment,
      identity,
      model,
      DateTime.new!(in_range_date, ~T[10:00:00], "Etc/UTC"),
      total_tokens: 3
    )

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "7d", as_of: as_of})

    model_usage = Map.fetch!(dashboard.charts, :model_usage)

    assert model_usage_series_order(model_usage) == ["gpt-5.5-daily"]
    assert model_usage_bucket_labels(model_usage) == daily_bucket_labels(as_of)
    assert length(model_usage) <= 7

    assert_model_usage_point!(model_usage, "gpt-5.5-daily", Date.to_iso8601(in_range_date), %{
      request_count: 3,
      input_tokens: 200,
      cached_input_tokens: 20,
      output_tokens: 80,
      reasoning_tokens: 41,
      total_tokens: 321,
      estimated_cost_micros: 123_000,
      settled_cost_micros: 120_000
    })

    assert_model_usage_point!(
      model_usage,
      "gpt-5.5-daily",
      Date.to_iso8601(first_visible_date),
      %{
        request_count: 2,
        input_tokens: 70,
        cached_input_tokens: 10,
        output_tokens: 25,
        reasoning_tokens: 16,
        total_tokens: 111,
        estimated_cost_micros: 45_000,
        settled_cost_micros: 40_000
      }
    )

    rendered = inspect(model_usage)

    refute rendered =~ "Daily display name must not label"
    refute rendered =~ "gpt-4.1-daily"
    refute rendered =~ Date.to_iso8601(out_of_range_date)

    assert dashboard.sources.model_usage_source == :daily_model_rollups
    assert dashboard.sources.model_usage_rows == length(model_usage)
  end

  test "empty selected period returns typed empty states and unavailable KPI values" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-empty", name: "Stats Empty"})
    upstream_assignment_fixture(pool)
    as_of = ~U[2026-01-10 12:00:00.000000Z]

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "1h", as_of: as_of})

    assert dashboard.kpis.requests == %{value: 0, succeeded: 0, failed: 0, in_progress: 0}
    assert dashboard.kpis.success_rate == %{value: nil, unit: "percent"}
    assert dashboard.kpis.tokens.total_tokens == 0
    assert dashboard.kpis.tokens_per_second == %{value: nil, unit: "tokens/second"}
    assert dashboard.kpis.settled_cost == %{status: "unavailable", micros: 0, usd: nil}
    assert dashboard.kpis.average_latency_ms == %{value: nil, unit: "ms"}
    assert dashboard.kpis.turns == %{value: 0, succeeded: 0, failed: 0, in_progress: 0}
    assert dashboard.kpis.quota_health.state == :unknown
    assert Enum.map(dashboard.empty_states, & &1.code) == [:no_requests, :no_usage]
    assert [%{requests: 0, succeeded: 0, failed: 0}] = dashboard.charts.requests
    assert [%{total_tokens: 0}] = dashboard.charts.tokens
    assert Map.fetch!(dashboard.charts, :model_usage) == []
  end

  test "empty scoped dashboard returns an empty model usage chart" do
    %{user: owner} = bootstrap_owner_fixture()
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    hidden_pool = pool_fixture(%{slug: "stats-model-empty-hidden", name: "Stats Empty Hidden"})
    hidden_model = model_fixture(hidden_pool, %{exposed_model_id: "gpt-hidden-empty"})

    insert_hourly_model_usage_rollup!(
      hidden_pool,
      hidden_model,
      ~U[2026-01-10 12:00:00.000000Z],
      total_tokens: 500,
      request_count: 5
    )

    admin_scope = Scope.for_user(admin)

    assert {:ok, dashboard} =
             Stats.build_dashboard(admin_scope, %{
               window: "1h",
               as_of: ~U[2026-01-10 12:00:00.000000Z]
             })

    assert dashboard.filters.pool_options == []
    assert dashboard.charts.requests == []
    assert dashboard.charts.tokens == []
    assert dashboard.charts.settled_cost == []
    assert Map.fetch!(dashboard.charts, :model_usage) == []
  end

  test "dashboard activity sources use full-window counts while recent activity remains capped" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-activity-counts", name: "Stats Activity Counts"})
    started_at = ~U[2026-06-02 10:00:00.000000Z]
    ended_at = ~U[2026-06-02 11:00:00.000000Z]

    for index <- 1..12 do
      insert_activity_audit_event!(pool, DateTime.add(started_at, index, :minute))
    end

    for index <- 1..11 do
      insert_activity_job!(pool, DateTime.add(started_at, 20 + index, :minute))
    end

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "1h", as_of: ended_at})

    assert dashboard.sources.audit_events == 12
    assert dashboard.sources.jobs == 11
    assert length(dashboard.tables.recent_activity) == 10
    assert Enum.all?(dashboard.tables.recent_activity, &(&1.type in [:audit_event, :job]))
  end

  test "missing daily rollups still falls back to raw request and ledger data" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-rollup-fallback", name: "Stats Rollup Fallback"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    as_of = ~U[2026-01-10 12:00:00.000000Z]
    occurred_at = ~U[2026-01-10 11:30:00.000000Z]

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{correlation_id: "stats-raw-fallback"})
      |> set_request_time!(occurred_at)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(occurred_at, %{latency_ms: 250})

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: 42,
      input_tokens: 30,
      output_tokens: 12,
      estimated_cost_micros: 420_000,
      settled_cost_micros: 210_000
    })
    |> set_ledger_time!(occurred_at)

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "1h", as_of: as_of})

    assert dashboard.kpis.requests.value == 1
    assert dashboard.kpis.tokens.total_tokens == 42
    assert dashboard.kpis.settled_cost.micros == 210_000
    assert dashboard.tables.daily_rollups == []
    assert dashboard.sources.daily_rollups == 0
    assert dashboard.sources.usage_source == :raw_ledger_fallback
  end

  test "pool_usage_metrics_by_pool_ids/2 returns per-pool request and usage aggregates" do
    pool = pool_fixture(%{slug: "stats-pool-usage", name: "Stats Pool Usage"})
    other_pool = pool_fixture(%{slug: "stats-pool-usage-other", name: "Stats Pool Usage Other"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{api_key: other_api_key} = active_api_key_fixture(other_pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    %{identity: other_identity, assignment: other_assignment} =
      upstream_assignment_fixture(other_pool)

    as_of = ~U[2026-01-10 12:00:00.000000Z]
    occurred_at = ~U[2026-01-10 11:30:00.000000Z]

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{correlation_id: "stats-pool-usage"})
      |> set_request_time!(occurred_at)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(occurred_at, %{latency_ms: 2_000})

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: 100,
      input_tokens: 60,
      cached_input_tokens: 20,
      output_tokens: 40,
      estimated_cost_micros: 1_500_000,
      settled_cost_micros: 700_000
    })
    |> set_ledger_time!(occurred_at)

    insert_timed_usage!(
      other_pool,
      other_api_key,
      other_assignment,
      other_identity,
      DateTime.add(as_of, -6, :hour),
      50
    )

    insert_timed_usage!(
      pool,
      api_key,
      assignment,
      identity,
      DateTime.add(as_of, -6, :day),
      25
    )

    metrics = Stats.pool_usage_metrics_by_pool_ids([pool.id, other_pool.id], as_of: as_of)

    assert metrics[pool.id].request_count == 1
    assert metrics[pool.id].tokens_per_second == 50.0
    assert metrics[pool.id].token_usage.total_tokens == 100
    assert metrics[pool.id].token_usage.cached_input_tokens == 20
    assert metrics[pool.id].token_usage_weekly.total_tokens == 125
    assert metrics[pool.id].settled_cost_micros == 700_000
    assert length(metrics[pool.id].token_histogram) == 24
    assert Enum.any?(metrics[pool.id].token_histogram, &(&1.total_tokens == 100))
    assert Enum.sum(Enum.map(metrics[pool.id].token_histogram, & &1.total_tokens)) == 100
    assert length(metrics[pool.id].request_histogram) == 24
    assert Enum.any?(metrics[pool.id].request_histogram, &(&1.requests == 1))
    assert Enum.sum(Enum.map(metrics[pool.id].request_histogram, & &1.requests)) == 1

    assert metrics[other_pool.id].request_count == 1
    assert metrics[other_pool.id].tokens_per_second == 500.0
    assert metrics[other_pool.id].token_usage.total_tokens == 50
    assert metrics[other_pool.id].token_usage_weekly.total_tokens == 50
    assert metrics[other_pool.id].settled_cost_micros == 50
    assert Enum.sum(Enum.map(metrics[other_pool.id].token_histogram, & &1.total_tokens)) == 50
    assert Enum.sum(Enum.map(metrics[other_pool.id].request_histogram, & &1.requests)) == 1

    seven_day_metrics =
      Stats.pool_usage_metrics_by_pool_ids([pool.id], as_of: as_of, traffic_window: "7d")

    assert seven_day_metrics[pool.id].request_count == 2
    assert seven_day_metrics[pool.id].token_usage.total_tokens == 125
    assert seven_day_metrics[pool.id].settled_cost_micros == 700_025
    assert length(seven_day_metrics[pool.id].token_histogram) == 7

    assert Enum.sum(Enum.map(seven_day_metrics[pool.id].token_histogram, & &1.total_tokens)) ==
             125

    assert Enum.sum(Enum.map(seven_day_metrics[pool.id].request_histogram, & &1.requests)) == 2
  end

  test "UTC window boundaries include exact start and end and exclude adjacent rows" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-boundary", name: "Stats Boundary"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    as_of = ~U[2026-01-10 12:00:00.000000Z]
    started_at = ~U[2026-01-10 11:00:00.000000Z]
    before_start = ~U[2026-01-10 10:59:59.999999Z]
    after_end = ~U[2026-01-10 12:00:00.000001Z]

    insert_timed_usage!(pool, api_key, assignment, identity, before_start, 10)
    insert_timed_usage!(pool, api_key, assignment, identity, started_at, 20)
    insert_timed_usage!(pool, api_key, assignment, identity, as_of, 30)
    insert_timed_usage!(pool, api_key, assignment, identity, after_end, 40)

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "1h", as_of: as_of})

    assert dashboard.filters.started_at == started_at
    assert dashboard.filters.ended_at == as_of
    assert dashboard.kpis.requests.value == 2
    assert dashboard.kpis.tokens.total_tokens == 50
  end

  test "selected hard-deleted pool ids are excluded from management-visible stats" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-deleted", name: "Stats Deleted"})
    pool_id = pool.id
    Repo.delete!(pool)

    assert {:error, %{code: :pool_not_found}} =
             Stats.build_dashboard(scope, %{pool_id: pool_id, window: "24h"})
  end

  test "weekly-only free-plan quota evidence is not treated as zero or exhausted" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-free-plan", name: "Stats Free Plan"})
    %{identity: identity} = upstream_assignment_fixture(pool, %{plan_family: "free"})
    now = now()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 100,
                 used_percent: Decimal.new(25),
                 reset_at: DateTime.add(now, 7, :day),
                 source: "codex_usage",
                 source_precision: "authoritative",
                 quota_scope: "account",
                 quota_family: "account"
               }
             ])

    assert {:ok, dashboard} = Stats.build_dashboard(scope, %{pool_id: pool.id, window: "5h"})
    assert dashboard.kpis.quota_health.state == :weekly_only_evidence
    assert dashboard.kpis.quota_health.weekly_only_evidence == 1
    assert dashboard.kpis.quota_health.exhausted == 0

    assert [account] = dashboard.quota.accounts
    assert account.state == :weekly_only_evidence
    assert is_nil(account.primary_5h)
    assert account.secondary.window_minutes == 10_080
    assert account.secondary.used_percent == 25.0
  end

  test "monthly-only primary quota evidence is available with a separate 30d projection" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-monthly-plan", name: "Stats Monthly Plan"})
    %{identity: identity} = upstream_assignment_fixture(pool, %{plan_family: "free"})
    now = now()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "primary",
                 window_minutes: 43_200,
                 used_percent: Decimal.new("42.5"),
                 reset_at: DateTime.add(now, 30, :day),
                 source: "codex_usage",
                 source_precision: "authoritative",
                 quota_scope: "account",
                 quota_family: "account"
               }
             ])

    assert {:ok, dashboard} = Stats.build_dashboard(scope, %{pool_id: pool.id, window: "5h"})
    assert dashboard.kpis.quota_health.state == :available
    assert dashboard.kpis.quota_health.available == 1
    assert dashboard.kpis.quota_health.missing_evidence == 0
    assert dashboard.kpis.quota_health.exhausted == 0
    assert dashboard.kpis.quota_health.weekly_only_evidence == 0

    assert [account] = dashboard.quota.accounts
    assert account.state == :available
    assert is_nil(account.primary_5h)
    assert is_nil(account.secondary)
    assert account.primary_30d.window_kind == "primary"
    assert account.primary_30d.window_minutes == 43_200
    assert account.primary_30d.used_percent == 42.5
    assert account.primary_30d.routing_usable? == true
  end

  test "dashboard data is metadata-only and does not expose raw prompts, bodies, tokens, or idempotency keys" do
    scope = owner_scope()
    pool = pool_fixture(%{slug: "stats-redaction", name: "Stats Redaction"})
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    raw_prompt = "raw prompt that must never appear"
    raw_token = "access-token-that-must-never-appear"
    raw_idempotency_key = "idem-secret-that-must-never-appear"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "stats-redaction",
        request_metadata: %{
          "prompt" => raw_prompt,
          "authorization" => "Bearer #{raw_token}",
          "safe_request_id" => "req-safe"
        }
      })
      |> Ecto.Changeset.change(%{idempotency_key: raw_idempotency_key})
      |> Repo.update!()

    attempt = attempt_fixture(request, assignment)

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: 9,
      estimated_cost_micros: 0,
      details: %{"body" => raw_prompt, "access_token" => raw_token}
    })

    assert {:ok, dashboard} =
             Stats.build_dashboard(scope, %{pool_id: pool.id, window: "24h"})

    rendered = inspect(dashboard)

    refute rendered =~ raw_prompt
    refute rendered =~ raw_token
    refute rendered =~ raw_idempotency_key
    refute rendered =~ raw_key
    refute Map.has_key?(hd(dashboard.tables.recent_failures ++ [%{}]), :metadata)
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end

  defp insert_active_session!(pool, api_key, now) do
    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "stats-session-#{System.unique_integer([:positive])}",
      status: "active",
      owner_instance_id: "test-instance",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 60, :second),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_turn!(session, request, now, attrs) do
    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: Map.get(attrs, :turn_sequence, 1),
      transport_kind: request.transport,
      status: Map.get(attrs, :status, "in_progress"),
      started_at: now,
      completed_at: Map.get(attrs, :completed_at, now),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_daily_rollup!(pool, api_key, now) do
    %DailyRollup{
      rollup_date: DateTime.to_date(now),
      dimension_kind: "api_key",
      pool_id: pool.id,
      api_key_id: api_key.id,
      request_count: 1,
      success_count: 1,
      failure_count: 0,
      retry_count: 0,
      input_tokens: 60,
      cached_input_tokens: 10,
      output_tokens: 30,
      reasoning_tokens: 10,
      total_tokens: 100,
      estimated_cost_micros: Decimal.new(1_500_000),
      settled_cost_micros: Decimal.new(750_000),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_activity_audit_event!(pool, occurred_at) do
    assert {:ok, audit_event} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "stats.activity_count",
               target_type: "pool",
               target_id: pool.id,
               outcome: "success",
               occurred_at: occurred_at,
               details: %{"safe" => "stats-dashboard-test"}
             })

    audit_event
  end

  defp insert_activity_job!(pool, inserted_at) do
    index = System.unique_integer([:positive])

    assert {:ok, job} =
             %{"pool_id" => pool.id, "index" => index}
             |> RuntimeStateCleanupWorker.new(
               meta: %{"source" => "stats-dashboard-test"},
               unique: false
             )
             |> Oban.insert()

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.update_all(set: [inserted_at: inserted_at, scheduled_at: inserted_at])

    Repo.get!(Oban.Job, job.id)
  end

  defp insert_timed_usage!(pool, api_key, assignment, identity, timestamp, tokens) do
    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "stats-boundary-#{System.unique_integer([:positive])}"
      })
      |> set_request_time!(timestamp)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(timestamp, %{latency_ms: 100})

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: tokens,
      input_tokens: tokens,
      output_tokens: 0,
      estimated_cost_micros: tokens,
      settled_cost_micros: tokens
    })
    |> set_ledger_time!(timestamp)

    request
  end

  defp insert_hourly_model_usage!(pool, api_key, assignment, identity, model, bucket, attrs) do
    insert_model_request_and_settlement!(
      pool,
      api_key,
      assignment,
      identity,
      model,
      bucket,
      total_tokens: Keyword.get(attrs, :ledger_total_tokens, Keyword.fetch!(attrs, :total_tokens))
    )

    insert_hourly_model_usage_rollup!(pool, model, bucket, attrs)
  end

  defp insert_model_request_and_settlement!(
         pool,
         api_key,
         assignment,
         identity,
         model,
         timestamp,
         attrs
       ) do
    timestamp = to_utc_datetime_usec(timestamp)
    total_tokens = Keyword.fetch!(attrs, :total_tokens)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: "requested-#{model.exposed_model_id}",
        correlation_id: "stats-model-#{System.unique_integer([:positive])}"
      })
      |> set_request_time!(timestamp)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(timestamp, %{latency_ms: 100})

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: total_tokens,
      input_tokens: total_tokens,
      output_tokens: 0,
      estimated_cost_micros: 0
    })
    |> Ecto.Changeset.change(%{
      model_id: model.id,
      occurred_at: timestamp,
      created_at: timestamp
    })
    |> Repo.update!()

    request
  end

  defp insert_hourly_model_usage_rollup!(pool, model, bucket, attrs) do
    total_tokens = Keyword.fetch!(attrs, :total_tokens)
    request_count = Keyword.get(attrs, :request_count, 1)
    now = now()

    Repo.insert_all("hourly_model_usage_rollups", [
      %{
        bucket_started_at: truncate_to_hour(bucket),
        pool_id: Ecto.UUID.dump!(pool.id),
        model_id: Ecto.UUID.dump!(model.id),
        model_code: Keyword.get(attrs, :model_code, model.exposed_model_id),
        request_count: request_count,
        success_count: Keyword.get(attrs, :success_count, request_count),
        failure_count: Keyword.get(attrs, :failure_count, 0),
        retry_count: Keyword.get(attrs, :retry_count, 0),
        input_tokens: Keyword.get(attrs, :input_tokens, total_tokens),
        cached_input_tokens: Keyword.get(attrs, :cached_input_tokens, 0),
        output_tokens: Keyword.get(attrs, :output_tokens, 0),
        reasoning_tokens: Keyword.get(attrs, :reasoning_tokens, 0),
        total_tokens: total_tokens,
        estimated_cost_micros: Decimal.new(Keyword.get(attrs, :estimated_cost_micros, 0)),
        settled_cost_micros: Decimal.new(Keyword.get(attrs, :settled_cost_micros, 0)),
        created_at: now,
        updated_at: now
      }
    ])
  end

  defp insert_daily_model_rollup!(pool, model, date, attrs) do
    total_tokens = Keyword.fetch!(attrs, :total_tokens)
    request_count = Keyword.get(attrs, :request_count, 1)
    now = now()

    %DailyRollup{
      rollup_date: date,
      dimension_kind: "model",
      pool_id: pool.id,
      model_id: model.id,
      request_count: request_count,
      success_count: Keyword.get(attrs, :success_count, request_count),
      failure_count: Keyword.get(attrs, :failure_count, 0),
      retry_count: Keyword.get(attrs, :retry_count, 0),
      input_tokens: Keyword.get(attrs, :input_tokens, total_tokens),
      cached_input_tokens: Keyword.get(attrs, :cached_input_tokens, 0),
      output_tokens: Keyword.get(attrs, :output_tokens, 0),
      reasoning_tokens: Keyword.get(attrs, :reasoning_tokens, 0),
      total_tokens: total_tokens,
      estimated_cost_micros: Decimal.new(Keyword.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: Decimal.new(Keyword.get(attrs, :settled_cost_micros, 0)),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp assert_model_usage_point!(rows, model_code, bucket, expected) do
    row =
      Enum.find(rows, fn row ->
        row.model_code == model_code and row.bucket == bucket
      end)

    assert row

    assert Map.take(row, Map.keys(expected)) == expected
  end

  defp model_usage_series_order(rows) do
    rows
    |> Enum.map(& &1.model_code)
    |> Enum.uniq()
  end

  defp model_usage_total(rows, model_code) do
    rows
    |> Enum.filter(&(&1.model_code == model_code))
    |> Enum.reduce(0, &(&1.total_tokens + &2))
  end

  defp model_usage_bucket_labels(rows) do
    rows
    |> Enum.map(& &1.bucket)
    |> Enum.uniq()
  end

  defp hourly_bucket_labels(as_of, count) do
    current_hour = truncate_to_hour(as_of)

    (count - 1)..0//-1
    |> Enum.map(&DateTime.add(current_hour, -&1, :hour))
    |> Enum.map(&hourly_bucket/1)
  end

  defp daily_bucket_labels(as_of) do
    today = DateTime.to_date(as_of)

    6..0//-1
    |> Enum.map(&Date.add(today, -&1))
    |> Enum.map(&Date.to_iso8601/1)
  end

  defp hourly_bucket(datetime) do
    datetime = truncate_to_hour(datetime)
    date = datetime |> DateTime.to_date() |> Date.to_iso8601()
    hour = datetime.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    date <> "T" <> hour <> ":00:00Z"
  end

  defp truncate_to_hour(datetime) do
    %{datetime | minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp to_utc_datetime_usec(datetime) do
    %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
  end

  defp set_request_time!(request, timestamp) do
    request
    |> Ecto.Changeset.change(%{admitted_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp set_attempt_time!(attempt, timestamp, attrs) do
    attempt
    |> Ecto.Changeset.change(Map.merge(%{started_at: timestamp, completed_at: timestamp}, attrs))
    |> Repo.update!()
  end

  defp set_ledger_time!(ledger_entry, timestamp) do
    ledger_entry
    |> Ecto.Changeset.change(%{occurred_at: timestamp, created_at: timestamp})
    |> Repo.update!()
  end

  defp upsert_primary_5h!(identity, now) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 100,
                 used_percent: Decimal.new(10),
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_rate_limits",
                 source_precision: "authoritative",
                 quota_scope: "account",
                 quota_family: "account"
               }
             ])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
