defmodule CodexPooler.MCP.OperatorsToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures, only: [operator_pool_assignment_fixture: 3, pool_fixture: 1]

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

    %{auth: auth, owner: owner, raw_token: raw_token}
  end

  test "lists bounded operator metadata with masked emails and no credential fields", %{
    auth: auth
  } do
    %{user: operator} =
      operator_fixture(auth.operator, %{
        "display_name" => "Operator fixture",
        "email" => Redaction.forbidden_sentinel!(:disallowed_email)
      })

    assert {:ok, _settings} = MCP.set_operator_mcp_enabled(operator, true)

    assert {:ok, %{raw_token: operator_raw_token}} =
             MCP.create_operator_token(operator, %{label: "Operator MCP"})

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_operators",
               %{"query" => "Operator", "limit" => 10},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 operator metadata records returned; total 1"
    assert text =~ "- name=Operator fixture status=active email=re***@example.com"
    assert text =~ "mcp=enabled"
    assert text =~ "keys=1"
    assert text =~ "password_change_required=true"
    assert text =~ "totp=disabled"

    assert [presented] = result["structuredContent"]["operators"]
    assert presented["id"] == operator.id
    assert presented["display_name"] == "Operator fixture"
    assert presented["email"] == "re***@example.com"
    assert presented["mcp_enabled"] == true
    assert presented["mcp_key_count"] == 1
    assert presented["password_change_required"] == true
    assert presented["totp_status"] == "disabled"

    refute inspect(result) =~ operator.email
    refute inspect(result) =~ operator.password_hash
    refute inspect(result) =~ operator_raw_token
    refute inspect(result) =~ "password_hash"
    refute inspect(result) =~ "temporary_password"
    refute inspect(result) =~ "session_token"
    refute inspect(result) =~ "totp_secret"
    refute inspect(result) =~ "recovery"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "gets one operator by id without exposing raw email", %{auth: auth} do
    %{user: operator} =
      operator_fixture(auth.operator, %{
        "display_name" => "Lookup Operator",
        "email" => "lookup-operator@example.com"
      })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_operator", %{"selector" => operator.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 operator metadata record returned"
    assert text =~ "- name=Lookup Operator status=active email=lo***@example.com"
    assert text =~ "mcp=disabled"
    assert text =~ "keys=0"
    assert text =~ "password_change_required=true"
    assert text =~ "totp=disabled"
    assert text =~ "created="
    assert text =~ "updated="
    assert result["structuredContent"]["status"] == "ok"
    assert result["structuredContent"]["kind"] == "operator"
    assert result["structuredContent"]["candidates"] == []
    assert result["structuredContent"]["message"] == ""
    operator_metadata = result["structuredContent"]["item"]
    assert operator_metadata["id"] == operator.id
    assert operator_metadata["email"] == "lo***@example.com"
    refute inspect(result) =~ "lookup-operator@example.com"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "ambiguous operator selectors return candidates instead of first match", %{auth: auth} do
    %{user: first} =
      operator_fixture(auth.operator, %{"display_name" => "Ambiguous Operator Alpha"})

    %{user: second} =
      operator_fixture(auth.operator, %{"display_name" => "Ambiguous Operator Beta"})

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_get_operator",
               %{"selector" => "Ambiguous Operator"},
               %{
                 auth: auth
               }
             )

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "2 visible operator metadata record candidates matched the selector"
    assert text =~ "name=Ambiguous Operator Alpha"
    assert text =~ "name=Ambiguous Operator Beta"
    refute text =~ "Ambiguous Operator;"
    assert result["structuredContent"]["status"] == "ambiguous"
    assert result["structuredContent"]["kind"] == "operator"
    assert result["structuredContent"]["item"] == nil
    refute Map.has_key?(result["structuredContent"], "selector")
    candidates = result["structuredContent"]["candidates"]
    assert length(candidates) == 2
    assert Enum.sort(Enum.map(candidates, & &1["id"])) == Enum.sort([first.id, second.id])
    assert Enum.all?(candidates, &String.contains?(&1["email"], "***@example.com"))
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "operator tools do not echo forbidden caller input in successful outputs", %{auth: auth} do
    sentinel = Redaction.forbidden_sentinel!(:prompt)

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_operators",
               %{"query" => sentinel, "status" => sentinel},
               %{auth: auth}
             )

    assert list_result["isError"] == false
    assert [%{"type" => "text", "text" => list_text}] = list_result["content"]
    assert list_text == "No operator metadata records matched the visible scope"

    assert list_result["structuredContent"]["filters"] == %{
             "applied" => %{"query" => %{"applied" => true}, "status" => %{"applied" => true}},
             "count" => 2
           }

    refute inspect(list_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_operator", %{"selector" => sentinel}, %{
               auth: auth
             })

    assert get_result["isError"] == false
    assert [%{"type" => "text", "text" => get_text}] = get_result["content"]
    assert get_text == "No visible operator metadata record matched the selector"

    assert get_result["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "operator",
             "item" => nil,
             "candidates" => [],
             "message" => "Operator selector did not match"
           }

    refute inspect(get_result) =~ sentinel
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
  end

  test "operator tools reject unexpected arguments as CallToolResult errors", %{auth: auth} do
    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_list_operators", %{"unexpected" => true}, %{
               auth: auth
             })

    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "invalid_arguments: Invalid tool arguments"
    refute Map.has_key?(result, "structuredContent")
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "operator metadata is owner-only for scoped admins", %{owner: owner} do
    target = operator_fixture(owner, %{"display_name" => "Hidden Operator Alpha"}).user
    _second = operator_fixture(owner, %{"display_name" => "Hidden Operator Beta"}).user

    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    pool = pool_fixture(%{name: "Operator visibility Pool"})
    operator_pool_assignment_fixture(admin, pool, created_by_user_id: owner.id)

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Admin MCP"})

    assert {:ok, admin_auth} = MCP.authenticate_token(raw_token)

    denied_text = "capability_denied: operator metadata tools require the instance owner role"

    assert {:ok, list_result} =
             ToolDispatch.call(
               "codex_pooler_list_operators",
               %{"query" => "Hidden Operator", "limit" => 10},
               %{auth: admin_auth}
             )

    assert list_result["isError"] == true
    assert [%{"type" => "text", "text" => ^denied_text}] = list_result["content"]
    refute Map.has_key?(list_result, "structuredContent")
    refute inspect(list_result) =~ target.id
    refute inspect(list_result) =~ "Hidden Operator"

    assert {:ok, get_result} =
             ToolDispatch.call("codex_pooler_get_operator", %{"selector" => target.id}, %{
               auth: admin_auth
             })

    assert get_result["isError"] == true
    assert [%{"type" => "text", "text" => ^denied_text}] = get_result["content"]
    refute Map.has_key?(get_result, "structuredContent")

    assert {:ok, ambiguous_result} =
             ToolDispatch.call(
               "codex_pooler_get_operator",
               %{"selector" => "Hidden Operator"},
               %{auth: admin_auth}
             )

    assert ambiguous_result["isError"] == true
    assert [%{"type" => "text", "text" => ^denied_text}] = ambiguous_result["content"]
    refute inspect(ambiguous_result) =~ "Hidden Operator"
    assert :ok = Redaction.assert_mcp_output_safe!(list_result)
    assert :ok = Redaction.assert_mcp_output_safe!(get_result)
    assert :ok = Redaction.assert_mcp_output_safe!(ambiguous_result)
  end
end
