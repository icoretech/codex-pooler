defmodule CodexPoolerWeb.Admin.JobsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.User
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.JobsReadModel

  test "redirects unauthenticated operators to login" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/jobs")
  end

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "denies instance admins without loading global jobs", %{scope: scope} do
    job =
      insert_job(
        1,
        worker: RuntimeStateCleanupWorker,
        state: "available",
        inserted_at: ~U[2026-05-04 10:00:00Z]
      )

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "jobs-denied-admin@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, html} = live(admin_conn, ~p"/admin/jobs")

    assert has_element?(view, "#admin-jobs-owner-denied", "System jobs require owner access")
    refute has_element?(view, "#admin-jobs-worker-grid")
    refute has_element?(view, "#admin-jobs-explorer")
    refute has_element?(view, "#job-#{job.id}")
    refute html =~ "RuntimeStateCleanupWorker"
    refute has_element?(view, "#admin-nav-jobs")
    refute has_element?(view, "#admin-nav-system")

    state = :sys.get_state(view.pid)
    refute state.socket.assigns.owner_authorized?
    assert state.socket.assigns.current_params == %{}
    refute Map.has_key?(state.socket.assigns, :recent_jobs)
    assert state.socket.assigns.explorer.items == []
    assert state.socket.assigns.selected_job == nil
    assert state.socket.assigns.filter_warnings == []
    assert state.socket.assigns.form_values["job_id"] == ""
    assert state.socket.assigns.subscribed_pool_ids == MapSet.new()
  end

  test "renders overview metrics and worker cards before row-level activity", %{conn: conn} do
    now = DateTime.utc_now()
    pool = pool_fixture(%{name: "Operations Pool", slug: "operations-pool"})

    %{identity: dominant_identity, assignment: dominant_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Dominant upstream",
        assignment_label: "Dominant assignment"
      })

    active_failure_a =
      insert_job(1,
        worker: TokenRefreshWorker,
        state: "discarded",
        inserted_at: DateTime.add(now, -120, :second),
        discarded_at: DateTime.add(now, -110, :second),
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => dominant_assignment.id,
          "token" => "secret-token-overview",
          "prompt" => "raw-prompt-overview"
        },
        meta: %{"cookie" => "cookie-overview"},
        errors: [
          %{
            "attempt" => 1,
            "error" => "stacktrace-with-secret-overview"
          }
        ]
      )

    insert_job(2,
      worker: TokenRefreshWorker,
      state: "discarded",
      inserted_at: DateTime.add(now, -240, :second),
      discarded_at: DateTime.add(now, -230, :second),
      args: %{
        "pool_id" => pool.id,
        "pool_upstream_assignment_id" => dominant_assignment.id
      }
    )

    insert_job(3,
      worker: TokenRefreshWorker,
      state: "retryable",
      attempt: 3,
      max_attempts: 5,
      inserted_at: DateTime.add(now, -300, :second),
      attempted_at: DateTime.add(now, -290, :second),
      args: %{"upstream_identity_id" => dominant_identity.id}
    )

    insert_job(4,
      worker: RuntimeStateCleanupWorker,
      state: "executing",
      inserted_at: DateTime.add(now, -7_200, :second),
      attempted_at: DateTime.add(now, -7_100, :second)
    )

    insert_job(5,
      worker: CatalogSyncWorker,
      state: "available",
      inserted_at: DateTime.add(now, -900, :second),
      scheduled_at: DateTime.add(now, -600, :second),
      args: %{"pool_id" => pool.id}
    )

    insert_job(6,
      worker: RuntimeStateCleanupWorker,
      state: "completed",
      inserted_at: DateTime.add(now, -60, :second),
      completed_at: DateTime.add(now, -50, :second)
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    refute has_element?(view, "#admin-jobs-overview")
    refute has_element?(view, "#admin-jobs-health-summary")
    refute has_element?(view, "#admin-jobs-overview-active-failure")
    refute has_element?(view, "#admin-jobs-overview-stuck-executing")
    refute has_element?(view, "#admin-jobs-overview-retry-pressure")
    refute has_element?(view, "#admin-jobs-overview-backlog-pressure")

    refute has_element?(view, "#admin-jobs-hotspots")

    rendered = render(view)
    assert String.contains?(rendered, "id=\"job-filter-form\"")
    assert String.contains?(rendered, "id=\"admin-jobs-worker-grid\"")
    assert String.contains?(rendered, "id=\"admin-jobs-explorer\"")
    refute rendered =~ "System job health"

    assert :binary.match(rendered, "id=\"admin-jobs-worker-grid\"") <
             :binary.match(rendered, "id=\"job-filter-form\"")

    assert :binary.match(rendered, "id=\"job-filter-form\"") <
             :binary.match(rendered, "id=\"admin-jobs-explorer\"")

    assert :binary.match(rendered, "id=\"admin-jobs-worker-grid\"") <
             :binary.match(rendered, "id=\"admin-jobs-explorer\"")

    assert has_element?(view, "#job-#{active_failure_a.id}")
    refute rendered =~ "secret-token-overview"
    refute rendered =~ "raw-prompt-overview"
    refute rendered =~ "cookie-overview"
    refute rendered =~ "stacktrace-with-secret-overview"
  end

  test "renders healthy overview when there are no actionable jobs", %{conn: conn} do
    now = DateTime.utc_now()

    insert_job(1,
      worker: RuntimeStateCleanupWorker,
      state: "completed",
      inserted_at: DateTime.add(now, -120, :second),
      completed_at: DateTime.add(now, -90, :second)
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    refute has_element?(view, "#admin-jobs-overview")
    refute has_element?(view, "#admin-jobs-health-summary")
    refute has_element?(view, "#admin-jobs-hotspots")
    assert has_element?(view, "#admin-jobs-explorer")
    assert has_element?(view, "#admin-jobs-empty-state", "No jobs match these filters")
  end

  test "renders worker cards and jobs explorer", %{conn: conn} do
    inserted_at = ~U[2026-05-04 10:00:00Z]
    attempted_at = ~U[2026-05-04 10:01:00Z]
    completed_at = ~U[2026-05-04 10:02:00Z]

    job =
      insert_job(
        1,
        state: "completed",
        attempt: 2,
        max_attempts: 5,
        inserted_at: inserted_at,
        attempted_at: attempted_at,
        completed_at: completed_at,
        args: %{
          "token" => "secret-token-123",
          "prompt" => "raw-prompt-text"
        },
        meta: %{"authorization" => "authorization-bearer-value"}
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")

    assert has_element?(view, "#admin-jobs-page")
    assert has_element?(view, "#admin-jobs-page-header", "System Jobs")
    assert has_element?(view, "#admin-jobs-page-header", "Monitor background work")
    assert has_element?(view, "#admin-jobs-worker-grid")
    assert has_element?(view, "#admin-jobs-worker-grid.items-start")
    assert has_element?(view, worker_card_selector(:runtime_cleanup), "Runtime cleanup")
    assert has_element?(view, "#{worker_card_selector(:runtime_cleanup)} .hero-sparkles")

    refute has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='worker-state-badge']"
           )

    refute has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)}",
             "Expired state cleanup"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='worker-schedule-facts']"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='next-run-group']",
             "Next run"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='last-run']",
             "10:02:00 UTC"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='schedule']",
             "Schedule"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='schedule'] [data-role='cadence-label']",
             "Every 15 min"
           )

    refute has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='worker-schedule-facts'] [data-role='attempts']"
           )

    refute has_element?(view, "#{worker_card_selector(:runtime_cleanup)}", "Last success")
    refute has_element?(view, "#{worker_card_selector(:runtime_cleanup)}", "Last failure")
    assert has_element?(view, "#{worker_card_selector(:catalog_sync)}", "Catalog sync")
    refute has_element?(view, "#{worker_card_selector(:catalog_sync)}", "Model catalog refresh")

    refute has_element?(
             view,
             "#{worker_card_selector(:catalog_sync)} [data-role='worker-state-badge']"
           )

    rendered = render(view)
    assert rendered =~ "2xl:grid-cols-3"
    refute rendered =~ "Per-pool model catalog refreshes and scheduled fan-out"
    refute rendered =~ "OpenAI pricing JSON catalog refreshes for request-log cost reporting"
    refute rendered =~ "Quota, health, token, and catalog checks for upstream assignments"
    refute rendered =~ "Persisted alert rule evaluation and incident lifecycle updates"
    refute rendered =~ "Expired files, sessions, runtime state, and stale reconciliation cleanup"

    assert has_element?(view, "#admin-jobs-explorer")
    assert has_element?(view, "#admin-jobs-explorer-total", "1 job")
    assert has_element?(view, "#admin-jobs-explorer-range", "Showing 1-1 of 1")
    assert has_element?(view, "#admin-jobs-explorer-table")
    assert has_element?(view, "#admin-jobs-explorer-mobile #job-card-#{job.id}")
    assert has_element?(view, "#job-#{job.id}", "RuntimeStateCleanupWorker")
    assert has_element?(view, state_label_selector(job), "Completed")
    refute has_element?(view, "#job-#{job.id} [data-role='state-icon']")
    refute has_element?(view, "#job-#{job.id} [data-role='state-chip']")
    assert has_element?(view, "#job-#{job.id} [data-role='queue']", "Queue jobs")
    assert has_element?(view, "#job-#{job.id} [data-role='job-target-empty']", "-")

    assert has_element?(
             view,
             "#job-#{job.id} [data-role='worker']",
             "RuntimeStateCleanupWorker"
           )

    assert has_element?(view, "#job-#{job.id} [data-role='job-event-label']", "Completed")
    assert has_element?(view, "#job-#{job.id} [data-role='job-event-time']", "2026-05-04")
    assert has_element?(view, "#job-#{job.id} [data-role='job-event-time']", "10:02:00 UTC")
    refute has_element?(view, "#job-#{job.id}", DateTime.to_iso8601(job.inserted_at))
    refute has_element?(view, "#job-#{job.id}", DateTime.to_iso8601(job.attempted_at))
    refute has_element?(view, "#job-#{job.id}", DateTime.to_iso8601(job.completed_at))

    rendered = render(view)
    refute rendered =~ "secret-token-123"
    refute rendered =~ "raw-prompt-text"
    refute rendered =~ "authorization-bearer-value"
  end

  test "renders absolute job timestamps with operator preferences while keeping relative next run",
       %{
         conn: conn,
         user: user
       } do
    set_datetime_preferences!(user, datetime_format: "short", timezone: "Europe/Rome")

    completed_job =
      insert_job(
        1,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:01:00Z],
        completed_at: ~U[2026-05-04 10:02:00Z]
      )

    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(1_200, :second)
      |> DateTime.truncate(:second)

    insert_job(
      2,
      worker: TokenRefreshWorker,
      state: "scheduled",
      inserted_at: DateTime.add(scheduled_at, -60, :second),
      scheduled_at: scheduled_at
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")

    assert has_element?(
             view,
             "#job-#{completed_job.id} [data-role='job-event-label']",
             "Completed"
           )

    assert has_element?(
             view,
             "#job-#{completed_job.id} [data-role='job-event-time']",
             "2026-05-04 12:02"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='last-run']",
             "2026-05-04 12:02"
           )

    refute has_element?(
             view,
             "#{worker_card_selector(:runtime_cleanup)} [data-role='last-run']",
             "UTC"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:token_refresh)} [data-role='next-run']",
             "in "
           )

    render_click(element(view, "#job-#{completed_job.id}"))

    assert has_element?(view, "#job-detail-inserted-at", "2026-05-04 12:00")
    assert has_element?(view, "#job-detail-attempted-at", "2026-05-04 12:01")
    assert has_element?(view, "#job-detail-completed-at", "2026-05-04 12:02")
    refute render(view) =~ "10:02:00 UTC"
  end

  test "jobs read model owns admin jobs page state" do
    job =
      insert_job(
        1,
        worker: RuntimeStateCleanupWorker,
        state: "available",
        inserted_at: ~U[2026-05-04 10:00:00Z]
      )

    page_state = JobsReadModel.load(:system)

    assert %{items: [%{id: job_id}], total: 1, limit: 20, offset: 0} = page_state.explorer
    assert job_id == job.id
    assert is_map(page_state.overview)
    assert page_state.filters.show_completed == false
    assert page_state.form_values["show_completed"] == "false"
    assert page_state.filter_warnings == []
    assert page_state.selected_job == nil
    assert is_map(page_state.filter_options)
    refute Map.has_key?(page_state, :recent_jobs)
    assert is_map(page_state.worker_jobs_by_group)
    assert Map.has_key?(page_state.worker_jobs_by_group, :runtime_cleanup)
  end

  test "renders job target entity for assignment and account jobs", %{conn: conn} do
    pool = pool_fixture(%{name: "Diagnostics Pool", slug: "diagnostics-pool"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Example upstream",
        assignment_label: "Example assignment"
      })

    reconciliation_job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "discarded",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "trigger_kind" => "manual"
        },
        errors: [
          %{
            "attempt" => 1,
            "error" => "account reconciliation partial: quota_refresh_unavailable"
          }
        ]
      )

    scheduled_identity_job =
      insert_job(
        2,
        worker: AccountReconciliationWorker,
        state: "available",
        inserted_at: ~U[2026-05-04 10:00:30Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "upstream_identity_id" => identity.id,
          "target_kind" => "upstream_identity",
          "trigger_kind" => "scheduled"
        }
      )

    refresh_job =
      insert_job(
        3,
        worker: TokenRefreshWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:01:00Z],
        args: %{"upstream_identity_id" => identity.id, "trigger_kind" => "manual"}
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")

    refute has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} [data-role='job-target']"
           )

    assert has_element?(
             view,
             "#job-#{reconciliation_job.id} [data-role='target-primary']",
             "Account: Example upstream"
           )

    assert has_element?(
             view,
             "#job-#{reconciliation_job.id} [data-role='target-secondary']",
             "Assignment: Example assignment · Pool: Diagnostics Pool · Status: active"
           )

    assert has_element?(
             view,
             "#job-#{scheduled_identity_job.id} [data-role='target-primary']",
             "Account: Example upstream"
           )

    assert has_element?(
             view,
             "#job-#{scheduled_identity_job.id} [data-role='target-secondary']",
             "Status: active"
           )

    refute has_element?(
             view,
             "#job-#{scheduled_identity_job.id} [data-role='target-secondary']",
             "Assignment:"
           )

    assert has_element?(
             view,
             "#job-#{refresh_job.id} [data-role='target-primary']",
             "Account: Example upstream"
           )

    assert has_element?(
             view,
             "#job-#{refresh_job.id} [data-role='target-secondary']",
             "Status: active"
           )
  end

  test "renders URL-backed filter controls and patches selected filters", %{conn: conn} do
    pool = pool_fixture(%{name: "Jobs Filter Pool", slug: unique_slug("jobs-filter-pool")})
    worker = worker_name(TokenRefreshWorker)
    completed_worker = worker_name(RuntimeStateCleanupWorker)

    retryable_job =
      insert_job(
        1,
        worker: TokenRefreshWorker,
        state: "retryable",
        queue: "jobs",
        attempt: 3,
        max_attempts: 5,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:01:00Z],
        args: %{"pool_id" => pool.id}
      )

    completed_job =
      insert_job(
        2,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        queue: "critical",
        inserted_at: ~U[2026-05-04 10:02:00Z],
        completed_at: ~U[2026-05-04 10:03:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#job-filter-form")
    assert has_element?(view, "#job-filter-form[phx-hook='AdminFilterDropdowns']")

    assert has_element?(
             view,
             "#job-filter-form [data-role='filter-fields'][data-layout='single-row']"
           )

    assert has_element?(
             view,
             "#job-attention-filter [data-role='attention-filter-trigger']",
             "Any attention"
           )

    assert has_element?(view, "#job-attention-filter [data-role='attention-filter-menu']")

    assert has_element?(
             view,
             "#job-attention-filter [data-role='attention-filter-option'][data-attention='retry_pressure']"
           )

    assert has_element?(view, "#filters_attention[value='']")

    assert has_element?(view, "#job-state-filter [data-role='state-filter-trigger']", "Any state")
    assert has_element?(view, "#job-state-filter [data-role='state-filter-menu']")

    assert has_element?(
             view,
             "#job-state-filter [data-role='state-filter-option'][data-state='retryable']"
           )

    assert has_element?(view, "#filters_state[value='']")

    assert has_element?(
             view,
             "#job-worker-filter [data-role='worker-filter-trigger']",
             "Any worker"
           )

    assert has_element?(
             view,
             "#job-worker-filter [data-role='worker-filter-option'][data-worker='#{worker}']"
           )

    assert has_element?(
             view,
             "#job-worker-filter [data-role='worker-filter-option'][data-worker='#{completed_worker}']"
           )

    assert has_element?(view, "#filters_worker[value='']")

    assert has_element?(view, "#job-queue-filter [data-role='queue-filter-trigger']", "Any queue")

    assert has_element?(
             view,
             "#job-queue-filter [data-role='queue-filter-option'][data-queue='jobs']"
           )

    assert has_element?(
             view,
             "#job-queue-filter [data-role='queue-filter-option'][data-queue='critical']"
           )

    assert has_element?(view, "#filters_queue[value='']")

    assert has_element?(
             view,
             "#job-target-kind-filter [data-role='target-kind-filter-trigger']",
             "Any target"
           )

    assert has_element?(
             view,
             "#job-target-kind-filter [data-role='target-kind-filter-option'][data-target-kind='pool']"
           )

    assert has_element?(view, "#filters_target_kind[value='']")
    assert has_element?(view, "#job-target-id-filter #filters_target_id[value='']")

    assert has_element?(
             view,
             "#job-show-completed-filter [data-role='show-completed-filter-trigger']",
             "Hide completed"
           )

    assert has_element?(
             view,
             "#job-show-completed-filter [data-role='show-completed-filter-option'][data-show-completed='true']"
           )

    assert has_element?(view, "#filters_show_completed[value='false']")
    refute has_element?(view, "#job-filter-clear")

    render_click(
      element(view, "#job-state-filter [data-role='state-filter-option'][data-state='retryable']")
    )

    assert_patch(view, ~p"/admin/jobs?state=retryable")
    assert has_element?(view, "#filters_state[value='retryable']")
    assert has_element?(view, "#job-state-filter [data-role='state-filter-trigger']", "Retryable")
    assert has_element?(view, "#job-#{retryable_job.id}")
    refute has_element?(view, "#job-#{completed_job.id}")

    render_submit(element(view, "#job-filter-form"), %{
      "filters" => %{
        "attention" => "retry_pressure",
        "state" => "retryable",
        "worker" => worker,
        "queue" => "jobs",
        "target_kind" => "pool",
        "target_id" => pool.id,
        "show_completed" => "true",
        "page" => "1",
        "job_id" => ""
      }
    })

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "attention" => "retry_pressure",
             "queue" => "jobs",
             "show_completed" => "true",
             "state" => "retryable",
             "target_id" => pool.id,
             "target_kind" => "pool",
             "worker" => worker
           }

    assert has_element?(view, "#filters_attention[value='retry_pressure']")
    assert has_element?(view, "#filters_worker[value='#{worker}']")
    assert has_element?(view, "#filters_queue[value='jobs']")
    assert has_element?(view, "#filters_target_kind[value='pool']")
    assert has_element?(view, "#filters_target_id[value='#{pool.id}']")
    assert has_element?(view, "#filters_show_completed[value='true']")

    assert has_element?(
             view,
             "#job-show-completed-filter [data-role='show-completed-filter-trigger']",
             "Include completed"
           )
  end

  test "renders invalid URL filter warnings with safe normalized controls", %{conn: conn} do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/jobs?attention=old_attention&page=0&queue=bad/queue&show_completed=maybe&state=completed&target_id=not-a-uuid&target_kind=pool&worker=bad worker"
      )

    assert has_element?(view, "#job-filter-errors", "Some filters were ignored")
    assert has_element?(view, "#job-filter-errors", "Attention filter is not supported")
    assert has_element?(view, "#job-filter-errors", "Page must be a positive integer")

    assert has_element?(
             view,
             "#job-filter-errors",
             "Queue filter contains unsupported characters"
           )

    assert has_element?(view, "#job-filter-errors", "Show completed must be true or false")
    assert has_element?(view, "#job-filter-errors", "Completed jobs require show_completed=true")
    assert has_element?(view, "#job-filter-errors", "Target id must be a valid UUID")

    assert has_element?(
             view,
             "#job-filter-errors",
             "Worker filter contains unsupported characters"
           )

    assert has_element?(view, "#filters_attention[value='']")

    assert has_element?(
             view,
             "#job-attention-filter [data-role='attention-filter-trigger']",
             "Any attention"
           )

    assert has_element?(view, "#filters_state[value='']")
    assert has_element?(view, "#job-state-filter [data-role='state-filter-trigger']", "Any state")
    assert has_element?(view, "#filters_worker[value='']")

    assert has_element?(
             view,
             "#job-worker-filter [data-role='worker-filter-trigger']",
             "Any worker"
           )

    assert has_element?(view, "#filters_queue[value='']")
    assert has_element?(view, "#job-queue-filter [data-role='queue-filter-trigger']", "Any queue")
    assert has_element?(view, "#filters_target_kind[value='']")
    assert has_element?(view, "#filters_target_id[value='']")
    assert has_element?(view, "#filters_page[value='1']")
    assert has_element?(view, "#filters_show_completed[value='false']")

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.filters.attention == nil
    assert state.socket.assigns.filters.state == nil
    assert state.socket.assigns.filters.worker == nil
    assert state.socket.assigns.filters.queue == nil
    assert state.socket.assigns.filters.target_kind == nil
    assert state.socket.assigns.filters.target_id == nil
    assert state.socket.assigns.filters.page == 1
    refute state.socket.assigns.filters.show_completed
  end

  test "opens and closes metadata-only job detail drawer through URL state", %{conn: conn} do
    pool = pool_fixture(%{name: "Drawer Pool", slug: unique_slug("drawer-pool")})

    job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 2,
        max_attempts: 5,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        scheduled_at: ~U[2026-05-04 10:00:30Z],
        attempted_at: ~U[2026-05-04 10:01:00Z],
        discarded_at: ~U[2026-05-04 10:02:00Z],
        args: %{"pool_id" => pool.id},
        errors: [
          %{
            "attempt" => 2,
            "kind" => "RuntimeError",
            "error" => "pool reconciliation timeout"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?state=discarded")

    assert has_element?(view, "#job-detail-drawer-root #job-detail-sidebar[role='dialog']")
    refute has_element?(view, "#job-detail-drawer[checked]")
    refute has_element?(view, "#job-detail-job-id")

    render_click(element(view, "#job-#{job.id}"))

    assert_patch(view, ~p"/admin/jobs?job_id=#{job.id}&state=discarded")
    assert has_element?(view, "#job-detail-drawer-root")
    assert has_element?(view, "#job-detail-sidebar[role='dialog']")
    assert has_element?(view, "#job-detail-sidebar", "Job ##{job.id}")
    assert has_element?(view, "#job-detail-job-id", Integer.to_string(job.id))
    assert has_element?(view, "#job-detail-worker", "AccountReconciliationWorker")
    assert has_element?(view, "#job-detail-queue", "jobs")
    assert has_element?(view, "#job-detail-state", "Discarded")
    assert has_element?(view, "#job-detail-health", "Active failure")
    assert has_element?(view, "#job-detail-attempts", "2/5")
    assert has_element?(view, "#job-detail-inserted-at", "2026-05-04 10:00:00 UTC")
    assert has_element?(view, "#job-detail-scheduled-at", "2026-05-04 10:00:30 UTC")
    assert has_element?(view, "#job-detail-attempted-at", "2026-05-04 10:01:00 UTC")
    assert has_element?(view, "#job-detail-discarded-at", "2026-05-04 10:02:00 UTC")
    assert has_element?(view, "#job-detail-target-summary", "Pool: Drawer Pool")
    assert has_element?(view, "#job-detail-failure-summary", "Attempt 2 · RuntimeError")
    assert has_element?(view, "#job-detail-failure-summary", "pool reconciliation timeout")

    render_click(element(view, "#job-detail-sidebar-close"))

    assert_patch(view, ~p"/admin/jobs?state=discarded")
    refute has_element?(view, "#job-detail-sidebar", "Job ##{job.id}")
  end

  test "job detail drawer redacts args meta errors and raw sensitive strings", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: TokenRefreshWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:02:00Z],
        args: %{
          "prompt" => "drawer-raw-arg-prompt",
          "access_token" => "drawer-arg-access-token",
          "refresh_token" => "drawer-arg-refresh-token"
        },
        meta: %{
          "authorization" => "Bearer drawer-meta-bearer",
          "cookie" => "drawer-meta-cookie"
        },
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" =>
              "upstream timeout\nauthorization=Bearer drawer-error-bearer\tprompt=drawer-error-prompt cookie=drawer-error-cookie access_token=drawer-error-access refresh_token=drawer-error-refresh password=drawer-error-password secret=drawer-error-secret"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?job_id=#{job.id}")

    assert has_element?(view, "#job-detail-failure-summary", "Attempt 1 · RuntimeError")
    assert has_element?(view, "#job-detail-failure-summary", "upstream timeout")
    assert has_element?(view, "#job-detail-failure-summary", "[redacted]")

    rendered = render(view)
    refute rendered =~ "drawer-raw-arg-prompt"
    refute rendered =~ "drawer-arg-access-token"
    refute rendered =~ "drawer-arg-refresh-token"
    refute rendered =~ "drawer-meta-bearer"
    refute rendered =~ "drawer-meta-cookie"
    refute rendered =~ "drawer-error-bearer"
    refute rendered =~ "drawer-error-prompt"
    refute rendered =~ "drawer-error-cookie"
    refute rendered =~ "drawer-error-access"
    refute rendered =~ "drawer-error-refresh"
    refute rendered =~ "drawer-error-password"
    refute rendered =~ "drawer-error-secret"
  end

  test "clears drawer URL state when selected job is outside current filtered page", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        completed_at: ~U[2026-05-04 10:02:00Z]
      )

    assert {:error, {:live_redirect, %{to: "/admin/jobs"}}} =
             live(conn, ~p"/admin/jobs?job_id=#{job.id}")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    refute has_element?(view, "#job-detail-sidebar", "Job ##{job.id}")
    assert has_element?(view, "#filters_job_id[value='']")

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.selected_job == nil
    assert state.socket.assigns.filters.job_id == nil
  end

  defp set_datetime_preferences!(user, attrs) do
    {1, _rows} =
      from(operator in User, where: operator.id == ^user.id)
      |> Repo.update_all(set: attrs)

    :ok
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
        :queue,
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

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp state_label_selector(job),
    do: "#job-#{job.id} [data-role='state-label']:not([class*='bg-'])"

  defp worker_card_selector(worker_group) do
    "#job-worker-card-#{String.replace(Atom.to_string(worker_group), "_", "-")}"
  end

  defp maybe_put_worker_name(updates) do
    if Keyword.has_key?(updates, :worker) do
      Keyword.update!(updates, :worker, &worker_name/1)
    else
      updates
    end
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
