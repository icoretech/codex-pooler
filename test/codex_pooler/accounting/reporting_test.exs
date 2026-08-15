defmodule CodexPooler.Accounting.ReportingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Reporting, Rollups}
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

    assert Reporting.settled_cost_totals_by_pool_ids([pool.id], started_at, ended_at) == %{
             pool.id => 700_000
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

  test "upstream model totals expose usage completeness while excluding unknown stored totals" do
    pool = pool_fixture(%{slug: "reporting-completeness", name: "Reporting Completeness"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    known_model = model_fixture(pool, %{exposed_model_id: "gpt-reporting-known"})
    unknown_model = model_fixture(pool, %{exposed_model_id: "gpt-reporting-unknown"})
    started_at = ~U[2026-01-10 11:00:00.000000Z]
    ended_at = ~U[2026-01-10 12:00:00.000000Z]
    occurred_at = ~U[2026-01-10 11:30:00.000000Z]

    insert_settlement!(pool, api_key, assignment, identity, occurred_at, %{
      model_id: known_model.id,
      request_count: 2,
      total_tokens: 40,
      settled_cost_micros: 400
    })

    insert_settlement!(pool, api_key, assignment, identity, occurred_at, %{
      model_id: unknown_model.id,
      usage_status: "usage_unknown",
      request_count: 3,
      total_tokens: 999_999,
      settled_cost_micros: 999_999
    })

    second_pool = pool_fixture(%{slug: "reporting-second-pool", name: "Reporting Second Pool"})
    %{api_key: second_api_key} = active_api_key_fixture(second_pool)

    insert_settlement!(second_pool, second_api_key, assignment, identity, occurred_at, %{
      model_id: known_model.id,
      request_count: 5,
      total_tokens: 70,
      settled_cost_micros: 700
    })

    totals_by_model =
      Reporting.token_totals_by_upstream_identity_pool_and_model_ids(
        [identity.id],
        started_at,
        ended_at
      )[identity.id]

    totals =
      Enum.find(totals_by_model, &(&1.model_id == known_model.id and &1.pool_id == pool.id))

    assert totals.request_count == 2
    assert totals.known_request_count == 2
    assert totals.unknown_request_count == 0
    assert totals.total_tokens == 40
    assert totals.settled_cost_micros == 400

    assert [%{request_count: 3, known_request_count: 0, unknown_request_count: 3} = unknown] =
             totals_by_model
             |> Enum.filter(&(&1.unknown_request_count > 0))

    assert unknown.pool_id == pool.id
    assert unknown.total_tokens == 0
    assert unknown.settled_cost_micros == 0

    # The same identity and model split by Pool rather than rolling up.
    assert %{request_count: 5, total_tokens: 70, known_request_count: 5} =
             Enum.find(
               totals_by_model,
               &(&1.model_id == known_model.id and &1.pool_id == second_pool.id)
             )
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

    assert Reporting.settled_cost_totals_by_pool_ids([pool.id], started_at, ended_at) == %{
             pool.id => 2
           }

    assert [bucket] =
             Reporting.settlement_usage_buckets_for_pool_ids(
               [pool.id],
               :hour,
               started_at,
               ended_at
             )

    assert bucket.settled_cost_micros == 2
  end

  test "model usage combines fully contained hourly rollups with both exact raw edges and ranks in SQL" do
    pool = pool_fixture(%{slug: "reporting-model-exact-hourly"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    started_at = ~U[2026-08-14 10:15:00.000000Z]
    ended_at = ~U[2026-08-14 12:45:00.000000Z]

    models =
      for {code, tokens} <- [
            {"gpt-a", 700},
            {"gpt-b", 600},
            {"gpt-c", 500},
            {"gpt-d", 400},
            {"gpt-e", 300},
            {"gpt-f", 200},
            {"gpt-g", 100}
          ] do
        model = model_fixture(pool, %{exposed_model_id: code})

        insert_model_usage!(
          pool,
          api_key,
          assignment,
          identity,
          model,
          ~U[2026-08-14 11:10:00.000000Z],
          total_tokens: tokens,
          request_count: if(code == "gpt-b", do: 2, else: 1),
          retry_count: if(code == "gpt-f", do: 3, else: 0)
        )

        model
      end

    [model_a | _models] = models

    insert_model_usage!(pool, api_key, assignment, identity, model_a, started_at,
      total_tokens: 11,
      settled_cost_micros: 110
    )

    insert_model_usage!(pool, api_key, assignment, identity, model_a, ended_at,
      total_tokens: 13,
      settled_cost_micros: 130
    )

    insert_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      model_a,
      DateTime.add(started_at, -1, :microsecond),
      total_tokens: 9_999
    )

    insert_model_usage!(
      pool,
      api_key,
      assignment,
      identity,
      model_a,
      DateTime.add(ended_at, 1, :microsecond),
      total_tokens: 8_888
    )

    {result, events} =
      collect_repo_query_events(fn ->
        Reporting.model_usage_buckets_for_pool_ids(
          [pool.id, pool.id],
          :five_hours,
          started_at,
          ended_at
        )
      end)

    assert result.source == :hourly_model_usage_rollups_with_exact_edges
    assert result.rollup_source == :hourly_model_usage_rollups
    assert result.edge_source == :raw_settlement_edges
    assert result.confidence == :temporal_containment_only
    assert length(result.rows) <= 18

    assert Enum.map(result.rows, & &1.model_code) |> Enum.uniq() == [
             "gpt-a",
             "gpt-b",
             "gpt-c",
             "gpt-d",
             "gpt-e",
             "Other"
           ]

    assert sum_model(result.rows, "gpt-a", :total_tokens) == 724
    assert sum_model(result.rows, "Other", :total_tokens) == 300
    assert sum_model(result.rows, "Other", :request_count) == 2
    refute inspect(result.rows) =~ "9999"
    refute inspect(result.rows) =~ "8888"

    assert [%{projection: :model_usage_exact_rollups_and_edges, row_count: row_count}] =
             Enum.filter(events, &(&1.projection == :model_usage_exact_rollups_and_edges))

    assert row_count == length(result.rows)
  end

  test "model usage uses one exact raw interval when no complete bucket and mirrors rollup semantics" do
    pool = pool_fixture(%{slug: "reporting-model-same-bucket"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    blank_model = model_fixture(pool, %{exposed_model_id: "reporting-blank-model"})
    model_less_time = ~U[2026-08-14 10:25:00.000000Z]
    started_at = ~U[2026-08-14 10:15:00.000000Z]
    ended_at = ~U[2026-08-14 10:45:00.000000Z]

    blank_model
    |> Ecto.Changeset.change(%{exposed_model_id: " "})
    |> Repo.update!()

    insert_model_usage!(pool, api_key, assignment, identity, blank_model, started_at,
      status: "failed",
      retry_count: 2,
      request_count: 2,
      input_tokens: 20,
      cached_input_tokens: 4,
      output_tokens: 10,
      reasoning_tokens: 3,
      total_tokens: 30,
      estimated_cost_micros: 40,
      settled_cost_micros: 35
    )

    insert_model_usage!(pool, api_key, assignment, identity, blank_model, ended_at,
      status: "rejected",
      retry_count: 4,
      request_count: 3,
      usage_status: "usage_unknown",
      input_tokens: 9_000,
      total_tokens: 9_999,
      settled_cost_micros: 9_999
    )

    insert_model_usage!(pool, api_key, assignment, identity, nil, model_less_time,
      total_tokens: 5_000
    )

    result =
      Reporting.model_usage_buckets_for_pool_ids(
        [pool.id],
        :one_hour,
        started_at,
        ended_at
      )

    assert result.source == :hourly_model_usage_rollups_with_exact_edges

    assert [row] = result.rows
    assert row.bucket == ~U[2026-08-14 10:00:00.000000Z]
    assert row.model_code == "Unknown model"
    assert row.request_count == 2
    assert row.success_count == 0
    assert row.failure_count == 2
    assert row.retry_count == 6
    assert row.input_tokens == 20
    assert row.cached_input_tokens == 4
    assert row.output_tokens == 10
    assert row.reasoning_tokens == 3
    assert row.total_tokens == 30
    assert row.estimated_cost_micros == 40
    assert row.settled_cost_micros == 35
  end

  test "daily model usage includes complete days plus only the aligned ending instant" do
    pool = pool_fixture(%{slug: "reporting-model-exact-daily"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-daily-exact"})
    started_at = ~U[2026-08-07 08:55:00.000000Z]
    ended_at = ~U[2026-08-09 00:00:00.000000Z]

    for {occurred_at, tokens} <- [
          {started_at, 10},
          {~U[2026-08-08 12:00:00.000000Z], 20},
          {ended_at, 30},
          {~U[2026-08-09 00:00:00.000001Z], 4_000}
        ] do
      insert_model_usage!(pool, api_key, assignment, identity, model, occurred_at,
        total_tokens: tokens
      )
    end

    result =
      Reporting.model_usage_buckets_for_pool_ids(
        [pool.id],
        :seven_days,
        started_at,
        ended_at
      )

    assert result.source == :daily_model_rollups_with_exact_edges
    assert Enum.map(result.rows, & &1.bucket) == [~D[2026-08-07], ~D[2026-08-08], ~D[2026-08-09]]
    assert Enum.sum(Enum.map(result.rows, & &1.total_tokens)) == 60
    refute inspect(result.rows) =~ "4000"
  end

  test "model usage rejects malformed bounds and empty scopes without querying" do
    started_at = ~U[2026-08-14 10:15:00.000000Z]
    ended_at = ~U[2026-08-14 10:45:00.000000Z]

    assert Reporting.model_usage_buckets_for_pool_ids([], :one_hour, started_at, ended_at).rows ==
             []

    assert Reporting.model_usage_buckets_for_pool_ids(
             [nil, 123, "not-a-uuid"],
             :one_hour,
             started_at,
             ended_at
           ).rows == []

    assert Reporting.model_usage_buckets_for_pool_ids(
             [Ecto.UUID.generate()],
             :one_hour,
             ended_at,
             started_at
           ).rows == []
  end

  test "model usage query count and returned cardinality stay invariant as fixture volume grows" do
    started_at = ~U[2026-08-14 10:15:00.000000Z]
    ended_at = ~U[2026-08-14 12:45:00.000000Z]

    results =
      for {suffix, repetitions} <- [{"small", 1}, {"large", 10}] do
        pool = pool_fixture(%{slug: "reporting-model-volume-#{suffix}"})
        %{api_key: api_key} = active_api_key_fixture(pool)
        %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

        models =
          for index <- 1..7 do
            model_fixture(pool, %{exposed_model_id: "gpt-volume-#{index}"})
          end

        for repetition <- 1..repetitions,
            {model, index} <- Enum.with_index(models, 1) do
          insert_model_usage!(
            pool,
            api_key,
            assignment,
            identity,
            model,
            DateTime.add(~U[2026-08-14 11:05:00.000000Z], repetition, :second),
            total_tokens: 100 - index
          )
        end

        {result, events} =
          collect_repo_query_events(fn ->
            Reporting.model_usage_buckets_for_pool_ids(
              [pool.id],
              :five_hours,
              started_at,
              ended_at
            )
          end)

        projection_events =
          Enum.filter(events, &(&1.projection == :model_usage_exact_rollups_and_edges))

        assert length(projection_events) == 1
        assert length(result.rows) == 6
        assert Enum.count(result.rows, &(&1.model_code == "Other")) == 1
        {length(projection_events), length(result.rows)}
      end

    assert results == [{1, 6}, {1, 6}]
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

  defp insert_model_usage!(pool, api_key, assignment, identity, model, occurred_at, attrs) do
    request_attrs = %{
      correlation_id: "reporting-model-#{System.unique_integer([:positive])}",
      model_id: model && model.id,
      status: Keyword.get(attrs, :status, "succeeded"),
      retry_count: Keyword.get(attrs, :retry_count, 0)
    }

    request =
      request_fixture(%{pool: pool, api_key: api_key}, request_attrs)
      |> set_request_time!(occurred_at)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(occurred_at)

    settlement_attrs =
      attrs
      |> Map.new()
      |> Map.drop([:status, :retry_count])
      |> Map.merge(%{
        attempt_id: attempt.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        model_id: model && model.id
      })

    settlement =
      request
      |> ledger_entry_fixture(settlement_attrs)
      |> set_ledger_time!(occurred_at)

    :ok = Rollups.accumulate!(request, settlement)
    settlement
  end

  defp sum_model(rows, model_code, field) do
    rows
    |> Enum.filter(&(&1.model_code == model_code))
    |> Enum.sum_by(&Map.fetch!(&1, field))
  end

  defp collect_repo_query_events(fun) do
    handler_id = "reporting-query-events-#{System.unique_integer([:positive])}"
    caller = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, measurements, metadata, _config ->
          send(caller, {:reporting_query_event, measurements, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      _ = :sys.get_state(CodexPooler.Repo)

      events =
        Stream.repeatedly(fn ->
          receive do
            {:reporting_query_event, measurements, metadata} ->
              {:event, measurements, metadata}
          after
            0 -> :done
          end
        end)
        |> Enum.take_while(&(&1 != :done))
        |> Enum.map(fn {:event, measurements, metadata} ->
          query_result =
            case metadata[:result] do
              {:ok, result} -> result
              result -> result
            end

          %{
            command: query_result && query_result.command,
            duration: measurements.total_time,
            projection: get_in(metadata, [:options, :reporting_projection]),
            row_count: query_result && query_result.num_rows,
            source: metadata[:source]
          }
        end)

      {result, events}
    after
      :telemetry.detach(handler_id)
    end
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
