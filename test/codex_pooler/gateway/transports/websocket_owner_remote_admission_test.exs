defmodule CodexPooler.Gateway.Transports.WebsocketOwnerRemoteAdmissionTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.AccountingTestSupport
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, WebsocketOwnerSession}
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.PeerRegistry
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout_ms 15_000

  setup_all do
    start_distribution!()
    name = String.to_atom("pending_owner_#{System.unique_integer([:positive])}")

    {:ok, peer, remote_node} =
      :peer.start_link(%{
        name: name,
        args: [~c"+S", ~c"2:2", ~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
      })

    Process.unlink(peer)
    on_exit(fn -> :peer.stop(peer) end)
    :ok = :erpc.call(remote_node, :code, :add_paths, [:code.get_path()])
    {:ok, runtime} = :erpc.call(remote_node, WebsocketOwnerNodeHarness, :start_owner_runtime, [])
    assert node(runtime) == remote_node
    refute remote_node == node()

    repo_config = Repo.config() |> Keyword.put(:pool, DBConnection.ConnectionPool)
    repo = :erpc.call(remote_node, WebsocketOwnerNodeHarness, :start_repo, [repo_config])
    assert node(repo) == remote_node
    {:ok, _apps} = :erpc.call(remote_node, Application, :ensure_all_started, [:phoenix_pubsub])

    {:ok, pubsub} =
      :erpc.call(remote_node, Supervisor, :start_child, [
        Logger.Supervisor,
        {Phoenix.PubSub, name: CodexPooler.PubSub}
      ])

    assert node(pubsub) == remote_node
    %{remote_node: remote_node}
  end

  setup %{remote_node: remote_node} do
    {fixture, session} =
      Sandbox.unboxed_run(Repo, fn ->
        fixture = AccountingTestSupport.accounting_setup()

        {:ok, session} =
          Websocket.start_codex_session(fixture.auth, %{
            accepted_turn_state: Ecto.UUID.generate(),
            owner_instance_id: Atom.to_string(remote_node),
            bridge_owner_lease_ttl_seconds: 300
          })

        {fixture, Repo.reload!(session)}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(fixture.pool)
        Repo.delete!(fixture.identity)
        Repo.delete!(fixture.pricing)
        refute Repo.get(CodexSession, session.id)
        refute Repo.get(fixture.identity.__struct__, fixture.identity.id)
        refute Repo.get(fixture.pricing.__struct__, fixture.pricing.id)
      end)
    end)

    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    {:ok, registry_pid} = ActivityRegistry.start_link(name: registry)
    Process.unlink(registry_pid)
    on_exit(fn -> GenServer.stop(registry_pid) end)

    upstream =
      :erpc.call(remote_node, WebsocketOwnerNodeHarness, :fake_upstream_boundary, [self()])

    {:ok, owner} =
      :erpc.call(remote_node, WebsocketOwnerSession, :start_owner, [
        [
          codex_session_id: session.id,
          owner_lease_token: session.owner_lease_token,
          owner_instance_id: session.owner_instance_id,
          owner_renewal_ms: 60_000,
          upstream: upstream
        ]
      ])

    assert node(owner) == remote_node

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid},
                   @detection_timeout_ms

    assert node(upstream_pid) == remote_node

    on_exit(fn ->
      :ok =
        :erpc.call(remote_node, WebsocketOwnerNodeHarness, :stop_owner, [
          session.id,
          @detection_timeout_ms
        ])
    end)

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: self(),
        epoch: 1,
        correlation_id: Ecto.UUID.generate()
      })

    {:ok, log_io} = StringIO.open("")
    Process.unlink(log_io)
    handler = String.to_atom("pending_owner_log_#{System.unique_integer([:positive])}")

    :ok =
      :erpc.call(remote_node, :logger, :add_handler, [
        handler,
        :logger_std_h,
        %{level: :warning, config: %{type: {:device, log_io}}}
      ])

    on_exit(fn ->
      :erpc.call(remote_node, :logger, :remove_handler, [handler])
      if Process.alive?(log_io), do: StringIO.close(log_io)
    end)

    %{
      fixture: fixture,
      session: session,
      owner: owner,
      registry: registry,
      downstream: downstream,
      log_io: log_io
    }
  end

  test "remote drain cancels proxy admission and finalizes a committed reservation before releasing its lease",
       context do
    {task, cleanup} = start_admission(context)
    assert cleanup.registry == {context.registry, node(task)}
    refute node(task) == node(context.owner)
    assert_receive {:began, :ok}, @detection_timeout_ms
    send(task, :claim_and_reserve)
    assert_receive {:reserved, request_id, turn_id}, @detection_timeout_ms

    pending = :sys.get_state(context.owner).pending_admissions
    assert Map.has_key?(pending, task)
    assert map_size(pending) == 1
    assert_pending_rows(context, request_id, turn_id)
    {blocker, backend_id} = lock_session(context.session.id)
    on_exit(fn -> send(blocker.pid, :release) end)
    task_monitor = Process.monitor(task)
    owner_monitor = Process.monitor(context.owner)
    drain = Task.async(fn -> WebsocketOwnerSession.drain_owner(context.owner) end)

    assert_receive {:DOWN, ^task_monitor, :process, ^task, {:shutdown, :owner_drained}},
                   @detection_timeout_ms

    await_database_blocker(
      backend_id,
      System.monotonic_time(:millisecond) + @detection_timeout_ms
    )

    assert Task.yield(drain, 0) == nil
    assert_pending_rows(context, request_id, turn_id)
    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker, @detection_timeout_ms)
    assert :ok = Task.await(drain, @detection_timeout_ms)
    owner = context.owner
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, @detection_timeout_ms

    Sandbox.unboxed_run(Repo, fn ->
      request = Repo.get!(Request, request_id)
      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "owner_drained"
      assert request.request_metadata["websocket_pre_attempt_drain"] == true
      assert Repo.get!(CodexTurn, turn_id).status == "interrupted"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request_id), :count) == 0
      assert Repo.get!(RequestLogFact, request_id)
      assert lease_status(context.session.id) == "released"

      entries = Repo.all(from(e in LedgerEntry, where: e.request_id == ^request_id))
      assert Enum.sort(Enum.map(entries, & &1.entry_kind)) == ["release", "reservation"]
    end)

    _receipt = ActivityRegistry.await_direct_cleanup(cleanup)
    assert :sys.get_state(context.registry).finished_direct == %{}
    assert ActivityRegistry.activities(name: context.registry) == []
    assert_remote_log_clean(context)
  end

  test "stale owner binding rejects a real remote registration with no persistent mutations",
       context do
    stale = %{context.session | owner_lease_token: Ecto.UUID.generate()}
    {task, _cleanup} = start_admission(%{context | session: stale})
    assert_receive {:began, {:error, :stale_owner}}, @detection_timeout_ms
    assert :sys.get_state(context.owner).pending_admissions == %{}

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(r in Request, where: r.pool_id == ^context.fixture.pool.id),
               :count
             ) == 0

      assert Repo.aggregate(
               from(t in CodexTurn, where: t.codex_session_id == ^context.session.id),
               :count
             ) == 0

      assert Repo.reload!(context.session) == context.session
      assert lease_status(context.session.id) == "active"
    end)

    monitor = Process.monitor(task)
    send(task, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, @detection_timeout_ms
    assert :ok = WebsocketOwnerSession.drain_owner(context.owner)
    assert_remote_log_clean(context)
  end

  defp start_admission(context) do
    parent = self()
    ref = make_ref()

    task =
      spawn(fn ->
        cleanup = %DirectCleanup{
          registry: {context.registry, node()},
          task: self(),
          ref: ref,
          parent: parent,
          session_id: context.session.id,
          owner_pid: context.owner,
          owner_binding: %{
            owner_instance_id: context.session.owner_instance_id,
            owner_lease_token: context.session.owner_lease_token,
            downstream_epoch: context.downstream.epoch
          }
        }

        {:ok, token} =
          ActivityRegistry.register(:direct, self(),
            name: context.registry,
            direct_cleanup_ref: ref,
            direct_cleanup_parent: parent
          )

        :ok = ActivityRegistry.admit(token, name: context.registry)

        options =
          Websocket.websocket_owner_response_options(
            %{
              websocket_owner_forwarder_opts: [
                app_node_names: [context.session.owner_instance_id]
              ]
            },
            context.session,
            context.session.owner_lease_token,
            context.downstream
          )
          |> RequestOptions.put_runtime_context(direct_cleanup: cleanup)

        send(parent, {:cleanup, cleanup})
        send(parent, {:began, DirectCleanup.begin(options)})

        receive do
          :claim_and_reserve ->
            reserve(context, cleanup, parent)

            receive do
              :stop -> :ok
            end

          :stop ->
            :ok
        end
      end)

    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert_receive {:cleanup, cleanup}, @detection_timeout_ms
    {task, cleanup}
  end

  defp reserve(context, cleanup, parent) do
    Sandbox.unboxed_run(Repo, fn ->
      opts = %{
        correlation_id: Ecto.UUID.generate(),
        transport: "websocket",
        requested_model: context.fixture.model.exposed_model_id,
        endpoint: "/backend-api/codex/responses",
        direct_cleanup_bind: &DirectCleanup.bind(cleanup, &1),
        request_metadata: %{
          "websocket_owner_forwarding" => %{
            "owner_instance_id" => context.session.owner_instance_id,
            "proxy_instance_id" => Atom.to_string(node()),
            "downstream_epoch" => context.downstream.epoch,
            "enabled" => true
          }
        }
      }

      {:ok, claim} =
        Accounting.claim_websocket_turn(context.fixture.auth, context.fixture.model, opts)

      {:ok, reservation} =
        Accounting.reserve(
          context.fixture.auth,
          context.fixture.model,
          %{},
          Map.put(opts, :turn_claim, claim.request)
        )

      {:ok, turn} = Websocket.start_codex_turn(context.session, reservation.request)
      send(parent, {:reserved, reservation.request.id, turn.id})
    end)
  end

  defp assert_pending_rows(context, request_id, turn_id) do
    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(Request, request_id).status == "in_progress"
      assert Repo.get!(CodexTurn, turn_id).status == "in_progress"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request_id), :count) == 0
      assert lease_status(context.session.id) == "active"

      assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^request_id), :count) ==
               1
    end)
  end

  defp lease_status(session_id) do
    Repo.one!(
      from(l in BridgeOwnerLease, where: l.codex_session_id == ^session_id, select: l.status)
    )
  end

  defp lock_session(session_id) do
    parent = self()

    blocker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          hold_session_lock(session_id, parent)
        end)
      end)

    assert_receive {:locked, backend_id}, @detection_timeout_ms
    {blocker, backend_id}
  end

  defp hold_session_lock(session_id, parent) do
    Repo.transaction(fn ->
      Repo.one!(from(s in CodexSession, where: s.id == ^session_id, lock: "FOR UPDATE"))
      %{rows: [[backend_id]]} = Repo.query!("SELECT pg_backend_pid()")
      send(parent, {:locked, backend_id})
      await_lock_release()
    end)
  end

  defp await_lock_release do
    receive do
      :release -> :ok
    after
      @detection_timeout_ms -> raise "session lock was not released"
    end
  end

  defp await_database_blocker(backend_id, deadline) do
    blocked =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[blocked]]} =
          Repo.query!(
            "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND $1::integer = ANY(pg_blocking_pids(pid)))",
            [backend_id]
          )

        blocked
      end)

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("remote finalization did not wait for the committed session lock")

      true ->
        receive do
        after
          10 -> await_database_blocker(backend_id, deadline)
        end
    end
  end

  defp assert_remote_log_clean(context) do
    :ok = :erpc.call(context.remote_node, Logger, :flush, [])
    {_input, output} = StringIO.contents(context.log_io)
    assert output == "", "remote owner emitted an unexpected warning during admission or drain"
  end

  defp start_distribution! do
    if node() == :nonode@nohost do
      {_output, 0} = System.cmd("epmd", ["-daemon"])
      PeerRegistry.assert_epmd_ready!()
      previous = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
      Application.put_env(:kernel, :prevent_overlapping_partitions, false)
      name = String.to_atom("pending_proxy_#{System.unique_integer([:positive])}")
      {:ok, _pid} = :net_kernel.start([name, :shortnames])

      on_exit(fn ->
        :ok = :net_kernel.stop()

        restore_partition_guard(previous)
      end)
    end
  end

  defp restore_partition_guard({:ok, value}),
    do: Application.put_env(:kernel, :prevent_overlapping_partitions, value)

  defp restore_partition_guard(:error),
    do: Application.delete_env(:kernel, :prevent_overlapping_partitions)
end
