defmodule CodexPooler.Alerts.PendingDeliveryRecoveryPeerTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard
  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import CodexPooler.AccountsFixtures
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.AlertDeliveryRecoveryPeer
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, PendingRecovery}
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertDeliveryAttempt}
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.InstancePresencePeer
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.PeerRegistry
  alias CodexPooler.Repo
  alias CodexPooler.TestDiagnostics
  alias CodexPooler.UnboxedFixture
  alias Ecto.Adapters.SQL.Sandbox

  @budget 15_000
  @moduletag capture_log: true

  defmodule Hold do
    def init(options), do: options

    def call(conn, parent) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:held_http, self()})

      receive do
        :finish -> Plug.Conn.send_resp(conn, 200, "")
      after
        20_000 -> Plug.Conn.send_resp(conn, 200, "")
      end
    end
  end

  setup_all do
    peer = InstancePresencePeer.start_presence_peer!(PeerRegistry.unique_node_name("alert_recovery"))

    on_exit(fn ->
      try do
        :peer.stop(peer.peer)
      catch
        :exit, _ -> :ok
      end

      PeerRegistry.assert_peer_absent!(peer.name, peer_node: peer.remote)
    end)

    {:ok, _} = :erpc.call(peer.remote, Application, :ensure_all_started, [:postgrex])
    :erpc.call(peer.remote, WebsocketOwnerNodeHarness, :start_repo, [Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 3, log: false)])
    %{peer: peer.remote}
  end

  @tag slow: "real second-BEAM recovery and owned Producer startup"
  test "surviving real Producer acknowledges killed worker and second-node duplicate recovery cannot overwrite the winner", %{peer: peer} do
    tls = CodexPooler.WebhookDestinationFixture.setup!()
    suffix = System.unique_integer([:positive])
    fixture = fixture!(suffix)
    oban_name = String.to_atom("recovery_oban_#{suffix}")
    repo_name = String.to_atom("recovery_repo_#{suffix}")
    server = start_supervised!({Bandit, plug: {Hold, self()}, ip: tls.ip, port: 0, scheme: :https, startup_log: false, thousand_island_options: [transport_options: [cert: tls.cert[:cert], key: tls.cert[:key]]]})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, encrypted} = AppSecretCrypto.encrypt("https://#{tls.host}:#{port}/hooks", "alert_webhook_endpoint_url")

    database(fn ->
      fixture.channel |> Ecto.Changeset.change(endpoint_url_ciphertext: encrypted.ciphertext, endpoint_url_nonce: encrypted.nonce, endpoint_url_aad: encrypted.aad, endpoint_url_key_version: encrypted.key_version) |> Repo.update!()
    end)

    repo = start_supervised!(Supervisor.child_spec({Repo, Keyword.merge(Repo.config(), name: repo_name, pool: DBConnection.ConnectionPool, pool_size: 3)}, id: repo_name))
    telemetry = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(telemetry) end)
    :ok = :telemetry.attach_many(telemetry, [[:oban, :job, :start], [:oban, :job, :exception]], &AlertDeliveryRecoveryPeer.observe/4, %{name: oban_name, repo: repo, parent: self()})
    oban = start_supervised!(Supervisor.child_spec({Oban, name: oban_name, repo: Repo, get_dynamic_repo: fn -> repo end, testing: :disabled, queues: [{String.to_atom(fixture.queue), 1}], plugins: [], notifier: Oban.Notifiers.PG, peer: false, log: false}, id: oban_name))
    assert_receive {:executor_started, pid, before_links}, @budget
    assert_receive {:held_http, handler}, @budget
    {:links, after_links} = Process.info(pid, :links)
    [network_child] = Enum.filter(after_links -- before_links, &is_pid/1)
    child_monitor = Process.monitor(network_child)
    [pending] = database(fn -> Repo.all(from a in AlertDeliveryAttempt, where: a.incident_id == ^fixture.incident.id) end)
    assert pending.status == "pending"
    binding = pending.response_metadata["delivery_execution"]
    assert binding["job_id"] == fixture.job.id
    assert {:ok, :unchanged} = :erpc.call(peer, PendingRecovery, :recover_one, [pending, DateTime.utc_now()])
    refute node() == peer
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @budget
    assert_receive {:DOWN, ^child_monitor, :process, ^network_child, _}, @budget
    assert_receive :executor_acknowledged, @budget
    assert database(fn -> Repo.get!(Oban.Job, fixture.job.id).state end) == "retryable"
    send(handler, :finish)
    tasks = start_supervised!(Task.Supervisor)
    first = Task.Supervisor.async_nolink(tasks, fn -> :erpc.call(peer, PendingRecovery, :recover_one, [pending, DateTime.utc_now()]) end)
    second = Task.Supervisor.async_nolink(tasks, fn -> database(fn -> PendingRecovery.recover_one(pending, DateTime.utc_now()) end) end)
    results = [Task.await(first, @budget), Task.await(second, @budget)]
    assert Enum.count(results, &match?({:ok, :unchanged}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %AlertDeliveryAttempt{status: "retryable"}}, &1)) == 1
    winner = database(fn -> Repo.get!(AlertDeliveryAttempt, pending.id) end)
    assert {:error, %{code: "alert_delivery_execution_superseded"}} = database(fn -> AttemptLifecycle.mark_sent_attempt(pending, DateTime.utc_now(), %{}) end)
    assert database(fn -> Repo.get!(AlertDeliveryAttempt, pending.id) end) == winner
    assert {:ok, :unchanged} = :erpc.call(peer, PendingRecovery, :recover_one, [pending, DateTime.utc_now()])
    assert Process.alive?(oban)
    assert :ok = stop_supervised(oban_name)
    assert :ok = stop_supervised(repo_name)
    TestDiagnostics.puts("alert-recovery producer_survived=true worker_killed=true remote_recovery=true duplicate_winners=1 delayed_writer_refused=true")
  end

  @tag slow: "real owner VM termination and independent Lifeline/recovery actors"
  test "node loss stays unresolved until stock Lifeline revokes executing authority", %{peer: recovery_peer} do
    tls = CodexPooler.WebhookDestinationFixture.setup!()
    suffix = System.unique_integer([:positive])
    fixture = fixture!(suffix)
    owner = InstancePresencePeer.start_presence_peer!(PeerRegistry.unique_node_name("alert_owner"))

    on_exit(fn ->
      try do
        :peer.stop(owner.peer)
      catch
        :exit, _ -> :ok
      end

      PeerRegistry.assert_peer_absent!(owner.name, peer_node: owner.remote)
    end)

    {:ok, _} = :erpc.call(owner.remote, Application, :ensure_all_started, [:postgrex])
    :erpc.call(owner.remote, WebsocketOwnerNodeHarness, :start_repo, [Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 3, log: false)])
    # The peer loads compiled support callbacks; recompiling this ExUnit file
    # would initialize the test framework and both scenarios inside the owner.
    server = start_supervised!({Bandit, plug: {Hold, self()}, ip: tls.ip, port: 0, scheme: :https, startup_log: false, thousand_island_options: [transport_options: [cert: tls.cert[:cert], key: tls.cert[:key]]]})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, encrypted} = AppSecretCrypto.encrypt("https://#{tls.host}:#{port}/hooks", "alert_webhook_endpoint_url")
    database(fn -> fixture.channel |> Ecto.Changeset.change(endpoint_url_ciphertext: encrypted.ciphertext, endpoint_url_nonce: encrypted.nonce, endpoint_url_aad: encrypted.aad, endpoint_url_key_version: encrypted.key_version) |> Repo.update!() end)
    :ok = :erpc.call(owner.remote, :persistent_term, :put, [:pubkey_os_cacerts, :persistent_term.get(:pubkey_os_cacerts)])
    :ok = :erpc.call(owner.remote, AlertDeliveryRecoveryPeer, :start_owner_worker, [fixture.queue, self()])
    assert_receive {:executor_started, worker, _links}, @budget
    assert node(worker) == owner.remote
    assert_receive {:held_http, handler}, @budget
    [pending] = database(fn -> Repo.all(from a in AlertDeliveryAttempt, where: a.incident_id == ^fixture.incident.id) end)
    assert {:ok, :unchanged} = :erpc.call(recovery_peer, PendingRecovery, :recover_one, [pending, DateTime.utc_now()])
    :peer.stop(owner.peer)
    PeerRegistry.assert_peer_absent!(owner.name, peer_node: owner.remote)
    send(handler, :finish)
    assert database(fn -> Repo.get!(Oban.Job, fixture.job.id).state end) == "executing"
    assert {:ok, :unchanged} = :erpc.call(recovery_peer, PendingRecovery, :recover_one, [pending, DateTime.utc_now()])

    # Exercise the installed Lifeline, with a deliberately short isolated
    # rescue threshold; this is not a physical one-hour production wait.
    name = String.to_atom("recovery_lifeline_#{suffix}")
    repo_name = String.to_atom("lifeline_repo_#{suffix}")
    repo = start_supervised!(Supervisor.child_spec({Repo, Keyword.merge(Repo.config(), name: repo_name, pool: DBConnection.ConnectionPool, pool_size: 2)}, id: repo_name))
    start_supervised!(Supervisor.child_spec({Oban, name: name, repo: Repo, get_dynamic_repo: fn -> repo end, testing: :disabled, queues: [], plugins: [], notifier: Oban.Notifiers.PG, peer: {Oban.Peers.Isolated, leader?: true}, log: false}, id: name))
    conf = Oban.config(name)
    lifeline = start_supervised!({Oban.Lifeline, conf: conf, interval: 60_000, rescue_after: 1})
    assert Oban.Peer.leader?(name)
    send(lifeline, :rescue)
    :sys.get_state(lifeline)
    assert database(fn -> Repo.get!(Oban.Job, fixture.job.id).state end) == "available"
    assert {:ok, recovered} = :erpc.call(recovery_peer, PendingRecovery, :recover_one, [pending, DateTime.utc_now()])
    assert recovered.status == "retryable"
    assert recovered.response_metadata["delivery_outcome"] == "unknown"
    assert {:ok, :unchanged} = :erpc.call(recovery_peer, PendingRecovery, :recover_one, [pending, DateTime.utc_now()])
    TestDiagnostics.puts("alert-recovery owner_node_stopped=true prior_executing_preserved=true stock_lifeline_rescue=true isolated_rescue_after_ms=1 remote_recovery=true")
  end

  defp fixture!(suffix) do
    queue = "pending_recovery_#{suffix}"
    %{user: owner} = committed_bootstrap_owner_fixture!()
    slug = "pending-recovery-#{suffix}"

    UnboxedFixture.register_unboxed_cleanup!(fn ->
      Repo.delete_all(from j in Oban.Job, where: j.queue == ^queue)
      if pool = Repo.get_by(CodexPooler.Pools.Pool, slug: slug), do: delete_committed_pools!([pool.id])
      Repo.delete_all(from c in AlertChannel, where: c.display_name == ^slug)
    end)

    database(fn ->
      pool = pool_fixture(%{slug: slug})
      {:ok, projection} = Alerts.create_channel(Scope.for_user(owner, ["instance_owner"]), %{channel_type: "webhook", display_name: slug, endpoint_url: "https://example.com/hooks", webhook_signing_secret: "synthetic-recovery-secret"})
      channel = Repo.get!(AlertChannel, projection.id)
      incident = alert_incident_fixture(pool: pool)
      rule = alert_rule_fixture(pool)
      alert_incident_target_fixture(incident, rule, pool)
      job = %{"alert_incident_id" => incident.id, "alert_channel_id" => channel.id} |> AlertDeliveryWorker.new(queue: queue) |> Repo.insert!()
      %{queue: queue, channel: channel, incident: incident, job: job}
    end)
  end

  defp database(fun), do: Sandbox.unboxed_run(Repo, fn -> Repo.checkout(fun) end)
end
