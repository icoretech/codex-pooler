defmodule CodexPooler.PoolsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment, RoutingSettings}
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures, only: [operator_pool_assignment_fixture: 3]

  describe "pool lifecycle" do
    test "instance owners create normalized pools and list active pools" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} = Pools.create_pool(scope, %{slug: " Team-Alpha ", name: " Team Alpha "})

      assert pool.slug == "team-alpha"
      assert pool.name == "Team Alpha"
      assert pool.status == "active"
      assert pool.created_by_user_id == owner.id
      assert {:ok, [^pool]} = Pools.list_pools(scope)
      assert Pools.list_visible_pools(scope) == [pool]
      assert Enum.any?(Pools.list_log_filter_pools(scope), &(&1.id == pool.id))

      assert audit = Repo.get_by(AuditEvent, action: "pool.create", target_id: pool.id)
      assert audit.actor_user_id == owner.id
      assert audit.pool_id == pool.id
      assert audit.details["slug"] == "team-alpha"
      assert audit.details["status"] == "active"
    end

    test "updating a pool to archived revokes assigned admins through the update path" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} =
               Pools.create_pool(owner_scope, %{slug: "update-archive", name: "Update Archive"})

      admin = user_fixture(%{"email" => "update-archive-admin@example.com"})

      assert {:ok, _membership} =
               Pools.create_membership(owner_scope, %{user_id: admin.id, role: "instance_admin"})

      assignment = operator_pool_assignment_fixture(admin, pool, created_by_user_id: owner.id)

      assert {:ok, archived_pool} = Pools.update_pool(owner_scope, pool, %{status: "archived"})
      assert archived_pool.status == "archived"

      revoked_assignment = Repo.get!(OperatorPoolAssignment, assignment.id)
      assert revoked_assignment.status == "revoked"
      assert revoked_assignment.revoked_at
      assert revoked_assignment.updated_at == revoked_assignment.revoked_at
      assert Scope.for_user(admin).assigned_pool_ids == []
    end

    test "archiving a pool revokes assigned admins and restoration does not restore grants" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} =
               Pools.create_pool(owner_scope, %{
                 slug: "assignment-archive",
                 name: "Assignment Archive"
               })

      admin = user_fixture(%{"email" => "archive-admin@example.com"})

      assert {:ok, _membership} =
               Pools.create_membership(owner_scope, %{user_id: admin.id, role: "instance_admin"})

      assignment = operator_pool_assignment_fixture(admin, pool, created_by_user_id: owner.id)

      assert Scope.for_user(admin).assigned_pool_ids == [pool.id]
      assert Enum.map(Pools.list_visible_pools(Scope.for_user(admin)), & &1.id) == [pool.id]

      assert {:ok, archived_pool} = Pools.change_pool_status(owner_scope, pool, "archived")
      assert archived_pool.status == "archived"

      revoked_assignment = Repo.get!(OperatorPoolAssignment, assignment.id)
      assert revoked_assignment.status == "revoked"
      assert revoked_assignment.revoked_at
      assert revoked_assignment.updated_at == revoked_assignment.revoked_at

      assert Scope.for_user(admin).assigned_pool_ids == []
      assert Pools.list_visible_pools(Scope.for_user(admin)) == []
      refute Pools.assigned_pool?(Scope.for_user(admin), pool)

      assert Pools.can_manage_pools?(Scope.for_user(owner, []))
      assert {:ok, management_pools} = Pools.list_pools_for_management(Scope.for_user(owner, []))
      assert Enum.any?(management_pools, &(&1.id == pool.id and &1.status == "archived"))

      assert {:ok, restored_pool} = Pools.change_pool_status(owner_scope, archived_pool, "active")
      assert restored_pool.status == "active"
      assert Scope.for_user(admin).assigned_pool_ids == []
      assert Pools.list_visible_pools(Scope.for_user(admin)) == []

      assert {:ok, archived_again} =
               Pools.change_pool_status(owner_scope, restored_pool, "archived")

      assert {:ok, _deleted_pool} =
               Pools.delete_archived_pool(owner_scope, archived_again, archived_again.slug)

      refute Repo.get(OperatorPoolAssignment, assignment.id)

      assert {:ok, replacement_pool} =
               Pools.create_pool(owner_scope, %{slug: pool.slug, name: "Assignment Archive Again"})

      assert Scope.for_user(admin).assigned_pool_ids == []
      refute Pools.assigned_pool?(Scope.for_user(admin), replacement_pool)
    end

    test "pool slugs stay unique until archived deletion is confirmed" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} = Pools.create_pool(scope, %{slug: "shared", name: "Shared"})
      assert {:error, changeset} = Pools.create_pool(scope, %{slug: "SHARED", name: "Shared 2"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)

      assert {:error, %{code: :pool_not_archived}} = Pools.delete_pool(scope, pool)
      assert Pools.get_pool(pool.id)

      assert {:ok, archived_pool} = Pools.change_pool_status(scope, pool, "archived")
      assert {:error, %{code: :confirmation_mismatch}} = Pools.delete_pool(scope, archived_pool)
      assert Pools.get_pool(pool.id)

      assert {:ok, deleted_pool} =
               Pools.delete_archived_pool(scope, archived_pool, archived_pool.slug)

      assert deleted_pool.id == pool.id
      refute Pools.get_pool(pool.id)

      assert {:ok, replacement} =
               Pools.create_pool(scope, %{slug: "shared", name: "Shared Again"})

      assert replacement.slug == "shared"
    end
  end

  describe "pool management" do
    test "routing settings load defaults, feature flags, and persisted strategies by pool id" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} =
               Pools.create_pool(scope, %{slug: "routing-default", name: "Routing Default"})

      refute Pools.get_routing_settings(pool)
      refute Repo.get(RoutingSettings, pool.id)

      assert %RoutingSettings{
               pool_id: pool_id,
               routing_strategy: "bridge_ring",
               bridge_ring_size: 3,
               sticky_websocket_sessions: true,
               sticky_http_sessions: false,
               prompt_cache_affinity_enabled: true,
               v1_compatibility_enabled: true,
               request_compression_enabled: false,
               allow_image_generation: true
             } = Pools.routing_settings_with_defaults(pool)

      assert pool_id == pool.id
      refute Repo.get(RoutingSettings, pool.id)

      assert %RoutingSettings{
               routing_strategy: "bridge_ring",
               prompt_cache_affinity_enabled: true,
               v1_compatibility_enabled: true,
               request_compression_enabled: false,
               allow_image_generation: true
             } =
               Pools.ensure_routing_settings(pool)

      assert Pools.v1_compatibility_enabled?(pool)

      assert {:ok, routed_pool} =
               Pools.create_pool(scope, %{slug: "routing-custom", name: "Routing Custom"})

      assert {:ok, _updated_pool} =
               Pools.update_routing_settings(scope, routed_pool, %{
                 "routing_strategy" => "deterministic_rotation",
                 "bridge_ring_size" => 5,
                 "sticky_websocket_sessions" => false,
                 "sticky_http_sessions" => true,
                 "prompt_cache_affinity_enabled" => false,
                 "v1_compatibility_enabled" => false,
                 "request_compression_enabled" => "true",
                 "allow_image_generation" => false
               })

      refute Pools.get_routing_settings(routed_pool).prompt_cache_affinity_enabled
      assert Pools.get_routing_settings(routed_pool).request_compression_enabled
      refute Pools.get_routing_settings(routed_pool).allow_image_generation
      refute Pools.routing_settings_with_defaults(routed_pool).prompt_cache_affinity_enabled

      assert Pools.routing_settings_with_defaults(routed_pool).request_compression_enabled
      refute Pools.v1_compatibility_enabled?(routed_pool)

      assert {:ok, %RoutingSettings{} = reenabled_settings} =
               Pools.update_routing_settings(scope, routed_pool, %{
                 "prompt_cache_affinity_enabled" => true,
                 "v1_compatibility_enabled" => true,
                 "request_compression_enabled" => false
               })

      assert reenabled_settings.prompt_cache_affinity_enabled
      assert reenabled_settings.v1_compatibility_enabled
      refute reenabled_settings.request_compression_enabled
      assert Pools.v1_compatibility_enabled?(routed_pool)

      assert {:ok, %RoutingSettings{} = string_disabled_settings} =
               Pools.update_routing_settings(scope, routed_pool, %{
                 "request_compression_enabled" => "false"
               })

      refute string_disabled_settings.request_compression_enabled

      assert {:ok, %RoutingSettings{} = invalid_disabled_settings} =
               Pools.update_routing_settings(scope, routed_pool, %{
                 "request_compression_enabled" => "invalid"
               })

      refute invalid_disabled_settings.request_compression_enabled

      audits =
        Repo.all(
          from audit in AuditEvent,
            where: audit.action == "pool.routing_update" and audit.target_id == ^routed_pool.id,
            order_by: [asc: audit.occurred_at]
        )

      assert Enum.map(audits, & &1.details["routing_strategy"]) == [
               "deterministic_rotation",
               "deterministic_rotation",
               "deterministic_rotation",
               "deterministic_rotation"
             ]

      assert Enum.map(audits, & &1.details["sticky_http_sessions"]) == [true, true, true, true]

      assert Enum.map(audits, & &1.details["prompt_cache_affinity_enabled"]) == [
               false,
               true,
               true,
               true
             ]

      assert Enum.map(audits, & &1.details["request_compression_enabled"]) == [
               true,
               false,
               false,
               false
             ]

      assert Enum.all?(audits, &is_boolean(&1.details["prompt_cache_affinity_enabled"]))
      assert Enum.all?(audits, &is_boolean(&1.details["request_compression_enabled"]))

      assert Enum.map(audits, & &1.pool_id) == [
               routed_pool.id,
               routed_pool.id,
               routed_pool.id,
               routed_pool.id
             ]

      pool_id = pool.id
      routed_pool_id = routed_pool.id
      missing_pool_id = Ecto.UUID.generate()

      settings_by_pool_id =
        Pools.routing_settings_by_pool_ids([pool_id, routed_pool_id, missing_pool_id])

      assert %{
               ^pool_id => %RoutingSettings{
                 routing_strategy: "bridge_ring",
                 prompt_cache_affinity_enabled: true,
                 v1_compatibility_enabled: true,
                 request_compression_enabled: false,
                 allow_image_generation: true
               },
               ^routed_pool_id => %RoutingSettings{
                 routing_strategy: "deterministic_rotation",
                 prompt_cache_affinity_enabled: true,
                 v1_compatibility_enabled: true,
                 request_compression_enabled: false,
                 allow_image_generation: false
               },
               ^missing_pool_id => %RoutingSettings{
                 routing_strategy: "bridge_ring",
                 prompt_cache_affinity_enabled: true,
                 v1_compatibility_enabled: true,
                 request_compression_enabled: false,
                 allow_image_generation: true
               }
             } = settings_by_pool_id
    end

    test "routing settings persist false image generation permission and reject nil" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "image-permission-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} =
               Pools.create_pool(scope, %{
                 slug: "image-generation-permission",
                 name: "Image Generation Permission"
               })

      assert {:ok, %RoutingSettings{allow_image_generation: false}} =
               Pools.update_routing_settings(scope, pool, %{
                 "allow_image_generation" => false
               })

      assert Repo.get!(RoutingSettings, pool.id).allow_image_generation == false

      assert {:error, changeset} =
               Pools.update_routing_settings(scope, pool, %{
                 "allow_image_generation" => nil
               })

      assert %{allow_image_generation: ["can't be blank"]} = errors_on(changeset)
      assert Repo.get!(RoutingSettings, pool.id).allow_image_generation == false
    end

    test "routing settings persist boolean request compression enablement" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "compression-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} =
               Pools.create_pool(scope, %{
                 slug: "request-compression-boolean",
                 name: "Request Compression Boolean"
               })

      assert {:ok, %RoutingSettings{} = settings} =
               Pools.update_routing_settings(scope, pool, %{
                 "request_compression_enabled" => true
               })

      assert settings.request_compression_enabled == true
      assert Repo.get!(RoutingSettings, pool.id).request_compression_enabled == true
      assert Pools.get_routing_settings(pool).request_compression_enabled == true
    end

    test "pool workflow defaults prompt cache affinity on and persists explicit disables" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, default_pool} =
               PoolWorkflow.create_pool_with_related_settings(scope, %{
                 "name" => "Workflow Default"
               })

      assert Pools.get_routing_settings(default_pool).prompt_cache_affinity_enabled == true

      assert {:ok, disabled_pool} =
               PoolWorkflow.create_pool_with_related_settings(scope, %{
                 "name" => "Workflow Disabled",
                 "prompt_cache_affinity_enabled" => "false"
               })

      assert Pools.get_routing_settings(disabled_pool).prompt_cache_affinity_enabled == false

      assert {:ok, _updated_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, disabled_pool, %{
                 "name" => disabled_pool.name,
                 "status" => disabled_pool.status,
                 "prompt_cache_affinity_enabled" => true
               })

      assert Pools.get_routing_settings(disabled_pool).prompt_cache_affinity_enabled == true
    end

    test "instance owner memberships can list and manage all pools without cached scope roles" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])
      db_owner_scope = Scope.for_user(owner, [])

      assert {:ok, managed_pool} =
               Pools.create_pool(owner_scope, %{slug: "managed", name: "Managed"})

      assert {:ok, disabled_pool} =
               Pools.create_pool(owner_scope, %{slug: "disabled", name: "Disabled"})

      assert {:ok, archived_pool} =
               Pools.create_pool(owner_scope, %{slug: "archived", name: "Archived"})

      assert {:ok, _disabled_pool} =
               Pools.change_pool_status(db_owner_scope, disabled_pool, "disabled")

      assert {:ok, _archived_pool} =
               Pools.change_pool_status(db_owner_scope, archived_pool, "archived")

      assert Pools.can_manage_pools?(db_owner_scope)
      refute Pools.can_manage_pools?(nil)

      assert {:ok, managed_pools} = Pools.list_pools_for_management(db_owner_scope)
      managed_pools_by_id = Map.new(managed_pools, &{&1.id, &1})

      assert managed_pools_by_id[managed_pool.id].status == "active"
      assert managed_pools_by_id[disabled_pool.id].status == "disabled"
      assert managed_pools_by_id[archived_pool.id].status == "archived"
      assert managed_pools_by_id[managed_pool.id].slug == "managed"
      assert managed_pools_by_id[disabled_pool.id].slug == "disabled"
      assert managed_pools_by_id[archived_pool.id].slug == "archived"

      managed_updated_at = managed_pool.updated_at

      assert {:ok, updated_pool} =
               Pools.update_pool(db_owner_scope, managed_pool, %{
                 name: "Managed Prime",
                 slug: "ignored"
               })

      assert updated_pool.id == managed_pool.id
      assert updated_pool.slug == managed_pool.slug
      assert updated_pool.name == "Managed Prime"
      assert DateTime.compare(updated_pool.updated_at, managed_updated_at) == :gt

      assert update_audit =
               Repo.get_by(AuditEvent, action: "pool.update", target_id: managed_pool.id)

      assert update_audit.pool_id == managed_pool.id
      assert update_audit.details["changed_fields"] == ["name"]

      assert {:ok, status_pool} =
               Pools.create_pool(owner_scope, %{slug: "status-change", name: "Status Change"})

      status_updated_at = status_pool.updated_at

      assert {:ok, transitioned_pool} =
               Pools.change_pool_status(db_owner_scope, status_pool, "disabled")

      assert transitioned_pool.id == status_pool.id
      assert transitioned_pool.status == "disabled"
      assert DateTime.compare(transitioned_pool.updated_at, status_updated_at) == :gt

      assert status_audit =
               Repo.get_by(AuditEvent, action: "pool.status_update", target_id: status_pool.id)

      assert status_audit.pool_id == status_pool.id
      assert status_audit.details["previous_status"] == "active"
      assert status_audit.details["status"] == "disabled"

      assert {:error, %{code: :invalid_status}} =
               Pools.change_pool_status(db_owner_scope, managed_pool, "paused")
    end

    test "invalid or missing scopes are denied" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} = Pools.create_pool(owner_scope, %{slug: "guarded", name: "Guarded"})

      assert {:error, %{code: :invalid_request}} = Pools.list_pools_for_management(nil)
      assert {:error, %{code: :invalid_request}} = Pools.list_pools_for_management(%{})
      assert {:error, %{code: :invalid_request}} = Pools.list_pools(nil)
      assert Pools.list_visible_pools(nil) == []
      assert Pools.list_log_filter_pools(nil) == []
      refute Pools.can_manage_pools?(%{})

      assert {:error, %{code: :invalid_request}} = Pools.update_pool(nil, pool, %{name: "Denied"})
      assert {:error, %{code: :invalid_request}} = Pools.change_pool_status(%{}, pool, "disabled")

      assert {:error, %{code: :invalid_request}} =
               Pools.delete_archived_pool(nil, pool, pool.slug)
    end

    test "archived pools require an exact slug confirmation before deletion" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])
      admin_scope = Scope.for_user(owner, [])

      assert {:ok, active_pool} =
               Pools.create_pool(owner_scope, %{slug: "active-delete", name: "Active Delete"})

      assert {:ok, disabled_pool} =
               Pools.create_pool(owner_scope, %{slug: "disabled-delete", name: "Disabled Delete"})

      assert {:ok, archived_pool} =
               Pools.create_pool(owner_scope, %{slug: "archived-delete", name: "Archived Delete"})

      assert {:ok, disabled_pool} =
               Pools.change_pool_status(admin_scope, disabled_pool, "disabled")

      assert {:ok, archived_pool} =
               Pools.change_pool_status(admin_scope, archived_pool, "archived")

      assert {:error, %{code: :pool_not_archived}} =
               Pools.delete_archived_pool(admin_scope, active_pool, active_pool.slug)

      assert {:error, %{code: :pool_not_archived}} =
               Pools.delete_archived_pool(admin_scope, disabled_pool, disabled_pool.slug)

      assert {:error, %{code: :confirmation_mismatch}} =
               Pools.delete_archived_pool(admin_scope, archived_pool, "wrong-slug")

      missing_id = Ecto.UUID.generate()

      assert {:error, %{code: :pool_not_found}} =
               Pools.delete_archived_pool(admin_scope, missing_id, missing_id)

      assert {:ok, deleted_pool} =
               Pools.delete_archived_pool(admin_scope, archived_pool, archived_pool.slug)

      assert deleted_pool.id == archived_pool.id
      refute Pools.get_pool(archived_pool.id)

      assert delete_audit =
               Repo.get_by(AuditEvent, action: "pool.delete", target_id: archived_pool.id)

      assert is_nil(delete_audit.pool_id)
      assert delete_audit.details["slug"] == archived_pool.slug
    end
  end

  describe "membership authorization" do
    test "canonical scope construction carries active roles and assigned pool ids" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner)

      assert owner_scope.roles == ["instance_owner"]
      assert owner_scope.assigned_pool_ids == []

      assert {:ok, assigned_pool} =
               Pools.create_pool(owner_scope, %{slug: "scope-assigned", name: "Scope Assigned"})

      assert {:ok, hidden_pool} =
               Pools.create_pool(owner_scope, %{slug: "scope-hidden", name: "Scope Hidden"})

      admin = user_fixture(%{"email" => "canonical-admin@example.com"})

      assert {:ok, _membership} =
               Pools.create_membership(owner_scope, %{user_id: admin.id, role: "instance_admin"})

      operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

      admin_scope = Scope.for_user(admin)

      assert admin_scope.roles == ["instance_admin"]
      assert admin_scope.assigned_pool_ids == [assigned_pool.id]
      assert Pools.list_assigned_pool_ids(admin_scope) == [assigned_pool.id]
      assert Enum.map(Pools.list_visible_pools(admin_scope), & &1.id) == [assigned_pool.id]
      refute Enum.any?(Pools.list_visible_pools(admin_scope), &(&1.id == hidden_pool.id))

      unassigned_admin = user_fixture(%{"email" => "canonical-unassigned@example.com"})

      assert {:ok, _membership} =
               Pools.create_membership(owner_scope, %{
                 user_id: unassigned_admin.id,
                 role: "instance_admin"
               })

      unassigned_scope = Scope.for_user(unassigned_admin)

      assert unassigned_scope.roles == ["instance_admin"]
      assert unassigned_scope.assigned_pool_ids == []
      assert Pools.list_assigned_pool_ids(unassigned_scope) == []
      assert Pools.list_visible_pools(unassigned_scope) == []
      assert Pools.list_log_filter_pools(unassigned_scope) == []
    end

    test "instance owner can manage pools globally" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, decision} = Pools.require_capability(scope, Pools.capability(:pool_manage))
      assert decision.actor_role == "instance_owner"
      assert decision.capability == Pools.capability(:pool_manage)
      assert is_nil(decision.pool_id)
    end

    test "instance admin pool capabilities require active operator pool assignments" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, assigned_pool} = Pools.create_pool(owner_scope, %{slug: "ops", name: "Ops"})

      assert {:ok, unassigned_pool} =
               Pools.create_pool(owner_scope, %{slug: "unassigned", name: "Unassigned"})

      assert {:ok, disabled_pool} =
               Pools.create_pool(owner_scope, %{slug: "disabled-ops", name: "Disabled Ops"})

      assert {:ok, disabled_pool} =
               Pools.change_pool_status(owner_scope, disabled_pool, "disabled")

      assert {:ok, revoked_pool} =
               Pools.create_pool(owner_scope, %{slug: "revoked-ops", name: "Revoked Ops"})

      admin = user_fixture(%{"email" => "admin@example.com"})

      assert {:ok, membership} =
               Pools.create_membership(owner_scope, %{user_id: admin.id, role: "instance_admin"})

      operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)
      operator_pool_assignment_fixture(admin, disabled_pool, created_by_user_id: owner.id)

      operator_pool_assignment_fixture(admin, revoked_pool,
        created_by_user_id: owner.id,
        status: "revoked"
      )

      admin_scope = Scope.for_user(admin, [])

      assert membership.role == "instance_admin"
      refute Pools.owner?(admin_scope)
      assert Pools.assigned_pool?(admin_scope, assigned_pool)
      refute Pools.assigned_pool?(admin_scope, unassigned_pool)
      refute Pools.assigned_pool?(admin_scope, revoked_pool)

      assert Pools.list_assigned_pool_ids(admin_scope) |> Enum.sort() ==
               [assigned_pool.id, disabled_pool.id] |> Enum.sort()

      assert {:ok, decision} =
               Pools.require_capability(admin_scope, Pools.capability(:pool_api_key_manage),
                 pool_id: assigned_pool.id
               )

      assert decision.actor_role == "instance_admin"
      assert decision.pool_id == assigned_pool.id

      assert {:ok, _decision} =
               Pools.require_capability(admin_scope, Pools.capability(:pool_operate),
                 pool_id: assigned_pool.id
               )

      assert {:error, %{code: :capability_denied}} =
               Pools.require_capability(admin_scope, Pools.capability(:pool_operate),
                 pool_id: unassigned_pool.id
               )

      assert {:error, %{code: :capability_denied}} =
               Pools.require_capability(admin_scope, Pools.capability(:pool_api_key_manage),
                 pool_id: revoked_pool.id
               )

      assert {:error, %{code: :pool_not_found}} =
               Pools.require_capability(admin_scope, Pools.capability(:pool_operate),
                 pool_id: disabled_pool.id
               )

      assert {:error, %{code: :capability_denied}} =
               Pools.require_capability(admin_scope, Pools.capability(:pool_operate))

      assert {:ok, visible_pools} = Pools.list_pools(admin_scope)
      assert Enum.map(visible_pools, & &1.slug) == [assigned_pool.slug]
      assert Enum.map(Pools.list_visible_pools(admin_scope), & &1.slug) == [assigned_pool.slug]

      assert Enum.map(Pools.list_log_filter_pools(admin_scope), & &1.slug) == [
               assigned_pool.slug,
               disabled_pool.slug
             ]

      assert {:error, %{code: :capability_denied}} =
               Pools.require_capability(admin_scope, Pools.capability(:pool_manage))

      refute Pools.can_manage_pools?(admin_scope)

      assert {:ok, scoped_management_pools} = Pools.list_pools_for_management(admin_scope)
      assert Enum.map(scoped_management_pools, & &1.id) == [assigned_pool.id]

      assert {:error, %{code: :capability_denied}} =
               Pools.create_pool(admin_scope, %{slug: "admin-global", name: "Admin Global"})
    end

    test "assigned admins cannot perform destructive pool lifecycle actions" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, assigned_pool} =
               Pools.create_pool(owner_scope, %{
                 slug: "assigned-lifecycle",
                 name: "Assigned Lifecycle"
               })

      assert {:ok, archived_pool} =
               Pools.create_pool(owner_scope, %{
                 slug: "assigned-archived",
                 name: "Assigned Archived"
               })

      assert {:ok, archived_pool} =
               Pools.change_pool_status(owner_scope, archived_pool, "archived")

      admin = user_fixture(%{"email" => "assigned-lifecycle-admin@example.com"})

      assert {:ok, _membership} =
               Pools.create_membership(owner_scope, %{user_id: admin.id, role: "instance_admin"})

      assignment =
        operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

      archived_assignment =
        operator_pool_assignment_fixture(admin, archived_pool, created_by_user_id: owner.id)

      admin_scope = Scope.for_user(admin, [])

      assert {:error, %{code: :capability_denied}} =
               Pools.update_pool(admin_scope, assigned_pool, %{status: "archived"})

      assert {:error, %{code: :capability_denied}} =
               Pools.change_pool_status(admin_scope, assigned_pool, "archived")

      assert {:error, %{code: :capability_denied}} =
               Pools.delete_archived_pool(admin_scope, archived_pool, archived_pool.slug)

      assert Repo.get!(Pools.Pool, assigned_pool.id).status == "active"
      assert Repo.get!(OperatorPoolAssignment, assignment.id).status == "active"
      assert Repo.get!(OperatorPoolAssignment, archived_assignment.id).status == "active"
      assert Repo.get!(Pools.Pool, archived_pool.id).status == "archived"
    end

    test "creates instance admin memberships through the pools boundary" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])
      scope_admin = user_fixture(%{"email" => "scope-admin@example.com"})
      user_admin = user_fixture(%{"email" => "user-admin@example.com"})
      owner_id = owner.id
      scope_admin_id = scope_admin.id
      user_admin_id = user_admin.id

      assert {:ok, scope_membership} =
               Pools.create_instance_admin_membership(owner_scope, scope_admin)

      assert %Membership{
               user_id: ^scope_admin_id,
               role: "instance_admin",
               status: "active",
               created_by_user_id: ^owner_id
             } = scope_membership

      assert {:ok, user_membership} = Pools.create_instance_admin_membership(owner, user_admin)

      assert %Membership{
               user_id: ^user_admin_id,
               role: "instance_admin",
               status: "active",
               created_by_user_id: ^owner_id
             } = user_membership
    end

    test "users without active memberships are denied deterministically" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner, ["instance_owner"])
      assert {:ok, pool} = Pools.create_pool(owner_scope, %{slug: "private", name: "Private"})

      user = user_fixture(%{"email" => "memberless@example.com"})
      scope = Scope.for_user(user, [])

      assert {:error, %{code: :capability_denied, message: message}} =
               Pools.require_capability(scope, Pools.capability(:pool_api_key_manage),
                 pool_id: pool.id
               )

      assert message =~ "node admins"
    end
  end

  defp user_fixture(attrs) do
    %User{}
    |> User.bootstrap_changeset(valid_bootstrap_attributes(attrs))
    |> Repo.insert!()
  end
end
