defmodule CodexPooler.MCP.InvitesToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.InviteAcceptance
  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
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
    assert {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(owner, %{label: "MCP"})
    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    scope = Scope.for_user(owner, Accounts.roles_for_user(owner))
    pool = pool_fixture(%{created_by_user_id: owner.id, name: "Invite test pool"})

    %{auth: auth, owner: owner, pool: pool, scope: scope}
  end

  test "lists invite metadata with masked recipient fields and no invite token material", %{
    auth: auth,
    pool: pool,
    scope: scope
  } do
    assert {:ok, %{invite: invite, token: invite_token}} =
             Access.create_invite(scope, pool, %{
               invited_email: Redaction.forbidden_sentinel!(:disallowed_email)
             })

    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    assert {:ok, _acceptance} =
             %InviteAcceptance{}
             |> InviteAcceptance.changeset(%{
               invite_id: invite.id,
               pool_id: pool.id,
               upstream_identity_id: identity.id,
               pool_upstream_assignment_id: assignment.id,
               onboarding_method: "invite",
               accepted_by_email: "accepted-invite@example.com",
               accepted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
               details: %{}
             })
             |> Repo.insert()

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_invites",
               %{"email" => "REDACTION_DISALLOWED", "limit" => 10},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 invite metadata records returned; total 1"
    assert text =~ "- status=active recipient=re***@example.com"
    assert text =~ "pool=#{pool.slug}"
    assert text =~ "sent=unknown"
    assert text =~ "accepted="
    refute text =~ "accepted=none"

    assert [presented] = result["structuredContent"]["invites"]
    assert presented["id"] == invite.id
    assert presented["pool_id"] == pool.id
    assert presented["pool_name"] == pool.name
    assert presented["pool_slug"] == pool.slug
    assert presented["invited_email"] == "re***@example.com"
    assert presented["accepted_by_email"] == "ac***@example.com"
    assert presented["status"] == "active"

    refute inspect(result) =~ invite.invited_email
    refute inspect(result) =~ "accepted-invite@example.com"
    refute inspect(result) =~ invite_token
    refute inspect(result) =~ Base.encode16(invite.token_hash)
    refute inspect(result) =~ "token_hash"
    refute inspect(result) =~ "invite_url"
    refute inspect(result) =~ "temporary_password"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "gets one invite by id with concise safe text", %{auth: auth, pool: pool, scope: scope} do
    assert {:ok, %{invite: invite, token: invite_token}} =
             Access.create_invite(scope, pool, %{invited_email: "single-invite@example.com"})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_invite", %{"selector" => invite.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 invite metadata record returned"
    assert text =~ "- status=active recipient=si***@example.com"
    assert text =~ "pool=#{pool.slug}"
    assert text =~ "sent=unknown"
    assert text =~ "accepted=none"
    assert result["structuredContent"]["status"] == "ok"
    assert result["structuredContent"]["kind"] == "invite"
    assert result["structuredContent"]["candidates"] == []
    assert result["structuredContent"]["message"] == ""
    invite_metadata = result["structuredContent"]["item"]

    if invite_metadata["created_by_user_id"] do
      assert text =~ "creator="
    else
      refute text =~ "creator="
    end

    assert invite_metadata["id"] == invite.id
    assert invite_metadata["invited_email"] == "si***@example.com"
    refute inspect(result) =~ "single-invite@example.com"
    refute inspect(result) =~ invite_token
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "ambiguous invite selectors return structured candidates", %{
    auth: auth,
    pool: pool,
    scope: scope
  } do
    assert {:ok, %{invite: first}} =
             Access.create_invite(scope, pool, %{invited_email: "ambiguous-one@example.com"})

    assert {:ok, %{invite: second}} =
             Access.create_invite(scope, pool, %{invited_email: "ambiguous-two@example.com"})

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_invite", %{"selector" => pool.slug}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "2 visible invite metadata record candidates matched the selector"
    assert text =~ "recipient=am***@example.com"
    assert text =~ "pool=#{pool.slug}"
    refute text =~ pool.name
    assert result["structuredContent"]["status"] == "ambiguous"
    assert result["structuredContent"]["kind"] == "invite"
    assert result["structuredContent"]["item"] == nil
    refute Map.has_key?(result["structuredContent"], "selector")
    candidates = result["structuredContent"]["candidates"]
    assert length(candidates) == 2
    assert Enum.map(candidates, & &1["id"]) == [second.id, first.id]
    assert Enum.all?(candidates, &String.contains?(&1["invited_email"], "***@example.com"))
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "invite tools do not echo forbidden caller input in successful outputs", %{auth: auth} do
    sentinel = Redaction.forbidden_sentinel!(:prompt)

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_invites",
               %{"email" => sentinel, "status" => "active"},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => list_text}] = list_result["content"]
    assert list_text == "No invite metadata records matched the visible scope"

    assert list_result["structuredContent"]["filters"] == %{
             "applied" => %{
               "email" => %{"applied" => true},
               "status" => %{"applied" => true}
             },
             "count" => 2
           }

    refute inspect(list_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_invite", %{"selector" => sentinel}, %{auth: auth})

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert get_text == "No visible invite metadata record matched the selector"

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "invite",
             "item" => nil,
             "candidates" => [],
             "message" => "Invite selector did not match"
           }

    refute inspect(get_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "scoped admin invite tools return assigned-pool invites only", %{
    owner: owner,
    scope: owner_scope
  } do
    visible_pool = pool_fixture(%{name: "Visible Invite Pool"})
    hidden_pool = pool_fixture(%{name: "Hidden Invite Pool"})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    assert {:ok, %{invite: visible_invite}} =
             Access.create_invite(owner_scope, visible_pool, %{
               invited_email: "visible-invite@example.com"
             })

    assert {:ok, %{invite: hidden_invite}} =
             Access.create_invite(owner_scope, hidden_pool, %{
               invited_email: "hidden-invite@example.com"
             })

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Scoped invite MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    assert {:ok, list_result} =
             ToolDispatch.call("codex_pooler_list_invites", %{"limit" => 10}, %{auth: admin_auth})

    assert [presented] = list_result["structuredContent"]["invites"]
    assert presented["id"] == visible_invite.id
    refute Jason.encode!(list_result["structuredContent"]) =~ hidden_invite.id

    assert {:ok, hidden_result} =
             ToolDispatch.call("codex_pooler_get_invite", %{"selector" => hidden_invite.id}, %{
               auth: admin_auth
             })

    assert hidden_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "invite",
             "item" => nil,
             "candidates" => [],
             "message" => "Invite selector did not match"
           }

    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(hidden_result)
  end

  test "invite tools reject unexpected arguments as CallToolResult errors", %{auth: auth} do
    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_list_invites", %{"unexpected" => true}, %{
               auth: auth
             })

    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "invalid_arguments: Invalid tool arguments"
    refute Map.has_key?(result, "structuredContent")
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end
end
