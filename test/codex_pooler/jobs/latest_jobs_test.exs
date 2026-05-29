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
               active: [_active | _],
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
               active: [],
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
               active: [],
               unresolved_failures: unresolved_failures
             } = Jobs.worker_job_summary(scope, [worker_name(CatalogSyncWorker)])

      refute success_id == catalog_job.id
      assert Enum.map(unresolved_failures, & &1.state) == ["discarded"]
      assert Enum.map(unresolved_failures, & &1.id) == [unresolved_failure.id]
      refute Enum.any?(unresolved_failures, &(&1.id == resolved_failure.id))
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
      assert Enum.find(results, &(&1.state == "completed")).completed_at
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

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

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
      :scheduled_at,
      :attempted_at,
      :completed_at,
      :discarded_at,
      :cancelled_at
    ]
  end
end
