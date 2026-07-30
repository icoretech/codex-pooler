defmodule CodexPooler.Jobs.ReconciliationJobsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
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
  alias CodexPooler.Jobs.SavedResetRedemptionWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Jobs.UpstreamEnqueue
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.PostResetEvidence
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
      assert result.quota.details["window_count"] == 2

      windows = QuotaWindows.list_quota_windows(identity)
      assert length(windows) == 2
      assert Enum.all?(windows, &(&1.observed_at == observed_at))

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "persisted quota reuse owns one historical timestamp across freshness boundaries" do
      as_of = ~U[2026-07-25 12:00:00.000000Z]
      ttl = Evidence.freshness_ttl_seconds()

      for {label, age_seconds, expected_code} <- [
            {"TTL-1s", ttl - 1, "quota_reused_fresh"},
            {"TTL", ttl, "quota_reused_fresh"},
            {"TTL+1s", ttl + 1, "quota_refresh_unavailable"}
          ] do
        upstream = start_upstream(unavailable_usage_paths())

        {pool, assignment} =
          active_assignment_fixture(
            %{"base_url" => FakeUpstream.url(upstream)},
            identity_metadata: %{
              "base_url" => FakeUpstream.url(upstream),
              "access_token_expires_at" => "2026-07-27T23:59:59Z"
            }
          )

        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

        persist_quota_windows!(identity, [
          persisted_account_primary_window_attrs(
            DateTime.add(as_of, -age_seconds, :second),
            %{reset_at: DateTime.add(as_of, 4, :hour)}
          )
        ])

        assert {:ok, result} =
                 PoolReconciliation.reconcile_pool_account(pool, assignment, as_of: as_of)

        assert result.quota.code == expected_code, label
      end
    end

    test "persisted quota reuse treats reset_at less than or equal to as_of as expired" do
      as_of = ~U[2026-07-25 12:00:00.000000Z]

      for {label, reset_offset_seconds, expected_code} <- [
            {"before", -1, "quota_refresh_unavailable"},
            {"equal", 0, "quota_refresh_unavailable"},
            {"after", 1, "quota_reused_fresh"}
          ] do
        upstream = start_upstream(unavailable_usage_paths())

        {pool, assignment} =
          active_assignment_fixture(
            %{"base_url" => FakeUpstream.url(upstream)},
            identity_metadata: %{
              "base_url" => FakeUpstream.url(upstream),
              "access_token_expires_at" => "2026-07-27T23:59:59Z"
            }
          )

        identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

        persist_quota_windows!(identity, [
          persisted_account_primary_window_attrs(as_of, %{
            reset_at: DateTime.add(as_of, reset_offset_seconds, :second)
          })
        ])

        assert {:ok, result} =
                 PoolReconciliation.reconcile_pool_account(pool, assignment, as_of: as_of)

        assert result.quota.code == expected_code, label
      end
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
      assert result.quota.details["window_count"] == 2

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

    test "reuses fresh persisted quota when live usage returns 429" do
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

      # Being told to slow down does not invalidate a usable snapshot.
      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded
      assert result.quota.status == :succeeded
      assert result.quota.code == "quota_reused_fresh"
      assert result.quota.details["window_count"] == 1

      [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == observed_at

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "does not reuse persisted quota when a 429 follows an auth-shaped rejection" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      future_expiry = observed_at |> DateTime.add(10, :day) |> DateTime.to_iso8601()

      for auth_status <- [401, 403] do
        upstream =
          start_upstream(
            {:path_json,
             %{
               "/backend-api/wham/usage" => {auth_status, %{"error" => "rejected"}},
               "/backend-api/codex/usage" => {429, %{"error" => "busy"}}
             }}
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

        assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
        assert result.status == :partial
        assert result.quota.status == :failed
        assert result.quota.code == "quota_refresh_unavailable"

        assert result.quota.message ==
                 "quota windows were not available (mixed_auth_rejection_upstream_status_429)"

        assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
                 "/backend-api/wham/usage",
                 "/backend-api/codex/usage"
               ]
      end
    end

    test "does not reuse persisted quota when an auth-shaped rejection follows a 429" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      future_expiry = observed_at |> DateTime.add(10, :day) |> DateTime.to_iso8601()

      for auth_status <- [401, 403] do
        upstream =
          start_upstream(
            {:path_json,
             %{
               "/backend-api/wham/usage" => {429, %{"error" => "busy"}},
               "/backend-api/codex/usage" => {auth_status, %{"error" => "rejected"}}
             }}
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

        assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
        assert result.status == :partial
        assert result.quota.status == :failed
        assert result.quota.code == "quota_refresh_unavailable"

        assert result.quota.message ==
                 "quota windows were not available (mixed_auth_rejection_upstream_status_429)"

        assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
                 "/backend-api/wham/usage",
                 "/backend-api/codex/usage"
               ]
      end
    end

    test "does not lose auth-shaped rejection before an invalid payload and later 429" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

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
             "/backend-api/codex/usage" => {200, []},
             "/backend-api/wham/usage" => {429, %{"error" => "busy"}}
           }}
        )

      {pool, assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata: %{
            "base_url" => FakeUpstream.url(upstream),
            "access_token_expires_at" =>
              observed_at |> DateTime.add(10, :day) |> DateTime.to_iso8601(),
            "saved_resets" => %{"usage_path" => "/api/codex/usage"}
          }
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      persist_quota_windows!(identity, [persisted_account_primary_window_attrs(observed_at)])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :partial
      assert result.quota.code == "quota_refresh_unavailable"

      assert result.quota.message ==
               "quota windows were not available (mixed_auth_rejection_upstream_status_429)"

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == paths
    end

    test "scheduled worker reuses fresh weekly-only persisted quota when live usage is unavailable" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      window_attrs =
        persisted_account_primary_window_attrs(observed_at, %{
          window_kind: "secondary",
          window_minutes: 10_080,
          quota_family: "account"
        })

      upstream = start_upstream(unavailable_usage_paths())

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      persist_quota_windows!(identity, [window_attrs])

      assert {:ok, job} =
               Jobs.enqueue_account_reconciliation(pool, assignment, trigger_kind: "scheduled")

      assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :jobs)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.errors == []

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
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
    end

    test "scheduled worker does not reuse stale expired resetless or exhausted persisted quota" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      weekly_window = fn observed_at, attrs ->
        persisted_account_primary_window_attrs(
          observed_at,
          Map.merge(
            %{window_kind: "secondary", window_minutes: 10_080, quota_family: "account"},
            attrs
          )
        )
      end

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
        {"weekly_stale",
         weekly_window.(DateTime.add(now, -3_600, :second), %{
           reset_at: DateTime.add(now, 3_600, :second)
         })},
        {"weekly_expired", weekly_window.(now, %{reset_at: DateTime.add(now, -60, :second)})},
        {"weekly_resetless", weekly_window.(now, %{reset_at: nil})},
        {"weekly_exhausted", weekly_window.(now, %{used_percent: Decimal.new("100")})}
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

    test "scheduled worker reuses fresh persisted quota after 429" do
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

      assert {:ok, job} =
               Jobs.enqueue_account_reconciliation(pool, assignment, trigger_kind: "scheduled")

      assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :jobs)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.errors == []

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert assignment.metadata["last_reconciliation"]["status"] == "succeeded"

      [window] = QuotaWindows.list_quota_windows(identity)
      assert window.observed_at == observed_at

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
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

    test "decoded auth rejection followed by weekly-only success fails closed" do
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
      assert result.identity.status == "reauth_required"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) ==
               Enum.take(paths, 2)
    end

    test "weekly-only success followed by decoded auth rejection fails closed" do
      paths = [
        "/api/codex/usage",
        "/backend-api/codex/usage",
        "/backend-api/wham/usage"
      ]

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {200, weekly_usage_payload()},
             "/backend-api/codex/usage" => {403, %{"error" => "rejected"}},
             "/backend-api/wham/usage" => {404, %{}}
           }}
        )

      {pool, assignment} =
        active_usage_probe_assignment(upstream, %{
          "saved_resets" => %{"usage_path" => "/api/codex/usage"}
        })

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.identity.status == "reauth_required"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) ==
               Enum.take(paths, 2)
    end

    test "weekly-only success cannot mask decoded 401 when token refresh is due" do
      paths = [
        "/api/codex/usage",
        "/backend-api/codex/usage",
        "/backend-api/wham/usage"
      ]

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/api/codex/usage" => {200, weekly_usage_payload()},
             "/backend-api/codex/usage" => {401, %{"error" => "rejected"}},
             "/backend-api/wham/usage" => {404, %{}}
           }}
        )

      {_pool, assignment} =
        active_assignment_fixture(
          %{
            "base_url" => FakeUpstream.url(upstream),
            "saved_resets" => %{"usage_path" => "/api/codex/usage"}
          },
          identity_metadata: %{
            "base_url" => FakeUpstream.url(upstream),
            "access_token_expires_at" =>
              DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()
          }
        )

      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:error, {:upstream_status, 401}} =
               UsageProbe.fetch(
                 identity,
                 assignment,
                 "synthetic-access-token",
                 DateTime.utc_now(),
                 []
               )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) ==
               Enum.take(paths, 2)
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
      assert transport_result.quota.code == "quota_refresh_unavailable"

      assert transport_result.quota.message ==
               "quota windows were not available (econnrefused)"

      transport_assignment = Repo.reload!(transport_assignment)

      assert [%{"message" => "quota windows were not available (econnrefused)"}] =
               Enum.filter(
                 transport_assignment.metadata["last_reconciliation"]["steps"],
                 &(&1["code"] == "quota_refresh_unavailable")
               )
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

    test "older persisted quota fallback cannot reactivate an assignment after a newer auth rejection" do
      fallback_release_ref = make_ref()
      rejection_release_ref = make_ref()

      fallback_upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(%{"error" => "busy"},
            status: 429,
            notify: self(),
            release_ref: fallback_release_ref
          )
        )

      rejection_upstream =
        start_upstream(rejection_barrier_paths(self(), rejection_release_ref))

      {fallback_pool, fallback_assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(fallback_upstream)},
          identity_metadata: fresh_access_token_metadata(FakeUpstream.url(fallback_upstream))
        )

      identity = Upstreams.get_upstream_identity(fallback_assignment.upstream_identity_id)
      rejection_pool = pool_fixture()

      assert {:ok, rejection_assignment} =
               PoolAssignments.create_pool_assignment(rejection_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible",
                 metadata: %{"base_url" => FakeUpstream.url(rejection_upstream)}
               })

      persist_quota_windows!(identity, [
        persisted_account_primary_window_attrs(DateTime.utc_now())
      ])

      fallback_task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(fallback_pool, fallback_assignment)
        end)

      fallback_barrier = await_upstream_barrier(fallback_release_ref)

      rejection_task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(rejection_pool, rejection_assignment)
        end)

      rejection_first_barrier = await_upstream_barrier(rejection_release_ref)
      release_upstream_barrier(rejection_first_barrier, rejection_release_ref)
      rejection_second_barrier = await_upstream_barrier(rejection_release_ref)
      release_upstream_barrier(rejection_second_barrier, rejection_release_ref)

      assert {:ok, rejection_result} = Task.await(rejection_task)
      assert rejection_result.identity.status == "reauth_required"

      release_upstream_barrier(fallback_barrier, fallback_release_ref)
      second_fallback_barrier = await_upstream_barrier(fallback_release_ref)
      release_upstream_barrier(second_fallback_barrier, fallback_release_ref)
      assert {:ok, fallback_result} = Task.await(fallback_task)
      assert fallback_result.quota.code == "quota_refresh_superseded"

      current_identity = Repo.get!(UpstreamIdentity, identity.id)
      current_assignment = Repo.get!(PoolUpstreamAssignment, fallback_assignment.id)
      assert current_identity.status == "reauth_required"
      assert current_assignment.health_status == "disabled"
      assert current_assignment.eligibility_status == "ineligible"
    end

    test "older unavailable probe cannot reactivate an assignment after a newer auth rejection" do
      unavailable_release_ref = make_ref()
      rejection_release_ref = make_ref()

      unavailable_upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(%{"error" => "busy"},
            status: 429,
            notify: self(),
            release_ref: unavailable_release_ref
          )
        )

      rejection_upstream =
        start_upstream(rejection_barrier_paths(self(), rejection_release_ref))

      {unavailable_pool, unavailable_assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(unavailable_upstream)},
          identity_metadata: fresh_access_token_metadata(FakeUpstream.url(unavailable_upstream))
        )

      identity = Upstreams.get_upstream_identity(unavailable_assignment.upstream_identity_id)
      rejection_pool = pool_fixture()

      assert {:ok, rejection_assignment} =
               PoolAssignments.create_pool_assignment(rejection_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible",
                 metadata: %{"base_url" => FakeUpstream.url(rejection_upstream)}
               })

      unavailable_task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(unavailable_pool, unavailable_assignment)
        end)

      unavailable_barrier = await_upstream_barrier(unavailable_release_ref)

      rejection_task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(rejection_pool, rejection_assignment)
        end)

      rejection_first_barrier = await_upstream_barrier(rejection_release_ref)
      release_upstream_barrier(rejection_first_barrier, rejection_release_ref)
      rejection_second_barrier = await_upstream_barrier(rejection_release_ref)
      release_upstream_barrier(rejection_second_barrier, rejection_release_ref)

      assert {:ok, rejection_result} = Task.await(rejection_task)
      assert rejection_result.identity.status == "reauth_required"

      release_upstream_barrier(unavailable_barrier, unavailable_release_ref)
      second_unavailable_barrier = await_upstream_barrier(unavailable_release_ref)
      release_upstream_barrier(second_unavailable_barrier, unavailable_release_ref)
      assert {:ok, unavailable_result} = Task.await(unavailable_task)
      assert unavailable_result.quota.code == "quota_refresh_superseded"

      current_identity = Repo.get!(UpstreamIdentity, identity.id)
      current_assignment = Repo.get!(PoolUpstreamAssignment, unavailable_assignment.id)
      assert current_identity.status == "reauth_required"
      assert current_identity.metadata["usage_probe_applied_sequence"] == 2
      assert current_assignment.health_status == "disabled"
      assert current_assignment.eligibility_status == "ineligible"
    end

    test "newer unavailable completion cannot suppress an older definitive auth rejection" do
      rejection_release_ref = make_ref()

      rejection_upstream =
        start_upstream(rejection_barrier_paths(self(), rejection_release_ref))

      unavailable_upstream =
        start_upstream(FakeUpstream.json_response(%{"error" => "busy"}, 429))

      {rejection_pool, rejection_assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(rejection_upstream)},
          identity_metadata: fresh_access_token_metadata(FakeUpstream.url(rejection_upstream))
        )

      identity = Upstreams.get_upstream_identity(rejection_assignment.upstream_identity_id)
      unavailable_pool = pool_fixture()

      assert {:ok, unavailable_assignment} =
               PoolAssignments.create_pool_assignment(unavailable_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible",
                 metadata: %{"base_url" => FakeUpstream.url(unavailable_upstream)}
               })

      rejection_task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(rejection_pool, rejection_assignment)
        end)

      rejection_first_barrier = await_upstream_barrier(rejection_release_ref)

      assert {:ok, unavailable_result} =
               Upstreams.reconcile_pool_account(unavailable_pool, unavailable_assignment)

      assert unavailable_result.quota.code == "quota_refresh_unavailable"

      release_upstream_barrier(rejection_first_barrier, rejection_release_ref)
      rejection_second_barrier = await_upstream_barrier(rejection_release_ref)
      release_upstream_barrier(rejection_second_barrier, rejection_release_ref)

      assert {:ok, rejection_result} = Task.await(rejection_task)
      assert rejection_result.quota.code == "quota_refresh_auth_unavailable"

      current_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert current_identity.status == "reauth_required"
      assert current_identity.metadata["usage_probe_applied_sequence"] == 1
      assert current_identity.metadata["usage_probe_completed_sequence"] == 2

      for assignment <- [rejection_assignment, unavailable_assignment] do
        current_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
        assert current_assignment.health_status == "disabled"
        assert current_assignment.eligibility_status == "ineligible"
      end
    end

    test "unavailable probe cannot mutate an assignment disabled while the request is in flight" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(%{"error" => "busy"},
            status: 429,
            notify: self(),
            release_ref: release_ref
          )
        )

      {pool, assignment} = active_usage_probe_assignment(upstream)

      task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(pool, assignment)
        end)

      barrier = await_upstream_barrier(release_ref)
      assert {:ok, disabled_assignment} = PoolAssignments.disable_pool_assignment(assignment)
      disabled_before = Repo.get!(PoolUpstreamAssignment, disabled_assignment.id)

      release_upstream_barrier(barrier, release_ref)
      second_barrier = await_upstream_barrier(release_ref)
      release_upstream_barrier(second_barrier, release_ref)
      assert {:ok, result} = Task.await(task)
      assert result.quota.code == "quota_refresh_superseded"
      assert Repo.get!(PoolUpstreamAssignment, assignment.id) == disabled_before
    end

    test "unavailable probe cannot mutate an assignment deleted while the request is in flight" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(%{"error" => "busy"},
            status: 429,
            notify: self(),
            release_ref: release_ref
          )
        )

      {pool, assignment} = active_usage_probe_assignment(upstream)
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)
      sibling_pool = pool_fixture()

      assert {:ok, _sibling_assignment} =
               PoolAssignments.create_pool_assignment(sibling_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible"
               })

      task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(pool, assignment)
        end)

      barrier = await_upstream_barrier(release_ref)

      assert {:ok, %{assignment: deleted_assignment}} =
               PoolAssignments.delete_pool_assignment(pool, assignment)

      deleted_before = Repo.get!(PoolUpstreamAssignment, deleted_assignment.id)

      release_upstream_barrier(barrier, release_ref)
      second_barrier = await_upstream_barrier(release_ref)
      release_upstream_barrier(second_barrier, release_ref)
      assert {:ok, result} = Task.await(task)
      assert result.quota.code == "quota_refresh_superseded"
      assert Repo.get!(PoolUpstreamAssignment, assignment.id) == deleted_before
    end

    test "failing reconciliation cannot write priming after an independent disable" do
      release_ref = make_ref()
      parent = self()

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" =>
               FakeUpstream.barrier_json_response(%{"error" => "busy"},
                 status: 429,
                 notify: self(),
                 release_ref: release_ref
               ),
             "/api/codex/usage" => {429, %{"error" => "busy"}},
             "/backend-api/codex/usage" => {429, %{"error" => "busy"}},
             "/wham/usage" => {429, %{"error" => "busy"}}
           }}
        )

      {pool, assignment} = committed_active_usage_probe_assignment(upstream)

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:failing_reconciliation_connection, release_ref, backend_pid})
            AccountReconciliation.run(pool.id, assignment.id, "scheduled")
          end)
        end)

      assert_receive {:failing_reconciliation_connection, ^release_ref, reconciliation_backend}
      first_barrier = await_upstream_barrier(release_ref)

      {lifecycle_backend, disabled_before} =
        Sandbox.unboxed_run(Repo, fn ->
          backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
          assert {:ok, disabled_assignment} = PoolAssignments.disable_pool_assignment(assignment)
          {backend_pid, Repo.reload!(disabled_assignment)}
        end)

      assert lifecycle_backend != reconciliation_backend
      release_upstream_barrier(first_barrier, release_ref)

      assert {:ok, _result} = Task.await(reconciliation, 10_000)

      current_assignment =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.get!(PoolUpstreamAssignment, assignment.id)
        end)

      assert current_assignment == disabled_before
    end

    test "priming events are published only after the fencing transaction commits" do
      {pool, _identity, assignment} = committed_metadata_reconciliation_fixture()
      release_ref = make_ref()
      parent = self()
      handler_id = {__MODULE__, :priming_commit, release_ref}

      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          &__MODULE__.handle_blocking_terminal_priming_update_event/4,
          {handler_id, parent, release_ref}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            AccountReconciliation.run(pool.id, assignment.id, "scheduled")
          end)
        end)

      assert_receive {Events,
                      %{
                        reason: "quota_priming_updated",
                        payload: %{
                          "assignment_id" => assignment_id,
                          "quota_priming_status" => "refreshing"
                        }
                      }}

      assert assignment_id == assignment.id

      assert_receive {:terminal_priming_update_before_commit, ^release_ref, query_pid}

      refute_receive {Events,
                      %{
                        reason: "quota_priming_updated",
                        payload: %{"quota_priming_status" => "known"}
                      }},
                     100

      persisted_before_commit =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert persisted_before_commit.metadata["quota_priming"]["status"] == "refreshing"
      assert persisted_before_commit.metadata["quota_priming"]["credential_epoch"] == 1

      send(query_pid, {:release_assignment_update, release_ref})
      assert {:ok, _result} = Task.await(reconciliation)

      assert_receive {Events,
                      %{
                        reason: "quota_priming_updated",
                        payload: %{
                          "assignment_id" => ^assignment_id,
                          "quota_priming_status" => "known"
                        }
                      }}

      persisted_after_commit =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert persisted_after_commit.metadata["quota_priming"]["status"] == "known"

      refute_receive {Events,
                      %{
                        reason: "quota_priming_updated",
                        payload: %{"quota_priming_status" => "known"}
                      }},
                     100
    end

    test "rolled back terminal priming publishes no event" do
      {pool, assignment} =
        active_assignment_fixture(%{
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 300,
              "active_limit" => 100,
              "credits" => 75,
              "reset_at" =>
                DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601(),
              "source" => "local_reconciliation",
              "freshness_state" => "fresh"
            }
          ]
        })

      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      assert {:error, :forced_rollback} =
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()

                 assert {:ok, %{status: :succeeded}} =
                          AccountReconciliation.run(pool.id, assignment.id, "scheduled")

                 refute_receive {Events,
                                 %{
                                   reason: "quota_priming_updated",
                                   payload: %{"quota_priming_status" => "known"}
                                 }}

                 Repo.rollback(:forced_rollback)
               end)

      refute_receive {Events,
                      %{
                        reason: "quota_priming_updated",
                        payload: %{"quota_priming_status" => "known"}
                      }}

      current_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert is_nil(current_assignment.metadata["quota_priming"])
      assert is_nil(current_assignment.metadata["last_reconciliation"])
    end

    test "terminal priming committed first cannot be overwritten by stale cleanup" do
      {pool, _identity, assignment} = committed_stale_priming_fixture()
      release_ref = make_ref()
      parent = self()
      handler_id = {__MODULE__, :terminal_before_cleanup, release_ref}

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          &__MODULE__.handle_blocking_terminal_priming_update_event/4,
          {handler_id, parent, release_ref}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            AccountReconciliation.run(pool.id, assignment.id, "scheduled")
          end)
        end)

      assert_receive {:terminal_priming_update_before_commit, ^release_ref, query_pid}

      cleanup =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:stale_cleanup_connection_ready, release_ref, backend_pid})

            AccountReconciliation.cleanup_stale_state(DateTime.add(DateTime.utc_now(), 2, :hour))
          end)
        end)

      assert_receive {:stale_cleanup_connection_ready, ^release_ref, cleanup_backend}
      assert_backend_waiting_on_db_lock!(cleanup_backend)

      send(query_pid, {:release_assignment_update, release_ref})

      assert {:ok, %{status: :succeeded}} = Task.await(reconciliation)

      assert {:ok, %{stale_account_reconciliations_failed: 0}} =
               Task.await(cleanup)

      current_assignment =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert current_assignment.metadata["quota_priming"]["status"] == "known"
    end

    test "stale cleanup committed first cannot overwrite later terminal priming" do
      {pool, _identity, assignment} = committed_stale_priming_fixture()
      release_ref = make_ref()
      parent = self()
      handler_id = {__MODULE__, :cleanup_before_terminal, release_ref}

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          &__MODULE__.handle_blocking_stale_priming_update_event/4,
          {handler_id, parent, release_ref}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      cleanup =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            AccountReconciliation.cleanup_stale_state(DateTime.utc_now())
          end)
        end)

      assert_receive {:stale_priming_update_before_commit, ^release_ref, query_pid}

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:terminal_reconciliation_connection_ready, release_ref, backend_pid})
            AccountReconciliation.run(pool.id, assignment.id, "scheduled")
          end)
        end)

      assert_receive {:terminal_reconciliation_connection_ready, ^release_ref,
                      reconciliation_backend}

      assert_backend_waiting_on_db_lock!(reconciliation_backend)

      send(query_pid, {:release_assignment_update, release_ref})

      assert {:ok, %{stale_account_reconciliations_failed: 1}} = Task.await(cleanup)
      assert {:ok, %{status: :succeeded}} = Task.await(reconciliation)

      current_assignment =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert current_assignment.metadata["quota_priming"]["status"] == "known"
    end

    test "stale cleanup does not mutate a disabled assignment" do
      {_pool, _identity, assignment} = committed_stale_priming_fixture()

      disabled_assignment =
        Sandbox.unboxed_run(Repo, fn ->
          assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
          assert {:ok, disabled_assignment} = PoolAssignments.disable_pool_assignment(assignment)
          disabled_assignment
        end)

      assert {:ok, %{stale_account_reconciliations_failed: 0}} =
               Sandbox.unboxed_run(Repo, fn ->
                 AccountReconciliation.cleanup_stale_state(DateTime.utc_now())
               end)

      current_assignment =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert current_assignment.status == "disabled"

      assert current_assignment.metadata["quota_priming"] ==
               disabled_assignment.metadata["quota_priming"]
    end

    test "stale cleanup does not mutate a deleted assignment with a live sibling" do
      {pool, identity, assignment} = committed_stale_priming_fixture()

      {sibling_pool, sibling_assignment} =
        Sandbox.unboxed_run(Repo, fn ->
          sibling_pool = pool_fixture()

          assert {:ok, sibling_assignment} =
                   PoolAssignments.create_pool_assignment(sibling_pool, identity, %{
                     assignment_label: "Committed cleanup sibling"
                   })

          assert {:ok, sibling_assignment} =
                   PoolAssignments.activate_pool_assignment(sibling_assignment, %{
                     skip_quota_priming: true
                   })

          {sibling_pool, sibling_assignment}
        end)

      on_exit(fn -> cleanup_committed_pool(sibling_pool.id) end)

      deleted_assignment =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, %{assignment: deleted_assignment}} =
                   PoolAssignments.delete_pool_assignment(pool, assignment)

          deleted_assignment
        end)

      assert {:ok, %{stale_account_reconciliations_failed: 0}} =
               Sandbox.unboxed_run(Repo, fn ->
                 AccountReconciliation.cleanup_stale_state(DateTime.utc_now())
               end)

      {current_assignment, current_sibling} =
        Sandbox.unboxed_run(Repo, fn ->
          {
            Repo.get!(PoolUpstreamAssignment, assignment.id),
            Repo.get!(PoolUpstreamAssignment, sibling_assignment.id)
          }
        end)

      assert current_assignment.status == "deleted"

      assert current_assignment.metadata["quota_priming"] ==
               deleted_assignment.metadata["quota_priming"]

      assert current_sibling.status == "active"
    end

    test "stale cleanup rejects priming from before pause and reactivation" do
      {scope, _pool, identity, assignment} = committed_scoped_lifecycle_fixture()
      assignment = mark_committed_assignment_stale!(assignment, 1)

      reactivated_identity =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, %{status: :paused}} =
                   Upstreams.pause_account_for_scope(scope, identity.id, %{
                     reason: "operator_pause"
                   })

          assert {:ok, %{status: :active, identity: reactivated_identity}} =
                   Upstreams.reactivate_account_for_scope(scope, identity.id, %{})

          reactivated_identity
        end)

      assert CredentialFencing.credential_epoch(reactivated_identity) == 3

      assert {:ok, %{stale_account_reconciliations_failed: 0}} =
               Sandbox.unboxed_run(Repo, fn ->
                 AccountReconciliation.cleanup_stale_state(DateTime.utc_now())
               end)

      current_assignment =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert current_assignment.status == "active"
      assert current_assignment.metadata["quota_priming"]["status"] == "refreshing"
      assert current_assignment.metadata["quota_priming"]["credential_epoch"] == 1
    end

    test "metadata quota read before an epoch change is superseded on another connection" do
      {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
      release_ref = make_ref()
      parent = self()

      epoch_change =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
              locked_identity = CredentialFencing.lock_credential_replacement(identity.id)

              epoch_two = CredentialFencing.advance_credential_epoch(locked_identity)

              epoch_three =
                CredentialFencing.advance_credential_epoch(%{
                  locked_identity
                  | metadata: epoch_two
                })

              locked_identity
              |> UpstreamIdentity.changeset(%{metadata: epoch_three})
              |> Repo.update!()

              send(parent, {:epoch_change_before_commit, release_ref, backend_pid})

              receive do
                {:release_epoch_change, ^release_ref} -> :ok
              end
            end)
          end)
        end)

      assert_receive {:epoch_change_before_commit, ^release_ref, epoch_backend}

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:metadata_reconciliation_ready, release_ref, backend_pid})
            Upstreams.reconcile_pool_account(pool, assignment)
          end)
        end)

      assert_receive {:metadata_reconciliation_ready, ^release_ref, reconciliation_backend}
      assert reconciliation_backend != epoch_backend
      assert_backend_waiting_on_db_lock!(reconciliation_backend)

      send(epoch_change.pid, {:release_epoch_change, release_ref})
      assert {:ok, :ok} = Task.await(epoch_change)

      assert {:ok, result} = Task.await(reconciliation)
      assert result.quota.code == "quota_refresh_superseded"

      {current_identity, windows} =
        Sandbox.unboxed_run(Repo, fn ->
          {
            Repo.get!(UpstreamIdentity, identity.id),
            QuotaWindows.list_quota_windows(identity)
          }
        end)

      assert CredentialFencing.credential_epoch(current_identity) == 3
      assert windows == []
    end

    test "unfenced quota event is published after commit with persisted state visible" do
      {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Upstreams.reconcile_pool_account(pool, assignment)
          end)
        end)

      assert {:ok, %{quota: %{code: "quota_refreshed"}}} = Task.await(reconciliation)

      assert_receive {Events,
                      %{
                        reason: "upstream_quota_windows_updated",
                        payload: %{"assignment_id" => assignment_id}
                      }}

      assert assignment_id == assignment.id

      assert [_window] =
               Sandbox.unboxed_run(Repo, fn -> QuotaWindows.list_quota_windows(identity) end)

      refute_receive {Events, %{reason: "upstream_quota_windows_updated"}}, 100
    end

    test "rolled back unfenced quota write publishes no local event" do
      {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, %{quota: %{code: "quota_refreshed"}}} =
                       Upstreams.reconcile_pool_account(pool, assignment)

              Repo.rollback(:forced_rollback)
            end)
          end)
        end)

      assert {:error, :forced_rollback} = Task.await(reconciliation)

      refute_receive {Events, %{reason: "upstream_quota_windows_updated"}}, 100

      assert [] = Sandbox.unboxed_run(Repo, fn -> QuotaWindows.list_quota_windows(identity) end)
    end

    test "unfenced quota event waits for an enclosing transaction commit" do
      {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      parent = self()
      release_ref = make_ref()

      commit =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              result = Upstreams.reconcile_pool_account(pool, assignment)
              send(parent, {:unfenced_outer_transaction_ready, release_ref, self(), result})

              receive do
                {:commit_unfenced_outer_transaction, ^release_ref} -> result
              end
            end)
          end)
        end)

      assert_receive {:unfenced_outer_transaction_ready, ^release_ref, transaction_pid,
                      {:ok, %{quota: %{code: "quota_refreshed"}}}}

      refute_received {Events, %{reason: "upstream_quota_windows_updated"}}
      send(transaction_pid, {:commit_unfenced_outer_transaction, release_ref})

      assert {:ok, {:ok, %{quota: %{code: "quota_refreshed"}}}} = Task.await(commit)

      assert_receive {Events,
                      %{
                        reason: "upstream_quota_windows_updated",
                        payload: %{"upstream_identity_id" => identity_id}
                      }}

      assert identity_id == identity.id
      refute_receive {Events, %{reason: "upstream_quota_windows_updated"}}, 100

      assert [_window] =
               Sandbox.unboxed_run(Repo, fn -> QuotaWindows.list_quota_windows(identity) end)
    end

    test "priming events wait for an enclosing account reconciliation commit" do
      {pool, _identity, assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      parent = self()
      release_ref = make_ref()

      commit =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              result = AccountReconciliation.run(pool.id, assignment.id, "scheduled")
              send(parent, {:account_outer_transaction_ready, release_ref, self(), result})

              receive do
                {:commit_account_outer_transaction, ^release_ref} -> result
              end
            end)
          end)
        end)

      assert_receive {:account_outer_transaction_ready, ^release_ref, transaction_pid,
                      {:ok, %{quota: %{code: "quota_refreshed"}}}}

      refute_received {Events, _event}
      send(transaction_pid, {:commit_account_outer_transaction, release_ref})
      assert {:ok, {:ok, %{quota: %{code: "quota_refreshed"}}}} = Task.await(commit)

      assert_receive {Events,
                      %{
                        reason: "quota_priming_updated",
                        payload: %{"quota_priming_status" => "refreshing"}
                      }}

      assert_receive {Events, %{reason: "upstream_quota_windows_updated"}}

      assert_receive {Events,
                      %{
                        reason: "quota_priming_updated",
                        payload: %{"quota_priming_status" => "known"}
                      }}

      refute_receive {Events, _event}, 100
    end

    test "priming events and state are discarded with an enclosing rollback" do
      {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      rollback =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, %{quota: %{code: "quota_refreshed"}}} =
                       AccountReconciliation.run(pool.id, assignment.id, "scheduled")

              Repo.rollback(:forced_outer_rollback)
            end)
          end)
        end)

      assert {:error, :forced_outer_rollback} = Task.await(rollback)
      refute_receive {Events, _event}, 100

      {current_assignment, windows} =
        Sandbox.unboxed_run(Repo, fn ->
          {
            Repo.get!(PoolUpstreamAssignment, assignment.id),
            QuotaWindows.list_quota_windows(identity)
          }
        end)

      assert is_nil(current_assignment.metadata["quota_priming"])
      assert is_nil(current_assignment.metadata["last_reconciliation"])
      assert windows == []
    end

    test "fenced quota event waits for an enclosing transaction commit" do
      {pool, identity, _assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      fence =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity)
          fence
        end)

      parent = self()
      release_ref = make_ref()

      commit =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, :applied, _identity, :persisted} =
                       CredentialFencing.apply_usage_success(
                         identity,
                         fence,
                         fn _locked_identity ->
                           {:ok, :persisted}
                         end
                       )

              send(parent, {:fenced_outer_transaction_ready, release_ref, self()})

              receive do
                {:commit_fenced_outer_transaction, ^release_ref} -> :ok
              end
            end)
          end)
        end)

      assert_receive {:fenced_outer_transaction_ready, ^release_ref, transaction_pid}
      refute_received {Events, %{reason: "upstream_quota_windows_updated"}}

      send(transaction_pid, {:commit_fenced_outer_transaction, release_ref})
      assert {:ok, :ok} = Task.await(commit)

      assert_receive {Events,
                      %{
                        reason: "upstream_quota_windows_updated",
                        payload: %{"upstream_identity_id" => identity_id}
                      }}

      assert identity_id == identity.id
      refute_receive {Events, %{reason: "upstream_quota_windows_updated"}}, 100
    end

    test "fenced quota event is discarded with an enclosing transaction rollback" do
      {pool, identity, _assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      fence =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity)
          fence
        end)

      rollback =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, :applied, _identity, :persisted} =
                       CredentialFencing.apply_usage_success(
                         identity,
                         fence,
                         fn _locked_identity -> {:ok, :persisted} end
                       )

              Repo.rollback(:forced_outer_rollback)
            end)
          end)
        end)

      assert {:error, :forced_outer_rollback} = Task.await(rollback)

      refute_receive {Events, %{reason: "upstream_quota_windows_updated"}}, 100

      current_identity =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(UpstreamIdentity, identity.id) end)

      assert current_identity.metadata["usage_probe_applied_sequence"] == 0
      assert current_identity.metadata["usage_probe_completed_sequence"] == 0
    end

    test "explicit quota terminal state is superseded after pause and reactivation" do
      {scope, pool, identity, assignment} = committed_scoped_lifecycle_fixture()
      release_ref = make_ref()
      parent = self()
      handler_id = {__MODULE__, :explicit_quota_terminal_epoch, release_ref}

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          &__MODULE__.handle_blocking_quota_notify_event/4,
          {handler_id, parent, release_ref}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Upstreams.reconcile_pool_account(pool, assignment,
              quota_windows: assignment.metadata["quota_windows"]
            )
          end)
        end)

      assert_receive {:quota_notify_before_return, ^release_ref, query_pid}

      reactivated_identity =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, %{status: :paused}} =
                   Upstreams.pause_account_for_scope(scope, identity.id, %{
                     reason: "operator_pause"
                   })

          assert {:ok, %{status: :active, identity: reactivated_identity}} =
                   Upstreams.reactivate_account_for_scope(scope, identity.id, %{})

          reactivated_identity
        end)

      assert CredentialFencing.credential_epoch(reactivated_identity) == 3
      send(query_pid, {:release_quota_notify, release_ref})

      assert {:ok, result} = Task.await(reconciliation)
      assert result.quota.code == "quota_refresh_superseded"

      current_assignment =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert is_nil(current_assignment.metadata["last_reconciliation"])
      assert is_nil(current_assignment.last_successful_refresh_at)
    end

    test "pause and reactivation invalidate a probe allocated on another connection" do
      {scope, _pool, identity, assignment} = committed_scoped_lifecycle_fixture()
      release_ref = make_ref()
      parent = self()

      allocator =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            assert {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity.id)
            send(parent, {:pre_pause_probe_allocated, release_ref, backend_pid, fence})

            receive do
              {:release_probe_connection, ^release_ref} -> {backend_pid, fence}
            end
          end)
        end)

      assert_receive {:pre_pause_probe_allocated, ^release_ref, probe_backend, fence}

      {lifecycle_backend, reactivated_identity} =
        Sandbox.unboxed_run(Repo, fn ->
          backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

          assert {:ok, %{status: :paused}} =
                   Upstreams.pause_account_for_scope(scope, identity.id, %{
                     reason: "operator_pause"
                   })

          assert {:ok, %{status: :active, identity: reactivated_identity}} =
                   Upstreams.reactivate_account_for_scope(scope, identity.id, %{})

          {backend_pid, reactivated_identity}
        end)

      assert lifecycle_backend != probe_backend
      assert CredentialFencing.credential_epoch(reactivated_identity) > fence.credential_epoch

      send(allocator.pid, {:release_probe_connection, release_ref})
      assert {^probe_backend, ^fence} = Task.await(allocator)

      stale_apply_result =
        Sandbox.unboxed_run(Repo, fn ->
          CredentialFencing.apply_usage_success(identity.id, fence, fn _locked_identity ->
            current_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)

            current_assignment
            |> PoolUpstreamAssignment.changeset(%{
              metadata: Map.put(current_assignment.metadata || %{}, "stale_probe_applied", true)
            })
            |> Repo.update()
          end)
        end)

      assert {:ok, :superseded, _identity, nil} = stale_apply_result

      current_assignment =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      refute current_assignment.metadata["stale_probe_applied"]
      assert current_assignment.status == "active"
      assert current_assignment.eligibility_status == "eligible"
    end

    test "account terminal state is superseded after metadata quota and a later epoch change" do
      catalog_release_ref = make_ref()

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/codex/models" =>
               FakeUpstream.barrier_json_response(%{"models" => []},
                 notify: self(),
                 release_ref: catalog_release_ref
               )
           }}
        )

      {scope, pool, identity, assignment} = committed_scoped_lifecycle_fixture()

      assignment =
        Sandbox.unboxed_run(Repo, fn ->
          assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)

          assignment
          |> PoolUpstreamAssignment.changeset(%{
            metadata: Map.put(assignment.metadata, "base_url", FakeUpstream.url(upstream))
          })
          |> Repo.update!()
        end)

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            AccountReconciliation.run(pool.id, assignment.id, "manual")
          end)
        end)

      catalog_barrier = await_upstream_barrier(catalog_release_ref)

      reactivated_identity =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, %{status: :paused}} =
                   Upstreams.pause_account_for_scope(scope, identity.id, %{
                     reason: "operator_pause"
                   })

          assert {:ok, %{status: :active, identity: reactivated_identity}} =
                   Upstreams.reactivate_account_for_scope(scope, identity.id, %{})

          reactivated_identity
        end)

      assert CredentialFencing.credential_epoch(reactivated_identity) == 3
      release_upstream_barrier(catalog_barrier, catalog_release_ref)

      assert {:ok, result} = Task.await(reconciliation)
      assert result.quota.code == "quota_refresh_superseded"

      current_assignment =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(PoolUpstreamAssignment, assignment.id) end)

      assert current_assignment.metadata["quota_priming"]["status"] == "refreshing"
      assert current_assignment.metadata["quota_priming"]["credential_epoch"] == 1
      assert is_nil(current_assignment.metadata["last_reconciliation"])
      assert is_nil(current_assignment.last_successful_refresh_at)
    end

    for lifecycle_action <- [:disable, :delete] do
      test "metadata reconciliation cannot mutate an assignment when #{lifecycle_action} commits first on independent connections" do
        lifecycle_action = unquote(lifecycle_action)
        {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
        release_ref = make_ref()
        parent = self()

        identity_lock =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                Repo.one!(
                  from(current_identity in UpstreamIdentity,
                    where: current_identity.id == ^identity.id,
                    lock: "FOR UPDATE"
                  )
                )

                send(parent, {:identity_lock_acquired, release_ref})

                receive do
                  ^release_ref -> :ok
                end
              end)
            end)
          end)

        assert_receive {:identity_lock_acquired, ^release_ref}

        reconciliation =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
              send(parent, {:reconciliation_connection_ready, release_ref, backend_pid})
              Upstreams.reconcile_pool_account(pool, assignment)
            end)
          end)

        assert_receive {:reconciliation_connection_ready, ^release_ref, reconciliation_backend}
        assert_backend_waiting_on_db_lock!(reconciliation_backend)

        lifecycle_snapshot =
          Sandbox.unboxed_run(Repo, fn ->
            apply_assignment_lifecycle!(lifecycle_action, pool, assignment)
          end)

        send(identity_lock.pid, release_ref)
        assert {:ok, :ok} = Task.await(identity_lock)

        assert {:ok, stale_result} = Task.await(reconciliation)
        assert stale_result.quota.code == "quota_refresh_superseded"

        {current_assignment, windows} =
          Sandbox.unboxed_run(Repo, fn ->
            {
              Repo.get!(PoolUpstreamAssignment, assignment.id),
              QuotaWindows.list_quota_windows(identity)
            }
          end)

        assert current_assignment == lifecycle_snapshot
        assert windows == []
      end
    end

    test "metadata reconciliation commits before a later disable on independent connections" do
      {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
      release_ref = make_ref()
      parent = self()
      handler_id = {__MODULE__, :production_reconciliation_lock, release_ref}

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          &__MODULE__.handle_blocking_assignment_update_event/4,
          {handler_id, parent, release_ref}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      reconciliation =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Upstreams.reconcile_pool_account(pool, assignment)
          end)
        end)

      assert_receive {:assignment_update_before_commit, ^release_ref, reconciliation_pid}

      lifecycle =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:lifecycle_connection_ready, release_ref, backend_pid})
            PoolAssignments.disable_pool_assignment(assignment)
          end)
        end)

      assert_receive {:lifecycle_connection_ready, ^release_ref, lifecycle_backend}
      assert_backend_waiting_on_db_lock!(lifecycle_backend)

      send(reconciliation_pid, {:release_assignment_update, release_ref})

      assert {:ok, reconciliation_result} = Task.await(reconciliation)
      assert reconciliation_result.quota.code == "quota_refreshed"
      assert {:ok, disabled_assignment} = Task.await(lifecycle)

      {current_assignment, windows} =
        Sandbox.unboxed_run(Repo, fn ->
          {
            Repo.get!(PoolUpstreamAssignment, assignment.id),
            QuotaWindows.list_quota_windows(identity)
          }
        end)

      assert current_assignment.status == "disabled"
      assert current_assignment.health_status == "disabled"
      assert current_assignment.eligibility_status == "ineligible"
      assert current_assignment.disabled_at == disabled_assignment.disabled_at
      assert [_persisted_window] = windows
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

    test "definitive rejection event is discarded with an enclosing transaction rollback" do
      {pool, identity, _assignment} = committed_metadata_reconciliation_fixture()
      assert :ok = Events.subscribe_pool(pool.id, "upstreams")

      fence =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity)
          fence
        end)

      rollback =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, :applied, rejected_identity} =
                       CredentialFencing.mark_definitive_rejection(identity, fence)

              assert rejected_identity.status == "reauth_required"
              Repo.rollback(:forced_outer_rollback)
            end)
          end)
        end)

      assert {:error, :forced_outer_rollback} = Task.await(rollback)
      refute_receive {Events, %{reason: "upstream_account_reauth_required"}}, 100

      current_identity =
        Sandbox.unboxed_run(Repo, fn -> Repo.get!(UpstreamIdentity, identity.id) end)

      assert current_identity.status == "active"
      assert current_identity.metadata["usage_probe_applied_sequence"] == 0
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

    test "guarded unavailable completion does not suppress an older rejection" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, _identity, older_fence} = CredentialFencing.allocate_usage_probe(identity)
      assert {:ok, _identity, newer_fence} = CredentialFencing.allocate_usage_probe(identity)

      assert {:ok, :applied, current_identity, :completed} =
               CredentialFencing.guard_active_usage_probe_completion(
                 identity,
                 newer_fence,
                 :auth_failure,
                 fn _locked_identity -> {:ok, :completed} end
               )

      assert current_identity.metadata["usage_probe_applied_sequence"] == 0
      assert current_identity.metadata["usage_probe_completed_sequence"] == 2

      assert {:ok, :applied, rejected_identity} =
               CredentialFencing.mark_definitive_rejection(identity, older_fence)

      assert rejected_identity.status == "reauth_required"
      assert rejected_identity.metadata["usage_probe_applied_sequence"] == 1
      assert rejected_identity.metadata["usage_probe_completed_sequence"] == 2

      test_pid = self()

      assert {:ok, :superseded, still_rejected_identity, nil} =
               CredentialFencing.guard_current_usage_probe_completion(
                 identity,
                 newer_fence,
                 :auth_failure,
                 fn _locked_identity ->
                   send(test_pid, :stale_terminal_callback_ran)
                   {:ok, :stale_terminal_write}
                 end
               )

      assert still_rejected_identity.status == "reauth_required"
      refute_received :stale_terminal_callback_ran
    end

    test "newer unavailable pool completion cannot run after an older rejection applies" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, _identity, rejection_fence} =
               CredentialFencing.allocate_usage_probe(identity)

      assert {:ok, _identity, unavailable_fence} =
               CredentialFencing.allocate_usage_probe(identity)

      assert {:ok, :applied, rejected_identity} =
               CredentialFencing.mark_definitive_rejection(identity, rejection_fence)

      assert rejected_identity.status == "reauth_required"
      test_pid = self()

      assert {:ok, :superseded, still_rejected_identity, nil} =
               CredentialFencing.guard_active_usage_probe_completion(
                 identity,
                 unavailable_fence,
                 :auth_failure,
                 fn _locked_identity ->
                   send(test_pid, :stale_pool_callback_ran)
                   {:ok, :stale_pool_write}
                 end
               )

      assert still_rejected_identity.status == "reauth_required"
      refute_received :stale_pool_callback_ran
    end

    test "older post-quota finalization is superseded after a newer rejection" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, _identity, older_fence} = CredentialFencing.allocate_usage_probe(identity)
      assert {:ok, _identity, newer_fence} = CredentialFencing.allocate_usage_probe(identity)

      assert {:ok, :applied, _identity, :persisted} =
               CredentialFencing.apply_usage_success(identity, older_fence, fn _locked_identity ->
                 {:ok, :persisted}
               end)

      assert {:ok, :applied, rejected_identity} =
               CredentialFencing.mark_definitive_rejection(identity, newer_fence)

      assert rejected_identity.status == "reauth_required"

      assert {:ok, :superseded, still_rejected_identity, nil} =
               CredentialFencing.guard_active_usage_probe_completion(
                 identity,
                 older_fence,
                 fn _locked_identity ->
                   send(self(), :unexpected_stale_finalization)
                   {:ok, :finalized}
                 end
               )

      refute_received :unexpected_stale_finalization
      assert still_rejected_identity.status == "reauth_required"
      assert still_rejected_identity.metadata["usage_probe_applied_sequence"] == 2
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

    test "fresh fenced provider quota preserves an assignment disabled after relink" do
      success_upstream = start_upstream(FakeUpstream.json_response(usage_payload()))
      recovery = rejected_and_relinked_identity_fixture()

      assert {:ok, _disabled_assignment} =
               PoolAssignments.disable_pool_assignment(recovery.sibling_assignment)

      disabled_before = Repo.get!(PoolUpstreamAssignment, recovery.sibling_assignment.id)

      source_assignment =
        update_assignment_upstream!(recovery.linked_assignment, success_upstream)

      assert {:ok, recovered_identity} =
               PoolReconciliation.refresh_quota_from_usage(
                 recovery.linked_identity,
                 source_assignment
               )

      assert recovered_identity.status == "active"

      assert Repo.get!(PoolUpstreamAssignment, recovery.sibling_assignment.id) ==
               disabled_before

      recovered_source = Repo.get!(PoolUpstreamAssignment, recovery.linked_assignment.id)
      assert recovered_source.health_status == "active"
      assert recovered_source.eligibility_status == "eligible"
    end

    test "fresh auth recovery preserves an independent disable committed while success waits" do
      recovery = committed_relinked_recovery_fixture()
      release_ref = make_ref()
      parent = self()

      identity_lock =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from(identity in UpstreamIdentity,
                  where: identity.id == ^recovery.identity.id,
                  lock: "FOR UPDATE"
                )
              )

              send(parent, {:recovery_identity_lock_acquired, release_ref})

              receive do
                ^release_ref -> :ok
              end
            end)
          end)
        end)

      assert_receive {:recovery_identity_lock_acquired, ^release_ref}

      recovery_success =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:recovery_success_connection, release_ref, backend_pid})

            CredentialFencing.apply_usage_success(
              recovery.identity,
              recovery.fence,
              fn _locked_identity -> {:ok, :persisted} end
            )
          end)
        end)

      assert_receive {:recovery_success_connection, ^release_ref, recovery_backend}
      assert_backend_waiting_on_db_lock!(recovery_backend)

      disabled_before =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, disabled_assignment} =
                   PoolAssignments.disable_pool_assignment(recovery.sibling_assignment)

          Repo.reload!(disabled_assignment)
        end)

      send(identity_lock.pid, release_ref)
      assert {:ok, :ok} = Task.await(identity_lock)

      assert {:ok, :applied, _identity, :persisted} = Task.await(recovery_success)

      {current_source, current_sibling} =
        Sandbox.unboxed_run(Repo, fn ->
          {
            Repo.get!(PoolUpstreamAssignment, recovery.source_assignment.id),
            Repo.get!(PoolUpstreamAssignment, recovery.sibling_assignment.id)
          }
        end)

      assert current_sibling == disabled_before
      assert current_source.health_status == "active"
      assert current_source.eligibility_status == "eligible"
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

    test "worker terminal writes cannot overwrite a newer rejection after catalog sync stalls" do
      catalog_release_ref = make_ref()

      success_upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {200, usage_payload()},
             "/backend-api/codex/models" =>
               FakeUpstream.barrier_json_response(
                 %{"models" => [%{"id" => "gpt-test"}]},
                 notify: self(),
                 release_ref: catalog_release_ref
               )
           }}
        )

      rejection_upstream =
        start_upstream(unavailable_usage_paths(401, %{"error" => "rejected"}))

      {success_pool, success_assignment} = active_usage_probe_assignment(success_upstream)
      identity = Upstreams.get_upstream_identity(success_assignment.upstream_identity_id)
      initial_success_at = ~U[2026-07-01 12:00:00.000000Z]

      success_assignment =
        success_assignment
        |> PoolUpstreamAssignment.changeset(%{last_successful_refresh_at: initial_success_at})
        |> Repo.update!()

      success_task =
        start_allowed_task(fn ->
          AccountReconciliation.run(success_pool.id, success_assignment.id, "manual")
        end)

      catalog_barrier = await_upstream_barrier(catalog_release_ref)
      rejection_pool = pool_fixture()

      assert {:ok, rejection_assignment} =
               PoolAssignments.create_pool_assignment(rejection_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible",
                 metadata: %{"base_url" => FakeUpstream.url(rejection_upstream)}
               })

      assert {:ok, rejection_result} =
               Upstreams.reconcile_pool_account(rejection_pool, rejection_assignment)

      assert rejection_result.quota.code == "quota_refresh_auth_unavailable"

      rejected_before = Repo.get!(PoolUpstreamAssignment, success_assignment.id)
      rejection_summary = rejected_before.metadata["last_reconciliation"]
      rejection_success_at = rejected_before.last_successful_refresh_at
      assert rejected_before.health_status == "disabled"
      assert rejected_before.eligibility_status == "ineligible"

      release_upstream_barrier(catalog_barrier, catalog_release_ref)

      assert {:ok, stale_result} = Task.await(success_task)
      assert stale_result.quota.code == "quota_refresh_superseded"

      current_assignment = Repo.get!(PoolUpstreamAssignment, success_assignment.id)
      assert current_assignment.metadata["last_reconciliation"] == rejection_summary
      assert current_assignment.last_successful_refresh_at == rejection_success_at
      assert current_assignment.health_status == "disabled"
      assert current_assignment.eligibility_status == "ineligible"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"
    end

    test "newer unavailable worker terminal cannot overwrite an older rejection after catalog stalls" do
      rejection_release_ref = make_ref()
      unavailable_release_ref = make_ref()
      catalog_release_ref = make_ref()

      rejection_upstream =
        start_upstream(rejection_barrier_paths(self(), rejection_release_ref))

      unavailable_response =
        FakeUpstream.barrier_json_response(%{"error" => "busy"},
          status: 429,
          notify: self(),
          release_ref: unavailable_release_ref
        )

      unavailable_upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" => unavailable_response,
             "/backend-api/codex/usage" => unavailable_response,
             "/backend-api/codex/models" =>
               FakeUpstream.barrier_json_response(
                 %{"models" => [%{"id" => "gpt-test"}]},
                 notify: self(),
                 release_ref: catalog_release_ref
               )
           }}
        )

      {rejection_pool, rejection_assignment} =
        active_usage_probe_assignment(rejection_upstream)

      identity = Upstreams.get_upstream_identity(rejection_assignment.upstream_identity_id)
      unavailable_pool = pool_fixture()

      assert {:ok, unavailable_assignment} =
               PoolAssignments.create_pool_assignment(unavailable_pool, identity, %{
                 status: "active",
                 health_status: "active",
                 eligibility_status: "eligible",
                 metadata: %{"base_url" => FakeUpstream.url(unavailable_upstream)}
               })

      rejection_task =
        start_allowed_task(fn ->
          Upstreams.reconcile_pool_account(rejection_pool, rejection_assignment)
        end)

      first_rejection_barrier = await_upstream_barrier(rejection_release_ref)

      unavailable_task =
        start_allowed_task(fn ->
          AccountReconciliation.run(
            unavailable_pool.id,
            unavailable_assignment.id,
            "manual"
          )
        end)

      first_unavailable_barrier = await_upstream_barrier(unavailable_release_ref)
      release_upstream_barrier(first_unavailable_barrier, unavailable_release_ref)
      second_unavailable_barrier = await_upstream_barrier(unavailable_release_ref)
      release_upstream_barrier(second_unavailable_barrier, unavailable_release_ref)
      catalog_barrier = await_upstream_barrier(catalog_release_ref)

      release_upstream_barrier(first_rejection_barrier, rejection_release_ref)
      second_rejection_barrier = await_upstream_barrier(rejection_release_ref)
      release_upstream_barrier(second_rejection_barrier, rejection_release_ref)

      assert {:ok, rejection_result} = Task.await(rejection_task)
      assert rejection_result.quota.code == "quota_refresh_auth_unavailable"

      rejected_before = Repo.get!(PoolUpstreamAssignment, unavailable_assignment.id)
      assert rejected_before.health_status == "disabled"
      assert rejected_before.eligibility_status == "ineligible"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

      release_upstream_barrier(catalog_barrier, catalog_release_ref)

      assert {:ok, stale_result} = Task.await(unavailable_task)
      assert stale_result.quota.code == "quota_refresh_superseded"

      current_assignment = Repo.get!(PoolUpstreamAssignment, unavailable_assignment.id)

      protected_fields = [
        :status,
        :health_status,
        :eligibility_status,
        :disabled_at,
        :last_healthcheck_at,
        :last_successful_refresh_at,
        :metadata
      ]

      assert Map.take(current_assignment, protected_fields) ==
               Map.take(rejected_before, protected_fields)

      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"
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

      preserved_healthcheck_at =
        DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      assignment =
        assignment
        |> PoolUpstreamAssignment.changeset(%{
          health_status: "disabled",
          eligibility_status: "ineligible",
          last_healthcheck_at: preserved_healthcheck_at
        })
        |> Repo.update!()

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
      assert assignment.health_status == "disabled"
      assert assignment.eligibility_status == "ineligible"
      assert assignment.last_healthcheck_at == preserved_healthcheck_at
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

    @tag :scheduled_expiry_enqueue
    test "concurrent sibling assignments enqueue one incomplete saved-reset job per identity" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      {_second_pool, second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Scheduled saved-reset sibling",
          created_at: DateTime.add(assignment.created_at, 60, :second)
        )

      parent = self()

      tasks =
        Enum.map([assignment, second_assignment], fn target_assignment ->
          start_allowed_task(fn ->
            send(parent, {:scheduled_enqueue_ready, self()})

            receive do
              :enqueue_scheduled_saved_reset ->
                Jobs.enqueue_scheduled_saved_reset_redemption(target_assignment)
            end
          end)
        end)

      task_pids =
        Enum.map(tasks, fn _task ->
          assert_receive {:scheduled_enqueue_ready, task_pid}
          task_pid
        end)

      Enum.each(task_pids, &send(&1, :enqueue_scheduled_saved_reset))
      results = Enum.map(tasks, &Task.await/1)

      assert Enum.count(results, &match?({:ok, %{conflict?: false}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, %{conflict?: true}}, &1)) == 1

      assert [persisted_job] =
               Repo.all(
                 from(job in Oban.Job,
                   where: job.worker == ^worker_name(SavedResetRedemptionWorker)
                 )
               )

      assert persisted_job.state in ~w(suspended available scheduled executing retryable)
      assert persisted_job.args["upstream_identity_id"] == identity.id
    end

    @tag :scheduled_expiry_enqueue
    test "scheduled saved-reset uniqueness covers every incomplete state without a time limit" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      {_second_pool, second_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Scheduled saved-reset uniqueness sibling",
          created_at: DateTime.add(assignment.created_at, 60, :second)
        )

      for incomplete_state <- ~w(suspended available scheduled executing retryable) do
        Repo.delete_all(Oban.Job)

        assert {:ok, first_job} =
                 Jobs.enqueue_scheduled_saved_reset_redemption(assignment)

        old_inserted_at =
          DateTime.utc_now()
          |> DateTime.add(-30, :day)
          |> DateTime.truncate(:microsecond)

        {1, _rows} =
          from(job in Oban.Job, where: job.id == ^first_job.id)
          |> Repo.update_all(set: [state: incomplete_state, inserted_at: old_inserted_at])

        assert {:ok, conflict_job} =
                 Jobs.enqueue_scheduled_saved_reset_redemption(second_assignment)

        assert conflict_job.conflict?
        assert conflict_job.id == first_job.id
      end

      Repo.delete_all(Oban.Job)

      assert {:ok, completed_job} =
               Jobs.enqueue_scheduled_saved_reset_redemption(assignment)

      {1, _rows} =
        from(job in Oban.Job, where: job.id == ^completed_job.id)
        |> Repo.update_all(set: [state: "completed", completed_at: DateTime.utc_now()])

      assert {:ok, replacement_job} =
               Jobs.enqueue_scheduled_saved_reset_redemption(second_assignment)

      refute replacement_job.conflict?
      refute replacement_job.id == completed_job.id
    end

    @tag :scheduled_expiry_reconciliation
    test "fresh canonical scheduled identity reconciliation enqueues B1, B2, and B3" do
      scenarios = [
        {:b1, [weekly_used_percent: 100], "exhausted"},
        {:b2,
         [
           weekly_used_percent: 95,
           policy_attrs: %{saved_reset_auto_redeem_trigger_mode: "threshold"}
         ], "threshold"},
        {:b3, [weekly_used_percent: 25], "last_call"}
      ]

      for {scenario, opts, expected_detail} <- scenarios do
        Repo.delete_all(Oban.Job)

        %{pool: pool, assignment: assignment, identity: identity, upstream: upstream} =
          scheduled_expiry_reconciliation_fixture(opts)

        assert :ok =
                 perform_job(
                   AccountReconciliationWorker,
                   scheduled_identity_reconciliation_args(pool, assignment, identity)
                 )

        persisted_identity = Repo.get!(UpstreamIdentity, identity.id)

        assert {:ok, observed_at, _offset} =
                 persisted_identity.metadata["saved_resets"]["observed_at"]
                 |> DateTime.from_iso8601()

        assert AutoEligibility.scheduled_expiry_candidate?(persisted_identity, DateTime.utc_now())
        assert [job] = scheduled_saved_reset_redemption_jobs()

        assert job.args == %{
                 "pool_upstream_assignment_id" => assignment.id,
                 "upstream_identity_id" => identity.id,
                 "target_kind" => "upstream_identity",
                 "trigger_kind" => "scheduled_expiry_rescue"
               }

        windows = QuotaWindows.list_evidence(persisted_identity)
        policy = SavedResets.auto_policy(persisted_identity)
        snapshot = SavedResets.snapshot(persisted_identity, observed_at)

        assert {:burn, %{trigger_detail: ^expected_detail}} =
                 AutoEligibility.scheduled_burn_condition(
                   windows,
                   policy,
                   snapshot,
                   observed_at
                 ),
               Atom.to_string(scenario)

        assert DateTime.compare(observed_at, DateTime.add(DateTime.utc_now(), -60, :second)) !=
                 :lt

        assert Repo.aggregate(Request, :count) == 0

        provider_requests = FakeUpstream.requests(upstream)

        assert Enum.any?(
                 provider_requests,
                 &(&1.method == "GET" and &1.path == "/backend-api/wham/usage")
               )

        assert Enum.all?(provider_requests, &(&1.method == "GET"))
        refute Enum.any?(provider_requests, &String.contains?(&1.path, "/consume"))

        post_consume_payload =
          observed_at
          |> scheduled_expiry_usage_payload(expiration?: false, weekly_used_percent: 0)
          |> put_in(["rate_limit_reset_credits", "available_count"], 0)

        FakeUpstream.set_mode(
          upstream,
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [%{"id" => "synthetic-credit", "status" => "available"}],
                  "available_count" => 1
                }},
             "/backend-api/wham/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/backend-api/wham/usage" => {200, post_consume_payload}
           }}
        )

        assert %{success: 1, failure: 0, discard: 0} = Oban.drain_queue(queue: :jobs)
        assert Repo.get!(Oban.Job, job.id).state == "completed"
        assert scheduled_consume_count(upstream) == 1
        assert Repo.aggregate(Request, :count) == 0

        redemption = Repo.get!(UpstreamIdentity, identity.id).metadata["saved_reset_redemption"]
        assert redemption["result"]["applied"] == true
        assert redemption["trigger_detail"] == expected_detail
        refute Map.has_key?(redemption, "probe")
        assert scheduled_saved_reset_redemption_jobs() == [Repo.get!(Oban.Job, job.id)]

        assert Repo.all(
                 from(current_job in Oban.Job, select: {current_job.worker, current_job.queue})
               ) ==
                 [{worker_name(SavedResetRedemptionWorker), "jobs"}]
      end
    end

    @tag :scheduled_expiry_reconciliation
    test "queued B2 condition flip completes as noop without provider consume" do
      %{pool: pool, assignment: assignment, identity: identity, upstream: upstream} =
        scheduled_expiry_reconciliation_fixture(
          weekly_used_percent: 95,
          policy_attrs: %{saved_reset_auto_redeem_trigger_mode: "threshold"}
        )

      assert :ok =
               perform_job(
                 AccountReconciliationWorker,
                 scheduled_identity_reconciliation_args(pool, assignment, identity)
               )

      assert [job] = scheduled_saved_reset_redemption_jobs()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      identity
      |> QuotaWindows.list_evidence()
      |> Enum.each(fn window ->
        window
        |> AccountQuotaWindow.changeset(%{
          used_percent: Decimal.new("0"),
          observed_at: observed_at,
          last_sync_at: observed_at
        })
        |> Repo.update!()
      end)

      persisted_identity = Repo.get!(UpstreamIdentity, identity.id)
      persisted_windows = QuotaWindows.list_evidence(persisted_identity)
      snapshot = SavedResets.snapshot(persisted_identity, observed_at)
      policy = SavedResets.auto_policy(persisted_identity)

      assert {:not_ready, :burn_condition_absent} =
               AutoEligibility.scheduled_burn_condition(
                 persisted_windows,
                 policy,
                 snapshot,
                 observed_at
               ),
             inspect(
               Enum.map(
                 persisted_windows,
                 &Map.take(&1, [:quota_key, :source, :used_percent, :reset_at, :observed_at])
               )
             )

      refute AutoEligibility.scheduled_expiry_candidate?(persisted_identity, observed_at)

      consume_count_before = scheduled_consume_count(upstream)

      drain_result = Oban.drain_queue(queue: :jobs)
      drained_job = Repo.get!(Oban.Job, job.id)

      assert drain_result ==
               %{cancelled: 0, discard: 0, failure: 0, snoozed: 0, success: 1},
             inspect(%{drain_result: drain_result, job: drained_job})

      assert drained_job.state == "completed"
      assert scheduled_consume_count(upstream) == consume_count_before
      assert Repo.aggregate(Request, :count) == 0

      persisted_identity = Repo.get!(UpstreamIdentity, identity.id)
      refute Map.has_key?(persisted_identity.metadata || %{}, "saved_reset_redemption")
    end

    @tag :scheduled_expiry_reconciliation
    test "scheduled B2 is evaluated per identity" do
      %{pool: pool, assignment: assignment, identity: identity} =
        scheduled_expiry_reconciliation_fixture(
          weekly_used_percent: 95,
          policy_attrs: %{saved_reset_auto_redeem_trigger_mode: "threshold"}
        )

      %{identity: sibling_identity} =
        active_upstream_assignment_fixture(pool, %{
          account_label: "Scheduled threshold sibling",
          assignment_label: "Scheduled threshold sibling assignment"
        })

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(sibling_identity, [
                 scheduled_weekly_window_attrs(
                   DateTime.utc_now() |> DateTime.truncate(:microsecond),
                   Decimal.new("10"),
                   2 * 60 * 60
                 )
               ])

      assert :ok =
               perform_job(
                 AccountReconciliationWorker,
                 scheduled_identity_reconciliation_args(pool, assignment, identity)
               )

      assert [job] = scheduled_saved_reset_redemption_jobs()
      assert job.args["upstream_identity_id"] == identity.id
      assert job.args["pool_upstream_assignment_id"] == assignment.id
    end

    @tag :scheduled_expiry_reconciliation
    test "scheduled redemption resolves its decision time after the assignment lock" do
      fixture =
        Sandbox.unboxed_run(Repo, fn ->
          %{pool: pool, assignment: assignment, identity: identity, upstream: upstream} =
            scheduled_expiry_reconciliation_fixture()

          assert :ok =
                   perform_job(
                     AccountReconciliationWorker,
                     scheduled_identity_reconciliation_args(pool, assignment, identity)
                   )

          {pool, assignment, Repo.reload!(identity), upstream}
        end)

      {pool, assignment, identity, upstream} = fixture

      on_exit(fn -> cleanup_committed_reconciliation_fixture(identity.id, [pool.id]) end)

      expires_at =
        DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.truncate(:microsecond)

      Sandbox.unboxed_run(Repo, fn ->
        persisted = Repo.reload!(identity)
        saved_resets = persisted.metadata["saved_resets"]
        expires_at_iso = DateTime.to_iso8601(expires_at)

        persisted
        |> UpstreamIdentity.changeset(%{
          metadata:
            put_in(persisted.metadata, ["saved_resets"], %{
              saved_resets
              | "available_expires_at" => [expires_at_iso],
                "available_expirations" => [
                  %{
                    "expires_at" => expires_at_iso,
                    "first_seen_at" => saved_resets["observed_at"]
                  }
                ],
                "next_expires_at" => expires_at_iso
            })
        })
        |> Repo.update!()
      end)

      parent = self()
      release_ref = make_ref()

      lock_holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from(current_assignment in PoolUpstreamAssignment,
                  where: current_assignment.id == ^assignment.id,
                  lock: "FOR UPDATE"
                )
              )

              send(parent, {:scheduled_assignment_locked, release_ref})

              receive do
                ^release_ref -> :ok
              end
            end)
          end)
        end)

      assert_receive {:scheduled_assignment_locked, ^release_ref}

      redemption =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:scheduled_redemption_connection, release_ref, backend_pid})
            SavedResetRedemption.redeem_scheduled_expiry(assignment.id, identity.id)
          end)
        end)

      assert_receive {:scheduled_redemption_connection, ^release_ref, backend_pid}
      assert_backend_waiting_on_db_lock!(backend_pid)

      receive do
      after
        max(
          DateTime.diff(DateTime.add(expires_at, 1, :second), DateTime.utc_now(), :millisecond) +
              50,
          0
        ) ->
          :ok
      end

      send(lock_holder.pid, release_ref)
      assert {:ok, :ok} = Task.await(lock_holder)

      assert {:ok, %{status: :noop, code: "scheduled_expiry_not_expiring"}} =
               Task.await(redemption)

      persisted = Sandbox.unboxed_run(Repo, fn -> Repo.reload!(identity) end)
      refute Map.has_key?(persisted.metadata || %{}, "saved_reset_redemption")
      assert scheduled_consume_count(upstream) == 0
    end

    @tag :scheduled_expiry_zero_traffic
    test "scheduled pending redemption converges from later reconciliation without a request probe" do
      %{pool: pool, assignment: assignment, identity: identity, upstream: upstream} =
        scheduled_expiry_reconciliation_fixture()

      reconciliation_args = scheduled_identity_reconciliation_args(pool, assignment, identity)

      assert :ok = perform_job(AccountReconciliationWorker, reconciliation_args)
      assert [job] = scheduled_saved_reset_redemption_jobs()

      FakeUpstream.set_mode(
        upstream,
        {:path_json,
         %{
           "/backend-api/wham/rate-limit-reset-credits" =>
             {200,
              %{
                "credits" => [%{"id" => "synthetic-credit", "status" => "available"}],
                "available_count" => 1
              }},
           "/backend-api/wham/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" => {500, %{"error" => "synthetic usage failure"}},
           "/backend-api/codex/usage" => {500, %{"error" => "synthetic usage failure"}},
           "/wham/usage" => {500, %{"error" => "synthetic usage failure"}},
           "/backend-api/wham/usage" => {500, %{"error" => "synthetic usage failure"}}
         }}
      )

      assert :ok = perform_job(SavedResetRedemptionWorker, job.args)

      pending =
        Repo.get!(UpstreamIdentity, identity.id).metadata["saved_reset_redemption"]

      assert pending["phase"] == "consumed_pending_probe"
      assert pending["status"] == "redeeming"
      refute Map.has_key?(pending, "probe")
      assert Repo.aggregate(Request, :count) == 0
      assert scheduled_consume_count(upstream) == 1

      fresh_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      fresh_payload =
        fresh_at
        |> scheduled_expiry_usage_payload(expiration?: false, weekly_used_percent: 100)
        |> put_in(["rate_limit_reset_credits", "available_count"], 0)

      FakeUpstream.set_mode(
        upstream,
        {:path_json, %{"/backend-api/wham/usage" => {200, fresh_payload}}}
      )

      Repo.delete_all(Oban.Job)
      assert :ok = perform_job(AccountReconciliationWorker, reconciliation_args)

      converged =
        Repo.get!(UpstreamIdentity, identity.id).metadata["saved_reset_redemption"]

      assert {:ok, consumed_at, _offset} = DateTime.from_iso8601(pending["consumed_at"])

      fresh_windows = QuotaWindows.list_evidence(identity)

      assert Enum.any?(fresh_windows, &(&1.quota_key == "account")),
             inspect(
               Enum.map(
                 fresh_windows,
                 &Map.take(&1, [:quota_key, :used_percent, :observed_at, :source_precision])
               )
             )

      assert Enum.any?(
               fresh_windows,
               &(is_struct(&1.observed_at, DateTime) and
                   DateTime.compare(&1.observed_at, consumed_at) != :lt)
             ),
             inspect(
               Enum.map(
                 fresh_windows,
                 &Map.take(&1, [:quota_key, :used_percent, :observed_at, :source_precision])
               )
             )

      assert PostResetEvidence.classify(
               fresh_windows,
               consumed_at,
               DateTime.utc_now()
             ) == :reblocked

      assert converged["phase"] == "reblocked"
      refute Map.has_key?(converged, "probe")
      assert Repo.aggregate(Request, :count) == 0
      assert scheduled_consume_count(upstream) == 1
      assert scheduled_saved_reset_redemption_jobs() == []

      if System.get_env("TASK5_MANUAL_QA") == "1" do
        IO.puts(
          "TASK5_ZERO_TRAFFIC pending_phase=#{pending["phase"]} " <>
            "probe_present=#{Map.has_key?(pending, "probe")} " <>
            "accounting_count=#{Repo.aggregate(Request, :count)} " <>
            "converged_phase=#{converged["phase"]} " <>
            "consume_count=#{scheduled_consume_count(upstream)}"
        )
      end
    end

    @tag :scheduled_expiry_reconciliation
    test "scheduled reconciliation policy and expiry negatives enqueue nothing" do
      scenarios = [
        {:policy_disabled, [policy_enabled?: false], :ok},
        {:no_weekly_usage, [weekly_used_percent: nil], :error},
        {:natural_reset_buffer, [weekly_reset_after_seconds: 30 * 60], :ok},
        {:blocked_only, [expiration?: false, weekly_used_percent: 100], :ok},
        {:threshold_only,
         [
           expiration?: false,
           weekly_used_percent: 70,
           policy_attrs: %{saved_reset_auto_redeem_trigger_mode: "threshold"}
         ], :ok}
      ]

      for {scenario, opts, expected_result} <- scenarios do
        Repo.delete_all(Oban.Job)

        %{pool: pool, assignment: assignment, identity: identity} =
          scheduled_expiry_reconciliation_fixture(opts)

        result =
          perform_job(
            AccountReconciliationWorker,
            scheduled_identity_reconciliation_args(pool, assignment, identity)
          )

        case expected_result do
          :ok -> assert result == :ok, Atom.to_string(scenario)
          :error -> assert match?({:error, _reason}, result), Atom.to_string(scenario)
        end

        assert scheduled_saved_reset_redemption_jobs() == [], Atom.to_string(scenario)
        assert Repo.aggregate(Request, :count) == 0, Atom.to_string(scenario)
      end
    end

    @tag :scheduled_expiry_reconciliation
    test "scheduled-shaped direct, malformed, and noncanonical jobs enqueue nothing" do
      malformed_args = [
        direct_assignment: fn pool, assignment, _identity ->
          %{
            "pool_id" => pool.id,
            "pool_upstream_assignment_id" => assignment.id,
            "trigger_kind" => "scheduled"
          }
        end,
        missing_identity: fn pool, assignment, _identity ->
          %{
            "pool_id" => pool.id,
            "pool_upstream_assignment_id" => assignment.id,
            "target_kind" => "upstream_identity",
            "trigger_kind" => "scheduled"
          }
        end,
        mismatched_identity: fn pool, assignment, _identity ->
          %{
            "pool_id" => pool.id,
            "pool_upstream_assignment_id" => assignment.id,
            "upstream_identity_id" => Ecto.UUID.generate(),
            "target_kind" => "upstream_identity",
            "trigger_kind" => "scheduled"
          }
        end
      ]

      for {scenario, args_builder} <- malformed_args do
        Repo.delete_all(Oban.Job)

        %{pool: pool, assignment: assignment, identity: identity} =
          scheduled_expiry_reconciliation_fixture()

        assert :ok =
                 perform_job(
                   AccountReconciliationWorker,
                   args_builder.(pool, assignment, identity)
                 )

        assert scheduled_saved_reset_redemption_jobs() == [], Atom.to_string(scenario)
        assert Repo.aggregate(Request, :count) == 0, Atom.to_string(scenario)
      end

      Repo.delete_all(Oban.Job)

      %{assignment: canonical_assignment, identity: identity} =
        scheduled_expiry_reconciliation_fixture()

      {noncanonical_pool, noncanonical_assignment} =
        active_assignment_for_identity_fixture(identity,
          assignment_label: "Noncanonical scheduled expiry assignment",
          created_at: DateTime.add(canonical_assignment.created_at, 60, :second),
          metadata: canonical_assignment.metadata
        )

      assert :ok =
               perform_job(
                 AccountReconciliationWorker,
                 scheduled_identity_reconciliation_args(
                   noncanonical_pool,
                   noncanonical_assignment,
                   identity
                 )
               )

      assert scheduled_saved_reset_redemption_jobs() == []
      assert Repo.aggregate(Request, :count) == 0
    end

    @tag :scheduled_expiry_reconciliation
    test "reused, failed, skipped, and stale saved-reset observations enqueue nothing" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_observed_at = DateTime.add(now, -60, :second)
      stale_saved_resets = scheduled_saved_reset_metadata(stale_observed_at, "codex_usage_api")
      upstream = start_upstream(unavailable_usage_paths())

      {reused_pool, reused_assignment} =
        active_assignment_fixture(
          %{"base_url" => FakeUpstream.url(upstream)},
          identity_metadata:
            fresh_access_token_metadata(FakeUpstream.url(upstream))
            |> Map.put("saved_resets", stale_saved_resets)
        )

      reused_identity =
        Repo.get!(UpstreamIdentity, reused_assignment.upstream_identity_id)
        |> enable_scheduled_expiry_policy!()

      persist_quota_windows!(reused_identity, [
        scheduled_weekly_window_attrs(now, Decimal.new("25"), 2 * 60 * 60)
      ])

      assert :ok =
               perform_job(
                 AccountReconciliationWorker,
                 scheduled_identity_reconciliation_args(
                   reused_pool,
                   reused_assignment,
                   reused_identity
                 )
               )

      assert scheduled_saved_reset_redemption_jobs() == []
      assert Repo.aggregate(Request, :count) == 0

      Repo.delete_all(Oban.Job)

      {failed_pool, failed_assignment} =
        active_usage_probe_assignment(start_upstream(unavailable_usage_paths()))

      failed_identity =
        Repo.get!(UpstreamIdentity, failed_assignment.upstream_identity_id)
        |> enable_scheduled_expiry_policy!()

      assert {:error, error} =
               perform_job(
                 AccountReconciliationWorker,
                 scheduled_identity_reconciliation_args(
                   failed_pool,
                   failed_assignment,
                   failed_identity
                 )
               )

      assert error =~ "quota_refresh_unavailable"
      assert scheduled_saved_reset_redemption_jobs() == []
      assert Repo.aggregate(Request, :count) == 0

      Repo.delete_all(Oban.Job)

      %{pool: skipped_pool, assignment: skipped_assignment, identity: skipped_identity} =
        scheduled_expiry_reconciliation_fixture()

      assert {:ok, skipped_assignment} =
               PoolAssignments.disable_pool_assignment(skipped_assignment)

      assert :ok =
               perform_job(
                 AccountReconciliationWorker,
                 scheduled_identity_reconciliation_args(
                   skipped_pool,
                   skipped_assignment,
                   skipped_identity
                 )
               )

      assert scheduled_saved_reset_redemption_jobs() == []
      assert Repo.aggregate(Request, :count) == 0

      Repo.delete_all(Oban.Job)

      local_saved_resets =
        scheduled_saved_reset_metadata(stale_observed_at, "local_reconciliation")

      {stale_pool, stale_assignment} =
        active_assignment_fixture(
          %{
            "quota_windows" => [
              %{
                "quota_key" => "account",
                "quota_scope" => "account",
                "quota_family" => "account",
                "window_kind" => "secondary",
                "window_minutes" => 10_080,
                "used_percent" => 25,
                "reset_at" => DateTime.to_iso8601(DateTime.add(now, 2, :hour)),
                "source" => "local_reconciliation",
                "source_precision" => "observed",
                "freshness_state" => "fresh"
              }
            ]
          },
          identity_metadata: %{"saved_resets" => local_saved_resets}
        )

      stale_identity =
        Repo.get!(UpstreamIdentity, stale_assignment.upstream_identity_id)
        |> enable_scheduled_expiry_policy!()

      assert :ok =
               perform_job(
                 AccountReconciliationWorker,
                 scheduled_identity_reconciliation_args(
                   stale_pool,
                   stale_assignment,
                   stale_identity
                 )
               )

      persisted_stale_identity = Repo.get!(UpstreamIdentity, stale_identity.id)
      persisted_stale_assignment = Repo.get!(PoolUpstreamAssignment, stale_assignment.id)

      assert Enum.any?(
               persisted_stale_assignment.metadata["last_reconciliation"]["steps"],
               &(&1["code"] == "quota_refreshed")
             )

      assert persisted_stale_identity.metadata["saved_resets"]["observed_at"] ==
               DateTime.to_iso8601(stale_observed_at)

      assert AutoEligibility.scheduled_expiry_candidate?(
               persisted_stale_identity,
               DateTime.utc_now()
             )

      assert scheduled_saved_reset_redemption_jobs() == []
      assert Repo.aggregate(Request, :count) == 0
    end

    @tag :scheduled_expiry_reconciliation
    test "superseded fresh provider reconciliation enqueues nothing" do
      release_ref = make_ref()
      payload = scheduled_expiry_usage_payload(DateTime.utc_now())

      upstream =
        start_upstream(
          {:path_json,
           %{
             "/backend-api/wham/usage" =>
               FakeUpstream.barrier_json_response(payload,
                 notify: self(),
                 release_ref: release_ref
               )
           }}
        )

      {pool, assignment} = active_usage_probe_assignment(upstream)

      identity =
        Repo.get!(UpstreamIdentity, assignment.upstream_identity_id)
        |> enable_scheduled_expiry_policy!()

      reconciliation =
        start_allowed_task(fn ->
          perform_job(
            AccountReconciliationWorker,
            scheduled_identity_reconciliation_args(pool, assignment, identity)
          )
        end)

      barrier = await_upstream_barrier(release_ref)
      assert {:ok, _disabled_assignment} = PoolAssignments.disable_pool_assignment(assignment)
      release_upstream_barrier(barrier, release_ref)

      assert :ok = Task.await(reconciliation)
      assert scheduled_saved_reset_redemption_jobs() == []
      assert Repo.aggregate(Request, :count) == 0
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

    test "scheduled enqueue observes same-process pause updates after the cache was primed" do
      {_pool, assignment} =
        active_assignment_fixture(%{"quota_priming" => %{"status" => "known"}})

      Application.put_env(:codex_pooler, :dev_features_enabled, true)

      assert {:ok, _settings} =
               InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
                 "development" => %{"account_reconciliation_paused" => false}
               })

      assert InstanceSettings.current().development.account_reconciliation_paused == false

      assert {:ok, _settings} =
               InstanceSettings.update_system_settings(InstanceSettings.get!(), %{
                 "development" => %{"account_reconciliation_paused" => true}
               })

      assert :ok = perform_job(AccountReconciliationEnqueueWorker, %{})

      reloaded_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert reloaded_assignment.metadata["quota_priming"]["status"] == "known"
      assert [] = all_enqueued(worker: AccountReconciliationWorker, queue: :jobs)
    end

    test "scheduled enqueue observes an external pause update after the cache was primed" do
      {_pool, assignment} =
        active_assignment_fixture(%{"quota_priming" => %{"status" => "known"}})

      Application.put_env(:codex_pooler, :dev_features_enabled, true)

      assert {:ok, settings} =
               InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
                 "development" => %{"account_reconciliation_paused" => false}
               })

      assert InstanceSettings.current().development.account_reconciliation_paused == false

      settings
      |> Repo.reload!()
      |> Settings.changeset(%{
        "development" => %{"account_reconciliation_paused" => true}
      })
      |> Repo.update!()

      assert Repo.get!(Settings, true).development.account_reconciliation_paused == true
      assert :ok = perform_job(AccountReconciliationEnqueueWorker, %{})

      reloaded_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert reloaded_assignment.metadata["quota_priming"]["status"] == "known"
      assert [] = all_enqueued(worker: AccountReconciliationWorker, queue: :jobs)
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

    test "skips already queued account reconciliation jobs when assignment is disabled" do
      {pool, assignment} = active_assignment_fixture(%{})

      assert {:ok, job} = Jobs.enqueue_account_reconciliation(pool, assignment)
      assert {:ok, _disabled_assignment} = PoolAssignments.disable_pool_assignment(assignment)

      disabled_before = Repo.get!(PoolUpstreamAssignment, assignment.id)

      assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :jobs)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.errors == []
      assert Repo.get!(PoolUpstreamAssignment, assignment.id) == disabled_before
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

    test "gateway reconciliation gate admits one simultaneous claim per identity" do
      identity_id = Ecto.UUID.generate()
      parent = self()

      on_exit(fn -> UpstreamEnqueue.release_gateway_reconciliation_gate(identity_id) end)

      tasks =
        for _index <- 1..32 do
          Task.async(fn ->
            send(parent, {:gate_claim_ready, self()})

            receive do
              :claim_gate -> UpstreamEnqueue.claim_gateway_reconciliation_gate(identity_id)
            end
          end)
        end

      task_pids =
        for _index <- 1..32 do
          assert_receive {:gate_claim_ready, task_pid}
          task_pid
        end

      Enum.each(task_pids, &send(&1, :claim_gate))
      results = Enum.map(tasks, &Task.await/1)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == :duplicate)) == 31
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
      assert :ok = Events.subscribe_pool(pool.id)

      assert {:ok, completed_job} =
               start_allowed_task(fn ->
                 Jobs.enqueue_gateway_account_reconciliation(pool, assignment)
               end)
               |> Task.await()

      completed_job_id = Integer.to_string(completed_job.id)

      assert_receive {Events,
                      %{
                        reason: "job_status_updated",
                        payload: %{
                          "id" => ^completed_job_id,
                          "status" => "scheduled",
                          "worker" => "account_reconciliation"
                        }
                      }}

      {1, _rows} =
        from(job in Oban.Job, where: job.id == ^completed_job.id)
        |> Repo.update_all(set: [state: "completed"])

      assert {:ok, completed_conflict} =
               start_allowed_task(fn ->
                 Jobs.enqueue_gateway_account_reconciliation(pool, assignment)
               end)
               |> Task.await()

      assert completed_conflict.conflict?
      assert completed_conflict.id == completed_job.id
      refute_received {Events, %{reason: "job_status_updated"}}

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

  defp committed_metadata_reconciliation_fixture do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        pool = pool_fixture()

        assert {:ok, identity} =
                 IdentityLifecycle.create_upstream_identity(%{
                   chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
                   account_label: "Committed reconciliation account",
                   onboarding_method: "import"
                 })

        assert {:ok, identity} = IdentityLifecycle.activate_upstream_identity(identity)

        assert {:ok, assignment} =
                 PoolAssignments.create_pool_assignment(pool, identity, %{
                   assignment_label: "Committed reconciliation assignment",
                   metadata: %{
                     "quota_windows" => [
                       %{
                         "window_kind" => "primary",
                         "window_minutes" => 300,
                         "active_limit" => 100,
                         "credits" => 75,
                         "reset_at" =>
                           DateTime.utc_now()
                           |> DateTime.add(3_600, :second)
                           |> DateTime.to_iso8601(),
                         "source" => "local_reconciliation",
                         "freshness_state" => "fresh"
                       }
                     ]
                   }
                 })

        assert {:ok, assignment} =
                 PoolAssignments.activate_pool_assignment(assignment, %{
                   skip_quota_priming: true
                 })

        {pool, identity, assignment}
      end)

    {pool, identity, _assignment} = fixture

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from(current_identity in UpstreamIdentity,
            where: current_identity.id == ^identity.id
          )
        )

        Repo.delete_all(
          from(current_pool in CodexPooler.Pools.Pool, where: current_pool.id == ^pool.id)
        )
      end)
    end)

    fixture
  end

  defp committed_stale_priming_fixture do
    {pool, identity, assignment} = committed_metadata_reconciliation_fixture()
    assignment = mark_committed_assignment_stale!(assignment)
    {pool, identity, assignment}
  end

  defp mark_committed_assignment_stale!(assignment, credential_epoch \\ nil) do
    Sandbox.unboxed_run(Repo, fn ->
      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      stale_started_at = DateTime.add(DateTime.utc_now(), -1, :hour)

      priming = %{
        "status" => "refreshing",
        "trigger_kind" => "scheduled",
        "started_at" => DateTime.to_iso8601(stale_started_at)
      }

      priming =
        if is_integer(credential_epoch),
          do: Map.put(priming, "credential_epoch", credential_epoch),
          else: priming

      assignment
      |> PoolUpstreamAssignment.changeset(%{
        metadata: Map.put(assignment.metadata || %{}, "quota_priming", priming)
      })
      |> Repo.update!()
    end)
  end

  defp committed_scoped_lifecycle_fixture do
    configure_upstream_secret_key!()
    {pool, identity, assignment} = committed_metadata_reconciliation_fixture()

    {scope, created_owner_id} =
      Sandbox.unboxed_run(Repo, fn ->
        owner =
          Repo.one(
            from(user in User,
              join: membership in Membership,
              on: membership.user_id == user.id,
              where:
                membership.role == "instance_owner" and membership.status == "active" and
                  user.status == "active" and is_nil(user.deleted_at),
              limit: 1
            )
          )

        {owner, created_owner_id} =
          case owner do
            %User{} = existing_owner -> {existing_owner, nil}
            nil -> insert_committed_owner!()
          end

        assert {:ok, _secret} =
                 Upstreams.store_encrypted_secret(identity, %{
                   secret_kind: "access_token",
                   plaintext: "committed-lifecycle-token"
                 })

        {%Scope{user: owner, roles: ["instance_owner"], assigned_pool_ids: []}, created_owner_id}
      end)

    if created_owner_id do
      on_exit(fn -> cleanup_committed_owner(created_owner_id) end)
    end

    {scope, pool, identity, assignment}
  end

  defp insert_committed_owner! do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    owner =
      Repo.insert!(%User{
        email: "committed-owner-#{System.unique_integer([:positive])}@example.com",
        display_name: "Committed owner",
        password_hash: "not-used",
        status: "active",
        password_change_required: false,
        created_at: timestamp,
        updated_at: timestamp
      })

    %Membership{}
    |> Membership.changeset(%{
      user_id: owner.id,
      role: "instance_owner",
      status: "active",
      created_at: timestamp
    })
    |> Repo.insert!()

    {owner, owner.id}
  end

  defp cleanup_committed_owner(owner_id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(
        from(event in CodexPooler.Audit.AuditEvent, where: event.actor_user_id == ^owner_id)
      )

      Repo.delete_all(from(membership in Membership, where: membership.user_id == ^owner_id))
      Repo.delete_all(from(user in User, where: user.id == ^owner_id))
    end)
  end

  defp committed_active_usage_probe_assignment(upstream) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        active_usage_probe_assignment(upstream)
      end)

    {pool, assignment} = fixture
    identity_id = assignment.upstream_identity_id

    on_exit(fn -> cleanup_committed_reconciliation_fixture(identity_id, [pool.id]) end)

    fixture
  end

  defp committed_relinked_recovery_fixture do
    recovery =
      Sandbox.unboxed_run(Repo, fn ->
        {source_pool, source_assignment} = active_assignment_fixture(%{})
        identity = Repo.get!(UpstreamIdentity, source_assignment.upstream_identity_id)

        {sibling_pool, sibling_assignment} =
          active_assignment_for_identity_fixture(identity,
            assignment_label: "Committed recovery sibling"
          )

        assert {:ok, _identity, rejection_fence} =
                 CredentialFencing.allocate_usage_probe(identity)

        assert {:ok, :applied, rejected_identity} =
                 CredentialFencing.mark_definitive_rejection(identity, rejection_fence)

        relinked_identity =
          rejected_identity
          |> UpstreamIdentity.changeset(%{
            status: "active",
            disabled_at: nil,
            metadata: CredentialFencing.advance_credential_epoch(rejected_identity)
          })
          |> Repo.update!()

        source_assignment =
          source_assignment
          |> Repo.reload!()
          |> PoolUpstreamAssignment.changeset(%{
            status: "active",
            health_status: "active",
            eligibility_status: "ineligible",
            disabled_at: nil
          })
          |> Repo.update!()

        assert {:ok, current_identity, fence} =
                 CredentialFencing.allocate_usage_probe(relinked_identity)

        %{
          identity: current_identity,
          fence: fence,
          source_assignment: source_assignment,
          sibling_assignment: sibling_assignment,
          pool_ids: [source_pool.id, sibling_pool.id]
        }
      end)

    on_exit(fn ->
      cleanup_committed_reconciliation_fixture(recovery.identity.id, recovery.pool_ids)
    end)

    recovery
  end

  defp cleanup_committed_reconciliation_fixture(identity_id, pool_ids) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(identity in UpstreamIdentity, where: identity.id == ^identity_id))

      Repo.delete_all(from(pool in CodexPooler.Pools.Pool, where: pool.id in ^pool_ids))
    end)
  end

  defp cleanup_committed_pool(pool_id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(
        from(assignment in PoolUpstreamAssignment, where: assignment.pool_id == ^pool_id)
      )

      Repo.delete_all(from(pool in CodexPooler.Pools.Pool, where: pool.id == ^pool_id))
    end)
  end

  defp apply_assignment_lifecycle!(:disable, _pool, assignment) do
    assert {:ok, disabled_assignment} = PoolAssignments.disable_pool_assignment(assignment)
    Repo.reload!(disabled_assignment)
  end

  defp apply_assignment_lifecycle!(:delete, pool, assignment) do
    assert {:ok, %{assignment: deleted_assignment}} =
             PoolAssignments.delete_pool_assignment(pool, assignment)

    Repo.reload!(deleted_assignment)
  end

  defp assert_backend_waiting_on_db_lock!(backend_pid) do
    assert_backend_waiting_on_db_lock!(
      backend_pid,
      System.monotonic_time(:millisecond) + 5_000
    )
  end

  defp assert_backend_waiting_on_db_lock!(backend_pid, deadline) do
    waiting? =
      Repo.query!(
        """
        SELECT 1
        FROM pg_stat_activity
        WHERE pid = $1
          AND wait_event_type = 'Lock'
        """,
        [backend_pid]
      ).num_rows == 1

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> assert_backend_waiting_on_db_lock!(backend_pid, deadline)
        end

      true ->
        flunk("backend did not enter a database lock wait")
    end
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

      assert assignment.health_status == "active",
             inspect(
               Map.take(assignment, [
                 :status,
                 :health_status,
                 :eligibility_status,
                 :disabled_at,
                 :metadata
               ])
             )

      assert assignment.eligibility_status == "eligible",
             inspect(
               Map.take(assignment, [
                 :status,
                 :health_status,
                 :eligibility_status,
                 :disabled_at,
                 :metadata
               ])
             )

      assert assignment.disabled_at == nil,
             inspect(
               Map.take(assignment, [
                 :status,
                 :health_status,
                 :eligibility_status,
                 :disabled_at,
                 :metadata
               ])
             )
    end
  end

  def handle_assignment_update_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    if metadata[:repo] == Repo and metadata[:source] == "pool_upstream_assignments" do
      send(test_pid, {handler_id, %{params: metadata[:params]}})
    end
  end

  def handle_blocking_assignment_update_event(
        _event,
        _measurements,
        metadata,
        {handler_id, test_pid, release_ref}
      ) do
    if metadata[:repo] == Repo and metadata[:source] == "pool_upstream_assignments" and
         metadata[:query] |> to_string() |> String.trim_leading() |> String.starts_with?("UPDATE") do
      :telemetry.detach(handler_id)
      send(test_pid, {:assignment_update_before_commit, release_ref, self()})

      receive do
        {:release_assignment_update, ^release_ref} -> :ok
      end
    end
  end

  def handle_blocking_terminal_priming_update_event(
        _event,
        _measurements,
        metadata,
        {handler_id, test_pid, release_ref}
      ) do
    terminal_priming_update? =
      metadata[:repo] == Repo and metadata[:source] == "pool_upstream_assignments" and
        metadata[:query] |> to_string() |> String.trim_leading() |> String.starts_with?("UPDATE") and
        query_params_contain?(metadata, "quota_priming") and
        query_params_contain?(metadata, "known")

    if terminal_priming_update? do
      :telemetry.detach(handler_id)
      send(test_pid, {:terminal_priming_update_before_commit, release_ref, self()})

      receive do
        {:release_assignment_update, ^release_ref} -> :ok
      end
    end
  end

  def handle_blocking_quota_notify_event(
        _event,
        _measurements,
        metadata,
        {handler_id, test_pid, release_ref}
      ) do
    quota_notify? =
      metadata[:repo] == Repo and
        metadata[:query] |> to_string() |> String.contains?("pg_notify") and
        query_params_contain?(metadata, "upstream_quota_windows_updated")

    if quota_notify? do
      :telemetry.detach(handler_id)
      send(test_pid, {:quota_notify_before_return, release_ref, self()})

      receive do
        {:release_quota_notify, ^release_ref} -> :ok
      end
    end
  end

  def handle_blocking_stale_priming_update_event(
        _event,
        _measurements,
        metadata,
        {handler_id, test_pid, release_ref}
      ) do
    stale_priming_update? =
      metadata[:repo] == Repo and metadata[:source] == "pool_upstream_assignments" and
        metadata[:query] |> to_string() |> String.trim_leading() |> String.starts_with?("UPDATE") and
        query_params_contain?(metadata, "quota_priming") and
        query_params_contain?(metadata, "runtime_timeout")

    if stale_priming_update? do
      :telemetry.detach(handler_id)
      send(test_pid, {:stale_priming_update_before_commit, release_ref, self()})

      receive do
        {:release_assignment_update, ^release_ref} -> :ok
      end
    end
  end

  defp query_params_contain?(metadata, expected) do
    metadata
    |> Map.get(:params, [])
    |> Enum.any?(&query_param_contains?(&1, expected))
  end

  defp query_param_contains?(value, expected) when is_binary(value) do
    value == expected or decoded_query_param_contains?(Jason.decode(value), expected)
  end

  defp query_param_contains?(%{} = value, expected) when not is_struct(value) do
    Enum.any?(value, fn {key, nested_value} ->
      query_param_contains?(key, expected) or query_param_contains?(nested_value, expected)
    end)
  end

  defp query_param_contains?(value, expected) when is_list(value) do
    Enum.any?(value, &query_param_contains?(&1, expected))
  end

  defp query_param_contains?(_value, _expected), do: false

  defp decoded_query_param_contains?({:ok, value}, expected),
    do: query_param_contains?(value, expected)

  defp decoded_query_param_contains?({:error, _reason}, _expected), do: false

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

  defp scheduled_expiry_reconciliation_fixture(opts \\ []) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    payload = scheduled_expiry_usage_payload(observed_at, opts)

    upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, payload}
         }}
      )

    {pool, assignment} = active_usage_probe_assignment(upstream)
    identity = Repo.get!(UpstreamIdentity, assignment.upstream_identity_id)

    identity =
      if Keyword.get(opts, :policy_enabled?, true) do
        enable_scheduled_expiry_policy!(
          identity,
          Keyword.get(opts, :policy_attrs, %{})
        )
      else
        identity
      end

    %{pool: pool, assignment: assignment, identity: identity, upstream: upstream}
  end

  defp scheduled_expiry_usage_payload(observed_at, opts \\ []) do
    expires_at = observed_at |> DateTime.add(1, :hour) |> DateTime.to_iso8601()
    granted_at = observed_at |> DateTime.add(-1, :day) |> DateTime.to_iso8601()

    reset_credits =
      if Keyword.get(opts, :expiration?, true) do
        %{
          "available_count" => 1,
          "credits" => [
            %{
              "status" => "available",
              "expires_at" => expires_at,
              "granted_at" => granted_at
            }
          ]
        }
      else
        %{"available_count" => 1}
      end

    rate_limit =
      case Keyword.get(opts, :weekly_used_percent, 25) do
        nil ->
          %{}

        used_percent ->
          %{
            "secondary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => 604_800,
              "reset_at" =>
                observed_at
                |> DateTime.add(
                  Keyword.get(opts, :weekly_reset_after_seconds, 2 * 60 * 60),
                  :second
                )
                |> DateTime.to_iso8601()
            }
          }
      end

    %{
      "plan_type" => "pro",
      "rate_limit" => rate_limit,
      "rate_limit_reset_credits" => reset_credits
    }
  end

  defp scheduled_saved_reset_metadata(observed_at, source) do
    observed_at_iso = DateTime.to_iso8601(observed_at)
    expires_at = observed_at |> DateTime.add(1, :hour) |> DateTime.to_iso8601()

    %{
      "status" => "reported",
      "available_count" => 1,
      "source" => source,
      "path_style" => "codex_api",
      "observed_at" => observed_at_iso,
      "usage_path" => "/api/codex/usage",
      "available_expires_at" => [expires_at],
      "available_expirations" => [
        %{"expires_at" => expires_at, "first_seen_at" => observed_at_iso}
      ],
      "next_expires_at" => expires_at,
      "expires_observed_at" => observed_at_iso,
      "expires_refresh_attempted_at" => observed_at_iso,
      "reason" => nil
    }
  end

  defp scheduled_weekly_window_attrs(observed_at, used_percent, reset_after_seconds) do
    %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: used_percent,
      reset_at: DateTime.add(observed_at, reset_after_seconds, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: observed_at
    }
  end

  defp enable_scheduled_expiry_policy!(identity, attrs \\ %{}) do
    identity
    |> UpstreamIdentity.changeset(
      Map.merge(
        %{
          saved_reset_auto_redeem_enabled: true,
          saved_reset_auto_redeem_min_blocked_minutes: 60,
          saved_reset_auto_redeem_keep_credits: 0
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  defp scheduled_identity_reconciliation_args(pool, assignment, identity) do
    %{
      "pool_id" => pool.id,
      "pool_upstream_assignment_id" => assignment.id,
      "upstream_identity_id" => identity.id,
      "target_kind" => "upstream_identity",
      "trigger_kind" => "scheduled"
    }
  end

  defp scheduled_saved_reset_redemption_jobs do
    Repo.all(
      from(job in Oban.Job,
        where: job.worker == ^worker_name(SavedResetRedemptionWorker),
        order_by: [asc: job.id]
      )
    )
  end

  defp scheduled_consume_count(upstream) do
    upstream
    |> FakeUpstream.requests()
    |> Enum.count(&String.contains?(&1.path, "/rate-limit-reset-credits/consume"))
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
