defmodule CodexPooler.Accounting.RequestLogsDetailsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  test "request log rows expose snapshots model settings route and cached token counts" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    pricing_snapshot =
      %PricingSnapshot{
        model_identifier: "gpt-row-shape",
        price_version: "test-cache-cost",
        currency_code: "USD",
        billing_unit: "token",
        input_token_micros: Decimal.new(10),
        cached_input_token_micros: Decimal.new(3),
        output_token_micros: Decimal.new(20),
        reasoning_token_micros: Decimal.new(0),
        request_base_micros: Decimal.new(0),
        effective_at: DateTime.add(now, -60, :second),
        captured_at: now,
        config: %{
          "service_tier" => "standard",
          "price_bucket" => "default",
          "pricing_type" => "per_1m_tokens"
        }
      }
      |> Repo.insert!()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-row-shape",
        endpoint: "/backend-api/codex/responses/compact",
        transport: "http_json",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "row-shape-compact-route"
      })
      |> Ecto.Changeset.change(%{
        upstream_account_label: "operator@example.com",
        upstream_account_email: "operator@example.com",
        upstream_account_plan_label: "chatgpt pro",
        upstream_account_plan_family: "paid",
        reasoning_effort: "high",
        service_tier: "priority",
        requested_service_tier: "auto",
        actual_service_tier: "priority"
      })
      |> Repo.update!()

    attempt = attempt_fixture(request, assignment)

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pricing_snapshot_id: pricing_snapshot.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      input_tokens: 11,
      cached_input_tokens: 4,
      output_tokens: 7,
      reasoning_tokens: 3,
      total_tokens: 21,
      settled_cost_micros: 42_000,
      details: %{
        "pricing_status" => "priced",
        "settled_cost_micros" => "42000",
        "cached_input_cost_micros" => "12"
      }
    })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.upstream_account_label == "operator@example.com"
    assert log.upstream_account_email == "operator@example.com"
    assert log.upstream_account_plan_label == "chatgpt pro"
    assert log.upstream_account_plan_family == "paid"
    assert log.upstream_identity_label == identity.account_label
    assert log.reasoning_effort == "high"
    assert log.service_tier == "priority"
    assert log.requested_service_tier == "auto"
    assert log.actual_service_tier == "priority"
    assert log.endpoint == "/backend-api/codex/responses/compact"
    assert log.transport == "http_json"
    assert log.token_counts.input_tokens == 11
    assert log.token_counts.cached_input_tokens == 4
    assert Decimal.equal?(log.token_counts.cached_input_cost_usd, Decimal.new("0.000012"))
    assert log.token_counts.output_tokens == 7
    assert log.token_counts.reasoning_tokens == 3
    assert log.token_counts.total_tokens == 21
    assert log.cost.status == "priced"
    assert Decimal.equal?(log.cost.usd, Decimal.new("0.042000"))
    assert log.errors == []
  end

  test "request log rows expose sanitized compression summary without raw candidate strings" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    sentinel = "SENTINEL_TOOL_OUTPUT_SHOULD_NOT_RENDER"
    compressed_sentinel = "SENTINEL_COMPRESSED_OUTPUT_SHOULD_NOT_STORE"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-row-compression",
        endpoint: "/backend-api/codex/responses",
        transport: "http_json",
        status: "succeeded",
        correlation_id: "row-compression"
      })

    assert {:ok, _attempt} =
             Accounting.create_attempt(request, assignment, %{
               status: "succeeded",
               response_metadata: %{
                 "payload_compression" => %{
                   "enabled" => true,
                   "attempted" => true,
                   "status" => "compressed",
                   "reason" => "rewritten",
                   "route_class" => "proxy_http",
                   "transport" => "http_json",
                   "candidate_count" => 3,
                   "compressed_count" => 2,
                   "skipped_count" => 1,
                   "original_bytes" => 12_000,
                   "compressed_bytes" => 3_000,
                   "original_tokens" => 900,
                   "compressed_tokens" => 300,
                   "strategies" => ["log_output", "diff"],
                   "raw_candidate" => sentinel,
                   "original_output" => sentinel,
                   "compressed_output" => compressed_sentinel
                 }
               }
             })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.metadata["payload_compression"]["candidate_count"] == 3
    assert log.metadata["payload_compression"]["compressed_count"] == 2
    assert log.metadata["payload_compression"]["skipped_count"] == 1
    assert log.metadata["payload_compression"]["saved_bytes"] == 9000
    assert log.metadata["payload_compression"]["saved_tokens"] == 600

    assert log.payload_compression.status == "compressed"
    assert log.payload_compression.reason == "rewritten"
    assert log.payload_compression.unit == "tokens"
    assert log.payload_compression.saved_count == 600
    assert log.payload_compression.savings_percent == 66.67
    assert log.payload_compression.compression_ratio == 0.3333

    log_text = inspect(log)
    refute log_text =~ sentinel
    refute log_text =~ compressed_sentinel
  end

  test "request log rows aggregate all sanitized denial attempt degraded and retryable errors" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    secret_token = "Bearer sk-cxp-abcdef123456-secretValue"
    raw_body = "raw upstream body must not leak"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-errors-log",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "row-errors",
        request_metadata: %{
          "routing" => %{
            "strategy" => "bridge_ring",
            "demotion_reason" => "upstream_5xx",
            "authorization" => secret_token
          },
          "candidate_exclusions" => [
            %{
              "reasons" => [
                %{"code" => "routing_circuit_open", "message" => secret_token},
                %{"code" => "quota_stale"}
              ]
            }
          ],
          "retryable_summary" => %{
            "code" => "retryable_upstream_status",
            "message" => "first backend can be retried",
            "authorization" => secret_token
          },
          "body" => %{"input" => raw_body}
        }
      })
      |> Ecto.Changeset.change(%{last_error_code: "quota_account_primary_unknown"})
      |> Repo.update!()

    request
    |> attempt_fixture(assignment, %{attempt_number: 1})
    |> Ecto.Changeset.change(%{
      status: "retryable_failed",
      retryable: true,
      network_error_code: "retryable_upstream_status",
      error_message: secret_token,
      upstream_status_code: 502,
      response_metadata: %{
        "error_code" => "retryable_upstream_status",
        "message" => "upstream returned 502",
        "authorization" => secret_token,
        "body" => raw_body
      }
    })
    |> Repo.update!()

    request
    |> attempt_fixture(assignment, %{attempt_number: 2})
    |> Ecto.Changeset.change(%{
      status: "failed",
      retryable: false,
      network_error_code: "upstream_status",
      error_message: "safe upstream status",
      upstream_status_code: 400,
      response_metadata: %{
        "error_code" => "upstream_status",
        "message" => "upstream rejected request",
        "raw_response" => raw_body
      }
    })
    |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.denial_reason == "quota_account_primary_unknown"
    assert log.metadata["body"] == "[REDACTED]"
    assert log.metadata["routing"]["authorization"] == "[REDACTED]"

    assert Enum.any?(
             log.errors,
             &(&1.source == "request" and &1.code == "quota_account_primary_unknown")
           )

    assert Enum.any?(log.errors, &(&1.source == "metadata" and &1.code == "routing_circuit_open"))
    refute Enum.any?(log.errors, &(&1.source == "metadata" and &1.code == "upstream_5xx"))

    assert Enum.any?(log.errors, fn error ->
             error.source == "attempt" and error.attempt_number == 1 and
               error.code == "retryable_upstream_status" and error.retryable == true
           end)

    assert Enum.any?(log.errors, fn error ->
             error.source == "attempt" and error.attempt_number == 2 and
               error.code == "upstream_status" and error.upstream_status_code == 400
           end)

    assert length(log.errors) >= 4
    refute inspect(log.errors) =~ secret_token
    refute inspect(log.errors) =~ raw_body
    refute inspect(log) =~ secret_token
    refute inspect(log) =~ raw_body
  end

  test "request log debug detail attempts are bounded to latest ten in ascending order" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-debug-detail-attempts",
        status: "failed",
        correlation_id: "debug-detail-attempts",
        request_metadata: %{"codex_session_id" => "session-detail-attempts"}
      })
      |> Ecto.Changeset.change(last_error_code: "final_failure")
      |> Repo.update!()

    attempts =
      for attempt_number <- 1..12 do
        request
        |> attempt_fixture(assignment, %{
          attempt_number: attempt_number,
          status: if(attempt_number == 12, do: "failed", else: "retryable_failed"),
          retryable: attempt_number < 12,
          upstream_status_code: 500 + attempt_number
        })
        |> Ecto.Changeset.change(%{
          latency_ms: attempt_number * 10,
          network_error_code: "attempt_error_#{attempt_number}",
          error_message: "raw attempt #{attempt_number} must not enter debug"
        })
        |> Repo.update!()
      end

    final_attempt = List.last(attempts)
    turn = debug_turn_fixture(pool, api_key, assignment, request, final_attempt.id)

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)

    assert log.debug.attempt.attempt_count == 12
    assert log.debug.attempt.latest_attempt_number == 12
    assert log.debug.attempt.latest_attempt_status == "failed"
    assert log.debug.turn.turn_ref == stable_ref(:turn, turn.id)
    assert log.debug.turn.final_attempt_ref == stable_attempt_ref(request.id, 12)

    assert Enum.map(log.debug.attempts, & &1.attempt_number) == Enum.to_list(3..12)
    assert length(log.debug.attempts) == 10
    assert hd(log.debug.attempts).attempt_ref == stable_attempt_ref(request.id, 3)
    assert List.last(log.debug.attempts).attempt_ref == stable_attempt_ref(request.id, 12)
    assert List.last(log.debug.attempts).final == true
    assert Enum.count(log.debug.attempts, & &1.final) == 1
    refute inspect(log.debug) =~ "raw attempt"
  end

  defp debug_turn_fixture(pool, api_key, assignment, request, final_attempt_id) do
    now = ~U[2026-05-26 00:00:00.000000Z]

    session =
      %CodexSession{
        pool_id: pool.id,
        api_key_id: api_key.id,
        session_key: "session-key-#{request.correlation_id}",
        conversation_key: "conversation-#{request.correlation_id}",
        pool_upstream_assignment_id: assignment.id,
        status: "active",
        owner_instance_id: "test-instance",
        owner_lease_token: Ecto.UUID.generate(),
        owner_lease_expires_at: DateTime.add(now, 60, :second),
        last_heartbeat_at: now,
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()

    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: request.transport,
      status: "failed",
      error_code: "turn_failed",
      first_visible_output_at: now,
      final_attempt_id: final_attempt_id,
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: DateTime.add(now, 1, :second)
    }
    |> Repo.insert!()
  end

  defp stable_ref(:turn, value), do: "turn_" <> stable_hash("codex_turn:" <> value)

  defp stable_attempt_ref(request_id, attempt_number) do
    "attempt_" <> stable_hash("request_attempt:#{request_id}:#{attempt_number}")
  end

  defp stable_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
