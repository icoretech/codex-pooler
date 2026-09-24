defmodule CodexPooler.Platform.InstancePresencePeerPublishTest do
  use CodexPooler.DataCase, async: false

  # findings#206 row 206-473: a BEAM peer's single presence beat overran
  # InstancePresence's one-second production write budget on a loaded host, and
  # DBConnection closed the connection under its insert (`tcp recv: closed`).
  # `InstancePresencePeer.publish_presence!/2` publishes through the production
  # heartbeat instead. The overrun is injected at the database boundary by
  # `CodexPooler.StallingPostgresProxy`, never by load.

  alias CodexPooler.{InstancePresencePeer, StallingPostgresProxy, UnboxedFixture}
  alias CodexPooler.Platform.InstancePresence

  @peer_call_budget_ms 15_000

  @tag slow: "boots a BEAM peer whose first presence beat waits out its one-second production budget"
  test "a peer beat cut by its write budget is retried by the heartbeat and the presence row lands" do
    proxy = StallingPostgresProxy.start!()
    on_exit(fn -> StallingPostgresProxy.stop!(proxy) end)
    # One pooled connection, reaching PostgreSQL only through the proxy.
    {peer, identity} = start_peer!(hostname: "127.0.0.1", port: proxy.port, pool_size: 1)

    # That pooled connection is connected before the stall, so the
    # first beat's statement is frozen rather than its connect; the reconnect
    # after the budget's disconnect passes the proxy.
    %{rows: [[1]]} = :peer.call(peer, Repo, :query!, ["SELECT 1"], @peer_call_budget_ms)
    :ok = StallingPostgresProxy.stall!(proxy)

    assert InstancePresencePeer.publish_presence!(peer, @peer_call_budget_ms) >= 1

    assert UnboxedFixture.run_unboxed(fn ->
             Repo.exists?(from instance in InstancePresence.Instance, where: instance.instance_id == ^identity.instance_id)
           end)
  end

  @tag slow: "boots a BEAM peer whose every presence write fails and waits out a one-second publication budget"
  test "a peer with no landed beat inside the budget fails naming its failed beats and the write budget" do
    {peer, identity} = start_peer!([])
    function = "presence_publish_failure_#{System.unique_integer([:positive])}"

    UnboxedFixture.register_unboxed_cleanup!(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{function} ON instance_presences")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
    end)

    UnboxedFixture.run_unboxed(fn ->
      Repo.query!("""
      CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.instance_id = '#{identity.instance_id}' THEN
          RAISE EXCEPTION 'synthetic presence write failure';
        END IF;
        RETURN NEW;
      END $$
      """)

      Repo.query!("CREATE TRIGGER #{function} BEFORE INSERT ON instance_presences FOR EACH ROW EXECUTE FUNCTION #{function}()")
    end)

    error = assert_raise ExUnit.AssertionError, fn -> InstancePresencePeer.publish_presence!(peer, 1_000) end
    assert error.message =~ ~r/published no presence within 1000 ms: [1-9]\d* heartbeat beat\(s\) failed/
    assert error.message =~ "one-second production write budget"
  end

  # An unnamed peer: presence publication needs no distribution.
  defp start_peer!(repo_overrides) do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})
    os_pid = :peer.call(peer, :os, :getpid, [], @peer_call_budget_ms) |> List.to_string()
    os_identity = InstancePresencePeer.capture_os_process_identity!(os_pid)
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()], @peer_call_budget_ms)
    config = Keyword.merge(Repo.config(), repo_overrides)

    :ok =
      :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :bootstrap, [Application.get_all_env(:codex_pooler), config], @peer_call_budget_ms)

    # The injected overruns are expected; the peer's logs are not the result.
    :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :none], @peer_call_budget_ms)
    identity = :peer.call(peer, InstancePresence, :local_identity, [], @peer_call_budget_ms)

    UnboxedFixture.register_unboxed_cleanup!(
      fn ->
        InstancePresencePeer.purge_peer_state!(
          identity.boot_id,
          fn -> Repo.delete_all(from instance in InstancePresence.Instance, where: instance.instance_id == ^identity.instance_id) end,
          budget_ms: @peer_call_budget_ms
        )
      end,
      InstancePresencePeer.cleanup_timeout_ms(@peer_call_budget_ms)
    )

    # Registered last so it runs first: the peer's pool would reconnect the
    # backends the purge ends.
    on_exit(fn ->
      # The test process's exit already stops the linked peer, racing this
      # stop; the OS-level assertion below is what proves the peer ended.
      try do
        :peer.stop(peer)
      catch
        :exit, _already_stopped -> :ok
      end

      InstancePresencePeer.assert_os_process_stopped!(os_identity, budget_ms: @peer_call_budget_ms)
    end)

    {peer, identity}
  end
end
