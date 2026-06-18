defmodule CodexPoolerWeb.Admin.JobsReadModelTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Jobs

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    RuntimeStateCleanupWorker,
    TokenRefreshEnqueueWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.JobsReadModel

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "loads one owner-only overview explorer projection with normalized filters and selected job" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, ["instance_owner"])
    now = ~U[2026-06-02 10:30:00Z]

    selected_job =
      insert_job(1,
        worker: TokenRefreshWorker,
        queue: "jobs",
        state: "retryable",
        attempt: 3,
        inserted_at: ~U[2026-06-02 10:00:00Z],
        attempted_at: ~U[2026-06-02 10:01:00Z],
        args: %{
          "token" => "secret-token-123",
          "prompt" => "raw-prompt-text",
          "request_body" => "request-body-json",
          "auth_json" => "auth-json-refresh-token",
          "websocket_frame" => "websocket-frame-bytes"
        },
        meta: %{"cookie" => "cookie-header-value"},
        errors: [
          %{
            "at" => DateTime.to_iso8601(~U[2026-06-02 10:02:00Z]),
            "attempt" => 1,
            "error" => "stacktrace-with-secret"
          }
        ]
      )

    completed_job =
      insert_job(2,
        worker: RuntimeStateCleanupWorker,
        queue: "critical",
        state: "completed",
        inserted_at: ~U[2026-06-02 10:10:00Z],
        completed_at: ~U[2026-06-02 10:11:00Z]
      )

    projection =
      JobsReadModel.load(owner_scope,
        params: %{
          "worker" => worker_name(TokenRefreshWorker),
          "queue" => "jobs",
          "job_id" => Integer.to_string(selected_job.id)
        },
        now: now
      )

    assert %{
             overview: overview,
             explorer: explorer,
             filters: filters,
             form_values: form_values,
             filter_options: filter_options,
             filter_warnings: [],
             selected_job: %{id: selected_id}
           } = projection

    assert selected_id == selected_job.id
    assert overview.status == :attention_required
    assert overview.total == 1
    assert explorer == %{items: [projection.selected_job], total: 1, limit: 20, offset: 0}
    assert filters.worker == worker_name(TokenRefreshWorker)
    assert filters.queue == "jobs"
    assert filters.job_id == selected_job.id
    assert form_values["job_id"] == Integer.to_string(selected_job.id)

    worker_option_values = Enum.map(filter_options.worker, & &1.value)
    assert "" in worker_option_values
    assert worker_name(RuntimeStateCleanupWorker) in worker_option_values
    assert worker_name(TokenRefreshEnqueueWorker) in worker_option_values
    assert worker_name(TokenRefreshWorker) in worker_option_values

    assert filter_options.queue |> Enum.map(& &1.value) == ["", "critical", "jobs"]

    failure_summary = %{title: "Attempt 1", message: "stacktrace-with-[redacted]"}

    assert projection.selected_job.failure_summary == failure_summary
    assert overview.buckets.retry_pressure.newest.failure_summary == failure_summary
    assert projection.worker_jobs_by_group.token_refresh.latest.failure_summary == failure_summary

    assert projection.worker_jobs_by_group.token_refresh.latest_failure.failure_summary ==
             failure_summary

    refute Enum.any?(projection.explorer.items, &(&1.id == completed_job.id))
    refute Map.has_key?(projection, :recent_jobs)

    serialized = inspect(projection)
    refute serialized =~ "secret-token-123"
    refute serialized =~ "raw-prompt-text"
    refute serialized =~ "request-body-json"
    refute serialized =~ "auth-json-refresh-token"
    refute serialized =~ "websocket-frame-bytes"
    refute serialized =~ "cookie-header-value"
    refute serialized =~ "stacktrace-with-secret"
    refute serialized =~ ":args"
    refute serialized =~ ":meta"
    refute serialized =~ ":errors"
  end

  test "returns selected_job nil when normalized job_id is absent from the filtered page" do
    hidden_completed_job =
      insert_job(1,
        state: "completed",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        completed_at: ~U[2026-06-02 10:01:00Z]
      )

    projection =
      JobsReadModel.load(:system,
        params: %{"job_id" => Integer.to_string(hidden_completed_job.id)},
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert projection.explorer.items == []
    assert projection.selected_job == nil
    assert projection.filters.job_id == hidden_completed_job.id
  end

  test "default projection excludes discarded jobs resolved by a later target success" do
    resolved_target_id = Ecto.UUID.generate()
    unresolved_target_id = Ecto.UUID.generate()

    resolved_failure =
      insert_job(1,
        worker: TokenRefreshWorker,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        discarded_at: ~U[2026-06-02 10:01:00Z],
        args: %{"upstream_identity_id" => resolved_target_id}
      )

    insert_job(2,
      worker: TokenRefreshWorker,
      state: "completed",
      inserted_at: ~U[2026-06-02 10:05:00Z],
      completed_at: ~U[2026-06-02 10:06:00Z],
      args: %{"upstream_identity_id" => resolved_target_id}
    )

    unresolved_failure =
      insert_job(3,
        worker: TokenRefreshWorker,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:10:00Z],
        discarded_at: ~U[2026-06-02 10:11:00Z],
        args: %{"upstream_identity_id" => unresolved_target_id}
      )

    projection =
      JobsReadModel.load(:system,
        params: %{},
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert projection.overview.actionable_count == 1
    assert projection.overview.buckets.active_failure.count == 1
    assert Enum.map(projection.explorer.items, & &1.id) == [unresolved_failure.id]
    refute Enum.any?(projection.explorer.items, &(&1.id == resolved_failure.id))
  end

  test "default projection resolves account reconciliation failures by upstream identity" do
    pool = pool_fixture(%{name: "Identity Reconcile Pool", slug: "identity-reconcile-pool"})

    recovery_pool =
      pool_fixture(%{name: "Identity Recovery Pool", slug: "identity-recovery-pool"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Resolved identity account",
        assignment_label: "Resolved identity assignment"
      })

    insert_job(1,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-06-02 10:00:00Z],
      discarded_at: ~U[2026-06-02 10:01:00Z],
      args: %{
        "pool_id" => pool.id,
        "pool_upstream_assignment_id" => assignment.id,
        "trigger_kind" => "scheduled"
      },
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
        }
      ]
    )

    insert_job(2,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-06-02 10:02:00Z],
      discarded_at: ~U[2026-06-02 10:03:00Z],
      args: %{
        "pool_id" => pool.id,
        "pool_upstream_assignment_id" => assignment.id,
        "trigger_kind" => "scheduled"
      },
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, %{code: :pool_account_not_reconcilable, message: \"active pool assignment was not found for reconciliation\"}}"
        }
      ]
    )

    insert_job(3,
      worker: AccountReconciliationWorker,
      state: "completed",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-06-02 10:05:00Z],
      completed_at: ~U[2026-06-02 10:06:00Z],
      args: %{
        "pool_id" => recovery_pool.id,
        "upstream_identity_id" => identity.id,
        "target_kind" => "upstream_identity",
        "trigger_kind" => "scheduled"
      }
    )

    unresolved_pool =
      pool_fixture(%{name: "Unresolved Identity Pool", slug: "unresolved-identity-pool"})

    unresolved_recovery_pool =
      pool_fixture(%{
        name: "Unresolved Recovery Pool",
        slug: "unresolved-recovery-pool"
      })

    %{identity: unresolved_identity, assignment: unresolved_assignment} =
      upstream_assignment_fixture(unresolved_pool, %{
        account_label: "Unresolved identity account",
        assignment_label: "Unresolved identity assignment"
      })

    unresolved_failure =
      insert_job(4,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-06-02 10:07:00Z],
        discarded_at: ~U[2026-06-02 10:08:00Z],
        args: %{
          "pool_id" => unresolved_pool.id,
          "pool_upstream_assignment_id" => unresolved_assignment.id,
          "trigger_kind" => "scheduled"
        },
        errors: [
          %{
            "attempt" => 1,
            "error" =>
              "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: catalog_sync_failed\"}"
          }
        ]
      )

    insert_job(5,
      worker: AccountReconciliationWorker,
      state: "completed",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-06-02 10:10:00Z],
      completed_at: ~U[2026-06-02 10:11:00Z],
      args: %{
        "pool_id" => unresolved_recovery_pool.id,
        "upstream_identity_id" => unresolved_identity.id,
        "target_kind" => "upstream_identity",
        "trigger_kind" => "scheduled"
      }
    )

    projection =
      JobsReadModel.load(:system,
        params: %{},
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert projection.overview.actionable_count == 1
    assert Enum.map(projection.explorer.items, & &1.id) == [unresolved_failure.id]

    assert Enum.map(
             projection.worker_jobs_by_group.account_reconciliation.unresolved_failures,
             & &1.id
           ) == [unresolved_failure.id]
  end

  test "default projection excludes stale reauth-required account reconciliation failures" do
    pool = pool_fixture(%{name: "Reauth Pool", slug: "reauth-pool"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Stale reauth account",
        assignment_label: "Stale reauth assignment",
        identity_status: "reauth_required"
      })

    stale_failure =
      insert_job(1,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-06-02 10:00:00Z],
        discarded_at: ~U[2026-06-02 10:01:00Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "trigger_kind" => "scheduled"
        },
        errors: [
          %{
            "attempt" => 1,
            "error" =>
              "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
          }
        ]
      )

    identity_scoped_failure =
      insert_job(2,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-06-02 10:02:00Z],
        discarded_at: ~U[2026-06-02 10:03:00Z],
        args: %{
          "pool_id" => pool.id,
          "upstream_identity_id" => identity.id,
          "target_kind" => "upstream_identity",
          "trigger_kind" => "scheduled"
        },
        errors: [
          %{
            "attempt" => 1,
            "error" =>
              "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
          }
        ]
      )

    projection =
      JobsReadModel.load(:system,
        params: %{},
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert projection.overview.actionable_count == 0
    assert projection.overview.status == :empty
    assert projection.explorer.items == []
    assert projection.worker_jobs_by_group.account_reconciliation.latest_failure == nil
    refute projected_job_id?(projection, stale_failure.id)
    refute projected_job_id?(projection, identity_scoped_failure.id)
  end

  test "projects account reconciliation token-refresh recovery jobs with safe trigger metadata" do
    pool =
      pool_fixture(%{name: "Token Refresh Recovery Pool", slug: "token-refresh-recovery-pool"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recovery account",
        assignment_label: "Recovery assignment"
      })

    recovery_job =
      insert_job(1,
        worker: TokenRefreshWorker,
        queue: "jobs",
        state: "retryable",
        attempt: 2,
        max_attempts: 8,
        inserted_at: ~U[2026-06-02 10:04:00Z],
        attempted_at: ~U[2026-06-02 10:05:00Z],
        args: %{
          "upstream_identity_id" => identity.id,
          "trigger_kind" => "account_reconciliation_recovery",
          "provider_body" => "raw-provider-body-do-not-leak",
          "access_token" => "token-refresh-do-not-leak",
          "auth_json" => "auth-json-do-not-leak"
        },
        errors: [
          %{
            "attempt" => 2,
            "error" =>
              "provider failed with safe recovery context. safe credential punctuation context: secret=secret-value-do-not-leak ; secret_token=secret-token-do-not-leak, client_secret=client-secret-do-not-leak. safe punctuation context: id_token=token-id-do-not-leak, session_token=token-session-do-not-leak; api-token=token-api-do-not-leak nested_token=token-nested-do-not-leak. provider_body={\"access_token\":\"token-access-do-not-leak\",\"nested\":{\"refresh_token\":\"token-refresh-do-not-leak\"}} body=first token-refresh-do-not-leak second auth_json={\"refresh_token\":\"token-auth-json-do-not-leak\"}. escaped string context: auth_json=\"{\\\"refresh_token\\\":\\\"escaped-refresh-do-not-leak\\\",\\\"access_token\\\":\\\"escaped-access-do-not-leak\\\"}\" provider_body=\"{\\\"refresh_token\\\":\\\"escaped-provider-refresh-do-not-leak\\\"}\". spaced alias context: client_secret=space-client-secret-do-not-leak first second; password=space-password-do-not-leak tail words"
          }
        ]
      )

    projection =
      JobsReadModel.load(:system,
        params: %{
          "job_id" => Integer.to_string(recovery_job.id),
          "worker" => worker_name(TokenRefreshWorker)
        },
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert %{
             id: job_id,
             worker: worker,
             state: "retryable",
             trigger_kind: "account_reconciliation_recovery",
             target: %{
               upstream_identity_id: identity_id,
               direct_identity_label: "Recovery account",
               direct_identity_status: "active"
             }
           } = projection.selected_job

    assert job_id == recovery_job.id
    assert worker == worker_name(TokenRefreshWorker)
    assert identity_id == identity.id

    assert projection.worker_jobs_by_group.token_refresh.latest.trigger_kind ==
             "account_reconciliation_recovery"

    failure_message = projection.selected_job.failure_summary.message
    assert failure_message =~ "provider failed"
    assert failure_message =~ "safe recovery context"
    assert failure_message =~ "safe punctuation context"
    assert failure_message =~ "safe credential punctuation context"
    refute failure_message =~ "provider_body"
    refute failure_message =~ "body=first"
    refute failure_message =~ "auth_json"
    refute failure_message =~ "access_token"
    refute failure_message =~ "refresh_token"
    refute failure_message =~ "id_token"
    refute failure_message =~ "session_token"
    refute failure_message =~ "api-token"
    refute failure_message =~ "nested_token"
    refute failure_message =~ "secret="
    refute failure_message =~ "secret_token"
    refute failure_message =~ "client_secret"
    refute failure_message =~ "token-access-do-not-leak"
    refute failure_message =~ "token-refresh-do-not-leak"
    refute failure_message =~ "token-auth-json-do-not-leak"
    refute failure_message =~ "escaped-refresh-do-not-leak"
    refute failure_message =~ "escaped-access-do-not-leak"
    refute failure_message =~ "escaped-provider-refresh-do-not-leak"
    refute failure_message =~ "token-id-do-not-leak"
    refute failure_message =~ "token-session-do-not-leak"
    refute failure_message =~ "token-api-do-not-leak"
    refute failure_message =~ "token-nested-do-not-leak"
    refute failure_message =~ "secret-value-do-not-leak"
    refute failure_message =~ "secret-token-do-not-leak"
    refute failure_message =~ "client-secret-do-not-leak"
    refute failure_message =~ "space-client-secret-do-not-leak"
    refute failure_message =~ "space-password-do-not-leak"
    refute failure_message =~ "first second"
    refute failure_message =~ "tail words"

    grouped_failure_message =
      projection.worker_jobs_by_group.token_refresh.latest_failure.failure_summary.message

    assert grouped_failure_message =~ "safe punctuation context"
    assert grouped_failure_message =~ "safe credential punctuation context"
    refute grouped_failure_message =~ "provider_body"
    refute grouped_failure_message =~ "auth_json"
    refute grouped_failure_message =~ "access_token"
    refute grouped_failure_message =~ "refresh_token"
    refute grouped_failure_message =~ "secret="
    refute grouped_failure_message =~ "secret_token"
    refute grouped_failure_message =~ "client_secret"
    refute grouped_failure_message =~ "password"
    refute grouped_failure_message =~ "escaped-refresh-do-not-leak"
    refute grouped_failure_message =~ "escaped-access-do-not-leak"
    refute grouped_failure_message =~ "escaped-provider-refresh-do-not-leak"
    refute grouped_failure_message =~ "token-id-do-not-leak"
    refute grouped_failure_message =~ "token-session-do-not-leak"
    refute grouped_failure_message =~ "token-api-do-not-leak"
    refute grouped_failure_message =~ "token-nested-do-not-leak"
    refute grouped_failure_message =~ "secret-value-do-not-leak"
    refute grouped_failure_message =~ "secret-token-do-not-leak"
    refute grouped_failure_message =~ "client-secret-do-not-leak"
    refute grouped_failure_message =~ "space-client-secret-do-not-leak"
    refute grouped_failure_message =~ "space-password-do-not-leak"
    refute grouped_failure_message =~ "first second"
    refute grouped_failure_message =~ "tail words"

    serialized = inspect(projection)
    refute serialized =~ "raw-provider-body-do-not-leak"
    refute serialized =~ "token-access-do-not-leak"
    refute serialized =~ "token-refresh-do-not-leak"
    refute serialized =~ "token-auth-json-do-not-leak"
    refute serialized =~ "escaped-refresh-do-not-leak"
    refute serialized =~ "escaped-access-do-not-leak"
    refute serialized =~ "escaped-provider-refresh-do-not-leak"
    refute serialized =~ "token-id-do-not-leak"
    refute serialized =~ "token-session-do-not-leak"
    refute serialized =~ "token-api-do-not-leak"
    refute serialized =~ "token-nested-do-not-leak"
    refute serialized =~ "secret="
    refute serialized =~ "secret_token"
    refute serialized =~ "client_secret"
    refute serialized =~ "secret-value-do-not-leak"
    refute serialized =~ "secret-token-do-not-leak"
    refute serialized =~ "client-secret-do-not-leak"
    refute serialized =~ "space-client-secret-do-not-leak"
    refute serialized =~ "space-password-do-not-leak"
    refute serialized =~ "first second"
    refute serialized =~ "tail words"
    refute serialized =~ "auth-json-do-not-leak"
    refute serialized =~ ":args"
    refute serialized =~ ":errors"
  end

  test "drops blank trigger metadata from projected jobs" do
    blank_trigger_job =
      insert_job(1,
        worker: TokenRefreshWorker,
        queue: "jobs",
        state: "retryable",
        inserted_at: ~U[2026-06-02 10:04:00Z],
        args: %{"trigger_kind" => ""}
      )

    projection =
      JobsReadModel.load(:system,
        params: %{
          "job_id" => Integer.to_string(blank_trigger_job.id),
          "worker" => worker_name(TokenRefreshWorker)
        },
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert projection.selected_job.id == blank_trigger_job.id
    refute Map.has_key?(projection.selected_job, :trigger_kind)
    refute Map.has_key?(projection.worker_jobs_by_group.token_refresh.latest, :trigger_kind)
  end

  test "keeps invalid URL filter warnings while applying safe defaults" do
    projection =
      JobsReadModel.load(:system,
        params: %{"state" => "completed", "page" => "0", "job_id" => "not-an-id"}
      )

    assert projection.filters.state == nil
    assert projection.filters.page == 1
    assert projection.filters.job_id == nil
    assert projection.form_values["state"] == "completed"
    assert projection.form_values["page"] == "1"

    assert %{field: :state, message: "Completed jobs require show_completed=true"} in projection.filter_warnings

    assert %{field: :page, message: "Page must be a positive integer"} in projection.filter_warnings

    assert %{field: :job_id, message: "Job id must be a positive integer"} in projection.filter_warnings
  end

  @tag :non_owner
  test "returns a safe empty projection for non-owner scopes without global leakage" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, ["instance_owner"])

    global_job =
      insert_job(1,
        worker: TokenRefreshWorker,
        state: "retryable",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        attempted_at: ~U[2026-06-02 10:01:00Z]
      )

    %{user: admin} = operator_fixture(owner_scope, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin, ["instance_admin"])

    {projection, events} =
      capture_repo_queries(fn ->
        JobsReadModel.load(admin_scope,
          params: %{
            "job_id" => Integer.to_string(global_job.id),
            "worker" => worker_name(TokenRefreshWorker)
          }
        )
      end)

    assert oban_jobs_query_count(events) == 0
    assert projection.overview.empty?
    assert projection.overview.total == 0
    assert projection.explorer == %{items: [], total: 0, limit: 20, offset: 0}
    assert projection.selected_job == nil
    refute Map.has_key?(projection, :recent_jobs)
    assert projection.filter_warnings == []
    assert projection.filters.job_id == nil
    assert projection.filters.worker == nil
    assert projection.form_values["job_id"] == ""
    assert projection.form_values["worker"] == ""
    refute projected_job_id?(projection, global_job.id)
  end

  @tag :non_owner
  test "non-owner grouped worker summaries return empty group entries without querying jobs" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, ["instance_owner"])

    hidden_job =
      insert_job(1,
        worker: TokenRefreshWorker,
        state: "retryable",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        attempted_at: ~U[2026-06-02 10:01:00Z]
      )

    %{user: admin} = operator_fixture(owner_scope, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin, ["instance_admin"])

    worker_groups = [
      %{
        key: :token_refresh,
        workers: [worker_name(TokenRefreshWorker), worker_name(TokenRefreshEnqueueWorker)]
      },
      %{key: :runtime_cleanup, workers: [worker_name(RuntimeStateCleanupWorker)]}
    ]

    {summaries, events} =
      capture_repo_queries(fn ->
        Jobs.worker_job_summaries_by_group(admin_scope, worker_groups)
      end)

    assert oban_jobs_query_count(events) == 0

    assert summaries == %{
             token_refresh: empty_worker_job_summary(),
             runtime_cleanup: empty_worker_job_summary()
           }

    refute projected_job_id?(summaries, hidden_job.id)
  end

  defp insert_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{}) |> Map.put_new("index", index)
    meta = Keyword.get(attrs, :meta, %{"source" => "jobs-read-model-test"})

    assert {:ok, job} =
             args
             |> RuntimeStateCleanupWorker.new(meta: meta, unique: false)
             |> Oban.insert()

    updates =
      attrs
      |> Keyword.take([
        :worker,
        :queue,
        :state,
        :errors,
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

  defp projected_job_id?(value, job_id) do
    value
    |> projected_job_id_values()
    |> Enum.any?(&job_id_value?(&1, job_id))
  end

  defp projected_job_id_values(%{} = value) do
    own_values =
      value
      |> Map.take([:id, :job_id, "id", "job_id"])
      |> Map.values()

    nested_values =
      value
      |> Map.values()
      |> Enum.flat_map(&projected_job_id_values/1)

    own_values ++ nested_values
  end

  defp projected_job_id_values(values) when is_list(values) do
    Enum.flat_map(values, &projected_job_id_values/1)
  end

  defp projected_job_id_values(_value), do: []

  defp job_id_value?(value, job_id) when is_integer(value), do: value == job_id
  defp job_id_value?(value, job_id) when is_binary(value), do: value == Integer.to_string(job_id)
  defp job_id_value?(_value, _job_id), do: false

  def handle_repo_query_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    if metadata[:repo] == Repo do
      send(test_pid, {handler_id, %{source: normalize_source(metadata[:source])}})
    end
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_repo_query_event/4,
        {handler_id, test_pid}
      )

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, event} ->
        drain_repo_query_events(handler_id, [event | events])
    after
      10 -> Enum.reverse(events)
    end
  end

  defp oban_jobs_query_count(events) do
    Enum.count(events, &(&1.source == "oban_jobs"))
  end

  defp normalize_source(nil), do: "unknown"
  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(source), do: to_string(source)

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
