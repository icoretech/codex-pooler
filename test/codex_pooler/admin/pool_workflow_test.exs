defmodule CodexPooler.Admin.PoolWorkflowTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  describe "pool workflow broadcasts" do
    test "broadcasts one pool event after coordinated creation commits" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      assert :ok = Events.subscribe_all_pools()

      assert {:ok, pool} =
               publish_from_task(fn ->
                 PoolWorkflow.create_pool_with_related_settings(scope, %{
                   "name" => "Workflow Commit",
                   "routing_strategy" => "bridge_ring"
                 })
               end)

      assert Pools.get_pool(pool.id)
      assert_receive {Events, event}
      assert event.pool_id == pool.id
      assert event.reason == "pool_created"
      assert event.payload["status"] == "active"
      refute_receive {Events, _event}
    end

    test "does not broadcast when a later coordinated creation step rolls back" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      missing_api_key_id = Ecto.UUID.generate()
      assert :ok = Events.subscribe_all_pools()

      assert {:error, %{message: "selected API keys are not available"}} =
               publish_from_task(fn ->
                 PoolWorkflow.create_pool_with_related_settings(scope, %{
                   "name" => "Workflow Rollback",
                   "api_key_ids" => [missing_api_key_id],
                   "routing_strategy" => "bridge_ring"
                 })
               end)

      refute Repo.get_by(Pool, slug: "workflow-rollback")
      refute_receive {Events, _event}
    end

    test "update accepts upstream identity ids for target-pool sync and preserves detached identities" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      source_pool = pool_fixture(%{slug: "workflow-source", name: "Workflow Source"})
      target_pool = pool_fixture(%{slug: "workflow-target", name: "Workflow Target"})
      assert :ok = Events.subscribe_all_pools()

      %{identity: moved_identity, assignment: source_assignment} =
        upstream_assignment_fixture(source_pool, %{chatgpt_account_id: "acct_workflow_move"})

      %{identity: detached_identity, assignment: target_assignment} =
        upstream_assignment_fixture(target_pool, %{chatgpt_account_id: "acct_workflow_detach"})

      assert {:ok, updated_pool} =
               publish_from_task(fn ->
                 PoolWorkflow.update_pool_with_related_settings(scope, target_pool, %{
                   "name" => "Workflow Target Updated",
                   "status" => "active",
                   "routing_strategy" => "bridge_ring",
                   "upstream_identity_ids" => [moved_identity.id],
                   "api_key_ids" => []
                 })
               end)

      assert updated_pool.id == target_pool.id
      assert updated_pool.name == "Workflow Target Updated"

      target_assignments =
        target_pool
        |> Upstreams.list_pool_assignments()
        |> Map.new(&{&1.upstream_identity_id, &1.status})

      assert target_assignments == %{
               detached_identity.id => "deleted",
               moved_identity.id => "active"
             }

      assert Repo.get!(PoolUpstreamAssignment, source_assignment.id).status == "active"
      assert Repo.get!(PoolUpstreamAssignment, target_assignment.id).status == "deleted"
      assert Repo.get!(UpstreamIdentity, detached_identity.id).status == "active"
      assert_receive {Events, event}
      assert event.pool_id == target_pool.id
      assert event.reason == "pool_updated"
      refute_receive {Events, _event}
    end
  end

  describe "pool routing settings workflow" do
    test "creation persists request compression routing setting when enabled" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} =
               PoolWorkflow.create_pool_with_related_settings(scope, %{
                 "name" => "Compression Workflow Create",
                 "routing_strategy" => "bridge_ring",
                 "request_compression_enabled" => "true"
               })

      settings = Pools.get_routing_settings(pool)

      assert settings.request_compression_enabled == true
      assert settings.prompt_cache_affinity_enabled == true
      assert settings.v1_compatibility_enabled == true
    end

    test "update persists request compression routing setting with compatibility toggles" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{slug: "compression-workflow-edit", name: "Compression Workflow Edit"})

      assert {:ok, _settings} =
               Pools.update_routing_settings(scope, pool, %{
                 "request_compression_enabled" => true
               })

      assert {:ok, updated_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, pool, %{
                 "name" => "Compression Workflow Updated",
                 "status" => "active",
                 "routing_strategy" => "bridge_ring",
                 "prompt_cache_affinity_enabled" => "false",
                 "v1_compatibility_enabled" => "false",
                 "request_compression_enabled" => "false",
                 "upstream_identity_ids" => [],
                 "api_key_ids" => []
               })

      settings = Pools.get_routing_settings(updated_pool)

      assert updated_pool.id == pool.id
      assert settings.request_compression_enabled == false
      assert settings.prompt_cache_affinity_enabled == false
      assert settings.v1_compatibility_enabled == false
    end
  end

  defp publish_from_task(fun) when is_function(fun, 0) do
    fun
    |> Task.async()
    |> Task.await(5_000)
  end
end
