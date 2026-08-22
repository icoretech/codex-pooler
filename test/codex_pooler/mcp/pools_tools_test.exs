defmodule CodexPooler.MCP.PoolsToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolDispatch}
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

  test "lists bounded Pool metadata with counts and no Pool API key material", %{auth: auth} do
    pool = pool_fixture(%{name: "MCP test pool"})
    %{raw_key: raw_key, api_key: api_key} = active_api_key_fixture(pool)
    active_upstream_assignment_fixture(pool, %{account_label: "MCP test upstream"})

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_pools",
               %{"query" => pool.slug, "limit" => 10},
               %{
                 auth: auth
               }
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 Pool metadata records returned"
    assert text =~ "name=MCP test pool"
    assert text =~ "slug=#{pool.slug}"
    assert text =~ "status=active"
    assert text =~ "upstreams=1"
    assert text =~ "api_keys=1"
    assert text =~ "routing=routing settings unavailable"

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "count",
             "items",
             "limit",
             "status"
           ]

    assert [presented] = result["structuredContent"]["items"]
    assert presented["id"] == pool.id
    assert presented["slug"] == pool.slug
    assert presented["api_key_count"] == 1
    assert presented["upstream_count"] == 1
    assert presented["routing_summary"]["summary"] =~ "routing"

    refute inspect(result) =~ raw_key
    refute inspect(result) =~ Base.encode16(api_key.key_hash)
    refute inspect(result) =~ "key_hash"
    refute inspect(result) =~ "raw_pool_api_key"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "gets one Pool by slug", %{auth: auth} do
    pool = pool_fixture(%{name: "Lookup Pool"})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_pool", %{"selector" => pool.slug}, %{auth: auth})

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 Pool metadata record returned"
    assert text =~ "id=#{pool.id}"
    assert text =~ "name=Lookup Pool"
    assert text =~ "slug=#{pool.slug}"
    assert text =~ "status=active"
    assert text =~ "upstreams=0"
    assert text =~ "api_keys=0"
    assert result["structuredContent"]["status"] == "ok"

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "candidates",
             "item",
             "kind",
             "message",
             "status"
           ]

    assert result["structuredContent"]["kind"] == "pool"
    assert result["structuredContent"]["item"]["id"] == pool.id
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "Pool list empty text and not-found text do not echo caller sentinels", %{auth: auth} do
    sentinel = Redaction.forbidden_sentinel!(:prompt)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_pools", %{"query" => sentinel}, %{auth: auth})

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = list_result["content"]
    assert text == "No Pool metadata records matched the visible scope"

    assert list_result["structuredContent"] == %{
             "status" => "ok",
             "count" => 0,
             "limit" => 25,
             "items" => []
           }

    refute inspect(list_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_pool", %{"selector" => sentinel}, %{auth: auth})

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert get_text == "No visible Pool metadata record matched the selector"

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "pool",
             "item" => nil,
             "candidates" => [],
             "message" => "Pool selector did not match"
           }

    refute inspect(get_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "Pool text truncates long labels while preserving structured content", %{auth: auth} do
    long_name = String.duplicate("Long Pool Label ", 12)
    pool = pool_fixture(%{name: long_name})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_pool", %{"selector" => pool.slug}, %{auth: auth})

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "name=#{String.slice(long_name, 0, 120)}"
    refute text =~ long_name
    assert result["structuredContent"]["item"]["name"] == long_name
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "ambiguous Pool selectors return candidates instead of first match", %{auth: auth} do
    first = pool_fixture(%{name: "Ambiguous Pool"})
    second = pool_fixture(%{name: "Ambiguous Pool"})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_pool", %{"selector" => "Ambiguous Pool"}, %{
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

    assert result["structuredContent"]["kind"] == "pool"
    assert result["structuredContent"]["item"] == nil
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "2 visible Pool metadata record candidates matched the selector"
    assert text =~ "id=#{first.id}"
    assert text =~ "slug=#{first.slug}"
    assert text =~ "name=Ambiguous Pool"
    assert text =~ "status=active"
    candidates = result["structuredContent"]["candidates"]
    assert Enum.map(candidates, & &1["id"]) == [first.id, second.id]
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "unassigned scoped admin Pool tools return empty list and not-found get envelope", %{
    owner: owner
  } do
    hidden_pool = pool_fixture(%{name: "Unassigned Hidden Pool"})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Unassigned pool MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_pools", %{"limit" => 10}, %{auth: admin_auth})

    assert list_result["isError"] == false
    assert list_result["structuredContent"]["items"] == []
    assert list_result["structuredContent"]["count"] == 0
    refute Jason.encode!(list_result["structuredContent"]) =~ hidden_pool.id

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_pool", %{"selector" => hidden_pool.id}, %{
               auth: admin_auth
             })

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "pool",
             "item" => nil,
             "candidates" => [],
             "message" => "Pool selector did not match"
           }

    refute inspect(get_result) =~ hidden_pool.id
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "scoped admin Pool tools return assigned Pools only", %{owner: owner} do
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()

    visible_pool = pool_fixture(%{name: "Scoped Pool"})
    hidden_pool = pool_fixture(%{name: "Scoped Pool"})
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Scoped pool MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_pools", %{"limit" => 10}, %{auth: admin_auth})

    assert list_result["isError"] == false
    assert [%{"id" => visible_id}] = list_result["structuredContent"]["items"]
    assert visible_id == visible_pool.id
    refute Jason.encode!(list_result["structuredContent"]) =~ hidden_pool.id

    assert {:ok, hidden_result} =
             ToolDispatch.call("codex_pooler_get_pool", %{"selector" => hidden_pool.id}, %{
               auth: admin_auth
             })

    assert hidden_result["isError"] == false

    assert hidden_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "pool",
             "item" => nil,
             "candidates" => [],
             "message" => "Pool selector did not match"
           }

    assert {:ok, ambiguous_result} =
             ToolDispatch.call("codex_pooler_get_pool", %{"selector" => "Scoped Pool"}, %{
               auth: admin_auth
             })

    assert ambiguous_result["structuredContent"]["status"] == "ok"
    assert ambiguous_result["structuredContent"]["item"]["id"] == visible_pool.id
    assert ambiguous_result["structuredContent"]["candidates"] == []
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(hidden_result)
    assert :ok = Redaction.assert_mcp_output_safe!(ambiguous_result)
  end
end
