defmodule CodexPooler.InstanceSettingsSandboxLifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.DataCase
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @shutdown_timeout 15_000

  defmodule BlockingRepo do
    def one(query) do
      Repo.checkout(fn ->
        Repo.query!("SELECT 1", [])
        observer = Application.fetch_env!(:codex_pooler, __MODULE__)
        send(observer, {:cache_connection_checked_out, self()})

        receive do
          :release_cache_connection -> Repo.one(query)
        after
          15_000 -> raise "cache connection release was not observed"
        end
      end)
    end
  end

  test "sandbox teardown drains reconciliation even when the published settings are unchanged" do
    previous_settings = Application.get_env(:codex_pooler, InstanceSettings, [])
    previous_cache = Cache.snapshot_for_test()
    owner = Sandbox.start_owner!(Repo, shared: true)
    cache = Process.whereis(Cache)
    parent = self()
    owner_monitor = Process.monitor(owner)

    try do
      :ok = Cache.put_for_test(InstanceSettings.ensure_singleton!())
      settings_cache = Cache.snapshot_for_test()
      generation = :sys.get_state(cache).reconciliation_timer.generation
      Application.put_env(:codex_pooler, InstanceSettings, repo: BlockingRepo)
      Application.put_env(:codex_pooler, BlockingRepo, parent)

      log =
        capture_log(fn ->
          send(cache, {Cache, {:reconcile, generation}})
          assert_receive {:cache_connection_checked_out, ^cache}, @shutdown_timeout
          assert Cache.snapshot_for_test() == settings_cache

          teardown =
            Task.async(fn ->
              receive do
                :stop_sandbox -> DataCase.stop_sandbox(owner, settings_cache)
              end
            end)

          :erlang.trace(teardown.pid, true, [:send])
          send(teardown.pid, :stop_sandbox)

          try do
            destination = await_teardown_call(teardown.pid, cache, owner)

            if destination == owner do
              assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, @shutdown_timeout
            end

            assert Process.alive?(owner), "sandbox owner stopped during cache reconciliation"
          after
            send(cache, :release_cache_connection)
            Task.await(teardown, @shutdown_timeout)
            :sys.get_state(cache)
          end
        end)

      refute log =~ "instance settings db load failed"
      refute log =~ "still using a connection from owner"
      refute Process.alive?(owner)
    after
      send(cache, :release_cache_connection)
      Application.put_env(:codex_pooler, InstanceSettings, previous_settings)
      Application.delete_env(:codex_pooler, BlockingRepo)
      Cache.restore_for_test(previous_cache)
      if Process.alive?(owner), do: Sandbox.stop_owner(owner)
      Process.demonitor(owner_monitor, [:flush])
    end
  end

  test "restored settings do not schedule database work after sandbox teardown" do
    previous_cache = Cache.snapshot_for_test()
    owner = Sandbox.start_owner!(Repo, shared: true)
    cache = Process.whereis(Cache)

    try do
      :ok = Cache.put_for_test(InstanceSettings.ensure_singleton!())
      snapshot = Cache.snapshot_for_test()
      :ok = DataCase.stop_sandbox(owner, snapshot)

      log =
        capture_log(fn ->
          case :sys.get_state(cache).reconciliation_timer do
            %{generation: generation} -> send(cache, {Cache, {:reconcile, generation}})
            nil -> :ok
          end

          :sys.get_state(cache)
        end)

      refute log =~ "instance settings db load failed", log
      assert Cache.snapshot_for_test() == snapshot
      assert :sys.get_state(cache).reconciliation_timer == nil
      assert :sys.get_state(cache).retry_timer == nil
    after
      Cache.restore_for_test(previous_cache)
      if Process.alive?(owner), do: Sandbox.stop_owner(owner)
    end
  end

  defp await_teardown_call(teardown, cache, owner) do
    receive do
      {:trace, ^teardown, :send, _message, destination} when destination in [cache, owner] ->
        destination

      {:trace, ^teardown, :send, _message, _destination} ->
        await_teardown_call(teardown, cache, owner)
    after
      @shutdown_timeout -> flunk("sandbox teardown did not reach the cache or owner")
    end
  end
end
