defmodule CodexPooler.AccountingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    DailyRollup,
    HourlyModelUsageRollup,
    LedgerEntry,
    RequestLogFact,
    Rollups
  }

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  describe "gateway accounting hooks" do
    test "latest_success_by_assignment_ids returns latest successful attempt per assignment" do
      setup = accounting_setup()
      %{assignment: other_assignment} = upstream_assignment_fixture(setup.pool)

      older_completed_at =
        DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      newer_completed_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      older_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          correlation_id: "latest-success-older"
        })

      newer_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          correlation_id: "latest-success-newer"
        })

      failed_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          correlation_id: "latest-success-failed"
        })

      _older_attempt =
        attempt_fixture(older_request, setup.assignment, %{completed_at: older_completed_at})

      _newer_attempt =
        attempt_fixture(newer_request, setup.assignment, %{completed_at: newer_completed_at})

      _failed_attempt =
        attempt_fixture(failed_request, other_assignment, %{
          status: "failed",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      assert Accounting.latest_success_by_assignment_ids([
               setup.assignment.id,
               other_assignment.id
             ]) == %{setup.assignment.id => newer_completed_at}
    end

    test "records retry, failure, and success side effects without double-counting retries" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "input" => "metadata only",
                   "max_output_tokens" => 5
                 },
                 %{
                   endpoint: "/backend-api/codex/responses",
                   transport: "http_json",
                   correlation_id: "corr-retry-success",
                   request_metadata: %{
                     "Authorization" => "Bearer sk-cxp-abcdef123456-secret",
                     "prompt" => "raw prompt must not persist"
                   }
                 }
               )

      assert {:ok, failed_attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, failed_attempt} =
               Accounting.record_retryable_attempt_failure(failed_attempt, %{
                 response_status_code: 502,
                 last_error_code: "upstream_502"
               })

      assert failed_attempt.status == "retryable_failed"
      request = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert {:ok, retry_attempt} = Accounting.create_attempt(request, setup.assignment)

      assert {:ok, finalized_success} =
               Accounting.finalize_success(
                 request,
                 retry_attempt,
                 %{status: "usage_known", input_tokens: 7, output_tokens: 3, total_tokens: 10},
                 %{
                   retry_count: 1,
                   response_status_code: 200
                 }
               )

      assert finalized_success.request.status == "succeeded"

      entries = Accounting.list_ledger_entries_for_request(reserved.request.id)

      assert Enum.map(entries, & &1.entry_kind) |> Enum.sort() == [
               "release",
               "reservation",
               "settlement"
             ]

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where: e.request_id == ^reserved.request.id and e.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert [rollup] =
               Repo.all(
                 from r in DailyRollup,
                   where: r.api_key_id == ^setup.api_key.id and r.dimension_kind == "api_key"
               )

      assert rollup.request_count == 1
      assert rollup.success_count == 1
      assert rollup.retry_count == 1
      assert rollup.total_tokens == 10

      assert Repo.aggregate(
               from(e in AuditEvent, where: e.request_id == ^reserved.request.id),
               :count
             ) == 0

      assert Repo.get!(CodexPooler.Accounting.Request, reserved.request.id).request_metadata[
               "Authorization"
             ] == "[REDACTED]"

      assert Repo.get!(CodexPooler.Accounting.Request, reserved.request.id).request_metadata[
               "prompt"
             ] == "[REDACTED]"
    end

    test "accumulates request metadata in memory before explicit persistence" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => "raw prompt"},
                 %{
                   correlation_id: "corr-metadata-accumulate",
                   request_metadata: %{"routing" => %{"strategy" => "pool_order"}}
                 }
               )

      assert {:ok, accumulated} =
               Accounting.accumulate_request_metadata(reserved.request, %{
                 "routing" => %{"selected_bridge_candidate_id" => setup.assignment.id},
                 "authorization" => "Bearer sk-cxp-secret",
                 "input" => "raw prompt"
               })

      assert accumulated.request_metadata["routing"]["strategy"] == "pool_order"

      assert accumulated.request_metadata["routing"]["selected_bridge_candidate_id"] ==
               setup.assignment.id

      assert accumulated.request_metadata["authorization"] == "[REDACTED]"
      assert accumulated.request_metadata["input"] == "[REDACTED]"

      persisted_before = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert persisted_before.request_metadata["routing"]["strategy"] == "pool_order"
      refute persisted_before.request_metadata["routing"]["selected_bridge_candidate_id"]

      assert {:ok, persisted_after} =
               Accounting.persist_request_metadata(accumulated, reload?: false)

      assert persisted_after.request_metadata["routing"]["strategy"] == "pool_order"

      assert persisted_after.request_metadata["routing"]["selected_bridge_candidate_id"] ==
               setup.assignment.id

      metadata_text = inspect(persisted_after.request_metadata)
      refute metadata_text =~ "raw prompt"
      refute metadata_text =~ "sk-cxp-secret"
    end

    test "create_attempt is idempotent when a database retry replays the generated id" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => "metadata only"},
                 %{correlation_id: "corr-attempt-pkey-retry"}
               )

      attempt_id = Ecto.UUID.generate()
      attrs = %{id: attempt_id, response_metadata: %{"retry_kind" => "db_replay"}}

      assert {:ok, first_attempt} =
               Accounting.create_attempt(reserved.request, setup.assignment, attrs)

      assert first_attempt.id == attempt_id

      assert {:ok, retried_attempt} =
               Accounting.create_attempt(reserved.request, setup.assignment, attrs)

      assert retried_attempt.id == first_attempt.id
      assert retried_attempt.attempt_number == first_attempt.attempt_number

      assert Repo.aggregate(
               from(attempt in Attempt, where: attempt.request_id == ^reserved.request.id),
               :count
             ) == 1
    end

    test "timeout before headers finalizes as failed with unknown usage" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-timeout-before"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 last_error_code: "timeout_before_headers",
                 response_status_code: nil,
                 usage: %{status: "usage_unknown"}
               })

      assert result.request.status == "failed"
      assert result.settlement.usage_status == "usage_unknown"
      assert result.request.last_error_code == "timeout_before_headers"
    end

    test "healthy reservation settlement avoids duplicate ledger rereads" do
      setup = accounting_setup()

      {_result, commands} =
        count_repo_commands(fn ->
          assert {:ok, reserved} =
                   Accounting.reserve(
                     setup.auth,
                     setup.model,
                     %{
                       "model" => setup.model.exposed_model_id,
                       "input" => "metadata only",
                       "max_output_tokens" => 5
                     },
                     %{correlation_id: "corr-ledger-rereads"}
                   )

          assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

          Accounting.finalize_success(
            reserved.request,
            attempt,
            %{status: "usage_known", input_tokens: 7, output_tokens: 3, total_tokens: 10},
            %{response_status_code: 200}
          )
        end)

      # Three reservation-window aggregates plus at most one finalization reread.
      assert command_count(commands, "ledger_entries", "SELECT") <= 4
      assert command_count(commands, "ledger_entries", "INSERT") == 3
      assert command_count(commands, "api_key_policy_bindings", "SELECT") == 1
    end

    test "repeated finalization reuses existing settlement without duplicate rollups" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 5},
                 %{correlation_id: "corr-idempotent-finalize"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      usage = %{status: "usage_known", input_tokens: 7, output_tokens: 3, total_tokens: 10}

      assert {:ok, first} =
               Accounting.finalize_success(reserved.request, attempt, usage, %{
                 response_status_code: 200
               })

      assert {:ok, second} =
               Accounting.finalize_success(first.request, first.attempt, usage, %{
                 response_status_code: 200
               })

      assert first.settlement.id == second.settlement.id
      assert first.release.id == second.release.id

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where: e.request_id == ^reserved.request.id and e.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert [rollup] =
               Repo.all(
                 from r in DailyRollup,
                   where: r.api_key_id == ^setup.api_key.id and r.dimension_kind == "api_key"
               )

      assert rollup.request_count == 1
      assert rollup.success_count == 1
      assert rollup.total_tokens == 10
    end

    test "late known usage replaces an unknown settlement and its projections" do
      setup = accounting_setup()
      first_timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      known_timestamp = DateTime.add(first_timestamp, 1, :second)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 5},
                 %{correlation_id: "corr-late-known-usage"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, failed} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 last_error_code: "owner_drained",
                 now: first_timestamp,
                 usage: %{status: "usage_unknown", source: "owner_drained"}
               })

      assert failed.request.status == "failed"
      assert failed.settlement.usage_status == "usage_unknown"

      known_usage = %{
        status: "usage_known",
        source: "late_owner_completion",
        recorded_at: known_timestamp,
        input_tokens: 7,
        output_tokens: 3,
        total_tokens: 10
      }

      assert {:ok, reconciled} =
               Accounting.finalize_success(failed.request, failed.attempt, known_usage, %{
                 now: known_timestamp,
                 response_status_code: 200
               })

      assert reconciled.request.status == "succeeded"
      assert reconciled.request.usage_status == "usage_known"
      assert reconciled.attempt.status == "succeeded"
      assert reconciled.attempt.usage_status == "usage_known"
      assert reconciled.settlement.usage_status == "usage_known"
      assert reconciled.settlement.correction_of_entry_id == failed.settlement.id
      assert reconciled.settlement.source_event_id =~ ":settlement:usage-known"

      assert {:ok, repeated} =
               Accounting.finalize_success(
                 reconciled.request,
                 reconciled.attempt,
                 known_usage,
                 %{now: known_timestamp, response_status_code: 200}
               )

      assert repeated.settlement.id == reconciled.settlement.id

      settlements =
        Repo.all(
          from entry in LedgerEntry,
            where: entry.request_id == ^reserved.request.id and entry.entry_kind == "settlement",
            order_by: [asc: entry.created_at, asc: entry.id]
        )

      assert [voided, recorded] = settlements
      assert voided.id == failed.settlement.id
      assert voided.amount_status == "voided"
      assert recorded.id == reconciled.settlement.id
      assert recorded.amount_status == "recorded"

      assert [daily_rollup] =
               Repo.all(
                 from rollup in DailyRollup,
                   where:
                     rollup.api_key_id == ^setup.api_key.id and
                       rollup.dimension_kind == "api_key"
               )

      assert daily_rollup.request_count == 1
      assert daily_rollup.success_count == 1
      assert daily_rollup.failure_count == 0
      assert daily_rollup.total_tokens == 10

      assert [hourly_rollup] =
               Repo.all(
                 from rollup in HourlyModelUsageRollup,
                   where:
                     rollup.pool_id == ^setup.pool.id and
                       rollup.model_code == ^setup.model.exposed_model_id
               )

      assert hourly_rollup.request_count == 1
      assert hourly_rollup.success_count == 1
      assert hourly_rollup.failure_count == 0
      assert hourly_rollup.total_tokens == 10

      fact = Repo.get_by!(RequestLogFact, request_id: reserved.request.id)
      assert fact.latest_attempt_status == "succeeded"
      assert fact.latest_settlement_entry_id == reconciled.settlement.id
      assert fact.latest_settlement_usage_status == "usage_known"
      assert fact.latest_total_tokens == 10
    end

    test "releases stale undispatched reservations without settling usage" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-stale-undispatched", now: stale_admitted_at}
               )

      assert {:ok, %{stale_reservations_released: 1, stale_reservations_settled: 0}} =
               Accounting.recover_stale_reservations(now)

      request = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert request.status == "failed"
      assert request.usage_status == "not_applicable"
      assert request.last_error_code == "stale_reservation_recovered"

      entries = Accounting.list_ledger_entries_for_request(reserved.request.id)
      assert Enum.map(entries, & &1.entry_kind) |> Enum.sort() == ["release", "reservation"]

      assert Enum.find(entries, &(&1.entry_kind == "release")).details["release_reason"] ==
               "stale_reservation_recovered"

      assert {:ok, %{stale_reservations_released: 0, stale_reservations_settled: 0}} =
               Accounting.recover_stale_reservations(now)
    end

    test "settles stale dispatched reservations from reserved estimate when usage is unknown" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-stale-dispatched", now: stale_admitted_at}
               )

      assert {:ok, _attempt} =
               Accounting.create_attempt(reserved.request, setup.assignment, %{
                 now: stale_admitted_at
               })

      assert {:ok, %{stale_reservations_released: 0, stale_reservations_settled: 1}} =
               Accounting.recover_stale_reservations(now)

      request = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert request.status == "failed"
      assert request.usage_status == "usage_unknown"
      assert request.last_error_code == "stale_reservation_recovered"

      entries = Accounting.list_ledger_entries_for_request(reserved.request.id)

      assert Enum.map(entries, & &1.entry_kind) |> Enum.sort() == [
               "release",
               "reservation",
               "settlement"
             ]

      settlement = Enum.find(entries, &(&1.entry_kind == "settlement"))
      assert settlement.usage_status == "usage_unknown"
      assert settlement.output_tokens == reserved.reservation.output_tokens
      assert settlement.total_tokens == reserved.reservation.total_tokens
      assert settlement.details["usage_source"] == "stale_reservation_recovery"
      assert settlement.details["estimated_from_reserve"] == true

      assert {:ok, %{stale_reservations_released: 0, stale_reservations_settled: 0}} =
               Accounting.recover_stale_reservations(now)
    end

    test "does not recover active long-running codex turns before the owner lease expires" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "stream" => true,
                   "max_output_tokens" => 10
                 },
                 %{correlation_id: "corr-active-turn", now: stale_admitted_at}
               )

      assert {:ok, attempt} =
               Accounting.create_attempt(reserved.request, setup.assignment, %{
                 now: stale_admitted_at
               })

      session =
        %CodexSession{
          pool_id: setup.pool.id,
          api_key_id: setup.api_key.id,
          session_key: "session-#{System.unique_integer([:positive])}",
          pool_upstream_assignment_id: setup.assignment.id,
          status: "active",
          owner_instance_id: "worker-1",
          owner_lease_token: Ecto.UUID.generate(),
          owner_lease_expires_at: DateTime.add(now, 5, :minute),
          last_heartbeat_at: now,
          created_at: stale_admitted_at,
          updated_at: stale_admitted_at
        }
        |> Repo.insert!()

      %CodexTurn{
        codex_session_id: session.id,
        request_id: reserved.request.id,
        turn_sequence: 1,
        transport_kind: "http_sse",
        status: "in_progress",
        final_attempt_id: attempt.id,
        started_at: stale_admitted_at,
        created_at: stale_admitted_at,
        updated_at: stale_admitted_at
      }
      |> Repo.insert!()

      assert {:ok, %{stale_reservations_released: 0, stale_reservations_settled: 0}} =
               Accounting.recover_stale_reservations(now)

      assert Repo.get!(CodexPooler.Accounting.Request, reserved.request.id).status ==
               "in_progress"

      assert Accounting.list_ledger_entries_for_request(reserved.request.id)
             |> Enum.map(& &1.entry_kind) == ["reservation"]
    end

    test "recovers stale in-progress codex turns when no owner lease is active" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "stream" => true,
                   "max_output_tokens" => 10
                 },
                 %{correlation_id: "corr-stale-turn-no-owner", now: stale_admitted_at}
               )

      assert {:ok, attempt} =
               Accounting.create_attempt(reserved.request, setup.assignment, %{
                 now: stale_admitted_at
               })

      session =
        %CodexSession{
          pool_id: setup.pool.id,
          api_key_id: setup.api_key.id,
          session_key: "session-#{System.unique_integer([:positive])}",
          pool_upstream_assignment_id: setup.assignment.id,
          status: "active",
          created_at: stale_admitted_at,
          updated_at: stale_admitted_at
        }
        |> Repo.insert!()

      turn =
        %CodexTurn{
          codex_session_id: session.id,
          request_id: reserved.request.id,
          turn_sequence: 1,
          transport_kind: "http_sse",
          status: "in_progress",
          final_attempt_id: attempt.id,
          started_at: stale_admitted_at,
          created_at: stale_admitted_at,
          updated_at: stale_admitted_at
        }
        |> Repo.insert!()

      assert {:ok, %{stale_reservations_released: 0, stale_reservations_settled: 1}} =
               Accounting.recover_stale_reservations(now)

      assert Repo.get!(CodexPooler.Accounting.Request, reserved.request.id).last_error_code ==
               "stale_reservation_recovered"

      assert Repo.reload!(attempt).status == "failed"

      assert %CodexTurn{
               status: "interrupted",
               error_code: "stale_reservation_recovered",
               final_attempt_id: attempt_id
             } = Repo.reload!(turn)

      assert attempt_id == attempt.id
    end

    test "skips already finalized reservations during stale recovery" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-finalized-skip", now: stale_admitted_at}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, _result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 4, output_tokens: 3, total_tokens: 7},
                 %{response_status_code: 200}
               )

      assert {:ok, %{stale_reservations_released: 0, stale_reservations_settled: 0}} =
               Accounting.recover_stale_reservations(now)

      entries = Accounting.list_ledger_entries_for_request(reserved.request.id)

      assert Enum.map(entries, & &1.entry_kind) |> Enum.sort() == [
               "release",
               "reservation",
               "settlement"
             ]
    end

    test "partial stream failure is accounted once and remains metadata-only" do
      setup = accounting_setup()
      raw_output = "partial assistant output should not persist"

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "stream" => true,
                   "input" => "raw prompt"
                 },
                 %{
                   endpoint: "/backend-api/codex/responses",
                   correlation_id: "corr-partial-stream",
                   request_metadata: %{"raw_response" => raw_output, "cookie" => "session=secret"}
                 }
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, first} =
               Accounting.finalize_partial_stream_failure(reserved.request, attempt, %{}, %{
                 last_error_code: "timeout_mid_stream"
               })

      assert {:ok, second} =
               Accounting.finalize_partial_stream_failure(first.request, first.attempt, %{}, %{
                 last_error_code: "timeout_mid_stream"
               })

      assert first.settlement.id == second.settlement.id
      assert first.request.status == "failed"
      assert first.settlement.usage_status == "usage_unknown"

      entries = Accounting.list_ledger_entries_for_request(reserved.request.id)
      assert length(entries) == 3

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where: e.request_id == ^reserved.request.id and e.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert [rollup] =
               Repo.all(
                 from r in DailyRollup,
                   where: r.api_key_id == ^setup.api_key.id and r.dimension_kind == "api_key"
               )

      assert rollup.request_count == 1
      assert rollup.failure_count == 1

      metadata =
        Repo.get!(CodexPooler.Accounting.Request, reserved.request.id).request_metadata

      assert metadata["raw_response"] == "[REDACTED]"
      assert metadata["cookie"] == "[REDACTED]"
      refute inspect(metadata) =~ raw_output
      refute inspect(entries) =~ "raw prompt"
    end

    test "shared upstream identity rollups update without cross-pool uniqueness crashes" do
      setup = accounting_setup()
      other_pool = pool_fixture()
      other_key = active_api_key_fixture(other_pool)

      {:ok, other_assignment} =
        PoolAssignments.create_pool_assignment(
          other_pool,
          setup.identity,
          %{
            assignment_label: "Shared upstream identity",
            metadata: %{},
            skip_quota_priming: true
          }
        )

      {:ok, other_assignment} =
        PoolAssignments.activate_pool_assignment(other_assignment, %{
          skip_quota_priming: true
        })

      first_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          correlation_id: "shared-rollup-1"
        })

      second_request =
        request_fixture(%{pool: other_pool, api_key: other_key.api_key}, %{
          correlation_id: "shared-rollup-2"
        })

      first_settlement =
        ledger_entry_fixture(first_request, %{
          pool_upstream_assignment_id: setup.assignment.id,
          upstream_identity_id: setup.identity.id,
          total_tokens: 11
        })

      second_settlement =
        ledger_entry_fixture(second_request, %{
          pool_upstream_assignment_id: other_assignment.id,
          upstream_identity_id: setup.identity.id,
          total_tokens: 13
        })

      assert :ok = Rollups.accumulate!(first_request, first_settlement)
      assert :ok = Rollups.accumulate!(second_request, second_settlement)

      today = DateTime.to_date(first_settlement.occurred_at)

      assert [rollup] =
               Repo.all(
                 from r in DailyRollup,
                   where:
                     r.dimension_kind == "upstream_identity" and
                       r.upstream_identity_id == ^setup.identity.id and
                       r.rollup_date == ^today
               )

      assert rollup.request_count == 2
      assert rollup.total_tokens == 24
    end

    test "API key moved between pools keeps a separate daily rollup for each pool" do
      setup = accounting_setup()
      other_pool = pool_fixture()

      first_request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          correlation_id: "api-key-before-pool-move"
        })

      moved_api_key =
        setup.api_key
        |> Ecto.Changeset.change(pool_id: other_pool.id)
        |> Repo.update!()

      second_request =
        request_fixture(%{pool: other_pool, api_key: moved_api_key}, %{
          correlation_id: "api-key-after-pool-move"
        })

      first_settlement = ledger_entry_fixture(first_request, %{total_tokens: 11})
      second_settlement = ledger_entry_fixture(second_request, %{total_tokens: 13})

      assert :ok = Rollups.accumulate!(first_request, first_settlement)
      assert :ok = Rollups.accumulate!(second_request, second_settlement)

      date = DateTime.to_date(first_settlement.occurred_at)

      expected =
        Enum.sort([
          {setup.pool.id, 1, 11},
          {other_pool.id, 1, 13}
        ])

      assert api_key_rollup_summaries(date, setup.api_key.id) == expected

      assert {:ok, 2} = Accounting.rebuild_daily_rollups_for_date(date)
      assert api_key_rollup_summaries(date, setup.api_key.id) == expected
    end

    test "incremental daily rollups use atomic conflict-safe increments" do
      setup = accounting_setup()

      request_settlements =
        for index <- 1..2 do
          request =
            request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
              correlation_id: "atomic-daily-rollup-#{index}",
              model_id: setup.model.id,
              requested_model: setup.model.exposed_model_id
            })

          settlement =
            ledger_entry_fixture(request, %{
              pool_upstream_assignment_id: setup.assignment.id,
              upstream_identity_id: setup.identity.id,
              input_tokens: 7,
              cached_input_tokens: 3,
              output_tokens: 5,
              reasoning_tokens: 2,
              total_tokens: 12,
              estimated_cost_micros: 11,
              settled_cost_micros: 9
            })

          {request, settlement}
        end

      {results, commands} =
        count_repo_commands(fn ->
          Enum.map(request_settlements, fn {request, settlement} ->
            Rollups.accumulate!(request, settlement)
          end)
        end)

      assert results == [:ok, :ok]
      assert command_count(commands, "daily_rollups", "SELECT") == 0
      assert command_count(commands, "daily_rollups", "UPDATE") == 0
      assert command_count(commands, "daily_rollups", "INSERT") == 10

      date =
        request_settlements |> hd() |> elem(1) |> Map.fetch!(:occurred_at) |> DateTime.to_date()

      rollups = daily_rollup_rows(date)

      assert Enum.map(rollups, & &1.dimension_kind) |> Enum.sort() ==
               Enum.sort(daily_rollup_dimensions())

      assert Enum.all?(rollups, &(&1.request_count == 2))
      assert Enum.all?(rollups, &(&1.total_tokens == 24))
      assert Enum.all?(rollups, &(&1.cached_input_tokens == 6))
      assert Enum.all?(rollups, &(&1.estimated_cost_micros == "22"))
      assert Enum.all?(rollups, &(&1.settled_cost_micros == "18"))
    end

    @tag :daily_rollup_rebuild_set_based_correctness
    test "daily rollup rebuild matches incremental rollups across every dimension" do
      date = ~D[2026-05-31]
      fixture = daily_rollup_rebuild_fixture(date)

      rebuild_expected_rollups!(date, fixture.settlements)
      expected_rows = daily_rollup_rows(date)

      assert {:ok, 3} = Accounting.rebuild_daily_rollups_for_date(date)
      actual_rows = daily_rollup_rows(date)

      assert actual_rows == expected_rows
      assert MapSet.new(actual_rows, & &1.dimension_kind) == MapSet.new(daily_rollup_dimensions())
      assert Enum.count(actual_rows) == 9

      assert rollup_row(actual_rows, "pool", pool_id: fixture.primary.pool.id).request_count == 2
      assert rollup_row(actual_rows, "pool", pool_id: fixture.primary.pool.id).success_count == 1
      assert rollup_row(actual_rows, "pool", pool_id: fixture.primary.pool.id).failure_count == 1
      assert rollup_row(actual_rows, "pool", pool_id: fixture.primary.pool.id).retry_count == 3
      assert rollup_row(actual_rows, "pool", pool_id: fixture.primary.pool.id).input_tokens == 10

      assert rollup_row(actual_rows, "pool", pool_id: fixture.primary.pool.id).settled_cost_micros ==
               "90.25"

      assert rollup_row(actual_rows, "pool", pool_id: fixture.secondary.pool.id).request_count ==
               1

      assert rollup_row(actual_rows, "pool", pool_id: fixture.secondary.pool.id).success_count ==
               1

      assert rollup_row(actual_rows, "pool", pool_id: fixture.secondary.pool.id).failure_count ==
               0

      identity_row =
        rollup_row(actual_rows, "upstream_identity",
          upstream_identity_id: fixture.primary.identity.id
        )

      assert identity_row.pool_id == fixture.secondary.pool.id
      assert identity_row.request_count == 2
      assert identity_row.success_count == 2
      assert identity_row.retry_count == 2
      assert identity_row.input_tokens == 15
      assert identity_row.cached_input_tokens == 4
      assert identity_row.output_tokens == 18
      assert identity_row.reasoning_tokens == 6
      assert identity_row.total_tokens == 42
      assert identity_row.estimated_cost_micros == "130.5"
      assert identity_row.settled_cost_micros == "115.375"

      assert Enum.count(actual_rows, &(&1.dimension_kind == "pool_upstream_assignment")) == 2
      assert Enum.count(actual_rows, &(&1.dimension_kind == "upstream_identity")) == 1
      assert Enum.count(actual_rows, &(&1.dimension_kind == "model")) == 2

      assert rollup_row(actual_rows, "api_key", api_key_id: fixture.primary.api_key.id).request_count ==
               2

      assert rollup_row(actual_rows, "api_key", api_key_id: fixture.primary.api_key.id).estimated_cost_micros ==
               "100.125"

      assert rollup_row(actual_rows, "model", model_id: fixture.primary.model.id).total_tokens ==
               22

      assert rollup_row(actual_rows, "model", model_id: fixture.secondary.model.id).total_tokens ==
               20
    end

    @tag :daily_rollup_rebuild_boundaries
    test "daily rollup rebuild clears stale empty-day rows" do
      date = ~D[2026-06-01]
      pool = pool_fixture()
      insert_daily_rollup!(date, %{dimension_kind: "pool", pool_id: pool.id, request_count: 9})

      assert {:ok, 0} = Accounting.rebuild_daily_rollups_for_date(date)
      assert [] = daily_rollup_rows(date)
    end

    @tag :daily_rollup_rebuild_boundaries
    test "daily rollup rebuild rolls back stale rows when replacement insert fails" do
      date = ~D[2026-06-02]
      fixture = daily_rollup_rebuild_fixture(date)

      stale_rollup =
        insert_daily_rollup!(date, %{dimension_kind: "pool", pool_id: fixture.primary.pool.id})

      Repo.query!("""
      ALTER TABLE daily_rollups
      ADD CONSTRAINT daily_rollups_rebuild_failure_check CHECK (false) NOT VALID
      """)

      assert_raise Postgrex.Error, fn ->
        Accounting.rebuild_daily_rollups_for_date(date)
      end

      assert Repo.get!(DailyRollup, stale_rollup.id).request_count == stale_rollup.request_count
    end

    @tag :daily_rollup_rebuild_boundaries
    test "daily rollup rebuild query count is independent from settlement count" do
      one_date = ~D[2026-06-03]
      many_date = ~D[2026-06-04]
      setup = accounting_setup()

      insert_rollup_query_budget_settlements!(setup, one_date, 1)
      insert_rollup_query_budget_settlements!(setup, many_date, 20)

      {one_result, one_commands} =
        count_repo_commands(fn -> Accounting.rebuild_daily_rollups_for_date(one_date) end)

      {many_result, many_commands} =
        count_repo_commands(fn -> Accounting.rebuild_daily_rollups_for_date(many_date) end)

      assert {:ok, 1} = one_result
      assert {:ok, 20} = many_result

      assert command_count(one_commands, "daily_rollups", "SELECT") == 0
      assert command_count(many_commands, "daily_rollups", "SELECT") == 0
      assert command_count(one_commands, "daily_rollups", "UPDATE") == 0
      assert command_count(many_commands, "daily_rollups", "UPDATE") == 0

      one_total = total_repo_command_count(one_commands)
      many_total = total_repo_command_count(many_commands)

      assert one_total <= 4

      assert many_total == one_total,
             "daily rollup rebuild query count must be row-count independent; one settlement used #{one_total}, twenty settlements used #{many_total}"
    end
  end

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "accounting-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, metadata[:source], command_name(metadata[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_commands(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_commands(handler_id, commands) do
    receive do
      {^handler_id, source, command} ->
        key = {source, command}
        drain_repo_commands(handler_id, Map.update(commands, key, 1, &(&1 + 1)))
    after
      0 -> commands
    end
  end

  defp command_count(commands, source, command), do: Map.get(commands, {source, command}, 0)

  defp total_repo_command_count(commands), do: commands |> Map.values() |> Enum.sum()

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil

  defp daily_rollup_rebuild_fixture(date) do
    primary = accounting_setup()
    secondary_pool = pool_fixture()
    secondary_key = active_api_key_fixture(secondary_pool)
    secondary_model = model_fixture(secondary_pool, %{exposed_model_id: "gpt-rollup-secondary"})

    {:ok, secondary_assignment} =
      PoolAssignments.create_pool_assignment(
        secondary_pool,
        primary.identity,
        %{
          assignment_label: "Shared rollup upstream",
          metadata: %{},
          skip_quota_priming: true
        }
      )

    {:ok, secondary_assignment} =
      PoolAssignments.activate_pool_assignment(secondary_assignment, %{
        skip_quota_priming: true
      })

    tied_at = DateTime.new!(date, ~T[10:00:00.000000], "Etc/UTC")
    nil_dimension_at = DateTime.new!(date, ~T[11:00:00.000000], "Etc/UTC")

    primary_request =
      request_fixture(%{pool: primary.pool, api_key: primary.api_key}, %{
        correlation_id: "daily-rollup-primary",
        model_id: primary.model.id,
        status: "succeeded",
        retry_count: 2
      })

    nil_dimension_request =
      request_fixture(%{pool: primary.pool, api_key: primary.api_key}, %{
        correlation_id: "daily-rollup-nil-dimensions",
        model_id: nil,
        status: "failed",
        usage_status: "usage_unknown",
        retry_count: 1,
        response_status_code: 500
      })

    secondary_request =
      request_fixture(%{pool: secondary_pool, api_key: secondary_key.api_key}, %{
        correlation_id: "daily-rollup-secondary",
        model_id: secondary_model.id,
        status: "succeeded",
        retry_count: 0
      })

    primary_settlement =
      insert_rollup_settlement!(primary_request, %{
        id: "ffffffff-ffff-ffff-ffff-ffffffffffff",
        pool_upstream_assignment_id: primary.assignment.id,
        upstream_identity_id: primary.identity.id,
        input_tokens: 10,
        cached_input_tokens: 3,
        output_tokens: 7,
        reasoning_tokens: 2,
        total_tokens: 22,
        estimated_cost_micros: "100.125",
        settled_cost_micros: "90.25",
        occurred_at: tied_at,
        created_at: tied_at
      })

    secondary_settlement =
      insert_rollup_settlement!(secondary_request, %{
        id: "00000000-0000-0000-0000-000000000001",
        pool_upstream_assignment_id: secondary_assignment.id,
        upstream_identity_id: primary.identity.id,
        input_tokens: 5,
        cached_input_tokens: 1,
        output_tokens: 11,
        reasoning_tokens: 4,
        total_tokens: 20,
        estimated_cost_micros: "30.375",
        settled_cost_micros: "25.125",
        occurred_at: tied_at,
        created_at: tied_at
      })

    nil_dimension_settlement =
      insert_rollup_settlement!(nil_dimension_request, %{
        pool_upstream_assignment_id: nil,
        upstream_identity_id: nil,
        input_tokens: nil,
        cached_input_tokens: nil,
        output_tokens: nil,
        reasoning_tokens: nil,
        total_tokens: nil,
        estimated_cost_micros: "50.5",
        settled_cost_micros: "70.75",
        usage_status: "usage_unknown",
        occurred_at: nil_dimension_at,
        created_at: nil_dimension_at
      })

    %{
      primary: primary,
      secondary: %{
        pool: secondary_pool,
        api_key: secondary_key.api_key,
        assignment: secondary_assignment,
        model: secondary_model
      },
      settlements: [primary_settlement, secondary_settlement, nil_dimension_settlement]
    }
  end

  defp rebuild_expected_rollups!(date, settlements) do
    Repo.delete_all(from rollup in DailyRollup, where: rollup.rollup_date == ^date)

    settlements
    |> Enum.sort_by(&{&1.occurred_at, &1.created_at, &1.id})
    |> Enum.each(fn settlement ->
      request = Repo.get!(CodexPooler.Accounting.Request, settlement.request_id)
      assert :ok = Rollups.accumulate!(request, settlement)
    end)
  end

  defp insert_rollup_query_budget_settlements!(setup, date, count) do
    base_at = DateTime.new!(date, ~T[09:00:00.000000], "Etc/UTC")

    Enum.map(1..count, fn index ->
      request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          correlation_id: "daily-rollup-budget-#{date}-#{index}",
          model_id: setup.model.id,
          status: "succeeded",
          retry_count: rem(index, 3)
        })

      insert_rollup_settlement!(request, %{
        pool_upstream_assignment_id: setup.assignment.id,
        upstream_identity_id: setup.identity.id,
        input_tokens: index,
        cached_input_tokens: 0,
        output_tokens: index + 1,
        reasoning_tokens: 0,
        total_tokens: index * 2 + 1,
        estimated_cost_micros: index,
        settled_cost_micros: index,
        occurred_at: DateTime.add(base_at, index, :second),
        created_at: DateTime.add(base_at, index, :second)
      })
    end)
  end

  defp insert_rollup_settlement!(request, attrs) do
    %LedgerEntry{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      request_id: request.id,
      attempt_id: Map.get(attrs, :attempt_id),
      pricing_snapshot_id: Map.get(attrs, :pricing_snapshot_id),
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      pool_upstream_assignment_id: Map.get(attrs, :pool_upstream_assignment_id),
      upstream_identity_id: Map.get(attrs, :upstream_identity_id),
      model_id: request.model_id,
      entry_kind: Map.get(attrs, :entry_kind, "settlement"),
      amount_status: Map.get(attrs, :amount_status, "recorded"),
      usage_status: Map.get(attrs, :usage_status, "usage_known"),
      transport: Map.get(attrs, :transport, request.transport),
      currency_code: Map.get(attrs, :currency_code, "USD"),
      input_tokens: Map.get(attrs, :input_tokens),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens),
      output_tokens: Map.get(attrs, :output_tokens),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens),
      total_tokens: Map.get(attrs, :total_tokens),
      request_count: Map.get(attrs, :request_count, 1),
      estimated_cost_micros: decimal_value(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: decimal_value(Map.get(attrs, :settled_cost_micros, 0)),
      occurred_at: Map.fetch!(attrs, :occurred_at),
      created_at: Map.get(attrs, :created_at, Map.fetch!(attrs, :occurred_at)),
      details: Map.get(attrs, :details, %{})
    }
    |> Repo.insert!()
  end

  defp insert_daily_rollup!(date, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      Map.merge(
        %{
          rollup_date: date,
          dimension_kind: "pool",
          request_count: 1,
          success_count: 0,
          failure_count: 1,
          retry_count: 0,
          input_tokens: 0,
          cached_input_tokens: 0,
          output_tokens: 0,
          reasoning_tokens: 0,
          total_tokens: 0,
          estimated_cost_micros: Decimal.new(0),
          settled_cost_micros: Decimal.new(0),
          created_at: now,
          updated_at: now
        },
        attrs
      )

    struct(DailyRollup, attrs)
    |> Repo.insert!()
  end

  defp daily_rollup_rows(date) do
    DailyRollup
    |> where([rollup], rollup.rollup_date == ^date)
    |> Repo.all()
    |> Enum.map(&daily_rollup_row/1)
    |> Enum.sort_by(&daily_rollup_sort_key/1)
  end

  defp api_key_rollup_summaries(date, api_key_id) do
    DailyRollup
    |> where(
      [rollup],
      rollup.rollup_date == ^date and rollup.dimension_kind == "api_key" and
        rollup.api_key_id == ^api_key_id
    )
    |> Repo.all()
    |> Enum.map(&{&1.pool_id, &1.request_count, &1.total_tokens})
    |> Enum.sort()
  end

  defp daily_rollup_row(%DailyRollup{} = rollup) do
    %{
      rollup_date: rollup.rollup_date,
      dimension_kind: rollup.dimension_kind,
      pool_id: rollup.pool_id,
      api_key_id: rollup.api_key_id,
      pool_upstream_assignment_id: rollup.pool_upstream_assignment_id,
      upstream_identity_id: rollup.upstream_identity_id,
      model_id: rollup.model_id,
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
  end

  defp daily_rollup_sort_key(row) do
    {
      row.dimension_kind,
      row.pool_id,
      row.api_key_id,
      row.pool_upstream_assignment_id,
      row.upstream_identity_id,
      row.model_id
    }
  end

  defp rollup_row(rows, dimension_kind, match) do
    Enum.find(rows, fn row ->
      row.dimension_kind == dimension_kind and
        Enum.all?(match, fn {key, value} -> Map.fetch!(row, key) == value end)
    end) || flunk("missing #{dimension_kind} rollup matching #{inspect(match)}")
  end

  defp daily_rollup_dimensions do
    ["pool", "api_key", "pool_upstream_assignment", "upstream_identity", "model"]
  end

  defp decimal_value(%Decimal{} = value), do: value
  defp decimal_value(value), do: Decimal.new(value)

  defp decimal_string(%Decimal{} = value) do
    value
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end
end
