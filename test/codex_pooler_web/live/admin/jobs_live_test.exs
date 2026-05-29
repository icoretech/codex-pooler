defmodule CodexPoolerWeb.Admin.JobsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Jobs.AccountReconciliationWorker
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
        state: "completed",
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
    refute has_element?(view, "#admin-jobs-recent-activity")
    refute has_element?(view, "#job-#{job.id}")
    refute html =~ "RuntimeStateCleanupWorker"
    refute has_element?(view, "#admin-nav-jobs")
    refute has_element?(view, "#admin-nav-system")

    state = :sys.get_state(view.pid)
    refute state.socket.assigns.owner_authorized?
    assert state.socket.assigns.recent_jobs == []
    assert state.socket.assigns.subscribed_pool_ids == MapSet.new()
  end

  test "renders worker cards and compact recent activity", %{conn: conn} do
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

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#admin-jobs-page")
    assert has_element?(view, "#admin-jobs-page-header", "System Jobs")
    assert has_element?(view, "#admin-jobs-page-header", "Monitor background work")
    assert has_element?(view, "#admin-jobs-worker-grid")
    assert has_element?(view, worker_card_selector(:runtime_cleanup), "Runtime cleanup")
    assert has_element?(view, "#{worker_card_selector(:runtime_cleanup)} .hero-sparkles")
    assert has_element?(view, "#{worker_card_selector(:runtime_cleanup)}", "Completed")
    assert has_element?(view, "#{worker_card_selector(:runtime_cleanup)}", "Last success")
    assert has_element?(view, "#{worker_card_selector(:runtime_cleanup)}", "10:02:00 UTC")
    assert has_element?(view, "#{worker_card_selector(:runtime_cleanup)}", "Next run")
    assert has_element?(view, "#{worker_card_selector(:runtime_cleanup)}", "2/5")
    assert has_element?(view, "#{worker_card_selector(:catalog_sync)}", "Catalog sync")
    assert has_element?(view, "#{worker_card_selector(:catalog_sync)}", "Awaiting first run")

    assert has_element?(view, "#admin-jobs-recent-activity")
    refute has_element?(view, "#admin-jobs-table")
    assert has_element?(view, "#job-#{job.id}", "RuntimeStateCleanupWorker")
    assert has_element?(view, state_icon_selector(job, "Completed"))
    refute has_element?(view, "#job-#{job.id} [data-role='state-chip']")
    refute has_element?(view, "#job-#{job.id} [data-role='queue']")
    assert has_element?(view, "#job-#{job.id} [data-role='job-target-empty']", "-")

    assert has_element?(
             view,
             "#job-#{job.id} [data-role='worker']",
             "RuntimeStateCleanupWorker"
           )

    assert has_element?(view, "#job-#{job.id}", "2026-05-04")
    assert has_element?(view, "#job-#{job.id}", "10:00:00 UTC")
    assert has_element?(view, "#job-#{job.id}", "10:01:00 UTC")
    assert has_element?(view, "#job-#{job.id}", "10:02:00 UTC")
    refute has_element?(view, "#job-#{job.id}", DateTime.to_iso8601(job.inserted_at))
    refute has_element?(view, "#job-#{job.id}", DateTime.to_iso8601(job.attempted_at))
    refute has_element?(view, "#job-#{job.id}", DateTime.to_iso8601(job.completed_at))

    rendered = render(view)
    refute rendered =~ "secret-token-123"
    refute rendered =~ "raw-prompt-text"
    refute rendered =~ "authorization-bearer-value"
  end

  test "jobs read model owns admin jobs page data loading" do
    job =
      insert_job(
        1,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:00:00Z]
      )

    page_state = JobsReadModel.load(:system, limit: 5)

    assert [%{id: job_id}] = page_state.recent_jobs
    assert job_id == job.id
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
          "trigger_kind" => "scheduled"
        },
        errors: [
          %{
            "attempt" => 1,
            "error" => "account reconciliation partial: quota_refresh_unavailable"
          }
        ]
      )

    refresh_job =
      insert_job(
        2,
        worker: TokenRefreshWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:01:00Z],
        args: %{"upstream_identity_id" => identity.id, "trigger_kind" => "manual"}
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

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
             "#job-#{refresh_job.id} [data-role='target-primary']",
             "Account: Example upstream"
           )

    assert has_element?(
             view,
             "#job-#{refresh_job.id} [data-role='target-secondary']",
             "Status: active"
           )
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

  defp state_icon_selector(job, label) do
    "#job-#{job.id} [data-role='state-icon'][aria-label='State: #{label}']"
  end

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
