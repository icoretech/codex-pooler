defmodule CodexPooler.AccessTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}
  alias CodexPooler.Access.APIKeys.TouchDebounce
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  import Ecto.Query
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    TouchDebounce.reset()

    on_exit(fn ->
      TouchDebounce.reset()
    end)

    :ok
  end

  describe "server-authoritative API key policy APIs" do
    test "selected model mode persists normalized catalog-backed and custom manual identifiers" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, policy_bindings: [default_policy]}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Selected model policy key",
                 model_mode: "selected_models",
                 allowed_model_identifiers: [" GPT-Alpha ", "custom/manual-test-model"],
                 enforced_model_identifier: "GPT-Alpha",
                 default_policy: %{max_tokens_per_week: 10_000}
               })

      persisted = Repo.get!(APIKey, api_key.id)

      assert persisted.allowed_model_identifiers == ["gpt-alpha", "custom/manual-test-model"]
      assert persisted.enforced_model_identifier == "gpt-alpha"
      assert default_policy.max_tokens_per_week == 10_000

      assert {:ok, policy} = Access.normalize_api_key_policy(persisted)
      assert {:ok, ^policy} = Access.authorize_api_key_policy(policy, %{model: "GPT-Alpha"})

      assert {:error, :model_not_allowed} =
               Access.authorize_api_key_policy(policy, %{model: "gpt-beta"})
    end

    test "all and deny-all model modes preserve nil versus empty-list semantics" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: all_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "All model policy key",
                 model_mode: "all_models"
               })

      assert is_nil(Repo.get!(APIKey, all_key.id).allowed_model_identifiers)

      assert {:ok, %{api_key: deny_all_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Deny all model policy key",
                 model_mode: "deny_all_models"
               })

      assert Repo.get!(APIKey, deny_all_key.id).allowed_model_identifiers == []
    end

    test "enforced model conflicts with selected and deny-all model modes are rejected" do
      {scope, pool} = owner_scope_and_pool()

      assert {:error, %{code: :invalid_policy, message: selected_message}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Conflicting selected key",
                 model_mode: "selected_models",
                 allowed_model_identifiers: ["gpt-alpha"],
                 enforced_model_identifier: "gpt-beta"
               })

      assert selected_message =~ "selected models"

      assert {:error, %{code: :invalid_policy, message: deny_all_message}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Conflicting deny all key",
                 model_mode: "deny_all_models",
                 enforced_model_identifier: "gpt-alpha"
               })

      assert deny_all_message =~ "deny-all"
    end

    test "policy binding replacement rolls back atomically when a model binding is invalid" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, policy_bindings: initial_bindings}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Atomic policy key",
                 model_mode: "selected_models",
                 allowed_model_identifiers: ["gpt-alpha"],
                 model_policies: [%{model_identifier: "gpt-alpha", max_tokens_per_day: 1000}]
               })

      assert {:error, %Ecto.Changeset{}} =
               Access.update_api_key_with_policy(scope, api_key, %{
                 display_name: "Should roll back",
                 model_mode: "selected_models",
                 allowed_model_identifiers: ["gpt-alpha"],
                 model_policies: [%{model_identifier: "gpt-alpha", max_tokens_per_day: 0}]
               })

      persisted = Repo.get!(APIKey, api_key.id)

      persisted_bindings =
        Repo.all(from b in APIKeyPolicyBinding, where: b.api_key_id == ^api_key.id)

      assert persisted.display_name == "Atomic policy key"

      assert Enum.map(
               persisted_bindings,
               &{&1.binding_scope, &1.model_identifier, &1.max_tokens_per_day}
             )
             |> Enum.sort() ==
               Enum.map(
                 initial_bindings,
                 &{&1.binding_scope, &1.model_identifier, &1.max_tokens_per_day}
               )
               |> Enum.sort()
    end

    test "model policy aliases remain compatible with explicit policy modes" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: old_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Old payload key",
                 allowed_model_identifiers: ["GPT-Old"],
                 default_policy: %{max_requests_per_minute: 10}
               })

      persisted_old_key = Repo.get!(APIKey, old_key.id)
      assert persisted_old_key.allowed_model_identifiers == ["gpt-old"]

      assert {:ok, old_policy} = Access.normalize_api_key_policy(persisted_old_key)
      assert old_policy.allowed_model_identifiers == ["gpt-old"]

      assert {:ok, %{api_key: updated_key}} =
               Access.update_api_key_with_policy(scope, persisted_old_key, %{
                 display_name: "Old alias update",
                 allowed_models_mode: "all_models"
               })

      updated_key = Repo.get!(APIKey, updated_key.id)
      assert is_nil(updated_key.allowed_model_identifiers)
    end
  end

  describe "api key authentication" do
    test "valid keys resolve the active key and pool and debounce last_used_at persistence" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Gateway key"})

      assert is_nil(api_key.last_used_at)

      {result, update_count} =
        count_api_key_updates(fn ->
          assert {:ok, auth} = Access.authenticate_api_key(raw_key)
          auth
        end)

      assert update_count == 0
      auth = result
      assert auth.api_key_id == api_key.id
      assert auth.pool_id == pool.id
      assert auth.key_prefix == api_key.key_prefix
      assert auth.pool.id == pool.id
      assert %DateTime{} = auth.api_key.last_used_at
      assert is_nil(Repo.get!(APIKey, api_key.id).last_used_at)

      assert :ok = TouchDebounce.flush()
      assert %DateTime{} = Repo.get!(APIKey, api_key.id).last_used_at
    end

    test "api key touch debounce flushes at most once per interval per key" do
      {scope, pool} = owner_scope_and_pool()

      assert TouchDebounce.debounce_interval_ms() == 60_000

      assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Debounced key"
               })

      assert {:ok, first_auth} = Access.authenticate_api_key(raw_key)
      assert {:ok, second_auth} = Access.authenticate_api_key(raw_key)

      assert DateTime.compare(first_auth.api_key.last_used_at, second_auth.api_key.last_used_at) !=
               :gt

      {result, update_count} = count_api_key_updates(fn -> TouchDebounce.flush() end)

      assert result == :ok
      assert update_count == 1

      persisted = Repo.get!(APIKey, api_key.id)
      assert DateTime.compare(persisted.last_used_at, first_auth.api_key.last_used_at) != :lt
      assert DateTime.compare(persisted.last_used_at, second_auth.api_key.last_used_at) != :gt
    end

    test "api key touch flush is monotonic when replicas race" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Raced key"
               })

      newer = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      older = DateTime.add(newer, -30, :second)

      assert %APIKey{} = TouchDebounce.touch(api_key, newer)
      assert :ok = TouchDebounce.flush()
      assert Repo.get!(APIKey, api_key.id).last_used_at == newer

      assert %APIKey{} = TouchDebounce.touch(api_key, older)

      {result, update_count} = count_api_key_updates(fn -> TouchDebounce.flush() end)

      assert result == :ok
      assert update_count == 1
      assert Repo.get!(APIKey, api_key.id).last_used_at == newer
    end

    test "authorization header helper accepts bearer keys" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{raw_key: raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Gateway key"})

      assert {:ok, auth} = Access.authenticate_authorization_header("Bearer #{raw_key}")
      assert auth.pool_id == pool.id
    end

    test "missing and invalid keys fail with the same missing-key code" do
      assert {:error, %{code: :api_key_missing}} = Access.authenticate_api_key(nil)
      assert {:error, %{code: :api_key_missing}} = Access.authenticate_api_key("")
      assert {:error, %{code: :api_key_missing}} = Access.authenticate_api_key("sk-cxp-invalid")

      old_shape_key = "cb" <> "k_example.secret"

      assert {:error, %{code: :api_key_missing}} =
               Access.authenticate_api_key(old_shape_key)

      assert {:error, %{code: :api_key_missing}} = Access.authenticate_authorization_header(nil)
    end

    test "paused, revoked, and expired keys are denied deterministically" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: paused_key, raw_key: paused_raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Paused key"})

      assert {:ok, _paused_key} = Access.pause_api_key(scope, paused_key)
      assert {:error, %{code: :api_key_paused}} = Access.authenticate_api_key(paused_raw_key)

      assert {:ok, %{api_key: revoked_key, raw_key: revoked_raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Revoked key"})

      assert {:ok, _revoked_key} = Access.revoke_api_key(scope, revoked_key)
      assert {:error, %{code: :api_key_revoked}} = Access.authenticate_api_key(revoked_raw_key)

      assert {:ok, %{raw_key: expired_raw_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Expired key",
                 expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
               })

      assert {:error, %{code: :api_key_expired}} = Access.authenticate_api_key(expired_raw_key)
    end

    test "v1 api keys require an active pool before returning an auth context" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{raw_key: raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Inactive pool key"})

      assert {:ok, _pool} = Pools.update_pool(scope, pool, %{status: "disabled"})

      assert {:error, %{code: :api_key_missing}} = Access.authenticate_api_key(raw_key)
      assert {:error, %{code: :api_key_missing}} = Access.authenticate_v1_api_key(raw_key)
    end
  end

  describe "assigned-admin API key scoping" do
    test "pool count projections include visible key statuses and exclude inactive parent pools" do
      {scope, active_pool} = owner_scope_and_pool()

      assert {:ok, disabled_pool} =
               Pools.create_pool(scope, %{
                 slug: "count-disabled-#{System.unique_integer([:positive])}",
                 name: "Count Disabled"
               })

      assert {:ok, archived_pool} =
               Pools.create_pool(scope, %{
                 slug: "count-archived-#{System.unique_integer([:positive])}",
                 name: "Count Archived"
               })

      assert {:ok, %{api_key: active_key}} =
               Access.create_api_key(scope, active_pool, %{display_name: "Count active"})

      assert {:ok, %{api_key: paused_key}} =
               Access.create_api_key(scope, active_pool, %{display_name: "Count paused"})

      assert {:ok, _paused_key} = Access.pause_api_key(scope, paused_key)

      assert {:ok, %{api_key: revoked_key}} =
               Access.create_api_key(scope, active_pool, %{display_name: "Count revoked"})

      assert {:ok, _revoked_key} = Access.revoke_api_key(scope, revoked_key)

      assert {:ok, %{api_key: disabled_key}} =
               Access.create_api_key(scope, disabled_pool, %{display_name: "Count disabled"})

      assert {:ok, %{api_key: archived_key}} =
               Access.create_api_key(scope, archived_pool, %{display_name: "Count archived"})

      assert {:ok, disabled_pool} = Pools.change_pool_status(scope, disabled_pool, "disabled")
      assert {:ok, archived_pool} = Pools.change_pool_status(scope, archived_pool, "archived")

      counts =
        Access.count_api_keys_by_pool_ids([
          active_pool.id,
          disabled_pool.id,
          archived_pool.id
        ])

      assert counts[active_pool.id] == 3
      assert counts[disabled_pool.id] == 0
      assert counts[archived_pool.id] == 0

      assert Repo.get!(APIKey, active_key.id).status == "active"
      assert Repo.get!(APIKey, paused_key.id).status == "paused"
      assert Repo.get!(APIKey, revoked_key.id).status == "revoked"
      assert Repo.get!(APIKey, disabled_key.id).pool_id == disabled_pool.id
      assert Repo.get!(APIKey, archived_key.id).pool_id == archived_pool.id
    end

    test "assigned admins list and read only API keys from assigned pools" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      owner_scope = Scope.for_user(owner)
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})

      pool_a = pool_fixture(%{name: "Pool A"})
      pool_b = pool_fixture(%{name: "Pool B"})
      pool_c = pool_fixture(%{name: "Pool C"})

      operator_pool_assignment_fixture(admin, pool_a, created_by_user_id: owner.id)
      operator_pool_assignment_fixture(admin, pool_b, created_by_user_id: owner.id)
      admin_scope = Scope.for_user(admin)

      {:ok, %{api_key: key_a}} = Access.create_api_key(owner_scope, pool_a, %{display_name: "A"})
      {:ok, %{api_key: key_b}} = Access.create_api_key(owner_scope, pool_b, %{display_name: "B"})
      {:ok, %{api_key: key_c}} = Access.create_api_key(owner_scope, pool_c, %{display_name: "C"})

      assert {:ok, visible_keys} = Access.list_api_keys(admin_scope)
      assert Enum.map(visible_keys, & &1.id) |> Enum.sort() == Enum.sort([key_a.id, key_b.id])
      assert {:ok, ^key_a} = Access.get_api_key(admin_scope, key_a.id)
      assert {:error, %{code: :api_key_not_found}} = Access.get_api_key(admin_scope, key_c.id)
    end

    test "unassigned admins cannot list read or create API keys for any pool" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      owner_scope = Scope.for_user(owner)
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})

      pool = pool_fixture(%{name: "Hidden API Key Pool"})

      {:ok, %{api_key: api_key}} =
        Access.create_api_key(owner_scope, pool, %{display_name: "Hidden"})

      admin_scope = Scope.for_user(admin)

      assert {:ok, []} = Access.list_api_keys(admin_scope)
      assert {:error, %{code: :api_key_not_found}} = Access.get_api_key(admin_scope, api_key.id)

      assert {:error, %{code: :capability_denied}} =
               Access.create_api_key(admin_scope, pool, %{display_name: "Denied"})

      assert Repo.get!(APIKey, api_key.id).status == "active"
    end

    test "assigned admins cannot mutate or move API keys through unassigned pools" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      owner_scope = Scope.for_user(owner)
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})

      pool_a = pool_fixture(%{name: "Pool A"})
      pool_c = pool_fixture(%{name: "Pool C"})

      operator_pool_assignment_fixture(admin, pool_a, created_by_user_id: owner.id)
      admin_scope = Scope.for_user(admin)

      {:ok, %{api_key: assigned_key}} =
        Access.create_api_key(owner_scope, pool_a, %{display_name: "Assigned"})

      {:ok, %{api_key: hidden_key}} =
        Access.create_api_key(owner_scope, pool_c, %{display_name: "Hidden"})

      assert {:error, %{code: :capability_denied}} =
               Access.create_api_key(admin_scope, pool_c, %{display_name: "Denied"})

      assert {:error, %{code: :capability_denied}} =
               Access.update_api_key(admin_scope, assigned_key, %{pool_id: pool_c.id})

      assert {:error, %{code: :capability_denied}} =
               Access.update_api_key(admin_scope, hidden_key, %{display_name: "Denied"})

      assert {:error, %{code: :capability_denied}} =
               Access.assign_api_keys_to_pool(admin_scope, pool_c, [])

      assert Repo.get!(APIKey, assigned_key.id).pool_id == pool_a.id
      assert Repo.get!(APIKey, hidden_key.id).display_name == "Hidden"
    end
  end

  describe "api key policy contract" do
    defp api_key_policy_contract do
      [
        %{
          field: "name",
          codex_pooler: :display_name,
          storage: {:current, :api_keys, :display_name},
          runtime: :not_applicable,
          ui_step: :basics,
          tests: [:liveview_create_edit]
        },
        %{
          field: "expiresAt",
          codex_pooler: :expires_at,
          storage: {:current, :api_keys, :expires_at},
          runtime: {:current, :deny_expired_before_routing},
          ui_step: :basics,
          tests: [:expired_key_denied]
        },
        %{
          field: "isActive",
          codex_pooler: :status,
          storage: {:current, :api_keys, :status},
          runtime: {:current, :deny_paused_or_revoked},
          ui_step: :basics,
          tests: [:inactive_key_denied]
        },
        %{
          field: "allowedModels",
          codex_pooler: :allowed_model_identifiers,
          storage: {:current, :api_keys, :allowed_model_identifiers},
          runtime: {:current, :model_policy_authorization},
          ui_step: :models,
          tests: [nil, :empty, :selected, :manual, :stale]
        },
        %{
          field: "enforcedModel",
          codex_pooler: :enforced_model_identifier,
          storage: {:current, :api_keys, :enforced_model_identifier},
          runtime: {:planned_missing, :request_model_rewritten_before_visible_lookup},
          ui_step: :models,
          tests: [:payload_model_rewritten, :incompatible_denied]
        },
        %{
          field: "enforcedReasoningEffort",
          codex_pooler: :enforced_reasoning_effort,
          storage: {:current, :api_keys, :enforced_reasoning_effort},
          runtime: {:planned_missing, :request_payload_enforced},
          ui_step: :models,
          tests: [:payload_enforced]
        },
        %{
          field: "enforcedServiceTier",
          codex_pooler: :enforced_service_tier,
          storage: {:current, :api_keys, :enforced_service_tier},
          runtime: {:planned_missing, :request_payload_enforced},
          ui_step: :models,
          tests: [:payload_enforced]
        },
        %{
          field: "weekly token limit",
          codex_pooler: :max_tokens_per_week,
          storage: {:current, :api_key_policy_bindings, :max_tokens_per_week},
          runtime: {:planned_missing, :accounting_limit_check},
          ui_step: :limits,
          tests: [:exceeded_denied]
        },
        %{
          field: "advanced limit rules",
          codex_pooler: :api_key_policy_bindings,
          storage: {:current, :api_key_policy_bindings, :default_and_model_rows},
          runtime: {:planned_missing, :accounting_and_gateway_limit_enforcement},
          ui_step: :limits,
          tests: [:default_limits, :model_scoped_limits]
        },
        %{
          field: "usage/current usage/trends",
          codex_pooler: :accounting_usage_summary,
          storage: {:current, :accounting_request_data, :usage_summary_basis},
          runtime: :read_only,
          ui_step: :review_edit,
          tests: [:summary_display_tests]
        }
      ]
    end

    @tag :api_key_policy_contract
    test "documents the API-key policy surface without runtime changes" do
      contract = api_key_policy_contract()

      assert Enum.map(contract, & &1.field) == [
               "name",
               "expiresAt",
               "isActive",
               "allowedModels",
               "enforcedModel",
               "enforcedReasoningEffort",
               "enforcedServiceTier",
               "weekly token limit",
               "advanced limit rules",
               "usage/current usage/trends"
             ]

      assert Enum.find(contract, &(&1.field == "allowedModels")).runtime ==
               {:current, :model_policy_authorization}

      planned_missing_storage =
        contract
        |> Enum.filter(fn row -> match?({:planned_missing, _table, _field}, row.storage) end)
        |> Enum.map(& &1.field)

      assert planned_missing_storage == []

      planned_missing_runtime =
        contract
        |> Enum.filter(fn row -> match?({:planned_missing, _reason}, row.runtime) end)
        |> Enum.map(& &1.field)

      assert planned_missing_runtime == [
               "enforcedModel",
               "enforcedReasoningEffort",
               "enforcedServiceTier",
               "weekly token limit",
               "advanced limit rules"
             ]

      assert Enum.find(contract, &(&1.field == "advanced limit rules")).runtime ==
               {:planned_missing, :accounting_and_gateway_limit_enforcement}
    end

    @tag :api_key_policy_contract
    test "exposes the stable denial reason precedence as strings" do
      assert Enum.map(Access.policy_denial_precedence(), &Atom.to_string/1) == [
               "api_key_missing",
               "api_key_disabled",
               "api_key_policy_malformed",
               "model_not_allowed",
               "quota_unavailable",
               "quota_exhausted",
               "no_eligible_upstream"
             ]
    end

    @tag :api_key_policy_contract
    test "missing and disabled policies use the first policy reason codes" do
      {scope, pool} = owner_scope_and_pool()

      assert {:error, :api_key_missing} = Access.normalize_api_key_policy(nil)

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Disabled policy key"})

      assert {:ok, paused_key} = Access.pause_api_key(scope, api_key)
      assert {:error, :api_key_disabled} = Access.normalize_api_key_policy(paused_key)
      assert {:error, :api_key_disabled} = Access.normalize_api_key_policy(%{enabled: false})
    end

    @tag :api_key_policy_contract
    @tag :malformed_policy
    test "malformed API-key policy fails closed" do
      assert {:error, :api_key_policy_malformed} =
               Access.normalize_api_key_policy(%{allowed_model_identifiers: "gpt-5"})

      assert {:error, :api_key_policy_malformed} =
               Access.normalize_api_key_policy(%{allowed_model_identifiers: ["gpt-5", nil]})

      assert {:error, :api_key_policy_malformed} =
               Access.normalize_api_key_policy(%{allowed_model_identifiers: ["gpt 5"]})

      assert {:error, :api_key_policy_malformed} =
               Access.normalize_api_key_policy(%{metadata: %{"labels" => "production"}})

      assert {:error, :api_key_policy_malformed} =
               Access.normalize_api_key_policy(%{enforced_reasoning_effort: "ultra"})

      assert {:error, :api_key_policy_malformed} =
               Access.normalize_api_key_policy(%{enforced_reasoning_effort: 123})
    end

    @tag :api_key_policy_contract
    test "missing and nil allow-list fields are unrestricted for their dimensions" do
      assert {:ok, policy} = Access.normalize_api_key_policy(%{})

      assert {:ok, ^policy} =
               Access.authorize_api_key_policy(policy, %{
                 model_identifier: "any-model"
               })

      assert {:ok, nil_policy} =
               Access.normalize_api_key_policy(%{
                 allowed_model_identifiers: nil
               })

      assert {:ok, ^nil_policy} =
               Access.authorize_api_key_policy(nil_policy, %{
                 model_identifier: "any-other-model"
               })
    end

    @tag :api_key_policy_contract
    test "normalizes max enforced reasoning effort" do
      assert {:ok, policy} =
               Access.normalize_api_key_policy(%{enforced_reasoning_effort: " Max "})

      assert policy.enforced_reasoning_effort == "max"
    end

    @tag :api_key_policy_contract
    @tag :empty_allow_lists
    test "empty model allow-list denies all models" do
      assert {:ok, policy} = Access.normalize_api_key_policy(%{allowed_model_identifiers: []})

      assert {:error, :model_not_allowed} =
               Access.authorize_api_key_policy(policy, %{model_identifier: "gpt-5.4-mini"})
    end

    @tag :api_key_policy_contract
    test "selected model allow-list authorizes only selected models" do
      assert {:ok, policy} =
               Access.normalize_api_key_policy(%{allowed_model_identifiers: ["gpt-selected"]})

      assert {:ok, ^policy} =
               Access.authorize_api_key_policy(policy, %{model_identifier: "GPT-Selected"})

      assert {:error, :model_not_allowed} =
               Access.authorize_api_key_policy(policy, %{model_identifier: "gpt-other"})
    end

    @tag :api_key_policy_contract
    test "normalizes allowed models and metadata" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{
                 display_name: "Restricted key",
                 policy: %{
                   allowed_model_identifiers: [" GPT-5.4-Mini ", "gpt-5.4-mini"],
                   metadata: %{
                     "labels" => [" production ", "production", ""],
                     "operator_notes" => "Created for a focused tenant rollout"
                   }
                 }
               })

      persisted = Repo.get!(APIKey, api_key.id)

      assert {:ok, policy} = Access.normalize_api_key_policy(persisted)
      assert policy.allowed_model_identifiers == ["gpt-5.4-mini"]
      assert policy.metadata["labels"] == ["production"]
      assert policy.metadata["operator_notes"] == "Created for a focused tenant rollout"

      assert {:ok, ^policy} =
               Access.authorize_api_key_policy(policy, %{
                 model: "GPT-5.4-MINI"
               })
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

  defp count_api_key_updates(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, :api_key_updates, System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = Map.get(metadata, :query, "")
          source = Map.get(metadata, :source)

          if source == "api_keys" and String.starts_with?(query, "UPDATE") do
            send(parent, {handler_id, :api_key_update})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, count_received_api_key_updates(handler_id, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp count_received_api_key_updates(handler_id, count) do
    receive do
      {^handler_id, :api_key_update} -> count_received_api_key_updates(handler_id, count + 1)
    after
      0 -> count
    end
  end
end
