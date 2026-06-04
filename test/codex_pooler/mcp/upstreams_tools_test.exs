defmodule CodexPooler.MCP.UpstreamsToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolDispatch}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()
    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    settings = InstanceSettings.ensure_singleton!()
    assert {:ok, _settings} = InstanceSettings.update(settings, %{"mcp" => %{"enabled" => true}})
    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(owner, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(owner, %{label: "Task 7 MCP"})

    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    %{auth: auth, owner: owner, raw_token: raw_token}
  end

  test "lists upstream metadata with masked email-like labels and no upstream secrets", %{
    auth: auth
  } do
    pool = pool_fixture(%{name: "Upstream Pool"})
    email = Redaction.forbidden_sentinel!(:disallowed_email)
    secret = Redaction.forbidden_sentinel!(:access_token)

    %{identity: identity} =
      active_upstream_assignment_fixture(pool, %{
        account_label: email,
        account_email: email,
        access_token: secret,
        metadata: %{"account_email" => email, "secret_note" => secret}
      })

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_upstreams",
               %{"pool_selector" => pool.slug, "limit" => 10},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 upstream metadata records returned"
    assert text =~ "label=TA***@example.com"
    assert text =~ "status=active"
    assert text =~ "account=ta***@example.com"
    assert text =~ "plan=unknown"
    assert text =~ "assignments=1 active of 1 Pool assignments"

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "count",
             "items",
             "limit",
             "status"
           ]

    assert [presented] = result["structuredContent"]["items"]
    assert presented["id"] == identity.id
    assert presented["account_label"] == "TA***@example.com"
    assert presented["account_email"] == "ta***@example.com"
    assert presented["assignment_summary"]["count"] == 1
    assert presented["metadata"]["summary"] == "metadata keys omitted"

    refute inspect(result) =~ email
    refute inspect(result) =~ secret
    refute inspect(result) =~ "auth_json"
    refute inspect(result) =~ "access_token"
    refute inspect(result) =~ "refresh_token"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "gets one upstream by stored account id", %{auth: auth} do
    pool = pool_fixture()

    %{identity: identity} =
      active_upstream_assignment_fixture(pool, %{chatgpt_account_id: "acct-task7"})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_upstream", %{"selector" => "acct-task7"}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 upstream metadata record returned"
    assert text =~ "id=#{identity.id}"
    assert text =~ "status=active"
    assert text =~ "account=acct-task7"
    assert text =~ "plan=unknown"
    assert text =~ "assignments=1 active of 1 Pool assignments"
    assert result["structuredContent"]["status"] == "ok"

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "candidates",
             "item",
             "kind",
             "message",
             "status"
           ]

    assert result["structuredContent"]["kind"] == "upstream"
    assert result["structuredContent"]["item"]["id"] == identity.id
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "stored account id selector returns workspace candidates when ambiguous", %{auth: auth} do
    pool = pool_fixture()
    account_id = "acct-task7-shared-#{System.unique_integer([:positive])}"
    first_workspace_id = "workspace-mcp-alpha-#{System.unique_integer([:positive])}"
    second_workspace_id = "workspace-mcp-beta-#{System.unique_integer([:positive])}"

    %{identity: first} =
      upstream_assignment_fixture(pool, %{
        account_label: "Shared MCP slot",
        chatgpt_account_id: account_id,
        workspace_id: first_workspace_id,
        workspace_label: "MCP alpha"
      })

    %{identity: second} =
      upstream_assignment_fixture(pool, %{
        account_label: "Shared MCP slot",
        chatgpt_account_id: account_id,
        workspace_id: second_workspace_id,
        workspace_label: "MCP beta"
      })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_upstream", %{"selector" => account_id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert result["structuredContent"]["status"] == "ambiguous"
    assert result["structuredContent"]["item"] == nil

    candidates = result["structuredContent"]["candidates"]
    assert MapSet.new(Enum.map(candidates, & &1["id"])) == MapSet.new([first.id, second.id])
    assert Enum.all?(candidates, &String.starts_with?(&1["workspace_ref"], "ws:"))
    assert Enum.sort(Enum.map(candidates, & &1["workspace_label"])) == ["MCP alpha", "MCP beta"]

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "2 visible upstream metadata record candidates matched the selector"
    assert text =~ "workspace=ws:"
    refute inspect(result) =~ first_workspace_id
    refute inspect(result) =~ second_workspace_id
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "upstream list empty text and not-found text do not echo caller sentinels", %{auth: auth} do
    sentinel = Redaction.forbidden_sentinel!(:prompt)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_upstreams", %{"query" => sentinel}, %{
               auth: auth
             })

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = list_result["content"]
    assert text == "No upstream metadata records matched the visible scope"

    assert list_result["structuredContent"] == %{
             "status" => "ok",
             "count" => 0,
             "limit" => 25,
             "items" => []
           }

    refute inspect(list_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_upstream", %{"selector" => sentinel}, %{
               auth: auth
             })

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert get_text == "No visible upstream metadata record matched the selector"

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "upstream",
             "item" => nil,
             "candidates" => [],
             "message" => "Upstream selector did not match"
           }

    refute inspect(get_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "upstream text truncates long labels while preserving structured content", %{auth: auth} do
    pool = pool_fixture()
    long_label = String.duplicate("Long Upstream Label ", 12)

    %{identity: identity} = active_upstream_assignment_fixture(pool, %{account_label: long_label})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_upstream", %{"selector" => identity.id}, %{
               auth: auth
             })

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "label=#{String.slice(long_label, 0, 120)}"
    refute text =~ long_label
    assert result["structuredContent"]["item"]["account_label"] == String.trim(long_label)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "ambiguous upstream labels return candidates", %{auth: auth} do
    first_pool = pool_fixture()
    second_pool = pool_fixture()

    %{identity: first} =
      active_upstream_assignment_fixture(first_pool, %{account_label: "Shared upstream"})

    %{identity: second} =
      active_upstream_assignment_fixture(second_pool, %{account_label: "Shared upstream"})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_upstream", %{"selector" => "Shared upstream"}, %{
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

    assert result["structuredContent"]["kind"] == "upstream"
    assert result["structuredContent"]["item"] == nil
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "2 visible upstream metadata record candidates matched the selector"
    assert text =~ "id=#{first.id}"
    assert text =~ "label=Shared upstream"
    assert text =~ "status=active"

    assert MapSet.new(Enum.map(result["structuredContent"]["candidates"], & &1["id"])) ==
             MapSet.new([first.id, second.id])

    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "scoped admin upstream tools hide unassigned identities and ambiguity candidates", %{
    owner: owner
  } do
    visible_pool = pool_fixture(%{name: "Visible Upstream Pool"})
    hidden_pool = pool_fixture(%{name: "Hidden Upstream Pool"})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    %{identity: visible_identity} =
      active_upstream_assignment_fixture(visible_pool, %{
        account_label: "Shared scoped upstream",
        chatgpt_account_id: "acct-visible-scoped-upstream"
      })

    %{identity: hidden_identity} =
      active_upstream_assignment_fixture(hidden_pool, %{
        account_label: "Shared scoped upstream",
        chatgpt_account_id: "acct-hidden-scoped-upstream"
      })

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Scoped upstream MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_upstreams", %{"limit" => 10}, %{
               auth: admin_auth
             })

    assert [%{"id" => visible_id}] = list_result["structuredContent"]["items"]
    assert visible_id == visible_identity.id
    refute Jason.encode!(list_result["structuredContent"]) =~ hidden_identity.id

    assert {:ok, hidden_result} =
             ToolDispatch.call(
               "codex_pooler_get_upstream",
               %{"selector" => hidden_identity.id},
               %{
                 auth: admin_auth
               }
             )

    assert hidden_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "upstream",
             "item" => nil,
             "candidates" => [],
             "message" => "Upstream selector did not match"
           }

    assert {:ok, ambiguous_result} =
             ToolDispatch.call(
               "codex_pooler_get_upstream",
               %{"selector" => "Shared scoped upstream"},
               %{
                 auth: admin_auth
               }
             )

    assert ambiguous_result["structuredContent"]["status"] == "ok"
    assert ambiguous_result["structuredContent"]["item"]["id"] == visible_identity.id
    assert ambiguous_result["structuredContent"]["candidates"] == []
    refute inspect(ambiguous_result) =~ hidden_identity.id
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(hidden_result)
    assert :ok = Redaction.assert_mcp_output_safe!(ambiguous_result)
  end

  test "scoped admin upstream summaries count only visible Pool assignments", %{owner: owner} do
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()

    visible_pool = pool_fixture(%{name: "Visible upstream summary Pool"})
    hidden_pool = pool_fixture(%{name: "Hidden upstream summary Pool"})
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Scoped upstream MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    %{identity: identity} =
      active_upstream_assignment_fixture(visible_pool, %{
        account_label: "Shared visibility upstream",
        chatgpt_account_id: "acct-shared-visible"
      })

    assert {:ok, hidden_assignment} =
             PoolAssignments.create_pool_assignment(hidden_pool, identity, %{
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_upstream", %{"selector" => identity.id}, %{
               auth: admin_auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "assignments=1 active of 1 Pool assignments"

    item = result["structuredContent"]["item"]
    assert item["id"] == identity.id
    assert item["assignment_summary"]["count"] == 1
    assert item["assignment_summary"]["summary"] == "1 active of 1 Pool assignments"
    refute Jason.encode!(result["structuredContent"]) =~ hidden_pool.id
    refute Jason.encode!(result["structuredContent"]) =~ hidden_assignment.id
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end
end
