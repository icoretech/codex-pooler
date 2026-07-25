defmodule CodexPooler.Jobs.JobsExplorerTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Jobs.ReadModel

  alias CodexPooler.Jobs.{
    CatalogSyncWorker,
    DailyRollupRebuildWorker,
    RuntimeStateCleanupWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.JobFilterForm

  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "jobs explorer" do
    test "returns total and stable inserted_at/id pagination without completed rows by default" do
      base_time = ~U[2026-06-02 10:00:00Z]

      completed_job =
        insert_explorer_job(0,
          state: "completed",
          inserted_at: DateTime.add(base_time, 120, :second),
          completed_at: DateTime.add(base_time, 121, :second)
        )

      for index <- 1..53 do
        insert_explorer_job(index, inserted_at: DateTime.add(base_time, index, :second))
      end

      same_inserted_at = ~U[2026-06-02 12:00:00Z]
      older_tie = insert_explorer_job(54, inserted_at: same_inserted_at)
      newer_tie = insert_explorer_job(55, inserted_at: same_inserted_at)

      first_page = ReadModel.list_explorer_jobs(:system, filters(%{}), now: base_time)

      assert %{total: 55, limit: 20, offset: 0, items: first_items} = first_page
      assert length(first_items) == 20
      assert Enum.map(first_items, & &1.id) |> Enum.take(2) == [newer_tie.id, older_tie.id]
      refute Enum.any?(first_items, &(&1.id == completed_job.id))
      assert Enum.all?(first_items, &safe_explorer_job_shape?/1)

      second_page =
        ReadModel.list_explorer_jobs(:system, filters(%{"page" => "2"}), now: base_time)

      assert %{total: 55, limit: 20, offset: 20, items: second_items} = second_page
      assert length(second_items) == 20
      refute Enum.any?(second_items, &(&1.id == completed_job.id))
    end

    test "includes completed rows only when requested or filtered explicitly" do
      completed_job =
        insert_explorer_job(1,
          state: "completed",
          inserted_at: ~U[2026-06-02 10:00:00Z],
          completed_at: ~U[2026-06-02 10:01:00Z]
        )

      available_job = insert_explorer_job(2, inserted_at: ~U[2026-06-02 10:02:00Z])

      assert %{items: [%{id: available_id}], total: 1} =
               ReadModel.list_explorer_jobs(:system, filters(%{}))

      assert available_id == available_job.id

      assert %{items: show_completed_items, total: 2} =
               ReadModel.list_explorer_jobs(:system, filters(%{"show_completed" => "true"}))

      assert Enum.map(show_completed_items, & &1.id) == [available_job.id, completed_job.id]

      assert %{items: [%{id: completed_id}], total: 1} =
               ReadModel.list_explorer_jobs(
                 :system,
                 filters(%{"state" => "completed", "show_completed" => "true"})
               )

      assert completed_id == completed_job.id
    end

    test "filters by state, attention, worker, and safe target ids" do
      now = ~U[2026-06-02 10:30:00Z]
      pool = pool_fixture()
      %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
      %{api_key: api_key} = active_api_key_fixture(pool)

      retry_job =
        insert_explorer_job(1,
          worker: TokenRefreshWorker,
          state: "retryable",
          queue: "jobs",
          attempt: 3,
          inserted_at: ~U[2026-06-02 10:00:00Z],
          attempted_at: ~U[2026-06-02 10:01:00Z],
          args: %{"upstream_identity_id" => identity.id}
        )

      assignment_job =
        insert_explorer_job(2,
          worker: CatalogSyncWorker,
          queue: "jobs",
          inserted_at: ~U[2026-06-02 10:02:00Z],
          args: %{"pool_id" => pool.id, "pool_upstream_assignment_id" => assignment.id}
        )

      api_key_job =
        insert_explorer_job(3,
          queue: "critical",
          inserted_at: ~U[2026-06-02 10:03:00Z],
          args: %{"api_key_id" => api_key.id}
        )

      rollup_job =
        insert_explorer_job(4,
          worker: DailyRollupRebuildWorker,
          inserted_at: ~U[2026-06-02 10:04:00Z],
          args: %{"rollup_date" => "2026-06-01"}
        )

      system_job = insert_explorer_job(5, inserted_at: ~U[2026-06-02 10:05:00Z])

      assert_ids(filters(%{"state" => "retryable"}), [retry_job.id], now: now)
      assert_ids(filters(%{"attention" => "retry_pressure"}), [retry_job.id], now: now)

      assert_ids(filters(%{"worker" => worker_name(TokenRefreshWorker)}), [retry_job.id],
        now: now
      )

      assert_ids(
        filters(%{"target_kind" => "assignment", "target_id" => assignment.id}),
        [assignment_job.id],
        now: now
      )

      assert_ids(
        filters(%{"target_kind" => "upstream_identity", "target_id" => identity.id}),
        [retry_job.id],
        now: now
      )

      assert_ids(filters(%{"target_kind" => "pool", "target_id" => pool.id}), [assignment_job.id],
        now: now
      )

      assert_ids(
        filters(%{"target_kind" => "api_key", "target_id" => api_key.id}),
        [api_key_job.id],
        now: now
      )

      assert_ids(
        filters(%{"target_kind" => "rollup_date", "target_id" => "2026-06-01"}),
        [rollup_job.id],
        now: now
      )

      assert_ids(filters(%{"target_kind" => "system"}), [system_job.id], now: now)

      assert %{items: [%{attention_state: :retry_pressure}]} =
               ReadModel.list_explorer_jobs(:system, filters(%{"attention" => "retry_pressure"}),
                 now: now
               )
    end

    test "returns metadata-only rows without args, meta, raw errors, or sensitive strings" do
      sensitive_values = [
        "secret-token-123",
        "raw-prompt-text",
        "request-body-json",
        "cookie-header-value",
        "auth-json-refresh-token",
        "websocket-frame-bytes",
        "stacktrace-with-secret"
      ]

      insert_explorer_job(1,
        inserted_at: ~U[2026-06-02 10:00:00Z],
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
            "at" => DateTime.to_iso8601(~U[2026-06-02 10:01:00Z]),
            "attempt" => 1,
            "error" => "stacktrace-with-secret"
          }
        ]
      )

      assert %{items: [result], total: 1, limit: 20, offset: 0} =
               ReadModel.list_explorer_jobs(:system, filters(%{}))

      assert safe_explorer_job_shape?(result)

      assert result.failure_summary == %{
               title: "Attempt 1",
               message: "stacktrace-with-[redacted]"
             }

      refute Map.has_key?(result, :errors)
      refute Map.has_key?(result, :args)
      refute Map.has_key?(result, :meta)

      serialized = inspect(result)
      Enum.each(sensitive_values, &refute(serialized =~ &1))
    end
  end

  defp assert_ids(filters, expected_ids, opts) do
    result = ReadModel.list_explorer_jobs(:system, filters, opts)
    assert Enum.map(result.items, & &1.id) == expected_ids
    assert result.total == length(expected_ids)
  end

  defp filters(params) do
    {filters, _form_values, []} = JobFilterForm.parse_filters(params)
    filters
  end

  defp insert_explorer_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{}) |> Map.put_new("index", index)
    meta = Keyword.get(attrs, :meta, %{"source" => "explorer-test"})

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

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp safe_explorer_job_shape?(job) do
    keys = job |> Map.keys() |> MapSet.new()

    MapSet.equal?(keys, MapSet.new(safe_explorer_job_keys())) or
      MapSet.equal?(keys, MapSet.new([:failure_summary | safe_explorer_job_keys()]))
  end

  defp safe_explorer_job_keys do
    [
      :id,
      :state,
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
