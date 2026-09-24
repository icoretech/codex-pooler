defmodule CodexPooler.Telemetry.ReviewRegressionsTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Telemetry.{Relay, RelayEvent, RelayRuntime}
  alias Ecto.Adapters.SQL.Sandbox

  @event [:codex_pooler, :quota, :cycle, :decision]
  @detection_ms 15_000

  test "coalescing beyond a durable row bound preserves every valid sample", context do
    runtime = runtime(context)
    count = RelayEvent.max_count() + 1
    emit_samples(runtime, count)
    flush(runtime)

    rows = Repo.all(RelayEvent)
    assert Enum.sum(Enum.map(rows, & &1.count)) == count
    assert Enum.all?(rows, &(&1.count <= RelayEvent.max_count()))
    assert rejected_samples() == 0
    assert :atomics.get(elem(:sys.get_state(runtime).capture, 1), 1) == 0
  end

  test "a failed second chunk retries only the unwritten remainder", context do
    runtime =
      runtime(context,
        insert_fun: fn event, labels, count, values, owner ->
          call = Process.get(:insert_call, 0) + 1
          Process.put(:insert_call, call)

          if call == 2,
            do: {:error, :unavailable},
            else: Relay.insert(event, labels, count, values, owner)
        end
      )

    emit_samples(runtime, RelayEvent.max_count() + 3)
    flush(runtime)
    assert Decimal.equal?(Repo.aggregate(RelayEvent, :sum, :count), RelayEvent.max_count())
    assert [{_, 3}] = :ets.tab2list(:sys.get_state(runtime).table)
    assert :atomics.get(elem(:sys.get_state(runtime).capture, 1), 1) == 1
    flush(runtime)
    assert Decimal.equal?(Repo.aggregate(RelayEvent, :sum, :count), RelayEvent.max_count() + 3)
    assert rejected_samples() == 0
  end

  test "failed rejected-sample checkpoint retries without another rejection", context do
    runtime =
      runtime(context,
        loss_fun: fn owner, reason, count ->
          call = Process.get(:loss_call, 0) + 1
          Process.put(:loss_call, call)

          if call == 1,
            do: {:error, :unavailable},
            else: Relay.checkpoint_loss(owner, reason, count)
        end
      )

    reject_sample()
    log = capture_log(fn -> flush(runtime) end)
    assert log =~ "loss persistence unavailable samples=1"
    assert rejected_samples() == 0
    capture_log(fn -> flush(runtime) end)
    assert rejected_samples() == 1
  end

  test "rejection arriving during checkpoint remains pending until persisted", context do
    parent = self()

    runtime =
      runtime(context,
        loss_fun: fn owner, reason, count ->
          if count == 1 do
            send(parent, {:checkpoint_started, self(), count})

            receive do
              :checkpoint_release -> :ok
            after
              @detection_ms -> raise "checkpoint barrier timed out"
            end
          end

          Relay.checkpoint_loss(owner, reason, count)
        end
      )

    reject_sample()

    capture_log(fn ->
      send(runtime, :flush)
      assert_receive {:checkpoint_started, ^runtime, 1}, @detection_ms
      reject_sample()
      send(runtime, :checkpoint_release)
      :sys.get_state(runtime)
      assert rejected_samples() == 1
      flush(runtime)
    end)

    assert rejected_samples() == 2
  end

  test "full retention batches promptly catch up while yielding to control messages", context do
    old = DateTime.add(DateTime.utc_now(), -172_800, :second)

    rows =
      for _ <- 1..350,
          do: %{
            event: "quota_cycle_decision",
            labels: %{},
            count: 1,
            measurements: %{},
            inserted_at: old,
            claimed_at: old,
            claimed_by: "test-consumer"
          }

    Repo.insert_all(RelayEvent, rows)
    parent = self()

    runtime =
      runtime(context,
        role: "web",
        cleanup_interval_ms: 60_000,
        cleanup_fun: fn ->
          {deleted, _} = Relay.prune()
          send(parent, {:cleanup_batch, deleted})
          if deleted == 100, do: :more, else: :done
        end
      )

    send(runtime, :cleanup)
    assert_receive {:cleanup_batch, 100}, @detection_ms
    assert :ok = GenServer.call(runtime, :quiesce, @detection_ms)
    assert_receive {:cleanup_batch, 100}, @detection_ms
    assert_receive {:cleanup_batch, 100}, @detection_ms
    assert_receive {:cleanup_batch, 50}, @detection_ms
    assert Repo.aggregate(RelayEvent, :count) == 0
    assert rejected_samples() == 0
  end

  test "default cleanup drains a real multi-batch retained backlog", context do
    insert_old_rows(250)
    runtime = runtime(context, role: "web", cleanup_interval_ms: 60_000)
    send(runtime, :cleanup)
    await_empty(System.monotonic_time(:millisecond) + @detection_ms)
    assert Repo.aggregate(RelayEvent, :count) == 0
  end

  test "bounded cleanup catches arrivals exceeding one batch per interval", context do
    parent = self()

    runtime =
      runtime(context,
        role: "web",
        cleanup_interval_ms: 60_000,
        cleanup_fun: fn ->
          generation = Process.get(:cleanup_generation, 0) + 1
          Process.put(:cleanup_generation, generation)
          if generation <= 4, do: insert_old_rows(120)
          result = Relay.cleanup()
          send(parent, {:cleanup_generation, generation, result})
          result
        end
      )

    send(runtime, :cleanup)
    for generation <- 1..4, do: assert_receive({:cleanup_generation, ^generation, :more}, @detection_ms)
    assert_receive {:cleanup_generation, 5, :done}, @detection_ms
    assert Repo.aggregate(RelayEvent, :count) == 0
  end

  test "shutdown chunk deadline counts only the unwritten remainder as lost", context do
    runtime =
      runtime(context,
        insert_fun: fn event, labels, count, values, owner ->
          result = Relay.insert(event, labels, count, values, owner)
          Process.put({RelayRuntime, :flush_deadline}, System.monotonic_time(:millisecond) - 1)
          result
        end
      )

    emit_samples(runtime, RelayEvent.max_count() + 7)
    log = capture_log(fn -> GenServer.stop(runtime) end)
    assert log =~ "unflushed_samples=7"
    assert Decimal.equal?(Repo.aggregate(RelayEvent, :sum, :count), RelayEvent.max_count())

    assert %{rows: [[7]]} =
             Repo.query!("SELECT samples FROM telemetry_relay_losses WHERE reason='shutdown_unflushed'")

    assert rejected_samples() == 0
  end

  defp insert_old_rows(count) do
    old = DateTime.add(DateTime.utc_now(), -172_800, :second)

    rows =
      for _ <- 1..count,
          do: %{
            event: "quota_cycle_decision",
            labels: %{},
            count: 1,
            measurements: %{},
            inserted_at: old,
            claimed_at: old,
            claimed_by: "test-consumer"
          }

    Repo.insert_all(RelayEvent, rows)
  end

  defp await_empty(deadline) do
    unless Repo.aggregate(RelayEvent, :count) == 0 do
      assert System.monotonic_time(:millisecond) < deadline, "cleanup failed to catch up"

      receive do
      after
        10 -> await_empty(deadline)
      end
    end
  end

  defp runtime(%{sandbox_owner: owner}, opts \\ []) do
    runtime =
      start_supervised!(
        {RelayRuntime,
         Keyword.merge(
           [enabled: true, start_paused: true, name: nil, role: "worker", flush_ms: 60_000],
           opts
         )},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, runtime)
    state = :sys.get_state(runtime)
    :ok = Relay.refresh_heartbeat(state.owner)
    runtime
  end

  defp emit_samples(runtime, count) do
    for batch <- Enum.chunk_every(1..count, 100) do
      for _ <- batch, do: :telemetry.execute(@event, %{count: 1}, %{scope: "review"})
      :sys.get_state(runtime)
    end
  end

  defp reject_sample, do: :telemetry.execute(@event, %{count: -1}, %{scope: "review"})

  defp flush(runtime) do
    send(runtime, :flush)
    :sys.get_state(runtime)
  end

  defp rejected_samples do
    %{rows: [[count]]} =
      Repo.query!("SELECT COALESCE(sum(samples), 0)::bigint FROM telemetry_relay_losses WHERE reason='rejected_sample'")

    count
  end
end
