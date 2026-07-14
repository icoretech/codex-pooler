defmodule CodexPooler.Jobs.ReconciliationJobsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Runtime.Finalization.SideEffects
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AccountReconciliationEnqueueWorker
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.TokenLinking
  alias Ecto.Adapters.SQL.Sandbox

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

    test "scheduled reconciliation skips direct catalog sync" do
      future_reset = DateTime.add(DateTime.utc_now(), 300, :second)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/codex/models" => {200, %{"models" => [%{"id" => "gpt-scheduled-skip"}]}}
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

      assert {:ok, result} = AccountReconciliation.run(pool.id, assignment.id, "scheduled")

      assert result.status == :succeeded
      assert result.catalog.status == :succeeded
      assert result.catalog.code == "catalog_sync_skipped"

      assert [] = Repo.all(SyncRun)
      assert [] = Catalog.list_models(pool)
      assert [] = FakeUpstream.requests(upstream)
    end

    test "records one canonical terminal reconciliation summary after catalog handling" do
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

      {result, assignment_updates} =
        capture_assignment_updates(fn ->
          AccountReconciliation.run(pool.id, assignment.id, "scheduled")
        end)

      assert {:ok, %{status: :succeeded} = result} = result
      assert result.health.code == "health_refreshed"
      assert result.quota.code == "quota_refreshed"
      assert result.catalog.code == "catalog_sync_skipped"

      assert [terminal_summary_update] =
               Enum.filter(assignment_updates, fn update ->
                 inspect(update.params) =~ "last_reconciliation"
               end)

      assert inspect(terminal_summary_update.params) =~ "catalog_sync_skipped"

      reloaded_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert reloaded_assignment.health_status == "active"
      assert reloaded_assignment.eligibility_status == "eligible"
      assert %DateTime{} = reloaded_assignment.last_healthcheck_at
      assert reloaded_assignment.metadata["quota_priming"]["status"] == "known"

      assert %{
               "status" => "succeeded",
               "finished_at" => finished_at,
               "steps" => steps
             } = reloaded_assignment.metadata["last_reconciliation"]

      assert {:ok, _finished_at, _offset} = DateTime.from_iso8601(finished_at)

      assert Enum.map(steps, & &1["code"]) == [
               "health_refreshed",
               "quota_refreshed",
               "catalog_sync_skipped"
             ]
    end

    test "gateway-triggered reconciliation skips direct catalog sync" do
      future_reset = DateTime.add(DateTime.utc_now(), 300, :second)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/codex/models" => {200, %{"models" => [%{"id" => "gpt-gateway-skip"}]}}
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

      assert {:ok, result} = AccountReconciliation.run(pool.id, assignment.id, "gateway")

      assert result.status == :succeeded
      assert result.catalog.status == :succeeded
      assert result.catalog.code == "catalog_sync_skipped"

      assert [] = Repo.all(SyncRun)
      assert [] = Catalog.list_models(pool)
      assert [] = FakeUpstream.requests(upstream)
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

    test "does not report stale persisted quota as refreshed when live usage is unavailable" do
      stale_observed_at = DateTime.add(DateTime.utc_now(), -3_600, :second)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {404, %{"error" => "missing"}},
             "/backend-api/codex/usage" => {404, %{"error" => "missing"}},
             "/wham/usage" => {404, %{"error" => "missing"}},
             "/backend-api/wham/usage" => {404, %{"error" => "missing"}}
           }}
        )

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{
            "access_token_expires_at" =>
              DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
          }
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("47"),
                   reset_at: DateTime.add(stale_observed_at, -60, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: stale_observed_at
                 }
               ])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :partial
      assert result.quota.status == :failed
      assert result.quota.code == "quota_refresh_unavailable"

      [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == DateTime.truncate(stale_observed_at, :microsecond)
    end

    test "reuses fresh persisted quota when live usage is temporarily unavailable" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {404, %{"error" => "missing"}},
             "/backend-api/codex/usage" => {404, %{"error" => "missing"}},
             "/wham/usage" => {404, %{"error" => "missing"}},
             "/backend-api/wham/usage" => {404, %{"error" => "missing"}}
           }}
        )

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{
            "access_token_expires_at" =>
              DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
          }
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, [_primary_5h, _weekly_secondary]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("47"),
                   reset_at: DateTime.add(observed_at, 3_600, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 },
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("12"),
                   reset_at: DateTime.add(observed_at, 3_600, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded
      assert result.quota.status == :succeeded
      assert result.quota.code == "quota_reused_fresh"
      assert result.quota.details["window_count"] == 1

      windows = QuotaWindows.list_quota_windows(identity)
      assert length(windows) == 2
      assert Enum.all?(windows, &(&1.observed_at == observed_at))

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "reuses fresh persisted monthly account primary quota when live usage is unavailable" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {404, %{"error" => "missing"}},
             "/backend-api/codex/usage" => {404, %{"error" => "missing"}},
             "/wham/usage" => {404, %{"error" => "missing"}},
             "/backend-api/wham/usage" => {404, %{"error" => "missing"}}
           }}
        )

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, [_monthly_primary, _weekly_secondary]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 43_200,
                   used_percent: Decimal.new("47"),
                   reset_at: DateTime.add(observed_at, 86_400, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 },
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("12"),
                   reset_at: DateTime.add(observed_at, 3_600, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded
      assert result.quota.status == :succeeded
      assert result.quota.code == "quota_reused_fresh"
      assert result.quota.details["window_count"] == 1

      windows = QuotaWindows.list_quota_windows(identity)
      assert length(windows) == 2
      assert Enum.all?(windows, &(&1.observed_at == observed_at))
    end

    test "scheduled worker completes by reusing fresh persisted 5h and monthly quota when live usage is unavailable" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      for window_attrs <- [
            persisted_account_primary_window_attrs(observed_at, %{window_minutes: 300}),
            persisted_account_primary_window_attrs(observed_at, %{
              window_minutes: 43_200,
              reset_at: DateTime.add(observed_at, 86_400, :second)
            })
          ] do
        upstream = start_upstream(unavailable_usage_paths())

        {pool, assignment} =
          active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

        persist_quota_windows!(identity, [window_attrs])

        assert {:ok, job} =
                 Jobs.enqueue_account_reconciliation(pool, assignment, trigger_kind: "scheduled")

        assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :jobs)

        completed_job = Repo.get!(Oban.Job, job.id)
        assert completed_job.state == "completed"
        assert completed_job.errors == []

        assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
        assert assignment.metadata["quota_priming"]["status"] == "known"
        assert assignment.metadata["last_reconciliation"]["status"] == "succeeded"

        assert [
                 %{
                   "status" => "succeeded",
                   "code" => "quota_reused_fresh",
                   "details" => %{"window_count" => 1}
                 }
               ] =
                 Enum.filter(
                   assignment.metadata["last_reconciliation"]["steps"],
                   &(&1["code"] == "quota_reused_fresh")
                 )

        assert [window] = QuotaWindows.list_quota_windows(identity)
        assert window.observed_at == observed_at

        assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
                 "/backend-api/wham/usage",
                 "/backend-api/codex/usage"
               ]
      end
    end

    test "does not reuse unknown-duration persisted account primary quota when live usage is unavailable" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {404, %{"error" => "missing"}},
             "/backend-api/codex/usage" => {404, %{"error" => "missing"}},
             "/wham/usage" => {404, %{"error" => "missing"}},
             "/backend-api/wham/usage" => {404, %{"error" => "missing"}}
           }}
        )

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 60,
                   used_percent: Decimal.new("47"),
                   reset_at: DateTime.add(observed_at, 3_600, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :partial
      assert result.quota.status == :failed
      assert result.quota.code == "quota_refresh_unavailable"

      [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == observed_at
    end

    test "does not reuse fresh persisted model-scoped quota when live usage is unavailable" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {404, %{"error" => "missing"}},
             "/backend-api/codex/usage" => {404, %{"error" => "missing"}},
             "/wham/usage" => {404, %{"error" => "missing"}},
             "/backend-api/wham/usage" => {404, %{"error" => "missing"}}
           }}
        )

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "sample-codex-spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "sample-codex-spark",
                   upstream_model: "sample-codex-spark-upstream",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("47"),
                   reset_at: DateTime.add(observed_at, 3_600, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :partial
      assert result.quota.status == :failed
      assert result.quota.code == "quota_refresh_unavailable"

      [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == observed_at
    end

    test "does not reuse fresh persisted quota when live usage returns 429" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {429, %{"error" => "rate_limited"}}
           }}
        )

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("47"),
                   reset_at: DateTime.add(observed_at, 3_600, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :partial
      assert result.quota.status == :failed
      assert result.quota.code == "quota_refresh_unavailable"

      [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == observed_at

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage"
             ]
    end

    test "scheduled worker does not reuse stale expired resetless exhausted or weekly-only persisted quota" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      scenarios = [
        {"stale",
         persisted_account_primary_window_attrs(DateTime.add(now, -3_600, :second), %{
           reset_at: DateTime.add(now, 3_600, :second)
         })},
        {"expired",
         persisted_account_primary_window_attrs(now, %{
           reset_at: DateTime.add(now, -60, :second)
         })},
        {"resetless", persisted_account_primary_window_attrs(now, %{reset_at: nil})},
        {"exhausted",
         persisted_account_primary_window_attrs(now, %{used_percent: Decimal.new("100")})},
        {"weekly_only",
         persisted_account_primary_window_attrs(now, %{
           window_kind: "secondary",
           window_minutes: 10_080,
           quota_family: "account"
         })}
      ]

      for {_name, window_attrs} <- scenarios do
        upstream = start_upstream(unavailable_usage_paths())

        {pool, assignment} =
          active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
        persist_quota_windows!(identity, [window_attrs])

        assert_scheduled_worker_quota_failure(pool, assignment, "quota_refresh_unavailable")

        [window] = QuotaWindows.list_quota_windows(identity)
        assert window.observed_at == window_attrs.observed_at
      end
    end

    test "scheduled worker does not reuse unknown-duration primary or model-scoped persisted quota" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      scenarios = [
        {"unknown_duration",
         persisted_account_primary_window_attrs(observed_at, %{window_minutes: 60})},
        {"model_scoped",
         persisted_account_primary_window_attrs(observed_at, %{
           quota_key: "sample-codex-spark",
           quota_scope: "model",
           quota_family: "codex_model",
           model: "sample-codex-spark",
           upstream_model: "sample-codex-spark-upstream"
         })}
      ]

      for {_name, window_attrs} <- scenarios do
        upstream = start_upstream(unavailable_usage_paths())

        {pool, assignment} =
          active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
        persist_quota_windows!(identity, [window_attrs])

        assert_scheduled_worker_quota_failure(pool, assignment, "quota_refresh_unavailable")

        [window] = QuotaWindows.list_quota_windows(identity)
        assert window.observed_at == observed_at
      end
    end

    test "scheduled worker does not reuse fresh persisted quota after auth rejection 401 or 403" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      future_expiry = observed_at |> DateTime.add(10, :day) |> DateTime.to_iso8601()

      for status <- [401, 403] do
        upstream =
          start_upstream(
            {:path_json, %{"/backend-api/wham/usage" => {status, %{"error" => "rejected"}}}}
          )

        {pool, assignment} =
          active_assignment_fixture(
            %{"base_url" => FakeUpstream.url(upstream)},
            identity_metadata: %{
              "base_url" => FakeUpstream.url(upstream),
              "access_token_expires_at" => future_expiry
            }
          )

        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
        persist_quota_windows!(identity, [persisted_account_primary_window_attrs(observed_at)])

        assert_scheduled_worker_quota_failure(pool, assignment, "quota_refresh_unavailable")

        [window] = QuotaWindows.list_quota_windows(identity)
        assert window.observed_at == observed_at

        expected_paths = ["/backend-api/wham/usage", "/backend-api/codex/usage"]

        assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == expected_paths
      end
    end

    test "scheduled worker does not reuse fresh persisted quota after 429" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {429, %{"error" => "rate_limited"}}
           }}
        )

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      persist_quota_windows!(identity, [persisted_account_primary_window_attrs(observed_at)])

      assert_scheduled_worker_quota_failure(pool, assignment, "quota_refresh_unavailable")

      [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == observed_at

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage"
             ]
    end

    test "does not refresh OAuth or disable routing when usage rejects a fresh access token" do
      access_token = "token-access-fresh-usage-rejected-do-not-leak"
      refresh_token = "token-refresh-fresh-usage-rejected-do-not-leak"
      provider_body = "raw-provider-body-fresh-usage-rejected-do-not-leak"

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {401, %{"error" => "usage_probe_rejected"}},
             "/oauth/token" => {503, %{"error" => provider_body}}
           }}
        )

      future_expiry =
        DateTime.utc_now()
        |> DateTime.add(10, :day)
        |> DateTime.truncate(:microsecond)
        |> DateTime.to_iso8601()

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          access_token: access_token,
          identity_metadata: %{
            "base_url" => FakeUpstream.url(upstream),
            "access_token_expires_at" => future_expiry
          }
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("47"),
                   reset_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh"
                 }
               ])

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "refresh_token",
                 plaintext: refresh_token
               })

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)

      assert result.status == :partial
      assert result.quota.status == :failed
      assert result.quota.code == "quota_refresh_unavailable"

      persisted_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted_identity.status == "active"
      refute persisted_identity.metadata["token_refresh"]

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      last_reconciliation = assignment.metadata["last_reconciliation"]
      assert last_reconciliation["status"] == "partial"

      assert [%{"code" => "quota_refresh_unavailable"}] =
               Enum.filter(last_reconciliation["steps"], &(&1["status"] == "failed"))

      assert [] = incomplete_token_refresh_jobs(identity.id)

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]

      safe_surfaces = [
        inspect(persisted_identity.metadata),
        inspect(last_reconciliation)
      ]

      for surface <- safe_surfaces do
        refute surface =~ access_token
        refute surface =~ refresh_token
        refute surface =~ provider_body
      end
    end

    test "usage probe walks every configured path when no path yields usable quota" do
      upstream = start_upstream(unavailable_usage_paths())

      {pool, assignment} =
        active_assignment_fixture(
          %{
            "base_url" => FakeUpstream.url(upstream),
            "saved_resets" => %{"usage_path" => "/api/codex/usage"}
          },
          identity_metadata: %{
            "access_token_expires_at" =>
              DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
          }
        )

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.identity.status == "active"

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/api/codex/usage",
               "/backend-api/codex/usage",
               "/backend-api/wham/usage"
             ]
    end

    test "successful token refresh retries usage with the rotated access token" do
      refreshed_access_token = "rotated-access-token-do-not-leak"
      refresh_token = "refresh-token-do-not-leak"

      upstream =
        start_upstream(
          {:sequence,
           [
             FakeUpstream.json_response(%{"error" => "expired"}, 401),
             FakeUpstream.json_response(%{
               "access_token" => refreshed_access_token,
               "expires_in" => 3_600
             }),
             FakeUpstream.json_response(usage_payload())
           ]}
        )

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{"base_url" => FakeUpstream.url(upstream)}
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "refresh_token",
                 plaintext: refresh_token
               })

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded
      assert result.quota.code == "quota_refreshed"

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/oauth/token",
               "/backend-api/wham/usage"
             ]

      retried_usage_request = FakeUpstream.requests(upstream) |> List.last()

      assert {"authorization", "Bearer " <> ^refreshed_access_token} =
               List.keyfind(retried_usage_request.headers, "authorization", 0)
    end

    test "definitive provider usage auth rejection disables the identity assignment" do
      rejected_body = %{"error" => "synthetic-auth-rejected-do-not-leak"}
      upstream = start_upstream(unavailable_usage_paths(401, rejected_body))
      healthchecked_at = ~U[2026-07-11 12:00:00.000000Z]

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{
            "base_url" => FakeUpstream.url(upstream),
            "access_token_expires_at" =>
              DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
          }
        )

      assignment =
        assignment
        |> PoolUpstreamAssignment.changeset(%{
          health_status: "degraded",
          eligibility_status: "ineligible",
          last_healthcheck_at: healthchecked_at,
          metadata: Map.put(assignment.metadata, "preserved_marker", "preserve-me")
        })
        |> Repo.update!()

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :partial
      assert result.quota.code == "quota_refresh_auth_unavailable"
      assert result.identity.status == "reauth_required"

      persisted_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted_identity.status == "reauth_required"

      assert persisted_identity.metadata["token_refresh"]["reason"]["code"] ==
               "provider_usage_auth_rejected"

      persisted_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert persisted_assignment.status == assignment.status
      assert persisted_assignment.health_status == "disabled"
      assert persisted_assignment.eligibility_status == "ineligible"
      assert %DateTime{} = persisted_assignment.disabled_at
      assert persisted_assignment.last_healthcheck_at == healthchecked_at
      assert persisted_assignment.metadata["preserved_marker"] == "preserve-me"

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]

      refute inspect(persisted_identity.metadata) =~ rejected_body["error"]
      refute inspect(persisted_assignment.metadata) =~ rejected_body["error"]
    end

    test "terminal reauth reconciliation jobs are suppressed from unresolved failures" do
      upstream = start_upstream(unavailable_usage_paths(401, %{"error" => "rejected"}))

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{
            "access_token_expires_at" =>
              DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
          }
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      persist_quota_windows!(identity, [
        persisted_account_primary_window_attrs(DateTime.utc_now())
      ])

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)
      assert %{discard: 1, success: 0} = Oban.drain_queue(queue: :jobs)

      assert Repo.get!(Oban.Job, job.id).state == "discarded"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

      summary =
        Jobs.worker_job_summaries_by_group(fixture_scope(), [
          %{key: :account_reconciliation, workers: [AccountReconciliationWorker]}
        ])
        |> Map.fetch!(:account_reconciliation)

      refute Enum.any?(summary.unresolved_failures, &(&1.id == job.id))
    end

    for {case_name, first_status, second_status} <- [
          {"all 401", 401, 401},
          {"401 then 403", 401, 403},
          {"403 then 401", 403, 401},
          {"all 403", 403, 403}
        ] do
      test "decoded JSON object auth rejection across both default paths is definitive: #{case_name}" do
        statuses = [unquote(first_status), unquote(second_status)]

        upstream =
          start_upstream(
            usage_path_responses(
              ["/backend-api/wham/usage", "/backend-api/codex/usage"],
              statuses,
              %{"error" => "rejected"}
            )
          )

        {pool, assignment} = active_usage_probe_assignment(upstream)
        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

        assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
        assert result.identity.status == "reauth_required"
        assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

        assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
                 "/backend-api/wham/usage",
                 "/backend-api/codex/usage"
               ]
      end
    end

    test "decoded JSON object auth rejection walks all three metadata-driven paths" do
      paths = [
        "/api/codex/usage",
        "/backend-api/codex/usage",
        "/backend-api/wham/usage"
      ]

      upstream =
        start_upstream(usage_path_responses(paths, [401, 403, 401], %{"error" => "rejected"}))

      {pool, assignment} =
        active_usage_probe_assignment(upstream, %{
          "saved_resets" => %{"usage_path" => "/api/codex/usage"}
        })

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.identity.status == "reauth_required"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"
      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == paths
    end

    test "usage probe exposes the definitive provider auth rejection sentinel" do
      upstream = start_upstream(unavailable_usage_paths(401, %{"error" => "rejected"}))
      {_pool, assignment} = active_usage_probe_assignment(upstream)
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:error, :definitive_provider_auth_rejected} =
               UsageProbe.fetch(
                 identity,
                 assignment,
                 "synthetic-access-token",
                 DateTime.utc_now(),
                 []
               )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "decoded auth rejection plus weekly-only success remains non-definitive after all paths" do
      paths = [
        "/api/codex/usage",
        "/backend-api/codex/usage",
        "/backend-api/wham/usage"
      ]

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {401, %{"error" => "rejected"}},
             "/backend-api/codex/usage" => {200, weekly_usage_payload()},
             "/backend-api/wham/usage" => {404, %{}}
           }}
        )

      {pool, assignment} =
        active_usage_probe_assignment(upstream, %{
          "saved_resets" => %{"usage_path" => "/api/codex/usage"}
        })

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.identity.status == "active"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == paths
    end

    test "one invalid auth body prevents promotion despite decoded auth objects on other paths" do
      paths = [
        "/api/codex/usage",
        "/backend-api/codex/usage",
        "/backend-api/wham/usage"
      ]

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {401, %{"error" => "rejected"}},
             "/backend-api/codex/usage" =>
               FakeUpstream.raw_response("rejected",
                 status: 401,
                 headers: [{"content-type", "application/json"}]
               ),
             "/backend-api/wham/usage" => {403, %{"error" => "rejected"}}
           }}
        )

      {pool, assignment} =
        active_usage_probe_assignment(upstream, %{
          "saved_resets" => %{"usage_path" => "/api/codex/usage"}
        })

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.identity.status == "active"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == paths
    end

    for {case_name, response_mode} <- [
          {"HTML challenge",
           FakeUpstream.raw_response("<html>challenge</html>",
             status: 401,
             headers: [{"content-type", "text/html"}]
           )},
          {"HTML 403 challenge",
           FakeUpstream.raw_response("<html>challenge</html>",
             status: 403,
             headers: [{"content-type", "text/html"}]
           )},
          {"empty body",
           FakeUpstream.raw_response("",
             status: 401,
             headers: [{"content-type", "application/json"}]
           )},
          {"plain text",
           FakeUpstream.raw_response("rejected",
             status: 401,
             headers: [{"content-type", "application/json"}]
           )},
          {"JSON array", {401, [%{"error" => "rejected"}]}},
          {"malformed JSON",
           FakeUpstream.raw_response("{invalid",
             status: 401,
             headers: [{"content-type", "application/json"}]
           )}
        ] do
      test "provider auth promotion excludes #{case_name}" do
        mode = unquote(Macro.escape(response_mode))

        upstream =
          start_upstream(
            {:path_json,
             %{
               "/backend-api/wham/usage" => mode,
               "/backend-api/codex/usage" => mode
             }}
          )

        {pool, assignment} = active_usage_probe_assignment(upstream)
        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

        assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
        assert result.identity.status == "active"
        assert Repo.get!(UpstreamIdentity, identity.id).status == "active"

        assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
                 "/backend-api/wham/usage",
                 "/backend-api/codex/usage"
               ]
      end
    end

    test "provider auth promotion excludes success and 404 responses" do
      scenarios = [
        {"success", FakeUpstream.json_response(usage_payload())},
        {"not_found", unavailable_usage_paths()}
      ]

      for {case_name, mode} <- scenarios do
        upstream = start_upstream(mode)
        {pool, assignment} = active_usage_probe_assignment(upstream)
        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

        assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
        assert result.identity.status == "active", case_name
        assert Repo.get!(UpstreamIdentity, identity.id).status == "active", case_name
      end
    end

    test "provider auth promotion excludes timeout and transport errors" do
      timeout_ref = make_ref()

      timeout_upstream =
        start_upstream(
          FakeUpstream.timeout_before_headers(notify: self(), release_ref: timeout_ref)
        )

      {timeout_pool, timeout_assignment} = active_usage_probe_assignment(timeout_upstream)

      timeout_task =
        Task.async(fn ->
          Upstreams.reconcile_pool_account(timeout_pool, timeout_assignment, receive_timeout: 10)
        end)

      Sandbox.allow(Repo, self(), timeout_task.pid)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, handler_pid, ^timeout_ref}
      assert {:ok, timeout_result} = Task.await(timeout_task)
      send(handler_pid, {:fake_upstream_release_timeout, timeout_ref})

      assert timeout_result.identity.status == "active"

      {transport_pool, transport_assignment} =
        active_assignment_fixture(
          %{"base_url" => "http://127.0.0.1:1"},
          identity_metadata: fresh_access_token_metadata("http://127.0.0.1:1")
        )

      assert {:ok, transport_result} =
               Upstreams.reconcile_pool_account(transport_pool, transport_assignment,
                 receive_timeout: 100
               )

      assert transport_result.identity.status == "active"
    end

    test "successful refresh followed by all-path decoded JSON auth rejection requires reauth" do
      refreshed_access_token = "rotated-rejected-access-token-do-not-leak"
      refresh_token = "refresh-token-for-second-rejection-do-not-leak"

      upstream =
        start_upstream(
          {:sequence,
           [
             FakeUpstream.json_response(%{"error" => "expired"}, 401),
             FakeUpstream.json_response(%{
               "access_token" => refreshed_access_token,
               "expires_in" => 3_600
             }),
             FakeUpstream.json_response(%{"error" => "rejected"}, 401),
             FakeUpstream.json_response(%{"error" => "rejected"}, 403)
           ]}
        )

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{"base_url" => FakeUpstream.url(upstream)}
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "refresh_token",
                 plaintext: refresh_token
               })

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.identity.status == "reauth_required"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/oauth/token",
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "provider usage failures short of definitive auth rejection preserve active state" do
      cases = [
        {"single_401",
         %{
           "/backend-api/wham/usage" => {401, %{"error" => "rejected"}},
           "/backend-api/codex/usage" => {404, %{}}
         }},
        {"html_challenge",
         %{
           "/backend-api/wham/usage" => {401, "<html>challenge</html>"},
           "/backend-api/codex/usage" => {401, "<html>challenge</html>"}
         }},
        {"malformed",
         %{
           "/backend-api/wham/usage" => {200, %{}},
           "/backend-api/codex/usage" => {200, %{}}
         }},
        {"quota_missing",
         %{
           "/backend-api/wham/usage" => {404, %{}},
           "/backend-api/codex/usage" => {404, %{}}
         }}
      ]

      for {case_name, paths} <- cases do
        upstream = start_upstream({:path_json, paths})

        {pool, assignment} =
          active_assignment_fixture(
            %{"base_url" => FakeUpstream.url(upstream)},
            identity_metadata: %{
              "access_token_expires_at" =>
                DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
            }
          )

        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

        assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
        assert result.identity.status == "active", case_name
        assert Repo.get!(UpstreamIdentity, identity.id).status == "active", case_name
        assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "active", case_name
      end
    end

    test "fresh route-usable historical evidence does not mask current auth rejection" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      upstream = start_upstream(unavailable_usage_paths(401, %{"error" => "rejected"}))

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{
            "access_token_expires_at" =>
              DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
          }
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      persist_quota_windows!(identity, [persisted_account_primary_window_attrs(observed_at)])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.identity.status == "reauth_required"
      assert result.quota.code == "quota_refresh_auth_unavailable"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"
    end

    test "blocked rejection from an earlier credential epoch cannot demote a relinked identity" do
      release_ref = make_ref()

      upstream =
        start_upstream(rejection_barrier_paths(self(), release_ref))

      {pool, assignment} = active_usage_probe_assignment(upstream)
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      scope = fixture_scope()

      rejection_task =
        start_allowed_task(fn ->
          PoolReconciliation.refresh_quota_from_usage(identity, assignment)
        end)

      first_barrier = await_upstream_barrier(release_ref)

      assert {:ok, %{identity: relinked_identity, assignment: relinked_assignment}} =
               TokenLinking.link_tokens(
                 scope,
                 pool,
                 %{
                   chatgpt_account_id: identity.chatgpt_account_id,
                   account_label: identity.account_label,
                   token: "replacement-access-token"
                 },
                 target_identity_id: identity.id
               )

      assert relinked_identity.metadata["credential_epoch"] == 2
      assert relinked_identity.metadata["usage_probe_sequence"] == 1
      assert relinked_identity.metadata["usage_probe_applied_sequence"] == 0
      assert relinked_assignment.health_status == "active"

      release_upstream_barrier(first_barrier, release_ref)
      second_barrier = await_upstream_barrier(release_ref)
      release_upstream_barrier(second_barrier, release_ref)

      assert {:error, :quota_refresh_superseded} = Task.await(rejection_task)

      current_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert current_identity.status == "active"
      assert current_identity.metadata["credential_epoch"] == 2

      current_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert current_assignment.health_status == "active"
      assert current_assignment.eligibility_status == "eligible"
      assert current_assignment.disabled_at == nil
    end

    test "higher rejection sequence wins when the lower success completes first" do
      lower_release_ref = make_ref()
      higher_release_ref = make_ref()

      lower_upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(usage_payload(),
            notify: self(),
            release_ref: lower_release_ref
          )
        )

      higher_upstream =
        start_upstream(rejection_barrier_paths(self(), higher_release_ref))

      {_pool, assignment} = active_usage_probe_assignment(lower_upstream)
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      rejection_assignment = assignment_with_upstream(assignment, higher_upstream)

      lower_task =
        start_allowed_task(fn ->
          PoolReconciliation.refresh_quota_from_usage(identity, assignment)
        end)

      lower_barrier = await_upstream_barrier(lower_release_ref)

      higher_task =
        start_allowed_task(fn ->
          PoolReconciliation.refresh_quota_from_usage(identity, rejection_assignment)
        end)

      higher_first_barrier = await_upstream_barrier(higher_release_ref)
      release_upstream_barrier(lower_barrier, lower_release_ref)
      assert {:ok, %UpstreamIdentity{status: "active"}} = Task.await(lower_task)

      release_upstream_barrier(higher_first_barrier, higher_release_ref)
      higher_second_barrier = await_upstream_barrier(higher_release_ref)
      release_upstream_barrier(higher_second_barrier, higher_release_ref)

      assert {:error, :definitive_provider_auth_rejected} = Task.await(higher_task)

      current_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert current_identity.status == "reauth_required"
      assert current_identity.metadata["usage_probe_applied_sequence"] == 2
      assert [_historical_window] = QuotaWindows.list_quota_windows(current_identity)
    end

    test "higher rejection sequence wins when it completes before the lower success" do
      lower_release_ref = make_ref()
      higher_release_ref = make_ref()

      lower_upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(usage_payload(),
            notify: self(),
            release_ref: lower_release_ref
          )
        )

      higher_upstream =
        start_upstream(rejection_barrier_paths(self(), higher_release_ref))

      {_pool, assignment} = active_usage_probe_assignment(lower_upstream)
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      rejection_assignment = assignment_with_upstream(assignment, higher_upstream)

      lower_task =
        start_allowed_task(fn ->
          PoolReconciliation.refresh_quota_from_usage(identity, assignment)
        end)

      lower_barrier = await_upstream_barrier(lower_release_ref)

      higher_task =
        start_allowed_task(fn ->
          PoolReconciliation.refresh_quota_from_usage(identity, rejection_assignment)
        end)

      higher_first_barrier = await_upstream_barrier(higher_release_ref)
      release_upstream_barrier(higher_first_barrier, higher_release_ref)
      higher_second_barrier = await_upstream_barrier(higher_release_ref)
      release_upstream_barrier(higher_second_barrier, higher_release_ref)

      assert {:error, :definitive_provider_auth_rejected} = Task.await(higher_task)

      rejected_identity = Repo.get!(UpstreamIdentity, identity.id)
      rejected_metadata = rejected_identity.metadata
      rejected_windows = QuotaWindows.list_quota_windows(rejected_identity)
      assert rejected_identity.status == "reauth_required"
      assert rejected_metadata["usage_probe_applied_sequence"] == 2
      assert rejected_windows == []

      release_upstream_barrier(lower_barrier, lower_release_ref)
      assert {:error, :quota_refresh_superseded} = Task.await(lower_task)

      current_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert current_identity.metadata == rejected_metadata
      assert QuotaWindows.list_quota_windows(current_identity) == rejected_windows
    end

    test "current rejection atomically disables live assignments across pools and leaves deleted assignment untouched" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      upstream = start_upstream(unavailable_usage_paths(401, %{"error" => "rejected"}))

      {source_pool, source_assignment} = active_usage_probe_assignment(upstream)
      identity = Upstreams.get_upstream_identity(source_assignment.upstream_identity_id)
      persist_quota_windows!(identity, [persisted_account_primary_window_attrs(observed_at)])

      second_pool = pool_fixture()
      deleted_pool = pool_fixture()

      assert {:ok, second_assignment} =
               PoolAssignments.create_pool_assignment(second_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible"
               })

      assert {:ok, deleted_assignment} =
               PoolAssignments.create_pool_assignment(deleted_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible"
               })

      assert {:ok, %{assignment: deleted_assignment}} =
               PoolAssignments.delete_pool_assignment(deleted_pool, deleted_assignment)

      deleted_before = Repo.get!(PoolUpstreamAssignment, deleted_assignment.id)

      assert {:ok, result} = Upstreams.reconcile_pool_account(source_pool, source_assignment)
      assert result.identity.status == "reauth_required"

      first = Repo.get!(PoolUpstreamAssignment, source_assignment.id)
      second = Repo.get!(PoolUpstreamAssignment, second_assignment.id)
      deleted = Repo.get!(PoolUpstreamAssignment, deleted_assignment.id)

      assert first.status == source_assignment.status
      assert second.status == second_assignment.status
      assert first.health_status == "disabled"
      assert second.health_status == "disabled"
      assert first.eligibility_status == "ineligible"
      assert second.eligibility_status == "ineligible"
      assert first.disabled_at == second.disabled_at
      assert deleted == deleted_before
      assert [_historical_window] = QuotaWindows.list_quota_windows(identity)
    end

    test "fenced usage success publishes once only after its transaction commits" do
      {pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")
      assert {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity)

      test_pid = self()

      task =
        start_allowed_task(fn ->
          CredentialFencing.apply_usage_success(identity, fence, fn _locked_identity ->
            send(test_pid, {:fenced_usage_persisted, self()})

            receive do
              :commit_fenced_usage -> {:ok, :persisted}
            end
          end)
        end)

      assert_receive {:fenced_usage_persisted, task_pid}
      refute_received {Events, %{reason: "upstream_quota_windows_updated"}}
      send(task_pid, :commit_fenced_usage)

      assert {:ok, :applied, _identity, :persisted} = Task.await(task)

      assert_receive {Events,
                      %{
                        reason: "upstream_quota_windows_updated",
                        payload: %{
                          "assignment_id" => assignment_id,
                          "upstream_identity_id" => identity_id
                        }
                      }}

      assert assignment_id == assignment.id
      assert identity_id == identity.id
      refute_received {Events, %{reason: "upstream_quota_windows_updated"}}
    end

    test "rolled back fenced usage success publishes no upstream event" do
      {pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")
      assert {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity)

      assert {:error, :synthetic_rollback} =
               CredentialFencing.apply_usage_success(identity, fence, fn locked_identity ->
                 locked_identity
                 |> UpstreamIdentity.changeset(%{status: "paused"})
                 |> Repo.update!()

                 {:error, :synthetic_rollback}
               end)

      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
      refute_received {Events, %{reason: "upstream_quota_windows_updated"}}
    end

    test "fenced definitive rejection publishes exactly once after persistence" do
      upstream = start_upstream(unavailable_usage_paths(401, %{"error" => "rejected"}))
      {pool, assignment} = active_usage_probe_assignment(upstream)
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      assert {:error, :definitive_provider_auth_rejected} =
               start_allowed_task(fn ->
                 PoolReconciliation.refresh_quota_from_usage(identity, assignment)
               end)
               |> Task.await()

      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

      assert_receive {Events,
                      %{
                        reason: "upstream_account_reauth_required",
                        payload: %{
                          "assignment_id" => assignment_id,
                          "upstream_identity_id" => identity_id,
                          "upstream_status" => "reauth_required"
                        }
                      }}

      assert assignment_id == assignment.id
      assert identity_id == identity.id
      refute_received {Events, %{reason: "upstream_account_reauth_required"}}
    end

    test "newer success supersedes an older same-epoch rejection" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, _identity, rejection_fence} =
               CredentialFencing.allocate_usage_probe(identity)

      assert {:ok, _identity, success_fence} = CredentialFencing.allocate_usage_probe(identity)

      assert {:ok, :applied, current_identity, :persisted} =
               CredentialFencing.apply_usage_success(
                 identity,
                 success_fence,
                 fn locked_identity ->
                   assert locked_identity.id == identity.id
                   {:ok, :persisted}
                 end
               )

      assert current_identity.status == "active"

      assert {:ok, :superseded, still_current_identity} =
               CredentialFencing.mark_definitive_rejection(identity, rejection_fence)

      assert still_current_identity.status == "active"

      assert Repo.get!(PoolUpstreamAssignment, assignment.id).health_status ==
               assignment.health_status
    end

    test "fresh fenced provider quota recovers every relinked assignment and retains history" do
      success_upstream = start_upstream(FakeUpstream.json_response(usage_payload()))
      recovery = rejected_and_relinked_identity_fixture()

      assert recovery.linked_identity.status == "active"
      assert recovery.linked_identity.metadata["credential_epoch"] == recovery.initial_epoch + 1
      assert recovery.linked_identity.metadata["audit_marker"] == %{"safe" => "retained"}
      assert recovery.linked_assignment.health_status == "active"
      assert recovery.linked_assignment.eligibility_status == "ineligible"

      sibling_before = Repo.get!(PoolUpstreamAssignment, recovery.sibling_assignment.id)
      assert sibling_before.health_status == "disabled"
      assert sibling_before.eligibility_status == "ineligible"

      assert {:ok, unfenced_result} =
               Upstreams.reconcile_pool_account(recovery.source_pool, recovery.linked_assignment,
                 quota_windows: [persisted_account_primary_window_attrs(DateTime.utc_now())]
               )

      assert unfenced_result.quota.code == "quota_refreshed"

      unfenced_source = Repo.get!(PoolUpstreamAssignment, recovery.linked_assignment.id)
      unfenced_sibling = Repo.get!(PoolUpstreamAssignment, recovery.sibling_assignment.id)
      assert unfenced_source.eligibility_status == "ineligible"
      assert unfenced_sibling.health_status == "disabled"
      assert unfenced_sibling.eligibility_status == "ineligible"

      source_assignment =
        update_assignment_upstream!(recovery.linked_assignment, success_upstream)

      assert :ok = Events.subscribe_pool(recovery.source_pool.id, "upstreams")
      assert :ok = Events.subscribe_pool(recovery.sibling_pool.id, "upstreams")

      assert {:ok, recovered_identity} =
               start_allowed_task(fn ->
                 PoolReconciliation.refresh_quota_from_usage(
                   recovery.linked_identity,
                   source_assignment
                 )
               end)
               |> Task.await()

      assert recovered_identity.status == "active"
      assert recovered_identity.disabled_at == nil
      assert recovered_identity.metadata["usage_probe_sequence"] == 2
      assert recovered_identity.metadata["usage_probe_applied_sequence"] == 2
      assert recovered_identity.metadata["audit_marker"] == %{"safe" => "retained"}

      assert recovered_identity.metadata["provider_auth_recovery"]["status"] == "recovered"

      assert recovered_identity.metadata["provider_auth_recovery"]["last_terminal"]["reason"][
               "code"
             ] == "provider_usage_auth_rejected"

      recovered_source = Repo.get!(PoolUpstreamAssignment, recovery.linked_assignment.id)
      recovered_sibling = Repo.get!(PoolUpstreamAssignment, recovery.sibling_assignment.id)

      for assignment <- [recovered_source, recovered_sibling] do
        assert assignment.status == "active"
        assert assignment.health_status == "active"
        assert assignment.eligibility_status == "eligible"
        assert assignment.cooldown_until == nil
        assert assignment.disabled_at == nil
      end

      assert Repo.get!(PoolUpstreamAssignment, recovery.deleted_assignment.id) ==
               recovery.deleted_before

      assert [_window] = QuotaWindows.list_quota_windows(recovered_identity)

      recovered_event_assignment_ids =
        for _index <- 1..2 do
          assert_receive {Events,
                          %{
                            reason: "upstream_quota_windows_updated",
                            payload: %{
                              "assignment_id" => assignment_id,
                              "upstream_status" => "active"
                            }
                          }}

          assignment_id
        end

      assert Enum.sort(recovered_event_assignment_ids) ==
               Enum.sort([recovered_source.id, recovered_sibling.id])

      current_epoch = recovered_identity.metadata["credential_epoch"]
      applied_sequence = recovered_identity.metadata["usage_probe_applied_sequence"]

      for stale_fence <- [
            %{credential_epoch: current_epoch - 1, usage_probe_sequence: applied_sequence + 10},
            %{credential_epoch: current_epoch, usage_probe_sequence: applied_sequence - 1},
            %{credential_epoch: current_epoch, usage_probe_sequence: applied_sequence}
          ] do
        assert {:ok, :superseded, _identity, nil} =
                 CredentialFencing.apply_usage_success(
                   recovered_identity,
                   stale_fence,
                   fn _identity ->
                     send(self(), :unexpected_duplicate_persist)
                     {:ok, :unexpected}
                   end
                 )
      end

      refute_received :unexpected_duplicate_persist
    end

    for completion_order <- [:rejection_first, :success_first] do
      test "higher-sequence recovery worker converges both pools with #{completion_order} completion" do
        completion_order = unquote(completion_order)
        rejection_release_ref = make_ref()
        success_release_ref = make_ref()

        rejection_upstream =
          start_upstream(rejection_barrier_paths(self(), rejection_release_ref))

        success_upstream =
          start_upstream(
            FakeUpstream.barrier_json_response(usage_payload(),
              notify: self(),
              release_ref: success_release_ref
            )
          )

        recovery = rejected_and_relinked_identity_fixture()
        recovery_epoch = recovery.linked_identity.metadata["credential_epoch"]

        rejection_assignment =
          update_assignment_upstream!(recovery.linked_assignment, rejection_upstream)

        success_assignment =
          update_assignment_upstream!(recovery.sibling_assignment, success_upstream)

        rejection_task =
          start_reconciliation_worker_task(rejection_assignment, recovery_epoch)

        first_rejection_barrier = await_upstream_barrier(rejection_release_ref)

        success_task = start_reconciliation_worker_task(success_assignment, recovery_epoch)
        success_barrier = await_upstream_barrier(success_release_ref)

        complete_recovery_race(
          completion_order,
          recovery,
          rejection_task,
          success_task,
          first_rejection_barrier,
          success_barrier,
          rejection_release_ref,
          success_release_ref
        )

        recovered_identity = Repo.get!(UpstreamIdentity, recovery.linked_identity.id)
        assert recovered_identity.status == "active"
        assert recovered_identity.metadata["usage_probe_sequence"] == 3
        assert recovered_identity.metadata["usage_probe_applied_sequence"] == 3
        assert recovered_identity.metadata["provider_auth_recovery"]["status"] == "recovered"
        assert_identity_assignments_recovered!(recovery)

        request_count = length(FakeUpstream.requests(success_upstream))
        applied_sequence = recovered_identity.metadata["usage_probe_applied_sequence"]

        assert :ok =
                 AccountReconciliationWorker.perform(
                   reconciliation_job(success_assignment, recovery_epoch)
                 )

        assert length(FakeUpstream.requests(success_upstream)) == request_count

        duplicate_identity = Repo.get!(UpstreamIdentity, recovered_identity.id)
        assert duplicate_identity.metadata["usage_probe_applied_sequence"] == applied_sequence

        assert :ok =
                 AccountReconciliationWorker.perform(
                   reconciliation_job(success_assignment, recovery_epoch - 1)
                 )

        assert length(FakeUpstream.requests(success_upstream)) == request_count
        assert_identity_assignments_recovered!(recovery)

        assert Repo.get!(PoolUpstreamAssignment, recovery.deleted_assignment.id) ==
                 recovery.deleted_before
      end
    end

    for completion_order <- [:rejection_first, :success_first] do
      test "higher-sequence rejection owns reconciliation persistence with #{completion_order} completion" do
        completion_order = unquote(completion_order)
        success_release_ref = make_ref()
        rejection_release_ref = make_ref()

        upstream =
          start_upstream(
            {:sequence,
             [
               FakeUpstream.barrier_json_response(usage_payload(),
                 notify: self(),
                 release_ref: success_release_ref
               ),
               FakeUpstream.barrier_json_response(%{"error" => "rejected"},
                 status: 401,
                 notify: self(),
                 release_ref: rejection_release_ref
               ),
               FakeUpstream.barrier_json_response(%{"error" => "rejected"},
                 status: 401,
                 notify: self(),
                 release_ref: rejection_release_ref
               )
             ]}
          )

        {_pool, assignment} = active_usage_probe_assignment(upstream)
        identity = Repo.get!(UpstreamIdentity, assignment.upstream_identity_id)
        initial_success_at = ~U[2026-07-01 12:00:00.000000Z]

        assignment =
          assignment
          |> PoolUpstreamAssignment.changeset(%{last_successful_refresh_at: initial_success_at})
          |> Repo.update!()

        success_task = start_account_reconciliation_worker_task(assignment)
        success_barrier = await_upstream_barrier(success_release_ref)

        rejection_task = start_account_reconciliation_worker_task(assignment)
        first_rejection_barrier = await_upstream_barrier(rejection_release_ref)

        maybe_complete_lower_success_first(
          completion_order,
          success_task,
          success_barrier,
          success_release_ref
        )

        release_upstream_barrier(first_rejection_barrier, rejection_release_ref)
        second_rejection_barrier = await_upstream_barrier(rejection_release_ref)
        release_upstream_barrier(second_rejection_barrier, rejection_release_ref)
        assert {:error, rejection_error} = Task.await(rejection_task)
        assert rejection_error =~ "quota_refresh_auth_unavailable"

        rejected_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
        rejected_identity = Repo.get!(UpstreamIdentity, identity.id)
        rejection_summary = rejected_assignment.metadata["last_reconciliation"]
        rejection_success_at = rejected_assignment.last_successful_refresh_at
        rejection_windows = QuotaWindows.list_quota_windows(rejected_identity)

        assert rejection_summary["status"] == "partial"
        assert rejected_identity.status == "reauth_required"
        assert rejected_assignment.health_status == "disabled"
        assert rejected_assignment.eligibility_status == "ineligible"

        assert_rejection_persistence_after_race(
          completion_order,
          %{
            assignment: assignment,
            identity: identity,
            success_task: success_task,
            success_barrier: success_barrier,
            success_release_ref: success_release_ref,
            initial_success_at: initial_success_at,
            rejection_summary: rejection_summary,
            rejection_success_at: rejection_success_at,
            rejection_windows: rejection_windows
          }
        )
      end
    end

    test "transient account reconciliation token refresh failure does not reuse persisted quota" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      access_token = "token-access-reconciliation-recovery-do-not-leak"
      refresh_token = "token-refresh-reconciliation-recovery-do-not-leak"
      provider_body = "raw-provider-body-reconciliation-recovery-do-not-leak"

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {401, %{"error" => "expired_access_token"}},
             "/oauth/token" => {503, %{"error" => provider_body}}
           }}
        )

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          access_token: access_token,
          identity_metadata: %{"base_url" => FakeUpstream.url(upstream)}
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      persist_quota_windows!(identity, [persisted_account_primary_window_attrs(observed_at)])

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "refresh_token",
                 plaintext: refresh_token
               })

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)
      assert %{discard: 1, success: 0} = Oban.drain_queue(queue: :jobs)

      discarded_job = Repo.get!(Oban.Job, job.id)
      assert discarded_job.state == "discarded"

      persisted_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted_identity.status == "refresh_failed"

      token_refresh_metadata = persisted_identity.metadata["token_refresh"]
      assert token_refresh_metadata["trigger_kind"] == "account_reconciliation"
      assert token_refresh_metadata["status"] == "failed"
      assert token_refresh_metadata["reason"]["code"] == "codex_auth_transient"

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      last_reconciliation = assignment.metadata["last_reconciliation"]
      assert last_reconciliation["status"] == "partial"
      assert assignment.metadata["quota_priming"]["status"] == "failed"

      assert assignment.metadata["quota_priming"]["reason"]["code"] ==
               "quota_refresh_auth_unavailable"

      assert [%{"code" => "quota_refresh_auth_unavailable"}] =
               Enum.filter(last_reconciliation["steps"], &(&1["status"] == "failed"))

      refute Enum.any?(
               last_reconciliation["steps"],
               &(&1["code"] == "quota_reused_fresh")
             )

      assert [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == observed_at

      assert [recovery_job] = incomplete_token_refresh_jobs(identity.id)

      assert recovery_job.args == %{
               "upstream_identity_id" => identity.id,
               "trigger_kind" => "account_reconciliation_recovery"
             }

      safe_surfaces = [
        inspect(recovery_job.args),
        inspect(recovery_job.meta),
        inspect(recovery_job.errors),
        inspect(discarded_job.args),
        inspect(discarded_job.meta),
        inspect(discarded_job.errors),
        inspect(token_refresh_metadata)
      ]

      for surface <- safe_surfaces do
        refute surface =~ access_token
        refute surface =~ refresh_token
        refute surface =~ provider_body
        refute surface =~ "auth_json"
      end
    end

    @tag :scheduled_identity_reconciliation
    test "enqueues one scheduled account reconciliation job per active upstream identity" do
      {pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      later_created_at = DateTime.add(assignment.created_at, 60, :second)

      {_second_pool, second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Job assignment duplicate",
          created_at: later_created_at
        )

      assert {:ok, %{inserted: [job], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert job.args["pool_id"] == pool.id
      assert job.args["pool_upstream_assignment_id"] == assignment.id
      assert job.args["upstream_identity_id"] == identity.id
      assert job.args["trigger_kind"] == "scheduled"
      assert job.args["target_kind"] == "upstream_identity"

      assert [row] = Jobs.list_recent_account_reconciliation_jobs(pool)
      assert row.id == job.id
      assert row.args["pool_upstream_assignment_id"] == assignment.id

      canonical_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      sibling_assignment = Repo.get!(PoolUpstreamAssignment, second_assignment.id)
      assert is_nil(canonical_assignment.metadata["last_reconciliation"])
      assert is_nil(sibling_assignment.metadata["last_reconciliation"])
    end

    @tag :scheduled_identity_reconciliation
    test "deduplicates incomplete scheduled reconciliation jobs by upstream identity" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      {_second_pool, _second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Job assignment duplicate",
          created_at: DateTime.add(assignment.created_at, 60, :second)
        )

      assert {:ok, %{inserted: [first_job], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert first_job.args["upstream_identity_id"] == identity.id
      assert first_job.args["target_kind"] == "upstream_identity"

      assert {:ok, %{inserted: [], conflicts: [conflict_job], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert conflict_job.conflict?
      assert conflict_job.id == first_job.id

      {1, _rows} =
        from(job in Oban.Job, where: job.id == ^first_job.id)
        |> Repo.update_all(
          set: [
            state: "completed",
            attempt: 1,
            inserted_at:
              DateTime.utc_now()
              |> DateTime.add(-61, :second)
              |> DateTime.truncate(:microsecond),
            attempted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
            completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          ]
        )

      assert {:ok, %{inserted: [later_job], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert later_job.id != first_job.id
      assert later_job.args["upstream_identity_id"] == identity.id
      assert later_job.args["pool_upstream_assignment_id"] == assignment.id
    end

    test "malformed active-pool trigger kind falls back to manual assignment fanout" do
      {pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      {second_pool, second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Malformed trigger duplicate",
          created_at: DateTime.add(assignment.created_at, 60, :second)
        )

      assert {:ok, %{inserted: jobs, conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: :scheduled)

      args = jobs |> Enum.map(& &1.args) |> Enum.sort_by(& &1["pool_id"])

      assert args ==
               Enum.sort_by(
                 [
                   %{
                     "pool_id" => pool.id,
                     "pool_upstream_assignment_id" => assignment.id,
                     "trigger_kind" => "manual"
                   },
                   %{
                     "pool_id" => second_pool.id,
                     "pool_upstream_assignment_id" => second_assignment.id,
                     "trigger_kind" => "manual"
                   }
                 ],
                 & &1["pool_id"]
               )

      refute Enum.any?(jobs, &Map.has_key?(&1.args, "target_kind"))
      refute Enum.any?(jobs, &Map.has_key?(&1.args, "upstream_identity_id"))
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

    test "skips already queued account reconciliation jobs when upstream account requires reauth" do
      {pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)

      assert {:ok, %{status: :reauth_required, retryable?: false}} =
               TokenRefresh.refresh_access_token(identity, trigger_kind: "scheduled")

      assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :jobs)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.errors == []

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert is_nil(assignment.metadata["quota_priming"])
      assert is_nil(assignment.metadata["last_reconciliation"])
    end

    test "gateway finalization reuses an incomplete scheduled identity reconciliation" do
      {pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      {_second_pool, second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Gateway assignment duplicate",
          created_at: DateTime.add(assignment.created_at, 60, :second)
        )

      assert {:ok, %{inserted: [scheduled_job], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert :ok =
               SideEffects.maybe_enqueue_gateway_reconciliation(
                 second_assignment.pool_id,
                 second_assignment
               )

      assert [persisted_job] =
               Repo.all(
                 from(job in Oban.Job,
                   where: job.worker == ^worker_name(AccountReconciliationWorker)
                 )
               )

      assert persisted_job.id == scheduled_job.id
      assert scheduled_job.args["pool_id"] == pool.id
      assert scheduled_job.args["pool_upstream_assignment_id"] == assignment.id
      assert scheduled_job.args["upstream_identity_id"] == identity.id
      assert scheduled_job.args["trigger_kind"] == "scheduled"
    end

    test "scheduled reconciliation reuses an incomplete gateway identity reconciliation" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      {second_pool, second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Scheduled assignment duplicate",
          created_at: DateTime.add(assignment.created_at, 60, :second)
        )

      assert {:ok, gateway_job} =
               Jobs.enqueue_gateway_account_reconciliation(second_pool, second_assignment)

      assert {:ok, %{inserted: [], conflicts: [scheduled_conflict], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      refute gateway_job.conflict?
      assert scheduled_conflict.conflict?
      assert scheduled_conflict.id == gateway_job.id

      assert gateway_job.args == %{
               "pool_id" => second_pool.id,
               "pool_upstream_assignment_id" => second_assignment.id,
               "upstream_identity_id" => identity.id,
               "target_kind" => "upstream_identity",
               "trigger_kind" => "gateway"
             }
    end

    test "concurrent gateway finalization enqueues one effective reconciliation job" do
      {pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      {second_pool, second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Concurrent gateway assignment",
          created_at: DateTime.add(assignment.created_at, 60, :second)
        )

      targets =
        [{pool, assignment}, {second_pool, second_assignment}]
        |> Stream.cycle()
        |> Enum.take(12)

      results =
        Enum.map(targets, fn {target_pool, target_assignment} ->
          start_allowed_task(fn ->
            Jobs.enqueue_gateway_account_reconciliation(target_pool, target_assignment)
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, %{conflict?: false}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, %{conflict?: true}}, &1)) == 11

      assert [job_id] =
               results
               |> Enum.map(fn {:ok, job} -> job.id end)
               |> Enum.uniq()

      assert [persisted_job] =
               Repo.all(
                 from(job in Oban.Job,
                   where: job.worker == ^worker_name(AccountReconciliationWorker)
                 )
               )

      assert persisted_job.id == job_id

      Repo.delete_all(Oban.Job)

      side_effect_results =
        Enum.map(targets, fn {target_pool, target_assignment} ->
          start_allowed_task(fn ->
            SideEffects.maybe_enqueue_gateway_reconciliation(
              target_pool.id,
              target_assignment
            )
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.all?(side_effect_results, &(&1 == :ok))

      assert [_single_job] =
               Repo.all(
                 from(job in Oban.Job,
                   where: job.worker == ^worker_name(AccountReconciliationWorker)
                 )
               )
    end

    test "automatic reconciliation blocks incomplete jobs older than the cooldown" do
      {pool, assignment} = active_assignment_fixture(%{})

      for incomplete_state <- ~w(suspended available scheduled executing retryable) do
        Repo.delete_all(Oban.Job)

        assert {:ok, first_job} =
                 Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

        expired_inserted_at =
          DateTime.utc_now()
          |> DateTime.add(-120, :second)
          |> DateTime.truncate(:microsecond)

        {1, _rows} =
          from(job in Oban.Job, where: job.id == ^first_job.id)
          |> Repo.update_all(set: [state: incomplete_state, inserted_at: expired_inserted_at])

        assert {:ok, duplicate_job} =
                 Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

        assert duplicate_job.conflict?
        assert duplicate_job.id == first_job.id
      end
    end

    test "automatic reconciliation cools down completion but not cancelled or discarded jobs" do
      {pool, assignment} = active_assignment_fixture(%{})

      assert {:ok, completed_job} =
               Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

      {1, _rows} =
        from(job in Oban.Job, where: job.id == ^completed_job.id)
        |> Repo.update_all(set: [state: "completed"])

      assert {:ok, completed_conflict} =
               Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

      assert completed_conflict.conflict?
      assert completed_conflict.id == completed_job.id

      for retryable_terminal_state <- ~w(discarded cancelled) do
        Repo.delete_all(Oban.Job)

        assert {:ok, first_job} =
                 Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

        {1, _rows} =
          from(job in Oban.Job, where: job.id == ^first_job.id)
          |> Repo.update_all(set: [state: retryable_terminal_state])

        assert {:ok, replacement_job} =
                 Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

        refute replacement_job.conflict?
        assert replacement_job.id != first_job.id
      end
    end

    test "gateway reconciliation can run again after the automatic cooldown expires" do
      {pool, assignment} = active_assignment_fixture(%{})

      assert {:ok, first_job} = Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

      expired_inserted_at =
        DateTime.utc_now()
        |> DateTime.add(-61, :second)
        |> DateTime.truncate(:microsecond)

      {1, _rows} =
        from(job in Oban.Job, where: job.id == ^first_job.id)
        |> Repo.update_all(set: [state: "completed", inserted_at: expired_inserted_at])

      assert {:ok, later_job} = Jobs.enqueue_gateway_account_reconciliation(pool, assignment)

      refute later_job.conflict?
      assert later_job.id != first_job.id
    end

    test "manual reconciliation can target a non-canonical assignment for the same identity" do
      {_canonical_pool, canonical_assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(canonical_assignment.upstream_identity_id)

      {requested_pool, requested_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Manual requested assignment",
          created_at: DateTime.add(canonical_assignment.created_at, 60, :second)
        )

      assert {:ok, job} =
               Jobs.enqueue_account_reconciliation(requested_pool, requested_assignment,
                 trigger_kind: "manual"
               )

      assert job.args == %{
               "pool_id" => requested_pool.id,
               "pool_upstream_assignment_id" => requested_assignment.id,
               "trigger_kind" => "manual"
             }
    end
  end

  defp start_allowed_task(fun) when is_function(fun, 0) do
    task = Task.async(fun)
    Sandbox.allow(Repo, self(), task.pid)
    task
  end

  defp start_reconciliation_worker_task(assignment, credential_epoch) do
    start_allowed_task(fn ->
      AccountReconciliationWorker.perform(reconciliation_job(assignment, credential_epoch))
    end)
  end

  defp start_account_reconciliation_worker_task(assignment) do
    start_allowed_task(fn ->
      AccountReconciliationWorker.perform(%Oban.Job{
        args: %{
          "pool_id" => assignment.pool_id,
          "pool_upstream_assignment_id" => assignment.id,
          "trigger_kind" => "scheduled"
        }
      })
    end)
  end

  defp maybe_complete_lower_success_first(
         :success_first,
         success_task,
         success_barrier,
         success_release_ref
       ) do
    release_upstream_barrier(success_barrier, success_release_ref)
    assert :ok = Task.await(success_task)
  end

  defp maybe_complete_lower_success_first(
         :rejection_first,
         _success_task,
         _success_barrier,
         _success_release_ref
       ),
       do: :ok

  defp assert_rejection_persistence_after_race(
         :rejection_first,
         %{
           assignment: assignment,
           identity: identity,
           success_task: success_task,
           success_barrier: success_barrier,
           success_release_ref: success_release_ref,
           initial_success_at: initial_success_at,
           rejection_summary: rejection_summary,
           rejection_success_at: rejection_success_at,
           rejection_windows: rejection_windows
         }
       ) do
    assert rejection_success_at == initial_success_at
    assert rejection_windows == []

    release_upstream_barrier(success_barrier, success_release_ref)
    assert :ok = Task.await(success_task)

    current_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
    current_identity = Repo.get!(UpstreamIdentity, identity.id)

    assert current_assignment.metadata["last_reconciliation"] == rejection_summary
    assert current_assignment.last_successful_refresh_at == rejection_success_at
    assert current_identity.status == "reauth_required"
    assert current_assignment.health_status == "disabled"
    assert current_assignment.eligibility_status == "ineligible"
    assert QuotaWindows.list_quota_windows(current_identity) == rejection_windows
  end

  defp assert_rejection_persistence_after_race(
         :success_first,
         %{
           initial_success_at: initial_success_at,
           rejection_success_at: rejection_success_at,
           rejection_windows: rejection_windows
         }
       ) do
    assert DateTime.compare(rejection_success_at, initial_success_at) == :gt
    assert [_window] = rejection_windows
  end

  defp complete_recovery_race(
         :rejection_first,
         recovery,
         rejection_task,
         success_task,
         first_rejection_barrier,
         success_barrier,
         rejection_release_ref,
         success_release_ref
       ) do
    release_upstream_barrier(first_rejection_barrier, rejection_release_ref)
    second_rejection_barrier = await_upstream_barrier(rejection_release_ref)
    release_upstream_barrier(second_rejection_barrier, rejection_release_ref)

    assert {:error, rejection_error} = Task.await(rejection_task)
    assert rejection_error =~ "quota_refresh_auth_unavailable"
    assert_identity_assignments_blocked!(recovery)

    release_upstream_barrier(success_barrier, success_release_ref)
    assert :ok = Task.await(success_task)
  end

  defp complete_recovery_race(
         :success_first,
         _recovery,
         rejection_task,
         success_task,
         first_rejection_barrier,
         success_barrier,
         rejection_release_ref,
         success_release_ref
       ) do
    release_upstream_barrier(success_barrier, success_release_ref)
    assert :ok = Task.await(success_task)

    release_upstream_barrier(first_rejection_barrier, rejection_release_ref)
    second_rejection_barrier = await_upstream_barrier(rejection_release_ref)
    release_upstream_barrier(second_rejection_barrier, rejection_release_ref)
    assert :ok = Task.await(rejection_task)
  end

  defp reconciliation_job(assignment, credential_epoch) do
    %Oban.Job{
      args: %{
        "pool_id" => assignment.pool_id,
        "pool_upstream_assignment_id" => assignment.id,
        "upstream_identity_id" => assignment.upstream_identity_id,
        "credential_epoch" => credential_epoch,
        "recovery_required" => true,
        "trigger_kind" => "scheduled",
        "target_kind" => "upstream_identity"
      }
    }
  end

  defp await_upstream_barrier(release_ref) do
    assert_receive {:fake_upstream_timeout_barrier, :before_headers, pid, ^release_ref}, 5_000
    pid
  end

  defp release_upstream_barrier(pid, release_ref) do
    send(pid, {:fake_upstream_release_timeout, release_ref})
  end

  defp rejection_barrier_paths(notify, release_ref) do
    response =
      FakeUpstream.barrier_json_response(%{"error" => "rejected"},
        status: 401,
        notify: notify,
        release_ref: release_ref
      )

    {:path_json,
     %{
       "/backend-api/wham/usage" => response,
       "/backend-api/codex/usage" => response
     }}
  end

  defp assignment_with_upstream(assignment, upstream) do
    %{
      assignment
      | metadata: Map.put(assignment.metadata || %{}, "base_url", FakeUpstream.url(upstream))
    }
  end

  defp update_assignment_upstream!(assignment, upstream) do
    assignment
    |> PoolUpstreamAssignment.changeset(%{
      metadata: Map.put(assignment.metadata || %{}, "base_url", FakeUpstream.url(upstream))
    })
    |> Repo.update!()
  end

  defp rejected_and_relinked_identity_fixture do
    rejection_upstream = start_upstream(unavailable_usage_paths(401, %{"error" => "rejected"}))
    {source_pool, source_assignment} = active_usage_probe_assignment(rejection_upstream)
    identity = Upstreams.get_upstream_identity(source_assignment.upstream_identity_id)

    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        metadata: Map.put(identity.metadata || %{}, "audit_marker", %{"safe" => "retained"})
      })
      |> Repo.update!()

    {sibling_pool, sibling_assignment} =
      active_assignment_for_identity_fixture(identity,
        assignment_label: "Sibling recovery assignment"
      )

    deleted_pool = pool_fixture()

    assert {:ok, deleted_assignment} =
             PoolAssignments.create_pool_assignment(deleted_pool, identity, %{
               assignment_label: "Deleted recovery assignment",
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

    assert {:ok, %{assignment: deleted_assignment}} =
             PoolAssignments.delete_pool_assignment(deleted_pool, deleted_assignment)

    deleted_before = Repo.get!(PoolUpstreamAssignment, deleted_assignment.id)

    assert {:ok, rejected_result} =
             Upstreams.reconcile_pool_account(source_pool, source_assignment)

    assert rejected_result.identity.status == "reauth_required"

    assert_identity_assignments_blocked!(%{
      linked_identity: identity,
      linked_assignment: source_assignment,
      sibling_assignment: sibling_assignment
    })

    rejected_identity = Repo.get!(UpstreamIdentity, identity.id)
    initial_epoch = rejected_identity.metadata["credential_epoch"]

    assert {:ok, %{identity: linked_identity, assignment: linked_assignment}} =
             TokenLinking.link_tokens(
               fixture_scope(),
               source_pool,
               %{
                 chatgpt_account_id: identity.chatgpt_account_id,
                 account_label: identity.account_label,
                 token: "relinked-access-token"
               },
               target_identity_id: identity.id
             )

    %{
      source_pool: source_pool,
      sibling_pool: sibling_pool,
      linked_identity: linked_identity,
      linked_assignment: linked_assignment,
      sibling_assignment: sibling_assignment,
      deleted_assignment: deleted_assignment,
      deleted_before: deleted_before,
      initial_epoch: initial_epoch
    }
  end

  defp assert_identity_assignments_blocked!(recovery) do
    identity = Repo.get!(UpstreamIdentity, recovery.linked_identity.id)
    assert identity.status == "reauth_required"

    for assignment_id <- [recovery.linked_assignment.id, recovery.sibling_assignment.id] do
      assignment = Repo.get!(PoolUpstreamAssignment, assignment_id)
      assert assignment.health_status == "disabled"
      assert assignment.eligibility_status == "ineligible"
      assert %DateTime{} = assignment.disabled_at
    end
  end

  defp assert_identity_assignments_recovered!(recovery) do
    identity = Repo.get!(UpstreamIdentity, recovery.linked_identity.id)
    assert identity.status == "active"
    assert identity.disabled_at == nil

    for assignment_id <- [recovery.linked_assignment.id, recovery.sibling_assignment.id] do
      assignment = Repo.get!(PoolUpstreamAssignment, assignment_id)
      assert assignment.status == "active"
      assert assignment.health_status == "active"
      assert assignment.eligibility_status == "eligible"
      assert assignment.disabled_at == nil
    end
  end

  def handle_assignment_update_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    if metadata[:repo] == Repo and metadata[:source] == "pool_upstream_assignments" do
      send(test_pid, {handler_id, %{params: metadata[:params]}})
    end
  end

  defp capture_assignment_updates(fun) when is_function(fun, 0) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_assignment_update_event/4,
        {handler_id, test_pid}
      )

    try do
      result = fun.()
      {result, drain_assignment_update_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_assignment_update_events(handler_id, updates) do
    receive do
      {^handler_id, update} -> drain_assignment_update_events(handler_id, [update | updates])
    after
      10 -> Enum.reverse(updates)
    end
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

  defp unavailable_usage_paths(status \\ 404, body \\ %{"error" => "missing"}) do
    {:path_json,
     %{
       "/api/codex/usage" => {status, body},
       "/backend-api/codex/usage" => {status, body},
       "/wham/usage" => {status, body},
       "/backend-api/wham/usage" => {status, body}
     }}
  end

  defp usage_payload do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 25,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 3_600
        }
      }
    }
  end

  defp weekly_usage_payload do
    %{
      "rate_limit" => %{
        "secondary_window" => %{
          "used_percent" => 25,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 3_600
        }
      }
    }
  end

  defp usage_path_responses(paths, statuses, body) do
    {:path_json,
     paths
     |> Enum.zip(statuses)
     |> Map.new(fn {path, status} -> {path, {status, body}} end)}
  end

  defp active_usage_probe_assignment(upstream, assignment_metadata \\ %{}) do
    active_assignment_fixture(
      Map.put(assignment_metadata, "base_url", FakeUpstream.url(upstream)),
      identity_metadata: fresh_access_token_metadata(FakeUpstream.url(upstream))
    )
  end

  defp fresh_access_token_metadata(base_url) do
    %{
      "base_url" => base_url,
      "access_token_expires_at" =>
        DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
    }
  end

  defp persisted_account_primary_window_attrs(observed_at, overrides \\ %{}) do
    Map.merge(
      %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("47"),
        reset_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        source: "codex_usage_api",
        source_precision: "observed",
        freshness_state: "fresh",
        observed_at: observed_at
      },
      overrides
    )
  end

  defp persist_quota_windows!(identity, window_attrs) do
    assert {:ok, windows} = QuotaWindows.upsert_quota_windows(identity, window_attrs)
    windows
  end

  defp assert_scheduled_worker_quota_failure(pool, assignment, expected_code) do
    assert {:ok, job} =
             Jobs.enqueue_account_reconciliation(pool, assignment, trigger_kind: "scheduled")

    assert %{discard: 1, success: 0} = Oban.drain_queue(queue: :jobs)

    discarded_job = Repo.get!(Oban.Job, job.id)
    assert discarded_job.state == "discarded"
    assert discarded_job.max_attempts == 1
    assert [%{"error" => error}] = discarded_job.errors
    assert error =~ "account reconciliation partial: #{expected_code}"

    assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
    assert assignment.metadata["last_reconciliation"]["status"] == "partial"
    assert assignment.metadata["quota_priming"]["status"] == "failed"
    assert assignment.metadata["quota_priming"]["reason"]["code"] == expected_code

    assert [%{"code" => ^expected_code, "status" => "failed"}] =
             Enum.filter(
               assignment.metadata["last_reconciliation"]["steps"],
               &(&1["status"] == "failed")
             )

    discarded_job
  end

  defp active_assignment_fixture(metadata, opts \\ []) do
    pool = pool_fixture()

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Job account",
               onboarding_method: "import",
               metadata: Keyword.get(opts, :identity_metadata, %{})
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    configure_upstream_secret_key!()

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: Keyword.get(opts, :access_token, "token")
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

  defp incomplete_token_refresh_jobs(identity_id) do
    Oban.Job
    |> where([job], job.worker == ^worker_name(TokenRefreshWorker))
    |> Repo.all()
    |> Enum.filter(fn job ->
      job.args["upstream_identity_id"] == identity_id and
        job.state not in ["completed", "cancelled", "discarded"]
    end)
  end

  defp active_assignment_for_identity_fixture(identity, attrs) do
    pool = Keyword.get(attrs, :pool, pool_fixture())

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: Keyword.fetch!(attrs, :assignment_label),
               created_at: Keyword.get(attrs, :created_at, DateTime.utc_now()),
               metadata: Keyword.get(attrs, :metadata, %{})
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
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
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
