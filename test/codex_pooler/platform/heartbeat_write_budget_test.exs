defmodule CodexPooler.Platform.HeartbeatWriteBudgetTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.UnboxedFixture
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Telemetry.Relay

  @tag capture_log: true
  @tag slow: "three real PostgreSQL heartbeat writes each exhaust their one-second production query budget"
  test "heartbeat writes release their checkout before a slow database operation completes" do
    suffix = System.unique_integer([:positive])
    function = "heartbeat_budget_#{suffix}"
    tables = ~w(instance_presences telemetry_relay_consumers telemetry_relay_heartbeats)

    register_unboxed_cleanup!(fn ->
      for table <- tables, do: Repo.query!("DROP TRIGGER IF EXISTS #{function} ON #{table}")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
    end)

    run_unboxed(fn ->
      Repo.query!("CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(10); RETURN NEW; END $$")

      for table <- tables,
          do: Repo.query!("CREATE TRIGGER #{function} BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION #{function}()")
    end)

    calls = [
      fn ->
        InstancePresence.record_heartbeat(InstancePresence.Identity.new("budget-test", Ecto.UUID.generate()))
      end,
      fn -> Relay.refresh_heartbeat("budget-#{suffix}") end,
      fn -> Relay.consumer_heartbeat("budget-#{suffix}") end
    ]

    for call <- calls do
      started = System.monotonic_time(:millisecond)

      result =
        run_unboxed(fn ->
          try do
            call.()
          rescue
            _ in [DBConnection.ConnectionError, Postgrex.Error] -> :bounded_failure
          catch
            :exit, _ -> :bounded_failure
          end
        end)

      assert result == :bounded_failure or match?({:error, _}, result)
      assert System.monotonic_time(:millisecond) - started < 8_000
    end
  end

  # A write that outlives its one-second budget costs the pooled connection it
  # holds: DBConnection enforces the budget by disconnecting it. When the server
  # stops answering (production: the database's storage stalls, and every pod's
  # heartbeat misses at once), the disconnect closes the socket under the
  # statement, Postgrex answers `disconnect_and_retry`, and DBConnection used to
  # check out a second connection under the same, already expired deadline and
  # disconnect that one too. The stall is injected at the boundary: a loopback
  # proxy in front of PostgreSQL stops relaying bytes on the connections it
  # already carries, while new connections (the cancel request, reconnects) pass.
  # A table lock is not a substitute: PostgreSQL answers the cancel of a lock
  # wait at once, so the error arrives before the socket closes and no retry
  # runs. The writes use the production pool (`DBConnection.ConnectionPool`) with
  # two connections, so a retry has a second one to take.
  @tag slow: "each of the three heartbeat writes waits out its one-second production budget against a stalled server"
  test "a heartbeat write that outlives its budget disconnects one pooled connection, not a second one on a retry" do
    suffix = System.unique_integer([:positive])
    node_name = "budget-stall-#{suffix}"
    owner = "budget-stall-#{suffix}"

    # A write that slips through (the unbounded retry this test guards against
    # can succeed on a reconnected connection) commits outside the sandbox.
    register_unboxed_cleanup!(fn ->
      Repo.query!("DELETE FROM instance_presences WHERE node_name = $1", [node_name])
      Repo.query!("DELETE FROM telemetry_relay_heartbeats WHERE owner = $1", [owner])
      Repo.query!("DELETE FROM telemetry_relay_consumers WHERE owner = $1", [owner])
    end)

    calls = [
      {"instance presence", fn -> InstancePresence.record_heartbeat(InstancePresence.Identity.new(node_name, Ecto.UUID.generate())) end},
      {"relay heartbeat", fn -> Relay.refresh_heartbeat(owner) end},
      {"relay consumer heartbeat", fn -> Relay.consumer_heartbeat(owner) end}
    ]

    for {{name, call}, index} <- Enum.with_index(calls) do
      proxy = start_stalling_proxy!()

      repo =
        start_supervised!(
          {Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 2, idle_interval: 60_000, hostname: "127.0.0.1", port: proxy.port},
          id: {:heartbeat_budget_repo, index}
        )

      await_pool_connected!(repo, 2)
      stall!(proxy)

      {{outcome, elapsed_ms}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Task.async(fn ->
            _previous = Repo.put_dynamic_repo(repo)
            started = System.monotonic_time(:millisecond)

            outcome =
              try do
                case call.() do
                  {:error, _reason} -> :bounded_failure
                  other -> {:returned, other}
                end
              rescue
                _ in [DBConnection.ConnectionError, Postgrex.Error] -> :bounded_failure
              catch
                :exit, _ -> :bounded_failure
              end

            {outcome, System.monotonic_time(:millisecond) - started}
          end)
          |> Task.await(15_000)
        end)

      :ok = stop_supervised({:heartbeat_budget_repo, index})
      stop_stalling_proxy!(proxy)

      disconnects = length(Regex.scan(~r/timed out because it queued and checked out the connection/, log))
      # The budget is one second; the margin covers the disconnect and scheduling, not a second attempt.
      assert {name, outcome, disconnects, elapsed_ms < 1_500} == {name, :bounded_failure, 1, true}
    end
  end

  # Both pooled connections must have finished their handshake before the stall,
  # or the stall would freeze a connect instead of a statement.
  defp await_pool_connected!(repo, size) do
    test_pid = self()
    ref = make_ref()

    holders = for _ <- 1..size, do: Task.async(fn -> hold_pool_connection(repo, test_pid, ref) end)

    for _ <- holders, do: assert_receive({:pool_connection_held, ^ref}, 15_000)
    for holder <- holders, do: send(holder.pid, {:release_pool_connection, ref})
    for holder <- holders, do: assert(Task.await(holder, 15_000) == :released)
    :ok
  end

  defp hold_pool_connection(repo, test_pid, ref) do
    _previous = Repo.put_dynamic_repo(repo)

    Repo.checkout(fn ->
      send(test_pid, {:pool_connection_held, ref})

      receive do
        {:release_pool_connection, ^ref} -> :released
      end
    end)
  end

  defp start_stalling_proxy! do
    config = Repo.config()
    target = {String.to_charlist(config[:hostname]), config[:port]}
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    # slot 1: connections accepted so far; slot 2: connections with a sequence at or below it are frozen
    counters = :atomics.new(2, [])
    acceptor = spawn(fn -> accept_loop(listen, target, counters) end)
    %{port: port, listen: listen, acceptor: acceptor, counters: counters}
  end

  defp stall!(%{counters: counters}), do: :atomics.put(counters, 2, :atomics.get(counters, 1))

  defp stop_stalling_proxy!(%{listen: listen, acceptor: acceptor}) do
    Process.exit(acceptor, :kill)
    :ok = :gen_tcp.close(listen)
  end

  defp accept_loop(listen, {host, port} = target, counters) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        sequence = :atomics.add_get(counters, 1, 1)
        {:ok, upstream} = :gen_tcp.connect(host, port, [:binary, active: false])
        spawn(fn -> relay(client, upstream, sequence, counters) end)
        spawn(fn -> relay(upstream, client, sequence, counters) end)
        accept_loop(listen, target, counters)

      {:error, _closed} ->
        :ok
    end
  end

  # Relays in bounded receive slices so a frozen connection keeps its bytes
  # unread without spinning.
  defp relay(from, to, sequence, counters) do
    if sequence <= :atomics.get(counters, 2) do
      Process.sleep(20)
      relay(from, to, sequence, counters)
    else
      case :gen_tcp.recv(from, 0, 50) do
        {:ok, data} ->
          _sent = :gen_tcp.send(to, data)
          relay(from, to, sequence, counters)

        {:error, :timeout} ->
          relay(from, to, sequence, counters)

        {:error, _closed} ->
          _closed = :gen_tcp.close(to)
          :ok
      end
    end
  end
end
