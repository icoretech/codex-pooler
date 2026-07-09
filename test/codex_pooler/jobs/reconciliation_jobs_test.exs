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
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

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

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

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

        assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
                 "/backend-api/wham/usage"
               ]
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
               "/backend-api/wham/usage"
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

  defp unavailable_usage_paths(status \\ 404, body \\ %{"error" => "missing"}) do
    {:path_json,
     %{
       "/api/codex/usage" => {status, body},
       "/backend-api/codex/usage" => {status, body},
       "/wham/usage" => {status, body},
       "/backend-api/wham/usage" => {status, body}
     }}
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
