defmodule CodexPooler.Accounting.ObservatoryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Rollups
  alias CodexPooler.Accounting.Usage.Observatory
  alias CodexPooler.Repo

  test "baseline: API-key self usage reports persisted rollup and ledger facts" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    occurred_at = ~U[2026-07-17 10:30:00.000000Z]

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{status: "succeeded"})

    settlement =
      ledger_entry_fixture(request, %{
        occurred_at: occurred_at,
        created_at: occurred_at,
        input_tokens: 40,
        cached_input_tokens: 10,
        output_tokens: 20,
        reasoning_tokens: 5,
        total_tokens: 65,
        settled_cost_micros: 250_000,
        details: %{"pricing_status" => "priced", "settled_cost_micros" => "250000"}
      })

    assert :ok = Rollups.accumulate!(request, settlement)

    assert {:ok, usage} =
             Accounting.build_api_key_self_usage(pool, api_key,
               as_of: ~U[2026-07-17 11:00:00.000000Z]
             )

    assert usage.request_count == 1
    assert usage.total_tokens == 65
    assert usage.cached_input_tokens == 10
    assert usage.total_cost_status == "priced"
    assert Decimal.equal?(usage.total_cost_usd, Decimal.new("0.250000"))
  end

  test "one-hour Observatory projection uses exact exclusive bounds and twelve buckets" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-observatory-small"})
    upper_bound = ~U[2026-07-17 12:00:00Z]

    succeeded =
      timed_request(pool, api_key, ~U[2026-07-17 11:02:00Z], %{
        model_id: model.id,
        status: "succeeded"
      })

    succeeded_attempt = timed_attempt(succeeded, assignment, ~U[2026-07-17 11:02:00Z], 1_000)

    timed_settlement(
      succeeded,
      succeeded_attempt,
      assignment,
      identity,
      ~U[2026-07-17 11:02:01Z],
      %{
        input_tokens: 60,
        cached_input_tokens: 20,
        output_tokens: 30,
        reasoning_tokens: 10,
        total_tokens: 100,
        estimated_cost_micros: 900,
        settled_cost_micros: 700
      }
    )

    failed =
      timed_request(pool, api_key, ~U[2026-07-17 11:07:00Z], %{
        model_id: model.id,
        status: "failed",
        response_status_code: 502,
        last_error_code: "upstream_unavailable"
      })

    _failed_attempt = timed_attempt(failed, assignment, ~U[2026-07-17 11:07:00Z], 2_000)

    _in_progress =
      timed_request(pool, api_key, ~U[2026-07-17 11:58:00Z], %{
        model_id: model.id,
        status: "in_progress",
        completed_at: nil
      })

    _at_exclusive_bound =
      timed_request(pool, api_key, upper_bound, %{model_id: model.id, status: "succeeded"})

    assert {:ok, projection} =
             Observatory.read(dashboard_principal(pool, api_key), "1h", as_of: upper_bound)

    assert projection.window == %{
             key: "1h",
             started_at: ~U[2026-07-17 11:00:00Z],
             ended_at: upper_bound,
             bucket_seconds: 300,
             bucket_count: 12
           }

    assert projection.totals.requests == %{
             total: 3,
             succeeded: 1,
             failed: 1,
             in_progress: 1
           }

    assert projection.totals.tokens == %{
             input: 60,
             cached_input: 20,
             output: 30,
             reasoning: 10,
             total: 100
           }

    assert projection.totals.cache_rate_percent == 33.3
    assert projection.totals.cost.settled == %{status: "settled", micros: 700}
    assert projection.totals.cost.estimated == %{status: "unavailable", micros: 0}
    assert projection.totals.cost.confidence == "partial"
    assert projection.performance.latency_ms == %{mean: 1_500, p50: 1_500, p95: 1_950, max: 2_000}
    assert projection.performance.throughput_tokens_per_second == %{p50: 100.0, p95: 100.0}

    assert projection.trends == %{
             success_rate: %{current: 0.0, previous: 50.0, delta: -50.0},
             cache_rate: %{current: nil, previous: 33.3, delta: nil},
             throughput: %{current: nil, previous: 100.0, delta: nil}
           }

    assert length(projection.buckets) == 12
    assert Enum.at(projection.buckets, 0).requests.total == 1
    assert Enum.at(projection.buckets, 0).tokens.total == 100
    assert Enum.at(projection.buckets, 1).requests.failed == 1
    assert Enum.at(projection.buckets, 11).requests.in_progress == 1

    assert Enum.any?(projection.outcomes, &(&1.code == "service_unavailable"))
    refute inspect(projection, limit: :infinity) =~ ~r/\bupstream\b/i
  end

  test "Observatory projection excludes another key and a mismatched Pool" do
    pool = pool_fixture()
    wrong_pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    %{api_key: other_api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    %{identity: wrong_identity, assignment: wrong_assignment} =
      upstream_assignment_fixture(wrong_pool)

    model = model_fixture(pool, %{exposed_model_id: "gpt-visible"})
    hidden_model = model_fixture(wrong_pool, %{exposed_model_id: "gpt-hidden"})
    upper_bound = ~U[2026-07-17 12:00:00Z]

    visible =
      timed_request(pool, api_key, ~U[2026-07-17 11:30:00Z], %{
        model_id: model.id,
        status: "succeeded"
      })

    visible_attempt = timed_attempt(visible, assignment, ~U[2026-07-17 11:30:00Z], 500)

    timed_settlement(visible, visible_attempt, assignment, identity, ~U[2026-07-17 11:30:01Z], %{
      total_tokens: 10,
      settled_cost_micros: 10
    })

    hidden =
      timed_request(pool, other_api_key, ~U[2026-07-17 11:31:00Z], %{
        model_id: model.id,
        status: "failed"
      })

    hidden_attempt = timed_attempt(hidden, assignment, ~U[2026-07-17 11:31:00Z], 9_000)

    timed_settlement(hidden, hidden_attempt, assignment, identity, ~U[2026-07-17 11:31:01Z], %{
      total_tokens: 90_000,
      settled_cost_micros: 90_000
    })

    mismatched =
      timed_request(wrong_pool, api_key, ~U[2026-07-17 11:32:00Z], %{
        model_id: hidden_model.id,
        status: "failed"
      })

    mismatched_attempt =
      timed_attempt(mismatched, wrong_assignment, ~U[2026-07-17 11:32:00Z], 8_000)

    timed_settlement(
      mismatched,
      mismatched_attempt,
      wrong_assignment,
      wrong_identity,
      ~U[2026-07-17 11:32:01Z],
      %{total_tokens: 80_000, settled_cost_micros: 80_000}
    )

    assert {:ok, projection} =
             Observatory.read(dashboard_principal(pool, api_key), "1h", as_of: upper_bound)

    assert projection.totals.requests.total == 1
    assert projection.totals.tokens.total == 10
    assert projection.totals.cost.settled.micros == 10
    assert [%{label: "gpt-visible", total_tokens: 10}] = projection.models
    assert length(projection.outcomes) == 1
    refute inspect(projection) =~ "gpt-hidden"
    refute inspect(projection) =~ "90000"
    refute inspect(projection) =~ "80000"
  end

  defp dashboard_api_key_fixture(pool) do
    %{api_key: api_key} = active_api_key_fixture(pool)

    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp dashboard_principal(pool, api_key) do
    DashboardPrincipal.new(%{
      api_key_id: api_key.id,
      pool_id: pool.id,
      display_name: api_key.display_name,
      key_prefix: api_key.key_prefix
    })
  end

  defp timed_request(pool, api_key, timestamp, attrs) do
    timestamp = usec(timestamp)

    %{pool: pool, api_key: api_key}
    |> request_fixture(attrs)
    |> Ecto.Changeset.change(%{
      admitted_at: timestamp,
      completed_at: Map.get(attrs, :completed_at, timestamp)
    })
    |> Repo.update!()
  end

  defp timed_attempt(request, assignment, timestamp, latency_ms) do
    timestamp = usec(timestamp)

    request
    |> attempt_fixture(assignment, %{latency_ms: latency_ms})
    |> Ecto.Changeset.change(%{started_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp timed_settlement(request, attempt, assignment, identity, timestamp, attrs) do
    timestamp = usec(timestamp)

    attrs =
      Map.merge(
        %{
          attempt_id: attempt.id,
          pool_upstream_assignment_id: assignment.id,
          upstream_identity_id: identity.id,
          occurred_at: timestamp,
          created_at: timestamp,
          details: %{"pricing_status" => "priced"}
        },
        attrs
      )

    ledger_entry_fixture(request, attrs)
  end

  defp usec(timestamp), do: %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
end
