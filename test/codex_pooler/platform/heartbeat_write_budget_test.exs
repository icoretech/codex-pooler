defmodule CodexPooler.Platform.HeartbeatWriteBudgetTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.UnboxedFixture
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.StallingPostgresProxy
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
  # disconnect that one too. The stall is injected at the boundary by
  # `CodexPooler.StallingPostgresProxy`, which also explains why a table lock
  # is not a substitute. The writes use the production pool (`DBConnection.ConnectionPool`) with
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
      proxy = StallingPostgresProxy.start!()
      repo = StallingPostgresProxy.start_repo!(proxy, {:heartbeat_budget_repo, index}, 2)
      StallingPostgresProxy.stall!(proxy)

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
      StallingPostgresProxy.stop!(proxy)

      disconnects = length(Regex.scan(~r/timed out because it queued and checked out the connection/, log))
      # The budget is one second; the margin covers the disconnect and scheduling, not a second attempt.
      assert {name, outcome, disconnects, elapsed_ms < 1_500} == {name, :bounded_failure, 1, true}
    end
  end
end
