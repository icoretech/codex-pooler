defmodule CodexPooler.Accounting.RollupsTest do
  use CodexPooler.DataCase, async: false

  alias Ecto.Migration.Runner

  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    DailyRollup,
    DailyRollupCoverage,
    HourlyModelUsageRollup,
    LedgerEntry,
    Request,
    Rollups
  }

  alias CodexPooler.Admin.GatewayReadModel
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  describe "daily rollups" do
    test "mixed known and unknown usage settlements count volume but aggregate known usage only" do
      setup = accounting_setup()
      bucket = ~U[2026-06-14 10:00:00.000000Z]
      rollup_date = DateTime.to_date(bucket)

      known_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "succeeded",
          retry_count: 1
        })

      unknown_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "failed",
          retry_count: 4,
          response_status_code: 502
        })

      known_settlement =
        insert_settlement!(known_request, %{
          occurred_at: DateTime.add(bucket, 9 * 60, :second),
          input_tokens: 13,
          cached_input_tokens: 5,
          output_tokens: 7,
          reasoning_tokens: 3,
          total_tokens: 23,
          estimated_cost_micros: "131.25",
          settled_cost_micros: "118.5"
        })

      unknown_settlement =
        insert_settlement!(unknown_request, %{
          usage_status: "usage_unknown",
          occurred_at: DateTime.add(bucket, 32 * 60, :second),
          input_tokens: 900,
          cached_input_tokens: 100,
          output_tokens: 800,
          reasoning_tokens: 700,
          total_tokens: 2_400,
          estimated_cost_micros: "98765.432",
          settled_cost_micros: "12345.678"
        })

      assert :ok = Rollups.accumulate!(known_request, known_settlement)
      assert :ok = Rollups.accumulate!(unknown_request, unknown_settlement)

      expected = [
        %{
          dimension_kind: "api_key",
          request_count: 2,
          success_count: 1,
          failure_count: 1,
          retry_count: 5,
          input_tokens: 13,
          cached_input_tokens: 5,
          output_tokens: 7,
          reasoning_tokens: 3,
          total_tokens: 23,
          estimated_cost_micros: "131.25",
          settled_cost_micros: "118.5"
        }
      ]

      assert daily_rollup_summary_rows(rollup_date, "api_key") == expected
      incremental_rows = daily_rollup_summary_rows(rollup_date, "api_key")

      assert {:ok, 2} = Rollups.rebuild_for_date(rollup_date)
      assert daily_rollup_summary_rows(rollup_date, "api_key") == incremental_rows
    end
  end

  describe "daily rollup coverage" do
    @tag :daily_rollup_coverage
    test "distinguishes complete zero-row dates from missing and incompatible coverage" do
      setup = accounting_setup()
      complete_date = ~D[2026-08-07]
      incompatible_date = ~D[2026-08-08]
      missing_date = ~D[2026-08-09]
      completed_at = ~U[2026-08-10 00:17:00.000000Z]

      Repo.insert!(%DailyRollupCoverage{
        rollup_date: complete_date,
        contract_version: DailyRollupCoverage.contract_version(),
        completed_at: completed_at,
        created_at: completed_at,
        updated_at: completed_at
      })

      Repo.insert!(%DailyRollupCoverage{
        rollup_date: incompatible_date,
        contract_version: DailyRollupCoverage.contract_version() + 1,
        completed_at: completed_at,
        created_at: completed_at,
        updated_at: completed_at
      })

      assert [] =
               DailyRollup
               |> where([rollup], rollup.rollup_date == ^complete_date)
               |> Repo.all()

      {1, _rows} =
        Repo.insert_all(DailyRollup, [
          %{
            rollup_date: missing_date,
            dimension_kind: "pool",
            pool_id: setup.pool.id,
            created_at: completed_at,
            updated_at: completed_at
          }
        ])

      assert [%DailyRollup{pool_id: pool_id}] =
               DailyRollup
               |> where([rollup], rollup.rollup_date == ^missing_date)
               |> Repo.all()

      assert pool_id == setup.pool.id

      assert Accounting.daily_rollup_coverage_statuses([
               missing_date,
               incompatible_date,
               complete_date,
               complete_date
             ]) == %{
               complete_date => :complete,
               incompatible_date => :incompatible,
               missing_date => :missing
             }
    end
  end

  describe "Pool usage daily rollups" do
    @tag :pool_usage_rollup_parity
    test "incremental admissions and per-entry rounded settlement costs match a covered rebuild" do
      setup = accounting_setup()
      rollup_date = ~D[2026-08-12]
      day_start = DateTime.new!(rollup_date, ~T[00:00:00.000000], "Etc/UTC")

      first = reserve_request!(setup, DateTime.add(day_start, 5, :minute), "pool-rollup-first")

      assert {:ok, %{request: turn_claim}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: "/backend-api/codex/responses",
                 correlation_id: "pool-rollup-turn",
                 now: DateTime.add(day_start, 10, :minute)
               })

      assert {:ok, second} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 5},
                 %{
                   correlation_id: turn_claim.correlation_id,
                   now: turn_claim.admitted_at,
                   turn_claim: turn_claim
                 }
               )

      first_settlement =
        insert_settlement!(first.request, %{
          occurred_at: DateTime.add(day_start, 20, :minute),
          input_tokens: 3,
          output_tokens: 2,
          total_tokens: 5,
          settled_cost_micros: "0.5"
        })

      second_settlement =
        insert_settlement!(second.request, %{
          occurred_at: DateTime.add(day_start, 30, :minute),
          input_tokens: 7,
          output_tokens: 4,
          total_tokens: 11,
          settled_cost_micros: "0.5"
        })

      assert :ok = Rollups.accumulate!(first.request, first_settlement)
      assert :ok = Rollups.accumulate!(second.request, second_settlement)

      assert %{setup.pool.id => 2} ==
               GatewayReadModel.request_counts_by_pool_ids(
                 [setup.pool.id],
                 day_start,
                 DateTime.add(day_start, 1, :day)
               )

      assert %{admitted_request_count: 2, request_count: 2, rounded_cost: "2"} =
               pool_rollup_summary!(setup.pool.id, rollup_date)

      replacement =
        first_settlement
        |> Ecto.Changeset.change(settled_cost_micros: Decimal.new("1.5"))
        |> Repo.update!()

      assert :ok =
               Rollups.replace!(
                 first.request,
                 first_settlement,
                 first.request,
                 replacement
               )

      incremental = pool_rollup_summary!(setup.pool.id, rollup_date)

      assert incremental.admitted_request_count == 2
      assert incremental.request_count == 2
      assert incremental.total_tokens == 16
      assert incremental.settled_cost == "2"
      assert incremental.rounded_cost == "3"

      assert {:ok, 2} = Rollups.rebuild_for_date(rollup_date)
      assert pool_rollup_summary!(setup.pool.id, rollup_date) == incremental

      assert Accounting.daily_rollup_coverage_statuses([rollup_date]) == %{
               rollup_date => :complete
             }

      late = reserve_request!(setup, DateTime.add(day_start, 40, :minute), "pool-rollup-late")

      late_settlement =
        insert_settlement!(late.request, %{
          occurred_at: DateTime.add(day_start, 50, :minute),
          input_tokens: 1,
          total_tokens: 1,
          settled_cost_micros: "0.4"
        })

      assert :ok = Rollups.accumulate!(late.request, late_settlement)

      assert %{
               admitted_request_count: 3,
               request_count: 3,
               total_tokens: 17,
               settled_cost: "2.4",
               rounded_cost: "3"
             } = pool_rollup_summary!(setup.pool.id, rollup_date)

      assert Accounting.daily_rollup_coverage_statuses([rollup_date]) == %{
               rollup_date => :complete
             }
    end

    test "unsettled and usage-unknown admitted requests preserve raw request semantics" do
      setup = accounting_setup()
      rollup_date = ~D[2026-08-11]
      day_start = DateTime.new!(rollup_date, ~T[00:00:00.000000], "Etc/UTC")

      _unsettled =
        reserve_request!(setup, DateTime.add(day_start, 5, :minute), "pool-rollup-unsettled")

      unknown =
        reserve_request!(setup, DateTime.add(day_start, 10, :minute), "pool-rollup-unknown")

      unknown_settlement =
        insert_settlement!(unknown.request, %{
          usage_status: "usage_unknown",
          occurred_at: DateTime.add(day_start, 20, :minute),
          input_tokens: 900,
          output_tokens: 800,
          total_tokens: 1_700,
          settled_cost_micros: "999.9"
        })

      assert :ok = Rollups.accumulate!(unknown.request, unknown_settlement)

      assert %{
               admitted_request_count: 2,
               request_count: 1,
               total_tokens: 0,
               settled_cost: "0",
               rounded_cost: "0"
             } = pool_rollup_summary!(setup.pool.id, rollup_date)
    end

    test "an empty-day rebuild removes stale rows and writes compatible coverage" do
      setup = accounting_setup()
      rollup_date = ~D[2026-08-10]

      insert_stale_pool_rollup!(setup.pool, rollup_date, %{
        admitted_request_count: 9,
        request_count: 7,
        total_tokens: 777,
        rounded_settled_cost_micros: "123"
      })

      assert {:ok, 0} = Rollups.rebuild_for_date(rollup_date)
      assert Repo.all(from rollup in DailyRollup, where: rollup.rollup_date == ^rollup_date) == []

      assert Accounting.daily_rollup_coverage_statuses([rollup_date]) == %{
               rollup_date => :complete
             }
    end

    @tag :pool_usage_rollup_atomic_failure
    test "a failure before coverage publication rolls back both rebuild sources" do
      setup = accounting_setup()
      rollup_date = ~D[2026-08-09]
      completed_at = ~U[2026-08-10 00:05:00.000000Z]

      stale =
        insert_stale_pool_rollup!(setup.pool, rollup_date, %{
          admitted_request_count: 4,
          request_count: 3,
          total_tokens: 444,
          rounded_settled_cost_micros: "22"
        })

      Repo.insert!(%DailyRollupCoverage{
        rollup_date: rollup_date,
        contract_version: DailyRollupCoverage.contract_version(),
        completed_at: completed_at,
        created_at: completed_at,
        updated_at: completed_at
      })

      assert {:error, :injected_coverage_failure} =
               Rollups.rebuild_for_date(rollup_date,
                 before_coverage: fn -> Repo.rollback(:injected_coverage_failure) end
               )

      assert Repo.reload!(stale).admitted_request_count == 4
      assert Repo.reload!(stale).total_tokens == 444
      assert Repo.get!(DailyRollupCoverage, rollup_date).completed_at == completed_at
    end
  end

  describe "hourly model usage rollups" do
    test "recorded settlements increment the request model's hourly bucket" do
      setup = accounting_setup()
      ledger_model = model_fixture(setup.pool, %{exposed_model_id: "gpt-ledger-not-source"})
      bucket = ~U[2026-06-13 10:00:00.000000Z]

      request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          requested_model: "misleading-requested-model",
          status: "succeeded",
          retry_count: 2
        })

      settlement =
        insert_settlement!(request, %{
          model_id: ledger_model.id,
          occurred_at: DateTime.add(bucket, 17 * 60, :second),
          input_tokens: 10,
          cached_input_tokens: 3,
          output_tokens: 7,
          reasoning_tokens: 2,
          total_tokens: 22,
          estimated_cost_micros: "100.125",
          settled_cost_micros: "90.25"
        })

      assert :ok = Rollups.accumulate!(request, settlement)

      assert [rollup] = hourly_rollup_rows(bucket, DateTime.add(bucket, 3_600, :second))
      assert rollup.bucket_started_at == bucket
      assert rollup.pool_id == setup.pool.id
      assert rollup.model_id == setup.model.id
      assert rollup.model_code == setup.model.exposed_model_id
      assert rollup.model_code != ledger_model.exposed_model_id
      assert rollup.request_count == 1
      assert rollup.success_count == 1
      assert rollup.failure_count == 0
      assert rollup.retry_count == 2
      assert rollup.input_tokens == 10
      assert rollup.cached_input_tokens == 3
      assert rollup.output_tokens == 7
      assert rollup.reasoning_tokens == 2
      assert rollup.total_tokens == 22
      assert decimal_string(rollup.estimated_cost_micros) == "100.125"
      assert decimal_string(rollup.settled_cost_micros) == "90.25"
    end

    test "repeated recorded settlements accumulate in the same hourly model bucket" do
      setup = accounting_setup()
      bucket = ~U[2026-06-13 14:00:00.000000Z]

      first_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "succeeded",
          retry_count: 1
        })

      second_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "failed",
          retry_count: 3,
          response_status_code: 500
        })

      first_settlement =
        insert_settlement!(first_request, %{
          occurred_at: DateTime.add(bucket, 8 * 60, :second),
          input_tokens: 11,
          cached_input_tokens: 4,
          output_tokens: 5,
          reasoning_tokens: 2,
          total_tokens: 16,
          estimated_cost_micros: "120.25",
          settled_cost_micros: "100.5"
        })

      second_settlement =
        insert_settlement!(second_request, %{
          usage_status: "usage_unknown",
          occurred_at: DateTime.add(bucket, 41 * 60, :second),
          input_tokens: 7,
          cached_input_tokens: 1,
          output_tokens: 9,
          reasoning_tokens: 3,
          total_tokens: 16,
          estimated_cost_micros: "80.75",
          settled_cost_micros: "999"
        })

      assert :ok = Rollups.accumulate!(first_request, first_settlement)
      assert :ok = Rollups.accumulate!(second_request, second_settlement)

      assert [rollup] = hourly_rollup_rows(bucket, DateTime.add(bucket, 3_600, :second))
      assert rollup.bucket_started_at == bucket
      assert rollup.pool_id == setup.pool.id
      assert rollup.model_id == setup.model.id
      assert rollup.model_code == setup.model.exposed_model_id
      assert rollup.request_count == 2
      assert rollup.success_count == 1
      assert rollup.failure_count == 1
      assert rollup.retry_count == 4
      assert rollup.input_tokens == 11
      assert rollup.cached_input_tokens == 4
      assert rollup.output_tokens == 5
      assert rollup.reasoning_tokens == 2
      assert rollup.total_tokens == 16
      assert decimal_string(rollup.estimated_cost_micros) == "120.25"
      assert decimal_string(rollup.settled_cost_micros) == "100.5"

      incremental_rows = hourly_rollup_summary_rows(bucket, DateTime.add(bucket, 3_600, :second))

      assert {:ok, 2} =
               Rollups.rebuild_hourly_model_usage_rollups_for_range(
                 bucket,
                 DateTime.add(bucket, 3_600, :second)
               )

      assert hourly_rollup_summary_rows(bucket, DateTime.add(bucket, 3_600, :second)) ==
               incremental_rows
    end

    test "automatic migration repairs stale rollups for affected unknown-usage buckets" do
      setup = accounting_setup()
      bucket = ~U[2026-06-13 16:00:00.000000Z]
      rollup_date = DateTime.to_date(bucket)

      known_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "succeeded",
          retry_count: 1
        })

      unknown_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "failed",
          retry_count: 3
        })

      insert_settlement!(known_request, %{
        occurred_at: DateTime.add(bucket, 21 * 60, :second),
        input_tokens: 12,
        cached_input_tokens: 4,
        output_tokens: 6,
        reasoning_tokens: 2,
        total_tokens: 20,
        estimated_cost_micros: "140.5",
        settled_cost_micros: "120.25"
      })

      unknown_settlement =
        insert_settlement!(unknown_request, %{
          usage_status: "usage_unknown",
          occurred_at: DateTime.add(bucket, 31 * 60, :second),
          input_tokens: 8_000,
          cached_input_tokens: 500,
          output_tokens: 1_400,
          reasoning_tokens: 99,
          total_tokens: 9_999,
          estimated_cost_micros: "8888",
          settled_cost_micros: "7777"
        })

      insert_stale_daily_rollup!(setup.pool, setup.api_key, rollup_date, %{
        request_count: 99,
        success_count: 98,
        failure_count: 1,
        retry_count: 77,
        input_tokens: 9_000,
        total_tokens: 9_000,
        estimated_cost_micros: "9000",
        settled_cost_micros: "9000"
      })

      insert_stale_hourly_rollup!(setup.pool, setup.model, bucket, %{
        request_count: 99,
        success_count: 98,
        failure_count: 1,
        retry_count: 77,
        input_tokens: 9_000,
        total_tokens: 9_000,
        estimated_cost_micros: "9000",
        settled_cost_micros: "9000"
      })

      run_unknown_usage_projection_migration!()
      run_unknown_usage_projection_migration!()

      assert Repo.get!(LedgerEntry, unknown_settlement.id).total_tokens == 9_999

      assert daily_rollup_summary_rows(rollup_date, "api_key") == [
               %{
                 dimension_kind: "api_key",
                 request_count: 2,
                 success_count: 1,
                 failure_count: 1,
                 retry_count: 4,
                 input_tokens: 12,
                 cached_input_tokens: 4,
                 output_tokens: 6,
                 reasoning_tokens: 2,
                 total_tokens: 20,
                 estimated_cost_micros: "140.5",
                 settled_cost_micros: "120.25"
               }
             ]

      assert hourly_rollup_summary_rows(bucket, DateTime.add(bucket, 3_600, :second)) == [
               %{
                 bucket_started_at: bucket,
                 model_code: setup.model.exposed_model_id,
                 request_count: 2,
                 success_count: 1,
                 failure_count: 1,
                 retry_count: 4,
                 input_tokens: 12,
                 cached_input_tokens: 4,
                 output_tokens: 6,
                 reasoning_tokens: 2,
                 total_tokens: 20,
                 estimated_cost_micros: "140.5",
                 settled_cost_micros: "120.25"
               }
             ]
    end

    test "recorded settlement increments an existing hourly model row through the conflict path" do
      setup = accounting_setup()
      bucket = ~U[2026-06-13 15:00:00.000000Z]
      existing_timestamp = ~U[2025-01-01 00:00:00.000000Z]

      existing =
        insert_stale_hourly_rollup!(setup.pool, setup.model, bucket, %{
          request_count: 4,
          success_count: 2,
          failure_count: 2,
          retry_count: 5,
          input_tokens: 100,
          cached_input_tokens: 20,
          output_tokens: 30,
          reasoning_tokens: 10,
          total_tokens: 140,
          estimated_cost_micros: "250.25",
          settled_cost_micros: "125.5",
          created_at: existing_timestamp,
          updated_at: existing_timestamp
        })

      request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "failed",
          retry_count: 6,
          response_status_code: 502
        })

      settlement =
        insert_settlement!(request, %{
          occurred_at: DateTime.add(bucket, 19 * 60, :second),
          input_tokens: 7,
          cached_input_tokens: 2,
          output_tokens: 11,
          reasoning_tokens: 3,
          total_tokens: 21,
          estimated_cost_micros: "30.75",
          settled_cost_micros: "10.125"
        })

      assert :ok = Rollups.accumulate!(request, settlement)

      assert [rollup] = hourly_rollup_rows(bucket, DateTime.add(bucket, 3_600, :second))
      assert rollup.id == existing.id
      assert rollup.created_at == existing_timestamp
      assert DateTime.compare(rollup.updated_at, existing_timestamp) == :gt
      assert rollup.bucket_started_at == bucket
      assert rollup.pool_id == setup.pool.id
      assert rollup.model_id == setup.model.id
      assert rollup.model_code == setup.model.exposed_model_id
      assert rollup.request_count == 5
      assert rollup.success_count == 2
      assert rollup.failure_count == 3
      assert rollup.retry_count == 11
      assert rollup.input_tokens == 107
      assert rollup.cached_input_tokens == 22
      assert rollup.output_tokens == 41
      assert rollup.reasoning_tokens == 13
      assert rollup.total_tokens == 161
      assert decimal_string(rollup.estimated_cost_micros) == "281"
      assert decimal_string(rollup.settled_cost_micros) == "135.625"
    end

    test "range rebuild is idempotent and matches recorded fixture settlements" do
      setup = accounting_setup()
      second_model = model_fixture(setup.pool, %{exposed_model_id: "gpt-hourly-backfill-large"})
      start_at = ~U[2026-06-13 09:00:00.000000Z]
      next_hour = DateTime.add(start_at, 3_600, :second)
      end_at = DateTime.add(start_at, 10_800, :second)

      insert_stale_hourly_rollup!(setup.pool, setup.model, start_at, %{total_tokens: 999})

      insert_stale_hourly_rollup!(
        setup.pool,
        second_model,
        DateTime.add(start_at, 7_200, :second),
        %{}
      )

      first_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "succeeded",
          retry_count: 1
        })

      second_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "failed",
          usage_status: "usage_unknown",
          retry_count: 2,
          response_status_code: 500
        })

      third_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: second_model.id,
          status: "succeeded",
          retry_count: 0
        })

      _first_settlement =
        insert_settlement!(first_request, %{
          occurred_at: DateTime.add(start_at, 3 * 60, :second),
          input_tokens: 5,
          cached_input_tokens: 2,
          output_tokens: 4,
          reasoning_tokens: 1,
          total_tokens: 10,
          estimated_cost_micros: "8.5",
          settled_cost_micros: "6.25"
        })

      _second_settlement =
        insert_settlement!(second_request, %{
          usage_status: "usage_unknown",
          occurred_at: DateTime.add(start_at, 33 * 60, :second),
          input_tokens: 7,
          cached_input_tokens: 1,
          output_tokens: 4,
          reasoning_tokens: 1,
          total_tokens: 10,
          estimated_cost_micros: "5",
          settled_cost_micros: "99"
        })

      _third_settlement =
        insert_settlement!(third_request, %{
          occurred_at: DateTime.add(next_hour, 9 * 60, :second),
          input_tokens: 2,
          cached_input_tokens: 0,
          output_tokens: 5,
          reasoning_tokens: 0,
          total_tokens: 7,
          estimated_cost_micros: "3",
          settled_cost_micros: "2"
        })

      insert_settlement!(first_request, %{
        entry_kind: "correction",
        occurred_at: DateTime.add(start_at, 12 * 60, :second),
        total_tokens: 500
      })

      insert_settlement!(third_request, %{
        amount_status: "voided",
        occurred_at: DateTime.add(next_hour, 13 * 60, :second),
        total_tokens: 700
      })

      assert {:ok, 3} = Rollups.rebuild_hourly_model_usage_rollups_for_range(start_at, end_at)
      first_rebuild_rows = hourly_rollup_summary_rows(start_at, end_at)

      assert first_rebuild_rows == [
               %{
                 bucket_started_at: start_at,
                 model_code: "gpt-accounting-mini",
                 request_count: 2,
                 success_count: 1,
                 failure_count: 1,
                 retry_count: 3,
                 input_tokens: 5,
                 cached_input_tokens: 2,
                 output_tokens: 4,
                 reasoning_tokens: 1,
                 total_tokens: 10,
                 estimated_cost_micros: "8.5",
                 settled_cost_micros: "6.25"
               },
               %{
                 bucket_started_at: next_hour,
                 model_code: "gpt-hourly-backfill-large",
                 request_count: 1,
                 success_count: 1,
                 failure_count: 0,
                 retry_count: 0,
                 input_tokens: 2,
                 cached_input_tokens: 0,
                 output_tokens: 5,
                 reasoning_tokens: 0,
                 total_tokens: 7,
                 estimated_cost_micros: "3",
                 settled_cost_micros: "2"
               }
             ]

      assert {:ok, 3} = Rollups.rebuild_hourly_model_usage_rollups_for_range(start_at, end_at)
      assert hourly_rollup_summary_rows(start_at, end_at) == first_rebuild_rows
    end

    test "range rebuild does not overwrite rollup rows updated after rebuild start" do
      setup = accounting_setup()
      bucket = ~U[2026-06-13 11:00:00.000000Z]

      future_update =
        DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)

      request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: setup.model.id,
          status: "succeeded"
        })

      _settlement =
        insert_settlement!(request, %{
          occurred_at: DateTime.add(bucket, 5 * 60, :second),
          input_tokens: 1,
          output_tokens: 2,
          total_tokens: 3
        })

      insert_stale_hourly_rollup!(setup.pool, setup.model, bucket, %{
        request_count: 9,
        total_tokens: 777,
        updated_at: future_update
      })

      assert {:ok, 1} =
               Rollups.rebuild_hourly_model_usage_rollups_for_range(
                 bucket,
                 DateTime.add(bucket, 3_600, :second)
               )

      assert [rollup] = hourly_rollup_rows(bucket, DateTime.add(bucket, 3_600, :second))
      assert rollup.request_count == 9
      assert rollup.total_tokens == 777
      assert rollup.updated_at == future_update
    end

    test "nil request model ids do not crash and are excluded from hourly model rollups" do
      setup = accounting_setup()
      bucket = ~U[2026-06-13 12:00:00.000000Z]

      request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: nil,
          requested_model: "gpt-requested-only",
          status: "succeeded"
        })

      settlement =
        insert_settlement!(request, %{
          occurred_at: DateTime.add(bucket, 7 * 60, :second),
          total_tokens: 42
        })

      assert :ok = Rollups.accumulate!(request, settlement)
      assert [] = hourly_rollup_rows(bucket, DateTime.add(bucket, 3_600, :second))

      assert {:ok, 0} =
               Rollups.rebuild_hourly_model_usage_rollups_for_range(
                 bucket,
                 DateTime.add(bucket, 3_600, :second)
               )

      assert [] = hourly_rollup_rows(bucket, DateTime.add(bucket, 3_600, :second))
    end

    test "range rebuild labels unresolved non-nil request model ids as Unknown model" do
      setup = accounting_setup()
      bucket = ~U[2026-06-13 13:00:00.000000Z]
      missing_model_id = Ecto.UUID.generate()
      drop_request_model_foreign_key!()

      request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          model_id: missing_model_id,
          requested_model: "do-not-use-requested-model",
          status: "succeeded"
        })

      _settlement =
        insert_settlement!(request, %{
          occurred_at: DateTime.add(bucket, 11 * 60, :second),
          input_tokens: 4,
          output_tokens: 6,
          total_tokens: 10
        })

      assert {:ok, 1} =
               Rollups.rebuild_hourly_model_usage_rollups_for_range(
                 bucket,
                 DateTime.add(bucket, 3_600, :second)
               )

      assert [rollup] = hourly_rollup_rows(bucket, DateTime.add(bucket, 3_600, :second))
      assert rollup.model_id == nil
      assert rollup.model_code == "Unknown model"
      assert rollup.total_tokens == 10
      assert rollup.request_count == 1
    end
  end

  defp daily_rollup_summary_rows(date, dimension_kind) do
    DailyRollup
    |> where([rollup], rollup.rollup_date == ^date and rollup.dimension_kind == ^dimension_kind)
    |> order_by([rollup],
      asc: rollup.dimension_kind,
      asc: rollup.api_key_id,
      asc: rollup.pool_upstream_assignment_id,
      asc: rollup.upstream_identity_id,
      asc: rollup.model_id
    )
    |> Repo.all()
    |> Enum.map(fn rollup ->
      %{
        dimension_kind: rollup.dimension_kind,
        request_count: rollup.request_count,
        success_count: rollup.success_count,
        failure_count: rollup.failure_count,
        retry_count: rollup.retry_count,
        input_tokens: rollup.input_tokens,
        cached_input_tokens: rollup.cached_input_tokens,
        output_tokens: rollup.output_tokens,
        reasoning_tokens: rollup.reasoning_tokens,
        total_tokens: rollup.total_tokens,
        estimated_cost_micros: decimal_string(rollup.estimated_cost_micros),
        settled_cost_micros: decimal_string(rollup.settled_cost_micros)
      }
    end)
  end

  defp reserve_request!(setup, admitted_at, correlation_id) do
    assert {:ok, reservation} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 5},
               %{correlation_id: correlation_id, now: admitted_at}
             )

    reservation
  end

  defp pool_rollup_summary!(pool_id, rollup_date) do
    rollup =
      Repo.get_by!(DailyRollup,
        pool_id: pool_id,
        rollup_date: rollup_date,
        dimension_kind: "pool"
      )

    %{
      admitted_request_count: rollup.admitted_request_count,
      request_count: rollup.request_count,
      total_tokens: rollup.total_tokens,
      settled_cost: decimal_string(rollup.settled_cost_micros),
      rounded_cost: decimal_string(rollup.rounded_settled_cost_micros)
    }
  end

  defp insert_settlement!(%Request{} = request, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    occurred_at = Map.get(attrs, :occurred_at, now)

    %LedgerEntry{
      request_id: request.id,
      attempt_id: Map.get(attrs, :attempt_id),
      pricing_snapshot_id: Map.get(attrs, :pricing_snapshot_id),
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      pool_upstream_assignment_id: Map.get(attrs, :pool_upstream_assignment_id),
      upstream_identity_id: Map.get(attrs, :upstream_identity_id),
      model_id: Map.get(attrs, :model_id),
      entry_kind: Map.get(attrs, :entry_kind, "settlement"),
      amount_status: Map.get(attrs, :amount_status, "recorded"),
      usage_status: Map.get(attrs, :usage_status, "usage_known"),
      transport: Map.get(attrs, :transport, request.transport),
      currency_code: Map.get(attrs, :currency_code, "USD"),
      input_tokens: Map.get(attrs, :input_tokens, 0),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 0),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens, 0),
      total_tokens: Map.get(attrs, :total_tokens, 0),
      request_count: Map.get(attrs, :request_count, 1),
      estimated_cost_micros: decimal_value(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: decimal_value(Map.get(attrs, :settled_cost_micros, 0)),
      occurred_at: occurred_at,
      created_at: Map.get(attrs, :created_at, occurred_at),
      details: Map.get(attrs, :details, %{})
    }
    |> Repo.insert!()
  end

  defp insert_stale_daily_rollup!(pool, api_key, rollup_date, attrs) do
    now =
      Map.get(
        attrs,
        :updated_at,
        DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:microsecond)
      )

    total_tokens = Map.get(attrs, :total_tokens, 1)

    %DailyRollup{
      rollup_date: rollup_date,
      dimension_kind: "api_key",
      pool_id: pool.id,
      api_key_id: api_key.id,
      request_count: Map.get(attrs, :request_count, 1),
      success_count: Map.get(attrs, :success_count, 1),
      failure_count: Map.get(attrs, :failure_count, 0),
      retry_count: Map.get(attrs, :retry_count, 0),
      input_tokens: Map.get(attrs, :input_tokens, total_tokens),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 0),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens, 0),
      total_tokens: total_tokens,
      estimated_cost_micros: decimal_value(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: decimal_value(Map.get(attrs, :settled_cost_micros, 0)),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_stale_pool_rollup!(pool, rollup_date, attrs) do
    now =
      Map.get(
        attrs,
        :updated_at,
        DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:microsecond)
      )

    %DailyRollup{
      rollup_date: rollup_date,
      dimension_kind: "pool",
      pool_id: pool.id,
      admitted_request_count: Map.get(attrs, :admitted_request_count, 0),
      request_count: Map.get(attrs, :request_count, 0),
      success_count: Map.get(attrs, :success_count, 0),
      failure_count: Map.get(attrs, :failure_count, 0),
      retry_count: Map.get(attrs, :retry_count, 0),
      input_tokens: Map.get(attrs, :input_tokens, 0),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 0),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens, 0),
      total_tokens: Map.get(attrs, :total_tokens, 0),
      estimated_cost_micros: decimal_value(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: decimal_value(Map.get(attrs, :settled_cost_micros, 0)),
      rounded_settled_cost_micros: decimal_value(Map.get(attrs, :rounded_settled_cost_micros, 0)),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_stale_hourly_rollup!(pool, model, bucket_started_at, attrs) do
    now =
      Map.get(
        attrs,
        :updated_at,
        DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:microsecond)
      )

    total_tokens = Map.get(attrs, :total_tokens, 1)

    %HourlyModelUsageRollup{
      bucket_started_at: bucket_started_at,
      pool_id: pool.id,
      model_id: model.id,
      model_code: model.exposed_model_id,
      request_count: Map.get(attrs, :request_count, 1),
      success_count: Map.get(attrs, :success_count, 1),
      failure_count: Map.get(attrs, :failure_count, 0),
      retry_count: Map.get(attrs, :retry_count, 0),
      input_tokens: Map.get(attrs, :input_tokens, total_tokens),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 0),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens, 0),
      total_tokens: total_tokens,
      estimated_cost_micros: decimal_value(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: decimal_value(Map.get(attrs, :settled_cost_micros, 0)),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp hourly_rollup_rows(started_at, ended_at) do
    HourlyModelUsageRollup
    |> where(
      [rollup],
      rollup.bucket_started_at >= ^started_at and rollup.bucket_started_at < ^ended_at
    )
    |> order_by([rollup], asc: rollup.bucket_started_at, asc: rollup.model_code)
    |> Repo.all()
  end

  defp hourly_rollup_summary_rows(started_at, ended_at) do
    started_at
    |> hourly_rollup_rows(ended_at)
    |> Enum.map(fn rollup ->
      %{
        bucket_started_at: rollup.bucket_started_at,
        model_code: rollup.model_code,
        request_count: rollup.request_count,
        success_count: rollup.success_count,
        failure_count: rollup.failure_count,
        retry_count: rollup.retry_count,
        input_tokens: rollup.input_tokens,
        cached_input_tokens: rollup.cached_input_tokens,
        output_tokens: rollup.output_tokens,
        reasoning_tokens: rollup.reasoning_tokens,
        total_tokens: rollup.total_tokens,
        estimated_cost_micros: decimal_string(rollup.estimated_cost_micros),
        settled_cost_micros: decimal_string(rollup.settled_cost_micros)
      }
    end)
  end

  defp decimal_value(%Decimal{} = value), do: value
  defp decimal_value(value), do: Decimal.new(to_string(value))

  defp decimal_string(%Decimal{} = value),
    do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp run_unknown_usage_projection_migration! do
    Runner.run(
      Repo,
      Repo.config(),
      20_260_626_133_501,
      unknown_usage_projection_migration(),
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp unknown_usage_projection_migration do
    module = CodexPooler.Repo.Migrations.RepairUnknownUsageAccountingProjections

    unless Code.ensure_loaded?(module) do
      Code.require_file(
        "../../../priv/repo/migrations/20260626133501_repair_unknown_usage_accounting_projections.exs",
        __DIR__
      )
    end

    module
  end

  defp drop_request_model_foreign_key! do
    Repo.query!("ALTER TABLE requests DROP CONSTRAINT IF EXISTS requests_model_id_fkey")
  end
end
