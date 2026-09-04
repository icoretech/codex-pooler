defmodule CodexPooler.Verification.RequestReplayMigrationProjection do
  @moduledoc false

  alias CodexPooler.Accounting.{Attempt, RequestLogFacts}
  alias CodexPooler.Repo

  @budget 15_000

  @type scenario ::
          :projection
          | :finalizer
          | :reader
          | :turn
          | :reservation
          | :pool
          | :model
          | :expiry
          | :writer_failure

  @spec run((-> :ok), scenario()) :: :ok
  def run(migrate, scenario \\ :projection) do
    [[request_id, attempt_id, assignment_id]] =
      query("SELECT request_id, id, pool_upstream_assignment_id FROM attempts LIMIT 1").rows

    attempt = %Attempt{
      id: Ecto.UUID.load!(attempt_id),
      request_id: Ecto.UUID.load!(request_id),
      pool_upstream_assignment_id: Ecto.UUID.load!(assignment_id),
      attempt_number: 1,
      status: "succeeded",
      retryable: false
    }

    parent = self()
    {:ok, supervisor} = Task.Supervisor.start_link()

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        writer(parent, request_id, attempt, scenario)
      end)

    try do
      writer_backend = receive_backend(:writer_locked_request)

      migration =
        Task.Supervisor.async_nolink(supervisor, fn -> timed_migration(migrate, scenario) end)

      migration_backend = await_migration_retry(writer_backend)

      receipt("projection_lock_retry", %{
        scenario: scenario,
        distinct_backends: writer_backend != migration_backend,
        partial_table_locks_released: true
      })

      finish(writer, migration, request_id, scenario)
    after
      Supervisor.stop(supervisor, :normal, @budget)
    end
  end

  defp finish(writer, migration, request_id, :expiry) do
    {:error, :lock_not_available} = await_task(migration)
    send(writer.pid, :project)
    {:ok, {:ok, :ok}} = await_task(writer)

    [[false, 0, true, true]] =
      query("""
      SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = 20260902024410),
        (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public'
          AND ((table_name = 'attempts' AND column_name = 'replay_generation')
            OR (table_name = 'codex_turns' AND column_name = 'semantic_turn_digest'))),
        to_regclass('public.request_replay_entitlements') IS NULL,
        to_regprocedure('public.request_replay_db_now()') IS NULL
      """).rows

    assert_projection!(request_id)

    receipt("projection_lock_expiry", %{
      writer: "committed",
      migration: "lock_not_available",
      schema_unchanged: true
    })

    :ok
  end

  defp finish(writer, migration, request_id, scenario) do
    send(writer.pid, :project)
    writer_result = await_task(writer)
    migration_result = await_task(migration)

    receipt("projection_lock_result", %{
      scenario: scenario,
      writer: result_class(writer_result),
      migration: result_class(migration_result)
    })

    unless writer_result == {:ok, {:ok, :ok}} and migration_result == {:ok, :ok} do
      raise "projection writer and migration must both commit without a deadlock"
    end

    assert_projection!(request_id)
    :ok
  end

  defp assert_projection!(request_id) do
    [[1]] =
      query("SELECT count(*) FROM request_log_facts WHERE request_id = $1", [request_id]).rows
  end

  defp timed_migration(migrate, scenario) do
    {duration, result} = :timer.tc(fn -> capture(migrate) end)
    receipt("migration_lock_duration", %{scenario: scenario, elapsed_ms: div(duration, 1000)})
    result
  end

  defp writer(parent, request_id, attempt, scenario) do
    capture(fn ->
      Repo.transaction(fn ->
        query("SET LOCAL deadlock_timeout = '500ms'")
        lock_writer_rows(request_id, attempt, scenario)
        [[backend]] = query("SELECT pg_backend_pid()").rows
        send(parent, {:writer_locked_request, backend})

        receive do
          :project ->
            if scenario == :writer_failure, do: raise("synthetic writer failure")
            RequestLogFacts.record_attempt_written!(attempt)
            query("UPDATE requests SET status = status WHERE id = $1", [request_id])
            :ok
        after
          @budget -> raise "projection writer release timeout"
        end
      end)
    end)
  end

  defp lock_writer_rows(request_id, _attempt, scenario)
       when scenario in [:projection, :expiry, :writer_failure] do
    query("UPDATE requests SET status = status WHERE id = $1", [request_id])
  end

  defp lock_writer_rows(request_id, attempt, :finalizer) do
    query("SELECT id FROM requests WHERE id = $1 FOR UPDATE", [request_id])
    query("SELECT id FROM attempts WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(attempt.id)])
    query("UPDATE attempts SET status = status WHERE id = $1", [Ecto.UUID.dump!(attempt.id)])
  end

  defp lock_writer_rows(request_id, _attempt, :reader) do
    query("SELECT id FROM codex_turns WHERE request_id = $1", [request_id])
  end

  defp lock_writer_rows(request_id, _attempt, :turn) do
    query("UPDATE codex_turns SET status = status WHERE request_id = $1", [request_id])
  end

  defp lock_writer_rows(request_id, _attempt, scenario) do
    {table, request_column} =
      case scenario do
        :reservation -> {"api_keys", "api_key_id"}
        :pool -> {"pools", "pool_id"}
        :model -> {"models", "model_id"}
      end

    query(
      "UPDATE #{table} SET id = id WHERE id = (SELECT #{request_column} FROM requests WHERE id = $1)",
      [request_id]
    )
  end

  defp receive_backend(event) do
    receive do
      {^event, backend} -> backend
    after
      @budget -> raise "projection writer readiness timeout"
    end
  end

  defp await_migration_retry(writer_backend) do
    await(fn ->
      case query(
             """
             SELECT activity.pid FROM pg_stat_activity activity
             WHERE activity.datname = current_database() AND activity.pid <> $1
               AND activity.wait_event = 'PgSleep' AND activity.query LIKE 'DO $migration_lock$%'
               AND NOT EXISTS (SELECT 1 FROM pg_locks held WHERE held.pid = activity.pid
                 AND held.relation = ANY(ARRAY['requests'::regclass, 'attempts'::regclass,
                   'codex_turns'::regclass, 'api_keys'::regclass, 'pools'::regclass, 'models'::regclass])
                 AND held.granted)
             """,
             [writer_backend]
           ).rows do
        [[backend]] -> {:ready, backend}
        [] -> :pending
      end
    end)
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + @budget)

  defp await(fun, deadline) do
    case fun.() do
      {:ready, result} ->
        result

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "expected PostgreSQL lock state not observed"
        end

        await(fun, deadline)
    end
  end

  defp capture(fun) do
    {:ok, fun.()}
  rescue
    error in Postgrex.Error -> {:error, error.postgres.code}
    _error -> {:error, :runtime_failure}
  end

  defp await_task(task) do
    case Task.yield(task, @budget) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :task_exit}
      nil -> {:error, :task_timeout}
    end
  end

  defp result_class({:error, code}), do: Atom.to_string(code)
  defp result_class({:ok, _result}), do: "committed"
  defp query(sql, params \\ []), do: Repo.query!(sql, params, log: false, timeout: @budget)
  defp receipt(stage, values), do: IO.puts(Jason.encode!(Map.put(values, :stage, stage)))
end
