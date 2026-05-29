defmodule CodexPooler.Jobs.ReconciliationJobsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AccountReconciliationEnqueueWorker
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  import CodexPooler.PoolerFixtures
  import CodexPooler.AccountsFixtures

  setup do
    Repo.delete_all(Oban.Job)
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    previous_dev_features_enabled = Application.get_env(:codex_pooler, :dev_features_enabled)

    on_exit(fn ->
      restore_env(:dev_features_enabled, previous_dev_features_enabled)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  describe "reconciliation jobs" do
    test "completes partial reconciliation when only catalog sync fails" do
      future_reset = DateTime.add(DateTime.utc_now(), 300, :second)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/codex/models" => {503, %{"error" => %{"code" => "temporarily_unavailable"}}}
           }}
        )

      {pool, assignment} =
        active_assignment_fixture(%{
          "base_url" => FakeUpstream.url(upstream),
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 300,
              "active_limit" => 100,
              "credits" => 75,
              "reset_at" => DateTime.to_iso8601(future_reset),
              "source" => "local_reconciliation",
              "freshness_state" => "fresh"
            }
          ]
        })

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)
      assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :jobs)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.errors == []

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert assignment.metadata["last_reconciliation"]["status"] == "partial"

      assert [%{"code" => "catalog_sync_failed"}] =
               Enum.filter(
                 assignment.metadata["last_reconciliation"]["steps"],
                 &(&1["status"] == "failed")
               )
    end

    test "records partial state and discards failed reconciliation without retry" do
      upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-reconcile"}]}))

      {pool, assignment} =
        active_assignment_fixture(%{
          "base_url" => FakeUpstream.url(upstream),
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 0,
              "source" => "local_reconciliation",
              "freshness_state" => "fresh"
            }
          ]
        })

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)
      assert %{discard: 1, success: 0} = Oban.drain_queue(queue: :jobs)

      discarded_job = Repo.get!(Oban.Job, job.id)
      assert discarded_job.state == "discarded"
      assert discarded_job.max_attempts == 1
      assert [%{"error" => error}] = discarded_job.errors
      assert error =~ "account reconciliation partial"

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert assignment.health_status == "active"
      assert %DateTime{} = assignment.last_healthcheck_at
      assert assignment.metadata["last_reconciliation"]["status"] == "partial"

      assert [] = QuotaWindows.list_quota_windows(assignment.upstream_identity_id)

      assert [model] = Catalog.list_models(pool)
      assert model.exposed_model_id == "gpt-reconcile"
    end

    test "does not sync catalog when upstream reconciliation fails" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-unexpected-reconcile"}]})
        )

      {pool, _assignment} =
        active_assignment_fixture(%{
          "base_url" => FakeUpstream.url(upstream),
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 300,
              "source" => "local_reconciliation",
              "freshness_state" => "fresh"
            }
          ]
        })

      assert {:error, %{code: :pool_account_not_reconcilable}} =
               AccountReconciliation.run(pool.id, Ecto.UUID.generate(), "failure_test")

      assert [] = Repo.all(SyncRun)
      assert [] = Catalog.list_models(pool)
    end

    test "completes partial reconciliation when catalog sync is already running" do
      future_reset = DateTime.add(DateTime.utc_now(), 300, :second)

      {pool, assignment} =
        active_assignment_fixture(%{
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 300,
              "active_limit" => 100,
              "credits" => 75,
              "reset_at" => DateTime.to_iso8601(future_reset),
              "source" => "local_reconciliation",
              "freshness_state" => "fresh"
            }
          ]
        })

      insert_running_catalog_sync(pool)

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :jobs)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.max_attempts == 1
      assert completed_job.errors == []

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert assignment.metadata["last_reconciliation"]["status"] == "partial"

      assert [%{"code" => "catalog_sync_in_progress"}] =
               Enum.filter(
                 assignment.metadata["last_reconciliation"]["steps"],
                 &(&1["status"] == "failed")
               )
    end

    test "refreshes quota windows when local-safe reconciliation data is valid" do
      future_reset = DateTime.add(DateTime.utc_now(), 300, :second)

      {pool, assignment} =
        active_assignment_fixture(%{
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 300,
              "active_limit" => 100,
              "credits" => 75,
              "reset_at" => DateTime.to_iso8601(future_reset),
              "source" => "local_reconciliation",
              "freshness_state" => "fresh"
            }
          ]
        })

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded
      assert [window] = Repo.all(Quota.AccountQuotaWindow)
      assert window.window_kind == "primary"
      assert window.credits == 75
    end

    test "enqueues account reconciliation jobs for active pools" do
      {pool, assignment} = active_assignment_fixture(%{})

      assert {:ok, %{inserted: [job], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert job.args["pool_id"] == pool.id
      assert job.args["pool_upstream_assignment_id"] == assignment.id
      assert job.args["trigger_kind"] == "scheduled"

      assert [row] = Jobs.list_recent_account_reconciliation_jobs(pool)
      assert row.id == job.id
      assert row.args["pool_upstream_assignment_id"] == assignment.id
    end

    test "active-pool account reconciliation enqueue returns no work when development pause is enabled" do
      {_pool, _assignment} = active_assignment_fixture(%{})
      pause_development_account_reconciliation!()

      assert {:ok, %{inserted: [], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert [] = all_enqueued(worker: AccountReconciliationWorker)
    end

    test "scheduled enqueue worker runs normally and enqueues nothing when development pause is enabled" do
      {_pool, _assignment} = active_assignment_fixture(%{})
      pause_development_account_reconciliation!()

      assert :ok = perform_job(AccountReconciliationEnqueueWorker, %{})

      assert [] = all_enqueued(worker: AccountReconciliationWorker)
    end

    test "account reconciliation worker no-ops when development reconciliation pause is enabled" do
      upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-dev-paused"}]}))

      {_pool, assignment} =
        active_assignment_fixture(%{
          "base_url" => FakeUpstream.url(upstream),
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 0,
              "source" => "local_reconciliation",
              "freshness_state" => "fresh"
            }
          ]
        })

      pause_development_account_reconciliation!()

      assert :ok =
               perform_job(AccountReconciliationWorker, %{
                 "pool_id" => assignment.pool_id,
                 "pool_upstream_assignment_id" => assignment.id,
                 "trigger_kind" => "scheduled"
               })

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert is_nil(assignment.metadata["last_reconciliation"])
      assert [] = Repo.all(SyncRun)
    end

    test "does not enqueue account reconciliation jobs for paused upstream accounts" do
      {pool, assignment} = active_assignment_fixture(%{})

      assert {:ok, %{status: :paused}} =
               Upstreams.pause_account_for_scope(
                 fixture_scope(),
                 assignment.upstream_identity_id,
                 %{
                   reason: "operator_pause"
                 }
               )

      assert {:ok, %{inserted: [], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert [] = all_enqueued(worker: AccountReconciliationWorker)

      assert [] = Jobs.list_recent_account_reconciliation_jobs(pool)
    end

    test "skips already queued account reconciliation jobs when upstream account is paused" do
      {pool, assignment} = active_assignment_fixture(%{})

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)

      assert {:ok, %{status: :paused}} =
               Upstreams.pause_account_for_scope(
                 fixture_scope(),
                 assignment.upstream_identity_id,
                 %{
                   reason: "operator_pause"
                 }
               )

      assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :jobs)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.errors == []

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert is_nil(assignment.metadata["quota_priming"])
      assert is_nil(assignment.metadata["last_reconciliation"])
    end

    test "gateway-triggered reconciliation deduplicates recently completed jobs" do
      {pool, assignment} = active_assignment_fixture(%{})
      assert :ok = Events.subscribe_pool(pool.id)

      unique = [
        fields: [:args, :queue, :worker],
        keys: [:pool_id, :pool_upstream_assignment_id, :trigger_kind],
        states: :successful,
        period: 60
      ]

      assert {:ok, first_job} =
               publish_from_task(fn ->
                 Jobs.enqueue_account_reconciliation(pool, assignment,
                   trigger_kind: "gateway",
                   unique: unique
                 )
               end)

      assert first_job.args == %{
               "pool_id" => pool.id,
               "pool_upstream_assignment_id" => assignment.id,
               "trigger_kind" => "gateway"
             }

      first_job_id = Integer.to_string(first_job.id)

      assert_receive {Events,
                      %{
                        reason: "job_status_updated",
                        payload: %{
                          "id" => ^first_job_id,
                          "status" => "scheduled",
                          "worker" => "account_reconciliation"
                        }
                      }}

      {1, _rows} =
        from(job in Oban.Job, where: job.id == ^first_job.id)
        |> Repo.update_all(
          set: [
            state: "completed",
            attempt: 1,
            attempted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
            completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          ]
        )

      assert {:ok, second_job} =
               publish_from_task(fn ->
                 Jobs.enqueue_account_reconciliation(pool, assignment,
                   trigger_kind: "gateway",
                   unique: unique
                 )
               end)

      refute first_job.conflict?
      assert second_job.conflict?
      assert second_job.id == first_job.id
      refute_received {Events, %{reason: "job_status_updated"}}

      assert [job] =
               Repo.all(
                 from(job in Oban.Job,
                   where: job.worker == ^worker_name(AccountReconciliationWorker)
                 )
               )

      assert job.id == first_job.id
    end
  end

  defp publish_from_task(fun) when is_function(fun, 0) do
    fun
    |> Task.async()
    |> Task.await(5_000)
  end

  defp insert_running_catalog_sync(pool, attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SyncRun{}
    |> SyncRun.changeset(%{
      pool_id: pool.id,
      trigger_kind: "reconcile",
      status: "running",
      started_at: Keyword.get(attrs, :started_at, now),
      discovered_model_count: 0,
      upserted_model_count: 0,
      stale_marked_count: 0,
      retired_count: 0,
      stats: %{}
    })
    |> Repo.insert!()
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp active_assignment_fixture(metadata) do
    pool = pool_fixture()

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Job account",
               onboarding_method: "import",
               metadata: %{}
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    configure_upstream_secret_key!()

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "token"
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Job assignment",
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment, %{
               skip_quota_priming: true
             })

    {pool, assignment}
  end

  defp fixture_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp pause_development_account_reconciliation! do
    Application.put_env(:codex_pooler, :dev_features_enabled, true)

    assert {:ok, settings} =
             InstanceSettings.update(InstanceSettings.ensure_singleton!(), %{
               "development" => %{
                 "impeccable_live_enabled" => false,
                 "account_reconciliation_paused" => true
               }
             })

    assert settings.development.account_reconciliation_paused == true
    settings
  end

  defp restore_env(key, nil), do: Application.delete_env(:codex_pooler, key)
  defp restore_env(key, value), do: Application.put_env(:codex_pooler, key, value)
end
