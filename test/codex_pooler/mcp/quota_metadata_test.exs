defmodule CodexPooler.MCP.QuotaMetadataTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      model_quota_window_attrs: 3,
      monthly_only_account_primary_quota_window_attrs: 1,
      primary_quota_window_attrs: 1,
      weekly_quota_window_attrs: 1
    ]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.FakeUpstream
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP

  alias CodexPooler.MCP.{
    OperatorMCPKey,
    OperatorMCPSettings,
    PrivacyMatrix,
    Redaction,
    ToolDispatch
  }

  alias CodexPooler.MCP.Tools.QuotaMetadata.ReadModel
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()
    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _settings} =
             InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(owner, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(owner, %{label: "Task 1 quota DTO"})

    assert {:ok, auth} = MCP.authenticate_token(raw_token)
    scope = Scope.for_user(auth.operator, Accounts.roles_for_user(auth.operator))

    %{auth: auth, owner: owner, scope: scope}
  end

  test "read model maps fresh account and model quota windows", %{scope: scope} do
    pool = pool_fixture(%{name: "Quota DTO Pool"})

    raw_email = Redaction.forbidden_sentinel!(:disallowed_email)
    raw_secret = Redaction.forbidden_sentinel!(:access_token)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: raw_email,
        chatgpt_account_id: "acct-quota-fresh",
        identity_metadata: %{"account_email" => raw_email, "provider_json" => raw_secret},
        plan_family: "team",
        workspace_id: "workspace-quota-alpha",
        workspace_label: "Quota alpha"
      })

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-quota-fresh",
        upstream_model_id: "provider-gpt-quota-fresh"
      })

    account_reset_at =
      DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    model_reset_at =
      DateTime.add(DateTime.utc_now(), 1_800, :second) |> DateTime.truncate(:second)

    assert {:ok, windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 active_limit: 100,
                 credits: 42,
                 reset_at: account_reset_at,
                 used_percent: Decimal.new("58.04")
               }),
               model_quota_window_attrs(model, "primary", %{
                 quota_key: "gpt_quota_fresh",
                 active_limit: 50,
                 credits: 12,
                 reset_at: model_reset_at,
                 used_percent: Decimal.new("76.66")
               })
             ])

    assert length(windows) == 2

    assert %{items: [account], count: 1, limit: 50, offset: 0} = ReadModel.list_accounts(scope)

    assert account.id == identity.id
    assert account.label == "TA***@example.com"
    assert account.stored_account_id == "acct-quota-fresh"
    assert String.starts_with?(account.workspace_ref, "ws:")
    assert account.workspace_label == "Quota alpha"
    assert account.status == "active"
    assert account.plan_family == "team"

    assert account.assignment_summary == %{
             count: 1,
             status: "active",
             summary: "1 active of 1 Pool assignments"
           }

    assert account.quota_summary == %{
             window_count: 2,
             truncated: false,
             freshness_status: "fresh",
             routing_usable: true,
             has_unknown: false,
             has_stale: false
           }

    assert Enum.map(account.quota_windows, & &1.quota_kind) == [
             "account_primary",
             "model_primary"
           ]

    account_window = Enum.find(account.quota_windows, &(&1.quota_kind == "account_primary"))
    assert_dto_keys(account_window)
    assert account_window.quota_scope == "account"
    assert account_window.quota_family == "account"
    assert account_window.model == nil
    assert account_window.upstream_model == nil
    assert account_window.window_minutes == 300
    assert account_window.active_limit == 100
    assert account_window.remaining_value == 42
    assert account_window.credits == 42
    assert account_window.used_percent == 58.0
    assert_iso8601_utc(account_window.reset_at, account_reset_at)
    assert account_window.observed_at =~ "Z"
    assert account_window.freshness_status == "fresh"
    assert account_window.routing_usable == true
    assert account_window.routing_unusable_reason == nil
    assert account_window.source_precision == "observed"

    model_window = Enum.find(account.quota_windows, &(&1.quota_kind == "model_primary"))
    assert_dto_keys(model_window)
    assert model_window.model == "gpt-quota-fresh"
    assert model_window.upstream_model == "provider-gpt-quota-fresh"
    assert model_window.used_percent == 76.7
    assert_iso8601_utc(model_window.reset_at, model_reset_at)

    refute inspect(account) =~ raw_email
    refute inspect(account) =~ raw_secret
    refute inspect(account) =~ "workspace-quota-alpha"
    refute inspect(account) =~ "provider_json"
    refute inspect(account) =~ "metadata"
  end

  test "read model historical at excludes evidence observed after that instant", %{scope: scope} do
    pool = pool_fixture(%{name: "Quota Historical Pool"})

    %{identity: _identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Historical account",
        chatgpt_account_id: "acct-quota-historical"
      })

    as_of = DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)

    identity =
      Repo.get_by!(CodexPooler.Upstreams.Schemas.UpstreamIdentity,
        chatgpt_account_id: "acct-quota-historical"
      )

    # fresh 5h at as_of; a weekly synced two hours later (now) would supersede
    # it at the current clock, but must not exist for the historical view
    assert {:ok, _primary} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 quota_key: "account",
                 quota_scope: "account",
                 quota_family: "account",
                 used_percent: Decimal.new("20"),
                 reset_at: DateTime.add(as_of, 10_800, :second),
                 last_sync_at: as_of,
                 observed_at: as_of
               })
             ])

    assert {:ok, _weekly} =
             QuotaWindows.upsert_quota_windows(identity, [
               weekly_quota_window_attrs(%{
                 source: "codex_usage_api",
                 used_percent: Decimal.new("1"),
                 reset_at: DateTime.add(as_of, 6, :day),
                 last_sync_at: DateTime.add(as_of, 2 * 3600, :second),
                 observed_at: DateTime.add(as_of, 2 * 3600, :second)
               })
             ])

    %{items: [account]} = ReadModel.list_accounts(scope, at: as_of)

    assert [window] = account.quota_windows
    assert window.quota_kind == "account_primary"
    assert window.window_minutes == 300
    refute Enum.any?(account.quota_windows, &(&1.window_minutes == 10_080))
  end

  test "read model reports unknown when no quota windows exist", %{scope: scope} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{chatgpt_account_id: "acct-no-quota"})

    assert %{items: [account]} = ReadModel.list_accounts(scope)

    assert account.id == identity.id
    assert account.quota_windows == []

    assert account.quota_summary == %{
             window_count: 0,
             truncated: false,
             freshness_status: "unknown",
             routing_usable: false,
             has_unknown: true,
             has_stale: false
           }
  end

  test "read model preserves percent only weekly evidence", %{scope: scope} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    reset_at = DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               weekly_quota_window_attrs(%{
                 active_limit: nil,
                 credits: nil,
                 reset_at: reset_at,
                 used_percent: Decimal.new("12.34")
               })
             ])

    assert %{items: [account]} = ReadModel.list_accounts(scope)
    assert [window] = account.quota_windows
    assert_dto_keys(window)
    assert window.quota_kind == "account_secondary"
    assert window.active_limit == nil
    assert window.remaining_value == nil
    assert window.credits == nil
    assert window.used_percent == 12.3
    assert_iso8601_utc(window.reset_at, reset_at)
    assert window.freshness_status == "fresh"
    assert window.routing_usable == true
    assert window.routing_unusable_reason == nil
  end

  test "read model preserves monthly-only account primary semantics", %{scope: scope} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    reset_at = DateTime.add(DateTime.utc_now(), 30, :day) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               monthly_only_account_primary_quota_window_attrs(%{
                 active_limit: nil,
                 credits: nil,
                 reset_at: reset_at,
                 used_percent: Decimal.new("42.5")
               })
             ])

    assert %{items: [account]} = ReadModel.list_accounts(scope)
    assert [window] = account.quota_windows
    assert_dto_keys(window)
    assert window.quota_kind == "account_primary"
    assert window.quota_scope == "account"
    assert window.quota_family == "account"
    assert window.model == nil
    assert window.upstream_model == nil
    assert window.window_minutes == 43_200
    assert window.active_limit == nil
    assert window.remaining_value == nil
    assert window.credits == nil
    assert window.used_percent == 42.5
    assert_iso8601_utc(window.reset_at, reset_at)
    assert window.freshness_status == "fresh"
    assert window.routing_usable == true
    assert window.routing_unusable_reason == nil
    assert window.source_precision == "observed"

    assert account.quota_summary == %{
             window_count: 1,
             truncated: false,
             freshness_status: "fresh",
             routing_usable: true,
             has_unknown: false,
             has_stale: false
           }
  end

  test "read model reports reset only evidence without invented limits", %{scope: scope} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 active_limit: nil,
                 credits: nil,
                 reset_at: reset_at,
                 used_percent: nil
               })
             ])

    assert %{items: [account]} = ReadModel.list_accounts(scope)
    assert [window] = account.quota_windows
    assert_dto_keys(window)
    assert_iso8601_utc(window.reset_at, reset_at)
    assert window.active_limit == nil
    assert window.remaining_value == nil
    assert window.credits == nil
    assert window.used_percent == nil
    assert window.freshness_status == "fresh"
    assert window.routing_usable == false
    assert window.routing_unusable_reason == "unknown_evidence"
  end

  test "read model returns stale expired windows without refresh", %{scope: scope} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    reset_at = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 active_limit: 100,
                 credits: 10,
                 reset_at: reset_at,
                 freshness_state: "stale"
               })
             ])

    before_windows = QuotaWindows.list_quota_windows(identity)
    assert %{items: [account]} = ReadModel.list_accounts(scope)
    after_windows = QuotaWindows.list_quota_windows(identity)

    assert Enum.map(after_windows, & &1.observed_at) == Enum.map(before_windows, & &1.observed_at)
    assert [window] = account.quota_windows
    assert_dto_keys(window)
    assert window.freshness_status == "stale"
    assert window.routing_usable == false
    assert window.routing_unusable_reason == "stale"
    assert account.quota_summary.has_stale == true
    assert account.quota_summary.freshness_status == "stale"
    assert account.quota_summary.routing_usable == false
  end

  test "list upstream quotas returns string keyed structured content with safe filter summary", %{
    auth: auth
  } do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Quota Tool Account",
        chatgpt_account_id: "acct-quota-tool",
        plan_family: "team"
      })

    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 active_limit: 100,
                 credits: 42,
                 reset_at: reset_at,
                 used_percent: Decimal.new("58.0")
               })
             ])

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{
                 "pool_id" => pool.id,
                 "status" => "active",
                 "plan_family" => "team",
                 "freshness_status" => "fresh",
                 "routing_usable" => true,
                 "limit" => 10,
                 "offset" => 0
               },
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 upstream quota metadata records returned; total 1; offset 0"
    assert text =~ "account Quota Tool Account status active account acct-quota-tool plan team"
    assert text =~ "account_primary: 42/100 remaining, 58.0% used"
    assert text =~ "fresh, routing usable"

    structured = result["structuredContent"]
    assert structured["limit"] == 10
    assert structured["offset"] == 0

    assert structured["filters"] == %{
             "applied" => [
               "freshness_status",
               "plan_family",
               "pool_id",
               "routing_usable",
               "status"
             ],
             "count" => 5
           }

    assert [account] = structured["items"]
    assert account["id"] == identity.id
    assert account["stored_account_id"] == "acct-quota-tool"
    assert account["quota_summary"]["routing_usable"] == true
    assert [window] = account["quota_windows"]
    assert window["quota_kind"] == "account_primary"
    assert window["remaining_value"] == 42
    assert window["active_limit"] == 100
    assert Enum.all?(Map.keys(account), &is_binary/1)
    assert Enum.all?(Map.keys(window), &is_binary/1)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "quota metadata tool exposes monthly primary evidence without capacity or raw material", %{
    auth: auth
  } do
    pool = pool_fixture()
    raw_metadata = Redaction.forbidden_sentinel!(:raw_metadata)
    provider_payload = Redaction.forbidden_sentinel!(:provider_payload)
    raw_evidence = Redaction.forbidden_sentinel!(:raw_evidence)
    auth_json = Redaction.forbidden_sentinel!(:upstream_auth_json)
    reset_at = DateTime.add(DateTime.utc_now(), 30, :day) |> DateTime.truncate(:second)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Monthly quota account",
        chatgpt_account_id: "acct-monthly-quota",
        identity_metadata: %{
          "auth_json" => auth_json,
          "raw_metadata" => raw_metadata,
          "provider_payload" => provider_payload
        },
        plan_family: nil
      })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               monthly_only_account_primary_quota_window_attrs(%{
                 active_limit: nil,
                 credits: nil,
                 reset_at: reset_at,
                 used_percent: Decimal.new("42.5"),
                 metadata: %{
                   "raw_metadata" => raw_metadata,
                   "raw_evidence" => raw_evidence,
                   "provider_payload" => provider_payload
                 }
               })
             ])

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_upstream_quota", %{"selector" => identity.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    structured = result["structuredContent"]
    serialized_structured = Jason.encode!(structured)

    for forbidden <- [raw_metadata, provider_payload, raw_evidence, auth_json] do
      refute serialized_structured =~ forbidden
      refute text =~ forbidden
    end

    assert structured["status"] == "ok"
    account = structured["item"]
    assert account["stored_account_id"] == "acct-monthly-quota"
    assert account["quota_summary"]["freshness_status"] == "fresh"
    assert account["quota_summary"]["routing_usable"] == true

    assert [window] = account["quota_windows"]
    assert window["quota_kind"] == "account_primary"
    assert window["window_minutes"] == 43_200
    assert window["model"] == nil
    assert window["upstream_model"] == nil
    assert window["active_limit"] == nil
    assert window["remaining_value"] == nil
    assert window["credits"] == nil
    assert window["used_percent"] == 42.5
    assert_iso8601_utc(window["reset_at"], reset_at)
    assert window["freshness_status"] == "fresh"
    assert window["routing_usable"] == true
    assert window["routing_unusable_reason"] == nil

    assert text =~ "account Monthly quota account status active account acct-monthly-quota plan"
    assert text =~ "account_primary: unknown remaining, 42.5% used"
    refute text =~ "/100 remaining"
    refute serialized_structured =~ ~s("active_limit":100)
    refute serialized_structured =~ ~s("remaining_value":100)
    refute serialized_structured =~ ~s("credits":100)
    refute serialized_structured =~ ~s("metadata")
    refute serialized_structured =~ ~s("evidence")

    assert :ok = Redaction.assert_structured_content_safe!(structured)
    assert :ok = Redaction.assert_text_content_safe!(text)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "quota metadata redacts forbidden upstream material from text and structured content", %{
    auth: auth
  } do
    pool = pool_fixture()
    raw_email = Redaction.forbidden_sentinel!(:disallowed_email)
    access_token = Redaction.forbidden_sentinel!(:access_token)
    auth_json = Redaction.forbidden_sentinel!(:upstream_auth_json)
    raw_metadata = Redaction.forbidden_sentinel!(:raw_metadata)
    provider_payload = Redaction.forbidden_sentinel!(:provider_payload)
    raw_evidence = Redaction.forbidden_sentinel!(:raw_evidence)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: raw_email,
        assignment_label: provider_payload,
        chatgpt_account_id: "acct-quota-redaction",
        identity_metadata: %{
          "account_email" => raw_email,
          "access_token" => access_token,
          "auth_json" => auth_json,
          "raw_metadata" => raw_metadata,
          "provider_payload" => provider_payload
        },
        assignment_metadata: %{
          "raw_evidence" => raw_evidence,
          "provider_payload" => provider_payload
        },
        plan_family: "team"
      })

    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 active_limit: 100,
                 credits: 42,
                 reset_at: reset_at,
                 used_percent: Decimal.new("58.0"),
                 metadata: %{
                   "raw_metadata" => raw_metadata,
                   "raw_evidence" => raw_evidence,
                   "provider_payload" => provider_payload
                 }
               })
             ])

    assert PrivacyMatrix.field_policy!(:upstream_quotas, :quota_windows) == :allowed
    assert PrivacyMatrix.field_policy!(:upstream_quotas, :metadata) == :omitted
    assert PrivacyMatrix.field_policy!(:upstream_quota_windows, :active_limit) == :allowed
    assert PrivacyMatrix.field_policy!(:upstream_quota_windows, :provider_payload) == :omitted

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_upstream_quota", %{"selector" => identity.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    structured = result["structuredContent"]
    serialized_structured = Jason.encode!(structured)

    for forbidden <- [
          raw_email,
          access_token,
          auth_json,
          raw_metadata,
          provider_payload,
          raw_evidence
        ] do
      refute serialized_structured =~ forbidden
      refute text =~ forbidden
    end

    for forbidden_key <- [
          "access_token",
          "auth_json",
          "provider_payload",
          "raw_evidence",
          "raw_metadata"
        ] do
      refute serialized_structured =~ forbidden_key
      refute text =~ forbidden_key
    end

    refute serialized_structured =~ ~s("metadata")
    refute serialized_structured =~ ~s("evidence")

    assert :ok = Redaction.assert_structured_content_safe!(structured)
    assert :ok = Redaction.assert_text_content_safe!(text)
    assert :ok = Redaction.assert_mcp_output_safe!(result)

    assert structured["status"] == "ok"
    account = structured["item"]
    assert account["id"] == identity.id
    assert account["label"] == "TA***@example.com"
    assert account["stored_account_id"] == "acct-quota-redaction"
    assert account["status"] == "active"
    assert account["plan_family"] == "team"
    assert account["assignment_summary"]["count"] == 1
    assert account["quota_summary"]["window_count"] == 1
    assert account["quota_summary"]["freshness_status"] == "fresh"
    assert account["quota_summary"]["routing_usable"] == true

    assert [window] = account["quota_windows"]
    assert window["active_limit"] == 100
    assert window["remaining_value"] == 42
    assert window["credits"] == 42
    assert window["used_percent"] == 58.0
    assert_iso8601_utc(window["reset_at"], reset_at)
    assert {:ok, _observed_at, 0} = DateTime.from_iso8601(window["observed_at"])
    assert window["freshness_status"] == "fresh"
    assert window["routing_usable"] == true
    assert window["routing_unusable_reason"] == nil
    assert window["source_precision"] == "observed"

    assert text =~
             "account TA***@example.com status active account acct-quota-redaction plan team"

    assert text =~ "account_primary: 42/100 remaining, 58.0% used"
    assert text =~ "fresh, routing usable"
  end

  test "list upstream quotas clamps limit and offset", %{auth: auth} do
    pool = pool_fixture()
    %{identity: _identity} = upstream_assignment_fixture(pool)

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{"limit" => 500, "offset" => -7},
               %{auth: auth}
             )

    assert result["structuredContent"]["limit"] == 100
    assert result["structuredContent"]["offset"] == 0

    assert {:ok, second_result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{"limit" => -5, "offset" => 20_000},
               %{auth: auth}
             )

    assert second_result["structuredContent"]["limit"] == 1
    assert second_result["structuredContent"]["offset"] == 10_000
  end

  test "quota tools reject invalid semantic arguments", %{auth: auth} do
    invalid_cases = [
      {%{"status" => "archived"}, "invalid_arguments: Invalid status"},
      {%{"freshness_status" => "old"}, "invalid_arguments: Invalid freshness_status"},
      {%{"routing_usable" => "true"}, "invalid_arguments: Invalid tool arguments"}
    ]

    for {arguments, expected_text} <- invalid_cases do
      assert {:ok, result} =
               ToolDispatch.call("codex_pooler_list_upstream_quotas", arguments, %{auth: auth})

      assert result["isError"] == true
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text == expected_text
      refute Map.has_key?(result, "structuredContent")
      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end
  end

  test "list upstream quotas treats blank optional string filters as omitted", %{auth: auth} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool, %{plan_family: "team"})

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{
                 "pool_id" => "   ",
                 "status" => "",
                 "plan_family" => "   ",
                 "freshness_status" => ""
               },
               %{auth: auth}
             )

    assert result["isError"] == false
    assert result["structuredContent"]["filters"] == %{"applied" => [], "count" => 0}
    assert Enum.any?(result["structuredContent"]["items"], &(&1["id"] == identity.id))
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "quota tools do not echo forbidden caller values in successful outputs", %{auth: auth} do
    sentinel = Redaction.forbidden_sentinel!(:prompt)

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{"pool_id" => sentinel, "plan_family" => sentinel},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => list_text}] = list_result["content"]
    assert list_text == "No upstream quota metadata records matched the visible scope"

    assert list_result["structuredContent"]["filters"] == %{
             "applied" => ["plan_family", "pool_id"],
             "count" => 2
           }

    refute inspect(list_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_upstream_quota", %{"selector" => sentinel}, %{
               auth: auth
             })

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert get_text == "No visible upstream quota metadata record matched the selector"

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "upstream_quota",
             "item" => nil,
             "candidates" => [],
             "message" => "Upstream quota selector did not match"
           }

    refute inspect(get_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "get upstream quota resolves id and stored account id", %{auth: auth} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Quota Detail Account",
        chatgpt_account_id: "acct-quota-detail"
      })

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_get_upstream_quota",
               %{"selector" => "acct-quota-detail"},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 upstream quota metadata record returned"
    assert text =~ "account Quota Detail Account"
    assert result["structuredContent"]["status"] == "ok"
    assert result["structuredContent"]["kind"] == "upstream_quota"
    assert result["structuredContent"]["item"]["id"] == identity.id
    assert result["structuredContent"]["candidates"] == []
    assert result["structuredContent"]["message"] == ""
  end

  test "get upstream quota returns bounded ambiguity candidates", %{auth: auth} do
    first_pool = pool_fixture()
    second_pool = pool_fixture()

    %{identity: first} =
      upstream_assignment_fixture(first_pool, %{account_label: "Shared quota account"})

    %{identity: second} =
      upstream_assignment_fixture(second_pool, %{account_label: "Shared quota account"})

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_get_upstream_quota",
               %{"selector" => "Shared quota account"},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "2 visible upstream quota metadata record candidates matched the selector"

    assert result["structuredContent"]["status"] == "ambiguous"
    assert result["structuredContent"]["kind"] == "upstream_quota"
    assert result["structuredContent"]["item"] == nil
    refute Map.has_key?(result["structuredContent"], "selector")

    candidates = result["structuredContent"]["candidates"]
    assert length(candidates) == 2
    assert MapSet.new(Enum.map(candidates, & &1["id"])) == MapSet.new([first.id, second.id])

    assert Enum.all?(
             candidates,
             &(Map.keys(&1) |> Enum.sort() == [
                 "id",
                 "label",
                 "plan_family",
                 "status",
                 "stored_account_id"
               ])
           )

    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "quota tools exclude evidence assigned only to invisible pools", %{auth: auth} do
    visible_pool = pool_fixture(%{name: "Visible Quota Pool"})
    invisible_pool = pool_fixture(%{name: "Invisible Quota Pool", status: "disabled"})

    %{identity: visible_identity} =
      upstream_assignment_fixture(visible_pool, %{
        account_label: "Visible quota account",
        chatgpt_account_id: "acct-visible-quota"
      })

    %{identity: invisible_identity} =
      upstream_assignment_fixture(invisible_pool, %{
        account_label: "Invisible quota account",
        chatgpt_account_id: "acct-invisible-quota"
      })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(invisible_identity, [
               primary_quota_window_attrs(%{active_limit: 100, credits: 7})
             ])

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_list_upstream_quotas", %{"limit" => 10}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert [item] = result["structuredContent"]["items"]
    assert item["id"] == visible_identity.id
    refute text =~ "Invisible quota account"
    refute Jason.encode!(result["structuredContent"]) =~ invisible_identity.id

    assert {:ok, get_result} =
             ToolDispatch.call(
               "codex_pooler_get_upstream_quota",
               %{"selector" => invisible_identity.id},
               %{auth: auth}
             )

    assert get_result["isError"] == false

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "upstream_quota",
             "item" => nil,
             "candidates" => [],
             "message" => "Upstream quota selector did not match"
           }
  end

  test "pool_id filter resolves against authenticated operator visible pools", %{owner: owner} do
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    active_pool = pool_fixture(%{name: "Visible quota filter pool"})
    disabled_pool = pool_fixture(%{name: "Invisible quota filter pool", status: "disabled"})
    operator_pool_assignment_fixture(admin, active_pool, created_by_user_id: owner.id)

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Quota pool visibility"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    %{identity: identity} =
      upstream_assignment_fixture(active_pool, %{
        account_label: "Visible through active pool",
        chatgpt_account_id: "acct-visible-through-active"
      })

    assert {:ok, _disabled_assignment} =
             PoolAssignments.create_pool_assignment(disabled_pool, identity, %{
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

    assert {:ok, active_result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{"pool_id" => active_pool.id},
               %{auth: admin_auth}
             )

    assert [active_item] = active_result["structuredContent"]["items"]
    assert active_item["id"] == identity.id
    assert active_item["assignment_summary"]["count"] == 1
    assert active_item["assignment_summary"]["summary"] == "1 active of 1 Pool assignments"

    assert {:ok, disabled_result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{"pool_id" => disabled_pool.id},
               %{auth: admin_auth}
             )

    assert disabled_result["isError"] == false
    assert disabled_result["structuredContent"]["items"] == []
    assert disabled_result["structuredContent"]["count"] == 0

    assert disabled_result["structuredContent"]["filters"] == %{
             "applied" => ["pool_id"],
             "count" => 1
           }

    assert [%{"type" => "text", "text" => text}] = disabled_result["content"]
    assert text == "No upstream quota metadata records matched the visible scope"
    refute inspect(disabled_result) =~ disabled_pool.id
    assert :ok = Redaction.assert_mcp_output_safe!(disabled_result)
  end

  test "pool_id filter ignores deleted assignments for visible pools", %{auth: auth} do
    filtered_pool = pool_fixture(%{name: "Deleted assignment filter pool"})
    other_pool = pool_fixture(%{name: "Active visibility pool"})

    %{identity: identity} =
      upstream_assignment_fixture(other_pool, %{
        account_label: "Deleted assignment quota account",
        chatgpt_account_id: "acct-deleted-assignment-quota"
      })

    assert {:ok, _deleted_assignment} =
             PoolAssignments.create_pool_assignment(filtered_pool, identity, %{
               status: "deleted",
               health_status: "disabled",
               eligibility_status: "ineligible"
             })

    assert {:ok, unfiltered_result} =
             ToolDispatch.call("codex_pooler_list_upstream_quotas", %{}, %{auth: auth})

    assert Enum.any?(unfiltered_result["structuredContent"]["items"], &(&1["id"] == identity.id))

    assert {:ok, filtered_result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{"pool_id" => filtered_pool.id},
               %{auth: auth}
             )

    assert filtered_result["isError"] == false
    assert filtered_result["structuredContent"]["items"] == []
    assert filtered_result["structuredContent"]["count"] == 0

    assert filtered_result["structuredContent"]["filters"] == %{
             "applied" => ["pool_id"],
             "count" => 1
           }

    refute Jason.encode!(filtered_result["structuredContent"]) =~ identity.id
    assert :ok = Redaction.assert_mcp_output_safe!(filtered_result)
  end

  test "visible disabled unhealthy and no-active-assignment accounts keep status and no-evidence summaries",
       %{
         auth: auth
       } do
    pool = pool_fixture(%{name: "Visible Edge Pool"})

    %{identity: disabled_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Disabled visible account",
        chatgpt_account_id: "acct-disabled-visible",
        identity_status: "disabled"
      })

    %{identity: unhealthy_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Unhealthy visible account",
        chatgpt_account_id: "acct-unhealthy-visible",
        health_status: "degraded"
      })

    %{identity: no_active_assignment_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Paused assignment visible account",
        chatgpt_account_id: "acct-paused-assignment-visible",
        assignment_status: "paused",
        health_status: "disabled",
        eligibility_status: "ineligible"
      })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(disabled_identity, [
               primary_quota_window_attrs(%{
                 active_limit: 100,
                 credits: 0,
                 used_percent: Decimal.new("100")
               })
             ])

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_list_upstream_quotas", %{"limit" => 10}, %{
               auth: auth
             })

    items_by_id = Map.new(result["structuredContent"]["items"], &{&1["id"], &1})

    disabled = Map.fetch!(items_by_id, disabled_identity.id)
    assert disabled["status"] == "disabled"
    assert disabled["quota_summary"]["window_count"] == 1
    assert disabled["quota_summary"]["routing_usable"] == false
    assert [disabled_window] = disabled["quota_windows"]
    assert disabled_window["remaining_value"] == 0
    assert disabled_window["routing_unusable_reason"] == "exhausted"

    unhealthy = Map.fetch!(items_by_id, unhealthy_identity.id)
    assert unhealthy["status"] == "active"
    assert unhealthy["assignment_summary"]["summary"] == "1 active of 1 Pool assignments"
    assert unhealthy["quota_windows"] == []
    assert unhealthy["quota_summary"]["freshness_status"] == "unknown"
    assert unhealthy["quota_summary"]["routing_usable"] == false

    no_active_assignment = Map.fetch!(items_by_id, no_active_assignment_identity.id)
    assert no_active_assignment["status"] == "active"

    assert no_active_assignment["assignment_summary"]["summary"] ==
             "0 active of 1 Pool assignments"

    assert no_active_assignment["quota_windows"] == []
    assert no_active_assignment["quota_summary"]["has_unknown"] == true
  end

  test "stale quota tool calls do not refresh or create side effects", %{auth: auth} do
    pool = pool_fixture()

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.json_response(%{"usage" => []}))
    on_exit(fn -> FakeUpstream.stop(upstream) end)

    observed_at = DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.truncate(:second)
    reset_at = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct-stale-no-refresh",
        identity_metadata: %{"base_url" => FakeUpstream.url(upstream)}
      })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 active_limit: 100,
                 credits: 10,
                 reset_at: reset_at,
                 observed_at: observed_at,
                 freshness_state: "stale"
               })
             ])

    before_oban_count = Repo.aggregate(Oban.Job, :count)
    before_request_count = Repo.aggregate(Request, :count)
    before_fake_count = FakeUpstream.count(upstream)
    before_windows = QuotaWindows.list_quota_windows(identity)
    before_observed_at = Enum.map(before_windows, & &1.observed_at)

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_get_upstream_quota",
               %{"selector" => identity.id},
               %{auth: auth}
             )

    assert result["isError"] == false

    assert get_in(result, ["structuredContent", "item", "quota_summary", "freshness_status"]) ==
             "stale"

    after_windows = QuotaWindows.list_quota_windows(identity)
    assert Repo.aggregate(Oban.Job, :count) == before_oban_count
    assert Repo.aggregate(Request, :count) == before_request_count
    assert FakeUpstream.count(upstream) == before_fake_count
    assert length(after_windows) == length(before_windows)
    assert Enum.map(after_windows, & &1.observed_at) == before_observed_at
  end

  test "list upstream quotas paginates deterministically after all visible accounts", %{
    auth: auth
  } do
    pool = pool_fixture(%{name: "Pagination Quota Pool"})

    for index <- 1..105 do
      upstream_assignment_fixture(pool, %{
        account_label: "Page Account #{String.pad_leading(Integer.to_string(index), 3, "0")}",
        chatgpt_account_id: "acct-page-#{index}"
      })
    end

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_upstream_quotas",
               %{"limit" => 5, "offset" => 100},
               %{auth: auth}
             )

    structured = result["structuredContent"]
    assert structured["count"] == 105
    assert structured["limit"] == 5
    assert structured["offset"] == 100

    assert Enum.map(structured["items"], & &1["label"]) == [
             "Page Account 101",
             "Page Account 102",
             "Page Account 103",
             "Page Account 104",
             "Page Account 105"
           ]
  end

  test "model quota evidence keeps missing model metadata explicit", %{scope: scope} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-edge-model",
        upstream_model_id: "provider-edge-model"
      })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               model_quota_window_attrs(model, "primary", %{
                 model: nil,
                 upstream_model: nil,
                 quota_key: "provider-edge-model",
                 active_limit: 50,
                 credits: 25
               })
             ])

    assert %{items: [account]} = ReadModel.list_accounts(scope)
    assert [window] = account.quota_windows
    assert_dto_keys(window)
    assert window.quota_scope == "model"
    assert window.quota_family == "codex_model"
    assert window.quota_kind == "unknown"
    assert window.model == nil
    assert window.upstream_model == nil
    assert window.remaining_value == 25
    assert window.active_limit == 50
  end

  defp assert_dto_keys(window) do
    assert Map.keys(window) |> Enum.sort() ==
             [
               :active_limit,
               :credits,
               :freshness_status,
               :model,
               :observed_at,
               :quota_family,
               :quota_kind,
               :quota_scope,
               :remaining_value,
               :reset_at,
               :routing_unusable_reason,
               :routing_usable,
               :source_precision,
               :upstream_model,
               :used_percent,
               :window_minutes
             ]
  end

  defp assert_iso8601_utc(actual, expected) do
    assert {:ok, actual_datetime, 0} = DateTime.from_iso8601(actual)
    assert DateTime.compare(actual_datetime, expected) == :eq
    assert String.ends_with?(actual, "Z")
  end
end
