defmodule CodexPooler.MCP.RequestLogsToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolDispatch}
  alias CodexPooler.MCP.Tools.LogMetadata
  alias CodexPooler.Repo

  @pinned_continuation_operator_action "reauthenticate the pinned upstream account and restart the client without continuation anchors"
  @pinned_continuation_unavailable_operator_action "wait for the pinned upstream to recover, then restart the client without continuation anchors"

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})

    user =
      user
      |> Ecto.Changeset.change(password_change_required: false)
      |> Repo.update!()

    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(user, %{label: "Logs MCP"})
    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    %{auth: auth, user: user}
  end

  test "lists request-log metadata as bounded sanitized readable rows", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-logs", name: "MCP Request Logs"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP runtime key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{account_label: "Primary upstream"})

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-alpha",
        endpoint: "/backend-api/codex/responses",
        transport: "http_sse",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "mcp-request-log-alpha",
        response_status_code: 202,
        retry_count: 2,
        user_agent: "Codex CLI/1.2.3 extra raw details",
        upstream_account_email: "upstream.account@example.com",
        upstream_account_label: "stored-account-alpha",
        request_metadata: unsafe_metadata(%{"safe" => "visible metadata"})
      })

    attempt_with_latency(request, assignment, 345, %{
      "reasoning" => %{
        "requested_effort" => "high",
        "applied_effort" => "max",
        "effective_effort" => "max",
        "source" => "api_key_policy",
        "rewrite" => "high_to_max"
      }
    })

    _other_status =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-alpha",
        status: "failed",
        correlation_id: "mcp-request-log-failed"
      })

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "pool_id" => pool.id,
                 "status" => "succeeded",
                 "model" => "gpt-log-alpha",
                 "limit" => 1
               },
               %{auth: auth}
             )

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)

    assert [%{"type" => "text", "text" => text}] = result["content"]
    refute text =~ Jason.encode!(result["structuredContent"])

    structured = result["structuredContent"]

    assert Map.keys(structured) |> Enum.sort() == [
             "items",
             "limit",
             "nextOffset",
             "offset",
             "total"
           ]

    assert structured["total"] == 1
    assert structured["limit"] == 1
    assert structured["offset"] == 0
    assert structured["nextOffset"] == nil
    assert [item] = structured["items"]

    assert item["id"] == request.id
    assert item["pool_id"] == pool.id
    assert item["pool_slug"] == "mcp-request-logs"
    assert item["pool_name"] == "MCP Request Logs"
    assert item["status"] == "succeeded"
    assert item["endpoint"] == "/backend-api/codex/responses"
    assert item["requested_model"] == "gpt-log-alpha"
    assert item["transport"] == "http_sse"
    assert item["usage_status"] == "usage_known"
    assert item["latency_ms"] == 345
    assert item["retry_count"] == 2
    assert item["response_status_code"] == 202
    assert item["applied_reasoning_effort"] == "max"
    assert item["effective_reasoning_effort"] == "max"
    assert item["reasoning_effort_source"] == "api_key_policy"
    assert item["reasoning_effort_rewrite"] == "high_to_max"
    assert item["metadata"]["safe"] == "visible metadata"
    assert item["metadata"]["nested"]["count"] == 2
    assert item["metadata"]["nested"]["safe_sentinel"] == "[REDACTED]"
    refute Map.has_key?(item["metadata"], "prompt")
    refute Map.has_key?(item["metadata"], "raw_headers")
    refute Map.has_key?(item["metadata"], "request_body")
    refute Map.has_key?(item["metadata"], "raw_idempotency_key")
    refute Map.has_key?(item["metadata"]["nested"], "signed_url")

    assert text =~ "1 request logs returned; total 1; offset 0; statuses succeeded:1"
    assert text =~ "admitted_at=#{item["admitted_at"]}"
    assert text =~ "completed_at=#{item["completed_at"]}"
    assert text =~ "pool=mcp-request-logs"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    assert text =~ "route=/backend-api/codex/responses"
    assert text =~ "status=succeeded"
    assert text =~ "model=gpt-log-alpha"
    assert text =~ "transport=http_sse"
    assert text =~ "usage=usage_known"
    assert text =~ "latency_ms=345"
    assert text =~ "retries=2"
    refute text =~ "retry_count="
    refute text =~ "metadata="

    assert_no_unsafe_request_log_text(result)
  end

  test "lists request-log debug metadata as compact sanitized incident fields", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-log-debug", name: "MCP Request Log Debug"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP debug key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Debug upstream",
        assignment_label: "Debug assignment"
      })

    %{request: terminal_request, attempt: terminal_attempt} =
      failed_debug_request_fixture(pool, api_key, assignment, %{
        correlation_id: "mcp-debug-terminal",
        codex_session_id: "session-example-1",
        codex_session_key: "session-key-example-1",
        request_error: "client_disconnected",
        attempt_error: "owner_drained",
        response_metadata: safe_transport_failure_metadata()
      })

    terminal_turn =
      debug_turn_fixture(terminal_request, %{
        session: debug_session_fixture(pool, api_key, assignment, "session-key-example-1"),
        status: "failed",
        error_code: "turn_owner_drained",
        final_attempt_id: terminal_attempt.id,
        turn_sequence: 1
      })

    %{request: mismatch_request, attempt: _mismatch_attempt} =
      failed_debug_request_fixture(pool, api_key, assignment, %{
        correlation_id: "mcp-debug-open-turn",
        codex_session_id: "session-example-2",
        codex_session_key: "session-key-example-2",
        request_error: "owner_unavailable",
        attempt_error: "upstream_timeout"
      })

    mismatch_turn =
      debug_turn_fixture(mismatch_request, %{
        session: debug_session_fixture(pool, api_key, assignment, "session-key-example-2"),
        status: "in_progress",
        error_code: nil,
        completed_at: nil,
        turn_sequence: 1
      })

    rejected_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-contract",
        endpoint: "/backend-api/codex/responses",
        transport: "http_json",
        status: "rejected",
        usage_status: "usage_unknown",
        correlation_id: "mcp-debug-rejected",
        response_status_code: 403,
        request_metadata: %{}
      })
      |> Ecto.Changeset.change(last_error_code: "model_not_allowed")
      |> Repo.update!()

    legacy_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-contract",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "mcp-debug-legacy",
        response_status_code: 499,
        request_metadata: %{"codex_session_id" => %{"legacy" => "bad-shape"}}
      })
      |> Ecto.Changeset.change(last_error_code: "legacy_failure")
      |> Repo.update!()

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "pool_id" => pool.id,
                 "model" => "gpt-log-debug-contract",
                 "limit" => 10
               },
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    refute text =~ Jason.encode!(result["structuredContent"])

    items_by_id = Map.new(result["structuredContent"]["items"], &{&1["id"], &1})

    terminal_item = Map.fetch!(items_by_id, terminal_request.id)

    assert Map.has_key?(terminal_item, "debug"),
           "expected request log item to include debug metadata"

    terminal_debug = terminal_item["debug"]
    refute Map.has_key?(terminal_debug, "attempts")
    refute inspect(terminal_debug) =~ "Mint.TransportError"
    refute inspect(terminal_debug) =~ "closed"

    terminal_continuity = terminal_debug["continuity"]
    assert_ref_prefix(terminal_continuity["session_ref"], "session_")
    assert_ref_prefix(terminal_continuity["turn_ref"], "turn_")

    assert anonymize_refs(terminal_continuity) == %{
             "status" => "available",
             "session_ref" => :session_ref,
             "session_source" => "continuity",
             "turn_ref" => :turn_ref,
             "turn_status" => "failed",
             "turn_status_source" => "turn_state",
             "has_open_turn" => false,
             "terminal_state" => "terminal",
             "terminal_state_source" => "turn_state"
           }

    assert terminal_debug["failure"] == %{
             "error_code" => "turn_owner_drained",
             "error_source" => "turn_error"
           }

    assert terminal_debug["attempt"] == %{
             "latest_attempt_number" => 1,
             "latest_attempt_status" => "failed",
             "latest_attempt_retryable" => true,
             "latest_upstream_status_code" => 499,
             "attempt_count" => 1
           }

    mismatch_item = Map.fetch!(items_by_id, mismatch_request.id)

    assert Map.has_key?(mismatch_item, "debug"),
           "expected request log item to include debug metadata"

    mismatch_debug = mismatch_item["debug"]

    mismatch_continuity = mismatch_debug["continuity"]
    assert_ref_prefix(mismatch_continuity["session_ref"], "session_")
    assert_ref_prefix(mismatch_continuity["turn_ref"], "turn_")

    assert anonymize_refs(mismatch_continuity) == %{
             "status" => "mismatch",
             "session_ref" => :session_ref,
             "session_source" => "continuity",
             "turn_ref" => :turn_ref,
             "turn_status" => "in_progress",
             "turn_status_source" => "turn_state",
             "has_open_turn" => true,
             "terminal_state" => "mismatch",
             "terminal_state_source" => "turn_state"
           }

    assert mismatch_debug["failure"] == %{
             "error_code" => "owner_unavailable",
             "error_source" => "request_error"
           }

    rejected_item = Map.fetch!(items_by_id, rejected_request.id)

    assert Map.has_key?(rejected_item, "debug"),
           "expected request log item to include debug metadata"

    rejected_debug = rejected_item["debug"]

    assert rejected_debug["continuity"] == %{
             "status" => "not_applicable",
             "session_ref" => nil,
             "session_source" => nil,
             "turn_ref" => nil,
             "turn_status" => nil,
             "turn_status_source" => nil,
             "has_open_turn" => nil,
             "terminal_state" => "not_applicable",
             "terminal_state_source" => nil
           }

    assert rejected_debug["failure"] == %{
             "error_code" => "model_not_allowed",
             "error_source" => "request_error"
           }

    legacy_item = Map.fetch!(items_by_id, legacy_request.id)

    assert Map.has_key?(legacy_item, "debug"),
           "expected request log item to include debug metadata"

    legacy_debug = legacy_item["debug"]
    assert legacy_debug["continuity"]["status"] == "unknown"
    assert legacy_debug["continuity"]["session_ref"] == nil

    assert_terminal_text_contract(text, terminal_request, terminal_turn)
    assert_terminal_text_contract(text, mismatch_request, mismatch_turn)
    assert_no_debug_raw_session_values(result)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log list output schema accepts absent next page marker" do
    request_logs_tool =
      Enum.find(LogMetadata.tools(), &(&1.name == "codex_pooler_list_request_logs"))

    assert get_in(request_logs_tool.output_schema, ["properties", "nextOffset", "type"]) == [
             "integer",
             "null"
           ]

    assert get_in(request_logs_tool.output_schema, [
             "properties",
             "items",
             "items",
             "properties",
             "debug",
             "required"
           ]) == ["continuity", "failure", "attempt"]
  end

  test "request-log list text handles empty results without echoing caller filters", %{auth: auth} do
    sentinels = caller_filter_sentinels()

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               Map.merge(sentinels, %{"limit" => 50, "offset" => 5}),
               %{auth: auth}
             )

    assert result["isError"] == false

    assert result["structuredContent"] == %{
             "items" => [],
             "total" => 0,
             "limit" => 50,
             "offset" => 5,
             "nextOffset" => nil
           }

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "0 request logs returned; total 0; offset 5; statuses none"

    for {_field, sentinel} <- sentinels do
      refute text =~ sentinel
      refute inspect(result) =~ sentinel
    end

    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log list accepts full ISO8601 timestamp range filters", %{auth: auth} do
    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "date_from" => "2026-05-23T02:23:30Z",
                 "date_to" => "2026-05-23T02:26:20Z",
                 "request_id" => "f5da8450",
                 "limit" => 20,
                 "offset" => 0
               },
               %{auth: auth}
             )

    assert result["isError"] == false

    assert result["structuredContent"] == %{
             "items" => [],
             "total" => 0,
             "limit" => 20,
             "offset" => 0,
             "nextOffset" => nil
           }

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "0 request logs returned; total 0; offset 0; statuses none"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log filters and pagination preserve debug fields", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-log-filters", name: "MCP Request Log Filters"})
    other_pool = pool_fixture(%{slug: "mcp-request-log-other", name: "MCP Request Log Other"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP filter key"})
    %{api_key: other_api_key} = active_api_key_fixture(other_pool)

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Filter upstream",
        assignment_label: "Filter assignment"
      })

    target_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-filter-debug-alpha",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "filter-debug-target",
        request_metadata: %{
          "codex_session_id" => "session-filter-target",
          "request_id" => "phoenix-filter-target"
        }
      })
      |> Ecto.Changeset.change(admitted_at: ~U[2026-05-23 02:25:00.000000Z])
      |> Repo.update!()

    attempt_with_latency(target_request, assignment, 222)

    older_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-filter-debug-alpha",
        endpoint: "/backend-api/codex/responses",
        transport: "http_sse",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "filter-debug-older",
        request_metadata: %{"codex_session_id" => "session-filter-older"}
      })
      |> Ecto.Changeset.change(admitted_at: ~U[2026-05-23 02:24:00.000000Z])
      |> Repo.update!()

    attempt_with_latency(older_request, assignment, 111)

    _wrong_status =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-filter-debug-alpha",
        status: "failed",
        correlation_id: "filter-debug-wrong-status"
      })
      |> Ecto.Changeset.change(admitted_at: ~U[2026-05-23 02:25:30.000000Z])
      |> Repo.update!()

    _wrong_pool =
      request_fixture(%{pool: other_pool, api_key: other_api_key}, %{
        requested_model: "gpt-filter-debug-alpha",
        status: "succeeded",
        correlation_id: "filter-debug-other-pool"
      })
      |> Ecto.Changeset.change(admitted_at: ~U[2026-05-23 02:25:40.000000Z])
      |> Repo.update!()

    assert {:ok, filtered_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "pool_id" => pool.id,
                 "status" => "succeeded",
                 "model" => "filter-debug-alpha",
                 "request_id" => "filter-debug-target",
                 "upstream_identity_id" => identity.id,
                 "date_from" => "2026-05-23T02:24:30Z",
                 "date_to" => "2026-05-23T02:26:00Z",
                 "limit" => 10,
                 "offset" => 0
               },
               %{auth: auth}
             )

    assert filtered_result["isError"] == false
    assert filtered_result["structuredContent"]["total"] == 1
    assert [filtered_item] = filtered_result["structuredContent"]["items"]
    assert filtered_item["id"] == target_request.id
    assert filtered_item["upstream_identity_id"] == identity.id
    assert filtered_item["debug"]["attempt"]["attempt_count"] == 1
    assert filtered_item["debug"]["continuity"]["status"] == "available"
    assert_ref_prefix(filtered_item["debug"]["continuity"]["session_ref"], "session_")
    assert :ok = Redaction.assert_mcp_output_safe!(filtered_result)

    assert {:ok, metadata_request_id_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "request_id" => "phoenix-filter-target"},
               %{auth: auth}
             )

    assert metadata_request_id_result["isError"] == false
    assert metadata_request_id_result["structuredContent"]["total"] == 1
    assert [metadata_request_id_item] = metadata_request_id_result["structuredContent"]["items"]
    assert metadata_request_id_item["id"] == target_request.id
    assert :ok = Redaction.assert_mcp_output_safe!(metadata_request_id_result)

    assert {:ok, first_page} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "pool_id" => pool.id,
                 "status" => "succeeded",
                 "model" => "filter-debug-alpha",
                 "date_from" => "2026-05-23T02:23:30Z",
                 "date_to" => "2026-05-23T02:26:00Z",
                 "limit" => 1,
                 "offset" => 0
               },
               %{auth: auth}
             )

    assert first_page["structuredContent"]["total"] == 2
    assert first_page["structuredContent"]["nextOffset"] == 1

    assert [%{"id" => first_page_id, "debug" => first_debug}] =
             first_page["structuredContent"]["items"]

    assert first_page_id == target_request.id
    assert first_debug["attempt"]["attempt_count"] == 1

    assert {:ok, second_page} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "pool_id" => pool.id,
                 "status" => "succeeded",
                 "model" => "filter-debug-alpha",
                 "date_from" => "2026-05-23T02:23:30Z",
                 "date_to" => "2026-05-23T02:26:00Z",
                 "limit" => 1,
                 "offset" => 1
               },
               %{auth: auth}
             )

    assert second_page["structuredContent"]["total"] == 2
    assert second_page["structuredContent"]["nextOffset"] == nil

    assert [%{"id" => second_page_id, "debug" => second_debug}] =
             second_page["structuredContent"]["items"]

    assert second_page_id == older_request.id
    assert second_debug["attempt"]["attempt_count"] == 1
    assert :ok = Redaction.assert_mcp_output_safe!(first_page)
    assert :ok = Redaction.assert_mcp_output_safe!(second_page)
  end

  test "request-log list text is capped when structured content contains more than ten rows", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-request-log-over-limit", name: "MCP Request Log Over Limit"})
    %{api_key: api_key} = active_api_key_fixture(pool)

    for index <- 1..12 do
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-over-limit",
        endpoint: "/backend-api/codex/responses",
        status: "succeeded",
        correlation_id: "mcp-request-log-over-limit-#{index}"
      })
    end

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "model" => "gpt-log-over-limit", "limit" => 12},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert length(result["structuredContent"]["items"]) == 12
    assert result["structuredContent"]["total"] == 12

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "10 request logs returned; total 12; offset 0; statuses succeeded:12"
    assert text =~ "- ... 2 more rows omitted from text; use structuredContent or refine filters"

    row_count =
      text
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "- admitted_at="))

    assert row_count == 10
    refute text =~ Jason.encode!(result["structuredContent"])
  end

  test "request-log tool rejects malformed semantic filters without echoing date sentinels", %{
    auth: auth
  } do
    date_sentinel = "#{Redaction.forbidden_sentinel!(:request_body)}-not-a-date"

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "date_from" => date_sentinel,
                 "date_to" => Redaction.forbidden_sentinel!(:raw_headers)
               },
               %{auth: auth}
             )

    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "invalid_arguments: Invalid date_from"
    refute Map.has_key?(result, "structuredContent")
    refute inspect(result) =~ date_sentinel
    refute inspect(result) =~ Redaction.forbidden_sentinel!(:raw_headers)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "gets one request-log metadata record with readable detail fields and safe metadata summary",
       %{
         auth: auth
       } do
    pool = pool_fixture(%{slug: "mcp-request-log-detail", name: "MCP Request Log Detail"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP detail key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Detail upstream",
        assignment_label: "Detail assignment"
      })

    long_metadata = String.duplicate("safe-detail-value", 30)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-detail",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "mcp-request-log-detail",
        response_status_code: 499,
        retry_count: 3,
        upstream_account_email: "detail.account@example.com",
        upstream_account_label: "detail-account-label",
        request_metadata: unsafe_metadata(%{"safe" => long_metadata})
      })

    attempt_with_latency(request, assignment, 678)

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    refute text =~ Jason.encode!(result["structuredContent"])

    assert %{"status" => "ok", "kind" => "request_log", "item" => item} =
             result["structuredContent"]

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "candidates",
             "item",
             "kind",
             "message",
             "status"
           ]

    assert item["id"] == request.id
    assert item["pool_id"] == pool.id
    assert item["endpoint"] == "/backend-api/codex/responses"
    assert item["status"] == "failed"
    assert item["response_status_code"] == 499
    assert item["upstream_identity_label"] == "Detail upstream"
    assert item["upstream_account_label"] == "detail-account-label"
    assert item["metadata"]["safe"] == String.slice(long_metadata, 0, 200)
    refute Map.has_key?(item["metadata"], "prompt")
    refute Map.has_key?(item["metadata"], "raw_headers")

    assert text =~ "1 request log returned"
    assert text =~ "admitted_at=#{item["admitted_at"]}"
    assert text =~ "completed_at=#{item["completed_at"]}"
    assert text =~ "pool=mcp-request-log-detail"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    assert text =~ "route=/backend-api/codex/responses"
    assert text =~ "status=failed"
    assert text =~ "model=gpt-log-detail"
    assert text =~ "transport=websocket"
    assert text =~ "usage=usage_unknown"
    assert text =~ "latency_ms=678"
    assert text =~ "retries=3"
    assert text =~ "response=499"
    assert text =~ "upstream=Detail upstream"
    refute text =~ "retry_count="
    refute text =~ "response_status="
    refute text =~ "account="
    assert text =~ "metadata=2 safe metadata keys: nested, safe"
    refute text =~ long_metadata

    assert_no_unsafe_request_log_text(result)
  end

  test "gets only valid failed-attempt upstream error parameters in structured detail and readable text",
       %{
         auth: auth
       } do
    pool = pool_fixture(%{slug: "mcp-upstream-error-param", name: "MCP Upstream Error Param"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    raw_message = "raw upstream message must stay out of MCP"
    raw_value = "https://example.com/raw-upstream-value"
    raw_frame = ~s({"type":"error","message":"raw websocket frame"})
    raw_header = "Bearer raw-upstream-header"
    raw_prompt = "raw upstream prompt must stay out of MCP"
    raw_body = "raw upstream response body must stay out of MCP"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-mcp-upstream-error-param",
        status: "failed",
        correlation_id: "mcp-upstream-error-param"
      })

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

    attempt_fixture(request, assignment, %{
      attempt_number: 2,
      status: "failed",
      response_metadata: %{"upstream_error_param" => raw_value}
    })

    attempt_fixture(request, assignment, %{
      attempt_number: 3,
      status: "succeeded",
      response_metadata: %{"upstream_error_param" => "reasoning.effort"}
    })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert %{"status" => "ok", "item" => item} = result["structuredContent"]
    assert [first_attempt, second_attempt, third_attempt] = item["debug"]["attempts"]
    assert first_attempt["upstream_error_param"] == "reasoning.summary"
    refute Map.has_key?(second_attempt, "upstream_error_param")
    refute Map.has_key?(third_attempt, "upstream_error_param")
    assert text =~ "upstream_error_param=reasoning.summary"

    for forbidden <- [raw_message, raw_value, raw_frame, raw_header, raw_prompt, raw_body] do
      refute text =~ forbidden
      refute Jason.encode!(result["structuredContent"]) =~ forbidden
      refute inspect(result) =~ forbidden
    end
  end

  test "gets request-log by exact id when a newer correlation id contains that id", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-log-exact-id", name: "MCP Exact Request Log"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP exact key"})
    older_time = ~U[2026-05-26 00:00:00.000000Z]
    newer_time = DateTime.add(older_time, 60, :second)

    target_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-exact-target",
        status: "succeeded",
        correlation_id: "target-correlation"
      })
      |> Ecto.Changeset.change(admitted_at: older_time)
      |> Repo.update!()

    distractor_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-exact-distractor",
        status: "failed",
        correlation_id: "newer-correlation-containing-#{target_request.id}"
      })
      |> Ecto.Changeset.change(admitted_at: newer_time)
      |> Repo.update!()

    assert {:ok, fuzzy_list_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"request_id" => target_request.id, "limit" => 1},
               %{auth: auth}
             )

    assert fuzzy_list_result["isError"] == false
    assert [fuzzy_item] = fuzzy_list_result["structuredContent"]["items"]
    assert fuzzy_item["id"] == distractor_request.id

    assert {:ok, exact_get_result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => target_request.id}, %{
               auth: auth
             })

    assert exact_get_result["isError"] == false
    assert %{"status" => "ok", "item" => item} = exact_get_result["structuredContent"]
    assert item["id"] == target_request.id
    assert item["requested_model"] == "gpt-log-exact-target"
    assert :ok = Redaction.assert_mcp_output_safe!(exact_get_result)
  end

  test "gets exact request-log debug metadata with bounded terminal state and attempts", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-request-log-debug-detail", name: "MCP Debug Detail"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP debug detail key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Debug detail upstream",
        assignment_label: "Debug detail assignment"
      })

    %{request: request, attempt: attempt} =
      failed_debug_request_fixture(pool, api_key, assignment, %{
        correlation_id: "mcp-debug-detail-terminal",
        codex_session_id: "session-example-1",
        codex_session_key: "session-key-example-1",
        request_error: "client_disconnected",
        attempt_error: "owner_drained",
        response_metadata: safe_transport_failure_metadata()
      })

    turn =
      debug_turn_fixture(request, %{
        session: debug_session_fixture(pool, api_key, assignment, "session-key-example-1"),
        status: "failed",
        error_code: "turn_owner_drained",
        final_attempt_id: attempt.id,
        turn_sequence: 1
      })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    refute text =~ Jason.encode!(result["structuredContent"])

    assert %{"status" => "ok", "kind" => "request_log", "item" => item} =
             result["structuredContent"]

    assert Map.has_key?(item, "debug"),
           "expected request log detail item to include debug metadata"

    debug = item["debug"]

    continuity = debug["continuity"]
    assert_ref_prefix(continuity["session_ref"], "session_")
    assert_ref_prefix(continuity["turn_ref"], "turn_")

    assert anonymize_refs(continuity) == %{
             "status" => "available",
             "session_ref" => :session_ref,
             "session_source" => "continuity",
             "turn_ref" => :turn_ref,
             "turn_status" => "failed",
             "turn_status_source" => "turn_state",
             "has_open_turn" => false,
             "terminal_state" => "terminal",
             "terminal_state_source" => "turn_state"
           }

    assert debug["terminal_state"] == %{
             "state" => "terminal",
             "mismatch" => false,
             "sources" => [
               %{
                 "source" => "request_state",
                 "status" => "failed",
                 "error_code" => "client_disconnected"
               },
               %{
                 "source" => "turn_state",
                 "status" => "failed",
                 "error_code" => "turn_owner_drained"
               },
               %{
                 "source" => "attempt_state",
                 "status" => "failed",
                 "error_code" => "owner_drained"
               }
             ]
           }

    turn_debug = debug["turn"]
    assert_ref_prefix(turn_debug["turn_ref"], "turn_")
    assert_ref_prefix(turn_debug["final_attempt_ref"], "attempt_")

    assert anonymize_refs(turn_debug) == %{
             "turn_ref" => :turn_ref,
             "status" => "failed",
             "error_code" => "turn_owner_drained",
             "final_attempt_ref" => :attempt_ref,
             "inserted_at" => DateTime.to_iso8601(turn.created_at),
             "updated_at" => DateTime.to_iso8601(turn.updated_at),
             "completed_at" => DateTime.to_iso8601(turn.completed_at)
           }

    assert [attempt_debug] = debug["attempts"]
    assert_ref_prefix(attempt_debug["attempt_ref"], "attempt_")

    assert anonymize_refs(attempt_debug) == %{
             "attempt_ref" => :attempt_ref,
             "attempt_number" => 1,
             "status" => "failed",
             "retryable" => true,
             "pool_upstream_assignment_id" => assignment.id,
             "upstream_status_code" => 499,
             "network_error_code" => "owner_drained",
             "latency_ms" => 321,
             "transport_failure" => %{
               "exception" => "Mint.TransportError",
               "reason_class" => "Mint.TransportError",
               "reason" => "closed",
               "phase" => "request",
               "pre_visible_output" => false,
               "terminal_seen" => false,
               "text_frame_count" => 0
             },
             "final" => true
           }

    assert text =~ "1 request log returned"
    assert text =~ "session=session_"
    assert text =~ "turn=turn_"
    assert text =~ "terminal=terminal"
    assert text =~ "attempts=1"
    assert_no_debug_raw_session_values(result)
    assert_output_omits_transport_failure_raw_values(result)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "gets exact request-log detail with synthesized HTTP SSE interruption diagnostics", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-request-log-http-sse", name: "MCP HTTP SSE Detail"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP HTTP SSE key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "HTTP SSE upstream",
        assignment_label: "HTTP SSE assignment"
      })

    %{request: request, attempt: attempt} =
      failed_debug_request_fixture(pool, api_key, assignment, %{
        correlation_id: "mcp-debug-http-sse-interrupted",
        codex_session_id: "session-example-http-sse",
        codex_session_key: "session-key-example-http-sse",
        request_error: "upstream_stream_error",
        attempt_error: "upstream_stream_error",
        transport: "http_sse",
        response_status_code: 200,
        upstream_status_code: 200,
        retryable: false,
        response_metadata: %{
          "error_kind" => "stream_interrupted",
          "status_code" => 200,
          "raw_body" => "raw stream body should stay hidden",
          "raw_headers" => %{"authorization" => "Bearer sk-example-hidden"}
        },
        error_message: "raw stream body should stay hidden"
      })

    _turn =
      debug_turn_fixture(request, %{
        session: debug_session_fixture(pool, api_key, assignment, "session-key-example-http-sse"),
        status: "failed",
        error_code: "upstream_stream_error",
        final_attempt_id: attempt.id,
        turn_sequence: 1
      })

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "model" => "gpt-log-debug-contract", "limit" => 10},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    assert [list_item] = list_result["structuredContent"]["items"]
    assert list_item["id"] == request.id
    refute inspect(list_item["debug"]) =~ "transport_failure"

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert %{"status" => "ok", "item" => item} = result["structuredContent"]
    assert [attempt_debug] = item["debug"]["attempts"]

    assert attempt_debug["transport_failure"] == %{
             "reason_class" => "upstream_stream_interrupted",
             "reason" => "closed_before_terminal",
             "phase" => "upstream_close",
             "pre_visible_output" => false,
             "terminal_seen" => false,
             "text_frame_count" => 1
           }

    assert text =~ "1 request log returned"
    assert text =~ "transport=http_sse"
    assert text =~ "terminal=terminal"
    refute text =~ "closed_before_terminal"
    assert_no_debug_raw_session_values(result)
    refute inspect(result) =~ "session-example-http-sse"
    refute inspect(result) =~ "session-key-example-http-sse"
    refute inspect(result) =~ "raw stream body"
    refute inspect(result) =~ "Bearer sk-example-hidden"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log debug outputs omit adversarial metadata from list and get results", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-request-log-debug-privacy", name: "MCP Debug Privacy"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP privacy key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Privacy upstream",
        assignment_label: "Privacy assignment"
      })

    %{request: request, attempt: attempt} =
      failed_debug_request_fixture(pool, api_key, assignment, %{
        correlation_id: "mcp-debug-privacy",
        codex_session_id: "session-example-privacy",
        codex_session_key: "session-key-example-privacy",
        request_error: "client_disconnected",
        attempt_error: "owner_drained",
        request_metadata: adversarial_debug_metadata(),
        response_metadata:
          Map.merge(adversarial_debug_metadata(), %{
            "transport_failure" => %{
              "exception" => "RuntimeError raw prompt: explain private data",
              "reason_class" => "https://example.com/raw-debug-url",
              "reason" => "Authorization: Bearer sk-example-secret",
              "phase" => "request",
              "stacktrace" => "raw stacktrace should stay hidden"
            }
          }),
        error_message: "raw prompt: explain private data"
      })

    _turn =
      debug_turn_fixture(request, %{
        session: debug_session_fixture(pool, api_key, assignment, "session-key-example-privacy"),
        status: "failed",
        error_code: "turn_owner_drained",
        final_attempt_id: attempt.id,
        turn_sequence: 1
      })

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "model" => "gpt-log-debug-contract", "limit" => 10},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    assert [list_item] = list_result["structuredContent"]["items"]
    assert list_item["id"] == request.id
    assert_debug_fields_present(list_item["debug"], :list)
    assert_output_omits_adversarial_debug_values(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert get_result["isError"] == false
    assert %{"status" => "ok", "item" => get_item} = get_result["structuredContent"]
    assert get_item["id"] == request.id
    assert_debug_fields_present(get_item["debug"], :get)
    assert_output_omits_adversarial_debug_values(get_result)
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "gets exact request-log debug attempts capped to latest ten in ascending order", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-request-log-attempt-bound", name: "MCP Attempt Bound"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP bound key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Bound upstream",
        assignment_label: "Bound assignment"
      })

    %{request: request, attempt: first_attempt} =
      failed_debug_request_fixture(pool, api_key, assignment, %{
        correlation_id: "mcp-debug-detail-attempt-bound",
        codex_session_id: "session-example-1",
        codex_session_key: "session-key-example-1",
        request_error: "client_disconnected",
        attempt_error: "first_attempt_failed"
      })

    attempts =
      [first_attempt] ++
        for attempt_number <- 2..12 do
          request
          |> attempt_fixture(assignment, %{
            attempt_number: attempt_number,
            status: "failed",
            retryable: true,
            upstream_status_code: 499,
            usage_status: "usage_unknown"
          })
          |> Ecto.Changeset.change(%{
            latency_ms: attempt_number * 10,
            network_error_code: "attempt_#{attempt_number}_failed",
            error_message: "raw bounded attempt error must stay out of MCP output",
            response_metadata: %{"websocket_frame" => "raw bounded websocket frame"}
          })
          |> Repo.update!()
        end

    final_attempt = List.last(attempts)

    _turn =
      debug_turn_fixture(request, %{
        session: debug_session_fixture(pool, api_key, assignment, "session-key-example-1"),
        status: "failed",
        error_code: "turn_owner_drained",
        final_attempt_id: final_attempt.id,
        turn_sequence: 1
      })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]

    assert %{"status" => "ok", "kind" => "request_log", "item" => item} =
             result["structuredContent"]

    debug_attempts = item["debug"]["attempts"]
    assert length(debug_attempts) == 10
    assert Enum.map(debug_attempts, & &1["attempt_number"]) == Enum.to_list(3..12)
    assert Enum.map(debug_attempts, & &1["final"]) == List.duplicate(false, 9) ++ [true]

    for attempt_debug <- debug_attempts do
      assert_ref_prefix(attempt_debug["attempt_ref"], "attempt_")
    end

    assert text =~ "attempts=10"
    refute inspect(result) =~ "raw bounded attempt error must stay out of MCP output"
    refute inspect(result) =~ "raw bounded websocket frame"
    assert_no_debug_raw_session_values(result)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log debug edge rows stay schema-valid in exact details", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-log-debug-edges", name: "MCP Debug Edges"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP edge key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Edge upstream",
        assignment_label: "Edge assignment"
      })

    rejected_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-edge",
        endpoint: "/backend-api/codex/responses",
        transport: "http_json",
        status: "rejected",
        usage_status: "usage_unknown",
        correlation_id: "mcp-debug-edge-rejected",
        response_status_code: 403,
        request_metadata: %{}
      })
      |> Ecto.Changeset.change(last_error_code: "model_not_allowed")
      |> Repo.update!()

    attempts_without_turn =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-edge",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "mcp-debug-edge-attempts",
        response_status_code: 502,
        request_metadata: %{"codex_session_id" => "session-edge-attempts"}
      })
      |> Ecto.Changeset.change(last_error_code: "request_failed")
      |> Repo.update!()

    attempts_without_turn
    |> attempt_fixture(assignment, %{
      status: "failed",
      retryable: false,
      upstream_status_code: 502,
      usage_status: "usage_unknown"
    })
    |> Ecto.Changeset.change(%{
      latency_ms: 456,
      network_error_code: "upstream_status",
      error_message: "raw edge attempt error must stay out of MCP output"
    })
    |> Repo.update!()

    turn_without_attempt =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-edge",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "mcp-debug-edge-turn",
        request_metadata: %{"codex_session_id" => "session-edge-turn"}
      })
      |> Ecto.Changeset.change(last_error_code: "turn_failed")
      |> Repo.update!()

    turn =
      debug_turn_fixture(turn_without_attempt, %{
        session: debug_session_fixture(pool, api_key, assignment, "session-edge-turn"),
        status: "failed",
        error_code: "turn_failed",
        final_attempt_id: nil,
        turn_sequence: 1
      })

    legacy_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-edge",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "mcp-debug-edge-legacy",
        request_metadata: %{"codex_session_id" => %{"legacy" => "bad-shape"}}
      })
      |> Ecto.Changeset.change(last_error_code: "legacy_failure")
      |> Repo.update!()

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "model" => "gpt-log-debug-edge", "limit" => 10},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    items_by_id = Map.new(list_result["structuredContent"]["items"], &{&1["id"], &1})

    assert Map.fetch!(items_by_id, rejected_request.id)["debug"]["continuity"]["status"] ==
             "not_applicable"

    assert Map.fetch!(items_by_id, attempts_without_turn.id)["debug"]["attempt"]["attempt_count"] ==
             1

    assert Map.fetch!(items_by_id, turn_without_attempt.id)["debug"]["continuity"]["turn_status"] ==
             "failed"

    assert Map.fetch!(items_by_id, legacy_request.id)["debug"]["continuity"]["status"] ==
             "unknown"

    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    rejected_debug = debug_for_request(auth, rejected_request)
    assert rejected_debug["continuity"]["status"] == "not_applicable"
    assert rejected_debug["attempts"] == []

    attempts_debug = debug_for_request(auth, attempts_without_turn)
    assert attempts_debug["continuity"]["status"] == "available"
    assert_ref_prefix(attempts_debug["continuity"]["session_ref"], "session_")
    assert attempts_debug["continuity"]["turn_ref"] == nil
    assert [attempt_debug] = attempts_debug["attempts"]
    assert attempt_debug["status"] == "failed"
    assert attempt_debug["network_error_code"] == "upstream_status"

    turn_debug = debug_for_request(auth, turn_without_attempt)
    assert turn_debug["continuity"]["status"] == "available"
    assert_ref_prefix(turn_debug["continuity"]["turn_ref"], "turn_")
    assert turn_debug["turn"]["turn_ref"] == turn_debug["continuity"]["turn_ref"]
    assert turn_debug["turn"]["status"] == "failed"
    assert turn_debug["turn"]["final_attempt_ref"] == nil
    assert turn_debug["turn"]["inserted_at"] == DateTime.to_iso8601(turn.created_at)
    assert turn_debug["attempts"] == []

    legacy_debug = debug_for_request(auth, legacy_request)
    assert legacy_debug["continuity"]["status"] == "unknown"
    assert legacy_debug["continuity"]["session_ref"] == nil
    assert legacy_debug["terminal_state"]["state"] == "unknown"
    assert legacy_debug["attempts"] == []

    inspected = inspect([list_result, rejected_debug, attempts_debug, turn_debug, legacy_debug])
    refute inspected =~ "session-edge-attempts"
    refute inspected =~ "session-edge-turn"
    refute inspected =~ "raw edge attempt error"
  end

  test "request-log get text handles nil optional fields and missing selectors", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-log-nil", name: "MCP Request Log Nil"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP nil key"})

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-nil",
        endpoint: "/backend-api/codex/responses",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        retry_count: nil,
        correlation_id: "mcp-request-log-nil",
        request_metadata: %{}
      })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 request log returned"
    assert text =~ "admitted_at="
    assert text =~ "pool=mcp-request-log-nil"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    assert text =~ "status=in_progress"
    assert text =~ "model=gpt-log-nil"
    assert text =~ "transport=http_json"
    refute text =~ "completed_at="
    assert text =~ "usage=usage_pending"
    refute text =~ "latency_ms="
    assert text =~ "retries=0"
    assert text =~ "upstream=unknown"
    refute text =~ "retry_count="
    refute text =~ "response_status="
    refute text =~ "response="
    refute text =~ "account="
    refute text =~ "metadata="

    missing_selector = "sk-cxp-secret-missing-selector"

    assert {:ok, missing} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => missing_selector}, %{
               auth: auth
             })

    assert missing["isError"] == false

    assert missing["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "request_log",
             "item" => nil,
             "candidates" => [],
             "message" => "request_log selector did not match"
           }

    assert [%{"type" => "text", "text" => missing_text}] = missing["content"]
    assert missing_text == "No visible request log matched the selector"
    refute inspect(missing) =~ missing_selector
    assert :ok = Redaction.assert_mcp_output_safe!(missing)
  end

  test "request-log tools expose pinned reauth denial metadata without unsafe anchors", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-pinned-denial", name: "MCP Pinned Denial"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP pinned key"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Pinned upstream",
        assignment_label: "Pinned assignment"
      })

    request = pinned_denial_request_fixture(pool, api_key, assignment, identity)

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "limit" => 10},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => list_text}] = list_result["content"]
    assert [list_item] = list_result["structuredContent"]["items"]
    assert list_item["id"] == request.id
    assert_pinned_denial_mcp_item(list_item, assignment, identity)
    assert list_text =~ "denial_family=pinned_continuation_reauth"
    assert list_text =~ "continuity_family=pinned_codex_session"
    assert list_text =~ "lifecycle=reauth_required"
    assert list_text =~ "refresh_reason=refresh_token_revoked"
    assert list_text =~ "action=#{@pinned_continuation_operator_action}"
    assert_no_pinned_denial_mcp_leaks(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert %{"status" => "ok", "item" => get_item} = get_result["structuredContent"]
    assert get_item["id"] == request.id
    assert_pinned_denial_mcp_item(get_item, assignment, identity)
    assert get_text =~ "denial_family=pinned_continuation_reauth"
    assert get_text =~ "action=#{@pinned_continuation_operator_action}"
    assert_no_pinned_denial_mcp_leaks(get_result)
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "request-log tools expose pinned unavailable denial metadata without unsafe anchors", %{
    auth: auth
  } do
    pool =
      pool_fixture(%{slug: "mcp-pinned-unavailable", name: "MCP Pinned Unavailable"})

    %{api_key: api_key} =
      active_api_key_fixture(pool, %{display_name: "MCP pinned unavailable key"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Pinned unavailable upstream",
        assignment_label: "Pinned unavailable assignment"
      })

    request = pinned_unavailable_denial_request_fixture(pool, api_key, assignment, identity)

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "limit" => 10},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => list_text}] = list_result["content"]
    assert [list_item] = list_result["structuredContent"]["items"]
    assert list_item["id"] == request.id
    assert_pinned_unavailable_denial_mcp_item(list_item, assignment, identity)
    assert list_text =~ "denial_family=pinned_continuation_unavailable"
    assert list_text =~ "continuity_family=pinned_codex_session"
    assert list_text =~ "pin_reason=previous_response_id"
    assert list_text =~ "internal_reason=quota_exhausted"
    assert list_text =~ "action=#{@pinned_continuation_unavailable_operator_action}"
    assert_no_pinned_denial_mcp_leaks(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert %{"status" => "ok", "item" => get_item} = get_result["structuredContent"]
    assert get_item["id"] == request.id
    assert_pinned_unavailable_denial_mcp_item(get_item, assignment, identity)
    assert get_text =~ "denial_family=pinned_continuation_unavailable"
    assert get_text =~ "pin_reason=previous_response_id"
    assert get_text =~ "internal_reason=quota_exhausted"
    assert get_text =~ "action=#{@pinned_continuation_unavailable_operator_action}"
    assert_no_pinned_denial_mcp_leaks(get_result)
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "scoped admin request-log tools keep pinned denial metadata inside assigned pools", %{
    user: owner
  } do
    visible_pool = pool_fixture(%{slug: "mcp-pinned-visible", name: "MCP Pinned Visible"})
    hidden_pool = pool_fixture(%{slug: "mcp-pinned-hidden", name: "MCP Pinned Hidden"})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    %{api_key: visible_key} = active_api_key_fixture(visible_pool)
    %{api_key: hidden_key} = active_api_key_fixture(hidden_pool)

    %{identity: visible_identity, assignment: visible_assignment} =
      upstream_assignment_fixture(visible_pool)

    %{identity: hidden_identity, assignment: hidden_assignment} =
      upstream_assignment_fixture(hidden_pool)

    visible_request =
      pinned_denial_request_fixture(
        visible_pool,
        visible_key,
        visible_assignment,
        visible_identity
      )

    hidden_request =
      pinned_denial_request_fixture(hidden_pool, hidden_key, hidden_assignment, hidden_identity)

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Scoped pinned MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_request_logs", %{"limit" => 10}, %{
               auth: admin_auth
             })

    assert list_result["isError"] == false
    assert [presented] = list_result["structuredContent"]["items"]
    assert presented["id"] == visible_request.id
    assert_pinned_denial_mcp_item(presented, visible_assignment, visible_identity)

    hidden_dump = inspect(list_result)
    refute hidden_dump =~ hidden_request.id
    refute hidden_dump =~ hidden_assignment.id
    refute hidden_dump =~ hidden_identity.id

    assert {:ok, hidden_result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => hidden_request.id}, %{
               auth: admin_auth
             })

    assert hidden_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "request_log",
             "item" => nil,
             "candidates" => [],
             "message" => "request_log selector did not match"
           }

    refute inspect(hidden_result) =~ hidden_request.id
    refute inspect(hidden_result) =~ hidden_assignment.id
    refute inspect(hidden_result) =~ hidden_identity.id
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(hidden_result)
  end

  test "scoped admin request-log tools return assigned-pool logs only", %{user: owner} do
    visible_pool =
      pool_fixture(%{slug: "mcp-visible-request-logs", name: "MCP Visible Request Logs"})

    hidden_pool =
      pool_fixture(%{slug: "mcp-hidden-request-logs", name: "MCP Hidden Request Logs"})

    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    %{api_key: visible_key} =
      active_api_key_fixture(visible_pool, %{display_name: "Visible request key"})

    %{api_key: hidden_key} =
      active_api_key_fixture(hidden_pool, %{display_name: "Hidden request key"})

    visible_request =
      request_fixture(%{pool: visible_pool, api_key: visible_key}, %{
        correlation_id: "visible-request-log"
      })

    hidden_request =
      request_fixture(%{pool: hidden_pool, api_key: hidden_key}, %{
        correlation_id: "hidden-request-log"
      })

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Scoped logs MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_request_logs", %{"limit" => 10}, %{
               auth: admin_auth
             })

    assert [presented] = list_result["structuredContent"]["items"]
    assert presented["id"] == visible_request.id
    refute Jason.encode!(list_result["structuredContent"]) =~ hidden_request.id

    assert {:ok, hidden_result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => hidden_request.id}, %{
               auth: admin_auth
             })

    assert hidden_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "request_log",
             "item" => nil,
             "candidates" => [],
             "message" => "request_log selector did not match"
           }

    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(hidden_result)
  end

  defp pinned_denial_request_fixture(pool, api_key, assignment, identity) do
    request_fixture(%{pool: pool, api_key: api_key}, %{
      requested_model: "gpt-pinned-denial-mcp",
      endpoint: "/backend-api/codex/responses",
      transport: "http_json",
      status: "rejected",
      usage_status: "not_applicable",
      correlation_id: "mcp-pinned-denial-#{System.unique_integer([:positive])}",
      response_status_code: 503,
      last_error_code: "pinned_continuation_reauth_required",
      request_metadata: %{
        "gateway_denial" => %{
          "code" => "pinned_continuation_reauth_required",
          "message" => "restart with full visible context"
        },
        "continuity_denial" =>
          continuity_denial_metadata(assignment, identity)
          |> Map.merge(%{
            "previous_response_id" => "resp_raw_anchor_mcp",
            "previous-response-id" => %{
              "id" => "resp_raw_nested_map_anchor_mcp",
              "preview" => "resp_raw_nested_map_preview_mcp"
            },
            "previous response id" => [%{"id" => "resp_raw_nested_list_anchor_mcp"}],
            "prompt" => Redaction.forbidden_sentinel!(:prompt),
            "request_body" => Redaction.forbidden_sentinel!(:request_body),
            "response_body" => Redaction.forbidden_sentinel!(:response_body),
            "raw_idempotency_key" => Redaction.forbidden_sentinel!(:raw_idempotency_key),
            "access_token" => Redaction.forbidden_sentinel!(:access_token),
            "refresh_token" => Redaction.forbidden_sentinel!(:refresh_token),
            "cookie" => Redaction.forbidden_sentinel!(:cookies),
            "auth_json" => Redaction.forbidden_sentinel!(:upstream_auth_json),
            "provider_payload" => Redaction.forbidden_sentinel!(:provider_payload),
            "websocket_frame" => Redaction.forbidden_sentinel!(:websocket_frame)
          })
      }
    })
  end

  defp pinned_unavailable_denial_request_fixture(pool, api_key, assignment, identity) do
    request_fixture(%{pool: pool, api_key: api_key}, %{
      requested_model: "gpt-pinned-unavailable-mcp",
      endpoint: "/backend-api/codex/responses",
      transport: "http_json",
      status: "rejected",
      usage_status: "not_applicable",
      correlation_id: "mcp-pinned-unavailable-#{System.unique_integer([:positive])}",
      response_status_code: 503,
      last_error_code: "pinned_continuation_unavailable",
      request_metadata: %{
        "gateway_denial" => %{
          "code" => "pinned_continuation_unavailable",
          "message" => "restart with full visible context"
        },
        "continuity_denial" =>
          unavailable_continuity_denial_metadata(assignment, identity)
          |> Map.merge(%{
            "previous_response_id" => "resp_raw_anchor_mcp",
            "previous-response-id" => %{
              "id" => "resp_raw_nested_map_anchor_mcp",
              "preview" => "resp_raw_nested_map_preview_mcp"
            },
            "previous response id" => [%{"id" => "resp_raw_nested_list_anchor_mcp"}],
            "prompt" => Redaction.forbidden_sentinel!(:prompt),
            "request_body" => Redaction.forbidden_sentinel!(:request_body),
            "response_body" => Redaction.forbidden_sentinel!(:response_body),
            "raw_idempotency_key" => Redaction.forbidden_sentinel!(:raw_idempotency_key),
            "access_token" => Redaction.forbidden_sentinel!(:access_token),
            "refresh_token" => Redaction.forbidden_sentinel!(:refresh_token),
            "cookie" => Redaction.forbidden_sentinel!(:cookies),
            "auth_json" => Redaction.forbidden_sentinel!(:upstream_auth_json),
            "provider_payload" => Redaction.forbidden_sentinel!(:provider_payload),
            "websocket_frame" => Redaction.forbidden_sentinel!(:websocket_frame)
          })
      }
    })
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

  defp unavailable_continuity_denial_metadata(assignment, identity) do
    %{
      "denial_family" => "pinned_continuation_unavailable",
      "continuity_family" => "pinned_codex_session",
      "pin_mode" => "hard",
      "pin_reason" => "previous_response_id",
      "internal_reason" => "quota_exhausted",
      "pool_upstream_assignment_id" => assignment.id,
      "upstream_identity_id" => identity.id,
      "operator_action" => @pinned_continuation_unavailable_operator_action
    }
  end

  defp assert_pinned_denial_mcp_item(item, assignment, identity) do
    assert item["denial_reason"] == "pinned_continuation_reauth_required"

    continuity_denial = item["metadata"]["continuity_denial"]
    assert continuity_denial["denial_family"] == "pinned_continuation_reauth"
    assert continuity_denial["continuity_family"] == "pinned_codex_session"
    assert continuity_denial["upstream_lifecycle_family"] == "reauth_required"
    assert continuity_denial["token_refresh_reason_code_preview"] == "refresh_token_revoked"
    assert continuity_denial["pool_upstream_assignment_id"] == assignment.id
    assert continuity_denial["upstream_identity_id"] == identity.id
    assert continuity_denial["operator_action"] == @pinned_continuation_operator_action
    refute Map.has_key?(continuity_denial, "previous_response_id")
    refute Map.has_key?(continuity_denial, "previous-response-id")
    refute Map.has_key?(continuity_denial, "previous response id")
    refute Map.has_key?(continuity_denial, "request_body")
    refute Map.has_key?(continuity_denial, "response_body")
    refute Map.has_key?(continuity_denial, "raw_idempotency_key")
    refute Map.has_key?(continuity_denial, "access_token")
    refute Map.has_key?(continuity_denial, "refresh_token")
    refute Map.has_key?(continuity_denial, "cookie")
    refute Map.has_key?(continuity_denial, "auth_json")
    refute Map.has_key?(continuity_denial, "provider_payload")
    refute Map.has_key?(continuity_denial, "websocket_frame")

    assert Enum.any?(item["errors"], fn error ->
             error["kind"] == "continuity_denial" and
               error["code"] == "pinned_continuation_reauth" and
               error["denial_family"] == "pinned_continuation_reauth" and
               error["continuity_family"] == "pinned_codex_session" and
               error["upstream_lifecycle_family"] == "reauth_required" and
               error["token_refresh_reason_code_preview"] == "refresh_token_revoked" and
               error["pool_upstream_assignment_id"] == assignment.id and
               error["upstream_identity_id"] == identity.id and
               error["operator_action"] == @pinned_continuation_operator_action
           end)
  end

  defp assert_pinned_unavailable_denial_mcp_item(item, assignment, identity) do
    assert item["denial_reason"] == "pinned_continuation_unavailable"

    continuity_denial = item["metadata"]["continuity_denial"]
    assert_pinned_unavailable_continuity_denial(continuity_denial, assignment, identity)
    refute_pinned_denial_metadata_leaks(continuity_denial)

    assert Enum.any?(item["errors"], &pinned_unavailable_denial_error?(&1, assignment, identity))
  end

  defp assert_pinned_unavailable_continuity_denial(continuity_denial, assignment, identity) do
    assert continuity_denial["denial_family"] == "pinned_continuation_unavailable"
    assert continuity_denial["continuity_family"] == "pinned_codex_session"
    assert continuity_denial["pin_mode"] == "hard"
    assert continuity_denial["pin_reason"] == "previous_response_id"
    assert continuity_denial["internal_reason"] == "quota_exhausted"
    assert continuity_denial["pool_upstream_assignment_id"] == assignment.id
    assert continuity_denial["upstream_identity_id"] == identity.id

    assert continuity_denial["operator_action"] ==
             @pinned_continuation_unavailable_operator_action
  end

  defp refute_pinned_denial_metadata_leaks(continuity_denial) do
    refute Map.has_key?(continuity_denial, "previous_response_id")
    refute Map.has_key?(continuity_denial, "previous-response-id")
    refute Map.has_key?(continuity_denial, "previous response id")
    refute Map.has_key?(continuity_denial, "request_body")
    refute Map.has_key?(continuity_denial, "response_body")
    refute Map.has_key?(continuity_denial, "raw_idempotency_key")
    refute Map.has_key?(continuity_denial, "access_token")
    refute Map.has_key?(continuity_denial, "refresh_token")
    refute Map.has_key?(continuity_denial, "cookie")
    refute Map.has_key?(continuity_denial, "auth_json")
    refute Map.has_key?(continuity_denial, "provider_payload")
    refute Map.has_key?(continuity_denial, "websocket_frame")
  end

  defp pinned_unavailable_denial_error?(error, assignment, identity) do
    assignment
    |> pinned_unavailable_denial_error_fields(identity)
    |> Enum.all?(fn {key, value} -> error[key] == value end)
  end

  defp pinned_unavailable_denial_error_fields(assignment, identity) do
    %{
      "kind" => "continuity_denial",
      "code" => "pinned_continuation_unavailable",
      "denial_family" => "pinned_continuation_unavailable",
      "continuity_family" => "pinned_codex_session",
      "pin_mode" => "hard",
      "pin_reason" => "previous_response_id",
      "internal_reason" => "quota_exhausted",
      "pool_upstream_assignment_id" => assignment.id,
      "upstream_identity_id" => identity.id,
      "operator_action" => @pinned_continuation_unavailable_operator_action
    }
  end

  defp assert_no_pinned_denial_mcp_leaks(result) do
    inspected = inspect(result)

    refute inspected =~ "resp_raw_anchor_mcp"
    refute inspected =~ "resp_raw_nested_map_anchor_mcp"
    refute inspected =~ "resp_raw_nested_map_preview_mcp"
    refute inspected =~ "resp_raw_nested_list_anchor_mcp"
    refute inspected =~ Redaction.forbidden_sentinel!(:prompt)
    refute inspected =~ Redaction.forbidden_sentinel!(:request_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:response_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:raw_idempotency_key)
    refute inspected =~ Redaction.forbidden_sentinel!(:access_token)
    refute inspected =~ Redaction.forbidden_sentinel!(:refresh_token)
    refute inspected =~ Redaction.forbidden_sentinel!(:cookies)
    refute inspected =~ Redaction.forbidden_sentinel!(:upstream_auth_json)
    refute inspected =~ Redaction.forbidden_sentinel!(:provider_payload)
    refute inspected =~ Redaction.forbidden_sentinel!(:websocket_frame)
  end

  defp failed_debug_request_fixture(pool, api_key, assignment, attrs) do
    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-contract",
        endpoint: "/backend-api/codex/responses",
        transport: Map.get(attrs, :transport, "websocket"),
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: Map.fetch!(attrs, :correlation_id),
        response_status_code: Map.get(attrs, :response_status_code, 499),
        retry_count: 1,
        request_metadata:
          Map.merge(
            %{
              "codex_session_id" => Map.fetch!(attrs, :codex_session_id),
              "codex_session_key" => Map.fetch!(attrs, :codex_session_key),
              "body" => %{"input" => "raw debug prompt"}
            },
            Map.get(attrs, :request_metadata, %{})
          )
      })
      |> Ecto.Changeset.change(last_error_code: Map.fetch!(attrs, :request_error))
      |> Repo.update!()

    attempt =
      request
      |> attempt_fixture(assignment, %{
        status: "failed",
        retryable: Map.get(attrs, :retryable, true),
        upstream_status_code: Map.get(attrs, :upstream_status_code, 499),
        usage_status: "usage_unknown"
      })
      |> Ecto.Changeset.change(%{
        latency_ms: 321,
        network_error_code: Map.fetch!(attrs, :attempt_error),
        error_message:
          Map.get(attrs, :error_message, "raw attempt error message must stay out of MCP output"),
        response_metadata:
          Map.merge(
            %{"websocket_frame" => "raw debug websocket frame"},
            Map.get(attrs, :response_metadata, %{})
          )
      })
      |> Repo.update!()

    %{request: request, attempt: attempt}
  end

  defp debug_session_fixture(pool, api_key, assignment, session_key) do
    now = debug_timestamp()

    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: session_key,
      conversation_key: "conversation-#{session_key}",
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
  end

  defp debug_turn_fixture(request, attrs) do
    now = debug_timestamp()
    completed_at = Map.get(attrs, :completed_at, now)

    %CodexTurn{
      codex_session_id: Map.fetch!(attrs, :session).id,
      request_id: request.id,
      turn_sequence: Map.fetch!(attrs, :turn_sequence),
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

  defp debug_timestamp, do: ~U[2026-05-26 00:00:00.000000Z]

  defp assert_ref_prefix(value, prefix) do
    assert is_binary(value)
    assert Regex.match?(~r/^#{Regex.escape(prefix)}[a-f0-9]{12}$/, value)
  end

  defp anonymize_refs(map) do
    map
    |> maybe_anonymize_ref("session_ref", :session_ref)
    |> maybe_anonymize_ref("turn_ref", :turn_ref)
    |> maybe_anonymize_ref("final_attempt_ref", :attempt_ref)
    |> maybe_anonymize_ref("attempt_ref", :attempt_ref)
  end

  defp maybe_anonymize_ref(map, key, marker) do
    if is_binary(Map.get(map, key)), do: Map.put(map, key, marker), else: map
  end

  defp assert_terminal_text_contract(text, request, turn) do
    assert text =~ "id=#{request.id}"
    assert text =~ "session=session_"
    assert text =~ "turn=turn_"
    assert text =~ "turn_status=#{turn.status}"
    assert text =~ "terminal="
  end

  defp adversarial_debug_metadata do
    %{
      "raw_headers" => %{
        "authorization" => "Authorization: Bearer sk-example-secret",
        "cookie" => "Cookie: session=secret-cookie"
      },
      "request_body" => "raw prompt: explain private data",
      "raw_idempotency_key" => "idempotency_key=idem-secret-123",
      "websocket_frame" => ~s({"type":"response.output_text.delta","delta":"secret frame"}),
      "safe_debug_marker" => "debug metadata present"
    }
  end

  defp safe_transport_failure_metadata do
    %{
      "transport_failure" => %{
        "exception" => "Mint.TransportError",
        "reason_class" => "Mint.TransportError",
        "reason" => "closed",
        "phase" => "request",
        "pre_visible_output" => false,
        "terminal_seen" => false,
        "text_frame_count" => 0,
        "raw_detail" => "raw transport detail should stay hidden",
        "raw_message" => "raw transport failure message should stay hidden",
        "headers" => %{"authorization" => "Bearer sk-example-hidden"}
      }
    }
  end

  defp assert_debug_fields_present(debug, :list) do
    assert is_map(debug)
    assert is_map(debug["continuity"])
    assert is_map(debug["failure"])
    assert is_map(debug["attempt"])
    assert debug["failure"]["error_code"] == "turn_owner_drained"
    assert debug["attempt"]["attempt_count"] == 1
  end

  defp assert_debug_fields_present(debug, :get) do
    assert is_map(debug)
    assert is_map(debug["continuity"])
    assert is_map(debug["terminal_state"])
    assert is_map(debug["turn"])
    assert [_attempt] = debug["attempts"]
    assert debug["terminal_state"]["state"] == "terminal"
  end

  defp assert_output_omits_adversarial_debug_values(result) do
    assert [%{"type" => "text", "text" => text}] = result["content"]
    structured = result["structuredContent"]
    encoded = Jason.encode!(result)
    inspected = inspect(result)

    refute text =~ Jason.encode!(structured)

    for forbidden <- adversarial_forbidden_strings() do
      refute text =~ forbidden
      refute Jason.encode!(structured) =~ forbidden
      refute encoded =~ forbidden
      refute inspected =~ forbidden
    end
  end

  defp assert_output_omits_transport_failure_raw_values(result) do
    inspected = inspect(result)

    refute inspected =~ "raw transport failure message should stay hidden"
    refute inspected =~ "raw transport detail should stay hidden"
    refute inspected =~ "Bearer sk-example-hidden"
  end

  defp adversarial_forbidden_strings do
    [
      "Authorization: Bearer sk-example-secret",
      "Cookie: session=secret-cookie",
      "raw prompt: explain private data",
      "idempotency_key=idem-secret-123",
      ~s({"type":"response.output_text.delta","delta":"secret frame"}),
      "https://example.com/raw-debug-url",
      "raw stacktrace should stay hidden"
    ]
  end

  defp assert_no_debug_raw_session_values(result) do
    inspected = inspect(result)

    refute inspected =~ "session-example-1"
    refute inspected =~ "session-example-2"
    refute inspected =~ "session-key-example-1"
    refute inspected =~ "session-key-example-2"
    refute inspected =~ "session-example-privacy"
    refute inspected =~ "session-key-example-privacy"
    refute inspected =~ "conversation-example-1"
    refute inspected =~ "raw debug prompt"
    refute inspected =~ "raw debug websocket frame"
    refute inspected =~ "raw attempt error message"
  end

  defp debug_for_request(auth, request) do
    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert %{"status" => "ok", "item" => item} = result["structuredContent"]
    assert item["id"] == request.id
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    item["debug"]
  end

  defp attempt_with_latency(request, assignment, latency_ms, response_metadata \\ %{}) do
    attempt_fixture(request, assignment, %{
      latency_ms: latency_ms,
      upstream_identity_id: assignment.upstream_identity_id,
      response_metadata: response_metadata
    })
  end

  defp unsafe_metadata(extra) do
    Map.merge(
      %{
        "prompt" => Redaction.forbidden_sentinel!(:prompt),
        "raw_headers" => %{"authorization" => Redaction.forbidden_sentinel!(:raw_headers)},
        "request_body" => Redaction.forbidden_sentinel!(:request_body),
        "response_body" => Redaction.forbidden_sentinel!(:response_body),
        "access_token" => Redaction.forbidden_sentinel!(:access_token),
        "raw_idempotency_key" => Redaction.forbidden_sentinel!(:raw_idempotency_key),
        "raw_email_value" => "unsafe.request.log@example.com",
        "raw_ip_value" => "192.0.2.44",
        "raw_url_value" => "https://uploads.example.com/request-log-unsafe",
        "nested" => %{
          "count" => 2,
          "signed_url" => Redaction.forbidden_sentinel!(:upload_url),
          "safe_sentinel" => Redaction.forbidden_sentinel!(:response_body)
        }
      },
      extra
    )
  end

  defp caller_filter_sentinels do
    %{
      "pool_id" => Redaction.forbidden_sentinel!(:raw_pool_api_key),
      "status" => Redaction.forbidden_sentinel!(:prompt),
      "model" => Redaction.forbidden_sentinel!(:raw_headers),
      "request_id" => Redaction.forbidden_sentinel!(:request_body),
      "upstream_identity_id" => Redaction.forbidden_sentinel!(:access_token)
    }
  end

  defp assert_no_unsafe_request_log_text(result) do
    inspected = inspect(result)

    refute inspected =~ "unsafe.request.log@example.com"
    refute inspected =~ "upstream.account@example.com"
    refute inspected =~ "detail.account@example.com"
    refute inspected =~ "192.0.2.44"
    refute inspected =~ "https://uploads.example.com/request-log-unsafe"
    refute inspected =~ Redaction.forbidden_sentinel!(:prompt)
    refute inspected =~ Redaction.forbidden_sentinel!(:raw_headers)
    refute inspected =~ Redaction.forbidden_sentinel!(:request_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:response_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:access_token)
    refute inspected =~ Redaction.forbidden_sentinel!(:raw_idempotency_key)
    refute inspected =~ Redaction.forbidden_sentinel!(:upload_url)
  end
end
