defmodule CodexPooler.MixTasks.TestDatabaseDropOnExitTest do
  @moduledoc """
  Acceptance for `mix codex_pooler.test` dropping a run-scoped database when the run ends.

  Each case runs a real namespaced `mix test` in a VM of its own against a one-test file written
  for it, so the database that run creates, migrates and must drop again is the one asserted on.
  The run reports the database it is connected to, which keeps "the database is absent" from
  passing for a name the run never used.
  """
  use CodexPooler.UnixIntegrationCase, async: false, tools: ~w(mix)

  alias CodexPooler.MixTasks.{TestDatabaseLock, TestDatabasePrune}
  alias CodexPooler.Repo

  @moduletag :test_infrastructure

  # Every child run boots a VM and creates, migrates and drops its own database, several seconds
  # each; that floor is the property under test, not a wait. The module timeout is the
  # failure-detection budget for those runs on a loaded host.
  @moduletag timeout: 300_000

  # Failure-detection budget for the drain a leaked owner holds when the run stops the application.
  # The test configuration's shutdown budget aborts the owner's turn within milliseconds; the
  # release default would hold it for about 39 s before the owner is even asked to drain.
  @drain_budget_ms 5_000

  @receipt_prefix "drop-on-exit-probe "

  @passing_test ~S"""
  defmodule CodexPooler.DropOnExitProbe.PassingTest do
    use CodexPooler.DataCase, async: false

    test "reports the database it runs against" do
      %{rows: [[database]]} = Repo.query!("SELECT current_database()")
      IO.puts("drop-on-exit-probe database=#{database}")
    end
  end
  """

  @failing_test ~S"""
  defmodule CodexPooler.DropOnExitProbe.FailingTest do
    use CodexPooler.DataCase, async: false

    test "reports the database it runs against and fails" do
      %{rows: [[database]]} = Repo.query!("SELECT current_database()")
      IO.puts("drop-on-exit-probe database=#{database}")
      flunk("drop-on-exit probe: this failure is the scenario")
    end
  end
  """

  # A process registered where the rollout drain looks for websocket owners, answering the three
  # calls the drain makes with a turn that never ends, and left running when its test finishes.
  @leaked_owner_test ~S"""
  defmodule CodexPooler.DropOnExitProbe.LeakedOwner do
    use GenServer

    @registry CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Registry

    @impl GenServer
    def init(:ok) do
      {:ok, _owner} = Registry.register(@registry, {__MODULE__, self()}, nil)
      {:ok, nil}
    end

    @impl GenServer
    def handle_cast(:begin_drain, state) do
      IO.puts("drop-on-exit-probe drain_begin_ms=#{System.monotonic_time(:millisecond)}")
      {:noreply, state}
    end

    @impl GenServer
    def handle_call(:owner_status, _from, state), do: {:reply, {:ok, %{active_turn?: true}}, state}

    def handle_call(:drain, _from, state) do
      IO.puts("drop-on-exit-probe drain_end_ms=#{System.monotonic_time(:millisecond)}")
      {:reply, :ok, state}
    end
  end

  defmodule CodexPooler.DropOnExitProbe.LeakedOwnerTest do
    use CodexPooler.DataCase, async: false

    test "leaves a websocket owner with an active turn running" do
      %{rows: [[database]]} = Repo.query!("SELECT current_database()")
      {:ok, owner} = GenServer.start(CodexPooler.DropOnExitProbe.LeakedOwner, :ok)
      assert Process.alive?(owner)
      IO.puts("drop-on-exit-probe database=#{database}")
    end
  end
  """

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "codex_pooler_drop_on_exit_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "a passing and a failing namespaced run each drop their database and report their outcome",
       %{directory: directory} do
    passing = run_namespaced!(directory, "passing", @passing_test)
    failing = run_namespaced!(directory, "failing", @failing_test)

    assert passing.exit_code == 0, passing.output
    assert failing.exit_code != 0, failing.output

    for run <- [passing, failing] do
      assert run.receipts["database"] == run.database,
             "the run did not report its run-scoped database #{run.database}\n#{run.output}"

      refute database_exists?(run.database),
             "run-scoped database #{run.database} survived its run\n#{run.output}"
    end
  end

  test "a run that leaks a websocket owner drops its database without waiting out the drain",
       %{directory: directory} do
    run = run_namespaced!(directory, "leaked_owner", @leaked_owner_test)

    assert run.exit_code == 0, run.output
    assert run.receipts["database"] == run.database, run.output

    assert Map.has_key?(run.receipts, "drain_begin_ms") and
             Map.has_key?(run.receipts, "drain_end_ms"),
           "the rollout drain never reached the leaked owner\n#{run.output}"

    drain_ms =
      String.to_integer(run.receipts["drain_end_ms"]) -
        String.to_integer(run.receipts["drain_begin_ms"])

    assert drain_ms < @drain_budget_ms,
           "stopping the application held the leaked owner for #{drain_ms} ms " <>
             "(budget #{@drain_budget_ms} ms)\n#{run.output}"

    refute database_exists?(run.database),
           "run-scoped database #{run.database} survived its run\n#{run.output}"
  end

  defp run_namespaced!(directory, name, source) do
    path = Path.join(directory, "#{name}_test.exs")
    File.write!(path, source)
    namespace = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    database = configured_database(namespace, "1")

    # Registered before the run, so a run that fails or is killed before its own drop still has
    # its database removed.
    on_exit(fn -> drop_database!(database) end)

    {output, exit_code} =
      System.cmd("mix", ["test", "--no-compile", path],
        env: [
          {"MIX_ENV", "test"},
          {"CODEX_POOLER_TEST_RUN_NAMESPACE", namespace},
          {"MIX_TEST_PARTITION", "1"},
          {"DATABASE_URL", nil},
          {"CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", nil}
        ],
        stderr_to_stdout: true
      )

    %{output: output, exit_code: exit_code, database: database, receipts: receipts(output)}
  end

  defp receipts(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, @receipt_prefix, parts: 2) do
        [_before, pairs] -> String.split(pairs, " ", trim: true)
        [_line] -> []
      end
    end)
    |> Map.new(fn pair ->
      [key, value] = String.split(pair, "=", parts: 2)
      {key, value}
    end)
  end

  defp database_exists?(database) do
    conn = TestDatabaseLock.start_maintenance_connection!(Repo.config())

    try do
      %{rows: [[exists?]]} =
        Postgrex.query!(conn, "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", [
          database
        ])

      exists?
    after
      TestDatabaseLock.stop_maintenance_connection(conn)
    end
  end

  defp drop_database!(database) do
    if TestDatabasePrune.run_scoped?(database) do
      conn = TestDatabaseLock.start_maintenance_connection!(Repo.config())

      try do
        Postgrex.query!(conn, ~s[DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)], [])
      after
        TestDatabaseLock.stop_maintenance_connection(conn)
      end
    end

    :ok
  end

  defp configured_database(namespace, partition) do
    previous =
      Map.new(
        ["CODEX_POOLER_TEST_RUN_NAMESPACE", "MIX_TEST_PARTITION"],
        &{&1, System.get_env(&1)}
      )

    restore = fn -> Enum.each(previous, fn {key, value} -> put_env(key, value) end) end

    # Also on_exit: the ExUnit timeout kills the test before `after` runs.
    on_exit(restore)

    put_env("CODEX_POOLER_TEST_RUN_NAMESPACE", namespace)
    put_env("MIX_TEST_PARTITION", partition)

    try do
      Config.Reader.read!("config/test.exs", env: :test)[:codex_pooler][Repo][:database]
    after
      restore.()
    end
  end

  defp put_env(key, nil), do: System.delete_env(key)
  defp put_env(key, value), do: System.put_env(key, value)
end
