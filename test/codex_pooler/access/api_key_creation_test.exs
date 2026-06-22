defmodule CodexPooler.Access.APIKeyCreationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures

  describe "api key creation" do
    test "counts api keys by pool id and defaults missing pools to zero" do
      {scope, pool} = owner_scope_and_pool()

      {:ok, other_pool} =
        Pools.create_pool(scope, %{
          slug: "other-#{System.unique_integer([:positive])}",
          name: "Other"
        })

      {:ok, _} = Access.create_api_key(scope, pool, %{display_name: "Primary"})
      {:ok, _} = Access.create_api_key(scope, pool, %{display_name: "Secondary"})
      {:ok, _} = Access.create_api_key(scope, other_pool, %{display_name: "Other"})

      pool_id = pool.id
      other_pool_id = other_pool.id
      missing_pool_id = Ecto.UUID.generate()

      assert %{
               ^pool_id => 2,
               ^other_pool_id => 1,
               ^missing_pool_id => 0
             } = Access.count_api_keys_by_pool_ids([pool_id, other_pool_id, missing_pool_id])
    end

    test "assigns selected visible API keys to a target pool" do
      {scope, pool} = owner_scope_and_pool()

      {:ok, other_pool} =
        Pools.create_pool(scope, %{
          slug: "assigned-#{System.unique_integer([:positive])}",
          name: "Assigned"
        })

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Movable",
                 model_mode: "selected_models",
                 allowed_model_identifiers: ["gpt-alpha"],
                 enforced_model_identifier: "gpt-alpha",
                 default_policy: %{max_tokens_per_week: 10_000},
                 model_policies: [%{model_identifier: "gpt-alpha", max_tokens_per_day: 500}]
               })

      assert :ok = Access.assign_api_keys_to_pool(scope, other_pool, [api_key.id])

      moved_api_key = Repo.get!(APIKey, api_key.id)

      assert moved_api_key.pool_id == other_pool.id
      assert moved_api_key.allowed_model_identifiers == ["gpt-alpha"]
      assert moved_api_key.enforced_model_identifier == "gpt-alpha"

      assert %APIKeyPolicyBinding{max_tokens_per_week: 10_000} =
               Repo.get_by!(
                 APIKeyPolicyBinding,
                 api_key_id: api_key.id,
                 binding_scope: "default"
               )

      assert %APIKeyPolicyBinding{max_tokens_per_day: 500} =
               Repo.get_by!(
                 APIKeyPolicyBinding,
                 api_key_id: api_key.id,
                 binding_scope: "model",
                 model_identifier: "gpt-alpha"
               )
    end

    test "rejects API key assignment when a selected key is not visible" do
      {scope, pool} = owner_scope_and_pool()
      missing_api_key_id = Ecto.UUID.generate()

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Still here"})

      assert {:error, %{message: "selected API keys are not available"}} =
               Access.assign_api_keys_to_pool(scope, pool, [api_key.id, missing_api_key_id])

      assert Repo.get!(APIKey, api_key.id).pool_id == pool.id
    end

    test "reveals the raw key only in the creation result and stores hash-only material" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, raw_key: raw_key, policy_bindings: [default_policy]}} =
               Access.create_api_key(scope, pool, %{display_name: "Gateway key"})

      assert raw_key =~ ~r/^sk-cxp-[0-9a-f]{12}-[A-Za-z0-9_-]+$/
      assert api_key.key_prefix == raw_key |> String.split("-") |> Enum.take(3) |> Enum.join("-")
      assert api_key.display_name == "Gateway key"
      assert default_policy.binding_scope == "default"

      persisted = Repo.get!(APIKey, api_key.id)
      secret = raw_key |> String.split("-", parts: 4) |> List.last()

      assert persisted.key_hash == Access.hash_api_key_secret(secret)
      refute persisted.key_hash == raw_key
      refute Map.has_key?(persisted, :raw_key)

      assert {:ok, keys} = Access.list_api_keys(scope, pool)
      assert [listed_key] = keys
      assert listed_key.id == api_key.id
      refute Map.has_key?(listed_key, :raw_key)

      assert audit = Repo.get_by(AuditEvent, action: "api_key.create", target_id: api_key.id)
      assert audit.actor_user_id == scope.user.id
      assert audit.pool_id == pool.id
      assert audit.details["key_prefix"] == api_key.key_prefix
      assert audit.details["status"] == "active"
      refute inspect(audit.details) =~ raw_key
      refute inspect(audit.details) =~ secret
    end

    test "model policy bindings are validated and persisted with the key" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{policy_bindings: [_default_policy, model_policy]}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Model key",
                 model_policies: [%{model_identifier: "gpt-5.4-mini", max_tokens_per_day: 1000}]
               })

      assert model_policy.binding_scope == "model"
      assert model_policy.model_identifier == "gpt-5.4-mini"
      assert model_policy.max_tokens_per_day == 1000
    end

    test "updates API key status and model policy through the admin context" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Editable key"})

      assert {:ok, updated} =
               Access.update_api_key(scope, api_key, %{
                 display_name: "Edited key",
                 pool_id: pool.id,
                 status: "paused",
                 allowed_model_identifiers: [" GPT-Admin "],
                 metadata: %{
                   "labels" => [],
                   "operator_notes" => "admin form update"
                 }
               })

      assert updated.display_name == "Edited key"
      assert updated.status == "paused"
      assert updated.allowed_model_identifiers == ["GPT-Admin"]
      assert updated.metadata["operator_notes"] == "admin form update"
      assert {:error, :api_key_disabled} = Access.normalize_api_key_policy(updated)

      assert {:ok, resumed} = Access.resume_api_key(scope, updated.id)
      assert {:ok, policy} = Access.normalize_api_key_policy(resumed)
      assert policy.allowed_model_identifiers == ["gpt-admin"]

      assert update_audit =
               Repo.get_by(AuditEvent, action: "api_key.update", target_id: api_key.id)

      assert update_audit.pool_id == pool.id
      assert "metadata" in update_audit.details["changed_fields"]
      refute inspect(update_audit.details) =~ "admin form update"

      assert resume_audit =
               Repo.get_by(AuditEvent, action: "api_key.resume", target_id: api_key.id)

      assert resume_audit.details["previous_status"] == "paused"
      assert resume_audit.details["status"] == "active"
    end

    test "rotates API key material without changing model policy fields" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, raw_key: old_raw_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Rotatable key",
                 policy: %{allowed_model_identifiers: ["gpt-rotate"]}
               })

      assert {:ok, %{api_key: rotated_key, raw_key: new_raw_key}} =
               Access.rotate_api_key(scope, api_key.id)

      assert new_raw_key =~ ~r/^sk-cxp-[0-9a-f]{12}-[A-Za-z0-9_-]+$/
      assert rotated_key.id == api_key.id
      assert rotated_key.key_prefix != api_key.key_prefix
      assert rotated_key.allowed_model_identifiers == ["gpt-rotate"]

      assert {:error, %{code: :api_key_missing}} = Access.authenticate_api_key(old_raw_key)
      assert {:ok, auth} = Access.authenticate_api_key(new_raw_key)
      assert auth.api_key_id == api_key.id

      assert rotate_audit =
               Repo.get_by(AuditEvent, action: "api_key.rotate", target_id: api_key.id)

      assert rotate_audit.details["previous_key_prefix"] == api_key.key_prefix
      assert rotate_audit.details["key_prefix"] == rotated_key.key_prefix
      refute inspect(rotate_audit.details) =~ old_raw_key
      refute inspect(rotate_audit.details) =~ new_raw_key
    end

    test "audits API key pause, revoke, and delete lifecycle actions" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Lifecycle key"})

      assert {:ok, paused_key} = Access.pause_api_key(scope, api_key)

      assert pause_audit =
               Repo.get_by(AuditEvent, action: "api_key.pause", target_id: api_key.id)

      assert pause_audit.details["previous_status"] == "active"
      assert pause_audit.details["status"] == "paused"

      assert {:ok, revoked_key} = Access.revoke_api_key(scope, paused_key)

      assert revoke_audit =
               Repo.get_by(AuditEvent, action: "api_key.revoke", target_id: api_key.id)

      assert revoke_audit.details["previous_status"] == "paused"
      assert revoke_audit.details["status"] == "revoked"

      assert {:ok, deleted_key} = Access.delete_api_key(scope, revoked_key)
      assert deleted_key.id == api_key.id

      assert delete_audit =
               Repo.get_by(AuditEvent, action: "api_key.delete", target_id: api_key.id)

      assert delete_audit.pool_id == pool.id
      assert delete_audit.details["key_prefix"] == api_key.key_prefix
    end

    test "API key lifecycle distinguishes invalid scope from missing keys" do
      {scope, _pool} = owner_scope_and_pool()
      missing_api_key_id = Ecto.UUID.generate()

      lifecycle_operations = [
        :pause_api_key,
        :resume_api_key,
        :rotate_api_key,
        :revoke_api_key,
        :delete_api_key
      ]

      for operation <- lifecycle_operations do
        assert {:error, %{code: :invalid_request, message: "user scope is required"}} =
                 apply(Access, operation, [nil, missing_api_key_id])

        assert {:error, %{code: :api_key_not_found, message: "api key was not found"}} =
                 apply(Access, operation, [scope, missing_api_key_id])
      end
    end

    test "list_api_keys propagates pool visibility errors" do
      {_owner_scope, _pool} = owner_scope_and_pool()

      blocked_user =
        %User{}
        |> User.bootstrap_changeset(
          valid_bootstrap_attributes(%{"email" => "blocked@example.com"})
        )
        |> Repo.insert!()

      blocked_scope = Scope.for_user(blocked_user, [])

      assert {:error, %{code: :capability_denied}} = Access.list_api_keys(blocked_scope)
      assert {:error, %{code: :invalid_request}} = Access.list_api_keys(nil)
    end

    test "preserves nil and empty model policy fields while defaulting enforced fields to nil" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: unrestricted_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Unrestricted policy key",
                 policy: %{allowed_model_identifiers: nil}
               })

      unrestricted_key = Repo.get!(APIKey, unrestricted_key.id)

      assert is_nil(unrestricted_key.allowed_model_identifiers)
      assert is_nil(unrestricted_key.enforced_model_identifier)
      assert is_nil(unrestricted_key.enforced_reasoning_effort)
      assert is_nil(unrestricted_key.enforced_service_tier)

      assert {:ok, %{api_key: deny_all_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Deny all policy key",
                 policy: %{allowed_model_identifiers: []}
               })

      deny_all_key = Repo.get!(APIKey, deny_all_key.id)

      assert deny_all_key.allowed_model_identifiers == []
    end

    test "validates enforced policy enums and weekly binding limits" do
      api_key_changeset =
        APIKey.changeset(%APIKey{}, %{
          pool_id: Ecto.UUID.generate(),
          display_name: "Typed policy key",
          key_prefix: "sk_typed_policy",
          key_hash: <<"typed-policy">>,
          status: "active",
          enforced_model_identifier: "gpt enforced",
          enforced_reasoning_effort: "extreme",
          enforced_service_tier: "vip"
        })

      refute api_key_changeset.valid?

      assert "must be a non-empty model identifier without whitespace" in errors_on(
               api_key_changeset
             ).enforced_model_identifier

      assert "is invalid" in errors_on(api_key_changeset).enforced_reasoning_effort
      assert "is invalid" in errors_on(api_key_changeset).enforced_service_tier

      valid_api_key_changeset =
        APIKey.changeset(%APIKey{}, %{
          pool_id: Ecto.UUID.generate(),
          display_name: "Typed policy key",
          key_prefix: "sk_typed_policy_valid",
          key_hash: <<"typed-policy-valid">>,
          status: "active",
          enforced_model_identifier: "gpt-5.4-mini",
          enforced_reasoning_effort: "max",
          enforced_service_tier: "scale"
        })

      assert valid_api_key_changeset.valid?

      ultrafast_api_key_changeset =
        APIKey.changeset(%APIKey{}, %{
          pool_id: Ecto.UUID.generate(),
          display_name: "Typed policy key",
          key_prefix: "sk_typed_policy_ultrafast",
          key_hash: <<"typed-policy-ultrafast">>,
          status: "active",
          enforced_service_tier: "ultrafast"
        })

      refute ultrafast_api_key_changeset.valid?
      assert "is invalid" in errors_on(ultrafast_api_key_changeset).enforced_service_tier

      binding_changeset =
        APIKeyPolicyBinding.changeset(%APIKeyPolicyBinding{}, %{
          api_key_id: Ecto.UUID.generate(),
          binding_scope: "default",
          status: "active",
          max_tokens_per_week: 0
        })

      refute binding_changeset.valid?
      assert "must be greater than 0" in errors_on(binding_changeset).max_tokens_per_week

      nil_weekly_changeset =
        APIKeyPolicyBinding.changeset(%APIKeyPolicyBinding{}, %{
          api_key_id: Ecto.UUID.generate(),
          binding_scope: "default",
          status: "active",
          max_tokens_per_week: nil
        })

      assert nil_weekly_changeset.valid?
    end
  end

  defp owner_scope_and_pool do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
    scope = Scope.for_user(owner, ["instance_owner"])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "pool-#{System.unique_integer([:positive])}",
               name: "Pool"
             })

    {scope, pool}
  end
end
