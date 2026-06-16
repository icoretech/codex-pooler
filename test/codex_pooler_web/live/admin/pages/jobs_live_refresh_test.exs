defmodule CodexPoolerWeb.Admin.JobsLiveRefreshTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CodexPooler.Events
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "job status events refresh rows after the debounce", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug("jobs-pubsub"), name: "Jobs PubSub"})

    job =
      insert_job(
        1,
        state: "available",
        inserted_at: ~U[2026-05-04 13:00:00Z],
        completed_at: nil
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")

    assert has_element?(view, state_label_selector(job), "Available")
    refute has_element?(view, state_label_selector(job), "Completed")

    updated_job =
      update_job(job,
        state: "completed",
        completed_at: ~U[2026-05-04 13:01:00Z]
      )

    assert {:ok, _event} =
             Events.broadcast_job_status(pool.id, "job_status_updated", %{
               id: Integer.to_string(updated_job.id),
               status: "completed"
             })

    state = :sys.get_state(view.pid)
    assert is_reference(state.socket.assigns.jobs_reload_timer)
    assert has_element?(view, state_label_selector(job), "Available")

    send(view.pid, :refresh_jobs)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, state_label_selector(job), "Completed")
    assert has_element?(view, "#job-#{job.id}", "2026-05-04")
    assert has_element?(view, "#job-#{job.id}", "13:01:00 UTC")
    refute has_element?(view, "#job-#{job.id}", DateTime.to_iso8601(updated_job.completed_at))
  end

  test "limits explorer rows to the first 20-row page", %{conn: conn} do
    base_time = ~U[2026-05-04 16:00:00Z]

    jobs =
      for index <- 1..51 do
        insert_job(index,
          state: "available",
          inserted_at: DateTime.add(base_time, index, :second)
        )
      end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    rendered = render(view)

    assert count_occurrences(rendered, ~s(<tr id="job-)) == 20
    assert count_occurrences(rendered, ~s(<article id="job-card-)) == 20
    assert has_element?(view, "#admin-jobs-explorer-total", "51 jobs")
    assert has_element?(view, "#admin-jobs-explorer-range", "Showing 1-20 of 51")
    assert has_element?(view, "#job-#{List.last(jobs).id}")
    refute has_element?(view, "#job-#{List.first(jobs).id}")
  end

  test "internal fallback refresh message loads jobs inserted after render", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#admin-jobs-empty-state", "No jobs match these filters")

    job =
      insert_job(
        1,
        state: "available",
        inserted_at: ~U[2026-05-04 14:00:00Z]
      )

    send(view.pid, :fallback_refresh_jobs)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, state_label_selector(job), "Available")
    refute has_element?(view, "#admin-jobs-empty-state")
  end

  test "refreshes preserve URL-backed filters and selected job state", %{conn: conn} do
    selected_job =
      insert_job(
        1,
        state: "available",
        inserted_at: ~U[2026-05-04 14:00:00Z]
      )

    hidden_job =
      insert_job(
        2,
        state: "completed",
        inserted_at: ~U[2026-05-04 14:01:00Z],
        completed_at: ~U[2026-05-04 14:02:00Z]
      )

    {:ok, view, _html} =
      live(conn, ~p"/admin/jobs?state=available&job_id=#{selected_job.id}&page=1")

    assert_url_backed_available_selection(view, selected_job, hidden_job)

    send(view.pid, :refresh_jobs)
    _ = :sys.get_state(view.pid)
    assert_url_backed_available_selection(view, selected_job, hidden_job)

    send(view.pid, :fallback_refresh_jobs)
    _ = :sys.get_state(view.pid)
    assert_url_backed_available_selection(view, selected_job, hidden_job)
  end

  test "unknown and deleted job status events do not crash", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug("jobs-deleted"), name: "Jobs Deleted"})

    job = insert_job(1, state: "available", inserted_at: ~U[2026-05-04 15:00:00Z])
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    monitor_ref = Process.monitor(view.pid)

    assert has_element?(view, state_label_selector(job), "Available")

    delete_job(job)

    assert {:ok, _event} =
             Events.broadcast_job_status(pool.id, "job_status_updated", %{
               id: Integer.to_string(job.id),
               status: "deleted"
             })

    state = :sys.get_state(view.pid)
    assert is_reference(state.socket.assigns.jobs_reload_timer)

    send(view.pid, :refresh_jobs)
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#job-#{job.id}")

    send(
      view.pid,
      {Events, %{pool_id: Ecto.UUID.generate(), topics: ["job_status"], payload: :unknown}}
    )

    _ = :sys.get_state(view.pid)
    refute_receive {:DOWN, ^monitor_ref, :process, _pid, _reason}
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

  defp update_job(job, attrs) do
    updates = Keyword.take(attrs, [:state, :completed_at])

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end

  defp delete_job(job) do
    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.delete_all()

    :ok
  end

  defp assert_url_backed_available_selection(view, selected_job, hidden_job) do
    state = :sys.get_state(view.pid)
    assigns = state.socket.assigns

    assert assigns.current_params == %{
             "job_id" => Integer.to_string(selected_job.id),
             "page" => "1",
             "state" => "available"
           }

    assert assigns.filters.state == "available"
    assert assigns.filters.job_id == selected_job.id
    assert assigns.form_values["state"] == "available"
    assert assigns.form_values["job_id"] == Integer.to_string(selected_job.id)
    assert assigns.filter_warnings == []
    assert assigns.filter_errors == []
    assert assigns.selected_job.id == selected_job.id
    assert Enum.map(assigns.explorer.items, & &1.id) == [selected_job.id]
    assert assigns.explorer.total == 1
    assert is_map(assigns.overview)
    assert Enum.all?(assigns.explorer.items, &(&1.id != hidden_job.id))
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp state_label_selector(job),
    do: "#job-#{job.id} [data-role='state-label']:not([class*='bg-'])"

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
