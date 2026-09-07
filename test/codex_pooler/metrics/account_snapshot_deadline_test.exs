defmodule CodexPooler.Metrics.AccountSnapshotDeadlineTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Metrics.AccountSnapshot
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule DeadlineRepo do
    use Ecto.Repo, otp_app: :codex_pooler, adapter: Ecto.Adapters.Postgres
  end

  defmodule ObservedRepo do
    alias CodexPooler.Metrics.AccountSnapshotDeadlineTest.DeadlineRepo

    def transaction(fun, opts) do
      [{:config, parent, _delay}] = :ets.lookup(__MODULE__, :config)
      {:links, links} = Process.info(self(), :links)
      send(parent, {:collector, self(), links, Process.get(:collector_parent_private_state)})
      DeadlineRepo.transaction(fun, opts)
    end

    def query!(sql, params, opts) do
      [{:config, parent, delay}] = :ets.lookup(__MODULE__, :config)
      send(parent, {:collector_query, self(), sql})

      if delay > 0 and String.contains?(sql, "SELECT id::text") do
        [[backend]] = DeadlineRepo.query!("SELECT pg_backend_pid()", [], opts).rows
        send(parent, {:collector_backend, self(), backend})
        DeadlineRepo.query!("SELECT pg_sleep($1)", [delay], opts)
      end

      DeadlineRepo.query!(sql, params, opts)
    end
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.checkin(Repo) end)

    # A separate one-connection pool against the configured synthetic suite DB
    # exercises actual checkout contention, without changing the app's pool.
    config =
      Keyword.merge(Repo.config(),
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        queue_target: 10_000,
        queue_interval: 10_000,
        name: DeadlineRepo
      )

    start_supervised!({DeadlineRepo, config})
    :ets.new(ObservedRepo, [:named_table, :public])
    configure(0)
    :ok
  end

  @tag timeout: 15_000
  test "fully occupied pool times out near five seconds and its dead collector never queries later" do
    holder = hold_connection(:infinity)
    Process.put(:collector_parent_private_state, "synthetic-do-not-copy")
    started = System.monotonic_time(:millisecond)
    body = AccountSnapshot.scrape(fn -> AccountSnapshot.load(ObservedRepo) end)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_500 and elapsed < 5_800
    assert body =~ "codex_pooler_account_metrics_collection_success 0"
    refute body =~ "codex_pooler_account_metrics_accounts 0"
    assert_receive {:collector, worker, links, nil}
    assert_dead(worker, links)
    refute_received {:collector_query, ^worker, _}
    release(holder)
    assert_pool_usable()
    refute_receive {:collector_query, ^worker, _}, 100
  end

  @tag timeout: 15_000
  test "slow SQL and mixed checkout-plus-query share the same total deadline" do
    for {held_ms, query_seconds} <- [{0, 7}, {2_000, 4}] do
      configure(query_seconds)
      holder = if held_ms > 0, do: hold_connection(held_ms)
      started = System.monotonic_time(:millisecond)
      assert {:error, :snapshot_unavailable} = AccountSnapshot.load(ObservedRepo)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 4_500 and elapsed < 5_800
      assert_receive {:collector, worker, links, nil}
      assert_receive {:collector_backend, ^worker, backend}
      assert_dead(worker, links)
      if holder, do: Task.await(holder)
      assert_pool_usable()
      assert_backend_idle(backend)
    end
  end

  test "caller termination cancels queued and executing collectors without detached stream processes" do
    for mode <- [:queued, :query] do
      configure(if(mode == :query, do: 7, else: 0))
      holder = if mode == :queued, do: hold_connection(:infinity)
      {caller, caller_monitor} = spawn_monitor(fn -> AccountSnapshot.load(ObservedRepo) end)
      assert_receive {:collector, worker, links, nil}
      worker_monitor = Process.monitor(worker)
      stream_monitors = Enum.map(links, &{&1, Process.monitor(&1)})

      backend =
        if mode == :query do
          assert_receive {:collector_backend, ^worker, backend}
          assert_sleeping(backend, 100)
          backend
        end

      Process.exit(caller, :shutdown)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :shutdown}
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000

      for {pid, monitor} <- stream_monitors do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      end

      if holder, do: release(holder)
      assert_pool_usable()
      if backend, do: assert_backend_idle(backend)
      drain_queries(worker)
      refute_receive {:collector_query, ^worker, _}, 100
    end
  end

  test "successful collection finishes the owned worker and stream before returning" do
    assert {:ok, snapshot} = AccountSnapshot.load(ObservedRepo)
    assert %DateTime{} = snapshot.as_of
    assert_receive {:collector, worker, links, nil}
    assert_dead(worker, links)
    assert_pool_usable()
  end

  defp configure(delay), do: :ets.insert(ObservedRepo, {:config, self(), delay})

  defp hold_connection(milliseconds) do
    parent = self()

    holder =
      Task.async(fn ->
        DeadlineRepo.transaction(
          fn ->
            send(parent, :connection_held)

            receive do
              :release -> :ok
            after
              milliseconds -> :ok
            end
          end,
          timeout: 12_000
        )
      end)

    assert_receive :connection_held
    holder
  end

  defp release(holder) do
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)
  end

  defp assert_dead(worker, links) do
    for pid <- [worker | links] do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
    end
  end

  defp assert_pool_usable do
    assert DeadlineRepo.query!("SELECT 1, current_setting('transaction_read_only')", [],
             timeout: 1_000
           ).rows == [[1, "off"]]
  end

  defp assert_backend_idle(backend) do
    assert DeadlineRepo.query!(
             "SELECT count(*) FROM pg_stat_activity WHERE pid = $1 AND state = 'active'",
             [backend]
           ).rows == [[0]]
  end

  defp assert_sleeping(_backend, 0), do: flunk("collector query never became active")

  defp assert_sleeping(backend, attempts) do
    result = Repo.query!("SELECT state, query FROM pg_stat_activity WHERE pid = $1", [backend])

    if result.rows != [["active", "SELECT pg_sleep($1)"]] do
      Process.sleep(10)
      assert_sleeping(backend, attempts - 1)
    end
  end

  defp drain_queries(worker) do
    receive do
      {:collector_query, ^worker, _} -> drain_queries(worker)
    after
      0 -> :ok
    end
  end
end
