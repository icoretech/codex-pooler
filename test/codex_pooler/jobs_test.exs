defmodule CodexPooler.JobsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.DailyRollup
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.FakeUpstream
  alias CodexPooler.InstanceSettings
  alias CodexPooler.Jobs

  alias CodexPooler.Jobs.{
    AccountReconciliationEnqueueWorker,
    AccountReconciliationWorker,
    AlertEvaluationEnqueueWorker,
    AlertEvaluationWorker,
    CatalogSyncEnqueueWorker,
    CatalogSyncWorker,
    DailyRollupRebuildEnqueueWorker,
    DailyRollupRebuildWorker,
    PricingImportWorker,
    RuntimeStateCleanupWorker,
    TokenRefreshEnqueueWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Jobs.Schedule
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "worker execution policy" do
    test "uses the shared schedule catalog for Oban cron entries" do
      assert Application.get_env(:codex_pooler, Oban)[:shutdown_grace_period] ==
               :timer.seconds(55)

      assert Schedule.oban_crontab() == [
               {"*/30 * * * *", CatalogSyncEnqueueWorker},
               {"0 * * * *", PricingImportWorker},
               {"* * * * *", AccountReconciliationEnqueueWorker},
               {"*/5 * * * *", AlertEvaluationEnqueueWorker},
               {"*/15 * * * *", TokenRefreshEnqueueWorker},
               {"17 0 * * *", DailyRollupRebuildEnqueueWorker},
               {"*/15 * * * *", RuntimeStateCleanupWorker}
             ]

      worker_groups = Schedule.worker_groups()

      assert Enum.find(worker_groups, &(&1.key == :catalog_sync)).cadence == %{
               label: "Every 30 min",
               cron: "*/30 * * * *"
             }

      assert Enum.find(worker_groups, &(&1.key == :token_refresh)).cadence == %{
               label: "Every 15 min",
               cron: "*/15 * * * *"
             }

      assert Enum.find(worker_groups, &(&1.key == :token_refresh)).workers ==
               [
                 "CodexPooler.Jobs.TokenRefreshWorker",
                 "CodexPooler.Jobs.TokenRefreshEnqueueWorker"
               ]

      assert Enum.find(worker_groups, &(&1.key == :pricing_import)).cadence == %{
               label: "Hourly",
               cron: "0 * * * *"
             }

      assert Enum.find(worker_groups, &(&1.key == :alert_evaluation)).cadence == %{
               label: "Every 5 min",
               cron: "*/5 * * * *"
             }
    end

    test "bounds retries and execution time according to job cadence" do
      assert worker_max_attempts(AccountReconciliationWorker, %{
               "pool_id" => Ecto.UUID.generate(),
               "pool_upstream_assignment_id" => Ecto.UUID.generate()
             }) == 1

      assert AccountReconciliationWorker.timeout(%Oban.Job{}) == :timer.minutes(20)
      assert worker_max_attempts(AccountReconciliationEnqueueWorker, %{}) == 1
      assert AccountReconciliationEnqueueWorker.timeout(%Oban.Job{}) == :timer.seconds(30)

      assert worker_max_attempts(AlertEvaluationWorker, %{
               "alert_rule_id" => Ecto.UUID.generate(),
               "evaluation_window_started_at" => "2026-05-30T10:05:00Z"
             }) == 1

      assert AlertEvaluationWorker.timeout(%Oban.Job{}) == :timer.minutes(2)
      assert worker_max_attempts(AlertEvaluationEnqueueWorker, %{}) == 1
      assert AlertEvaluationEnqueueWorker.timeout(%Oban.Job{}) == :timer.seconds(30)

      assert worker_max_attempts(CatalogSyncWorker, %{"pool_id" => Ecto.UUID.generate()}) == 3
      assert CatalogSyncWorker.timeout(%Oban.Job{}) == :timer.minutes(15)
      assert worker_max_attempts(CatalogSyncEnqueueWorker, %{}) == 3
      assert CatalogSyncEnqueueWorker.timeout(%Oban.Job{}) == :timer.seconds(30)

      assert worker_max_attempts(PricingImportWorker, %{}) == 3
      assert PricingImportWorker.timeout(%Oban.Job{}) == :timer.minutes(2)

      assert worker_max_attempts(DailyRollupRebuildWorker, %{"rollup_date" => "2026-05-15"}) ==
               3

      assert DailyRollupRebuildWorker.timeout(%Oban.Job{}) == :timer.minutes(30)
      assert worker_max_attempts(DailyRollupRebuildEnqueueWorker, %{}) == 3
      assert DailyRollupRebuildEnqueueWorker.timeout(%Oban.Job{}) == :timer.seconds(30)

      assert worker_max_attempts(TokenRefreshWorker, %{
               "upstream_identity_id" => Ecto.UUID.generate()
             }) == 8

      assert TokenRefreshWorker.timeout(%Oban.Job{}) == :timer.seconds(45)
      assert worker_max_attempts(TokenRefreshEnqueueWorker, %{}) == 1
      assert TokenRefreshEnqueueWorker.timeout(%Oban.Job{}) == :timer.seconds(30)

      assert worker_max_attempts(RuntimeStateCleanupWorker, %{}) == 3
      assert RuntimeStateCleanupWorker.timeout(%Oban.Job{}) == :timer.minutes(5)
    end
  end

  describe "manual worker group enqueue" do
    test "fans out targetless catalog sync requests to active pools" do
      pool = pool_fixture()

      assert {:ok, %{inserted: [job], conflicts: [], errors: []}} =
               Jobs.enqueue_worker_group_now("catalog-sync", trigger_kind: "admin_jobs_live")

      assert job.args == %{"pool_id" => pool.id, "trigger_kind" => "manual"}
      assert [enqueued_job] = all_enqueued(worker: CatalogSyncWorker)
      assert enqueued_job.id == job.id
    end

    test "enqueues singleton worker groups without extra params" do
      assert {:ok, runtime_job} = Jobs.enqueue_worker_group_now(:runtime_cleanup)
      assert {:ok, pricing_job} = Jobs.enqueue_worker_group_now("pricing_import")

      assert runtime_job.worker == worker_name(RuntimeStateCleanupWorker)
      assert runtime_job.args == %{}
      assert pricing_job.worker == worker_name(PricingImportWorker)
      assert pricing_job.args == %{}
    end

    test "keeps target-scoped worker groups out of manual enqueue" do
      assert Jobs.worker_group_manual_enqueueable?(:runtime_cleanup)
      refute Jobs.worker_group_manual_enqueueable?("token-refresh")
      refute Jobs.worker_group_manual_enqueueable?("unknown-worker")

      assert {:error, :worker_group_requires_target} =
               Jobs.enqueue_worker_group_now("token-refresh")

      assert {:error, :unknown_worker_group} = Jobs.enqueue_worker_group_now("unknown-worker")
      assert [] = all_enqueued(worker: TokenRefreshWorker)
    end
  end

  describe "catalog jobs" do
    test "deduplicates duplicate catalog sync enqueue for the same pool" do
      pool = pool_fixture()

      assert {:ok, first_job} = Jobs.enqueue_catalog_sync(pool)
      assert {:ok, second_job} = Jobs.enqueue_catalog_sync(pool)

      refute first_job.conflict?
      assert second_job.conflict?
      assert first_job.id == second_job.id
      assert [job] = all_enqueued(worker: CatalogSyncWorker)
      assert job.args == %{"pool_id" => pool.id, "trigger_kind" => "scheduled"}
    end

    test "rejects catalog sync enqueue without a pool id" do
      assert {:error, :pool_id_required} = Jobs.enqueue_catalog_sync(%{})
      assert {:error, :pool_id_required} = Jobs.enqueue_catalog_sync(nil)
    end

    test "runs catalog sync through the public catalog context" do
      upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-job-mini"}]}))

      {pool, _assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      assert :ok = perform_job(CatalogSyncWorker, %{"pool_id" => pool.id})

      assert [model] = Catalog.list_models(pool)
      assert model.exposed_model_id == "gpt-job-mini"
    end

    test "returns retryable error when catalog sync records a failed run" do
      upstream = start_upstream(FakeUpstream.http_500_json_error())
      {pool, _assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      assert {:error, %{code: :catalog_sync_failed}} =
               perform_job(CatalogSyncWorker, %{"pool_id" => pool.id})
    end

    test "imports pricing snapshots from the published JSON catalog URL" do
      pricing_payload = %{
        "generated_at" => "2026-05-23T12:00:00Z",
        "models" => %{
          "gpt-job-pricing" => %{
            "model" => "gpt-job-pricing",
            "pricing_type" => "per_1m_tokens",
            "prices" => %{
              "standard" => %{
                "default" => %{"input" => 1.25, "output" => 10.0}
              }
            }
          }
        },
        "source" => "openai-json-pricing-test",
        "source_url" => "https://example.com/pricing"
      }

      upstream = start_upstream(FakeUpstream.json_response(pricing_payload))
      source_url = FakeUpstream.url(upstream)

      assert {:ok, _settings} =
               InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
                 "catalog" => %{"openai_pricing_url" => source_url}
               })

      assert :ok = perform_job(PricingImportWorker, %{})

      assert Repo.exists?(
               from snapshot in CodexPooler.Catalog.PricingSnapshot,
                 where:
                   snapshot.model_identifier == "gpt-job-pricing" and
                     snapshot.price_version == "2026-05-23T12:00:00Z:importer-format-1" and
                     snapshot.source_url == ^source_url
             )

      assert [%{method: "GET", path: "/"}] = FakeUpstream.requests(upstream)
    end
  end

  describe "account reconciliation jobs" do
    test "rejects reconciliation enqueue without a pool id" do
      assert {:error, :pool_id_required} = Jobs.enqueue_account_reconciliations(%{})
      assert {:error, :pool_id_required} = Jobs.enqueue_account_reconciliations(nil)
    end

    test "rejects malformed reconciliation enqueue refs with tagged errors" do
      assert {:error, :pool_id_required} =
               Jobs.enqueue_account_reconciliation(%{}, Ecto.UUID.generate())

      assert {:error, :pool_upstream_assignment_id_required} =
               Jobs.enqueue_account_reconciliation(Ecto.UUID.generate(), %{})

      assert [] = all_enqueued(worker: AccountReconciliationWorker)
    end

    test "rejects malformed assignment priming refs with tagged errors" do
      assert {:error, :pool_id_required} =
               Jobs.enqueue_assignment_priming(%{}, Ecto.UUID.generate())

      assert {:error, :pool_upstream_assignment_id_required} =
               Jobs.enqueue_assignment_priming(Ecto.UUID.generate(), %{})

      assert [] = all_enqueued(worker: AccountReconciliationWorker)
    end
  end

  describe "token refresh jobs" do
    test "rejects malformed token refresh refs with tagged errors" do
      assert {:error, :upstream_identity_id_required} = Jobs.enqueue_token_refresh(%{})
      assert {:error, :upstream_identity_id_required} = Jobs.enqueue_token_refresh(nil)
      assert [] = all_enqueued(worker: TokenRefreshWorker)
    end

    test "scheduled enqueue worker succeeds without candidates" do
      assert :ok = perform_job(TokenRefreshEnqueueWorker, %{})
      assert [] = all_enqueued(worker: TokenRefreshWorker)
    end

    test "scheduled enqueue worker succeeds when every target job conflicts" do
      {_pool, assignment} = active_assignment_fixture(%{})
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      assert {:ok, identity} =
               IdentityLifecycle.update_upstream_identity(identity, %{status: "refresh_due"})

      assert {:ok, first_job} = Jobs.enqueue_token_refresh(identity, trigger_kind: "manual")

      assert :ok = perform_job(TokenRefreshEnqueueWorker, %{})

      assert [job] = all_enqueued(worker: TokenRefreshWorker)
      assert job.id == first_job.id
      assert job.args["trigger_kind"] == "manual"
    end

    test "scheduled enqueue worker returns a sanitized error count when target inserts fail" do
      sensitive_error = "raw-provider-payload-do-not-render"

      original_config = Application.get_env(:codex_pooler, TokenRefreshEnqueueWorker)

      on_exit(fn ->
        case original_config do
          nil -> Application.delete_env(:codex_pooler, TokenRefreshEnqueueWorker)
          config -> Application.put_env(:codex_pooler, TokenRefreshEnqueueWorker, config)
        end
      end)

      Application.put_env(:codex_pooler, TokenRefreshEnqueueWorker,
        enqueue_fun: fn opts ->
          assert Keyword.fetch!(opts, :trigger_kind) == "scheduled"

          {:ok,
           %{
             inserted: [],
             conflicts: [],
             errors: [sensitive_error, %{refresh_token: sensitive_error}]
           }}
        end
      )

      result = perform_job(TokenRefreshEnqueueWorker, %{})

      assert {:error, {:enqueue_failed, 2}} = result
      refute inspect(result) =~ sensitive_error
      assert [] = all_enqueued(worker: TokenRefreshWorker)
    end
  end

  describe "rollup jobs" do
    test "rebuilds the requested daily rollup date" do
      date = Date.add(Date.utc_today(), -1)

      assert :ok =
               perform_job(DailyRollupRebuildWorker, %{"rollup_date" => Date.to_iso8601(date)})

      assert {:ok, 0} = CodexPooler.Accounting.rebuild_daily_rollups_for_date(date)
    end

    @tag :daily_rollup_rebuild_boundaries
    test "rebuilds non-empty daily rollups through Oban testing worker surface" do
      setup = accounting_setup()
      date = Date.utc_today()

      request =
        request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
          correlation_id: "daily-rollup-worker-surface",
          model_id: setup.model.id,
          status: "succeeded",
          retry_count: 1
        })

      ledger_entry_fixture(request, %{
        pool_upstream_assignment_id: setup.assignment.id,
        upstream_identity_id: setup.identity.id,
        total_tokens: 17,
        occurred_at: DateTime.new!(date, ~T[12:00:00.000000], "Etc/UTC")
      })

      Repo.delete_all(from rollup in DailyRollup, where: rollup.rollup_date == ^date)

      assert :ok =
               perform_job(DailyRollupRebuildWorker, %{"rollup_date" => Date.to_iso8601(date)})

      assert [rollup] =
               Repo.all(
                 from rollup in DailyRollup,
                   where:
                     rollup.rollup_date == ^date and rollup.dimension_kind == "api_key" and
                       rollup.api_key_id == ^setup.api_key.id
               )

      assert rollup.request_count == 1
      assert rollup.success_count == 1
      assert rollup.retry_count == 1
      assert rollup.total_tokens == 17
    end

    test "returns a tagged error for non-binary rollup dates" do
      assert {:error, :invalid_rollup_date} =
               perform_job(DailyRollupRebuildWorker, %{"rollup_date" => nil})
    end
  end

  describe "runtime cleanup jobs" do
    test "deduplicates overlapping cleanup jobs at the worker queue level" do
      assert {:ok, first_job} = Jobs.enqueue_runtime_state_cleanup()
      assert {:ok, second_job} = Jobs.enqueue_runtime_state_cleanup()

      refute first_job.conflict?
      assert second_job.conflict?
      assert first_job.id == second_job.id
      assert [job] = all_enqueued(worker: RuntimeStateCleanupWorker)
      assert job.args == %{}
    end

    test "finalizes stale running catalog syncs and account reconciliations" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_started_at = DateTime.add(now, -31, :minute)
      fresh_started_at = DateTime.add(now, -1, :minute)

      {stale_pool, stale_assignment} = active_assignment_fixture(%{})
      {fresh_pool, fresh_assignment} = active_assignment_fixture(%{})

      stale_run = insert_running_catalog_sync(stale_pool, started_at: stale_started_at)
      fresh_run = insert_running_catalog_sync(fresh_pool, started_at: fresh_started_at)

      assert {:ok, _assignment} =
               PoolAssignments.update_pool_assignment(stale_assignment, %{
                 metadata: %{
                   "quota_priming" => %{
                     "status" => "refreshing",
                     "trigger_kind" => "scheduled",
                     "started_at" => DateTime.to_iso8601(stale_started_at)
                   }
                 }
               })

      assert {:ok, _assignment} =
               PoolAssignments.update_pool_assignment(fresh_assignment, %{
                 metadata: %{
                   "quota_priming" => %{
                     "status" => "refreshing",
                     "trigger_kind" => "scheduled",
                     "started_at" => DateTime.to_iso8601(fresh_started_at)
                   }
                 }
               })

      assert {:ok,
              %{
                stale_catalog_sync_runs_failed: 1,
                stale_account_reconciliations_failed: 1
              }} = Jobs.cleanup_runtime_state(now)

      assert %{status: "failed", error_message: "catalog sync timed out before completion"} =
               Repo.get!(SyncRun, stale_run.id)

      assert %{status: "running"} = Repo.get!(SyncRun, fresh_run.id)

      stale_assignment = Repo.get!(PoolUpstreamAssignment, stale_assignment.id)
      assert stale_assignment.metadata["quota_priming"]["status"] == "failed"
      assert stale_assignment.metadata["quota_priming"]["reason"]["code"] == "runtime_timeout"

      fresh_assignment = Repo.get!(PoolUpstreamAssignment, fresh_assignment.id)
      assert fresh_assignment.metadata["quota_priming"]["status"] == "refreshing"
    end

    test "runtime cleanup recovers stale accounting reservations" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_admitted_at = DateTime.add(now, -7, :hour)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-cleanup-stale-reservation", now: stale_admitted_at}
               )

      assert {:ok,
              %{
                stale_reservations_released: 1,
                stale_reservations_settled: 0
              }} = Jobs.cleanup_runtime_state(now)

      assert Repo.get!(CodexPooler.Accounting.Request, reserved.request.id).last_error_code ==
               "stale_reservation_recovered"

      assert Accounting.list_ledger_entries_for_request(reserved.request.id)
             |> Enum.map(& &1.entry_kind)
             |> Enum.sort() == ["release", "reservation"]
    end

    test "scheduled reconciliation enqueue discards stale exhausted executing blockers" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_attempted_at = DateTime.add(now, -31, :minute)
      {pool, assignment} = active_assignment_fixture(%{})

      assert {:ok, stale_job} =
               %{
                 "pool_id" => pool.id,
                 "pool_upstream_assignment_id" => assignment.id,
                 "trigger_kind" => "scheduled"
               }
               |> AccountReconciliationWorker.new(unique: false)
               |> Oban.insert()

      {1, _rows} =
        from(job in Oban.Job, where: job.id == ^stale_job.id)
        |> Repo.update_all(
          set: [
            state: "executing",
            attempt: 1,
            max_attempts: 1,
            attempted_at: stale_attempted_at
          ]
        )

      assert {:ok, %{inserted: [fresh_job], conflicts: [], errors: []}} =
               Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled")

      assert fresh_job.id != stale_job.id
      assert fresh_job.args["pool_upstream_assignment_id"] == assignment.id
      assert Repo.get!(Oban.Job, stale_job.id).state == "discarded"
    end
  end

  defp insert_running_catalog_sync(pool, attrs) do
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

  defp worker_max_attempts(worker, args) do
    args
    |> worker.new()
    |> Ecto.Changeset.get_field(:max_attempts)
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
end
