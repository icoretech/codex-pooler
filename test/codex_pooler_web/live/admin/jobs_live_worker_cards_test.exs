defmodule CodexPoolerWeb.Admin.JobsLiveWorkerCardsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Jobs.AlertEvaluationWorker
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Jobs.DailyRollupRebuildWorker
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AvatarComponents

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "worker cards render active markers and unresolved failure panels by target", %{
    conn: conn
  } do
    active_pool = pool_fixture(%{name: "Active Pool", slug: "active-pool"})
    failing_pool = pool_fixture(%{name: "Failing Pool", slug: "failing-pool"})
    resolved_pool = pool_fixture(%{name: "Resolved Pool", slug: "resolved-pool"})

    active_job =
      insert_job(
        1,
        worker: CatalogSyncWorker,
        state: "executing",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:00:30Z],
        args: %{"pool_id" => active_pool.id}
      )

    failing_job =
      insert_job(
        2,
        worker: CatalogSyncWorker,
        state: "discarded",
        inserted_at: ~U[2026-05-04 10:01:00Z],
        discarded_at: ~U[2026-05-04 10:02:00Z],
        args: %{"pool_id" => failing_pool.id},
        errors: [
          %{
            "attempt" => 3,
            "kind" => "RuntimeError",
            "error" => "catalog sync timeout authorization=Bearer secret-token-123"
          }
        ]
      )

    resolved_failure =
      insert_job(
        3,
        worker: CatalogSyncWorker,
        state: "discarded",
        inserted_at: ~U[2026-05-04 10:03:00Z],
        discarded_at: ~U[2026-05-04 10:04:00Z],
        args: %{"pool_id" => resolved_pool.id},
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" => "resolved failure"
          }
        ]
      )

    insert_job(
      4,
      worker: CatalogSyncWorker,
      state: "completed",
      inserted_at: ~U[2026-05-04 10:05:00Z],
      completed_at: ~U[2026-05-04 10:06:00Z],
      args: %{"pool_id" => resolved_pool.id}
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:catalog_sync)

    assert has_element?(view, "#{card} [data-role='worker-activity-strip']")

    assert has_element?(
             view,
             "#{card} #job-activity-#{active_job.id}[aria-label*='CatalogSync']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{active_job.id}[aria-label*='Active Pool']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{active_job.id} [data-role='target-initial']",
             "AP"
           )

    refute has_element?(view, "#{card} [data-role='worker-activity-strip'] .loading-spinner")

    assert has_element?(
             view,
             "#{card} #job-failure-#{failing_job.id}[aria-label*='Failing Pool'][aria-expanded='false'][aria-controls='job-failure-panel-#{failing_job.id}']"
           )

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(failing_job)}[data-open='false'][aria-hidden='true']"
           )

    refute has_element?(view, "#{card} #job-failure-dialog-#{failing_job.id}")

    render_click(element(view, "#{card} #job-failure-#{failing_job.id}"))
    assert_patch(view, ~p"/admin/jobs?failure_job_id=#{failing_job.id}")

    assert has_element?(
             view,
             "#{card} #job-failure-#{failing_job.id}[aria-expanded='true']"
           )

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(failing_job)}[data-open='true'][aria-hidden='false']",
             "RuntimeError"
           )

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(failing_job)}",
             "catalog sync timeout"
           )

    refute has_element?(view, "#job-detail-drawer[checked]")
    refute has_element?(view, "#{card} #job-failure-#{resolved_failure.id}")

    rendered = render(view)
    refute rendered =~ "secret-token-123"
    refute rendered =~ "Bearer secret-token"
  end

  test "selected worker failure panels survive LiveView refreshes and can close", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: TokenRefreshWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 8,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:00:30Z],
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" => "refresh failed"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?failure_job_id=#{job.id}")
    card = worker_card_selector(:token_refresh)

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(job)}[data-open='true'][aria-hidden='false']",
             "refresh failed"
           )

    send(view.pid, :refresh_jobs)
    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(job)}[data-open='true'][aria-hidden='false']",
             "refresh failed"
           )

    render_click(
      element(view, "#{card} #{failure_panel_selector(job)} [data-role='failure-panel-close']")
    )

    assert_patch(view, ~p"/admin/jobs")

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(job)}[data-open='false'][aria-hidden='true']"
           )
  end

  test "opening an already rendered worker failure panel does not reload jobs", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: TokenRefreshWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 8,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:00:30Z],
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" => "refresh failed"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:token_refresh)

    {_result, events} =
      capture_repo_queries(fn ->
        render_click(element(view, "#{card} #job-failure-#{job.id}"))
        assert_patch(view, ~p"/admin/jobs?failure_job_id=#{job.id}")
      end)

    assert oban_jobs_query_count(events) == 0

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(job)}[data-open='true'][aria-hidden='false']",
             "refresh failed"
           )
  end

  test "opening an already rendered job detail drawer does not reload jobs", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: TokenRefreshWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 8,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:00:30Z],
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" => "refresh failed"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    {_result, events} =
      capture_repo_queries(fn ->
        render_click(element(view, "#admin-jobs-explorer-desktop #job-#{job.id}"))
        assert_patch(view, ~p"/admin/jobs?job_id=#{job.id}")
      end)

    assert oban_jobs_query_count(events) == 0

    assert has_element?(view, "#job-detail-drawer[checked]")
    assert has_element?(view, "#job-detail-sidebar #job-detail-failure-summary", "refresh failed")
  end

  test "job detail drawer panel is mounted before selection so opening can slide", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: TokenRefreshWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 8,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:00:30Z],
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" => "refresh failed"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#job-detail-drawer:not([checked])")
    assert has_element?(view, "[data-role='job-detail-drawer-side']")
    assert has_element?(view, "[data-role='job-detail-drawer-side'] > #job-detail-sidebar")
    refute has_element?(view, "#job-detail-sidebar #job-detail-metadata")

    render_click(element(view, "#admin-jobs-explorer-desktop #job-#{job.id}"))
    assert_patch(view, ~p"/admin/jobs?job_id=#{job.id}")

    assert has_element?(view, "#job-detail-drawer[checked]")
    assert has_element?(view, "[data-role='job-detail-drawer-side'] > #job-detail-sidebar")
    assert has_element?(view, "#job-detail-sidebar #job-detail-metadata")
  end

  test "worker cards omit subtitles and keep compact schedule facts", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        attempt: 2,
        max_attempts: 5,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        completed_at: ~U[2026-05-04 10:02:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")
    card = worker_card_selector(:runtime_cleanup)

    assert has_element?(view, "#{card}", "Runtime cleanup")
    assert has_element?(view, "#{card} [data-role='worker-card-title-row'].items-center")
    assert has_element?(view, "#{card} [data-role='worker-card-title-row'] > .hero-sparkles")
    refute has_element?(view, "#{card} [data-role='worker-card-title-row'] > .rounded-box")
    refute has_element?(view, "#{card}", "Expired state cleanup")

    refute has_element?(view, "#{card} [data-role='worker-state-badge']")

    refute has_element?(view, "#{card} [data-role='state-icon']")

    assert has_element?(
             view,
             "#{card} [data-role='worker-schedule-facts'][data-density='compact']"
           )

    assert has_element?(view, "#{card} [data-role='next-run-group']", "Next run")
    assert has_element?(view, "#{card} [data-role='last-run']", "2026-05-04 10:02:00 UTC")
    refute has_element?(view, "#{card} [data-role='last-run'] dd.font-semibold")
    assert has_element?(view, "#{card} [data-role='schedule']", "Schedule")

    assert has_element?(
             view,
             "#{card} [data-role='schedule'] [data-role='cadence-label']",
             "Every 15 min"
           )

    refute has_element?(
             view,
             "#{card} [data-role='worker-schedule-facts'] [data-role='attempts']"
           )

    refute has_element?(view, "#{card}", "Last success")
    refute has_element?(view, "#{card}", "Last failure")
    refute has_element?(view, "#{card} [data-role='last-success']")
    refute has_element?(view, "#{card} [data-role='last-failure']")

    rendered = render(view)

    assert rendered =~ ~s(data-role="worker-schedule-grid")
    refute has_element?(view, "#{card} [data-role='worker-state-badge']")

    refute has_element?(view, worker_card_selector(:catalog_sync), "Model catalog refresh")
    refute has_element?(view, worker_card_selector(:pricing_import), "Pricing data refresh")

    refute has_element?(
             view,
             worker_card_selector(:account_reconciliation),
             "Upstream account checks"
           )

    refute has_element?(view, worker_card_selector(:alert_evaluation), "Alert rule checks")
    refute has_element?(view, worker_card_selector(:token_refresh), "Access-token renewal")
    refute has_element?(view, worker_card_selector(:daily_rollup_rebuild), "Usage rollup rebuild")
    refute rendered =~ "Expired files, sessions, runtime state, and stale reconciliation cleanup"
    refute rendered =~ "OpenAI pricing JSON catalog refreshes"
    refute rendered =~ "Quota, health, token, and catalog checks"
    assert has_element?(view, "#job-#{job.id}")
  end

  test "daily rollup active jobs do not render live target avatars", %{conn: conn} do
    insert_job(
      1,
      worker: DailyRollupRebuildWorker,
      state: "executing",
      inserted_at: ~U[2026-05-04 10:00:00Z],
      attempted_at: ~U[2026-05-04 10:00:30Z],
      args: %{"rollup_date" => "2026-05-03"}
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:daily_rollup_rebuild)

    assert has_element?(view, "#{card} [data-role='worker-state-badge']", "Executing")
    assert has_element?(view, "#{card} [data-role='next-run']", "Running now")
    refute has_element?(view, "#{card} [data-role='worker-activity-strip']")
    refute has_element?(view, "#{card} [data-role='active-worker-marker']")
    refute has_element?(view, "#{card} [data-role='target-initial']", "R2")
  end

  test "daily rollup failures still render failure markers with rollup context", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: DailyRollupRebuildWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 3,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:00:30Z],
        args: %{"rollup_date" => "2026-05-03"},
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" => "rollup rebuild failed"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:daily_rollup_rebuild)

    assert has_element?(view, "#{card} [data-role='worker-activity-strip']", "Needs attention")

    assert has_element?(
             view,
             "#{card} #job-failure-#{job.id}[aria-label*='Rollup 2026-05-03']"
           )

    render_click(element(view, "#{card} #job-failure-#{job.id}"))

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(job)}[data-open='true']",
             "Rollup 2026-05-03"
           )
  end

  test "catalog sync changeset failures use latest attempt and operator copy", %{conn: conn} do
    pool = pool_fixture(%{name: "Manual Catalog Pool", slug: "manual-catalog-pool"})

    job =
      insert_job(
        1,
        worker: CatalogSyncWorker,
        state: "discarded",
        attempt: 3,
        max_attempts: 3,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:02:00Z],
        args: %{"pool_id" => pool.id, "trigger_kind" => "manual"},
        errors: [
          %{
            "attempt" => 1,
            "error" => catalog_sync_invalid_trigger_error("2026-05-04 10:00:00Z")
          },
          %{
            "attempt" => 2,
            "error" => catalog_sync_invalid_trigger_error("2026-05-04 10:01:00Z")
          },
          %{
            "attempt" => 3,
            "error" => catalog_sync_invalid_trigger_error("2026-05-04 10:02:00Z")
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:catalog_sync)

    render_click(element(view, "#{card} #job-failure-#{job.id}"))

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(job)}[data-open='true']",
             "Attempt 3 · Invalid catalog sync trigger"
           )

    assert has_element?(
             view,
             "#{card} #{failure_panel_selector(job)} [data-role='failure-message']",
             "Manual catalog sync could not start because the enqueue action used an unsupported trigger kind."
           )

    assert has_element?(
             view,
             "#admin-jobs-explorer-desktop #job-#{job.id} [data-role='failure-title']",
             "Attempt 3 · Invalid catalog sync trigger"
           )

    rendered = render(view)
    refute rendered =~ "Ecto.Changeset"
    refute rendered =~ "admin_jobs_live"
  end

  test "worker card action menus enqueue runnable workers and skip target-scoped workers", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    runtime_card = worker_card_selector(:runtime_cleanup)
    catalog_card = worker_card_selector(:catalog_sync)
    token_card = worker_card_selector(:token_refresh)

    assert has_element?(view, "#{runtime_card} [data-role='job-worker-card-actions']")

    assert has_element?(
             view,
             "#{runtime_card} #enqueue-job-worker-runtime-cleanup",
             "Enqueue Now"
           )

    assert has_element?(view, "#{catalog_card} #enqueue-job-worker-catalog-sync", "Enqueue Now")

    refute has_element?(view, "#{token_card} [data-role='job-worker-card-actions']")
    refute has_element?(view, "#{token_card}", "Enqueue Now")

    render_click(element(view, "#{runtime_card} #enqueue-job-worker-runtime-cleanup"))

    runtime_worker = worker_name(RuntimeStateCleanupWorker)

    assert [
             %Oban.Job{
               args: %{},
               state: "available",
               worker: ^runtime_worker
             }
           ] = Repo.all(from job in Oban.Job, order_by: [asc: job.id])

    assert render(view) =~ "Runtime cleanup queued"
  end

  test "alert evaluation enqueue explains when there are no active rules", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:alert_evaluation)

    assert has_element?(view, "#{card} #enqueue-job-worker-alert-evaluation", "Enqueue Now")

    render_click(element(view, "#{card} #enqueue-job-worker-alert-evaluation"))

    alert_worker = worker_name(AlertEvaluationWorker)
    refute Repo.exists?(from job in Oban.Job, where: job.worker == ^alert_worker)
    assert render(view) =~ "Alert evaluation has no active alert rules to evaluate"
  end

  test "account reconciliation card renders one compact active marker per assignment", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Fanout Pool", slug: "fanout-pool"})

    %{assignment: first_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "codex01@example.com",
        assignment_label: "codex01@example.com"
      })

    %{assignment: second_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "codex02@example.com",
        assignment_label: "codex02@example.com"
      })

    first_job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "executing",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:00:30Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => first_assignment.id,
          "trigger_kind" => "scheduled"
        }
      )

    second_job =
      insert_job(
        2,
        worker: AccountReconciliationWorker,
        state: "executing",
        inserted_at: ~U[2026-05-04 10:00:01Z],
        attempted_at: ~U[2026-05-04 10:00:31Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => second_assignment.id,
          "trigger_kind" => "scheduled"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)
    rendered = render(view)

    assert has_element?(view, "#{card} [data-role='worker-activity-strip']")
    assert has_element?(view, "#{card} [data-role='worker-state-badge']", "Executing")
    assert has_element?(view, "#{card} [data-role='worker-state-badge'] .hero-clock")
    refute has_element?(view, "#{card} [data-role='worker-live-dot']")
    refute rendered =~ "Account fan-out slots are always visible"
    refute rendered =~ "Empty slots stay reserved"
    refute rendered =~ "job-target-board"

    assert has_element?(
             view,
             "#{card} #job-activity-#{first_job.id}[aria-label*='codex01@example.com']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{second_job.id}[aria-label*='codex02@example.com']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{first_job.id}[data-has-avatar='true'].avatar.avatar-online img[src='#{AvatarComponents.gravatar_url("codex01@example.com", size: 64)}']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{second_job.id}[data-has-avatar='true'].avatar.avatar-online img[src='#{AvatarComponents.gravatar_url("codex02@example.com", size: 64)}']"
           )

    refute has_element?(view, "#{card} #job-activity-#{first_job.id} > img")

    refute has_element?(
             view,
             "#{card} #job-activity-#{first_job.id} [data-role='target-initial']"
           )

    refute has_element?(
             view,
             "#{card} #job-activity-#{first_job.id} [data-role='target-live-indicator']"
           )

    refute has_element?(view, "#{card} [data-role='worker-activity-strip'] .loading-spinner")
    refute has_element?(view, "#{card} #job-activity-#{first_job.id}", "AccountReconciliation")
    refute has_element?(view, "#{card} #job-activity-#{first_job.id}", "codex01@example.com")
    refute has_element?(view, "#{card} #job-activity-#{second_job.id}", "codex02@example.com")
  end

  test "account reconciliation failure markers use operator avatar status styling", %{conn: conn} do
    pool = pool_fixture(%{name: "Failure Avatar Pool", slug: "failure-avatar-pool"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "failed-account@example.com",
        assignment_label: "failed-account@example.com"
      })

    job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:00:30Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "trigger_kind" => "scheduled"
        },
        errors: [
          %{
            "attempt" => 1,
            "error" => "account reconciliation partial: quota_refresh_failed"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    assert has_element?(
             view,
             "#{card} #job-failure-#{job.id}[data-has-avatar='true'].avatar.avatar-offline img[src='#{AvatarComponents.gravatar_url("failed-account@example.com", size: 64)}']"
           )

    refute has_element?(view, "#{card} #job-failure-#{job.id} .hero-exclamation-triangle")
    refute has_element?(view, "#{card} #job-failure-#{job.id} > img")
  end

  test "account reconciliation card caps active target markers", %{conn: conn} do
    pool = pool_fixture(%{name: "Fanout Pool", slug: "fanout-pool"})

    for index <- 1..10 do
      insert_job(
        index,
        worker: AccountReconciliationWorker,
        state: "executing",
        inserted_at: DateTime.add(~U[2026-05-04 10:00:00Z], index, :second),
        attempted_at: DateTime.add(~U[2026-05-04 10:00:30Z], index, :second),
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => "target-#{index}",
          "trigger_kind" => "scheduled"
        }
      )
    end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)
    rendered = render(view)

    assert count_occurrences(rendered, "data-role=\"active-worker-marker\"") == 8
    assert has_element?(view, "#{card} [data-role='active-worker-overflow']", "+2")
    refute rendered =~ "Account fan-out slots are always visible"
  end

  test "renders redacted failure details for failed jobs", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" =>
              "upstream timeout authorization=Bearer secret-token-123 prompt=raw-prompt-text"
          }
        ],
        args: %{"prompt" => "raw-arg-prompt"},
        meta: %{"authorization" => "meta-bearer-value"}
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #job-failure-#{job.id}[aria-label*='AccountReconciliation']"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #{failure_panel_selector(job)}[data-open='false'][aria-hidden='true']"
           )

    render_click(
      element(view, "#{worker_card_selector(:account_reconciliation)} #job-failure-#{job.id}")
    )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #{failure_panel_selector(job)}[data-open='true'][aria-hidden='false']",
             "RuntimeError"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #{failure_panel_selector(job)} [data-role='failure-message']",
             "upstream timeout"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #{failure_panel_selector(job)}",
             "Latest failure"
           )

    assert has_element?(view, "#job-#{job.id} [data-role='failure-details']", "Attempt 1")
    assert has_element?(view, "#job-#{job.id} [data-role='failure-details']", "RuntimeError")

    assert has_element?(
             view,
             "#job-#{job.id} [data-role='failure-message']",
             "upstream timeout"
           )

    rendered = render(view)
    refute rendered =~ "secret-token-123"
    refute rendered =~ "secret-token"
    refute rendered =~ "raw-prompt-text"
    refute rendered =~ "raw-arg-prompt"
    refute rendered =~ "meta-bearer-value"
  end

  test "account reconciliation failures use operator-facing copy", %{conn: conn} do
    insert_job(
      1,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    render_click(element(view, "#{card} [data-role='failed-worker-marker']"))

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='true']",
             "Quota refresh needs account reauthentication."
           )

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='true']",
             "Quota refresh blocked"
           )

    refute has_element?(view, "#{card} [data-role='failed-worker-dialog']")

    rendered = render(view)
    refute rendered =~ "Oban.PerformError"
    refute rendered =~ "account reconciliation partial: quota_refresh_auth_unavailable"
  end

  test "reauth-required account reconciliation failures are not unresolved targets", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Recovery Pool", slug: "recovery-pool"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "recovery@example.com",
        assignment_label: "Recovery account",
        identity_status: "reauth_required",
        assignment_health_status: "disabled",
        assignment_eligibility_status: "ineligible",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "reauth_required",
            "reason" => %{"code" => "missing_refresh_token"}
          }
        }
      })

    insert_job(
      1,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      discarded_at: ~U[2026-05-04 10:00:30Z],
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

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    refute has_element?(view, "#{card} [data-role='failed-worker-marker']")
    refute has_element?(view, "#{card} [data-role='failed-worker-overflow']")
  end

  test "resolved account reconciliation failures do not render the latest failure panel", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Recovered Pool", slug: "recovered-pool"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "recovered@example.com",
        assignment_label: "Recovered account"
      })

    args = %{
      "pool_id" => pool.id,
      "pool_upstream_assignment_id" => assignment.id,
      "trigger_kind" => "scheduled"
    }

    insert_job(
      1,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      discarded_at: ~U[2026-05-04 10:00:30Z],
      args: args,
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
        }
      ]
    )

    insert_job(
      2,
      worker: AccountReconciliationWorker,
      state: "completed",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:01:00Z],
      completed_at: ~U[2026-05-04 10:01:30Z],
      args: args
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    refute has_element?(view, "#{card} [data-role='worker-failure-panel']")
    refute has_element?(view, "#{card} [data-role='failed-worker-marker']")
  end

  test "map-shaped oban errors use operator-facing copy", %{conn: conn} do
    insert_job(
      1,
      worker: CatalogSyncWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.CatalogSyncWorker failed with {:error, %{code: :catalog_sync_failed, message: \"upstream secret could not be decrypted\"}}"
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:catalog_sync)

    render_click(element(view, "#{card} [data-role='failed-worker-marker']"))

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='true']",
             "upstream [redacted] could not be decrypted"
           )

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='true']",
             "Catalog sync failed"
           )

    refute has_element?(view, "#{card} [data-role='failed-worker-dialog']")

    rendered = render(view)
    refute rendered =~ "Oban.PerformError"
    refute rendered =~ "catalog_sync_failed"
    refute rendered =~ "upstream secret"
  end

  test "discard oban errors use operator-facing copy", %{conn: conn} do
    insert_job(
      1,
      worker: TokenRefreshWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 8,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.TokenRefreshWorker failed with :discard"
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:token_refresh)

    assert has_element?(view, "#{card} [data-role='next-run']", "On demand")
    assert has_element?(view, "#{card} [data-role='next-run'] .hero-clock")

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='false'][aria-hidden='true']"
           )

    render_click(element(view, "#{card} [data-role='failed-worker-marker']"))

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='true']",
             "The job stopped without additional diagnostics."
           )

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='true'] [data-role='failure-message']",
             "The job stopped without additional diagnostics."
           )

    assert has_element?(
             view,
             "#{card} [data-role='failure-panel-summary'] [data-role='failure-panel-meta']"
           )

    refute has_element?(view, "#{card} [data-role='failure-message'].line-clamp-2")

    assert has_element?(
             view,
             "#{card} [data-role='worker-failure-panel'][data-open='true']",
             "Run discarded"
           )

    refute has_element?(view, "#{card} [data-role='failed-worker-dialog']")

    rendered = render(view)
    refute rendered =~ "Oban.PerformError"
    refute rendered =~ "TokenRefreshWorker failed with :discard"
  end

  defp insert_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{"index" => index})
    meta = Keyword.get(attrs, :meta, %{"source" => "admin-jobs-live-test"})

    assert {:ok, job} =
             args
             |> RuntimeStateCleanupWorker.new(meta: meta)
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
        :cancelled_at,
        :errors
      ])
      |> maybe_put_worker_name()
      |> Keyword.put(:inserted_at, inserted_at)

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end

  defp worker_card_selector(worker_group) do
    "#job-worker-card-#{String.replace(Atom.to_string(worker_group), "_", "-")}"
  end

  defp failure_panel_selector(job), do: "#job-failure-panel-#{job.id}"

  defp catalog_sync_invalid_trigger_error(timestamp) do
    "** (Oban.PerformError) CodexPooler.Jobs.CatalogSyncWorker failed with {:error, #Ecto.Changeset<action: :insert, changes: %{status: \"running\", started_at: ~U[#{timestamp}], stats: %{}, pool_id: \"pool-id\", trigger_kind: \"admin_jobs_live\"}, errors: [trigger_kind: {\"is invalid\", [validation: :inclusion, enum: [\"manual\", \"scheduled\", \"bootstrap\", \"reconcile\"]]}], data: #CodexPooler.Catalog.SyncRun<>, valid?: false, ...>}"
  end

  defp count_occurrences(source, pattern) do
    source
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

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

  defp maybe_put_worker_name(updates) do
    if Keyword.has_key?(updates, :worker) do
      Keyword.update!(updates, :worker, &worker_name/1)
    else
      updates
    end
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
