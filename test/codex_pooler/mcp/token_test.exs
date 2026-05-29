defmodule CodexPooler.MCP.TokenTest do
  use CodexPooler.DataCase, async: false

  import Ecto.Query
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures, only: [operator_pool_assignment_fixture: 3]

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup do
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    user = user |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    %{user: user, scope: Scope.for_user(user)}
  end

  test "creates operator MCP keys with one-time raw token and light storage", %{user: user} do
    assert {:ok, %{key: key, raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: " Laptop MCP "})

    assert raw_token =~ ~r/^mcp-cxp-[0-9a-f]{12}-[A-Za-z0-9_-]+$/
    assert key.operator_id == user.id
    assert key.label == "Laptop MCP"
    assert key.key_prefix == raw_token |> String.split("-") |> Enum.take(3) |> Enum.join("-")
    refute Map.has_key?(key, :raw_token)

    persisted = Repo.get!(OperatorMCPKey, key.id)
    secret = raw_token |> String.split("-", parts: 4) |> List.last()

    assert persisted.operator_id == user.id
    assert persisted.key_hash == MCP.hash_mcp_token_secret(secret)
    refute persisted.key_hash == raw_token
    refute inspect(persisted) =~ raw_token
    refute Map.has_key?(persisted, :raw_token)

    assert OperatorMCPKey.__schema__(:fields) |> Enum.sort() ==
             [:id, :inserted_at, :key_hash, :key_prefix, :label, :operator_id, :updated_at]

    forbidden_columns =
      ~w(raw_token token last_used_at usage_count request_count last_ip last_user_agent user_agent activity status deleted_at revoked_at)

    column_names = db_column_names("operator_mcp_keys")

    for forbidden <- forbidden_columns do
      refute forbidden in column_names
    end
  end

  test "list/get/update/delete never reveal raw token and delete is permanent", %{user: user} do
    enable_global_mcp!()
    assert {:ok, _settings} = MCP.set_operator_mcp_enabled(user, true)

    {:ok, %{key: created, raw_token: raw_token}} =
      MCP.create_operator_token(user, %{label: "Editor MCP"})

    assert {:ok, [listed]} = MCP.list_operator_tokens(user)
    assert listed.id == created.id
    refute Map.has_key?(listed, :raw_token)
    refute inspect(listed) =~ raw_token

    assert {:ok, fetched} = MCP.get_operator_token(user, created.id)
    refute Map.has_key?(fetched, :raw_token)
    refute inspect(fetched) =~ raw_token

    assert {:ok, renamed} = MCP.update_operator_token(user, created.id, %{label: "Renamed MCP"})
    assert renamed.label == "Renamed MCP"
    refute Map.has_key?(renamed, :raw_token)
    refute inspect(renamed) =~ raw_token

    assert {:ok, deleted} = MCP.delete_operator_token(user, created.id)
    assert deleted.id == created.id
    refute Repo.get(OperatorMCPKey, created.id)
    assert {:error, %{code: :mcp_token_missing}} = MCP.authenticate_token(raw_token)
  end

  test "global and account gates preserve keys but make tokens unusable immediately", %{
    user: user
  } do
    {:ok, %{key: key, raw_token: raw_token}} =
      MCP.create_operator_token(user, %{label: "Gated MCP"})

    assert {:error, %{code: :mcp_service_disabled}} = MCP.authenticate_token(raw_token)
    assert Repo.get!(OperatorMCPKey, key.id)

    enable_global_mcp!()
    assert {:error, %{code: :mcp_account_disabled}} = MCP.authenticate_token(raw_token)

    assert {:ok, settings} = MCP.set_operator_mcp_enabled(user, true)
    assert settings.operator_id == user.id
    assert settings.enabled == true
    assert {:ok, auth} = MCP.authenticate_token(raw_token)
    assert auth.operator.id == user.id
    assert auth.scope.user.id == user.id
    assert auth.scope.roles == ["instance_owner"]
    assert auth.scope.assigned_pool_ids == []
    refute Map.has_key?(auth.key, :raw_token)

    assert {:ok, disabled_settings} = MCP.set_operator_mcp_enabled(user, false)
    assert disabled_settings.enabled == false
    assert {:error, %{code: :mcp_account_disabled}} = MCP.authenticate_token(raw_token)
    assert Repo.get!(OperatorMCPKey, key.id)

    assert {:ok, _enabled_settings} = MCP.set_operator_mcp_enabled(user, true)
    disable_global_mcp!()
    assert {:error, %{code: :mcp_service_disabled}} = MCP.authenticate_token(raw_token)
    assert Repo.get!(OperatorMCPKey, key.id)
  end

  test "token authentication attaches the canonical pool-scoped admin scope", %{
    scope: owner_scope,
    user: owner
  } do
    enable_global_mcp!()

    assert {:ok, assigned_pool} =
             Pools.create_pool(owner_scope, %{slug: "mcp-assigned", name: "MCP Assigned"})

    assert {:ok, _hidden_pool} =
             Pools.create_pool(owner_scope, %{slug: "mcp-hidden", name: "MCP Hidden"})

    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin = admin |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    assert {:ok, _settings} = MCP.set_operator_mcp_enabled(admin, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(admin, %{label: "Admin MCP"})

    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    assert auth.operator.id == admin.id
    assert auth.scope.user.id == admin.id
    assert auth.scope.roles == ["instance_admin"]
    assert auth.scope.assigned_pool_ids == [assigned_pool.id]
    assert Enum.map(Pools.list_visible_pools(auth.scope), & &1.id) == [assigned_pool.id]
  end

  test "operator MCP enable and disable writes are audited without token material", %{user: user} do
    assert {:ok, enabled_settings} = MCP.set_operator_mcp_enabled(user, true)
    assert enabled_settings.enabled == true

    assert {:ok, disabled_settings} = MCP.set_operator_mcp_enabled(user, false)
    assert disabled_settings.enabled == false

    assert [enable_audit] = audit_events("mcp.operator_enable", user.id)
    assert enable_audit.actor_user_id == user.id
    assert enable_audit.target_type == "user"
    assert enable_audit.details["operator_id"] == user.id
    assert enable_audit.details["enabled"] == true

    assert [disable_audit] = audit_events("mcp.operator_disable", user.id)
    assert disable_audit.actor_user_id == user.id
    assert disable_audit.target_type == "user"
    assert disable_audit.details["operator_id"] == user.id
    assert disable_audit.details["enabled"] == false
  end

  test "operator MCP token lifecycle writes are audited without raw tokens or hashes", %{
    user: user
  } do
    assert {:ok, %{key: key, raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "Audited MCP"})

    secret = raw_token |> String.split("-", parts: 4) |> List.last()

    assert [create_audit] = audit_events("mcp.token_create", key.id)
    assert_token_audit(create_audit, user, key)
    refute_audit_secret_material(create_audit, raw_token, secret, key.key_hash)

    assert {:ok, updated_key} = MCP.update_operator_token(user, key.id, %{label: "Renamed MCP"})

    assert [update_audit] = audit_events("mcp.token_update", key.id)
    assert_token_audit(update_audit, user, updated_key)
    assert update_audit.details["changed_fields"] == ["label"]
    assert update_audit.details["previous_label"] == "Audited MCP"
    assert update_audit.details["label"] == "Renamed MCP"
    refute_audit_secret_material(update_audit, raw_token, secret, key.key_hash)

    assert {:ok, deleted_key} = MCP.delete_operator_token(user, key.id)

    assert [delete_audit] = audit_events("mcp.token_delete", key.id)
    assert_token_audit(delete_audit, user, deleted_key)
    refute_audit_secret_material(delete_audit, raw_token, secret, key.key_hash)
  end

  test "operator policy denies disabled deleted and password-change-required operators", %{
    user: user
  } do
    enable_global_mcp!()
    {:ok, _settings} = MCP.set_operator_mcp_enabled(user, true)
    {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(user, %{label: "Policy MCP"})

    assert {:ok, _auth} = MCP.authenticate_token(raw_token)

    user |> Ecto.Changeset.change(password_change_required: true) |> Repo.update!()

    assert {:error, %{code: :mcp_operator_password_change_required}} =
             MCP.authenticate_token(raw_token)

    user
    |> Ecto.Changeset.change(password_change_required: false, status: "disabled")
    |> Repo.update!()

    assert {:error, %{code: :mcp_operator_disabled}} = MCP.authenticate_token(raw_token)

    user
    |> Ecto.Changeset.change(status: "active", deleted_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, %{code: :mcp_operator_deleted}} = MCP.authenticate_token(raw_token)
  end

  test "account MCP setting is stored separately from users" do
    assert OperatorMCPSettings.__schema__(:fields) |> Enum.sort() ==
             [:enabled, :inserted_at, :operator_id, :updated_at]

    refute :mcp_enabled in User.__schema__(:fields)
    refute "mcp_enabled" in db_column_names("users")
  end

  defp enable_global_mcp! do
    settings = InstanceSettings.ensure_singleton!()
    assert {:ok, updated} = InstanceSettings.update(settings, %{"mcp" => %{"enabled" => true}})
    updated
  end

  defp disable_global_mcp! do
    settings = InstanceSettings.get!()
    assert {:ok, updated} = InstanceSettings.update(settings, %{"mcp" => %{"enabled" => false}})
    updated
  end

  defp audit_events(action, target_id) do
    Repo.all(
      from event in AuditEvent,
        where: event.action == ^action and event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
    )
  end

  defp assert_token_audit(event, user, key) do
    assert event.actor_user_id == user.id
    assert event.target_type == "operator_mcp_key"
    assert event.target_id == key.id
    assert event.details["operator_id"] == user.id
    refute Map.has_key?(event.details, "key_prefix")
  end

  defp refute_audit_secret_material(event, raw_token, secret, key_hash) do
    inspected = inspect(event.details)

    refute inspected =~ raw_token
    refute inspected =~ secret
    refute inspected =~ key_hash
    refute Map.has_key?(event.details, "key_hash")
    refute Map.has_key?(event.details, "key_prefix")
    refute Map.has_key?(event.details, "raw_token")
  end

  defp db_column_names(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        ORDER BY column_name
        """,
        [table]
      )

    Enum.map(rows, fn [column_name] -> column_name end)
  end
end
