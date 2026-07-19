defmodule CodexPooler.Admin.PoolWorkflowTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Catalog
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

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
      assert_receive {Events, job_event}
      assert job_event.pool_id == target_pool.id
      assert job_event.reason == "job_status_updated"
      assert job_event.payload["worker"] == "catalog_sync"
      assert job_event.payload["status"] == "scheduled"
      refute_receive {Events, _event}
    end
  end

  describe "pool assignment catalog sync enqueue" do
    test "creation with upstream identity selection enqueues an immediate catalog sync" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "catalog-create-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      identity = active_upstream_identity_fixture(%{chatgpt_account_id: "acct_catalog_create"})

      assert {:ok, pool} =
               PoolWorkflow.create_pool_with_related_settings(scope, %{
                 "name" => "Catalog Create Sync",
                 "routing_strategy" => "bridge_ring",
                 "upstream_identity_ids" => [identity.id],
                 "api_key_ids" => []
               })

      assert [job] = all_enqueued(worker: CatalogSyncWorker)
      assert job.args == %{"pool_id" => pool.id, "trigger_kind" => "manual"}
    end

    test "active assignment edit enqueues one immediate catalog sync" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "catalog-edit-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{slug: "catalog-edit-sync", name: "Catalog Edit Sync"})
      %{assignment: assignment} = upstream_assignment_fixture(pool)

      assert {:ok, updated_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, pool, %{
                 "name" => "Catalog Edit Sync Updated",
                 "status" => "active",
                 "routing_strategy" => "bridge_ring",
                 "upstream_assignment_ids" => [assignment.id],
                 "api_key_ids" => []
               })

      assert updated_pool.id == pool.id
      assert [job] = all_enqueued(worker: CatalogSyncWorker)
      assert job.args == %{"pool_id" => pool.id, "trigger_kind" => "manual"}
    end

    test "rolled back assignment edit enqueues no catalog sync" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "catalog-rollback-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      missing_api_key_id = Ecto.UUID.generate()
      identity = active_upstream_identity_fixture(%{chatgpt_account_id: "acct_catalog_rollback"})

      assert {:error, %{message: "selected API keys are not available"}} =
               PoolWorkflow.create_pool_with_related_settings(scope, %{
                 "name" => "Catalog Rollback Sync",
                 "routing_strategy" => "bridge_ring",
                 "upstream_identity_ids" => [identity.id],
                 "api_key_ids" => [missing_api_key_id]
               })

      refute Repo.get_by(Pool, slug: "catalog-rollback-sync")
      assert [] = all_enqueued(worker: CatalogSyncWorker)
    end

    test "edit without assignment selection enqueues no catalog sync" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "catalog-noop-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{slug: "catalog-noop-sync", name: "Catalog Noop Sync"})

      assert {:ok, updated_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, pool, %{
                 "name" => "Catalog Noop Sync Updated",
                 "status" => "active",
                 "routing_strategy" => "bridge_ring",
                 "api_key_ids" => []
               })

      assert updated_pool.id == pool.id
      assert [] = all_enqueued(worker: CatalogSyncWorker)
    end

    test "final inactive pool assignment edit enqueues no catalog sync" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "catalog-inactive-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{slug: "catalog-inactive-sync", name: "Catalog Inactive Sync"})
      %{assignment: assignment} = upstream_assignment_fixture(pool)

      assert {:ok, updated_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, pool, %{
                 "name" => "Catalog Inactive Sync Updated",
                 "status" => "disabled",
                 "routing_strategy" => "bridge_ring",
                 "upstream_assignment_ids" => [assignment.id],
                 "api_key_ids" => []
               })

      assert updated_pool.status == "disabled"
      assert [] = all_enqueued(worker: CatalogSyncWorker)
    end

    test "drained assignment edit sync refreshes model source metadata for new upstream" do
      %{user: owner} =
        bootstrap_owner_fixture(%{"email" => "catalog-freshness-owner@example.com"})

      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{slug: "catalog-freshness-sync", name: "Catalog Freshness Sync"})

      first_upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-immediate-sync"}]}))

      second_upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-immediate-sync"}]}))

      first =
        active_upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct_immediate_first",
          metadata: %{"base_url" => FakeUpstream.url(first_upstream)}
        })

      assert {:ok, %{models: [initial_model]}} = Catalog.sync_pool_catalog(pool)
      assert initial_model.metadata["source_assignment_ids"] == [first.assignment.id]

      second_identity =
        active_upstream_identity_fixture(%{
          chatgpt_account_id: "acct_immediate_second",
          metadata: %{"base_url" => FakeUpstream.url(second_upstream)}
        })

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(second_identity, %{
                 secret_kind: "access_token",
                 plaintext: "catalog-test-token-second"
               })

      assert {:ok, _updated_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, pool, %{
                 "name" => "Catalog Freshness Sync Updated",
                 "status" => "active",
                 "routing_strategy" => "bridge_ring",
                 "upstream_identity_ids" => [first.identity.id, second_identity.id],
                 "api_key_ids" => []
               })

      assignments_by_identity =
        pool
        |> Upstreams.list_pool_assignments()
        |> Map.new(&{&1.upstream_identity_id, &1})

      second_assignment = Map.fetch!(assignments_by_identity, second_identity.id)
      assert second_assignment.status == "active"
      assert [job] = all_enqueued(worker: CatalogSyncWorker)
      assert job.args == %{"pool_id" => pool.id, "trigger_kind" => "manual"}
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :jobs)

      refreshed_model = Catalog.get_model_by_exposed_id(pool, "gpt-immediate-sync")
      expected_assignment_ids = Enum.sort([first.assignment.id, second_assignment.id])

      assert refreshed_model.source_assignment_count == 2
      assert refreshed_model.metadata["source_assignment_ids"] == expected_assignment_ids
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

    test "creation defaults image generation permission on" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, pool} =
               PoolWorkflow.create_pool_with_related_settings(scope, %{
                 "name" => "Image Generation Workflow Create",
                 "routing_strategy" => "bridge_ring"
               })

      assert Pools.get_routing_settings(pool).allow_image_generation == true
      assert Pools.allow_image_generation?(pool)
    end

    test "update toggles image generation permission both ways" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{slug: "image-workflow-edit", name: "Image Workflow Edit"})

      assert {:ok, disabled_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, pool, %{
                 "name" => "Image Workflow Disabled",
                 "status" => "active",
                 "routing_strategy" => "bridge_ring",
                 "allow_image_generation" => "false",
                 "upstream_identity_ids" => [],
                 "api_key_ids" => []
               })

      assert Pools.get_routing_settings(disabled_pool).allow_image_generation == false
      refute Pools.allow_image_generation?(disabled_pool)

      assert {:ok, enabled_pool} =
               PoolWorkflow.update_pool_with_related_settings(scope, disabled_pool, %{
                 "name" => "Image Workflow Enabled",
                 "status" => "active",
                 "routing_strategy" => "bridge_ring",
                 "allow_image_generation" => "true",
                 "upstream_identity_ids" => [],
                 "api_key_ids" => []
               })

      assert Pools.get_routing_settings(enabled_pool).allow_image_generation == true
      assert Pools.allow_image_generation?(enabled_pool)
    end
  end

  defp publish_from_task(fun) when is_function(fun, 0) do
    fun
    |> Task.async()
    |> Task.await(5_000)
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end
end
