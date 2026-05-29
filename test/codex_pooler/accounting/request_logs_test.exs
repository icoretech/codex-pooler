defmodule CodexPooler.Accounting.RequestLogsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.MCP.Redaction
  alias CodexPooler.Repo

  @pinned_continuation_operator_action "reauthenticate the pinned upstream account and restart the client without continuation anchors"

  test "request logs present latest settlement token counts and persisted costs" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-priced-projection",
        status: "succeeded",
        correlation_id: "req-priced-projection"
      })

    ledger_entry_fixture(request, %{
      input_tokens: 10,
      cached_input_tokens: 4,
      output_tokens: 6,
      reasoning_tokens: 2,
      total_tokens: 18,
      settled_cost_micros: 123_456,
      details: %{
        "pricing_status" => "priced",
        "settled_cost_micros" => "123456",
        "cached_input_cost_micros" => "4000"
      }
    })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.token_counts.input_tokens == 10
    assert log.token_counts.cached_input_tokens == 4
    assert Decimal.equal?(log.token_counts.cached_input_cost_usd, Decimal.new("0.004000"))
    assert log.token_counts.total_tokens == 18
    assert log.cost.status == "priced"
    assert Decimal.equal?(log.cost.usd, Decimal.new("0.123456"))
  end

  test "request log cost marks unpriced settlements explicitly" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-unpriced",
        status: "succeeded",
        correlation_id: "req-unpriced"
      })

    ledger_entry_fixture(request, %{
      details: %{"pricing_status" => "unpriced_missing_model", "settled_cost_micros" => nil},
      settled_cost_micros: 0
    })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.cost.status == "unpriced_missing_model"
    assert is_nil(log.cost.usd)
  end

  test "usage total_cost_usd sums persisted 0.100000 and 0.200000 to 0.300000 while ignoring unpriced rows" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    priced_request_1 =
      request_fixture(%{pool: pool, api_key: api_key}, %{correlation_id: "req-priced-1"})

    ledger_entry_fixture(priced_request_1, %{
      settled_cost_micros: 100_000,
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "100000"}
    })

    priced_request_2 =
      request_fixture(%{pool: pool, api_key: api_key}, %{correlation_id: "req-priced-2"})

    ledger_entry_fixture(priced_request_2, %{
      settled_cost_micros: 200_000,
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "200000"}
    })

    unpriced_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{correlation_id: "req-unpriced-2"})

    ledger_entry_fixture(unpriced_request, %{
      settled_cost_micros: 0,
      details: %{"pricing_status" => "unpriced_missing_model", "settled_cost_micros" => nil}
    })

    assert {:ok, usage} = Accounting.build_api_key_self_usage(pool, api_key)
    assert usage.total_cost_status == "priced"
    assert Decimal.equal?(usage.total_cost_usd, Decimal.new("0.300000"))
  end

  test "request log filters stay scoped to one Pool and metadata fields" do
    first_pool = pool_fixture(%{slug: "request-log-alpha", name: "Request Log Alpha"})
    second_pool = pool_fixture(%{slug: "request-log-beta", name: "Request Log Beta"})
    %{api_key: first_key} = active_api_key_fixture(first_pool, %{display_name: "Alpha key"})
    %{api_key: second_key} = active_api_key_fixture(second_pool, %{display_name: "Beta key"})

    %{identity: first_identity, assignment: first_assignment} =
      upstream_assignment_fixture(first_pool, %{
        account_label: "Alpha upstream",
        assignment_label: "Alpha assignment"
      })

    %{identity: second_identity, assignment: second_assignment} =
      upstream_assignment_fixture(second_pool, %{
        account_label: "Beta upstream",
        assignment_label: "Beta assignment"
      })

    first_request =
      request_fixture(%{pool: first_pool, api_key: first_key}, %{
        requested_model: "gpt-alpha",
        status: "succeeded",
        correlation_id: "req-alpha",
        admitted_at: DateTime.add(DateTime.utc_now(), -120, :second)
      })

    first_attempt =
      first_request
      |> attempt_fixture(first_assignment)
      |> Ecto.Changeset.change(%{latency_ms: 123})
      |> Repo.update!()

    ledger_entry_fixture(first_request, %{
      attempt_id: first_attempt.id,
      pool_upstream_assignment_id: first_assignment.id,
      upstream_identity_id: first_identity.id,
      total_tokens: 14
    })

    second_request =
      request_fixture(%{pool: second_pool, api_key: second_key}, %{
        requested_model: "gpt-beta",
        status: "failed",
        correlation_id: "req-beta",
        request_metadata: %{
          "client_request_id" => "client-beta-request",
          "request_id" => "phoenix-beta-request"
        }
      })
      |> Ecto.Changeset.change(%{last_error_code: "quota_account_primary_unknown"})
      |> Repo.update!()

    second_attempt =
      second_request
      |> attempt_fixture(second_assignment)
      |> Ecto.Changeset.change(%{latency_ms: 456, network_error_code: "upstream_rate_limited"})
      |> Repo.update!()

    ledger_entry_fixture(second_request, %{
      attempt_id: second_attempt.id,
      pool_upstream_assignment_id: second_assignment.id,
      upstream_identity_id: second_identity.id,
      input_tokens: 9,
      output_tokens: 2,
      total_tokens: 11
    })

    assert %{items: [alpha], total: 1} =
             Accounting.list_request_logs(first_pool,
               filters: [status: "succeeded", model: "alpha"]
             )

    assert alpha.id == first_request.id
    assert alpha.latency_ms == 123
    assert alpha.token_counts.total_tokens == 14

    assert %{items: [beta], total: 1} =
             Accounting.list_request_logs(second_pool,
               filters: [
                 status: "failed",
                 upstream_identity_id: second_identity.id,
                 request_id: "req-beta"
               ]
             )

    assert beta.id == second_request.id
    assert beta.pool_name == "Request Log Beta"
    assert beta.denial_reason == "quota_account_primary_unknown"
    assert beta.latency_ms == 456
    assert beta.token_counts.input_tokens == 9

    assert %{items: [metadata_match], total: 1} =
             Accounting.list_request_logs(second_pool, filters: [request_id: "phoenix-beta"])

    assert metadata_match.id == second_request.id

    assert %{items: [client_metadata_match], total: 1} =
             Accounting.list_request_logs(second_pool, filters: [request_id: "client-beta"])

    assert client_metadata_match.id == second_request.id

    assert %{items: [], total: 0} =
             Accounting.list_request_logs(first_pool, filters: [status: "failed"])
  end

  test "exact scoped request log lookup is not affected by fuzzy correlation matches" do
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, [])

    visible_pool = pool_fixture(%{slug: "request-log-exact-visible", name: "Exact Visible"})
    hidden_pool = pool_fixture(%{slug: "request-log-exact-hidden", name: "Exact Hidden"})
    %{api_key: visible_key} = active_api_key_fixture(visible_pool)
    %{api_key: hidden_key} = active_api_key_fixture(hidden_pool)
    hidden_pool = hidden_pool |> Ecto.Changeset.change(status: "archived") |> Repo.update!()

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "pool_ids" => [visible_pool.id]
      })

    scope = Scope.for_user(admin)
    older_time = ~U[2026-05-26 00:00:00.000000Z]
    newer_time = DateTime.add(older_time, 60, :second)

    hidden_request =
      request_fixture(%{pool: hidden_pool, api_key: hidden_key}, %{
        requested_model: "gpt-exact-hidden",
        correlation_id: "hidden-exact-request"
      })

    target_request =
      request_fixture(%{pool: visible_pool, api_key: visible_key}, %{
        requested_model: "gpt-exact-target",
        correlation_id: "target-exact-request"
      })
      |> Ecto.Changeset.change(admitted_at: older_time)
      |> Repo.update!()

    distractor_request =
      request_fixture(%{pool: visible_pool, api_key: visible_key}, %{
        requested_model: "gpt-exact-distractor",
        correlation_id: "newer-visible-correlation-containing-#{target_request.id}"
      })
      |> Ecto.Changeset.change(admitted_at: newer_time)
      |> Repo.update!()

    assert %{items: [fuzzy_match]} =
             Accounting.list_request_logs_for_scope(scope,
               limit: 1,
               filters: [request_id: target_request.id]
             )

    assert fuzzy_match.id == distractor_request.id

    assert exact_match = Accounting.get_request_log_for_scope(scope, target_request.id)
    assert exact_match.id == target_request.id
    assert exact_match.requested_model == "gpt-exact-target"
    assert is_nil(Accounting.get_request_log_for_scope(scope, hidden_request.id))

    assert owner_hidden_match =
             Accounting.get_request_log_for_scope(owner_scope, hidden_request.id)

    assert owner_hidden_match.id == hidden_request.id
  end

  test "policy denial request logs keep sanitized reason metadata only" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    synthetic_token = "sk-" <> "cxp" <> "-redacted-test"

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-policy-log",
        upstream_model_id: "provider-gpt-policy-log",
        pricing_ref: "provider-gpt-policy-log"
      })

    assert {:ok, %{request: request}} =
             Accounting.record_denied_request(%{pool: pool, api_key: api_key}, model, %{
               endpoint: "/backend-api/codex/responses",
               transport: "http_json",
               correlation_id: "policy-denial-log",
               requested_model: "gpt-policy-log",
               response_status_code: 403,
               last_error_code: "model_not_allowed",
               request_metadata: %{
                 "policy_denial" => %{
                   "code" => "model_not_allowed",
                   "message" => "api key is not allowed to use this model"
                 },
                 "authorization" => "Bearer " <> synthetic_token,
                 "body" => %{"input" => "raw denied prompt"}
               }
             })

    assert request.status == "rejected"

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.denial_reason == "model_not_allowed"
    assert log.status == "rejected"
    assert log.metadata["policy_denial"]["code"] == "model_not_allowed"
    assert log.metadata["authorization"] == "[REDACTED]"
    assert log.metadata["body"] == "[REDACTED]"
    refute inspect(log) =~ "raw denied prompt"
    refute inspect(log) =~ synthetic_token
  end

  test "gateway denial request logs expose pinned reauth metadata-only summaries" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Pinned upstream",
        assignment_label: "Pinned assignment"
      })

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-pinned-denial-log",
        upstream_model_id: "provider-gpt-pinned-denial-log",
        pricing_ref: "provider-gpt-pinned-denial-log"
      })

    raw_anchor = "resp_raw_anchor_#{System.unique_integer([:positive])}"
    raw_nested_map_anchor = "resp_nested_map_anchor_#{System.unique_integer([:positive])}"
    raw_nested_list_anchor = "resp_nested_list_anchor_#{System.unique_integer([:positive])}"
    raw_prompt = Redaction.forbidden_sentinel!(:prompt)
    raw_idempotency_key = Redaction.forbidden_sentinel!(:raw_idempotency_key)
    request_body = Redaction.forbidden_sentinel!(:request_body)
    response_body = Redaction.forbidden_sentinel!(:response_body)
    access_token = Redaction.forbidden_sentinel!(:access_token)
    refresh_token = Redaction.forbidden_sentinel!(:refresh_token)
    cookie = Redaction.forbidden_sentinel!(:cookies)
    auth_json = Redaction.forbidden_sentinel!(:upstream_auth_json)
    provider_payload = Redaction.forbidden_sentinel!(:provider_payload)
    websocket_frame = Redaction.forbidden_sentinel!(:websocket_frame)

    opts =
      RequestOptions.build(
        [
          transport: "http_json",
          requested_model: "gpt-pinned-denial-log",
          previous_response_id: raw_anchor,
          idempotency_key: raw_idempotency_key,
          request_id: "safe-server-correlation"
        ],
        "/backend-api/codex/responses",
        %{
          "model" => "gpt-pinned-denial-log",
          "previous_response_id" => raw_anchor,
          "input" => raw_prompt
        }
      )

    reason = %{
      code: "pinned_continuation_reauth_required",
      status: 503,
      message: "restart with full visible context",
      param: "model",
      continuity_denial:
        continuity_denial_metadata(assignment, identity)
        |> Map.merge(%{
          "previous_response_id" => raw_anchor,
          "previous-response-id" => %{
            "id" => raw_nested_map_anchor,
            "preview" => raw_nested_map_anchor
          },
          "previous response id" => [%{"id" => raw_nested_list_anchor}],
          "request_body" => request_body,
          "response_body" => response_body,
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "cookie" => cookie,
          "auth_json" => auth_json,
          "provider_payload" => provider_payload,
          "websocket_frame" => websocket_frame
        })
    }

    assert {:error, ^reason} =
             Denials.log_gateway(%Denials.Context{
               auth: %{pool: pool, api_key: api_key, key_prefix: api_key.key_prefix},
               model: model,
               reason: reason,
               endpoint: "/backend-api/codex/responses",
               payload: %{
                 "model" => "gpt-pinned-denial-log",
                 "previous_response_id" => raw_anchor,
                 "input" => raw_prompt
               },
               opts: opts
             })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.status == "rejected"
    assert log.denial_reason == "pinned_continuation_reauth_required"
    assert log.pool_upstream_assignment_id == nil
    assert log.upstream_identity_id == nil

    assert log.metadata["gateway_denial"] == %{
             "code" => "pinned_continuation_reauth_required",
             "message" => "restart with full visible context",
             "param" => "model"
           }

    assert log.metadata["continuity_denial"] == %{
             "denial_family" => "pinned_continuation_reauth",
             "continuity_family" => "pinned_codex_session",
             "upstream_lifecycle_family" => "reauth_required",
             "token_refresh_reason_code_preview" => "refresh_token_revoked",
             "pool_upstream_assignment_id" => assignment.id,
             "upstream_identity_id" => identity.id,
             "operator_action" => @pinned_continuation_operator_action,
             "previous_response_id" => "[REDACTED]",
             "previous-response-id" => "[REDACTED]",
             "previous response id" => "[REDACTED]",
             "request_body" => "[REDACTED]",
             "response_body" => "[REDACTED]",
             "access_token" => "[REDACTED]",
             "refresh_token" => "[REDACTED]",
             "cookie" => "[REDACTED]",
             "auth_json" => "[REDACTED]",
             "provider_payload" => "[REDACTED]",
             "websocket_frame" => "[REDACTED]"
           }

    assert Enum.any?(log.errors, fn error ->
             error.source == "metadata" and
               error.kind == "continuity_denial" and
               error.code == "pinned_continuation_reauth" and
               error.denial_family == "pinned_continuation_reauth" and
               error.continuity_family == "pinned_codex_session" and
               error.upstream_lifecycle_family == "reauth_required" and
               error.token_refresh_reason_code_preview == "refresh_token_revoked" and
               error.pool_upstream_assignment_id == assignment.id and
               error.upstream_identity_id == identity.id and
               error.operator_action == @pinned_continuation_operator_action
           end)

    inspected = inspect(log)
    refute inspected =~ raw_anchor
    refute inspected =~ raw_nested_map_anchor
    refute inspected =~ raw_nested_list_anchor
    refute inspected =~ raw_prompt
    refute inspected =~ raw_idempotency_key
    refute inspected =~ request_body
    refute inspected =~ response_body
    refute inspected =~ access_token
    refute inspected =~ refresh_token
    refute inspected =~ cookie
    refute inspected =~ auth_json
    refute inspected =~ provider_payload
    refute inspected =~ websocket_frame
  end

  test "scoped request-log visibility keeps pinned denial rows inside assigned pools" do
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, [])

    visible_pool = pool_fixture(%{slug: "request-log-pinned-visible", name: "Pinned Visible"})
    hidden_pool = pool_fixture(%{slug: "request-log-pinned-hidden", name: "Pinned Hidden"})
    %{api_key: visible_key} = active_api_key_fixture(visible_pool)
    %{api_key: hidden_key} = active_api_key_fixture(hidden_pool)

    %{identity: visible_identity, assignment: visible_assignment} =
      upstream_assignment_fixture(visible_pool)

    %{identity: hidden_identity, assignment: hidden_assignment} =
      upstream_assignment_fixture(hidden_pool)

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "pool_ids" => [visible_pool.id]
      })

    admin_scope = Scope.for_user(admin)

    visible_request =
      pinned_denial_request_fixture(
        visible_pool,
        visible_key,
        visible_assignment,
        visible_identity
      )

    hidden_request =
      pinned_denial_request_fixture(hidden_pool, hidden_key, hidden_assignment, hidden_identity)

    assert %{items: owner_logs, total: 2} = Accounting.list_request_logs_for_scope(owner_scope)

    assert MapSet.new(Enum.map(owner_logs, & &1.id)) ==
             MapSet.new([visible_request.id, hidden_request.id])

    assert %{items: [admin_log], total: 1} = Accounting.list_request_logs_for_scope(admin_scope)
    assert admin_log.id == visible_request.id

    assert admin_log.metadata["continuity_denial"]["pool_upstream_assignment_id"] ==
             visible_assignment.id

    assert admin_log.metadata["continuity_denial"]["upstream_identity_id"] == visible_identity.id
    assert is_nil(Accounting.get_request_log_for_scope(admin_scope, hidden_request.id))

    assert hidden_owner_log = Accounting.get_request_log_for_scope(owner_scope, hidden_request.id)

    assert hidden_owner_log.metadata["continuity_denial"]["pool_upstream_assignment_id"] ==
             hidden_assignment.id

    assert hidden_owner_log.metadata["continuity_denial"]["upstream_identity_id"] ==
             hidden_identity.id
  end

  test "websocket request logs expose session metadata without payload capture" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    session_id = Ecto.UUID.generate()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-websocket-log",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        correlation_id: "ws-request-log",
        request_metadata: %{
          "codex_session_id" => session_id,
          "codex_session_key" => "stable-log-session",
          "body" => %{"input" => "raw websocket prompt"}
        }
      })
      |> Ecto.Changeset.change(%{last_error_code: "client_disconnected"})
      |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.transport == "websocket"
    assert log.metadata["codex_session_id"] == session_id
    assert log.metadata["codex_session_key"] == "stable-log-session"
    assert log.metadata["body"] == "[REDACTED]"
    refute inspect(log) =~ "raw websocket prompt"
  end

  test "request log status stays authoritative when the latest attempt reports owner_drained" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    sentinel = "request-log-owner-drained-secret-do-not-render"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-owner-drained-mixed-state",
        status: "in_progress",
        correlation_id: "req-owner-drained-in-progress",
        request_metadata: %{
          "body" => %{"input" => "raw websocket prompt #{sentinel}"},
          "authorization" => "Bearer #{sentinel}"
        }
      })

    request
    |> attempt_fixture(assignment, %{status: "failed"})
    |> Ecto.Changeset.change(%{
      network_error_code: "owner_drained",
      response_metadata: %{
        "body" => %{"input" => "raw websocket frame #{sentinel}"},
        "authorization" => "Bearer #{sentinel}"
      }
    })
    |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.status == "in_progress"
    assert Enum.any?(log.errors, &(&1.source == "attempt" and &1.code == "owner_drained"))
    refute Enum.any?(log.errors, &(&1.code == sentinel))
    assert log.metadata["body"] == "[REDACTED]"
    assert log.metadata["authorization"] == "[REDACTED]"
    refute inspect(log) =~ sentinel
  end

  test "failed request log keeps failed status when the latest attempt reports owner_drained" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    sentinel = "request-log-owner-drained-terminal-secret-do-not-render"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-owner-drained-terminal-state",
        status: "failed",
        correlation_id: "req-owner-drained-failed",
        request_metadata: %{
          "body" => %{"input" => "terminal raw prompt #{sentinel}"},
          "authorization" => "Bearer #{sentinel}"
        }
      })

    request
    |> attempt_fixture(assignment, %{status: "failed"})
    |> Ecto.Changeset.change(%{
      network_error_code: "owner_drained",
      response_metadata: %{
        "body" => %{"input" => "terminal raw frame #{sentinel}"},
        "authorization" => "Bearer #{sentinel}"
      }
    })
    |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.status == "failed"
    assert Enum.any?(log.errors, &(&1.source == "attempt" and &1.code == "owner_drained"))
    refute Enum.any?(log.errors, &(&1.code == sentinel))
    assert log.metadata["body"] == "[REDACTED]"
    assert log.metadata["authorization"] == "[REDACTED]"
    refute inspect(log) =~ sentinel
  end

  test "request logs list legacy rows with nil snapshot fields" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-legacy-snapshot",
        correlation_id: "legacy-snapshot-nil"
      })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
  end

  test "request log attempt aggregation uses bounded queries for paged rows" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    for index <- 1..3 do
      request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          requested_model: "gpt-query-bound-#{index}",
          status: "failed",
          correlation_id: "query-bound-#{index}"
        })
        |> Ecto.Changeset.change(%{last_error_code: "request_failed_#{index}"})
        |> Repo.update!()

      request
      |> attempt_fixture(assignment, %{attempt_number: 1})
      |> Ecto.Changeset.change(%{
        status: "failed",
        network_error_code: "upstream_failed_#{index}",
        response_metadata: %{"message" => "safe failure #{index}"}
      })
      |> Repo.update!()
    end

    counter = :counters.new(1, [])
    handler_id = {:request_logs_query_counter, self(), System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        unless String.starts_with?(metadata.query, ["begin", "commit", "rollback"]) do
          :counters.add(counter, 1, 1)
        end
      end,
      nil
    )

    try do
      assert %{items: logs, total: 3} = Accounting.list_request_logs(pool)
      assert Enum.all?(logs, fn log -> Enum.any?(log.errors, &(&1.source == "attempt")) end)
      assert :counters.get(counter, 1) <= 3
    after
      :telemetry.detach(handler_id)
    end
  end

  test "request log debug projection reports terminal linked failed turn" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-debug-terminal",
        status: "failed",
        correlation_id: "debug-terminal",
        response_status_code: 499,
        request_metadata: %{
          "codex_session_id" => "session-example-1",
          "codex_session_key" => "session-key-example-1"
        }
      })
      |> Ecto.Changeset.change(last_error_code: "client_disconnected")
      |> Repo.update!()

    attempt =
      request
      |> attempt_fixture(assignment, %{
        status: "failed",
        retryable: true,
        upstream_status_code: 499
      })
      |> Ecto.Changeset.change(%{
        latency_ms: 321,
        network_error_code: "owner_drained",
        error_message: "raw attempt error must not enter debug"
      })
      |> Repo.update!()

    turn =
      debug_turn_fixture(pool, api_key, assignment, request, %{
        status: "failed",
        error_code: "turn_owner_drained",
        final_attempt_id: attempt.id
      })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)

    assert log.debug.continuity == %{
             status: "available",
             session_ref: stable_ref(:session, "session-example-1"),
             session_source: "continuity",
             turn_ref: stable_ref(:turn, turn.id),
             turn_status: "failed",
             turn_status_source: "turn_state",
             has_open_turn: false,
             terminal_state: "terminal",
             terminal_state_source: "turn_state"
           }

    assert log.debug.failure == %{error_code: "turn_owner_drained", error_source: "turn_error"}

    assert log.debug.attempt == %{
             latest_attempt_number: 1,
             latest_attempt_status: "failed",
             latest_attempt_retryable: true,
             latest_upstream_status_code: 499,
             attempt_count: 1
           }

    assert log.debug.terminal_state.state == "terminal"
    assert log.debug.terminal_state.mismatch == false

    assert log.debug.terminal_state.sources == [
             %{source: "request_state", status: "failed", error_code: "client_disconnected"},
             %{source: "turn_state", status: "failed", error_code: "turn_owner_drained"},
             %{source: "attempt_state", status: "failed", error_code: "owner_drained"}
           ]

    assert log.debug.turn.turn_ref == stable_ref(:turn, turn.id)
    assert log.debug.turn.final_attempt_ref == stable_attempt_ref(request.id, 1)
    assert log.debug.turn.status == "failed"
    assert log.debug.turn.error_code == "turn_owner_drained"
    assert log.debug.turn.inserted_at == DateTime.to_iso8601(turn.created_at)
    assert log.debug.turn.updated_at == DateTime.to_iso8601(turn.updated_at)
    assert log.debug.turn.completed_at == DateTime.to_iso8601(turn.completed_at)

    assert [attempt_debug] = log.debug.attempts

    assert attempt_debug == %{
             attempt_ref: stable_attempt_ref(request.id, 1),
             attempt_number: 1,
             status: "failed",
             retryable: true,
             upstream_status_code: 499,
             network_error_code: "owner_drained",
             latency_ms: 321,
             final: true
           }

    refute inspect(log.debug) =~ "session-example-1"
    refute inspect(log.debug) =~ "session-key-example-1"
    refute inspect(log.debug) =~ "raw attempt error"
  end

  test "request log debug projection reports failed request with linked open turn as mismatch" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-debug-mismatch",
        status: "failed",
        correlation_id: "debug-mismatch",
        request_metadata: %{"codex_session_id" => "session-example-2"}
      })
      |> Ecto.Changeset.change(last_error_code: "owner_unavailable")
      |> Repo.update!()

    request
    |> attempt_fixture(assignment, %{status: "failed"})
    |> Ecto.Changeset.change(network_error_code: "upstream_timeout")
    |> Repo.update!()

    turn =
      debug_turn_fixture(pool, api_key, assignment, request, %{
        status: "in_progress",
        completed_at: nil
      })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)

    assert log.debug.continuity.status == "mismatch"
    assert log.debug.continuity.session_ref == stable_ref(:session, "session-example-2")
    assert log.debug.continuity.turn_ref == stable_ref(:turn, turn.id)
    assert log.debug.continuity.turn_status == "in_progress"
    assert log.debug.continuity.has_open_turn == true
    assert log.debug.continuity.terminal_state == "mismatch"
    assert log.debug.continuity.terminal_state_source == "turn_state"
    assert log.debug.failure == %{error_code: "owner_unavailable", error_source: "request_error"}

    assert log.debug.terminal_state == %{
             state: "mismatch",
             mismatch: true,
             sources: [
               %{source: "request_state", status: "failed", error_code: "owner_unavailable"},
               %{source: "turn_state", status: "in_progress", error_code: nil},
               %{source: "attempt_state", status: "failed", error_code: "upstream_timeout"}
             ]
           }
  end

  test "request log debug projection reports failed no-turn request from request state" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-debug-no-turn",
        status: "failed",
        correlation_id: "debug-no-turn",
        request_metadata: %{}
      })
      |> Ecto.Changeset.change(last_error_code: "request_failed")
      |> Repo.update!()

    request
    |> attempt_fixture(assignment, %{
      status: "failed",
      retryable: false,
      upstream_status_code: 502
    })
    |> Ecto.Changeset.change(network_error_code: "upstream_status", latency_ms: 111)
    |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)

    assert log.debug.continuity == %{
             status: "not_applicable",
             session_ref: nil,
             session_source: nil,
             turn_ref: nil,
             turn_status: nil,
             turn_status_source: nil,
             has_open_turn: nil,
             terminal_state: "terminal",
             terminal_state_source: "request_state"
           }

    assert log.debug.failure == %{error_code: "request_failed", error_source: "request_error"}
    assert log.debug.attempt.attempt_count == 1
    assert log.debug.attempt.latest_attempt_number == 1

    assert log.debug.attempts == [
             %{
               attempt_ref: stable_attempt_ref(request.id, 1),
               attempt_number: 1,
               status: "failed",
               retryable: false,
               upstream_status_code: 502,
               network_error_code: "upstream_status",
               latency_ms: 111,
               final: false
             }
           ]
  end

  test "request log debug projection reports no-continuity rejected rows as not applicable" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-debug-rejected",
        status: "rejected",
        correlation_id: "debug-rejected",
        response_status_code: 403,
        request_metadata: %{}
      })
      |> Ecto.Changeset.change(last_error_code: "model_not_allowed")
      |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id

    assert log.debug.continuity == %{
             status: "not_applicable",
             session_ref: nil,
             session_source: nil,
             turn_ref: nil,
             turn_status: nil,
             turn_status_source: nil,
             has_open_turn: nil,
             terminal_state: "not_applicable",
             terminal_state_source: nil
           }

    assert log.debug.failure == %{error_code: "model_not_allowed", error_source: "request_error"}
    assert log.debug.attempt.attempt_count == 0
    assert log.debug.attempts == []
  end

  test "request log debug projection reports malformed legacy continuity as unknown" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-debug-legacy",
        status: "failed",
        correlation_id: "debug-legacy",
        request_metadata: %{"codex_session_id" => %{"legacy" => "bad-shape"}}
      })
      |> Ecto.Changeset.change(last_error_code: "legacy_failure")
      |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.debug.continuity.status == "unknown"
    assert log.debug.continuity.session_ref == nil
    assert log.debug.continuity.turn_ref == nil
    assert log.debug.continuity.terminal_state == "unknown"
    assert log.debug.failure == %{error_code: "legacy_failure", error_source: "request_error"}
  end

  test "request log model listing returns distinct models for the full pool history" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{pool: other_pool, api_key: other_api_key} = active_api_key_fixture()

    for {model, index} <- [{"gpt-beta", 1}, {"gpt-alpha", 2}, {"gpt-beta", 3}] do
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: model,
        correlation_id: "model-list-#{index}"
      })
    end

    request_fixture(%{pool: pool, api_key: api_key}, %{
      requested_model: "/backend-api/codex/models",
      endpoint: "/backend-api/codex/models",
      correlation_id: "model-list-metadata"
    })

    request_fixture(%{pool: other_pool, api_key: other_api_key}, %{
      requested_model: "gpt-other-pool",
      correlation_id: "model-list-other"
    })

    assert Accounting.list_request_log_models(pool) == ["gpt-alpha", "gpt-beta"]
  end

  test "request rows persist non-nil snapshot fields" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    request =
      %Request{
        pool_id: pool.id,
        api_key_id: api_key.id,
        requested_model: "gpt-snapshot-contract",
        endpoint: "/backend-api/codex/responses",
        transport: "http_json",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "snapshot-fields-persist",
        request_metadata: %{},
        admitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        response_status_code: 200,
        retry_count: 0,
        upstream_account_label: "operator@example.com",
        upstream_account_email: "operator@example.com",
        upstream_account_plan_label: "pro",
        upstream_account_plan_family: "paid",
        reasoning_effort: "medium",
        service_tier: "priority",
        requested_service_tier: "auto",
        actual_service_tier: "priority"
      }
      |> Repo.insert!()

    persisted = Repo.get!(Request, request.id)
    assert persisted.upstream_account_label == "operator@example.com"
    assert persisted.upstream_account_email == "operator@example.com"
    assert persisted.upstream_account_plan_label == "pro"
    assert persisted.upstream_account_plan_family == "paid"
    assert persisted.reasoning_effort == "medium"
    assert persisted.service_tier == "priority"
    assert persisted.requested_service_tier == "auto"
    assert persisted.actual_service_tier == "priority"
  end

  test "request logs expose sanitized bridge routing metadata" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-routing-log",
        correlation_id: "routing-log",
        request_metadata: %{
          "routing" => %{
            "strategy" => "bridge_ring",
            "selected_bridge_candidate_id" => Ecto.UUID.generate(),
            "affinity_status" => "miss",
            "demotion_reason" => "upstream_5xx",
            "body" => %{"input" => "raw routing prompt"}
          }
        }
      })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.metadata["routing"]["strategy"] == "bridge_ring"
    assert log.metadata["routing"]["affinity_status"] == "miss"
    assert log.metadata["routing"]["demotion_reason"] == "upstream_5xx"
    assert log.metadata["routing"]["body"] == "[REDACTED]"
    refute inspect(log) =~ "raw routing prompt"
  end

  @tag :feature_control_plane_redaction
  test "control-plane request logs persist metadata-only route details and redact request and attempt secrets" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Control plane upstream",
        account_email: "control-plane-upstream@example.com",
        assignment_label: "Control plane assignment"
      })

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "/backend-api/codex/safety/arc",
        endpoint: "/backend-api/codex/safety/arc",
        transport: "http_json",
        status: "failed",
        correlation_id: "control-plane-request-log",
        response_status_code: 502,
        upstream_account_label: identity.account_label,
        upstream_account_email: identity.account_email,
        upstream_account_plan_label: identity.plan_label,
        upstream_account_plan_family: identity.plan_family,
        request_metadata: %{
          "endpoint" => "/backend-api/codex/safety/arc",
          "routing" => %{
            "route_class" => "proxy_control",
            "selected_assignment_id" => assignment.id,
            "upstream_identity_id" => identity.id
          },
          "request" => %{
            "body_bytes" => 187,
            "content_type" => "application/json",
            "body" => "ship sanitized control route tests"
          },
          "control_plane" => %{
            "authorization" => "Bearer client-secret",
            "cookie" => "session=secret",
            "trace" => "trace-secret-payload",
            "analytics" => "analytics-secret-payload",
            "arc" => "arc-secret-payload",
            "idempotency_key" => "raw-idempotency-key-secret"
          },
          "body" => %{"messages" => ["ship sanitized control route tests"]}
        }
      })
      |> Ecto.Changeset.change(%{last_error_code: "upstream_status"})
      |> Repo.update!()

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Accounting.record_retryable_attempt_failure(%{
        attempt_status: "failed",
        response_status_code: 502,
        last_error_code: "upstream_status",
        attempt_metadata: %{
          "message" => "Bearer client-secret",
          "error_body" => "analytics-secret-payload",
          "cookie" => "session=secret",
          "sdp" => "v=0",
          "idempotency_key" => "raw-idempotency-key-secret"
        }
      })
      |> then(fn {:ok, attempt} -> attempt end)

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.endpoint == "/backend-api/codex/safety/arc"
    assert log.response_status_code == 502
    assert log.assignment_label == "Control plane assignment"
    assert log.upstream_identity_label == "Control plane upstream"
    assert log.metadata["endpoint"] == "/backend-api/codex/safety/arc"
    assert log.metadata["routing"]["route_class"] == "proxy_control"
    assert log.metadata["routing"]["selected_assignment_id"] == assignment.id
    assert log.metadata["routing"]["upstream_identity_id"] == identity.id
    assert log.metadata["request"]["body_bytes"] == 187
    assert log.metadata["request"]["content_type"] == "application/json"
    assert log.metadata["request"]["body"] in [nil, "[REDACTED]"]
    assert log.metadata["control_plane"] in [nil, %{}]
    assert log.metadata["body"] in [nil, "[REDACTED]"]
    assert Enum.any?(log.errors, &(&1.source == "attempt"))

    refute inspect(log) =~ "ship sanitized control route tests"
    refute inspect(log) =~ "Bearer client-secret"
    refute inspect(log) =~ "session=secret"
    refute inspect(log) =~ "raw-idempotency-key-secret"
    refute inspect(log) =~ "v=0"
    refute inspect(log.errors) =~ "Bearer client-secret"
    refute inspect(log.errors) =~ "analytics-secret-payload"
    refute inspect(log.errors) =~ "session=secret"
    refute inspect(log.errors) =~ "raw-idempotency-key-secret"
    refute inspect(log.errors) =~ "v=0"

    assert attempt.id
  end

  @tag :feature_control_plane_redaction
  test "analytics-disabled control-plane request logs stay local metadata-only with a 204 and no attempts" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    assert {:ok, %{request: request}} =
             Accounting.record_metadata_request(%{pool: pool, api_key: api_key}, %{
               endpoint: "/backend-api/codex/analytics-events/events",
               transport: "http_json",
               status: "succeeded",
               correlation_id: "control-plane-analytics-disabled",
               response_status_code: 204,
               request_metadata: %{
                 "endpoint" => "/backend-api/codex/analytics-events/events",
                 "routing" => %{"route_class" => "proxy_control"},
                 "request" => %{
                   "body_bytes" => 99,
                   "content_type" => "application/json",
                   "body" => "ship sanitized control route tests"
                 },
                 "control_plane" => %{
                   "analytics_forwarding" => "disabled",
                   "authorization" => "Bearer client-secret",
                   "cookie" => "session=secret",
                   "trace" => "trace-secret-payload",
                   "analytics" => "analytics-secret-payload",
                   "idempotency_key" => "raw-idempotency-key-secret"
                 },
                 "body" => ["ship sanitized control route tests"]
               }
             })

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id == ^request.id),
             :count
           ) == 0

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.status == "succeeded"
    assert log.response_status_code == 204
    assert log.endpoint == "/backend-api/codex/analytics-events/events"
    assert log.metadata["routing"]["route_class"] == "proxy_control"
    assert log.metadata["request"]["body_bytes"] == 99
    assert log.metadata["request"]["content_type"] == "application/json"
    assert log.metadata["request"]["body"] in [nil, "[REDACTED]"]
    assert log.metadata["control_plane"] in [nil, %{}]
    assert log.metadata["body"] in [nil, ["[REDACTED]"]]

    refute inspect(log) =~ "ship sanitized control route tests"
    refute inspect(log) =~ "Bearer client-secret"
    refute inspect(log) =~ "session=secret"
    refute inspect(log) =~ "raw-idempotency-key-secret"
    refute inspect(log) =~ "v=0"
  end

  @tag :media_redaction
  test "media request logs redact prompts filenames images and transcripts" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    prompt = "raw media " <> "prompt"
    filename = "private-" <> "recording.wav"
    transcript = "raw transcript " <> "text"
    image_payload = "raw generated " <> "image payload"
    audio_payload = "raw audio " <> "bytes"

    request_fixture(%{pool: pool, api_key: api_key}, %{
      requested_model: "gpt-media-log",
      endpoint: "/backend-api/transcribe",
      transport: "http_multipart",
      status: "succeeded",
      correlation_id: "media-redaction-log",
      request_metadata: %{
        "endpoint" => "/backend-api/transcribe",
        "request_bytes" => 123,
        "upload_bytes" => 123,
        "request_content_type" => "multipart/form-data",
        "prompt" => prompt,
        "filename" => filename,
        "transcription_text" => transcript,
        "generated_image" => image_payload,
        "body" => %{"file" => audio_payload}
      }
    })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.endpoint == "/backend-api/transcribe"
    assert log.transport == "http_multipart"
    assert log.metadata["endpoint"] == "/backend-api/transcribe"
    assert log.metadata["request_bytes"] == 123
    assert log.metadata["upload_bytes"] == 123
    assert log.metadata["request_content_type"] == "multipart/form-data"
    assert log.metadata["prompt"] == "[REDACTED]"
    assert log.metadata["filename"] == "[REDACTED]"
    assert log.metadata["transcription_text"] == "[REDACTED]"
    assert log.metadata["generated_image"] == "[REDACTED]"
    assert log.metadata["body"] == "[REDACTED]"
    refute inspect(log) =~ prompt
    refute inspect(log) =~ filename
    refute inspect(log) =~ transcript
    refute inspect(log) =~ image_payload
    refute inspect(log) =~ audio_payload
  end

  test "metadata request rows do not persist raw idempotency keys" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    raw_idempotency_key =
      "raw-idempotency-key-secret-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, %{request: request}} =
             Accounting.record_metadata_request(%{pool: pool, api_key: api_key}, %{
               endpoint: "/api/codex/usage",
               transport: "http_json",
               correlation_id: "metadata-idempotency-boundary",
               idempotency_key: raw_idempotency_key,
               response_status_code: 200,
               request_metadata: %{
                 "operation" => "usage",
                 "idempotency_key" => raw_idempotency_key
               }
             })

    persisted = Repo.get!(Request, request.id)
    assert is_nil(persisted.idempotency_key)
    assert persisted.request_metadata["idempotency_key"] == "[REDACTED]"
    refute inspect(persisted) =~ raw_idempotency_key

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    refute inspect(log) =~ raw_idempotency_key
  end

  test "denied request rows do not persist raw idempotency keys" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    raw_idempotency_key =
      "raw-denied-idempotency-key-secret-" <>
        Integer.to_string(System.unique_integer([:positive]))

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-denied-idempotency",
        upstream_model_id: "provider-gpt-denied-idempotency",
        pricing_ref: "provider-gpt-denied-idempotency"
      })

    assert {:ok, %{request: request}} =
             Accounting.record_denied_request(%{pool: pool, api_key: api_key}, model, %{
               endpoint: "/backend-api/codex/responses",
               transport: "http_json",
               correlation_id: "denied-idempotency-boundary",
               idempotency_key: raw_idempotency_key,
               response_status_code: 429,
               last_error_code: "rate_limited",
               request_metadata: %{
                 "gateway_denial" => %{
                   "code" => "rate_limited",
                   "message" => "request was rate limited"
                 },
                 "idempotency_key" => raw_idempotency_key
               }
             })

    persisted = Repo.get!(Request, request.id)
    assert is_nil(persisted.idempotency_key)
    assert persisted.request_metadata["idempotency_key"] == "[REDACTED]"
    refute inspect(persisted) =~ raw_idempotency_key

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    refute inspect(log) =~ raw_idempotency_key
  end

  defp pinned_denial_request_fixture(pool, api_key, assignment, identity) do
    assert {:ok, %{request: request}} =
             Accounting.record_denied_request(%{pool: pool, api_key: api_key}, nil, %{
               endpoint: "/backend-api/codex/responses",
               transport: "http_json",
               correlation_id: "pinned-denial-#{System.unique_integer([:positive])}",
               requested_model: "gpt-pinned-denial-scope",
               response_status_code: 503,
               last_error_code: "pinned_continuation_reauth_required",
               request_metadata: %{
                 "gateway_denial" => %{
                   "code" => "pinned_continuation_reauth_required",
                   "message" => "restart with full visible context"
                 },
                 "continuity_denial" => continuity_denial_metadata(assignment, identity)
               }
             })

    request
  end

  defp continuity_denial_metadata(assignment, identity) do
    %{
      "denial_family" => "pinned_continuation_reauth",
      "continuity_family" => "pinned_codex_session",
      "upstream_lifecycle_family" => "reauth_required",
      "token_refresh_reason_code_preview" => "refresh_token_revoked",
      "pool_upstream_assignment_id" => assignment.id,
      "upstream_identity_id" => identity.id,
      "operator_action" => @pinned_continuation_operator_action
    }
  end

  defp debug_turn_fixture(pool, api_key, assignment, request, attrs) do
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

    completed_at = Map.get(attrs, :completed_at, now)

    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: request.transport,
      status: Map.fetch!(attrs, :status),
      error_code: Map.get(attrs, :error_code),
      first_visible_output_at: now,
      final_attempt_id: Map.get(attrs, :final_attempt_id),
      started_at: now,
      completed_at: completed_at,
      created_at: now,
      updated_at: DateTime.add(now, 1, :second)
    }
    |> Repo.insert!()
  end

  defp stable_ref(:session, value), do: "session_" <> stable_hash("codex_session:" <> value)
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
