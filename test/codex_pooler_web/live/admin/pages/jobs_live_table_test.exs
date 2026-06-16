defmodule CodexPoolerWeb.Admin.JobsLiveTableTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "renders exactly one sidebar Jobs entry", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(
             view,
             "#admin-nav-jobs[aria-current='page'][href='/admin/jobs']",
             "System Jobs"
           )

    assert render(view) |> count_occurrences(~s(id="admin-nav-jobs")) == 1
  end

  test "renders empty state when no jobs exist", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#admin-jobs-worker-grid")
    assert has_element?(view, worker_card_selector(:catalog_sync), "Catalog sync")

    refute has_element?(
             view,
             "#{worker_card_selector(:catalog_sync)} [data-role='worker-state-badge']"
           )

    assert has_element?(view, worker_card_selector(:token_refresh), "Token refresh")

    assert has_element?(
             view,
             "#{worker_card_selector(:token_refresh)} [data-role='schedule'] [data-role='cadence-label']",
             "Every 15 min"
           )

    refute has_element?(
             view,
             "#{worker_card_selector(:token_refresh)} [data-role='worker-state-badge']"
           )

    refute has_element?(
             view,
             "#{worker_card_selector(:token_refresh)} [data-role='job-worker-card-actions']"
           )

    assert has_element?(view, "#admin-jobs-explorer")
    assert has_element?(view, "#admin-jobs-explorer-total", "0 jobs")
    assert has_element?(view, "#admin-jobs-explorer-range", "Showing 0 of 0")
    assert has_element?(view, "#admin-jobs-empty-state", "No jobs match these filters")
    refute has_element?(view, "#admin-jobs-explorer-table")
    refute has_element?(view, "#admin-jobs-explorer-mobile")
  end

  test "worker cards use worker-specific history beyond the explorer page slice", %{conn: conn} do
    catalog_job =
      insert_job(
        1,
        worker: CatalogSyncWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        completed_at: ~U[2026-05-04 10:01:00Z]
      )

    for index <- 2..56 do
      insert_job(index,
        worker: AccountReconciliationWorker,
        state: "completed",
        inserted_at: DateTime.add(~U[2026-05-04 11:00:00Z], index, :second),
        completed_at: DateTime.add(~U[2026-05-04 11:01:00Z], index, :second)
      )
    end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    refute has_element?(view, "#job-#{catalog_job.id}")

    refute has_element?(
             view,
             "#{worker_card_selector(:catalog_sync)} [data-role='worker-state-badge']"
           )

    assert has_element?(view, worker_card_selector(:catalog_sync), "10:01:00 UTC")
  end

  test "worker cards show the next scheduled job when one is queued", %{conn: conn} do
    scheduled_at =
      DateTime.utc_now() |> DateTime.add(1_200, :second) |> DateTime.truncate(:second)

    insert_job(
      1,
      worker: TokenRefreshWorker,
      state: "scheduled",
      inserted_at: DateTime.add(scheduled_at, -60, :second),
      scheduled_at: scheduled_at
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, worker_card_selector(:token_refresh), "Next run")
    assert has_element?(view, "#{worker_card_selector(:token_refresh)} [data-role='next-run']")
  end

  test "renders uncommon state and missing timestamps safely", %{conn: conn} do
    job =
      insert_job(
        1,
        state: "suspended",
        inserted_at: ~U[2026-05-04 11:00:00Z],
        attempted_at: nil,
        completed_at: nil,
        discarded_at: nil,
        cancelled_at: nil
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, state_label_selector(job), "Suspended")
    assert has_element?(view, "#job-#{job.id}", "-")
    refute has_element?(view, "#job-#{job.id}", "not recorded")
  end

  test "represents known job states with row text", %{conn: conn} do
    base_time = ~U[2026-05-04 12:00:00Z]

    expected_states = [
      {"available", "Available"},
      {"scheduled", "Scheduled"},
      {"executing", "Executing"},
      {"retryable", "Retryable"},
      {"completed", "Completed"},
      {"discarded", "Discarded"},
      {"cancelled", "Cancelled"}
    ]

    jobs =
      for {{state, label}, index} <- Enum.with_index(expected_states, 1) do
        job =
          insert_job(index,
            state: state,
            inserted_at: DateTime.add(base_time, index, :second)
          )

        {job, label}
      end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")

    for {job, label} <- jobs do
      assert has_element?(view, state_label_selector(job), label)
      refute has_element?(view, "#job-#{job.id} [data-role='state-icon']")
    end
  end

  test "explorer hides completed jobs by default and includes them explicitly", %{conn: conn} do
    completed_job =
      insert_job(1,
        state: "completed",
        inserted_at: ~U[2026-05-04 12:00:00Z],
        completed_at: ~U[2026-05-04 12:01:00Z]
      )

    available_job = insert_job(2, state: "available", inserted_at: ~U[2026-05-04 12:02:00Z])

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#admin-jobs-explorer")
    assert has_element?(view, "#admin-jobs-explorer-total", "1 job")
    assert has_element?(view, "#admin-jobs-explorer-desktop #job-#{available_job.id}")
    assert has_element?(view, "#admin-jobs-explorer-mobile #job-card-#{available_job.id}")
    refute has_element?(view, "#job-#{completed_job.id}")
    refute has_element?(view, "#job-card-#{completed_job.id}")

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")

    assert has_element?(view, "#admin-jobs-explorer-total", "2 jobs")
    assert has_element?(view, "#admin-jobs-explorer-desktop #job-#{completed_job.id}")
    assert has_element?(view, "#admin-jobs-explorer-mobile #job-card-#{completed_job.id}")
  end

  test "desktop explorer rows use compact one-event summaries", %{conn: conn} do
    job =
      insert_job(1,
        state: "discarded",
        attempt: 2,
        max_attempts: 5,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:01:00Z],
        discarded_at: ~U[2026-05-04 10:02:00Z],
        errors: [
          %{
            "attempt" => 2,
            "kind" => "RuntimeError",
            "error" => "pool reconciliation timeout"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?state=discarded")
    row = "#admin-jobs-explorer-desktop #job-#{job.id}"

    assert has_element?(view, "#{row}[data-density='compact']")
    assert has_element?(view, "#{row} [data-role='state-label']", "Discarded")
    assert has_element?(view, "#{row} [data-role='worker']", "RuntimeStateCleanupWorker")
    assert has_element?(view, "#{row} [data-role='job-meta']", "##{job.id}")
    assert has_element?(view, "#{row} [data-role='job-event-label']", "Discarded")
    assert has_element?(view, "#{row} [data-role='job-event-time']", "2026-05-04 10:02:00 UTC")
    refute has_element?(view, "#{row} [data-role='job-event-time'].font-mono")
    refute has_element?(view, "#{row} [data-role='attempts'].font-mono")
    assert has_element?(view, "#{row} [data-role='failure-title']", "Attempt 2 · RuntimeError")

    refute has_element?(view, "#{row} [data-role='inserted-at']")
    refute has_element?(view, "#{row} [data-role='attempted-at']")
    refute has_element?(view, "#{row} [data-role='discarded-at']")
  end

  test "explorer paginates globally with stable desktop and mobile selectors", %{conn: conn} do
    base_time = ~U[2026-05-04 12:00:00Z]

    jobs =
      for index <- 1..55 do
        insert_job(index,
          state: "available",
          inserted_at: DateTime.add(base_time, index, :second)
        )
      end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    rendered = render(view)

    assert has_element?(view, "#admin-jobs-explorer")
    assert rendered =~ ~s(id="admin-jobs-explorer" class="grid min-w-0 gap-3")
    assert rendered =~ ~s(id="admin-jobs-explorer-table" class="table table-sm admin-log-table)
    assert has_element?(view, "#admin-jobs-explorer-total", "55 jobs")
    assert has_element?(view, "#admin-jobs-explorer-range", "Showing 1-20 of 55")
    refute has_element?(view, "#admin-jobs-explorer-table th", "State")

    assert has_element?(
             view,
             "#admin-jobs-explorer-pagination #admin-jobs-explorer-range",
             "Showing 1-20 of 55"
           )

    assert has_element?(view, "#admin-jobs-explorer-pagination", "Page 1 of 3")
    assert has_element?(view, "#admin-jobs-explorer-pagination-prev[aria-disabled='true']")
    assert has_element?(view, "#admin-jobs-explorer-pagination-next[href='/admin/jobs?page=2']")
    assert count_occurrences(rendered, ~s(<tr id="job-)) == 20
    assert count_occurrences(rendered, ~s(<article id="job-card-)) == 20
    assert has_element?(view, "#admin-jobs-explorer-desktop #job-#{List.last(jobs).id}")
    assert has_element?(view, "#admin-jobs-explorer-mobile #job-card-#{List.last(jobs).id}")
    refute has_element?(view, "#job-#{List.first(jobs).id}")
    refute has_element?(view, "#job-card-#{List.first(jobs).id}")

    render_click(element(view, "#admin-jobs-explorer-pagination-next"))
    assert_patch(view, ~p"/admin/jobs?page=2")

    assert has_element?(view, "#admin-jobs-explorer-range", "Showing 21-40 of 55")
    assert has_element?(view, "#admin-jobs-explorer-pagination", "Page 2 of 3")
    assert has_element?(view, "#admin-jobs-explorer-pagination-prev[href='/admin/jobs']")
    assert has_element?(view, "#admin-jobs-explorer-pagination-next[href='/admin/jobs?page=3']")
    refute has_element?(view, "#admin-jobs-explorer-desktop #job-#{List.first(jobs).id}")
    refute has_element?(view, "#admin-jobs-explorer-mobile #job-card-#{List.first(jobs).id}")
  end

  test "does not render job mutation controls", %{conn: conn} do
    insert_job(1, inserted_at: ~U[2026-05-04 12:00:00Z])
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    for label <- ["Retry", "Cancel", "Discard", "Delete"] do
      refute has_element?(view, "#admin-jobs-explorer [data-role='job-row'] button", label)
      refute has_element?(view, "#admin-jobs-explorer [data-role='job-row'] a", label)
      refute has_element?(view, "#admin-jobs-explorer [data-role='job-card'] button", label)
      refute has_element?(view, "#admin-jobs-explorer [data-role='job-card'] a", label)
    end
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

  defp state_label_selector(job),
    do: "#job-#{job.id} [data-role='state-label']:not([class*='bg-'])"

  defp worker_card_selector(worker_group) do
    "#job-worker-card-#{String.replace(Atom.to_string(worker_group), "_", "-")}"
  end

  defp count_occurrences(source, pattern) do
    source
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
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
