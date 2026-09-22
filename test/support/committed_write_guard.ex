defmodule CodexPooler.CommittedWriteGuard do
  @moduledoc """
  Fails a test that leaves committed rows behind, and names the tables.

  A row written inside the Ecto sandbox rolls back with its test. A row committed outside it,
  through `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, `Sandbox.mode(Repo, :auto)`, a connection of
  its own, a `:peer` node or a child `mix` VM, survives into every later test of the same
  `mix test` invocation and surfaces there as a failure in a file that has nothing to do with it.
  Every table of the schema is watched, so rows no user path reaches, such as an identity created
  without a creator or a pricing snapshot, count as much as an owner's graph. Every watched
  table is also compared by normalized content, so updates that nothing puts back fail even
  when row counts stay constant. Every column is compared, `lock_version` and the timestamps that
  carry meaning (`platform_bootstrap_state.completed_at`, `openai_status_feed_states.last_*_at`)
  included; only `updated_at` is excluded, as bookkeeping a restore through the domain API
  rewrites without changing what the row says. Comparing the timestamps costs nothing: 8.9 ms
  against 9.5 ms p50 for the same query without them (n=200 each, `SAMPLES=200 mix run
  --no-start` over this database's 67 base tables).

  ## Cost on the sandboxed path

  Every guarded test ends with a row count of every watched table over the guard's own connection,
  a cached statement that costs 0.46 ms at p50 and 0.70 ms at p90, against a 0.46 ms `SELECT 1`
  round trip (n=200 per variant, `SAMPLES=200 mix run --no-start` over this database's 67 base
  tables). A row committed through a channel the guard cannot see is therefore charged to the test
  that committed it as soon as it changes a count, rather than to a later test. Over the 88 files
  of this suite that commit outside the sandbox, 2,204 tests, the guard reported 2,211 checks,
  451 of them content, in 4.97 s of query time (`CODEX_POOLER_TEST_DIAGNOSTICS=1`): the 1,760
  counts the content gate would have skipped cost under a second in all.

  The content fingerprint costs 7.3 ms at p50 on the same sample, sixteen times the count, so it
  is not paid per test. It runs when a count moved, and when the test could have committed through
  a channel whose writes need not move one: a trace session counts calls to `entry_points/0` with
  `call_count`, which the VM keeps synchronously and without sending messages, and the guard reads
  those counters when the test's setup starts and again after its last `on_exit` callback; a
  connected node counts as well, because it commits without a local call. Tests in `async: true`
  modules are not guarded: they run before every sync module, where concurrent sandbox owners
  would move each other's counters, and they must not commit anyway.

  ## What it cannot see

  The entry points are the calls through which this suite commits outside the sandbox: the sandbox
  modes, a new connection (`DBConnection.start_link/2`, which `Postgrex.start_link/1` and every
  Repo start go through, and `Postgrex.SimpleConnection`), a node (`:peer`, `:erpc`, `:rpc`) and a
  child OS process (`System.cmd/3`). Two things stay unattributable.

  An **in-place update** through a channel none of those calls reveals, such as a query on a
  connection opened before the test or a port opened directly, moves no row count either, so the
  content is never read for that test. It is reported by the next content check, whose message
  says the rows may not be that test's own, and after the suite, where the content is always
  compared once more.

  A commit that lands **after a test's own verification**, from a process that outlived it, is
  reported the same way: by the next check that reads the state, or after the suite.

  ## Coverage

  `CodexPooler.DataCase.setup_sandbox/1`, and through it `CodexPoolerWeb.ConnCase`, guards every
  sync test. A module on plain `ExUnit.Case` that commits outside the sandbox puts
  `use CodexPooler.CommittedWriteGuard` directly below `use ExUnit.Case`: the guard registers its
  `on_exit` before any other callback so that it runs after all of them, cleanups included.

  A sync module also gets a window, from a `setup_all` the case template or `__using__/1` injects
  before the module's own. Rows the module commits in `setup_all` belong to it: its first test
  accepts them instead of failing, every test of that module is compared by content, because what
  a `setup_all` opened can commit without a call the guard counts, and the committed state is
  compared with the state from before the module once every module-level callback has run. A
  difference there fails the module, naming the tables no test of it was already blamed for, and
  ExUnit invalidates the module's tests. The next module's first test is never charged for it.

  Counters that move outside every guarded test and outside a module window (an unguarded module,
  a process that outlived its test) are verified when the next guarded test starts. That test fails
  in setup with the tables and a message saying the rows are not its own. After the last test the
  rows are compared once more whatever the counters say, and a change there fails the run.
  """

  use GenServer

  alias CodexPooler.TestDiagnostics

  @server __MODULE__
  @table __MODULE__
  @verify_callback {__MODULE__, :verify}
  @module_callback {__MODULE__, :module}

  # Names Postgrex caches the two verification statements under, on the guard's own connection.
  @counts_statement "committed_write_guard_counts"
  @content_statement "committed_write_guard_content"

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

  # Columns a restore through the domain API rewrites without changing what the row says. Only
  # `updated_at` qualifies: every other timestamp column names an event, so a test that moves one
  # and leaves it has changed the committed state. A restore through the domain API also bumps
  # `lock_version`, which is compared, so excluding `updated_at` spares only a raw restore that
  # puts the content back without the bookkeeping.
  @bookkeeping_columns ["updated_at"]

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

  # Failure-detection budget for one verification query, not a behaviour timer. The guard's connection also
  # bounds its own lock wait, so a leaked `ACCESS EXCLUSIVE` lock fails the test with the Postgres
  # error instead of stalling it.
  @verify_timeout_ms 30_000
  @lock_timeout "5s"
  @statement_timeout "20s"

  @type counts :: tuple()
  @type window :: %{where: map(), start: counts(), session: term()} | nil

  defmacro __using__(_opts) do
    quote do
      setup_all context do
        CodexPooler.CommittedWriteGuard.guard_module!(context)
      end

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
  Opens the calling module's window, from a `setup_all` that runs before the module's own.

  Rows the module commits in its `setup_all` belong to the module: the first test accepts them
  instead of failing, every test of that module is compared by content because what `setup_all`
  opened can commit without a call the guard counts, and the committed state is compared with the
  state from before the module once every module-level callback has run. A difference there fails
  the module, never the next module's first test.

  `CodexPooler.DataCase` and `CodexPoolerWeb.ConnCase` call this for every sync module they cover;
  a plain `ExUnit.Case` module gets it from `use CodexPooler.CommittedWriteGuard`. It does nothing
  for an `async: true` module, which is not guarded.
  """
  @spec guard_module!(map()) :: :ok
  def guard_module!(tags) do
    if running?() and tags[:async] != true do
      module = Map.fetch!(tags, :module)
      start = @table |> :ets.lookup_element(:session, 2) |> read_counts()
      :ok = GenServer.call(@server, {:begin_module, module, start}, @verify_timeout_ms)

      # Registered before any callback the module's own `setup_all` registers, and callbacks run in
      # reverse registration order, so this one runs after the module has removed its fixture.
      ExUnit.Callbacks.on_exit(@module_callback, fn -> end_module!(module) end)
    end

    :ok
  end

  @doc false
  def end_module!(module) do
    if running?() do
      now = @table |> :ets.lookup_element(:session, 2) |> read_counts()

      case GenServer.call(@server, {:end_module, module, now}, @verify_timeout_ms) do
        :ok ->
          :ok

        {:leak, message} ->
          # ExUnit keeps only the first error a module's `on_exit` callbacks raise, and this one
          # runs last, so the diagnostic is printed as well as raised.
          IO.puts(:stderr, message)
          raise ExUnit.AssertionError, message: message
      end
    end

    :ok
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

      verified = :ets.lookup_element(@table, :verified, 2)

      if verified != start do
        verify_or_raise!({:verify, moved_where(tags[:module], verified), where, start})
      end

      %{where: where, start: start, session: session}
    end
  end

  # Counters that moved between this module's window opening and its first test moved inside a
  # `setup_all`: what it committed belongs to the module, which owns it until it ends. The window
  # has to have opened on verified counters for that to hold; a module that opens its window after
  # an unguarded module already moved them inherits nothing, and its first test reports the rows
  # as committed outside every guarded test, as before.
  defp moved_where(module, verified) do
    case :ets.lookup(@table, :module) do
      [{:module, %{name: ^module, verified: ^verified, start: ^verified}}] -> :setup_all
      _other -> :outside
    end
  end

  @doc """
  Registers the verification that runs after every other `on_exit` callback of the test. Calls
  made between `begin_test!/1` and this one belong to the harness, not to the test.
  """
  @spec register_verify!(window()) :: :ok
  def register_verify!(nil), do: :ok

  def register_verify!(%{where: where, session: session}) do
    harness = read_counts(session)
    ExUnit.Callbacks.on_exit(@verify_callback, fn -> verify!(where, harness, session) end)
  end

  @doc false
  def verify!(where, harness, session) do
    now = read_counts(session)
    # A connected node commits without a local call the guard counts, so compare the content
    # whenever one is.
    nodes = Node.list(:connected)

    verify_or_raise!({:verify, :test, where, now, calls(harness, now), nodes})
  rescue
    error in ExUnit.AssertionError ->
      # ExUnit retains the primary failure when teardown also fails. Keep the
      # metadata-only leak diagnostic visible even when the test already failed.
      IO.puts(:stderr, error.message)
      reraise error, __STACKTRACE__
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
    tables = watched_tables!(conn)
    sql = %{counts: counts_sql(tables), content: content_sql(tables)}
    prepared = prepare!(conn, sql)
    snapshot = query_content!(conn, prepared.content)
    session = start_session!()
    true = :ets.insert(@table, [{:session, session}, {:verified, read_counts(session)}])

    {:ok,
     %{
       repo_config: repo_config,
       conn: conn,
       sql: sql,
       prepared: prepared,
       snapshot: snapshot,
       session: session,
       module: nil,
       checks: 0,
       content_checks: 0,
       check_native: 0
     }}
  end

  @impl GenServer
  def handle_call({:begin_module, module, start}, _from, state) do
    verified = :ets.lookup_element(@table, :verified, 2)
    true = :ets.insert(@table, {:module, %{name: module, verified: verified, start: start}})
    {:reply, :ok, %{state | module: open_window(state, module)}}
  end

  def handle_call({:end_module, module, now}, _from, state) do
    {reply, state} = end_module(state, module, now)
    {:reply, reply, state}
  end

  def handle_call({:verify, :outside, where, now}, _from, state) do
    verified = :ets.lookup_element(@table, :verified, 2)

    {reply, changes, state} =
      verify_rows(state, now, true, &outside_message(label(where), &1, calls(verified, now)))

    # Charged to this test, so the module it belongs to is not asked for it again when it ends.
    {:reply, reply, remember_reported(state, where[:module], changes)}
  end

  # The module's own `setup_all` committed these rows. They are read and accepted here, and
  # compared again when the module ends; a `setup_all` that opened a channel the guard cannot see,
  # such as `Sandbox.mode(Repo, :auto)`, also makes every test of the module content-compared.
  def handle_call({:verify, :setup_all, _where, now}, _from, state) do
    {state, read} = state |> ensure_connected() |> read_row_content()
    true = :ets.insert(@table, {:verified, now})

    case read do
      {:ok, current} ->
        state = %{state | snapshot: current, content_checks: state.content_checks + 1}
        {:reply, :ok, %{state | module: %{state.module | fixture?: true}}}

      {:error, error} ->
        {:reply, {:leak, query_failed_message(error)}, state}
    end
  end

  def handle_call({:verify, :test, where, now, calls, nodes}, _from, state) do
    # A call the guard counts, or a connected node, means the test could have committed through a
    # channel whose writes need not move a row count, so the content is compared for it. So does a
    # `setup_all` of this module that committed: what it opened outlives its own window.
    content? = calls != [] or nodes != [] or escalated?(state, where[:module])

    {reply, changes, state} =
      verify_rows(state, now, content?, &test_message(label(where), &1, calls, nodes))

    {:reply, reply, remember_reported(state, where[:module], changes)}
  end

  # Always compares the content: a commit no entry point reveals in the last tests has no later
  # test to show in.
  def handle_call({:finish, now}, _from, state) do
    verified = :ets.lookup_element(@table, :verified, 2)

    {reply, _changes, state} =
      verify_rows(state, now, true, &after_suite_message(&1, calls(verified, now)))

    TestDiagnostics.puts(fn ->
      "committed write guard: #{state.checks} checks, #{state.content_checks} of them content, " <>
        "#{System.convert_time_unit(state.check_native, :native, :microsecond)} us in total"
    end)

    {:reply, reply, disconnect(state)}
  end

  @impl GenServer
  def terminate(_reason, %{session: session}) do
    :trace.session_destroy(session)
  end

  # The row counts run for every guarded test, so a row committed through a channel the guard
  # cannot see is charged to the test that committed it. The content fingerprint, an order of
  # magnitude dearer, runs only when a count moved or when the caller already knows the test could
  # have committed unseen.
  defp verify_rows(state, now, content?, message) do
    state = ensure_connected(state)
    true = :ets.insert(@table, {:verified, now})

    if content?, do: verify_content(state, message), else: verify_counts(state, message)
  end

  defp verify_counts(state, message) do
    case read_row_counts(state) do
      {state, {:ok, counts}} ->
        if counts == row_counts(state.snapshot),
          do: {:ok, [], state},
          else: verify_content(state, message)

      {state, {:error, error}} ->
        {{:leak, message.({:count_failed, error})}, [], state}
    end
  end

  defp verify_content(state, message) do
    case read_row_content(state) do
      {state, {:ok, current}} ->
        before = state.snapshot
        state = %{state | content_checks: state.content_checks + 1, snapshot: current}

        case changes(before, current) do
          [] -> {:ok, [], state}
          changes -> {{:leak, message.(changes)}, changes, state}
        end

      {state, {:error, error}} ->
        {{:leak, message.({:count_failed, error})}, [], state}
    end
  end

  defp read_row_counts(state) do
    started = System.monotonic_time()
    result = query_counts(state.conn, state.prepared.counts)
    {charge(state, started), result}
  end

  defp read_row_content(state) do
    started = System.monotonic_time()
    result = query_content(state.conn, state.prepared.content)
    {charge(state, started), result}
  end

  defp charge(state, started) do
    elapsed = System.monotonic_time() - started
    %{state | checks: state.checks + 1, check_native: state.check_native + elapsed}
  end

  defp row_counts(snapshot), do: Map.new(snapshot, fn {table, {n, _content}} -> {table, n} end)

  # Sync modules run one at a time, so one window is enough. Opening it twice, for a module that
  # both uses a case template and `use CodexPooler.CommittedWriteGuard`, keeps the first.
  defp open_window(%{module: %{name: module}} = state, module), do: state.module

  defp open_window(state, module) do
    %{name: module, baseline: state.snapshot, fixture?: false, reported: MapSet.new()}
  end

  defp escalated?(%{module: %{name: module, fixture?: true}}, module), do: true
  defp escalated?(_state, _module), do: false

  defp remember_reported(%{module: %{name: module} = window} = state, module, [_ | _] = changes) do
    tables = MapSet.new(changes, fn {table, _was, _now} -> table end)
    %{state | module: %{window | reported: MapSet.union(window.reported, tables)}}
  end

  defp remember_reported(state, _module, _changes), do: state

  # Runs from the module's last `on_exit`, so the module has already removed what its `setup_all`
  # committed. The comparison is against the committed state from before the module, minus the
  # tables one of its tests was already blamed for.
  defp end_module(%{module: %{name: module} = window} = state, module, now) do
    true = :ets.insert(@table, {:verified, now})
    true = :ets.delete(@table, :module)
    state = %{ensure_connected(state) | module: nil}

    if window.fixture?,
      do: compare_module(state, window),
      else: compare_module_counts(state, window)
  end

  defp end_module(state, _module, now) do
    true = :ets.insert(@table, {:verified, now})
    {:ok, state}
  end

  # Nothing the module committed in `setup_all`, so the content is only read when a count moved
  # since the state from before the module or since the last verification, which is what a
  # module-level callback that commits leaves behind.
  defp compare_module_counts(state, window) do
    case read_row_counts(state) do
      {state, {:ok, counts}} ->
        if module_counts_unchanged?(counts, window, state),
          do: {:ok, state},
          else: compare_module(state, window)

      {state, {:error, error}} ->
        {{:leak, query_failed_message(error)}, state}
    end
  end

  defp module_counts_unchanged?(counts, window, state) do
    counts == row_counts(window.baseline) and counts == row_counts(state.snapshot)
  end

  defp compare_module(state, window) do
    case read_row_content(state) do
      {state, {:ok, current}} ->
        state = %{state | content_checks: state.content_checks + 1, snapshot: current}

        case module_changes(window, current) do
          [] -> {:ok, state}
          changes -> {{:leak, module_message(window.name, changes)}, state}
        end

      {state, {:error, error}} ->
        {{:leak, query_failed_message(error)}, state}
    end
  end

  defp module_changes(window, current) do
    window.baseline
    |> changes(current)
    |> Enum.reject(fn {table, _was, _now} -> MapSet.member?(window.reported, table) end)
  end

  # The run's last verification disconnects so that `mix codex_pooler.test` can drop a run-scoped
  # database; `mix test --repeat-until-failure` runs the suite again in the same VM.
  defp ensure_connected(%{conn: nil, repo_config: repo_config} = state) do
    conn = connect!(repo_config)
    %{state | conn: conn, prepared: prepare!(conn, state.sql)}
  end

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

  # Every table is compared by normalized row content, excluding only `@bookkeeping_columns`.
  # `lock_version` and every timestamp that names an event remain included.
  # This catches updates to non-singleton rows as well as singleton state changes.
  defp watched_tables!(conn) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT t.table_name::text,
               bool_or(c.column_name = 'singleton'),
               coalesce(
                 array_agg(c.column_name::text ORDER BY c.column_name)
                   FILTER (WHERE c.column_name = ANY ($1)),
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
        Enum.map(tables, fn [table, _singleton?, ignored] ->
          Enum.each([table | ignored], &ensure_plain_identifier!/1)
          {table, ignored}
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
  defp content_sql(tables) do
    Enum.map_join(tables, " UNION ALL ", fn {table, ignored} ->
      content =
        ~s|(to_jsonb(r) - ARRAY[#{Enum.map_join(ignored, ", ", &"'#{&1}'")}]::text[])::text|

      ~s|SELECT '#{table}', count(*), | <>
        ~s|md5(coalesce(string_agg(#{content}, ',' ORDER BY #{content}), '')) | <>
        ~s|FROM "#{table}" AS r|
    end)
  end

  defp counts_sql(tables) do
    Enum.map_join(tables, " UNION ALL ", fn {table, _ignored} ->
      ~s|SELECT '#{table}', count(*) FROM "#{table}"|
    end)
  end

  # Both statements are prepared once per connection, so every check after the first skips the
  # parse and the plan; the run's last verification disconnects, and the next one prepares again.
  defp prepare!(conn, sql) do
    {:ok, counts} = Postgrex.prepare(conn, @counts_statement, sql.counts)
    {:ok, content} = Postgrex.prepare(conn, @content_statement, sql.content)
    %{counts: counts, content: content}
  end

  defp query_content!(conn, query) do
    case query_content(conn, query) do
      {:ok, rows} -> rows
      {:error, error} -> raise error
    end
  end

  defp query_counts(conn, query) do
    case run_query(conn, query) do
      {:ok, rows} -> {:ok, Map.new(rows, fn [table, n] -> {table, n} end)}
      {:error, error} -> {:error, error}
    end
  end

  defp query_content(conn, query) do
    case run_query(conn, query) do
      {:ok, rows} -> {:ok, Map.new(rows, fn [table, n, content] -> {table, {n, content}} end)}
      {:error, error} -> {:error, error}
    end
  end

  defp run_query(conn, query) do
    case Postgrex.execute(conn, query, [], timeout: @verify_timeout_ms) do
      {:ok, _query, %Postgrex.Result{rows: rows}} -> {:ok, rows}
      {:error, error} -> {:error, error}
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

  defp module_message(module, changes) do
    """
    committed rows changed while #{inspect(module)} ran, and nothing removed them:
    #{format_changes(changes)}
    Rows a module commits in its setup_all belong to that module, not to its first test and not to \
    the next module: remove them from a callback the setup_all registers, so the removal runs \
    before this check. Tables a test of this module was already blamed for are not repeated here.
    """
  end

  defp query_failed_message(error) do
    "committed write guard: could not read the committed rows: #{Exception.message(error)}"
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
        "  #{table}: content changed (#{n} rows)"

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
