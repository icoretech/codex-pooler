defmodule CodexPooler.Platform.SupersededIncarnationRecoveryTest do
  use CodexPooler.DataCase, async: false

  # findings#207 row 207-17: the production cleanup role shares only PostgreSQL
  # with the app pods. An app VM that dies without publishing terminal proofs
  # (a hard kill) and restarts in place under the same node name must have its
  # stranded execution settled by a cleanup VM that is connected to neither
  # incarnation, through the successor's presence row alone.

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.InstancePresencePeer
  alias CodexPooler.Platform.{ExecutionIdentity, InstancePresence}
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture

  # Also the budget of every call into a peer: `:peer.call/4` defaults to
  # 5 s, which a peer's bootstrap outgrew on a loaded host (findings#206 row
  # 206-184).
  @peer_timeout_ms 15_000
  # Every unboxed cleanup gets a task timeout above the detection budgets it
  # may wait on (an OS-process wait plus a connection wait, each bounded by
  # @peer_timeout_ms), so a slow peer is reported by its own assertion instead
  # of `Task.await` timing out first. The relation lives in the helper, which
  # owns it for every caller.
  @cleanup_timeout_ms InstancePresencePeer.cleanup_timeout_ms(@peer_timeout_ms)

  @tag slow: "boots two BEAM incarnations and verifies OS identity and database-only recovery"
  test "a hard-killed named owner is recovered once its in-place successor publishes presence" do
    %{user: owner} = CodexPooler.AccountsFixtures.committed_bootstrap_owner_fixture!()
    slug = "superseded-incarnation-#{Ecto.UUID.generate()}"

    UnboxedFixture.register_unboxed_cleanup!(
      fn ->
        ids = Repo.all(from p in CodexPooler.Pools.Pool, where: p.slug == ^slug, select: p.id)
        CodexPooler.PoolerFixtures.delete_committed_pools!(ids)

        Repo.delete_all(
          from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
            where: identity.account_label == ^slug
        )
      end,
      @cleanup_timeout_ms
    )

    setup =
      UnboxedFixture.run_unboxed(fn ->
        pool =
          CodexPooler.PoolerFixtures.pool_fixture(%{slug: slug, created_by_user_id: owner.id})

        %{api_key: key} =
          CodexPooler.PoolerFixtures.active_api_key_fixture(pool, %{created_by_user_id: owner.id})

        model = CodexPooler.PoolerFixtures.model_fixture(pool)

        %{assignment: assignment} =
          CodexPooler.PoolerFixtures.upstream_assignment_fixture(pool, %{account_label: slug})

        %{pool: pool, auth: %{pool: pool, api_key: key}, model: model, assignment: assignment}
      end)

    # Both incarnations carry the same node name (an in-place restart keeps
    # the pod's address and hostname); neither is connected to this VM.
    name = :"superseded_#{System.unique_integer([:positive])}"
    {_, 0} = System.cmd("epmd", ["-daemon"])
    CodexPooler.PeerRegistry.assert_epmd_ready!()

    {first_peer, first_os_identity, first_identity} = start_named_peer!(name, setup)
    refute first_identity.node_name == "nonode@nohost"
    assert [] == :peer.call(first_peer, Node, :list, [], @peer_timeout_ms)

    UnboxedFixture.register_unboxed_cleanup!(
      fn ->
        # `purge_peer_state!/3` owns the order: the hard-killed peer's proof
        # publisher may still hold a backend mid-statement on these very rows,
        # so its backends are ended before the deletion rather than by whatever
        # LIFO position this callback happens to hold.
        InstancePresencePeer.purge_peer_state!(
          first_identity.boot_id,
          fn ->
            Repo.delete_all(
              from instance in InstancePresence.Instance,
                where: instance.node_name == ^first_identity.node_name
            )

            Repo.delete_all(
              from proof in CodexPooler.Platform.ExecutionTerminalProof,
                where: proof.owner_instance_id == ^first_identity.node_name
            )
          end,
          budget_ms: @peer_timeout_ms
        )
      end,
      @cleanup_timeout_ms
    )

    {request, attempt, _worker} =
      :peer.call(first_peer, CodexPooler.DisconnectedExecutionPeer, :start, [setup], @peer_timeout_ms)

    assert attempt.owner_instance_id == first_identity.node_name
    assert attempt.owner_instance_boot_id == first_identity.boot_id
    assert is_binary(attempt.owner_execution_id)

    # The first VM is killed hard: no drain, no terminal proof, its heartbeat
    # simply stops. Age the row and the attempt past the liveness window the
    # way ten silent minutes would; its stale row alone must not settle the
    # execution.
    kill_peer!(first_peer, first_os_identity, name)
    assert ExecutionIdentity.status(attempt) == :unknown
    refute InstancePresence.superseded?(first_identity)
    now = DateTime.utc_now()
    stale = DateTime.add(now, -10, :minute)

    UnboxedFixture.run_unboxed(fn ->
      {:ok, _} = InstancePresence.record_heartbeat(first_identity, stale)

      {1, _} =
        Repo.update_all(from(a in Attempt, where: a.id == ^attempt.id), set: [started_at: stale])
    end)

    refresh_local_observer!()

    assert {:ok, %{absent_instance_attempts_recovered: 0}} =
             UnboxedFixture.run_unboxed(fn ->
               Accounting.recover_absent_instance_attempts(now)
             end)

    assert UnboxedFixture.run_unboxed(fn -> Repo.reload!(attempt).status end) == "in_progress"

    # The container restarts in place under the same name with a new boot id.
    {second_peer, second_os_identity, second_identity} = start_named_peer!(name, setup)
    assert second_identity.node_name == first_identity.node_name
    refute second_identity.boot_id == first_identity.boot_id
    assert [] == :peer.call(second_peer, Node, :list, [], @peer_timeout_ms)
    assert InstancePresence.superseded?(first_identity)

    assert {:ok, %{absent_instance_attempts_recovered: 1}} =
             UnboxedFixture.run_unboxed(fn ->
               Accounting.recover_absent_instance_attempts(now)
             end)

    assert %Request{status: "failed", last_error_code: "absent_instance_recovered"} =
             UnboxedFixture.run_unboxed(fn -> Repo.get!(Request, request.id) end)

    assert %Attempt{status: "failed", network_error_code: "absent_instance_recovered"} =
             UnboxedFixture.run_unboxed(fn -> Repo.reload!(attempt) end)

    assert UnboxedFixture.run_unboxed(fn ->
             Accounting.list_ledger_entries_for_request(request.id)
             |> Enum.map(& &1.entry_kind)
             |> Enum.sort()
           end) == ["release", "reservation", "settlement"]

    # The successor's own live execution is untouched by the same pass.
    {successor_request, successor_attempt, successor_worker} =
      :peer.call(second_peer, CodexPooler.DisconnectedExecutionPeer, :start, [setup], @peer_timeout_ms)

    assert {:ok, %{absent_instance_attempts_recovered: 0}} =
             UnboxedFixture.run_unboxed(fn ->
               Accounting.recover_absent_instance_attempts(now)
             end)

    assert UnboxedFixture.run_unboxed(fn -> Repo.reload!(successor_attempt).status end) ==
             "in_progress"

    :ok =
      :peer.call(second_peer, CodexPooler.DisconnectedExecutionPeer, :finish, [successor_worker, successor_attempt], @peer_timeout_ms)

    assert UnboxedFixture.run_unboxed(fn -> Repo.get!(Request, successor_request.id).status end) in [
             "in_progress",
             "queued"
           ]

    kill_peer!(second_peer, second_os_identity, name)
  end

  defp start_named_peer!(name, _setup) do
    parent = self()

    peer_owner =
      start_supervised!(
        {Task,
         fn ->
           {:ok, peer, _node} =
             :peer.start_link(%{
               name: name,
               connection: :standard_io,
               args: [~c"+S", ~c"2:2"]
             })

           send(parent, {:peer, self(), peer})

           receive do
             :stop -> :ok
           end
         end},
        id: make_ref()
      )

    assert_receive {:peer, ^peer_owner, peer}, @peer_timeout_ms
    os_pid = :peer.call(peer, :os, :getpid, [], @peer_timeout_ms) |> List.to_string()
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()], @peer_timeout_ms)

    :ok =
      :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :bootstrap, [Application.get_all_env(:codex_pooler), Repo.config()], @peer_timeout_ms)

    # The peer is identified by PID plus kernel start signature so a reused
    # PID never reads as the peer, and so a hard-killed peer that lingers as a
    # zombie until its port is reaped counts as stopped rather than surviving.
    os_identity = InstancePresencePeer.capture_os_process_identity!(os_pid)

    identity = :peer.call(peer, CodexPooler.Platform.InstancePresence.Identity, :local, [], @peer_timeout_ms)
    # Through the production heartbeat, which retries a beat its one-second
    # write budget cut; one direct beat failed on a loaded host (row 206-473).
    _failed_beats = InstancePresencePeer.publish_presence!(peer, @peer_timeout_ms)

    UnboxedFixture.register_unboxed_cleanup!(
      fn ->
        # A backend the dead peer left mid-statement still holds its row
        # locks; end it first so the row cleanup registered earlier (which
        # runs after this one) can never block on the peer's leftovers.
        InstancePresencePeer.purge_peer_state!(
          identity.boot_id,
          fn ->
            InstancePresencePeer.assert_os_process_stopped!(os_identity,
              budget_ms: @peer_timeout_ms
            )
          end,
          budget_ms: @peer_timeout_ms
        )
      end,
      @cleanup_timeout_ms
    )

    {peer, os_identity, identity}
  end

  # SIGKILL the peer VM: nothing inside it runs, so no proof and no drain. The
  # controlling process notices the lost stdio connection and stops on its
  # own, and the name must have left epmd before a successor can reuse it.
  defp kill_peer!(peer, os_identity, name) do
    {_, 0} = System.cmd("kill", ["-9", os_identity.pid])
    InstancePresencePeer.assert_os_process_stopped!(os_identity, budget_ms: @peer_timeout_ms)
    await_controller_down!(peer, System.monotonic_time(:millisecond) + @peer_timeout_ms)
    CodexPooler.PeerRegistry.assert_peer_absent!(name, budget_ms: @peer_timeout_ms)
    :ok
  end

  defp await_controller_down!(peer, deadline) do
    if Process.alive?(peer) do
      assert System.monotonic_time(:millisecond) < deadline, "peer controller survived the kill"
      Process.sleep(10)
      await_controller_down!(peer, deadline)
    else
      :ok
    end
  end

  defp refresh_local_observer! do
    local = InstancePresence.local_identity()

    existed? =
      UnboxedFixture.run_unboxed(fn ->
        Repo.exists?(
          from instance in InstancePresence.Instance,
            where: instance.instance_id == ^local.instance_id
        )
      end)

    unless existed? do
      UnboxedFixture.register_unboxed_cleanup!(
        fn ->
          Repo.delete_all(
            from instance in InstancePresence.Instance,
              where: instance.instance_id == ^local.instance_id
          )
        end,
        @cleanup_timeout_ms
      )
    end

    {:ok, _} = UnboxedFixture.run_unboxed(fn -> InstancePresence.record_heartbeat(local) end)
    :ok
  end
end
