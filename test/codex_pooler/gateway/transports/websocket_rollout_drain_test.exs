defmodule CodexPooler.Gateway.Transports.Websocket.RolloutDrainTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport.{
    ActiveShutdownProbeOwner,
    DrainProbeOwner,
    SlowFinalStatusOwner,
    VirtualDeadline,
    WaitingOwner
  }

  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

  # Two independent clocks run in most tests here: the drain's own `timeout_ms`,
  # which is the budget under test, and the test's wait for the result. When they
  # are set to the same value the wait has no headroom, and a loaded machine turns
  # a drain that was merely slow into an await crash. Keep the detection budget
  # well above every scenario budget so only the drain's own clock decides an
  # outcome.
  @drain_timeout_ms 1_000
  @await_timeout_ms 10_000

  setup do
    previous_config = Application.get_env(:codex_pooler, RolloutDrain)
    previous_timeout = System.get_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS")
    drain_name = :"rollout-drain-#{System.unique_integer([:positive])}"
    start_supervised!({RolloutDrain, name: drain_name})

    on_exit(fn ->
      if previous_config do
        Application.put_env(:codex_pooler, RolloutDrain, previous_config)
      else
        Application.delete_env(:codex_pooler, RolloutDrain)
      end

      restore_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", previous_timeout)
    end)

    {:ok, drain_name: drain_name}
  end

  test "flips the app drain flag and drains local owner sessions with a compact summary",
       %{drain_name: drain_name} do
    first_context = owner_context()
    second_context = owner_context()

    on_exit(fn ->
      cleanup_owner_session(first_context.codex_session_id)
      cleanup_owner_session(second_context.codex_session_id)
    end)

    first_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    second_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert RolloutDrain.draining?(name: drain_name) == false
    assert {:ok, first_owner} = start_owner(first_context, upstream: first_upstream)
    assert_receive {:websocket_owner_harness_upstream_started, first_upstream_pid}
    assert {:ok, second_owner} = start_owner(second_context, upstream: second_upstream)
    assert_receive {:websocket_owner_harness_upstream_started, second_upstream_pid}

    first_ref = Process.monitor(first_owner)
    second_ref = Process.monitor(second_owner)

    assert %{
             result: :ok,
             owners_seen: 2,
             owners_drained: 2,
             owners_idle: 2,
             owners_failed: 0,
             turns_completed: 0,
             turns_aborted: 0,
             timeout_ms: @drain_timeout_ms,
             elapsed_ms: elapsed_ms,
             already_draining?: false
           } = RolloutDrain.start_drain(name: drain_name, timeout_ms: @drain_timeout_ms)

    assert is_integer(elapsed_ms) and elapsed_ms >= 0
    assert RolloutDrain.draining?(name: drain_name)

    assert_receive {:DOWN, ^first_ref, :process, ^first_owner, :normal}
    assert_receive {:DOWN, ^second_ref, :process, ^second_owner, :normal}
    assert_receive {:websocket_owner_harness_upstream_closed, ^first_upstream_pid}
    assert_receive {:websocket_owner_harness_upstream_closed, ^second_upstream_pid}
  end

  test "concurrent and repeated drains are idempotent and enumerate fresh owners",
       %{drain_name: drain_name} do
    first_key = owner_key()
    second_key = owner_key()

    first_owner = start_supervised!({DrainProbeOwner, key: first_key, parent: self()})

    first_task =
      Task.async(fn ->
        RolloutDrain.start_drain(name: drain_name, timeout_ms: @drain_timeout_ms)
      end)

    assert_receive {:rollout_drain_probe_started, ^first_key}
    assert RolloutDrain.draining?(name: drain_name)

    second_task =
      Task.async(fn ->
        RolloutDrain.start_drain(name: drain_name, timeout_ms: @drain_timeout_ms)
      end)

    send(first_owner, {:release_rollout_drain_probe, first_key})

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_idle: 1,
             owners_failed: 0,
             timeout_ms: @drain_timeout_ms
           } = Task.await(first_task, @await_timeout_ms)

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_idle: 1,
             owners_failed: 0,
             timeout_ms: @drain_timeout_ms
           } = Task.await(second_task, @await_timeout_ms)

    second_owner =
      start_supervised!({DrainProbeOwner, key: second_key, parent: self()})

    repeated_task =
      Task.async(fn ->
        RolloutDrain.start_drain(name: drain_name, timeout_ms: @drain_timeout_ms)
      end)

    assert_receive {:rollout_drain_probe_started, ^second_key}
    send(second_owner, {:release_rollout_drain_probe, second_key})

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_idle: 1,
             owners_failed: 0,
             timeout_ms: @drain_timeout_ms,
             already_draining?: true
           } = Task.await(repeated_task, @await_timeout_ms)
  end

  test "release-callable shutdown drain is idempotent through configured app server",
       %{drain_name: drain_name} do
    configure_rollout_drain_server(drain_name)
    System.put_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", "750")

    owner_key = owner_key()
    owner = start_supervised!({DrainProbeOwner, key: owner_key, parent: self()})

    first_task = Task.async(fn -> RolloutDrain.drain_for_shutdown() end)

    assert_receive {:rollout_drain_probe_started, ^owner_key}
    send(owner, {:release_rollout_drain_probe, owner_key})

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_failed: 0,
             timeout_ms: 750,
             already_draining?: false
           } = Task.await(first_task, @await_timeout_ms)

    assert %{
             result: :ok,
             owners_seen: 0,
             owners_drained: 0,
             owners_failed: 0,
             timeout_ms: repeated_timeout_ms,
             already_draining?: true
           } = RolloutDrain.drain_for_shutdown()

    assert repeated_timeout_ms in 1..750
  end

  test "release-callable shutdown drain does not spend a fresh timeout after a timed-out drain",
       %{drain_name: drain_name} do
    configure_rollout_drain_server(drain_name)
    System.put_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", "120")

    owner_key = owner_key()

    # This probe is never released: the drain is meant to spend its 120ms budget
    # and report a failed owner. A short release timeout keeps teardown quick
    # without affecting the assertions, which hold whichever of the two fires
    # first.
    _owner =
      start_supervised!(
        {DrainProbeOwner, key: owner_key, parent: self(), release_timeout_ms: 1_000}
      )

    {first_elapsed_us, first_summary} = :timer.tc(fn -> RolloutDrain.drain_for_shutdown() end)

    assert_receive {:rollout_drain_probe_started, ^owner_key}

    assert %{
             result: :error,
             owners_seen: 1,
             owners_drained: 0,
             owners_failed: 1,
             timeout_ms: 120,
             already_draining?: false
           } = first_summary

    {second_elapsed_us, second_summary} = :timer.tc(fn -> RolloutDrain.drain_for_shutdown() end)

    assert second_elapsed_us < first_elapsed_us / 2

    assert %{
             result: :ok,
             owners_seen: 0,
             owners_drained: 0,
             owners_failed: 0,
             already_draining?: true
           } = second_summary
  end

  test "release-callable shutdown drain falls back on invalid timeout configuration",
       %{drain_name: drain_name} do
    configure_rollout_drain_server(drain_name)
    System.put_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", "0")

    assert %{
             result: :ok,
             owners_seen: 0,
             owners_drained: 0,
             owners_failed: 0,
             timeout_ms: 50_000,
             already_draining?: false
           } = RolloutDrain.drain_for_shutdown()
  end

  test "application prep_stop drains through the release-callable coordinator before shutdown",
       %{drain_name: drain_name} do
    configure_rollout_drain_server(drain_name)
    System.put_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", "750")

    owner_key = owner_key()
    owner = start_supervised!({DrainProbeOwner, key: owner_key, parent: self()})

    prep_stop_task = Task.async(fn -> CodexPooler.Application.prep_stop(:shutdown_state) end)

    assert_receive {:rollout_drain_probe_started, ^owner_key}
    assert RolloutDrain.draining?(name: drain_name)

    send(owner, {:release_rollout_drain_probe, owner_key})

    assert :shutdown_state = Task.await(prep_stop_task, @await_timeout_ms)
    assert RolloutDrain.draining?(name: drain_name)
  end

  test "active release-callable shutdown drain is reused by application prep_stop",
       %{drain_name: drain_name} do
    configure_rollout_drain_server(drain_name)
    System.put_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", "240")

    owner_key = owner_key()

    owner =
      start_supervised!({ActiveShutdownProbeOwner, key: owner_key, parent: self()})

    first_task = Task.async(fn -> RolloutDrain.drain_for_shutdown() end)

    assert_receive {:active_shutdown_probe_started, ^owner_key, 1}

    prep_stop_task =
      Task.async(fn -> CodexPooler.Application.prep_stop(:duplicate_shutdown_state) end)

    assert :ok = await_active_drain_waiters(drain_name, 2)
    send(owner, {:release_active_shutdown_probe, owner_key})

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_failed: 0,
             timeout_ms: 240,
             already_draining?: false
           } = Task.await(first_task, @await_timeout_ms)

    assert :duplicate_shutdown_state = Task.await(prep_stop_task, @await_timeout_ms)
    assert GenServer.call(owner, :drain_calls, @await_timeout_ms) == 1
  end

  @tag :rollout_drain_t1
  test "T1 drain waits for an active turn terminal before stopping its owner", %{
    drain_name: _drain_name
  } do
    harness = start_rollout_drain_harness(self())
    deadline = harness.deadline
    owner_key = owner_key()
    owner = start_supervised!({WaitingOwner, key: owner_key, parent: self()})
    owner_ref = Process.monitor(owner)

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++ deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_begin_wait, ^owner_key, 1}
    assert_receive {:rollout_drain_deadline_wait, ^deadline, wait_ms}
    refute_received {:rollout_drain_owner_stopped, ^owner_key, _outcome, _calls}

    assert :ok = WaitingOwner.complete_turn(owner)
    assert_receive {:rollout_drain_terminal_delivered, ^owner_key}
    assert :ok = VirtualDeadline.advance(harness.deadline, wait_ms)

    assert_receive {:rollout_drain_owner_stopped, ^owner_key, :completed, 1}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_failed: 0,
             turns_completed: 1,
             turns_aborted: 0
           } = Task.await(drain_task, @await_timeout_ms)

    assert VirtualDeadline.waiter_pids(deadline) == []
  end

  @tag :rollout_drain_t2
  test "T2 injectable deadline clamps a tiny budget and preserves exact abort fallback" do
    harness = start_rollout_drain_harness(self())
    deadline = harness.deadline
    owner_key = owner_key()
    owner = start_supervised!({WaitingOwner, key: owner_key, parent: self()})
    owner_ref = Process.monitor(owner)

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [
            name: harness.name,
            timeout_ms: 25,
            deadline_margin_ms: 20,
            deadline_floor_ms: 10
          ] ++ deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_begin_wait, ^owner_key, 1}
    assert_receive {:rollout_drain_deadline_wait, ^deadline, 10}
    assert :ok = VirtualDeadline.advance(harness.deadline, 10)

    assert_receive {:rollout_drain_owner_stopped, ^owner_key, :aborted, 1}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_failed: 0,
             turns_completed: 0,
             turns_aborted: 1,
             timeout_ms: 25
           } = Task.await(drain_task, @await_timeout_ms)
  end

  @tag :rollout_drain_t4
  test "T4 joined shutdown drains share one active-turn wait and one abort decision" do
    harness = start_rollout_drain_harness(self())
    deadline = harness.deadline
    configure_rollout_drain_server(harness.name)
    System.put_env("CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS", "240")

    owner_key = owner_key()
    owner = start_supervised!({WaitingOwner, key: owner_key, parent: self()})

    first_task = Task.async(fn -> RolloutDrain.drain_for_shutdown() end)
    assert_receive {:rollout_drain_begin_wait, ^owner_key, 1}
    assert_receive {:rollout_drain_deadline_wait, ^deadline, wait_ms}

    second_task = Task.async(fn -> RolloutDrain.drain_for_shutdown() end)
    assert :ok = await_active_drain_waiters(harness.name, 2)

    assert :ok = WaitingOwner.complete_turn(owner)
    assert_receive {:rollout_drain_terminal_delivered, ^owner_key}
    assert :ok = VirtualDeadline.advance(harness.deadline, wait_ms)
    assert_receive {:rollout_drain_owner_stopped, ^owner_key, :completed, 1}
    refute_received {:rollout_drain_owner_stopped, ^owner_key, _outcome, 2}

    first_summary = Task.await(first_task, @await_timeout_ms)
    assert Task.await(second_task, @await_timeout_ms) == first_summary
    assert first_summary.turns_completed == 1
    assert first_summary.turns_aborted == 0
  end

  @tag :rollout_drain_t5
  test "T5 client disconnect wins during rollout wait without blocking socket cleanup" do
    harness = start_rollout_drain_harness(self())
    owner_key = owner_key()
    owner = start_supervised!({WaitingOwner, key: owner_key, parent: self()})
    owner_ref = Process.monitor(owner)

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++ deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_begin_wait, ^owner_key, 1}
    assert :ok = WebsocketOwnerSession.drain_owner(owner)
    assert_receive {:rollout_drain_owner_stopped, ^owner_key, :aborted, 1}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert %{owners_failed: 1, turns_completed: 0} = Task.await(drain_task, @await_timeout_ms)
    refute_received {:rollout_drain_owner_stopped, ^owner_key, _outcome, 2}
    assert VirtualDeadline.waiter_pids(harness.deadline) == []
  end

  @tag :rollout_drain_t6
  test "T6 owner crash during rollout wait is failed rather than completed" do
    assert_waiting_owner_failure(:crash)
  end

  @tag :rollout_drain_t6
  test "T6 lease loss during rollout wait is failed rather than completed" do
    assert_waiting_owner_failure(:lease_loss)
  end

  test "tiny deadline reserves the final owner status and near-timeout drain calls" do
    harness = start_rollout_drain_harness(self())
    owner_key = owner_key()
    owner = start_supervised!({SlowFinalStatusOwner, key: owner_key, parent: self()})

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [
            name: harness.name,
            timeout_ms: 25,
            deadline_margin_ms: 20,
            deadline_floor_ms: 10
          ] ++ deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, deadline, 10}
    assert :ok = VirtualDeadline.advance(deadline, 10)
    assert_receive {:slow_final_owner_status_started, ^owner_key}
    Process.send_after(owner, {:release_slow_final_owner_status, owner_key}, 600)
    assert_receive {:slow_final_owner_drain_started, ^owner_key}, 1_000
    Process.send_after(owner, {:release_slow_final_owner_drain, owner_key}, 4_950)

    assert %{
             result: :ok,
             owners_drained: 1,
             owners_failed: 0,
             turns_completed: 1,
             turns_aborted: 0
           } = Task.await(drain_task, 11_000)
  end

  test "task timeout leaves no hung deadline waiter process" do
    harness = start_rollout_drain_harness(self())
    owner_key = owner_key()
    _owner = start_supervised!({WaitingOwner, key: owner_key, parent: self()})

    assert %{owners_failed: 1} =
             RolloutDrain.start_drain(
               [
                 name: harness.name,
                 timeout_ms: 25,
                 deadline_margin_ms: 20,
                 deadline_floor_ms: 10
               ] ++ deadline_options(harness.deadline)
             )

    assert VirtualDeadline.waiter_pids(harness.deadline) == []
  end

  test "wait callback failure leaves no waiter process or stale elapsed message" do
    parent = self()
    drain_name = :"rollout-drain-wait-error-#{System.unique_integer([:positive])}"

    deadline = %{
      now_ms: fn -> System.monotonic_time(:millisecond) end,
      schedule_wait: fn _recipient, wait_token, _wait_ms ->
        send(parent, {:rollout_drain_wait_callback_started, wait_token})
        raise "synthetic wait callback failure"
      end,
      cancel_wait: fn _wait_ref, _wait_token -> :ok end
    }

    {RolloutDrain, name: drain_name, deadline: deadline}
    |> Supervisor.child_spec(id: {RolloutDrain, drain_name})
    |> start_supervised!()

    owner_key = owner_key()
    _owner = start_supervised!({WaitingOwner, key: owner_key, parent: self()})

    assert %{owners_failed: 1, owners_drained: 0} =
             RolloutDrain.start_drain(name: drain_name, timeout_ms: 500, deadline: deadline)

    assert_receive {:rollout_drain_wait_callback_started, wait_token}
    refute_received {:rollout_drain_wait_elapsed, ^wait_token}
  end

  defp assert_waiting_owner_failure(failure) do
    harness = start_rollout_drain_harness(self())
    owner_key = owner_key()
    owner = start_supervised!({WaitingOwner, key: owner_key, parent: self()})
    owner_ref = Process.monitor(owner)

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++ deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_begin_wait, ^owner_key, 1}

    expected_reason =
      case failure do
        :crash ->
          Process.exit(owner, :kill)
          :killed

        :lease_loss ->
          assert :ok = WaitingOwner.lose_lease(owner)
          assert_receive {:rollout_drain_lease_lost, ^owner_key}
          {:shutdown, :stale_owner}
      end

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, ^expected_reason}

    assert %{
             owners_failed: 1,
             turns_completed: 0,
             turns_aborted: 0
           } = Task.await(drain_task, @await_timeout_ms)
  end
end
