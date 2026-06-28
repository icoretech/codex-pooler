defmodule CodexPooler.Gateway.Transports.Websocket.RolloutDrainTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain

  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport.{
    ActiveShutdownProbeOwner,
    DrainProbeOwner
  }

  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

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
             owners_failed: 0,
             timeout_ms: 1_000,
             elapsed_ms: elapsed_ms,
             already_draining?: false
           } = RolloutDrain.start_drain(name: drain_name, timeout_ms: 1_000)

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
        RolloutDrain.start_drain(name: drain_name, timeout_ms: 1_000)
      end)

    assert_receive {:rollout_drain_probe_started, ^first_key}
    assert RolloutDrain.draining?(name: drain_name)

    second_task =
      Task.async(fn ->
        RolloutDrain.start_drain(name: drain_name, timeout_ms: 1_000)
      end)

    send(first_owner, {:release_rollout_drain_probe, first_key})

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_failed: 0,
             timeout_ms: 1_000
           } = Task.await(first_task, 1_000)

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_failed: 0,
             timeout_ms: 1_000
           } = Task.await(second_task, 1_000)

    second_owner =
      start_supervised!({DrainProbeOwner, key: second_key, parent: self()})

    repeated_task =
      Task.async(fn ->
        RolloutDrain.start_drain(name: drain_name, timeout_ms: 1_000)
      end)

    assert_receive {:rollout_drain_probe_started, ^second_key}
    send(second_owner, {:release_rollout_drain_probe, second_key})

    assert %{
             result: :ok,
             owners_seen: 1,
             owners_drained: 1,
             owners_failed: 0,
             timeout_ms: 1_000,
             already_draining?: true
           } = Task.await(repeated_task, 1_000)
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
           } = Task.await(first_task, 1_000)

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
    _owner = start_supervised!({DrainProbeOwner, key: owner_key, parent: self()})

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

    assert :shutdown_state = Task.await(prep_stop_task, 1_000)
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
           } = Task.await(first_task, 1_000)

    assert :duplicate_shutdown_state = Task.await(prep_stop_task, 1_000)
    assert GenServer.call(owner, :drain_calls, 250) == 1
  end
end
