defmodule CodexPooler.AccountingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{DailyRollup, LedgerEntry, Rollups}
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

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil
end
