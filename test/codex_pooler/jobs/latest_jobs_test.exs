defmodule CodexPooler.Jobs.LatestJobsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Jobs

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    CatalogSyncWorker,
    RuntimeStateCleanupWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "latest jobs listing" do
    test "returns the newest 15 jobs ordered by inserted_at then id" do
      base_time = ~U[2026-05-04 10:00:00Z]

      jobs =
        for index <- 1..101 do
          inserted_at = DateTime.add(base_time, index, :second)
          insert_listing_job(index, inserted_at: inserted_at)
        end

      same_inserted_at = ~U[2026-05-04 12:00:00Z]
      older_tie = insert_listing_job(102, inserted_at: same_inserted_at)
      newer_tie = insert_listing_job(103, inserted_at: same_inserted_at)

      results = Jobs.list_system_jobs()

      assert length(results) == 15
      assert Enum.map(results, & &1.id) |> Enum.take(2) == [newer_tie.id, older_tie.id]
      refute Enum.any?(results, &(&1.id == hd(jobs).id))

      assert Enum.all?(results, &safe_job_shape?/1)
    end

    test "returns only safe metadata when args and meta contain sensitive strings" do
      inserted_at = ~U[2026-05-04 10:00:00Z]

      job =
        insert_listing_job(
          1,
          inserted_at: inserted_at,
          args: %{
            "token" => "secret-token-123",
            "prompt" => "raw-prompt-text"
          },
          meta: %{
            "authorization" => "authorization-bearer-value"
          }
        )

      assert [result] = Jobs.list_system_jobs()
      assert result.id == job.id
      assert safe_job_shape?(result)

      serialized = inspect(result)
      refute serialized =~ "secret-token-123"
      refute serialized =~ "raw-prompt-text"
      refute serialized =~ "authorization-bearer-value"
    end

    test "owner scope sees global latest jobs while instance admins see no jobs" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "jobs-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      visible_pool = pool_fixture()
      hidden_pool = pool_fixture(%{status: "disabled"})

      %{identity: visible_identity, assignment: visible_assignment} =
        upstream_assignment_fixture(visible_pool, %{assignment_label: "Visible assignment"})

      %{identity: hidden_identity, assignment: hidden_assignment} =
        upstream_assignment_fixture(hidden_pool, %{assignment_label: "Hidden assignment"})

      visible_job =
        insert_listing_job(1,
          inserted_at: ~U[2026-05-04 10:00:00Z],
          args: %{
            "pool_id" => visible_pool.id,
            "pool_upstream_assignment_id" => visible_assignment.id
          }
        )

      hidden_job =
        insert_listing_job(2,
          inserted_at: ~U[2026-05-04 10:01:00Z],
          args: %{
            "pool_id" => hidden_pool.id,
            "pool_upstream_assignment_id" => hidden_assignment.id
          }
        )

      rollup_job =
        insert_listing_job(3,
          inserted_at: ~U[2026-05-04 10:02:00Z],
          args: %{"rollup_date" => "2026-05-03"}
        )

      visible_identity_job =
        insert_listing_job(4,
          worker: TokenRefreshWorker,
          inserted_at: ~U[2026-05-04 10:03:00Z],
          args: %{"upstream_identity_id" => visible_identity.id}
        )

      hidden_identity_job =
        insert_listing_job(5,
          worker: TokenRefreshWorker,
          inserted_at: ~U[2026-05-04 10:04:00Z],
          args: %{"upstream_identity_id" => hidden_identity.id}
        )

      assert Enum.map(Jobs.list_latest_jobs(scope), & &1.id) == [
               hidden_identity_job.id,
               visible_identity_job.id,
               rollup_job.id,
               hidden_job.id,
               visible_job.id
             ]

      assert %{
               latest: %{id: latest_id},
               open: [_open | _],
               unresolved_failures: []
             } = Jobs.worker_job_summary(scope, [worker_name(TokenRefreshWorker)])

      assert latest_id == hidden_identity_job.id

      %{user: admin} = operator_fixture(scope, %{"email" => "jobs-admin@example.com"})
      admin_scope = Scope.for_user(admin, ["instance_admin"])

      assert Jobs.list_latest_jobs(admin_scope) == []

      assert Jobs.worker_job_summary(admin_scope, [worker_name(TokenRefreshWorker)]) == %{
               latest: nil,
               latest_success: nil,
               latest_failure: nil,
               pending: nil,
               open: [],
               unresolved_failures: []
             }

      memberless_user = user_fixture(%{"email" => "jobs-memberless@example.com"})

      assert Jobs.list_latest_jobs(Scope.for_user(memberless_user, [])) == []
    end

    test "system scope still returns safe system jobs for internal callers" do
      visible_pool = pool_fixture()
      hidden_pool = pool_fixture(%{status: "disabled"})

      %{identity: visible_identity, assignment: visible_assignment} =
        upstream_assignment_fixture(visible_pool, %{assignment_label: "Visible assignment"})

      %{identity: hidden_identity, assignment: hidden_assignment} =
        upstream_assignment_fixture(hidden_pool, %{assignment_label: "Hidden assignment"})

      visible_job =
        insert_listing_job(1,
          inserted_at: ~U[2026-05-04 10:00:00Z],
          args: %{
            "pool_id" => visible_pool.id,
            "pool_upstream_assignment_id" => visible_assignment.id
          }
        )

      hidden_job =
        insert_listing_job(2,
          inserted_at: ~U[2026-05-04 10:01:00Z],
          args: %{
            "pool_id" => hidden_pool.id,
            "pool_upstream_assignment_id" => hidden_assignment.id
          }
        )

      rollup_job =
        insert_listing_job(3,
          inserted_at: ~U[2026-05-04 10:02:00Z],
          args: %{"rollup_date" => "2026-05-03"}
        )

      visible_identity_job =
        insert_listing_job(4,
          worker: TokenRefreshWorker,
          inserted_at: ~U[2026-05-04 10:03:00Z],
          args: %{"upstream_identity_id" => visible_identity.id}
        )

      hidden_identity_job =
        insert_listing_job(5,
          worker: TokenRefreshWorker,
          inserted_at: ~U[2026-05-04 10:04:00Z],
          args: %{"upstream_identity_id" => hidden_identity.id}
        )

      assert Enum.map(Jobs.list_latest_jobs(:system), & &1.id) == [
               hidden_identity_job.id,
               visible_identity_job.id,
               rollup_job.id,
               hidden_job.id,
               visible_job.id
             ]
    end

    test "summarizes worker jobs without bounded history loss and resolves failures by target" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "jobs-worker-owner@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture()

      %{assignment: assignment} =
        upstream_assignment_fixture(pool, %{assignment_label: "Worker assignment"})

      unresolved_pool = pool_fixture()

      catalog_job =
        insert_listing_job(1,
          worker: CatalogSyncWorker,
          state: "completed",
          inserted_at: ~U[2026-05-04 10:00:00Z],
          completed_at: ~U[2026-05-04 10:01:00Z],
          args: %{"pool_id" => pool.id}
        )

      for index <- 2..60 do
        insert_listing_job(index,
          worker: AccountReconciliationWorker,
          inserted_at: DateTime.add(~U[2026-05-04 11:00:00Z], index, :second),
          args: %{"pool_id" => pool.id, "pool_upstream_assignment_id" => assignment.id}
        )
      end

      for index <- 61..90 do
        insert_listing_job(index,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: DateTime.add(~U[2026-05-04 12:00:00Z], index, :second),
          discarded_at: DateTime.add(~U[2026-05-04 12:01:00Z], index, :second),
          args: %{"pool_id" => pool.id}
        )
      end

      unresolved_failure =
        insert_listing_job(90,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 12:30:00Z],
          discarded_at: ~U[2026-05-04 12:31:00Z],
          args: %{"pool_id" => unresolved_pool.id}
        )

      resolved_failure =
        insert_listing_job(91,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 13:00:00Z],
          discarded_at: ~U[2026-05-04 13:01:00Z],
          args: %{"pool_id" => pool.id}
        )

      insert_listing_job(92,
        worker: CatalogSyncWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 14:00:00Z],
        completed_at: ~U[2026-05-04 14:01:00Z],
        args: %{"pool_id" => pool.id}
      )

      assert resolved_failure.id

      assert %{
               latest: %{state: "completed"},
               latest_success: %{id: success_id},
               latest_failure: %{state: "discarded"},
               pending: nil,
               open: [],
               unresolved_failures: unresolved_failures
             } = Jobs.worker_job_summary(scope, [worker_name(CatalogSyncWorker)])

      refute success_id == catalog_job.id
      assert Enum.map(unresolved_failures, & &1.state) == ["discarded"]
      assert Enum.map(unresolved_failures, & &1.id) == [unresolved_failure.id]
      refute Enum.any?(unresolved_failures, &(&1.id == resolved_failure.id))
    end

    @tag :latest
    test "grouped worker summaries preserve latest and pending same-timestamp tie-breaks" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])
      same_inserted_at = ~U[2026-05-04 12:00:00Z]
      same_scheduled_at = ~U[2026-05-04 13:00:00Z]

      older_latest =
        insert_listing_job(1,
          worker: CatalogSyncWorker,
          state: "completed",
          inserted_at: same_inserted_at,
          completed_at: ~U[2026-05-04 12:01:00Z]
        )

      newer_latest =
        insert_listing_job(2,
          worker: CatalogSyncWorker,
          state: "completed",
          inserted_at: same_inserted_at,
          completed_at: ~U[2026-05-04 12:02:00Z]
        )

      older_pending =
        insert_listing_job(3,
          worker: TokenRefreshWorker,
          state: "scheduled",
          inserted_at: ~U[2026-05-04 11:00:00Z],
          scheduled_at: same_scheduled_at
        )

      newer_pending =
        insert_listing_job(4,
          worker: TokenRefreshWorker,
          state: "scheduled",
          inserted_at: ~U[2026-05-04 11:01:00Z],
          scheduled_at: same_scheduled_at
        )

      summaries =
        Jobs.worker_job_summaries_by_group(scope, [
          worker_group(:catalog_card, [CatalogSyncWorker]),
          worker_group(:token_refresh_card, [TokenRefreshWorker])
        ])

      assert Map.keys(summaries) == [:catalog_card, :token_refresh_card]
      refute Map.has_key?(summaries, worker_name(CatalogSyncWorker))
      assert summaries.catalog_card.latest.id == newer_latest.id
      assert summaries.catalog_card.latest_success.id == newer_latest.id
      refute summaries.catalog_card.latest.id == older_latest.id
      assert summaries.token_refresh_card.pending.id == newer_pending.id
      refute summaries.token_refresh_card.pending.id == older_pending.id
    end

    @tag :latest
    test "grouped worker summaries preserve latest-style category winners across overlapping groups" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])
      success_inserted_at = ~U[2026-05-04 12:00:00Z]
      failure_inserted_at = ~U[2026-05-04 12:10:00Z]

      older_catalog_success =
        insert_listing_job(1,
          worker: CatalogSyncWorker,
          state: "completed",
          inserted_at: success_inserted_at,
          completed_at: ~U[2026-05-04 12:01:00Z],
          args: %{"prompt" => "raw prompt must not project", "token" => "hidden-token"},
          meta: %{"authorization" => "Bearer hidden"}
        )

      newer_catalog_success =
        insert_listing_job(2,
          worker: CatalogSyncWorker,
          state: "completed",
          inserted_at: success_inserted_at,
          completed_at: ~U[2026-05-04 12:02:00Z]
        )

      older_catalog_failure =
        insert_listing_job(3,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: failure_inserted_at,
          discarded_at: ~U[2026-05-04 12:11:00Z]
        )

      newer_catalog_failure =
        insert_listing_job(4,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: failure_inserted_at,
          discarded_at: ~U[2026-05-04 12:12:00Z]
        )

      token_success =
        insert_listing_job(5,
          worker: TokenRefreshWorker,
          state: "completed",
          inserted_at: ~U[2026-05-04 12:05:00Z],
          completed_at: ~U[2026-05-04 12:06:00Z]
        )

      token_latest =
        insert_listing_job(6,
          worker: TokenRefreshWorker,
          state: "available",
          inserted_at: ~U[2026-05-04 12:20:00Z],
          scheduled_at: ~U[2026-05-04 12:30:00Z]
        )

      summaries =
        Jobs.worker_job_summaries_by_group(scope, [
          worker_group(:catalog_card, [CatalogSyncWorker]),
          worker_group("overlap-card", [CatalogSyncWorker, TokenRefreshWorker]),
          worker_group(:missing_card, [AccountReconciliationWorker])
        ])

      assert Map.keys(summaries) == [:catalog_card, :missing_card, "overlap-card"]

      assert summaries.catalog_card.latest.id == newer_catalog_failure.id

      assert DateTime.compare(summaries.catalog_card.latest.inserted_at, failure_inserted_at) ==
               :eq

      assert summaries.catalog_card.latest_success.id == newer_catalog_success.id

      assert DateTime.compare(
               summaries.catalog_card.latest_success.inserted_at,
               success_inserted_at
             ) ==
               :eq

      assert summaries.catalog_card.latest_failure.id == newer_catalog_failure.id

      assert DateTime.compare(
               summaries.catalog_card.latest_failure.inserted_at,
               failure_inserted_at
             ) ==
               :eq

      refute summaries.catalog_card.latest_success.id == older_catalog_success.id
      refute summaries.catalog_card.latest_failure.id == older_catalog_failure.id

      overlap_summary = Map.fetch!(summaries, "overlap-card")
      assert overlap_summary.latest.id == token_latest.id
      assert DateTime.compare(overlap_summary.latest.inserted_at, token_latest.inserted_at) == :eq
      assert overlap_summary.latest_success.id == token_success.id

      assert DateTime.compare(
               overlap_summary.latest_success.inserted_at,
               token_success.inserted_at
             ) ==
               :eq

      assert overlap_summary.latest_failure.id == newer_catalog_failure.id

      assert summaries.missing_card.latest == nil
      assert summaries.missing_card.latest_success == nil
      assert summaries.missing_card.latest_failure == nil

      assert Enum.all?(
               [
                 summaries.catalog_card.latest,
                 summaries.catalog_card.latest_success,
                 summaries.catalog_card.latest_failure,
                 overlap_summary.latest,
                 overlap_summary.latest_success,
                 overlap_summary.latest_failure
               ],
               &safe_job_shape?/1
             )

      serialized = inspect([summaries.catalog_card, overlap_summary])
      refute serialized =~ "raw prompt must not project"
      refute serialized =~ "hidden-token"
      refute serialized =~ "Bearer hidden"
    end

    test "grouped worker summaries preserve pending winner and open-job ordering across groups" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])
      same_scheduled_at = ~U[2026-05-04 12:00:00Z]

      catalog_later_open =
        insert_listing_job(1,
          worker: CatalogSyncWorker,
          state: "available",
          inserted_at: ~U[2026-05-04 10:00:00Z],
          scheduled_at: ~U[2026-05-04 13:00:00Z]
        )

      older_catalog_pending =
        insert_listing_job(2,
          worker: CatalogSyncWorker,
          state: "scheduled",
          inserted_at: ~U[2026-05-04 10:01:00Z],
          scheduled_at: same_scheduled_at
        )

      newer_catalog_pending =
        insert_listing_job(3,
          worker: CatalogSyncWorker,
          state: "executing",
          inserted_at: ~U[2026-05-04 10:02:00Z],
          scheduled_at: same_scheduled_at
        )

      token_open =
        insert_listing_job(4,
          worker: TokenRefreshWorker,
          state: "retryable",
          inserted_at: ~U[2026-05-04 10:03:00Z],
          scheduled_at: ~U[2026-05-04 12:30:00Z]
        )

      summaries =
        Jobs.worker_job_summaries_by_group(scope, [
          worker_group(:catalog_card, [CatalogSyncWorker]),
          worker_group(:overlap_card, [CatalogSyncWorker, TokenRefreshWorker]),
          worker_group(:missing_card, [AccountReconciliationWorker])
        ])

      assert summaries.catalog_card.pending.id == newer_catalog_pending.id

      assert Enum.map(summaries.catalog_card.open, & &1.id) == [
               newer_catalog_pending.id,
               older_catalog_pending.id,
               catalog_later_open.id
             ]

      assert summaries.overlap_card.pending.id == newer_catalog_pending.id

      assert Enum.map(summaries.overlap_card.open, & &1.id) == [
               newer_catalog_pending.id,
               older_catalog_pending.id,
               token_open.id,
               catalog_later_open.id
             ]

      assert summaries.missing_card.pending == nil
      assert summaries.missing_card.open == []
      assert Enum.all?(summaries.overlap_card.open, &safe_job_shape?/1)
    end

    test "grouped worker summaries support overlapping worker groups and empty group entries" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])

      catalog_job =
        insert_listing_job(1,
          worker: CatalogSyncWorker,
          state: "completed",
          inserted_at: ~U[2026-05-04 10:00:00Z],
          completed_at: ~U[2026-05-04 10:01:00Z]
        )

      token_job =
        insert_listing_job(2,
          worker: TokenRefreshWorker,
          state: "completed",
          inserted_at: ~U[2026-05-04 10:05:00Z],
          completed_at: ~U[2026-05-04 10:06:00Z]
        )

      summaries =
        Jobs.worker_job_summaries_by_group(scope, [
          worker_group(:catalog_only, [CatalogSyncWorker]),
          worker_group(:overlap, [CatalogSyncWorker, TokenRefreshWorker]),
          worker_group(:empty_group, [AccountReconciliationWorker])
        ])

      assert summaries.catalog_only.latest.id == catalog_job.id
      assert summaries.overlap.latest.id == token_job.id

      assert summaries.empty_group == %{
               latest: nil,
               latest_success: nil,
               latest_failure: nil,
               pending: nil,
               open: [],
               unresolved_failures: []
             }
    end

    test "grouped worker summaries batch oban job selects across configured groups" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])

      insert_listing_job(1,
        worker: CatalogSyncWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        completed_at: ~U[2026-05-04 10:01:00Z]
      )

      insert_listing_job(2,
        worker: TokenRefreshWorker,
        state: "scheduled",
        inserted_at: ~U[2026-05-04 10:05:00Z],
        scheduled_at: ~U[2026-05-04 10:06:00Z]
      )

      insert_listing_job(3,
        worker: RuntimeStateCleanupWorker,
        state: "retryable",
        inserted_at: ~U[2026-05-04 10:10:00Z],
        attempted_at: ~U[2026-05-04 10:11:00Z]
      )

      groups = [
        worker_group(:catalog_card, [CatalogSyncWorker]),
        worker_group(:token_refresh_card, [TokenRefreshWorker]),
        worker_group(:runtime_cleanup_card, [RuntimeStateCleanupWorker]),
        worker_group(:mixed_card, [CatalogSyncWorker, TokenRefreshWorker]),
        worker_group(:missing_card, [AccountReconciliationWorker])
      ]

      {summaries, repo_queries} =
        capture_repo_queries(fn -> Jobs.worker_job_summaries_by_group(scope, groups) end)

      assert MapSet.new(Map.keys(summaries)) ==
               MapSet.new([
                 :catalog_card,
                 :missing_card,
                 :mixed_card,
                 :runtime_cleanup_card,
                 :token_refresh_card
               ])

      assert oban_jobs_select_count(repo_queries) <= 6
    end

    @tag :unresolved
    test "grouped worker summaries preserve unresolved failure target resolution semantics" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])
      resolved_pool = pool_fixture()

      %{assignment: resolved_assignment} = upstream_assignment_fixture(resolved_pool)
      %{assignment: different_assignment} = upstream_assignment_fixture(resolved_pool)
      resolved_identity = active_upstream_identity_fixture()
      different_identity = active_upstream_identity_fixture()
      %{api_key: resolved_api_key} = api_key_fixture(resolved_pool)
      %{api_key: different_api_key} = api_key_fixture(resolved_pool)

      resolved_args = %{
        "pool_id" => resolved_pool.id,
        "pool_upstream_assignment_id" => resolved_assignment.id,
        "upstream_identity_id" => resolved_identity.id,
        "api_key_id" => resolved_api_key.id,
        "rollup_date" => "2026-05-03"
      }

      resolved_failure =
        insert_listing_job(1,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 10:00:00Z],
          discarded_at: ~U[2026-05-04 10:01:00Z],
          args: resolved_args
        )

      insert_listing_job(2,
        worker: CatalogSyncWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:05:00Z],
        completed_at: ~U[2026-05-04 10:06:00Z],
        args: resolved_args
      )

      pool_mismatch_failure =
        insert_listing_job(3,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 11:00:00Z],
          discarded_at: ~U[2026-05-04 11:01:00Z],
          args: %{resolved_args | "pool_id" => pool_fixture().id}
        )

      assignment_mismatch_failure =
        insert_listing_job(4,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 11:00:00Z],
          discarded_at: ~U[2026-05-04 11:01:00Z],
          args: %{resolved_args | "pool_upstream_assignment_id" => different_assignment.id}
        )

      identity_mismatch_failure =
        insert_listing_job(5,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 11:00:00Z],
          discarded_at: ~U[2026-05-04 11:01:00Z],
          args: %{resolved_args | "upstream_identity_id" => different_identity.id}
        )

      api_key_mismatch_failure =
        insert_listing_job(6,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 11:00:00Z],
          discarded_at: ~U[2026-05-04 11:01:00Z],
          args: %{resolved_args | "api_key_id" => different_api_key.id}
        )

      rollup_mismatch_failure =
        insert_listing_job(7,
          worker: CatalogSyncWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 11:00:00Z],
          discarded_at: ~U[2026-05-04 11:01:00Z],
          args: %{resolved_args | "rollup_date" => "2026-05-04"}
        )

      insert_listing_job(8,
        worker: CatalogSyncWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 11:05:00Z],
        completed_at: ~U[2026-05-04 11:06:00Z],
        args: resolved_args
      )

      summary =
        Jobs.worker_job_summaries_by_group(scope, [
          worker_group(:catalog_card, [CatalogSyncWorker])
        ])
        |> Map.fetch!(:catalog_card)

      unresolved_ids = Enum.map(summary.unresolved_failures, & &1.id)

      assert unresolved_ids == [
               rollup_mismatch_failure.id,
               api_key_mismatch_failure.id,
               identity_mismatch_failure.id,
               assignment_mismatch_failure.id,
               pool_mismatch_failure.id
             ]

      refute resolved_failure.id in unresolved_ids
    end

    @tag :unresolved
    test "grouped worker summaries keep refresh-failed reconciliation failures actionable until recovery" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])

      healthy_pool =
        pool_fixture(%{name: "Healthy reconciliation", slug: "healthy-reconciliation"})

      refresh_failed_pool =
        pool_fixture(%{
          name: "Refresh failed reconciliation",
          slug: "refresh-failed-reconciliation"
        })

      recovered_pool =
        pool_fixture(%{name: "Recovered reconciliation", slug: "recovered-reconciliation"})

      reauth_pool = pool_fixture(%{name: "Reauth reconciliation", slug: "reauth-reconciliation"})

      %{assignment: healthy_assignment} = upstream_assignment_fixture(healthy_pool)

      %{identity: refresh_failed_identity, assignment: refresh_failed_assignment} =
        upstream_assignment_fixture(refresh_failed_pool, %{
          identity_status: "refresh_failed",
          health_status: "active",
          eligibility_status: "eligible"
        })

      %{identity: recovered_identity, assignment: recovered_assignment} =
        upstream_assignment_fixture(recovered_pool, %{
          identity_status: "refresh_failed",
          health_status: "active",
          eligibility_status: "eligible"
        })

      %{assignment: reauth_assignment} =
        upstream_assignment_fixture(reauth_pool, %{
          identity_status: "reauth_required",
          assignment_health_status: "disabled",
          assignment_eligibility_status: "ineligible"
        })

      visible_failure =
        insert_listing_job(1,
          worker: AccountReconciliationWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 10:00:00Z],
          discarded_at: ~U[2026-05-04 10:01:00Z],
          args: %{
            "pool_id" => healthy_pool.id,
            "pool_upstream_assignment_id" => healthy_assignment.id
          }
        )

      unresolved_refresh_failed_failure =
        insert_listing_job(2,
          worker: AccountReconciliationWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 10:30:00Z],
          discarded_at: ~U[2026-05-04 10:31:00Z],
          args: %{
            "pool_id" => refresh_failed_pool.id,
            "pool_upstream_assignment_id" => refresh_failed_assignment.id,
            "upstream_identity_id" => refresh_failed_identity.id
          },
          errors: [
            %{
              "attempt" => 1,
              "error" => "Quota refresh needs account reauthentication"
            }
          ]
        )

      recovered_refresh_failed_failure =
        insert_listing_job(3,
          worker: AccountReconciliationWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 10:45:00Z],
          discarded_at: ~U[2026-05-04 10:46:00Z],
          args: %{
            "pool_id" => recovered_pool.id,
            "pool_upstream_assignment_id" => recovered_assignment.id,
            "upstream_identity_id" => recovered_identity.id
          },
          errors: [
            %{
              "attempt" => 1,
              "error" => "Quota refresh needs account reauthentication"
            }
          ]
        )

      filtered_reauth_failure =
        insert_listing_job(4,
          worker: AccountReconciliationWorker,
          state: "discarded",
          inserted_at: ~U[2026-05-04 11:00:00Z],
          discarded_at: ~U[2026-05-04 11:01:00Z],
          args: %{
            "pool_id" => reauth_pool.id,
            "pool_upstream_assignment_id" => reauth_assignment.id
          }
        )

      assert {1, _rows} =
               from(identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
                 where: identity.id == ^recovered_identity.id
               )
               |> Repo.update_all(set: [status: "active"])

      insert_listing_job(5,
        worker: AccountReconciliationWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 11:30:00Z],
        completed_at: ~U[2026-05-04 11:31:00Z],
        args: %{
          "pool_id" => recovered_pool.id,
          "pool_upstream_assignment_id" => recovered_assignment.id,
          "upstream_identity_id" => recovered_identity.id
        }
      )

      summary =
        Jobs.worker_job_summaries_by_group(scope, [
          worker_group(:reconciliation_card, [AccountReconciliationWorker])
        ])
        |> Map.fetch!(:reconciliation_card)

      unresolved_ids = Enum.map(summary.unresolved_failures, & &1.id)

      assert unresolved_ids == [unresolved_refresh_failed_failure.id, visible_failure.id]
      refute filtered_reauth_failure.id in unresolved_ids
      refute recovered_refresh_failed_failure.id in unresolved_ids

      assert %{attention_state: :active_failure, target: target} =
               Enum.find(
                 summary.unresolved_failures,
                 &(&1.id == unresolved_refresh_failed_failure.id)
               )

      assert target.assignment_identity_status == "refresh_failed"
    end

    test "grouped worker summaries preserve the single-summary facade shape" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])

      insert_listing_job(1,
        worker: RuntimeStateCleanupWorker,
        state: "retryable",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:01:00Z]
      )

      workers = [worker_name(RuntimeStateCleanupWorker)]
      single_summary = Jobs.worker_job_summary(scope, workers)

      grouped_summary =
        Jobs.worker_job_summaries_by_group(scope, [
          %{key: :runtime_cleanup_card, workers: workers}
        ])
        |> Map.fetch!(:runtime_cleanup_card)

      assert grouped_summary == single_summary

      assert Enum.all?(
               [grouped_summary.latest, grouped_summary.latest_failure],
               &safe_job_shape?/1
             )
    end

    test "single-summary facade keeps empty and invalid scopes safe-empty" do
      job =
        insert_listing_job(1,
          worker: RuntimeStateCleanupWorker,
          state: "retryable",
          inserted_at: ~U[2026-05-04 10:00:00Z],
          attempted_at: ~U[2026-05-04 10:01:00Z]
        )

      assert Jobs.worker_job_summary(:system, []) == empty_worker_job_summary()

      assert Jobs.worker_job_summary(:invalid_scope, [worker_name(RuntimeStateCleanupWorker)]) ==
               empty_worker_job_summary()

      refute inspect(Jobs.worker_job_summary(:system, [])) =~ Integer.to_string(job.id)
    end

    test "grouped worker summaries preserve target metadata from the single-summary path" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{name: "Summary target pool", slug: "summary-target-pool"})

      %{identity: assignment_identity, assignment: assignment} =
        upstream_assignment_fixture(pool, %{
          account_label: "Assignment identity",
          assignment_label: "Summary assignment"
        })

      direct_identity = active_upstream_identity_fixture(%{account_label: "Direct identity"})
      %{api_key: api_key} = api_key_fixture(pool, %{display_name: "Summary API key"})

      cases = [
        {:pool_target, %{"pool_id" => pool.id}},
        {:assignment_target,
         %{"pool_id" => pool.id, "pool_upstream_assignment_id" => assignment.id}},
        {:upstream_identity_target, %{"upstream_identity_id" => direct_identity.id}},
        {:api_key_target, %{"pool_id" => pool.id, "api_key_id" => api_key.id}},
        {:rollup_target, %{"rollup_date" => "2026-05-03"}}
      ]

      for {group_key, args} <- cases do
        Repo.delete_all(Oban.Job)

        insert_listing_job(1,
          worker: CatalogSyncWorker,
          state: "completed",
          inserted_at: ~U[2026-05-04 10:00:00Z],
          completed_at: ~U[2026-05-04 10:01:00Z],
          args: args
        )

        workers = [worker_name(CatalogSyncWorker)]
        single_summary = Jobs.worker_job_summary(scope, workers)

        grouped_summary =
          Jobs.worker_job_summaries_by_group(scope, [%{key: group_key, workers: workers}])
          |> Map.fetch!(group_key)

        assert grouped_summary.latest.target == single_summary.latest.target
        assert safe_job_shape?(grouped_summary.latest)
      end

      assert assignment_identity.id
    end

    test "returns safe metadata for terminal and non-terminal Oban states" do
      base_time = ~U[2026-05-04 10:00:00Z]

      states = [
        {"available", []},
        {"scheduled", [scheduled_at: DateTime.add(base_time, 1_800, :second)]},
        {"completed",
         [attempted_at: base_time, completed_at: DateTime.add(base_time, 30, :second)]},
        {"retryable", [attempted_at: base_time]},
        {"discarded", [discarded_at: DateTime.add(base_time, 60, :second)]},
        {"cancelled", [cancelled_at: DateTime.add(base_time, 90, :second)]},
        {"suspended", []}
      ]

      for {{state, attrs}, index} <- Enum.with_index(states, 1) do
        insert_listing_job(
          index,
          Keyword.merge(attrs, state: state, inserted_at: DateTime.add(base_time, index, :second))
        )
      end

      results = Jobs.list_system_jobs()

      assert Enum.map(results, & &1.state) == [
               "suspended",
               "cancelled",
               "discarded",
               "retryable",
               "completed",
               "scheduled",
               "available"
             ]

      assert Enum.all?(results, &safe_job_shape?/1)
      assert Enum.find(results, &(&1.state == "scheduled")).scheduled_at
      assert Enum.find(results, &(&1.state == "retryable")).attention_state == :retry_pressure
      assert Enum.find(results, &(&1.state == "discarded")).attention_state == :active_failure
      assert Enum.find(results, &(&1.state == "completed")).attention_state == :healthy_context
      assert Enum.find(results, &(&1.state == "discarded")).discarded_at
      assert Enum.find(results, &(&1.state == "cancelled")).cancelled_at
    end
  end

  defp insert_listing_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{"index" => index})
    meta = Keyword.get(attrs, :meta, %{"source" => "listing-test"})

    assert {:ok, job} =
             args
             |> RuntimeStateCleanupWorker.new(meta: meta, unique: false)
             |> Oban.insert()

    updates =
      attrs
      |> Keyword.take([
        :worker,
        :state,
        :attempt,
        :max_attempts,
        :inserted_at,
        :scheduled_at,
        :attempted_at,
        :completed_at,
        :discarded_at,
        :cancelled_at
      ])
      |> Keyword.put_new(:state, "available")
      |> Keyword.put_new(:attempt, 0)
      |> Keyword.put_new(:max_attempts, 20)
      |> maybe_put_worker_name()
      |> Keyword.put(:inserted_at, inserted_at)

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end

  defp maybe_put_worker_name(updates) do
    if Keyword.has_key?(updates, :worker) do
      Keyword.update!(updates, :worker, &worker_name/1)
    else
      updates
    end
  end

  defp worker_group(key, workers), do: %{key: key, workers: Enum.map(workers, &worker_name/1)}

  defp worker_name(worker) when is_atom(worker),
    do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp worker_name(worker) when is_binary(worker), do: worker

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, System.unique_integer([:positive])}

    handler = fn _event, _measurements, metadata, _config ->
      if metadata[:repo] == Repo do
        send(test_pid, {
          handler_id,
          %{
            source: normalize_query_metadata(metadata[:source]),
            query: normalize_query_metadata(metadata[:query])
          }
        })
      end
    end

    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], handler, nil)

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_repo_query_events(handler_id, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp oban_jobs_select_count(events) do
    Enum.count(events, fn event ->
      event.source == "oban_jobs" and
        event.query |> String.trim_leading() |> String.upcase() |> String.starts_with?("SELECT")
    end)
  end

  defp normalize_query_metadata(nil), do: "unknown"
  defp normalize_query_metadata(value) when is_binary(value), do: value
  defp normalize_query_metadata(value), do: to_string(value)

  defp empty_worker_job_summary do
    %{
      latest: nil,
      latest_success: nil,
      latest_failure: nil,
      pending: nil,
      open: [],
      unresolved_failures: []
    }
  end

  defp user_fixture(attrs) do
    %User{}
    |> User.bootstrap_changeset(valid_bootstrap_attributes(attrs))
    |> Repo.insert!()
  end

  defp safe_job_shape?(job) do
    job |> Map.keys() |> MapSet.new() |> MapSet.equal?(MapSet.new(safe_job_keys()))
  end

  defp safe_job_keys do
    [
      :id,
      :state,
      :errors,
      :max_attempts,
      :queue,
      :worker,
      :target,
      :inserted_at,
      :attempt,
      :attention_state,
      :scheduled_at,
      :attempted_at,
      :completed_at,
      :discarded_at,
      :cancelled_at
    ]
  end
end
