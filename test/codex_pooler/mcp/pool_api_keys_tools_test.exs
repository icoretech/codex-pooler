defmodule CodexPooler.MCP.PoolApiKeysToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP

  alias CodexPooler.MCP.{
    OperatorMCPKey,
    OperatorMCPSettings,
    PrivacyMatrix,
    Redaction,
    ToolDispatch
  }

  alias CodexPooler.Repo

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
             MCP.create_operator_token(owner, %{label: "MCP operator"})

    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    %{auth: auth, owner: owner, raw_token: raw_token}
  end

  test "lists Pool API key metadata without raw key material", %{auth: auth, owner: owner} do
    pool = pool_fixture(%{name: "API Key Pool"})
    raw_sentinel = Redaction.forbidden_sentinel!(:raw_pool_api_key)
    body_sentinel = Redaction.forbidden_sentinel!(:request_body)

    assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
             Access.create_api_key(Scope.for_user(owner), pool, %{
               display_name: Redaction.forbidden_sentinel!(:disallowed_email),
               allowed_model_identifiers: ["gpt-mcp-test"],
               enforced_reasoning_effort: "minimal",
               metadata: %{
                 "labels" => ["safe"],
                 "operator_notes" => raw_sentinel <> body_sentinel
               },
               default_policy: %{"max_requests_per_minute" => 5}
             })

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_pool_api_keys",
               %{"pool_selector" => pool.slug, "limit" => 10},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 Pool API key metadata records returned"
    assert text =~ "name=RE***@example.com"
    assert text =~ "status=active"
    assert text =~ "prefix=#{api_key.key_prefix}"
    assert text =~ "pool=#{pool.slug}"
    assert text =~ "policy=selected models; 1 active policy bindings"
    assert text =~ "usage=last-used metadata only"

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "count",
             "items",
             "limit",
             "status"
           ]

    assert [presented] = result["structuredContent"]["items"]
    assert presented["id"] == api_key.id
    assert presented["pool_slug"] == pool.slug
    assert presented["display_name"] == "RE***@example.com"
    assert presented["key_prefix"] == api_key.key_prefix
    assert presented["allowed_model_identifiers"] == ["gpt-mcp-test"]
    assert presented["enforced_reasoning_effort"] == "minimal"
    assert presented["reasoning_policy_mode"] == "always_use"
    refute Map.has_key?(presented, "maximum_reasoning_effort")
    assert presented["policy_summary"]["count"] == 1

    refute inspect(result) =~ raw_key
    refute inspect(result) =~ raw_sentinel
    refute inspect(result) =~ body_sentinel
    refute inspect(result) =~ Base.encode16(api_key.key_hash)
    refute inspect(result) =~ "key_hash"
    refute inspect(result) =~ "raw_pool_api_key"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "Pool API key metadata exposes derived maximum policy without arbitrary metadata", %{
    auth: auth,
    owner: owner
  } do
    pool = pool_fixture(%{name: "Maximum Policy Pool"})
    metadata_sentinel = Redaction.forbidden_sentinel!(:raw_metadata)

    assert {:ok, %{api_key: api_key}} =
             Access.create_api_key(Scope.for_user(owner), pool, %{
               display_name: "Maximum reasoning key",
               maximum_reasoning_effort: "high",
               metadata: %{"arbitrary_policy" => metadata_sentinel}
             })

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_get_pool_api_key",
               %{"selector" => api_key.key_prefix},
               %{auth: auth}
             )

    item = result["structuredContent"]["item"]
    assert item["reasoning_policy_mode"] == "allow_up_to"
    assert item["maximum_reasoning_effort"] == "high"
    refute Map.has_key?(item, "enforced_reasoning_effort")
    refute inspect(result) =~ metadata_sentinel
    refute inspect(result) =~ "arbitrary_policy"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log MCP privacy projection does not expand with API key policy fields" do
    assert PrivacyMatrix.project!(:request_logs, %{
             reasoning_policy_mode: "allow_up_to",
             configured_effort: "high",
             maximum_reasoning_effort: "high",
             enforced_reasoning_effort: "medium"
           }) == %{}
  end

  test "gets one Pool API key by prefix", %{auth: auth} do
    pool = pool_fixture()

    %{api_key: api_key, raw_key: raw_key} =
      active_api_key_fixture(pool, %{display_name: "Lookup key"})

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_get_pool_api_key",
               %{"selector" => api_key.key_prefix},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 Pool API key metadata record returned"
    assert text =~ "id=#{api_key.id}"
    assert text =~ "name=Lookup key"
    assert text =~ "status=active"
    assert text =~ "prefix=#{api_key.key_prefix}"
    assert text =~ "pool=#{pool.slug}"
    assert text =~ "policy=all models; 1 active policy bindings"
    assert text =~ "usage=last-used metadata only"
    assert result["structuredContent"]["status"] == "ok"

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "candidates",
             "item",
             "kind",
             "message",
             "status"
           ]

    assert result["structuredContent"]["kind"] == "pool_api_key"
    assert result["structuredContent"]["item"]["id"] == api_key.id
    refute inspect(result) =~ raw_key
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "Pool API key list empty text and not-found text do not echo caller sentinels", %{
    auth: auth
  } do
    sentinel = Redaction.forbidden_sentinel!(:prompt)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_pool_api_keys", %{"query" => sentinel}, %{
               auth: auth
             })

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = list_result["content"]
    assert text == "No Pool API key metadata records matched the visible scope"

    assert list_result["structuredContent"] == %{
             "status" => "ok",
             "count" => 0,
             "limit" => 25,
             "items" => []
           }

    refute inspect(list_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_pool_api_key", %{"selector" => sentinel}, %{
               auth: auth
             })

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert get_text == "No visible Pool API key metadata record matched the selector"

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "pool_api_key",
             "item" => nil,
             "candidates" => [],
             "message" => "Pool API key selector did not match"
           }

    refute inspect(get_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "Pool API key text truncates long labels while preserving structured content", %{
    auth: auth
  } do
    pool = pool_fixture()
    long_name = String.duplicate("Long API Key Label ", 12)

    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: long_name})

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_get_pool_api_key",
               %{"selector" => api_key.key_prefix},
               %{auth: auth}
             )

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "name=#{String.slice(long_name, 0, 120)}"
    refute text =~ long_name
    assert result["structuredContent"]["item"]["display_name"] == String.trim(long_name)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "scoped admin Pool API key tools return assigned-pool keys only", %{owner: owner} do
    visible_pool = pool_fixture(%{name: "Visible Key Pool"})
    hidden_pool = pool_fixture(%{name: "Hidden Key Pool"})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    %{api_key: visible_key} =
      active_api_key_fixture(visible_pool, %{display_name: "Shared scoped key"})

    %{api_key: hidden_key} =
      active_api_key_fixture(hidden_pool, %{display_name: "Shared scoped key"})

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Scoped key MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_pool_api_keys", %{"limit" => 10}, %{
               auth: admin_auth
             })

    assert [%{"id" => visible_id}] = list_result["structuredContent"]["items"]
    assert visible_id == visible_key.id
    refute Jason.encode!(list_result["structuredContent"]) =~ hidden_key.id

    assert {:ok, hidden_result} =
             ToolDispatch.call("codex_pooler_get_pool_api_key", %{"selector" => hidden_key.id}, %{
               auth: admin_auth
             })

    assert hidden_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "pool_api_key",
             "item" => nil,
             "candidates" => [],
             "message" => "Pool API key selector did not match"
           }

    assert {:ok, ambiguous_result} =
             ToolDispatch.call(
               "codex_pooler_get_pool_api_key",
               %{"selector" => "Shared scoped key"},
               %{
                 auth: admin_auth
               }
             )

    assert ambiguous_result["structuredContent"]["status"] == "ok"
    assert ambiguous_result["structuredContent"]["item"]["id"] == visible_key.id
    assert ambiguous_result["structuredContent"]["candidates"] == []
    refute inspect(ambiguous_result) =~ hidden_key.id
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(hidden_result)
    assert :ok = Redaction.assert_mcp_output_safe!(ambiguous_result)
  end

  test "ambiguous Pool API key display names return candidates", %{auth: auth} do
    first_pool = pool_fixture()
    second_pool = pool_fixture()
    %{api_key: first} = active_api_key_fixture(first_pool, %{display_name: "Shared key"})
    %{api_key: second} = active_api_key_fixture(second_pool, %{display_name: "Shared key"})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_pool_api_key", %{"selector" => "Shared key"}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert result["structuredContent"]["status"] == "ambiguous"

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "candidates",
             "item",
             "kind",
             "message",
             "status"
           ]

    assert result["structuredContent"]["kind"] == "pool_api_key"
    assert result["structuredContent"]["item"] == nil
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "2 visible Pool API key metadata record candidates matched the selector"
    assert text =~ "id=#{first.id}"
    assert text =~ "name=Shared key"
    assert text =~ "prefix=#{first.key_prefix}"
    assert text =~ "status=active"

    assert Enum.map(result["structuredContent"]["candidates"], & &1["id"]) == [
             first.id,
             second.id
           ]

    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end
end
