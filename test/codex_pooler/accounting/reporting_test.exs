defmodule CodexPooler.Accounting.ReportingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.Reporting
  alias CodexPooler.Admin.Stats.Aggregates
  alias CodexPooler.Repo

  test "reporting consumption totals exclude usage_unknown settlement estimates" do
    pool = pool_fixture(%{slug: "reporting-known-only", name: "Reporting Known Only"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    started_at = ~U[2026-01-10 11:00:00.000000Z]
    ended_at = ~U[2026-01-10 12:00:00.000000Z]
    occurred_at = ~U[2026-01-10 11:30:00.000000Z]

    insert_settlement!(pool, api_key, assignment, identity, occurred_at, %{
      total_tokens: 100,
      input_tokens: 60,
      cached_input_tokens: 20,
      output_tokens: 30,
      reasoning_tokens: 10,
      estimated_cost_micros: 1_500_000,
      settled_cost_micros: 700_000
    })

    insert_settlement!(pool, api_key, assignment, identity, occurred_at, %{
      usage_status: "usage_unknown",
      total_tokens: 20_000,
      input_tokens: 12_000,
      cached_input_tokens: 4_000,
      output_tokens: 6_000,
      reasoning_tokens: 2_000,
      estimated_cost_micros: 200_000_000,
      settled_cost_micros: 90_000_000
    })

    assert Reporting.token_totals_by_pool_ids([pool.id], started_at, ended_at) == %{
             pool.id => 100
           }

    assert Reporting.token_totals_by_upstream_identity_ids([identity.id], started_at, ended_at) ==
             %{identity.id => 100}

    assert Reporting.token_usage_by_pool_ids([pool.id], started_at, ended_at) == %{
             pool.id => %{
               cached_input_tokens: 20,
               input_tokens: 60,
               output_tokens: 30,
               reasoning_tokens: 10,
               total_tokens: 100
             }
           }

    settlements = Reporting.settlements_for_pool_ids([pool.id], started_at, ended_at)

    assert Enum.sum(Enum.map(settlements, & &1.request_count)) == 2
    assert Enum.sum(Enum.map(settlements, & &1.total_tokens)) == 100
    assert Enum.sum(Enum.map(settlements, & &1.input_tokens)) == 60
    assert Enum.sum(Enum.map(settlements, & &1.cached_input_tokens)) == 20
    assert Enum.sum(Enum.map(settlements, & &1.output_tokens)) == 30
    assert Enum.sum(Enum.map(settlements, & &1.reasoning_tokens)) == 10
    assert sum_decimal_integer(settlements, :estimated_cost_micros) == 1_500_000
    assert sum_decimal_integer(settlements, :settled_cost_micros) == 700_000
  end

  test "settlement usage buckets aggregate exact inclusive windows without model rollups" do
    first_pool = pool_fixture(%{slug: "reporting-buckets-first", name: "Reporting Buckets First"})

    second_pool =
      pool_fixture(%{slug: "reporting-buckets-second", name: "Reporting Buckets Second"})

    %{api_key: first_api_key} = active_api_key_fixture(first_pool)
    %{api_key: second_api_key} = active_api_key_fixture(second_pool)

    %{identity: first_identity, assignment: first_assignment} =
      upstream_assignment_fixture(first_pool)

    %{identity: second_identity, assignment: second_assignment} =
      upstream_assignment_fixture(second_pool)

    started_at = ~U[2026-01-10 11:34:56.000000Z]
    ended_at = ~U[2026-01-10 12:34:56.000000Z]

    for {timestamp, tokens, cost} <- [
          {DateTime.add(started_at, -1, :microsecond), 1, 1},
          {started_at, 20, 200},
          {~U[2026-01-10 12:05:00.000000Z], 30, 300},
          {ended_at, 40, 400},
          {DateTime.add(ended_at, 1, :microsecond), 2, 2}
        ] do
      insert_settlement!(
        first_pool,
        first_api_key,
        first_assignment,
        first_identity,
        timestamp,
        %{
          total_tokens: tokens,
          input_tokens: tokens,
          output_tokens: 0,
          settled_cost_micros: cost
        }
      )
    end

    insert_settlement!(
      first_pool,
      first_api_key,
      first_assignment,
      first_identity,
      ~U[2026-01-10 12:15:00.000000Z],
      %{
        usage_status: "usage_unknown",
        total_tokens: 50_000,
        input_tokens: 50_000,
        output_tokens: 50_000,
        settled_cost_micros: 50_000
      }
    )

    insert_settlement!(
      second_pool,
      second_api_key,
      second_assignment,
      second_identity,
      ~U[2026-01-10 12:20:00.000000Z],
      %{total_tokens: 7, input_tokens: 7, output_tokens: 0, settled_cost_micros: 70}
    )

    rows =
      Reporting.settlement_usage_buckets_for_pool_ids(
        [first_pool.id, second_pool.id],
        :hour,
        started_at,
        ended_at
      )

    assert Map.new(rows, &{{&1.pool_id, &1.bucket}, &1}) == %{
             {first_pool.id, ~U[2026-01-10 11:00:00.000000Z]} => %{
               pool_id: first_pool.id,
               bucket: ~U[2026-01-10 11:00:00.000000Z],
               request_count: 1,
               input_tokens: 20,
               cached_input_tokens: 0,
               output_tokens: 0,
               reasoning_tokens: 0,
               total_tokens: 20,
               settled_cost_micros: 200
             },
             {first_pool.id, ~U[2026-01-10 12:00:00.000000Z]} => %{
               pool_id: first_pool.id,
               bucket: ~U[2026-01-10 12:00:00.000000Z],
               request_count: 3,
               input_tokens: 70,
               cached_input_tokens: 0,
               output_tokens: 0,
               reasoning_tokens: 0,
               total_tokens: 70,
               settled_cost_micros: 700
             },
             {second_pool.id, ~U[2026-01-10 12:00:00.000000Z]} => %{
               pool_id: second_pool.id,
               bucket: ~U[2026-01-10 12:00:00.000000Z],
               request_count: 1,
               input_tokens: 7,
               cached_input_tokens: 0,
               output_tokens: 0,
               reasoning_tokens: 0,
               total_tokens: 7,
               settled_cost_micros: 70
             }
           }

    assert Reporting.settlement_usage_buckets_for_pool_ids(
             [first_pool.id],
             :day,
             started_at,
             ended_at
           ) == [
             %{
               pool_id: first_pool.id,
               bucket: ~U[2026-01-10 00:00:00.000000Z],
               request_count: 4,
               input_tokens: 90,
               cached_input_tokens: 0,
               output_tokens: 0,
               reasoning_tokens: 0,
               total_tokens: 90,
               settled_cost_micros: 900
             }
           ]
  end

  test "settlement usage buckets reject unsupported shapes without querying" do
    started_at = ~U[2026-01-10 11:00:00.000000Z]
    ended_at = ~U[2026-01-10 12:00:00.000000Z]

    assert Reporting.settlement_usage_buckets_for_pool_ids([], :hour, started_at, ended_at) == []

    assert Reporting.settlement_usage_buckets_for_pool_ids(
             [nil, 123],
             :hour,
             started_at,
             ended_at
           ) == []

    assert Reporting.settlement_usage_buckets_for_pool_ids(
             [Ecto.UUID.generate()],
             :minute,
             started_at,
             ended_at
           ) == []

    assert Reporting.settlement_usage_buckets_for_pool_ids(
             [Ecto.UUID.generate()],
             :hour,
             ended_at,
             started_at
           ) == []
  end

  test "settlement usage buckets preserve legacy per-settlement fractional cost rounding" do
    pool = pool_fixture(%{slug: "reporting-fractional-cost", name: "Reporting Fractional Cost"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    started_at = ~U[2026-01-10 11:00:00.000000Z]
    ended_at = ~U[2026-01-10 12:00:00.000000Z]
    occurred_at = ~U[2026-01-10 11:30:00.000000Z]

    for _index <- 1..2 do
      insert_settlement!(pool, api_key, assignment, identity, occurred_at, %{
        total_tokens: 1,
        input_tokens: 1,
        output_tokens: 0,
        settled_cost_micros: Decimal.new("0.5")
      })
    end

    raw_settlements = Reporting.settlements_for_pool_ids([pool.id], started_at, ended_at)

    assert Aggregates.sum_decimal_integer(raw_settlements, :settled_cost_micros) == 2

    assert [bucket] =
             Reporting.settlement_usage_buckets_for_pool_ids(
               [pool.id],
               :hour,
               started_at,
               ended_at
             )

    assert bucket.settled_cost_micros == 2
  end

  defp insert_settlement!(pool, api_key, assignment, identity, occurred_at, attrs) do
    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "reporting-known-only-#{System.unique_integer([:positive])}"
      })
      |> set_request_time!(occurred_at)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(occurred_at)

    attrs =
      Map.merge(
        %{
          attempt_id: attempt.id,
          pool_upstream_assignment_id: assignment.id,
          upstream_identity_id: identity.id
        },
        attrs
      )

    request
    |> ledger_entry_fixture(attrs)
    |> set_ledger_time!(occurred_at)
  end

  defp set_request_time!(request, timestamp) do
    request
    |> Ecto.Changeset.change(%{admitted_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp set_attempt_time!(attempt, timestamp) do
    attempt
    |> Ecto.Changeset.change(%{started_at: timestamp, completed_at: timestamp, latency_ms: 1_000})
    |> Repo.update!()
  end

  defp set_ledger_time!(ledger_entry, timestamp) do
    ledger_entry
    |> Ecto.Changeset.change(%{occurred_at: timestamp, created_at: timestamp})
    |> Repo.update!()
  end

  defp sum_decimal_integer(rows, field) do
    rows
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    |> Decimal.to_integer()
  end
end
