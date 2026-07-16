defmodule CodexPooler.Accounting.RequestLogsDetailsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{LedgerEntry, RequestLogFact}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

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

    attempt =
      attempt_fixture(request, assignment, %{
        response_metadata: %{
          "reasoning" => %{
            "requested_effort" => "high",
            "applied_effort" => "max",
            "effective_effort" => "max",
            "source" => "api_key_policy",
            "rewrite" => "high_to_max"
          }
        }
      })

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
    assert log.applied_reasoning_effort == "max"
    assert log.effective_reasoning_effort == "max"
    assert log.reasoning_effort_source == "api_key_policy"
    assert log.reasoning_effort_rewrite == "high_to_max"
    assert log.service_tier == "priority"
    assert log.requested_service_tier == "auto"
    assert log.actual_service_tier == "priority"
    assert log.endpoint == "/backend-api/codex/responses/compact"
    assert log.transport == "http_json"
    assert log.token_counts.input_tokens == 11
    assert log.token_counts.cached_input_tokens == 4
    assert is_nil(Map.get(log.token_counts, :cache_write_tokens))
    assert Decimal.equal?(log.token_counts.cached_input_cost_usd, Decimal.new("0.000012"))
    assert log.token_counts.output_tokens == 7
    assert log.token_counts.reasoning_tokens == 3
    assert log.token_counts.total_tokens == 21
    assert log.cost.status == "priced"
    assert Decimal.equal?(log.cost.usd, Decimal.new("0.042000"))
    assert log.errors == []
  end

  test "request log facts preserve positive cache-write usage while legacy NULL remains nil" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    positive_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "cache-write-positive",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "cache-write-positive"
      })

    positive_attempt = attempt_fixture(positive_request, assignment)

    positive_entry =
      ledger_entry_fixture(positive_request, %{
        attempt_id: positive_attempt.id,
        input_tokens: 11,
        cached_input_tokens: 4,
        cache_write_tokens: 3,
        output_tokens: 7,
        total_tokens: 18,
        details: %{
          "pricing_status" => "priced",
          "settled_cost_micros" => "42"
        }
      })

    legacy_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "cache-write-legacy-null",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "cache-write-legacy-null"
      })

    legacy_attempt = attempt_fixture(legacy_request, assignment)

    legacy_entry =
      ledger_entry_fixture(legacy_request, %{
        attempt_id: legacy_attempt.id,
        input_tokens: 5,
        output_tokens: 2,
        total_tokens: 7,
        details: %{"pricing_status" => "priced", "settled_cost_micros" => "12"}
      })

    persisted_positive_entry = Repo.get!(LedgerEntry, positive_entry.id)
    persisted_legacy_entry = Repo.get!(LedgerEntry, legacy_entry.id)
    positive_fact = Repo.get!(RequestLogFact, positive_request.id)
    legacy_fact = Repo.get!(RequestLogFact, legacy_request.id)

    assert is_nil(Map.get(persisted_legacy_entry, :cache_write_tokens))
    assert Map.get(persisted_positive_entry, :cache_write_tokens) == 3
    assert Map.get(positive_fact, :latest_cache_write_tokens) == 3
    assert is_nil(Map.get(legacy_fact, :latest_cache_write_tokens))

    assert %{items: logs, total: 2} = Accounting.list_request_logs(pool)
    logs_by_id = Map.new(logs, &{&1.id, &1})

    assert Map.get(logs_by_id[positive_request.id].token_counts, :cache_write_tokens) == 3
    assert is_nil(Map.get(logs_by_id[legacy_request.id].token_counts, :cache_write_tokens))
  end

  test "request detail component cost follows the fact settlement entry exactly" do
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, [])
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "cache-write-settlement-authority",
        status: "succeeded",
        usage_status: "usage_known"
      })

    attempt = attempt_fixture(request, assignment)
    earlier = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    authoritative_entry =
      ledger_entry_fixture(request, %{
        attempt_id: attempt.id,
        input_tokens: 11,
        cached_input_tokens: 4,
        cache_write_tokens: 3,
        output_tokens: 7,
        total_tokens: 18,
        occurred_at: earlier,
        created_at: earlier,
        details: %{
          "pricing_status" => "priced",
          "settled_cost_micros" => "42",
          "cache_write_cost_micros" => "250000"
        }
      })

    authoritative_entry
    |> Ecto.Changeset.change(entry_kind: "correction")
    |> Repo.update!()

    _chronologically_newer_entry =
      ledger_entry_fixture(request, %{
        attempt_id: attempt.id,
        input_tokens: 99,
        cached_input_tokens: 0,
        cache_write_tokens: 90,
        output_tokens: 1,
        total_tokens: 100,
        details: %{
          "pricing_status" => "priced",
          "settled_cost_micros" => "999",
          "cache_write_cost_micros" => "900000"
        }
      })

    RequestLogFact
    |> where([fact], fact.request_id == ^request.id)
    |> Repo.update_all(
      set: [
        latest_settlement_entry_id: authoritative_entry.id,
        latest_input_tokens: 11,
        latest_cached_input_tokens: 4,
        latest_cache_write_tokens: 3,
        latest_output_tokens: 7,
        latest_total_tokens: 18,
        latest_settled_cost_micros: 42
      ]
    )

    detail = Accounting.get_request_log_for_scope(owner_scope, request.id)

    assert detail.token_counts.cache_write_tokens == 3
    assert Decimal.equal?(detail.token_counts.cache_write_cost_usd, Decimal.new("0.250000"))
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
             with_dispatchable_request(request, fn request ->
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
             end)

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
    lifecycle_id = "11111111-1111-4111-8111-111111111111"

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
          upstream_status_code: 500 + attempt_number,
          response_metadata: %{
            "upstream_websocket_connection" => %{
              "lifecycle_id" => lifecycle_id,
              "generation" => attempt_number,
              "reused" => rem(attempt_number, 2) == 0,
              "reconnected" => attempt_number > 1
            }
          }
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

    assert Enum.all?(log.debug.attempts, fn attempt ->
             Map.keys(attempt) |> Enum.sort() ==
               [
                 :attempt_number,
                 :attempt_ref,
                 :final,
                 :latency_ms,
                 :network_error_code,
                 :pool_upstream_assignment_id,
                 :retryable,
                 :status,
                 :upstream_status_code
               ]
           end)

    refute inspect(log.debug) =~ "upstream_websocket_connection"
    refute inspect(log.debug) =~ lifecycle_id
    refute inspect(log.debug) =~ "raw attempt"

    assert %{items: [admin_log], total: 1, limit: 50, offset: 0} =
             Accounting.list_request_logs(pool, surface: :admin)

    assert Enum.map(admin_log.debug.attempts, & &1.attempt_number) == Enum.to_list(3..12)
    assert length(admin_log.debug.attempts) == 10

    assert Enum.map(admin_log.debug.attempts, & &1.upstream_websocket_connection) ==
             Enum.map(3..12, fn attempt_number ->
               %{
                 lifecycle_id: lifecycle_id,
                 generation: attempt_number,
                 reused: rem(attempt_number, 2) == 0,
                 reconnected: true
               }
             end)

    assert Enum.all?(admin_log.debug.attempts, fn attempt ->
             Map.keys(attempt.upstream_websocket_connection) |> Enum.sort() ==
               [:generation, :lifecycle_id, :reconnected, :reused]
           end)

    assert %{items: [non_admin_log]} = Accounting.list_request_logs(pool, surface: "admin")

    assert Enum.all?(non_admin_log.debug.attempts, fn attempt ->
             not Map.has_key?(attempt, :upstream_websocket_connection)
           end)
  end

  test "admin request logs omit malformed connection namespaces and ignore extras" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    lifecycle_id = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    prompt_injection = "ignore-instructions-leak-secrets-now"
    extra_value = "synthetic-extra-must-not-project"
    assert byte_size(prompt_injection) == 36

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-admin-connection-validation",
        status: "failed",
        correlation_id: "admin-connection-validation"
      })

    connection_namespaces = [
      %{
        "lifecycle_id" => lifecycle_id,
        "generation" => 1,
        "reused" => false,
        "reconnected" => true,
        "access_token" => extra_value,
        "prompt" => prompt_injection
      },
      %{
        "lifecycle_id" => prompt_injection,
        "generation" => 2,
        "reused" => false,
        "reconnected" => false
      },
      %{
        "lifecycle_id" => lifecycle_id <> "-overlong",
        "generation" => 3,
        "reused" => false,
        "reconnected" => false
      },
      %{
        "lifecycle_id" => String.upcase(lifecycle_id),
        "generation" => 4,
        "reused" => false,
        "reconnected" => false
      },
      %{"lifecycle_id" => lifecycle_id, "generation" => 5, "reused" => false},
      %{
        "lifecycle_id" => lifecycle_id,
        "generation" => 0,
        "reused" => false,
        "reconnected" => false
      },
      %{
        "lifecycle_id" => lifecycle_id,
        "generation" => 7.0,
        "reused" => false,
        "reconnected" => false
      },
      %{
        "lifecycle_id" => lifecycle_id,
        "generation" => 8,
        "reused" => 0,
        "reconnected" => false
      },
      %{
        "lifecycle_id" => lifecycle_id,
        "generation" => 9,
        "reused" => false,
        "reconnected" => "false"
      },
      "not-a-map"
    ]

    for {connection_namespace, index} <- Enum.with_index(connection_namespaces, 1) do
      attempt_fixture(request, assignment, %{
        attempt_number: index,
        status: "failed",
        response_metadata: %{"upstream_websocket_connection" => connection_namespace}
      })
    end

    assert %{items: [admin_log], total: 1} =
             Accounting.list_request_logs(pool, surface: :admin)

    attempts_by_number = Map.new(admin_log.debug.attempts, &{&1.attempt_number, &1})

    assert Map.fetch!(attempts_by_number, 1).upstream_websocket_connection == %{
             lifecycle_id: lifecycle_id,
             generation: 1,
             reused: false,
             reconnected: true
           }

    for attempt_number <- 2..10 do
      refute Map.has_key?(
               Map.fetch!(attempts_by_number, attempt_number),
               :upstream_websocket_connection
             )
    end

    projected = inspect(admin_log.debug.attempts)
    refute projected =~ prompt_injection
    refute projected =~ extra_value
    refute projected =~ "access_token"
  end

  test "admin request logs do not retain stale connection metadata across projections" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    initial_lifecycle_id = "55555555-5555-4555-8555-555555555555"
    replacement_lifecycle_id = "66666666-6666-4666-8666-666666666666"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-admin-connection-stale-state",
        status: "failed",
        correlation_id: "admin-connection-stale-state"
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: "failed",
        response_metadata: %{
          "upstream_websocket_connection" => %{
            "lifecycle_id" => initial_lifecycle_id,
            "generation" => 1,
            "reused" => false,
            "reconnected" => false
          }
        }
      })

    assert %{items: [initial_log]} = Accounting.list_request_logs(pool, surface: :admin)

    assert [initial_projection] = initial_log.debug.attempts
    assert initial_projection.upstream_websocket_connection.lifecycle_id == initial_lifecycle_id

    attempt
    |> Ecto.Changeset.change(%{
      response_metadata: %{
        "upstream_websocket_connection" => %{
          "lifecycle_id" => initial_lifecycle_id,
          "generation" => 0,
          "reused" => false,
          "reconnected" => false
        }
      }
    })
    |> Repo.update!()

    assert %{items: [malformed_log]} = Accounting.list_request_logs(pool, surface: :admin)
    assert [malformed_projection] = malformed_log.debug.attempts
    refute Map.has_key?(malformed_projection, :upstream_websocket_connection)

    attempt
    |> Ecto.Changeset.change(%{
      response_metadata: %{
        "upstream_websocket_connection" => %{
          "lifecycle_id" => replacement_lifecycle_id,
          "generation" => 2,
          "reused" => true,
          "reconnected" => true
        }
      }
    })
    |> Repo.update!()

    assert %{items: [replacement_log]} = Accounting.list_request_logs(pool, surface: :admin)
    assert [replacement_projection] = replacement_log.debug.attempts

    assert replacement_projection.upstream_websocket_connection == %{
             lifecycle_id: replacement_lifecycle_id,
             generation: 2,
             reused: true,
             reconnected: true
           }

    assert %{items: [default_log]} = Accounting.list_request_logs(pool)
    assert [default_projection] = default_log.debug.attempts
    refute Map.has_key?(default_projection, :upstream_websocket_connection)
    refute inspect(default_log) =~ replacement_lifecycle_id
  end

  test "request log detail projects only valid upstream error parameters from failed attempts" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    raw_message = "raw upstream error message must stay hidden"
    raw_value = "https://example.com/raw-error-value"
    raw_frame = ~s({"type":"error","message":"raw websocket frame"})
    raw_header = "Bearer hidden-header-value"
    raw_prompt = "raw upstream prompt must stay hidden"
    raw_body = "raw upstream response body must stay hidden"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-upstream-error-param",
        status: "failed",
        correlation_id: "upstream-error-param-detail"
      })

    valid_attempt =
      attempt_fixture(request, assignment, %{
        attempt_number: 1,
        status: "failed",
        response_metadata: %{
          "upstream_error_param" => "reasoning.summary",
          "raw_message" => raw_message,
          "value" => raw_value,
          "websocket_frame" => raw_frame,
          "headers" => %{"authorization" => raw_header},
          "prompt" => raw_prompt,
          "body" => raw_body
        }
      })

    invalid_attempt =
      attempt_fixture(request, assignment, %{
        attempt_number: 2,
        status: "failed",
        response_metadata: %{"upstream_error_param" => raw_value}
      })

    succeeded_attempt =
      attempt_fixture(request, assignment, %{
        attempt_number: 3,
        status: "succeeded",
        response_metadata: %{"upstream_error_param" => "reasoning.effort"}
      })

    {log, captured_logs} =
      with_log(fn ->
        assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
        log
      end)

    projected_valid_attempt =
      Enum.find(log.debug.attempts, &(&1.attempt_number == valid_attempt.attempt_number))

    assert projected_valid_attempt.pool_upstream_assignment_id == assignment.id
    assert projected_valid_attempt.upstream_error_param == "reasoning.summary"

    for attempt <- [invalid_attempt, succeeded_attempt] do
      projected_attempt =
        Enum.find(log.debug.attempts, &(&1.attempt_number == attempt.attempt_number))

      refute Map.has_key?(projected_attempt, :upstream_error_param)
    end

    for forbidden <- [raw_message, raw_value, raw_frame, raw_header, raw_prompt, raw_body] do
      refute inspect(log) =~ forbidden
      refute captured_logs =~ forbidden
    end
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
