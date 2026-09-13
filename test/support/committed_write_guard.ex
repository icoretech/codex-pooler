defmodule CodexPooler.CommittedWriteGuard do
  @moduledoc """
  Fails a test that leaves committed rows behind, and names the tables.

  A row written inside the Ecto sandbox rolls back with its test. A row committed outside it,
  through `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, `Sandbox.mode(Repo, :auto)`, a connection of
  its own, a `:peer` node or a child `mix` VM, survives into every later test of the same
  `mix test` invocation and surfaces there as a failure in a file that has nothing to do with it.
  Every table of the schema is watched, so rows no user path reaches, such as an identity created
  without a creator or a pricing snapshot, count as much as an owner's graph. A table with a
  `singleton` column is also compared by content, so an update to the instance settings or the
  bootstrap state that nothing puts back fails as well; timestamps and `lock_version` are left out
  of that comparison, because putting a value back through the domain API rewrites them.

  ## Cost on the sandboxed path

  A trace session counts calls to `entry_points/0` with `call_count`, which the VM keeps
  synchronously and without sending messages. A guarded test reads the counters when its setup
  starts and again after its last `on_exit` callback. When no counter moved and no other node is
  connected, the guard does nothing more: no message, no query. Otherwise the rows of every watched
  table are counted over the guard's own connection and compared with the committed state the
  guard verified last. Tests in `async: true` modules are not guarded: they run before every sync
  module, where concurrent sandbox owners would move each other's counters and every one of them
  would pay for a count, and they must not commit anyway.

  ## What it cannot see

  The entry points are the calls through which this suite commits outside the sandbox: the sandbox
  modes, a new connection (`DBConnection.start_link/2`, which `Postgrex.start_link/1` and every
  Repo start go through, and `Postgrex.SimpleConnection`), a node (`:peer`, `:erpc`, `:rpc`) and a
  child OS process (`System.cmd/3`). A commit that makes none of those calls while no node is
  connected, such as a query on a connection opened before the test or a port opened directly, is
  not seen by the test that made it. It is reported by the next test whose counters move, which
  fails in setup when the rows changed before it started and in its own verification otherwise,
  and after the suite, where the rows are always counted once more.

  ## Coverage

  `CodexPooler.DataCase.setup_sandbox/1`, and through it `CodexPoolerWeb.ConnCase`, guards every
  sync test. A module on plain `ExUnit.Case` that commits outside the sandbox puts
  `use CodexPooler.CommittedWriteGuard` directly below `use ExUnit.Case`: the guard registers its
  `on_exit` before any other callback so that it runs after all of them, cleanups included.

  Counters that move outside every guarded test (an unguarded module, a `setup_all`, a process that
  outlived its test) are verified when the next guarded test starts. That test fails in setup with
  the tables and a message saying the rows are not its own. After the last test the rows are
  counted once more whatever the counters say, and a change there fails the run.
  """

  use GenServer

  alias CodexPooler.TestDiagnostics

  @server __MODULE__
  @table __MODULE__
  @verify_callback {__MODULE__, :verify}

  # Every call through which this suite commits outside the sandbox. `mode/2` and `checkout/2` also
  # count the calls `Sandbox.start_owner!/2` makes for an ordinary sandboxed test;
  # `register_verify!/1` absorbs those as the harness's own. `call_count` counts local calls too, so
  # `:erpc.call/4` delegating to `call/5` moves both counters, which is harmless.
  @entry_points [
    {Ecto.Adapters.SQL.Sandbox, :unboxed_run, 2},
    {Ecto.Adapters.SQL.Sandbox, :mode, 2},
    {Ecto.Adapters.SQL.Sandbox, :checkout, 2},
    {DBConnection, :start_link, 2},
    {Postgrex.SimpleConnection, :start_link, 3},
    {:peer, :start, 1},
    {:peer, :start_link, 1},
    {:peer, :call, 4},
    {:peer, :call, 5},
    {:erpc, :call, 4},
    {:erpc, :call, 5},
    {:rpc, :call, 4},
    {:rpc, :call, 5},
    {System, :cmd, 3}
  ]

  # Tables the harness writes while tests run and no test owns. None: `schema_migrations` is
  # written before the first test and only migration tests move it, restoring it themselves;
  # Oban runs with `testing: :manual` and an isolated peer, so it writes no `oban_*` row; the
  # `instance_settings` singleton is committed by `test/test_helper.exs` before the guard starts
  # and tests only update it; nothing in the test runtime imports pricing snapshots, and a leaked
  # one is exactly the findings#188 failure.
  @harness_tables []

  # Columns a restore through the domain API rewrites without changing what the row says.
  @bookkeeping_columns ["lock_version"]

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

  # Failure-detection budget for one row count, not a behaviour timer. The guard's connection also
  # bounds its own lock wait, so a leaked `ACCESS EXCLUSIVE` lock fails the test with the Postgres
  # error instead of stalling it.
  @verify_timeout_ms 30_000
  @lock_timeout "5s"
  @statement_timeout "20s"

  @type counts :: tuple()
  @type window :: %{where: map(), start: counts(), session: term()} | nil

  defmacro __using__(_opts) do
    quote do
      setup context do
        CodexPooler.CommittedWriteGuard.guard_test!(context)
      end
    end
  end

  @doc "The calls through which a test commits outside the sandbox that the guard can see."
  @spec entry_points() :: [mfa()]
  def entry_points, do: @entry_points

  @doc """
  Starts the guard for this `mix test` invocation. Call it once from `test/test_helper.exs`, after
  the migrations and the harness's own committed rows, before any test runs.
  """
  @spec start!(keyword()) :: :ok
  def start!(opts \\ []) do
    repo_config = Keyword.get_lazy(opts, :repo_config, &CodexPooler.Repo.config/0)

    # Owned by the calling process, which lives for the whole run: if the guard process dies, a
    # guarded test still finds the table and fails on the dead server instead of going unguarded.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    {:ok, _pid} = GenServer.start_link(__MODULE__, repo_config, name: @server)
    ExUnit.after_suite(&finish/1)
    :ok
  end

  @doc """
  Guards the calling test from the first line of its setup. For plain `ExUnit.Case` modules
  through `use CodexPooler.CommittedWriteGuard`.
  """
  @spec guard_test!(map()) :: :ok
  def guard_test!(tags) do
    tags |> begin_test!() |> register_verify!()
  end

  @doc """
  Opens the calling test's window. Call it before the harness's own sandbox calls, then
  `register_verify!/1` once they are done and before any other `on_exit` is registered.

  Returns `nil`, guarding nothing, for a test in an `async: true` module.

  Raises when the counters moved since the last verification and the committed rows changed with
  them: those rows were committed outside every guarded test, and this test is where it shows.
  """
  @spec begin_test!(map()) :: window()
  def begin_test!(tags) do
    if running?() and tags[:async] != true do
      session = :ets.lookup_element(@table, :session, 2)
      start = read_counts(session)
      # Only a message needs the label, so it is formatted on the paths that report something.
      where = Map.take(tags, [:module, :test, :file, :line])

      if :ets.lookup_element(@table, :verified, 2) != start do
        verify_or_raise!({:verify, :outside, label(where), start})
      end

      %{where: where, start: start, session: session}
    end
  end

  @doc """
  Registers the verification that runs after every other `on_exit` callback of the test. Calls
  made between `begin_test!/1` and this one belong to the harness, not to the test.
  """
  @spec register_verify!(window()) :: :ok
  def register_verify!(nil), do: :ok

  def register_verify!(%{where: where, start: start, session: session}) do
    harness = read_counts(session)
    ExUnit.Callbacks.on_exit(@verify_callback, fn -> verify!(where, start, harness, session) end)
  end

  @doc false
  def verify!(where, start, harness, session) do
    now = read_counts(session)
    # A connected node commits without a local call the guard counts, so count whenever one is.
    nodes = Node.list(:connected)

    if now == harness and nodes == [] do
      # Nothing the test ran could commit. Advance the verified counters over the harness's own
      # calls, unless another verification moved them meanwhile.
      _replaced =
        :ets.select_replace(@table, [{{:verified, start}, [], [{:const, {:verified, now}}]}])

      :ok
    else
      verify_or_raise!({:verify, :test, label(where), now, calls(harness, now), nodes})
    end
  end

  @doc false
  def finish(_suite_stats) do
    if running?() do
      now = read_counts(:ets.lookup_element(@table, :session, 2))
      @server |> GenServer.call({:finish, now}, @verify_timeout_ms) |> report_after_suite()
    end

    :ok
  end

  defp report_after_suite(:ok), do: :ok

  # Nothing is left to fail after the last test, so the leak fails the run through its exit status.
  defp report_after_suite({:leak, message}) do
    IO.puts(:stderr, message)
    System.at_exit(fn _status -> exit({:shutdown, 1}) end)
  end

  defp running?, do: :ets.whereis(@table) != :undefined

  defp verify_or_raise!(request) do
    case GenServer.call(@server, request, @verify_timeout_ms) do
      :ok -> :ok
      {:leak, message} -> raise ExUnit.AssertionError, message: message
    end
  end

  @impl GenServer
  def init(repo_config) do
    # Connected before counting starts, so the guard's own connection never counts.
    conn = connect!(repo_config)
    query = conn |> watched_tables!() |> count_query()
    snapshot = count_rows!(conn, query)
    session = start_session!()
    true = :ets.insert(@table, [{:session, session}, {:verified, read_counts(session)}])

    {:ok,
     %{
       repo_config: repo_config,
       conn: conn,
       query: query,
       snapshot: snapshot,
       session: session,
       checks: 0,
       check_native: 0
     }}
  end

  @impl GenServer
  def handle_call({:verify, :outside, label, now}, _from, state) do
    verified = :ets.lookup_element(@table, :verified, 2)
    {reply, state} = verify_rows(state, now, &outside_message(label, &1, calls(verified, now)))
    {:reply, reply, state}
  end

  def handle_call({:verify, :test, label, now, calls, nodes}, _from, state) do
    {reply, state} = verify_rows(state, now, &test_message(label, &1, calls, nodes))
    {:reply, reply, state}
  end

  # Always counts: a commit no entry point reveals in the last tests has no later test to show in.
  def handle_call({:finish, now}, _from, state) do
    verified = :ets.lookup_element(@table, :verified, 2)
    {reply, state} = verify_rows(state, now, &after_suite_message(&1, calls(verified, now)))

    TestDiagnostics.puts(fn ->
      "committed write guard: #{state.checks} row counts, " <>
        "#{System.convert_time_unit(state.check_native, :native, :microsecond)} us in total"
    end)

    {:reply, reply, disconnect(state)}
  end

  @impl GenServer
  def terminate(_reason, %{session: session}) do
    :trace.session_destroy(session)
  end

  defp verify_rows(state, now, message) do
    state = ensure_connected(state)
    started = System.monotonic_time()
    counted = count_rows(state.conn, state.query)
    state = %{state | checks: state.checks + 1}
    state = %{state | check_native: state.check_native + System.monotonic_time() - started}
    true = :ets.insert(@table, {:verified, now})

    case counted do
      {:ok, current} ->
        case changes(state.snapshot, current) do
          [] -> {:ok, %{state | snapshot: current}}
          changes -> {{:leak, message.(changes)}, %{state | snapshot: current}}
        end

      {:error, error} ->
        {{:leak, message.({:count_failed, error})}, state}
    end
  end

  # The run's last verification disconnects so that `mix codex_pooler.test` can drop a run-scoped
  # database; `mix test --repeat-until-failure` runs the suite again in the same VM.
  defp ensure_connected(%{conn: nil, repo_config: repo_config} = state),
    do: %{state | conn: connect!(repo_config)}

  defp ensure_connected(state), do: state

  defp disconnect(%{conn: nil} = state), do: state

  defp disconnect(%{conn: conn} = state) do
    GenServer.stop(conn)
    %{state | conn: nil}
  end

  defp connect!(repo_config) do
    {:ok, conn} =
      repo_config
      |> Keyword.take(@connection_keys)
      |> Keyword.merge(
        pool_size: 1,
        parameters: [
          application_name: "codex_pooler_test_committed_write_guard",
          lock_timeout: @lock_timeout,
          statement_timeout: @statement_timeout
        ]
      )
      |> Postgrex.start_link()

    Postgrex.query!(conn, "SELECT 1", [])
    conn
  end

  # `[{table, nil}]` for a table compared by row count, `[{table, ignored_columns}]` for a table with
  # a `singleton` column, whose row is also compared by content.
  defp watched_tables!(conn) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT t.table_name::text,
               bool_or(c.column_name = 'singleton'),
               coalesce(
                 array_agg(c.column_name::text ORDER BY c.column_name)
                   FILTER (WHERE c.data_type LIKE 'timestamp%' OR c.column_name = ANY ($1)),
                 ARRAY[]::text[]
               )
        FROM information_schema.tables t
        JOIN information_schema.columns c
          ON c.table_schema = t.table_schema AND c.table_name = t.table_name
        WHERE t.table_schema = ANY (current_schemas(false)) AND t.table_type = 'BASE TABLE'
        GROUP BY t.table_name
        ORDER BY t.table_name
        """,
        [@bookkeeping_columns]
      )

    case Enum.reject(rows, fn [table | _rest] -> table in @harness_tables end) do
      [] ->
        raise "committed write guard: the test database has no tables; start it after migrating"

      tables ->
        Enum.map(tables, fn [table, singleton?, ignored] ->
          Enum.each([table | ignored], &ensure_plain_identifier!/1)
          {table, if(singleton?, do: ignored)}
        end)
    end
  end

  # Catalog names are interpolated into the count query, so only plain identifiers are accepted.
  defp ensure_plain_identifier!(name) do
    unless Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      raise "committed write guard: cannot count #{inspect(name)}"
    end
  end

  # `~s|...|` because the SQL carries both `[]` and `()`.
  defp count_query(tables) do
    Enum.map_join(tables, " UNION ALL ", fn
      {table, nil} ->
        ~s|SELECT '#{table}', count(*), NULL::text FROM "#{table}"|

      {table, ignored} ->
        content =
          ~s|(to_jsonb(r) - ARRAY[#{Enum.map_join(ignored, ", ", &"'#{&1}'")}]::text[])::text|

        ~s|SELECT '#{table}', count(*), | <>
          ~s|md5(coalesce(string_agg(#{content}, ',' ORDER BY #{content}), '')) | <>
          ~s|FROM "#{table}" AS r|
    end)
  end

  defp count_rows!(conn, query) do
    case count_rows(conn, query) do
      {:ok, counts} -> counts
      {:error, error} -> raise error
    end
  end

  defp count_rows(conn, query) do
    case Postgrex.query(conn, query, [], timeout: @verify_timeout_ms) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        {:ok, Map.new(rows, fn [table, n, content] -> {table, {n, content}} end)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp start_session! do
    session = :trace.session_create(:codex_pooler_committed_write_guard, self(), [])

    for {module, _function, _arity} = mfa <- @entry_points do
      Code.ensure_loaded!(module)

      unless :trace.function(session, mfa, true, [:call_count]) == 1 do
        raise "committed write guard: cannot count calls to #{format_mfa(mfa)}"
      end
    end

    session
  end

  defp read_counts(session) do
    @entry_points
    |> Enum.map(fn mfa ->
      case :trace.info(session, mfa, :call_count) do
        {:call_count, count} when is_integer(count) ->
          count

        other ->
          raise "committed write guard: call counting for #{format_mfa(mfa)} stopped " <>
                  "(#{inspect(other)}); something destroyed the guard's trace session"
      end
    end)
    |> List.to_tuple()
  end

  defp calls(from, to) do
    @entry_points
    |> Enum.with_index()
    |> Enum.flat_map(fn {mfa, index} ->
      case elem(to, index) - elem(from, index) do
        n when n > 0 -> [{mfa, n}]
        _none -> []
      end
    end)
  end

  defp changes(before, current) do
    before
    |> Map.keys()
    |> Enum.concat(Map.keys(current))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn table ->
      case {Map.get(before, table), Map.get(current, table)} do
        {same, same} -> []
        {{n, _was}, {n, _now}} -> [{table, :content, n}]
        {was, now} -> [{table, row_count(was), row_count(now)}]
      end
    end)
  end

  defp row_count({n, _content}), do: n
  defp row_count(nil), do: nil

  defp test_message(label, changes, calls, nodes) do
    """
    committed rows changed during #{label}, and nothing removed them:
    #{format_changes(changes)}
    Rows committed outside the sandbox outlive the test and fail later tests in unrelated files. \
    Register their removal before committing them, with \
    CodexPooler.UnboxedFixture.register_unboxed_cleanup!/1, or commit an owner through \
    CodexPooler.AccountsFixtures.committed_bootstrap_owner_fixture!/1.
    Calls that can commit outside the sandbox made during this test: #{format_calls(calls)}
    #{format_channels(calls, nodes)}\
    """
  end

  defp outside_message(label, changes, calls) do
    """
    committed rows changed before #{label} started, outside every guarded test, and nothing \
    removed them:
    #{format_changes(changes)}
    This test did not commit them. They come from a test module that commits outside the sandbox \
    without the guard (put `use CodexPooler.CommittedWriteGuard` below `use ExUnit.Case`), from a \
    setup_all, from a process that outlived its test, or from an earlier guarded test that \
    committed through a channel the guard cannot see (see the CodexPooler.CommittedWriteGuard \
    moduledoc).
    Calls that can commit outside the sandbox made since the last verification: \
    #{format_calls(calls)}
    """
  end

  defp after_suite_message(changes, calls) do
    """
    committed write guard: committed rows changed after the guard last verified them, and \
    nothing removed them:
    #{format_changes(changes)}
    They come from a test module that commits outside the sandbox without the guard, from a \
    process that outlived its test, or from a guarded test that committed through a channel the \
    guard cannot see (see the CodexPooler.CommittedWriteGuard moduledoc).
    Calls that can commit outside the sandbox made since the last verification: \
    #{format_calls(calls)}
    """
  end

  defp format_channels([], []) do
    "No call the guard counts moved and no node was connected, so these rows may not be this " <>
      "test's own: they can come from an earlier test that committed through a channel the " <>
      "guard cannot see (see the CodexPooler.CommittedWriteGuard moduledoc).\n"
  end

  defp format_channels(_calls, []), do: ""

  defp format_channels(_calls, nodes),
    do: "Connected nodes, which commit without a call the guard counts: #{inspect(nodes)}\n"

  defp format_changes({:count_failed, error}),
    do: "  the guard could not count the rows: #{Exception.message(error)}"

  defp format_changes(changes) do
    Enum.map_join(changes, "\n", fn
      {table, :content, n} ->
        "  #{table}: content changed (#{n} rows; timestamps and lock_version are not compared)"

      {table, was, now} ->
        "  #{table}: #{was || "absent"} -> #{now || "absent"}#{format_delta(was, now)}"
    end)
  end

  defp format_delta(was, now) when is_integer(was) and is_integer(now) and now > was,
    do: " (+#{now - was})"

  defp format_delta(was, now) when is_integer(was) and is_integer(now), do: " (#{now - was})"
  defp format_delta(_was, _now), do: ""

  defp format_calls([]), do: "none"

  defp format_calls(calls) do
    Enum.map_join(calls, ", ", fn {mfa, n} -> "#{format_mfa(mfa)} x#{n}" end)
  end

  defp format_mfa({module, function, arity}),
    do: "#{inspect(module)}.#{function}/#{arity}"

  defp label(tags) do
    test = tags |> Map.get(:test) |> to_string()
    location = "#{Path.relative_to_cwd(to_string(Map.get(tags, :file)))}:#{Map.get(tags, :line)}"
    "#{inspect(Map.get(tags, :module))} #{inspect(test)} (#{location})"
  end
end
