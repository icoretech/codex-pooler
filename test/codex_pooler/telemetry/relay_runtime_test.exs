defmodule CodexPooler.Telemetry.RelayRuntimeTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting.PreAttemptRelease
  alias CodexPooler.Gateway.Runtime.Finalization.InterruptionOutcome
  alias CodexPooler.Telemetry.{Relay, RelayEvent, RelayRuntime}
  alias Ecto.Adapters.SQL.Sandbox

  setup %{sandbox_owner: owner} = context do
    opts = [
      enabled: true,
      role: "worker",
      start_paused: true,
      name: :"relay-runtime-test-#{System.unique_integer([:positive])}",
      flush_ms: 60_000,
      drain_ms: 60_000
    ]

    runtime =
      if recovery = context[:relay_recovery] do
        start_recoverable_runtime!(opts, recovery)
      else
        start_supervised!({RelayRuntime, opts})
      end

    Sandbox.allow(Repo, owner, runtime)
    :ok = GenServer.call(runtime, :activate)
    state = :sys.get_state(runtime)

    %{
      sandbox_owner: owner,
      runtime: runtime,
      table: state.table,
      writer: state.owner,
      handler: state.handler
    }
  end

  test "captures each source contract with its bounded relay event", %{
    table: table,
    runtime: runtime
  } do
    events = [
      {[:codex_pooler, :quota, :cycle, :decision], "quota_cycle_decision", %{scope: :account}},
      {[:codex_pooler, :saved_reset, :convergence], "saved_reset_convergence", %{source: "x"}},
      {[:codex_pooler, :accounting, :reservation, :pre_attempt_release], "pre_attempt_release", %{phase: :reserve}},
      {[:codex_pooler, :gateway, :stream, :outcome], "stream_outcome", %{outcome: :ok}}
    ]

    Enum.each(events, fn {source, relay, metadata} ->
      :telemetry.execute(
        source,
        %{count: 2},
        Map.put(metadata, :oversized, String.duplicate("x", 200))
      )

      :sys.get_state(runtime)

      assert [{{^relay, _labels, _values}, 1}] =
               Enum.filter(:ets.tab2list(table), fn {{name, _, _}, _} -> name == relay end)
    end)
  end

  test "synchronized callbacks preserve emission multiplicity and original samples", %{
    table: table,
    runtime: runtime
  } do
    coordinator = self()
    gate = make_ref()
    writers = 32
    iterations = 200

    tasks =
      for _ <- 1..writers do
        Task.async(fn ->
          send(coordinator, {gate, self()})

          receive do
            ^gate -> :ok
          end

          for _ <- 1..iterations do
            :telemetry.execute(
              [:codex_pooler, :saved_reset, :convergence],
              # Whole milliseconds because that is what the storage layer accepts
              # and what `DateTime.diff/3` produces; a fractional one is refused
              # and counted, which the refusal tests below pin.
              %{count: 2, applied_to_canonical_ms: 5, applied_to_lifecycle_ms: 3},
              %{source: "runtime_headers", outcome: "confirmed_by_quota"}
            )
          end
        end)
      end

    for _ <- tasks do
      assert_receive {^gate, _pid}
    end

    Enum.each(tasks, &send(&1.pid, gate))
    Enum.each(tasks, &Task.await(&1, 10_000))
    :sys.get_state(runtime)

    assert [{{"saved_reset_convergence", _labels, measurements}, count}] = :ets.tab2list(table)
    assert count == writers * iterations
    assert measurements.applied_to_canonical_ms == 5
    assert measurements.applied_to_lifecycle_ms == 3
  end

  test "flush persists rows and drain re-emits once without recursion", %{
    runtime: runtime,
    table: table,
    sandbox_owner: owner
  } do
    ref = make_ref()
    test_pid = self()
    on_exit(fn -> :telemetry.detach(ref) end)

    :telemetry.attach(
      ref,
      [:codex_pooler, :quota, :cycle, :decision],
      fn _event, _measurements, _metadata, pid -> send(pid, :seen) end,
      test_pid
    )

    :telemetry.execute([:codex_pooler, :quota, :cycle, :decision], %{count: 1}, %{scope: "test"})
    send(runtime, :flush)
    :sys.get_state(runtime)
    assert_receive :seen, 1_000
    assert Repo.aggregate(RelayEvent, :count) == 1

    web =
      start_supervised!(%{
        id: make_ref(),
        start: {RelayRuntime, :start_link, [[enabled: true, role: "web", start_paused: true, name: nil]]}
      })

    Sandbox.allow(Repo, owner, web)
    send(web, :drain)
    :sys.get_state(web)
    assert_receive :seen, 1_000
    refute_received :seen
    assert :ets.tab2list(table) == []
    assert Repo.aggregate(RelayEvent, :count) == 1
  end

  test "startup publishes an owned heartbeat and termination detaches the handler", %{
    runtime: runtime,
    writer: writer,
    handler: handler,
    table: table
  } do
    assert Relay.heartbeat_fresh?(writer)
    assert Process.whereis(RelayRuntime) == nil

    assert Enum.any?(
             :telemetry.list_handlers([:codex_pooler, :quota, :cycle, :decision]),
             &(&1.id == handler)
           )

    monitor = Process.monitor(runtime)
    stop_supervised!(RelayRuntime)
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :shutdown}

    refute Enum.any?(
             :telemetry.list_handlers([:codex_pooler, :quota, :cycle, :decision]),
             &(&1.id == handler)
           )

    assert :ets.info(table) == :undefined
  end

  test "producer shutdown flushes the final captured sample", %{runtime: runtime} do
    InterruptionOutcome.emit("http_sse", "websocket")

    assert Repo.aggregate(RelayEvent, :count) == 0
    :ok = GenServer.stop(runtime)
    assert [%RelayEvent{event: "stream_outcome", count: 1}] = Repo.all(RelayEvent)
  end

  for finish_first? <- [true, false] do
    @tag finish_first?: finish_first?
    test "callback completion versus close transfers each sample once, completion first=#{finish_first?}",
         %{sandbox_owner: owner, finish_first?: finish_first?} do
      parent = self()

      runtime =
        start_supervised!(
          {RelayRuntime,
           enabled: true,
           role: "worker",
           start_paused: true,
           name: nil,
           before_capture_complete: fn ->
             send(parent, {:admitted, self()})

             receive do
               :finish -> :ok
             end
           end},
          id: make_ref()
        )

      Sandbox.allow(Repo, owner, runtime)
      GenServer.call(runtime, :activate)

      emitter =
        Task.async(fn ->
          PreAttemptRelease.emit(
            "stale_sweep",
            "http_sse",
            "stale_reservation_recovered"
          )
        end)

      assert_receive {:admitted, callback}

      if finish_first? do
        send(callback, :finish)
        Task.await(emitter)
      end

      log = ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(runtime) end)

      if finish_first? do
        assert [%RelayEvent{count: 1}] = Repo.all(RelayEvent)
        refute log =~ "unflushed_samples"
      else
        assert log =~ "unflushed_samples=1"
        send(callback, :finish)
        Task.await(emitter)
        assert Repo.all(RelayEvent) == []

        assert %{rows: [[1]]} =
                 Repo.query!("SELECT samples FROM telemetry_relay_losses WHERE reason='shutdown_unflushed'")
      end
    end
  end

  test "pending callback capacity is bounded and overflow is counted", %{sandbox_owner: owner} do
    parent = self()

    runtime =
      start_supervised!(
        {RelayRuntime,
         enabled: true,
         role: "worker",
         start_paused: true,
         name: nil,
         max_pending_callbacks: 1,
         before_capture_complete: fn ->
           send(parent, {:admitted, self()})

           receive do
             :finish -> :ok
           end
         end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, runtime)
    GenServer.call(runtime, :activate)

    emitter =
      Task.async(fn ->
        PreAttemptRelease.emit(
          "stale_sweep",
          "http_sse",
          "stale_reservation_recovered"
        )
      end)

    assert_receive {:admitted, callback}

    PreAttemptRelease.emit(
      "stale_sweep",
      "http_sse",
      "stale_reservation_recovered"
    )

    send(callback, :finish)
    Task.await(emitter)
    ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(runtime) end)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT samples FROM telemetry_relay_losses WHERE reason='buffer_overflow'")
  end

  test "sharded pending capacity stays global under concurrent admissions", %{
    sandbox_owner: owner
  } do
    parent = self()

    runtime =
      start_supervised!(
        {RelayRuntime,
         enabled: true,
         role: "worker",
         start_paused: true,
         name: nil,
         max_pending_callbacks: 64,
         before_capture_complete: fn ->
           send(parent, {:admission_result, :held, self()})

           receive do
             :finish -> :ok
           end
         end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, runtime)
    GenServer.call(runtime, :activate)

    tasks =
      for _ <- 1..128 do
        Task.async(fn ->
          PreAttemptRelease.emit(
            "stale_sweep",
            "http_sse",
            "stale_reservation_recovered"
          )

          send(parent, {:admission_result, :finished, self()})
        end)
      end

    results =
      for _ <- 1..128 do
        assert_receive {:admission_result, outcome, pid}, 15_000
        {outcome, pid}
      end

    state = :sys.get_state(runtime)

    rows =
      for {shard, _, pending, _} <- :ets.tab2list(state.callbacks), is_integer(shard), do: pending

    assert length(rows) == 64
    assert Enum.all?(rows, &(map_size(&1) <= 1))
    held = Enum.filter(results, &(elem(&1, 0) == :held))
    assert length(held) <= 64
    assert Enum.sum(Enum.map(rows, &map_size/1)) == length(held)
    for {_, pid} <- held, do: send(pid, :finish)
    Enum.each(tasks, &Task.await(&1, 15_000))
    ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(runtime) end)

    assert %{rows: [[dropped]]} =
             Repo.query!("SELECT samples FROM telemetry_relay_losses WHERE reason='buffer_overflow'")

    assert dropped + length(held) == 128
  end

  test "failed final flush records known shutdown loss", %{sandbox_owner: owner} do
    pid =
      start_supervised!(
        {RelayRuntime, enabled: true, role: "worker", start_paused: true, name: nil, insert_fun: fn _, _, _, _, _ -> {:error, :synthetic_unavailable} end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, pid)
    GenServer.call(pid, :activate)

    PreAttemptRelease.emit(
      "stale_sweep",
      "http_sse",
      "stale_reservation_recovered"
    )

    log = ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(pid) end)
    assert log =~ "unflushed_samples=1"

    assert %{rows: [[1]]} =
             Repo.query!("SELECT samples FROM telemetry_relay_losses WHERE reason='shutdown_unflushed'")
  end

  test "returned loss checkpoint errors warn with bounded sample count", %{sandbox_owner: owner} do
    pid =
      start_supervised!(
        {RelayRuntime, enabled: true, role: "worker", start_paused: true, name: nil, insert_fun: fn _, _, _, _, _ -> {:error, :unavailable} end, loss_fun: fn _, _, _ -> {:error, :unavailable} end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, pid)
    GenServer.call(pid, :activate)

    PreAttemptRelease.emit(
      "stale_sweep",
      "http_sse",
      "stale_reservation_recovered"
    )

    log = ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(pid) end)
    assert log =~ "loss persistence unavailable samples=1"
  end

  test "shutdown waits for a held final insert and persists its exact multiplicity", %{
    sandbox_owner: owner
  } do
    parent = self()

    pid =
      start_supervised!(
        {RelayRuntime,
         enabled: true,
         role: "worker",
         start_paused: true,
         name: nil,
         insert_fun: fn event, labels, count, values, writer ->
           send(parent, {:inserting, self(), count})

           receive do
             :release -> Relay.insert(event, labels, count, values, writer)
           end
         end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, pid)
    GenServer.call(pid, :activate)

    for _ <- 1..7,
        do:
          PreAttemptRelease.emit(
            "stale_sweep",
            "http_sse",
            "stale_reservation_recovered"
          )

    stopping = Task.async(fn -> GenServer.stop(pid) end)
    assert_receive {:inserting, ^pid, 7}
    send(pid, :release)
    assert :ok = Task.await(stopping)
    assert [%RelayEvent{count: 7}] = Repo.all(RelayEvent)
  end

  test "held claim completes before quiesce acknowledgement and no later claim starts", %{
    sandbox_owner: owner
  } do
    parent = self()

    web =
      start_supervised!(
        {RelayRuntime,
         enabled: true,
         role: "web",
         start_paused: true,
         name: nil,
         claim_fun: fn _, _ ->
           send(parent, {:claiming, self()})

           receive do
             :release -> {:ok, []}
           end
         end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, web)
    send(web, :drain)
    assert_receive {:claiming, ^web}
    quiesce = Task.async(fn -> GenServer.call(web, :quiesce) end)
    send(web, :release)
    assert :ok = Task.await(quiesce)
    send(web, :drain)
    :sys.get_state(web)
    refute_received {:claiming, _}
  end

  test "consumer quiesce acknowledges before later drain messages can claim", %{
    sandbox_owner: owner
  } do
    parent = self()

    web =
      start_supervised!(
        {RelayRuntime,
         enabled: true,
         role: "web",
         start_paused: true,
         name: nil,
         claim_fun: fn _, _ ->
           send(parent, :claimed)
           {:ok, []}
         end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, web)
    assert :ok = GenServer.call(web, :quiesce)
    send(web, :drain)
    :sys.get_state(web)
    refute_received :claimed
  end

  test "blocked consumer heartbeat cannot keep claim admission open after quiesce", %{
    sandbox_owner: owner
  } do
    parent = self()

    web =
      start_supervised!(
        {RelayRuntime,
         enabled: true,
         role: "web",
         name: nil,
         start_paused: true,
         claim_fun: fn _, _ ->
           send(parent, :claimed)
           {:ok, []}
         end,
         consumer_heartbeat_fun: fn _, closed ->
           if closed do
             {:error, :unavailable}
           else
             send(parent, {:heartbeat_blocked, self()})

             receive do
               :release -> {:error, :unavailable}
             end
           end
         end},
        id: make_ref()
      )

    Sandbox.allow(Repo, owner, web)
    send(web, :drain)
    assert_receive :claimed
    assert_receive {:heartbeat_blocked, ^web}
    send(web, :drain)
    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = RelayRuntime.quiesce(web, 10) end)
    assert log =~ "claim gate closed"
    send(web, :release)
    send(web, :drain)
    :sys.get_state(web)
    refute_received :claimed
  end

  test "stale writer requeues until its own heartbeat is refreshed", %{
    runtime: runtime,
    writer: writer,
    table: table
  } do
    Repo.query!(
      "UPDATE telemetry_relay_heartbeats SET heartbeat_at = NOW() - INTERVAL '2 minutes' WHERE owner = $1",
      [writer]
    )

    :ok = Relay.refresh_heartbeat("another-writer")
    refute Relay.heartbeat_fresh?(writer)

    for _ <- 1..2,
        do:
          :telemetry.execute([:codex_pooler, :quota, :cycle, :decision], %{count: 1}, %{
            scope: :account
          })

    send(runtime, :flush)
    :sys.get_state(runtime)
    assert Repo.aggregate(RelayEvent, :count) == 0
    assert [{_, 2}] = :ets.tab2list(table)
    send(runtime, :heartbeat)
    :sys.get_state(runtime)
    assert Relay.heartbeat_fresh?(writer)
    send(runtime, :flush)
    :sys.get_state(runtime)
    assert [%RelayEvent{count: 2}] = Repo.all(RelayEvent)
    assert :ets.tab2list(table) == []
  end

  test "cleanup failure schedules another cleanup pass" do
    parent = self()

    {:ok, runtime} =
      start_supervised(
        {RelayRuntime,
         [
           enabled: true,
           start_paused: true,
           name: :"relay-runtime-test-#{System.unique_integer([:positive])}",
           cleanup_interval_ms: 1,
           cleanup_fun: fn ->
             attempts = Process.get(:cleanup_attempts, 0) + 1
             Process.put(:cleanup_attempts, attempts)
             send(parent, {:cleanup_attempt, attempts})

             if attempts == 1, do: raise("synthetic cleanup failure")
           end
         ]},
        id: make_ref()
      )

    send(runtime, :cleanup)
    assert_receive {:cleanup_attempt, 1}
    assert_receive {:cleanup_attempt, 2}, 1_000
  end

  describe "a sample the storage layer will never accept" do
    test "is refused where it is captured, and counted", %{
      runtime: runtime,
      table: table,
      handler: handler
    } do
      # `flush_snapshot/3` re-accumulates anything that did not insert, which is
      # right for an outage and wrong for a value no retry can fix: a rejected
      # sample was re-queued forever, holding a `max_series` slot, with no
      # retry cap and no loss reason — claimed and vanished, the shape the
      # storage allowlist exists to eliminate. The capture path now asks the
      # same question the changeset asks, so the corrupt sample never becomes a
      # permanent resident.
      before = rejected_samples()
      quota_event = [:codex_pooler, :quota, :cycle, :decision]
      quota_handlers = :telemetry.list_handlers(quota_event)
      %{config: handler_config} = Enum.find(quota_handlers, &(&1.id == handler))

      # Exercise the owned relay's invalid-input boundary. Broadcasting an
      # invalid floating counter also crashes and detaches the unrelated Core
      # reporter, whose ETS counter intentionally accepts integers only.
      RelayRuntime.handle_event(
        [:codex_pooler, :saved_reset, :convergence],
        %{count: 1, applied_to_canonical_ms: 1.5},
        %{source: "reconciliation"},
        handler_config
      )

      RelayRuntime.handle_event(
        quota_event,
        %{count: 1.5},
        %{scope: :account},
        handler_config
      )

      :sys.get_state(runtime)
      assert :ets.tab2list(table) == []
      assert :telemetry.list_handlers(quota_event) == quota_handlers

      # Five cycles, because the defect was unbounded re-queuing rather than a
      # single lost flush: this is the state that used to never change.
      for _ <- 1..5 do
        send(runtime, :flush)
        :sys.get_state(runtime)
      end

      assert :ets.tab2list(table) == []
      assert Repo.aggregate(RelayEvent, :count) == 0
      assert rejected_samples() - before == 2

      # An integer measurement beside it is unaffected: the guard refuses the
      # corrupt sample, not the family.
      :telemetry.execute(
        [:codex_pooler, :saved_reset, :convergence],
        %{count: 1, applied_to_canonical_ms: 2},
        %{source: "reconciliation"}
      )

      :sys.get_state(runtime)
      send(runtime, :flush)
      :sys.get_state(runtime)
      assert [%RelayEvent{measurements: %{"applied_to_canonical_ms" => 2}}] = Repo.all(RelayEvent)
      assert rejected_samples() - before == 2
    end

    test "is counted lost when only the database can see it, through the real insert", %{
      runtime: runtime,
      table: table
    } do
      # The capture guard and the changeset are one predicate, so no sample the
      # capture path admits is refused by the *changeset*. The storage layer is
      # a different question, and it is the one that matters: the changeset
      # declares no bound on NUL bytes, invalid UTF-8, a constraint added by a
      # later migration, or anything else PostgreSQL alone decides, and a
      # refusal that arrives as an exception used to land in the catch-all and
      # re-queue forever.
      #
      # So this drives a refusal only the database can make — a real CHECK
      # constraint, added inside this test's transaction, that no changeset
      # knows about — through the real `Relay.insert`. A fabricated `insert_fun`
      # would exercise the arm without exercising the path.
      Repo.query!(
        "ALTER TABLE telemetry_relay_events ADD CONSTRAINT probe_refusal " <>
          "CHECK (labels->>'phase' IS DISTINCT FROM 'probe_refused')"
      )

      before = rejected_samples()

      :telemetry.execute(
        [:codex_pooler, :accounting, :reservation, :pre_attempt_release],
        %{count: 1},
        %{phase: "probe_refused"}
      )

      :sys.get_state(runtime)
      assert :ets.tab2list(table) != [], "the capture path refused it; nothing reached the insert"

      for _ <- 1..5 do
        send(runtime, :flush)
        :sys.get_state(runtime)
      end

      assert :ets.tab2list(table) == []
      assert Repo.aggregate(RelayEvent, :count) == 0
      assert rejected_samples() - before == 1
    end

    for {code, label, permanent?} <- [
          {"22P05", "a refusal no changeset declares", true},
          {"40001", "a serialization failure", false},
          {"08006", "a connection failure", false},
          {"53000", "an insufficient-resources failure", false},
          {"55P03", "a lock-unavailable failure", false},
          {"57000", "an operator-intervention failure", false},
          {"58000", "a system failure", false}
        ] do
      @tag code: code,
           permanent?: permanent?,
           relay_recovery: if(permanent?, do: nil, else: :sqlstate)
      test "#{label} is #{if permanent?, do: "counted", else: "re-queued"}, by its SQLSTATE", %{
        runtime: runtime,
        table: table,
        code: code,
        permanent?: permanent?
      } do
        # The arm above is reached through `Ecto.ConstraintError`, which is only
        # the subclass PostgreSQL reports as a constraint. A NUL byte is 22P05,
        # a bad encoding is 22021, and a future rule is whatever it is: those
        # arrive as a bare `Postgrex.Error`, and the first version of this fix
        # matched `Ecto.Changeset` alone and let every one of them re-queue
        # forever. So the rule is not an enumeration of what is permanent — that
        # set is open — but of the few server errors that are about the server.
        #
        # These two cases differ in one character of one SQLSTATE and in nothing
        # else: same trigger, same row, same five flush cycles. If the
        # classification stopped working, they would stop disagreeing.
        install_refusal_trigger!(code)
        before = rejected_samples()

        :telemetry.execute(
          [:codex_pooler, :accounting, :reservation, :pre_attempt_release],
          %{count: 1},
          %{phase: "probe_refused"}
        )

        :sys.get_state(runtime)
        assert :ets.tab2list(table) != []

        for _ <- 1..5 do
          send(runtime, :flush)
          :sys.get_state(runtime)
        end

        assert Repo.aggregate(RelayEvent, :count) == 0

        if permanent? do
          assert :ets.tab2list(table) == []
          assert rejected_samples() - before == 1
        else
          assert [{_key, 1}] = :ets.tab2list(table)
          assert rejected_samples() - before == 0

          recover_relay!(runtime, :sqlstate)

          assert [%RelayEvent{count: 1, labels: %{"phase" => "probe_refused"}}] =
                   Repo.all(RelayEvent)
        end
      end
    end

    @tag relay_recovery: :heartbeat
    test "is not a sample the database never saw: an outage still re-queues", %{
      runtime: runtime,
      table: table,
      writer: writer
    } do
      # The other half of the same decision. A failure the server never
      # answered — here the producer's own heartbeat, the outage the module
      # already models — must keep its sample, or a database blip becomes data
      # loss. `stale writer requeues until its own heartbeat is refreshed`
      # pins the recovery; this pins that the new permanent arm did not eat it.
      before = rejected_samples()

      Repo.query!(
        "UPDATE telemetry_relay_heartbeats SET heartbeat_at = NOW() - INTERVAL '2 minutes' WHERE owner = $1",
        [writer]
      )

      :telemetry.execute([:codex_pooler, :quota, :cycle, :decision], %{count: 1}, %{
        scope: :account
      })

      :sys.get_state(runtime)

      for _ <- 1..5 do
        send(runtime, :flush)
        :sys.get_state(runtime)
      end

      assert [{_key, 1}] = :ets.tab2list(table)
      assert rejected_samples() - before == 0

      recover_relay!(runtime, :heartbeat)
      assert [%RelayEvent{count: 1, event: "quota_cycle_decision"}] = Repo.all(RelayEvent)
    end

    test "a label value PostgreSQL cannot store is bounded before it is captured", %{
      runtime: runtime,
      table: table
    } do
      # `bounded/1` bounded length and type and let a NUL byte through, so an
      # 11-byte label value carrying one passed every predicate and then made
      # `Relay.insert` raise 22P05. It is not a short label; it is a value the
      # storage layer refuses. It is bounded to `unknown` the same way an
      # oversized or non-binary value already is, so the sample still counts.
      before = rejected_samples()

      :telemetry.execute(
        [:codex_pooler, :accounting, :reservation, :pre_attempt_release],
        %{count: 1},
        %{phase: "in_process" <> <<0>>, outcome: <<0xFF, 0xFE>>}
      )

      :sys.get_state(runtime)
      assert [{{"pre_attempt_release", labels, _values}, 1}] = :ets.tab2list(table)
      assert labels.phase == "unknown"
      assert labels.outcome == "unknown"

      send(runtime, :flush)
      :sys.get_state(runtime)

      assert [%RelayEvent{labels: %{"phase" => "unknown"}}] = Repo.all(RelayEvent)
      assert rejected_samples() - before == 0
    end
  end

  defp start_recoverable_runtime!(opts, recovery) do
    name = Keyword.fetch!(opts, :name)

    # ExUnit stops supervised children before on_exit. These fault scenarios
    # need recovery while the sandbox is still alive, even if an assertion fails.
    on_exit(fn -> stop_recoverable_runtime!(name, recovery) end)

    {:ok, runtime} = RelayRuntime.start_link(opts)
    Process.unlink(runtime)
    runtime
  end

  defp stop_recoverable_runtime!(name, recovery) do
    if runtime = GenServer.whereis(name) do
      state = :sys.get_state(runtime)
      monitor = Process.monitor(runtime)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          try do
            recover_relay!(runtime, recovery)
          after
            GenServer.stop(runtime)
          end
        end)

      assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
      assert :ets.info(state.table) == :undefined
      refute Enum.any?(:telemetry.list_handlers([]), &(&1.id == state.handler))
      assert log == ""
    end
  end

  defp recover_relay!(runtime, recovery) do
    state = :sys.get_state(runtime)
    :telemetry.detach(state.handler)

    if recovery == :sqlstate do
      Repo.query!("DROP TRIGGER IF EXISTS relay_probe_refusal ON telemetry_relay_events")
    end

    # Every scenario emits synchronously from its test process. Detaching closes
    # admission; the same-sender flush and state call fence the remaining sample.
    send(runtime, :heartbeat)
    send(runtime, :flush)
    :sys.get_state(runtime)
    assert :ets.tab2list(state.table) == []
  end

  # A real server refusal of a real row, at a SQLSTATE the caller chooses. A
  # `CHECK` can only ever be `23514`, and the class this has to cover is the one
  # PostgreSQL does not report as a constraint at all. Sandbox rollback removes
  # both objects with the test's transaction.
  defp install_refusal_trigger!(sqlstate) do
    Repo.query!("""
    CREATE FUNCTION relay_probe_refuse() RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      RAISE EXCEPTION 'relay probe refusal' USING ERRCODE = '#{sqlstate}';
    END
    $fn$
    """)

    Repo.query!("""
    CREATE TRIGGER relay_probe_refusal BEFORE INSERT ON telemetry_relay_events
      FOR EACH ROW WHEN (NEW.labels->>'phase' = 'probe_refused')
      EXECUTE FUNCTION relay_probe_refuse()
    """)
  end

  defp rejected_samples do
    %{rows: rows} =
      Repo.query!("SELECT samples FROM telemetry_relay_losses WHERE reason = 'rejected_sample'")

    case rows do
      [[samples]] -> samples
      [] -> 0
    end
  end
end
