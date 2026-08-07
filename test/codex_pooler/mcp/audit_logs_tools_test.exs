defmodule CodexPooler.MCP.AuditLogsToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolDispatch}
  alias CodexPooler.Postgres.INET
  alias CodexPooler.Repo

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

  test "lists audit-log metadata as bounded sanitized readable rows", %{auth: auth, user: user} do
    pool = pool_fixture(%{slug: "mcp-audit-logs", name: "MCP Audit Logs"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP audit key"})
    request = request_fixture(%{pool: pool, api_key: api_key})
    {:ok, ip_address} = INET.cast("198.51.100.42")

    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    event =
      %AuditEvent{
        occurred_at: occurred_at,
        actor_type: "user",
        actor_user_id: user.id,
        pool_id: pool.id,
        request_id: request.id,
        action: "operator.update",
        target_type: "user",
        target_id: user.id,
        outcome: "success",
        correlation_id: "mcp-audit-correlation",
        ip_address: ip_address,
        details: unsafe_details(%{"status" => "changed"})
      }
      |> Repo.insert!()

    _other =
      %AuditEvent{
        occurred_at: DateTime.add(occurred_at, -60, :second),
        actor_type: "system",
        pool_id: pool.id,
        action: "pool.update",
        target_type: "pool",
        target_id: pool.id,
        outcome: "success",
        details: %{"status" => "safe"}
      }
      |> Repo.insert!()

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_audit_logs",
               %{"pool_id" => pool.id, "action" => "operator.update", "limit" => 10},
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

    assert %{"items" => [item], "total" => 1, "limit" => 10, "offset" => 0} = structured
    assert structured["nextOffset"] == nil

    assert item["id"] == event.id
    assert item["action"] == "operator.update"
    assert item["outcome"] == "success"
    assert item["pool_id"] == pool.id
    assert item["pool_slug"] == "mcp-audit-logs"
    assert item["pool_name"] == "MCP Audit Logs"
    assert item["request_id"] == request.id
    assert item["correlation_id"] == "mcp-audit-correlation"
    assert item["actor_user_email"] =~ "***@"
    assert item["ip_address"] == "198.51.100.xxx"
    assert item["actor_summary"] == %{"summary" => "user #{String.slice(user.id, 0, 8)}"}
    assert item["target_summary"] == %{"summary" => "user #{String.slice(user.id, 0, 8)}"}
    assert item["details"]["status"] == "changed"
    assert item["details"]["safe_sentinel"] == "[REDACTED]"
    assert item["details"]["nested"]["count"] == 3
    assert item["details"]["nested"]["email"] == "[REDACTED]"
    refute Map.has_key?(item["details"], "before")
    refute Map.has_key?(item["details"], "after")
    refute Map.has_key?(item["details"], "raw_headers")
    refute Map.has_key?(item["details"], "request_body")
    refute Map.has_key?(item["details"], "response_body")
    refute Map.has_key?(item["details"], "access_token")
    refute Map.has_key?(item["details"]["nested"], "filename")

    assert text =~
             "1 audit events returned; total 1; offset 0; actions operator.update:1; outcomes success:1"

    assert text =~ "occurred_at=#{item["occurred_at"]}"
    assert text =~ "action=operator.update"
    assert text =~ "outcome=success"
    assert text =~ "actor=user #{String.slice(user.id, 0, 8)}"
    assert text =~ "target=user #{String.slice(user.id, 0, 8)}"
    assert text =~ "pool=mcp-audit-logs"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    assert text =~ "details=5 safe detail keys"
    refute text =~ "request="
    refute text =~ "correlation="

    assert_no_unsafe_audit_log_text(result)
  end

  test "audit-log list text handles empty results without echoing caller filters", %{auth: auth} do
    sentinels = caller_filter_sentinels()

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_audit_logs",
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
    assert text == "0 audit events returned; total 0; offset 5; actions none; outcomes none"

    for {_field, sentinel} <- sentinels do
      refute text =~ sentinel
      refute inspect(result) =~ sentinel
    end

    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "audit-log list text includes system and pool events with nil optional fields", %{
    auth: auth,
    user: user
  } do
    pool = pool_fixture(%{slug: "mcp-audit-pool-event", name: "MCP Audit Pool Event"})
    base_time = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    pool_event =
      %AuditEvent{
        occurred_at: base_time,
        actor_type: "user",
        actor_user_id: user.id,
        pool_id: pool.id,
        action: "pool.update",
        target_type: "pool",
        target_id: pool.id,
        outcome: "success",
        details: %{"status" => "pool event"}
      }
      |> Repo.insert!()

    system_event =
      %AuditEvent{
        occurred_at: DateTime.add(base_time, 1, :second),
        actor_type: "system",
        action: "system.rotate",
        target_type: "instance_settings",
        outcome: "success",
        details: %{}
      }
      |> Repo.insert!()

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_audit_logs",
               %{"limit" => 2},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert [first_item, second_item] = result["structuredContent"]["items"]
    assert Enum.map([first_item, second_item], & &1["id"]) == [system_event.id, pool_event.id]

    assert text =~ "2 audit events returned; total 5; offset 0"
    assert text =~ "action=system.rotate"
    assert text =~ "actor=system"
    assert text =~ "target=instance_settings"
    assert text =~ "pool=system"
    assert text =~ "details=0 safe detail keys"
    assert text =~ "action=pool.update"
    assert text =~ "pool=mcp-audit-pool-event"
    refute text =~ "request="
    refute text =~ "correlation="
    refute text =~ "nil"
  end

  test "audit-log list text is capped when structured content contains more than ten rows", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-audit-over-limit", name: "MCP Audit Over Limit"})
    base_time = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for index <- 1..12 do
      %AuditEvent{
        occurred_at: DateTime.add(base_time, index, :second),
        actor_type: "system",
        pool_id: pool.id,
        action: "pool.audit_over_limit",
        target_type: "pool",
        target_id: pool.id,
        outcome: "success",
        details: %{"index" => index}
      }
      |> Repo.insert!()
    end

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_audit_logs",
               %{"pool_id" => pool.id, "action" => "pool.audit_over_limit", "limit" => 12},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert length(result["structuredContent"]["items"]) == 12
    assert result["structuredContent"]["total"] == 12

    assert [%{"type" => "text", "text" => text}] = result["content"]

    assert text =~
             "10 audit events returned; total 12; offset 0; actions pool.audit_over_limit:12; outcomes success:12"

    assert text =~ "- ... 2 more rows omitted from text; use structuredContent or refine filters"

    row_count =
      text
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "- occurred_at="))

    assert row_count == 10
    refute text =~ Jason.encode!(result["structuredContent"])
  end

  test "audit-log tool rejects malformed semantic filters without echoing date sentinels", %{
    auth: auth
  } do
    date_sentinel = "#{Redaction.forbidden_sentinel!(:request_body)}-not-a-date"

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_audit_logs",
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

  test "gets one audit-log metadata record with readable detail fields and safe detail summary",
       %{
         auth: auth,
         user: user
       } do
    pool = pool_fixture(%{slug: "mcp-audit-log-detail", name: "MCP Audit Log Detail"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP audit detail key"})
    request = request_fixture(%{pool: pool, api_key: api_key})
    {:ok, ip_address} = INET.cast("198.51.100.77")
    long_detail = String.duplicate("safe-detail-value", 30)

    event =
      %AuditEvent{
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        actor_type: "user",
        actor_user_id: user.id,
        pool_id: pool.id,
        request_id: request.id,
        action: "operator.update",
        target_type: "user",
        target_id: user.id,
        outcome: "success",
        correlation_id: "mcp-audit-detail-correlation",
        ip_address: ip_address,
        details: unsafe_details(%{"status" => "detail changed", "long_detail" => long_detail})
      }
      |> Repo.insert!()

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_audit_log", %{"id" => event.id}, %{auth: auth})

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    refute text =~ Jason.encode!(result["structuredContent"])

    assert %{"status" => "ok", "kind" => "audit_log", "item" => item} =
             result["structuredContent"]

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "candidates",
             "item",
             "kind",
             "message",
             "status"
           ]

    assert item["id"] == event.id
    assert item["pool_id"] == pool.id
    assert item["outcome"] == "success"
    assert item["action"] == "operator.update"
    assert item["ip_address"] == "198.51.100.xxx"
    assert item["request_id"] == request.id
    assert item["correlation_id"] == "mcp-audit-detail-correlation"
    assert item["details"]["status"] == "detail changed"
    assert item["details"]["long_detail"] == String.slice(long_detail, 0, 200)
    assert item["details"]["safe_sentinel"] == "[REDACTED]"
    assert item["details"]["nested"]["count"] == 3
    assert item["details"]["nested"]["email"] == "[REDACTED]"
    refute Map.has_key?(item["details"], "before")

    assert text =~ "1 audit event returned"
    assert text =~ "occurred_at=#{item["occurred_at"]}"
    assert text =~ "action=operator.update"
    assert text =~ "outcome=success"
    assert text =~ "actor=user #{String.slice(user.id, 0, 8)}"
    assert text =~ "target=user #{String.slice(user.id, 0, 8)}"
    assert text =~ "pool=mcp-audit-log-detail"
    assert text =~ "details=6 safe detail keys"
    assert text =~ "request=#{request.id}"
    assert text =~ "correlation=mcp-audit-detail-correlation"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    refute text =~ long_detail

    assert_no_unsafe_audit_log_text(result)
  end

  test "audit-log MCP output hides IPv4 and IPv6 immediate peer provenance", %{
    auth: auth,
    user: user
  } do
    ipv4_peer = "192.0.2.91"
    ipv6_peer = "2001:db8::91"

    event =
      %AuditEvent{
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        actor_type: "user",
        actor_user_id: user.id,
        action: "auth.login",
        target_type: "session",
        target_id: Ecto.UUID.generate(),
        outcome: "success",
        details: %{
          "ipv4_provenance" => %{
            "immediate_peer_ip" => ipv4_peer,
            "client_ip_source" => "x_forwarded_for",
            "inspected_hops" => 2
          },
          "ipv6_provenance" => %{
            "immediate_peer_ip" => ipv6_peer,
            "client_ip_source" => "x_real_ip",
            "inspected_hops" => 1
          }
        }
      }
      |> Repo.insert!()

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_audit_log", %{"id" => event.id}, %{auth: auth})

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)

    details = result["structuredContent"]["item"]["details"]
    assert details["ipv4_provenance"]["immediate_peer_ip"] == "[REDACTED]"
    assert details["ipv6_provenance"]["immediate_peer_ip"] == "[REDACTED]"
    assert details["ipv4_provenance"]["client_ip_source"] == "x_forwarded_for"
    assert details["ipv6_provenance"]["inspected_hops"] == 1
    refute inspect(result) =~ ipv4_peer
    refute inspect(result) =~ ipv6_peer
  end

  test "audit-log get text handles nil optional fields and missing selectors", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-audit-log-nil", name: "MCP Audit Log Nil"})

    event =
      %AuditEvent{
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        actor_type: "system",
        pool_id: pool.id,
        action: "pool.nil_fields",
        target_type: "pool",
        target_id: pool.id,
        outcome: "success",
        details: %{}
      }
      |> Repo.insert!()

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_audit_log", %{"id" => event.id}, %{auth: auth})

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 audit event returned"
    assert text =~ "occurred_at="
    assert text =~ "action=pool.nil_fields"
    assert text =~ "outcome=success"
    assert text =~ "actor=system"
    assert text =~ "target=pool #{String.slice(pool.id, 0, 8)}"
    assert text =~ "pool=mcp-audit-log-nil"
    assert text =~ "details=0 safe detail keys"
    refute text =~ "request="
    refute text =~ "correlation="
    missing_selector = "sk-cxp-secret-missing-selector"

    assert {:ok, missing} =
             ToolDispatch.call("codex_pooler_get_audit_log", %{"id" => missing_selector}, %{
               auth: auth
             })

    assert missing["isError"] == false

    assert missing["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "audit_log",
             "item" => nil,
             "candidates" => [],
             "message" => "audit_log selector did not match"
           }

    assert [%{"type" => "text", "text" => missing_text}] = missing["content"]
    assert missing_text == "No visible audit event matched the selector"
    refute inspect(missing) =~ missing_selector
    assert :ok = Redaction.assert_mcp_output_safe!(missing)
  end

  defp unsafe_details(extra) do
    Map.merge(
      %{
        "before" => %{"email" => Redaction.forbidden_sentinel!(:audit_before_blob)},
        "after" => %{"email" => Redaction.forbidden_sentinel!(:audit_after_blob)},
        "safe_sentinel" => Redaction.forbidden_sentinel!(:prompt),
        "request_body" => Redaction.forbidden_sentinel!(:request_body),
        "response_body" => Redaction.forbidden_sentinel!(:response_body),
        "access_token" => Redaction.forbidden_sentinel!(:access_token),
        "raw_idempotency_key" => Redaction.forbidden_sentinel!(:raw_idempotency_key),
        "contact" => "dirty.details@example.com",
        "client_ip" => "192.0.2.55",
        "nested" => %{
          "count" => 3,
          "filename" => Redaction.forbidden_sentinel!(:filename),
          "email" => "nested.details@example.com"
        },
        "raw_headers" => %{"cookie" => Redaction.forbidden_sentinel!(:cookies)}
      },
      extra
    )
  end

  defp caller_filter_sentinels do
    %{
      "pool_id" => Redaction.forbidden_sentinel!(:raw_pool_api_key),
      "outcome" => Redaction.forbidden_sentinel!(:prompt),
      "actor_type" => Redaction.forbidden_sentinel!(:raw_headers),
      "actor" => Redaction.forbidden_sentinel!(:request_body),
      "action" => Redaction.forbidden_sentinel!(:access_token),
      "target" => Redaction.forbidden_sentinel!(:response_body),
      "request" => Redaction.forbidden_sentinel!(:raw_idempotency_key),
      "date_from" => "2999-01-01",
      "date_to" => "2999-01-02"
    }
  end

  defp assert_no_unsafe_audit_log_text(result) do
    inspected = inspect(result)

    refute inspected =~ "dirty.details@example.com"
    refute inspected =~ "nested.details@example.com"
    refute inspected =~ "192.0.2.55"
    refute inspected =~ Redaction.forbidden_sentinel!(:audit_before_blob)
    refute inspected =~ Redaction.forbidden_sentinel!(:audit_after_blob)
    refute inspected =~ Redaction.forbidden_sentinel!(:prompt)
    refute inspected =~ Redaction.forbidden_sentinel!(:request_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:response_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:access_token)
    refute inspected =~ Redaction.forbidden_sentinel!(:raw_idempotency_key)
    refute inspected =~ Redaction.forbidden_sentinel!(:filename)
    refute inspected =~ Redaction.forbidden_sentinel!(:cookies)
  end
end
