defmodule CodexPoolerWeb.Admin.JobsReadModelTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.{RuntimeStateCleanupWorker, TokenRefreshWorker}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.JobsReadModel

  import CodexPooler.AccountsFixtures

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
      %{key: :token_refresh, workers: [worker_name(TokenRefreshWorker)]},
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
      active: [],
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
