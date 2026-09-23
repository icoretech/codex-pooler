defmodule CodexPooler.RollupCoverageFence do
  @moduledoc """
  Puts the committed `daily_rollup_coverages` rows back the way each sync test found them.

  PostgreSQL writes those rows, not the test: constraint triggers on `requests`, `ledger_entries`
  and `daily_rollups` (migration `20260815010747`, `mark_pool_daily_rollup_dates_mutated/1`) mark
  a date as mutated whenever a row that projects onto a date *before the database's current UTC
  day* is inserted, moved or deleted. Which day that is depends on the database clock at commit,
  so a test that commits accounting rows outside the sandbox writes a coverage row only when it
  straddles 00:00 UTC: a request admitted a few minutes before midnight and committed after it,
  or a Pool graph created before midnight whose cleanup deletes it after. The same test is clean
  at any other time of day, so no fixture can own the row by construction, and the rows it leaves
  make every later test that touches that date fail (Drone 1507: four tests red at 00:00:00 UTC).

  The fence therefore belongs to the test lifecycle, like the settings cache `DataCase` snapshots:
  `fence_test!/1` reads the committed rows when a sync test starts and registers a callback that
  runs after every cleanup of the test and after the sandbox owner stops, just before
  `CodexPooler.CommittedWriteGuard` verifies. When the rows differ, the callback deletes the
  dates the test added and writes the rows it found back exactly, `created_at` and
  `mutation_version` included. Only this table is restored: a leaked request, ledger entry or
  rollup row still fails its test through the guard, and so does a coverage row written after the
  fence ran, by a process that outlived the test.

  The reads and writes go over a connection of the fence's own, opened by `start!/0` before the
  guard starts counting, so the fence never makes a call the guard counts. A sync test pays one
  single-table read when it starts; the closing read runs only when the test made a call the guard
  counts or had a node connected, the same condition under which the guard compares content. Two
  reads cost 0.92 ms at p50 against a 0.54 ms `SELECT 1` round trip (n=500, host load 9-24), so
  the skipped closing read keeps a test that cannot commit at one round trip. Async tests are not
  fenced; they must not commit.
  """

  alias CodexPooler.CommittedWriteGuard

  @key {__MODULE__, :conn}
  @callback_ref {__MODULE__, :restore}

  # Failure-detection budgets for one statement and one lock wait, not behaviour timers.
  @lock_timeout "5s"
  @statement_timeout "20s"

  @connection_keys [
    :hostname,
    :port,
    :username,
    :password,
    :socket_dir,
    :socket_options,
    :ssl,
    :ssl_opts,
    :connect_timeout,
    :database
  ]

  @columns "rollup_date, contract_version, completed_at, mutation_version, created_at, updated_at"

  @select_sql "SELECT #{@columns} FROM public.daily_rollup_coverages ORDER BY rollup_date"

  @delete_sql "DELETE FROM public.daily_rollup_coverages WHERE NOT (rollup_date = ANY($1::date[]))"

  @upsert_sql """
  INSERT INTO public.daily_rollup_coverages (#{@columns})
  VALUES ($1, $2, $3, $4, $5, $6)
  ON CONFLICT (rollup_date) DO UPDATE SET
    contract_version = EXCLUDED.contract_version,
    completed_at = EXCLUDED.completed_at,
    mutation_version = EXCLUDED.mutation_version,
    created_at = EXCLUDED.created_at,
    updated_at = EXCLUDED.updated_at
  """

  @type snapshot :: [list()]

  @doc """
  Opens the fence's connection for this `mix test` invocation. Call it once from
  `test/test_helper.exs`, before `CodexPooler.CommittedWriteGuard.start!/0`.
  """
  @spec start!(keyword()) :: :ok
  def start!(opts \\ []) do
    repo_config = Keyword.get_lazy(opts, :repo_config, &CodexPooler.Repo.config/0)

    {:ok, conn} =
      repo_config
      |> Keyword.take(@connection_keys)
      |> Keyword.merge(
        pool_size: 1,
        parameters: [
          application_name: "codex_pooler_test_rollup_coverage_fence",
          lock_timeout: @lock_timeout,
          statement_timeout: @statement_timeout
        ]
      )
      |> Postgrex.start_link()

    :persistent_term.put(@key, conn)
    :ok
  end

  @doc """
  Fences the calling sync test. `CodexPooler.DataCase.setup_sandbox/1` calls it after the guard's
  verification is registered and before the sandbox owner's stop, so the restore runs after the
  owner stopped and before the guard verifies; a plain `ExUnit.Case` module gets it from
  `use CodexPooler.CommittedWriteGuard`. Does nothing for an `async: true` test or when the fence
  was not started.
  """
  @spec fence_test!(map()) :: :ok
  def fence_test!(tags) do
    case {tags[:async], :persistent_term.get(@key, nil)} do
      {true, _conn} ->
        :ok

      {_async, nil} ->
        :ok

      {_async, conn} ->
        found = snapshot!(conn)
        counters = CommittedWriteGuard.counters()
        ExUnit.Callbacks.on_exit(@callback_ref, fn -> close!(conn, found, counters) end)
    end
  end

  @doc "The committed coverage rows, in date order."
  @spec snapshot!(pid()) :: snapshot()
  def snapshot!(conn), do: Postgrex.query!(conn, @select_sql, []).rows

  @doc """
  Writes `found` back when the committed rows differ from it. Returns the dates it deleted and
  the dates it wrote back.
  """
  @spec restore!(pid(), snapshot()) :: %{deleted: [Date.t()], restored: [Date.t()]}
  def restore!(conn, found) do
    case snapshot!(conn) do
      ^found -> %{deleted: [], restored: []}
      current -> write_back!(conn, found, current)
    end
  end

  defp write_back!(conn, found, current) do
    found_dates = Enum.map(found, &hd/1)
    deleted = current |> Enum.map(&hd/1) |> Enum.reject(&(&1 in found_dates))
    restored = Enum.reject(found, &(&1 in current))

    {:ok, :ok} =
      Postgrex.transaction(conn, fn conn ->
        Postgrex.query!(conn, @delete_sql, [found_dates])
        Enum.each(restored, &Postgrex.query!(conn, @upsert_sql, &1))
      end)

    result = %{deleted: deleted, restored: Enum.map(restored, &hd/1)}

    CodexPooler.TestDiagnostics.puts(fn ->
      "rollup coverage fence: deleted=#{inspect(result.deleted)} restored=#{inspect(result.restored)}"
    end)

    result
  end

  # A test that made no call the guard counts and had no node connected cannot have committed
  # through a channel the guard sees, so its closing read is skipped. A commit through a channel
  # it cannot see is not fenced; the guard reports that one as it reports any other.
  defp close!(conn, found, counters) do
    unless quiet?(counters), do: restore!(conn, found)
    :ok
  end

  defp quiet?(nil), do: false
  defp quiet?(counters), do: CommittedWriteGuard.counters() == counters and Node.list(:connected) == []
end
