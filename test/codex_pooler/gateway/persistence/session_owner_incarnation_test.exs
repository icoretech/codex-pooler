defmodule CodexPooler.Gateway.Persistence.SessionOwnerIncarnationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    RuntimeCleanup
  }

  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness
  alias CodexPooler.Gateway.Routing.SessionContinuity, as: RoutingContinuity
  alias CodexPooler.Gateway.Runtime.SessionLeaseHeartbeat
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Platform.{InstanceHeartbeat, InstancePresence}
  alias CodexPooler.Platform.InstancePresence.Identity
  alias CodexPooler.Repo

  setup do
    boot_id = Identity.boot_id()
    on_exit(fn -> :persistent_term.put({Identity, :boot_id}, boot_id) end)
    :ok
  end

  test "local heartbeat starvation preserves acquire and renewal of the exact owner lease" do
    setup = accounting_setup()
    local = start_instance!(:session_owner_stale_local)
    key = turn_state()
    {:ok, session} = start_session(setup, key)
    lease = active_lease!(session.id)
    dispatched_at = DateTime.add(now(), -180, :second)
    %{request: request, attempt: attempt} = dispatch_open_attempt!(setup, dispatched_at)
    _turn = turn_row(session, request, attempt, dispatched_at)
    {:ok, _} = InstancePresence.record_heartbeat(local, DateTime.add(now(), -180, :second))

    assert RuntimeCleanup.active_runtime_request?(request, now(), [])

    assert {:ok, renewed} =
             SessionContinuity.renew_owner_token(
               session,
               session.owner_lease_token,
               RequestOptions.for_websocket(%{})
             )

    assert renewed.owner_lease_token == lease.lease_token
    assert {:ok, reattached} = start_session(setup, key)
    assert reattached.owner_lease_token == lease.lease_token
    assert Repo.reload!(lease).status == "active"
  end

  describe "session ownership names a VM" do
    test "a successor under the same node name cannot renew its predecessor's lease" do
      setup = accounting_setup()
      first = start_instance!(:session_owner_restart_first)
      turn_state = turn_state()

      {:ok, session} = start_session(setup, turn_state)
      lease = active_lease!(session.id)

      # Ownership came from the running VM, not from this test.
      assert session.owner_instance_id == first.node_name
      assert session.owner_instance_boot_id == first.boot_id
      assert lease.owner_instance_id == first.node_name
      assert lease.owner_instance_boot_id == first.boot_id

      end_instance!(:session_owner_restart_first)

      # Kubernetes restarts the container in place: same pod, same address, so
      # the same node name, with a new VM behind it.
      second = start_instance!(:session_owner_restart_second)
      assert second.node_name == first.node_name
      refute second.boot_id == first.boot_id

      # The client reconnects and lands on the successor, which is the request
      # that renewed a destroyed VM's lease in production.
      {:ok, reattached} = start_session(setup, turn_state)

      renewed_lease = Repo.get!(BridgeOwnerLease, lease.id)

      # The lease was not renewed: it still expires when its own VM's lease was
      # going to expire, so it can run out and be recovered.
      assert renewed_lease.expires_at == lease.expires_at
      assert renewed_lease.renewed_at == lease.renewed_at
      assert renewed_lease.owner_instance_boot_id == first.boot_id

      # And the successor did not take the session as its own.
      assert reattached.owner_instance_id == first.node_name
      assert reattached.owner_instance_boot_id == first.boot_id
      assert Repo.get!(CodexSession, session.id).owner_instance_boot_id == first.boot_id
    end

    test "the successor can still take a session over, which is how one genuinely moves" do
      setup = accounting_setup()
      _first = start_instance!(:session_owner_takeover_first)

      {:ok, session} = start_session(setup, turn_state())
      stale_lease = active_lease!(session.id)

      end_instance!(:session_owner_takeover_first)
      second = start_instance!(:session_owner_takeover_second)

      # No owner override, so the takeover names whichever VM is running it:
      # the successor, by its own incarnation.
      assert {:ok, replacement} =
               SessionContinuity.replace_unavailable_owner_lease(
                 session,
                 RequestOptions.for_websocket(%{})
               )

      replacement_lease = active_lease!(session.id)

      assert replacement.owner_instance_id == second.node_name
      assert replacement.owner_instance_boot_id == second.boot_id
      assert replacement_lease.owner_instance_boot_id == second.boot_id
      refute replacement_lease.id == stale_lease.id
      assert Repo.get!(BridgeOwnerLease, stale_lease.id).status == "released"
      refute replacement.owner_lease_token == session.owner_lease_token
      assert Repo.get!(CodexSession, session.id).owner_instance_boot_id == second.boot_id
    end
  end

  describe "the liveness guard judges a lease by its holder" do
    test "a legacy orphan behind an absent incarnation's unexpired lease is recovered" do
      setup = accounting_setup()
      now = now()
      dispatched_at = DateTime.add(now, -10, :minute)

      name = :"lease_presence_#{unique()}"
      first_peer = start_presence_peer!(name)
      first = first_peer.identity
      {:ok, _} = InstancePresence.record_heartbeat(first)

      # The attempt is dispatched by the VM that owns the session, and the
      # session and its lease are minted by the ordinary start path, so the
      # lease under test is the one production writes.
      %{request: request, attempt: attempt} = dispatch_open_attempt!(setup, dispatched_at)

      attempt =
        attempt
        |> Ecto.Changeset.change(
          owner_instance_id: first.node_name,
          owner_instance_boot_id: first.boot_id,
          owner_execution_id: nil,
          owner_process_id: nil
        )
        |> Repo.update!()

      {:ok, session} = start_session(setup, turn_state(), first)
      turn = turn_row(session, request, attempt, dispatched_at)

      lease = active_lease!(session.id)
      assert DateTime.compare(lease.expires_at, now) == :gt

      # The VM is halted from inside, so no drain runs and its presence row
      # keeps whatever it last wrote. Place that refresh ten minutes back
      # through the same upsert the heartbeat uses rather than waiting out the
      # liveness window.
      {:ok, _stale} = InstancePresence.record_heartbeat(first, dispatched_at)
      stop_presence_peer!(first_peer)

      second = start_presence_peer!(name).identity
      {:ok, _} = InstancePresence.record_heartbeat()
      assert second.node_name == first.node_name

      assert {:ok, %{absent_instance_attempts_recovered: 1}} =
               Accounting.recover_absent_instance_attempts(now)

      assert %Request{status: "failed", last_error_code: "absent_instance_recovered"} =
               Repo.get!(Request, request.id)

      assert %CodexTurn{status: "interrupted", error_code: "absent_instance_recovered"} =
               Repo.reload!(turn)

      assert Repo.reload!(attempt).status == "failed"
    end

    test "a session that moved to a live replica keeps its work" do
      setup = accounting_setup()
      now = now()
      dispatched_at = DateTime.add(now, -10, :minute)

      absent = start_instance!(:session_owner_moved_absent)
      %{request: request, attempt: attempt} = dispatch_open_attempt!(setup, dispatched_at)

      # The replica that took the session over is a different VM entirely. Only
      # another node can name its own incarnation, so this is the one owner the
      # test supplies, exactly as owner forwarding supplies it on takeover.
      replica = Identity.new("codex_pooler@10.0.0.#{unique()}", "boot-#{unique()}")
      {:ok, _live} = InstancePresence.record_heartbeat(replica, now)

      {:ok, session} = start_session(setup, turn_state(), replica)
      _turn = turn_row(session, request, attempt, dispatched_at)

      assert session.owner_instance_boot_id == replica.boot_id

      {:ok, _stale} = InstancePresence.record_heartbeat(absent, dispatched_at)
      end_instance!(:session_owner_moved_absent)

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"
    end

    test "an owner that never published presence still protects its session" do
      setup = accounting_setup()
      now = now()
      dispatched_at = DateTime.add(now, -10, :minute)

      absent = start_instance!(:session_owner_unknown_absent)
      %{request: request, attempt: attempt} = dispatch_open_attempt!(setup, dispatched_at)

      # A VM that minted its incarnation and never got a heartbeat written: a
      # failed first write, or a replica that could not reach the database.
      silent = Identity.new("codex_pooler@10.0.0.#{unique()}", "boot-#{unique()}")
      refute Repo.get(InstancePresence.Instance, silent.instance_id)

      {:ok, session} = start_session(setup, turn_state(), silent)
      _turn = turn_row(session, request, attempt, dispatched_at)

      {:ok, _stale} = InstancePresence.record_heartbeat(absent, dispatched_at)
      end_instance!(:session_owner_unknown_absent)

      # Unknown is not gone: the lease still counts as live work.
      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
    end

    test "a session written before incarnations existed is not wrongly recoverable" do
      setup = accounting_setup()
      now = now()
      dispatched_at = DateTime.add(now, -10, :minute)

      first = start_instance!(:session_owner_pre_incarnation)
      %{request: request, attempt: attempt} = dispatch_open_attempt!(setup, dispatched_at)
      {:ok, session} = start_session(setup, turn_state())
      _turn = turn_row(session, request, attempt, dispatched_at)

      # The shape the previous release wrote and that is still in production: an
      # owner named by node name alone. Its writer no longer exists in the tree,
      # so the rows are put back exactly as it left them.
      strip_incarnation!(session)

      {:ok, _stale} = InstancePresence.record_heartbeat(first, dispatched_at)
      end_instance!(:session_owner_pre_incarnation)

      # The owning node name has a stale presence row, but the session names no
      # incarnation, so nothing proves that row is its owner's.
      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"

      assert {:ok, %{stale_reservations_settled: 1}} =
               Accounting.recover_stale_reservations(DateTime.add(now, 7, :hour))
    end
  end

  test "an HTTP request cannot renew an absent incarnation owner lease" do
    setup = accounting_setup()
    name = :"lease_presence_#{unique()}"
    first_peer = start_presence_peer!(name)
    first = first_peer.identity
    {:ok, _} = InstancePresence.record_heartbeat(first)
    state = turn_state()
    {:ok, session} = start_session(setup, state, first)
    lease = active_lease!(session.id)

    opts =
      RequestOptions.build(%{accepted_turn_state: state}, "/backend-api/codex/responses", %{})

    {:ok, attached} = RoutingContinuity.attach_codex_session(setup.auth, %{}, opts)
    lease = Repo.reload!(lease)
    {:ok, _stale} = InstancePresence.record_heartbeat(first, DateTime.add(now(), -10, :minute))
    stop_presence_peer!(first_peer)
    second = start_presence_peer!(name).identity
    assert second.node_name == first.node_name
    refute second.boot_id == first.boot_id

    assert attached.continuity.codex_session.owner_instance_boot_id == first.boot_id
    result = SessionLeaseHeartbeat.run(attached, fn -> :dispatched end)

    assert Repo.reload!(lease).expires_at == lease.expires_at
    assert result == {:error, :owner_unavailable}
  end

  for presence <- [:live, :unknown, :legacy, :stale_unreachable] do
    @tag renewal_presence: presence
    test "HTTP renewal preserves #{presence} remote ownership", %{renewal_presence: presence} do
      setup = accounting_setup()
      _local = start_instance!(:http_control_local)
      remote = Identity.new("sample-owner@remote", "boot-#{unique()}")

      if presence == :live do
        {:ok, _row} = InstancePresence.record_heartbeat(remote, now())
      end

      state = turn_state()
      {:ok, session} = start_session(setup, state, remote)
      if presence == :legacy, do: strip_incarnation!(session)
      before = active_lease!(session.id)

      if presence == :stale_unreachable do
        {:ok, _} = InstancePresence.record_heartbeat(remote, DateTime.add(now(), -180, :second))
      end

      opts =
        RequestOptions.build(%{accepted_turn_state: state}, "/backend-api/codex/responses", %{})

      {:ok, attached} = RoutingContinuity.attach_codex_session(setup.auth, %{}, opts)

      assert :dispatched = SessionLeaseHeartbeat.run(attached, fn -> :dispatched end)
      after_lease = active_lease!(session.id)
      assert after_lease.owner_instance_id == remote.node_name
      assert after_lease.owner_instance_boot_id == before.owner_instance_boot_id
      assert after_lease.lease_token == before.lease_token
      assert DateTime.compare(after_lease.expires_at, before.expires_at) == :gt
    end
  end

  for witnessed <- [false, true] do
    @tag witnessed: witnessed
    test "completion cannot renew known-absent ownership with witness=#{witnessed}", %{
      witnessed: witnessed
    } do
      setup = accounting_setup()
      name = :"lease_presence_#{unique()}"
      peer = start_presence_peer!(name)
      remote = peer.identity
      {:ok, _} = InstancePresence.record_heartbeat(remote)
      {:ok, session} = start_session(setup, turn_state(), remote)
      before_lease = active_lease!(session.id)
      before_session = Repo.reload!(session)

      before_aliases =
        Repo.aggregate(
          from(a in BridgeSessionAlias,
            where: a.codex_session_id == ^session.id
          ),
          :count
        )

      {:ok, _} = InstancePresence.record_heartbeat(remote, DateTime.add(now(), -10, :minute))
      stop_presence_peer!(peer)
      _successor = start_presence_peer!(name)
      opts = RequestOptions.build(%{codex_session: session}, "/backend-api/codex/responses", %{})

      opts =
        if witnessed do
          {:ok, witness} =
            OwnerWitness.new(session)

          RequestOptions.put_session_owner_witness(opts, witness)
        else
          opts
        end

      assert {:error, :owner_unavailable} =
               SessionContinuity.register_codex_session_continuity(
                 session,
                 %{},
                 %{"id" => "resp_absent_completion"},
                 opts
               )

      assert Repo.reload!(before_lease) == before_lease
      assert Repo.reload!(session) == before_session

      assert Repo.aggregate(
               from(a in BridgeSessionAlias,
                 where: a.codex_session_id == ^session.id
               ),
               :count
             ) == before_aliases
    end
  end

  test "fresh HTTP attach replaces an unexpired lease whose owner is known absent" do
    setup = accounting_setup()
    name = :"lease_presence_#{unique()}"
    peer = start_presence_peer!(name)
    remote = peer.identity
    {:ok, _} = InstancePresence.record_heartbeat(remote)
    key = turn_state()
    {:ok, session} = start_session(setup, key, remote)
    before_lease = active_lease!(session.id)

    {:ok, old_witness} =
      OwnerWitness.new(session)

    old_options =
      RequestOptions.build(%{codex_session: session}, "/backend-api/codex/responses", %{})
      |> RequestOptions.put_session_owner_witness(old_witness)

    old_aliases =
      Repo.aggregate(
        from(a in BridgeSessionAlias,
          where: a.codex_session_id == ^session.id
        ),
        :count
      )

    {:ok, _} = InstancePresence.record_heartbeat(remote, DateTime.add(now(), -10, :minute))
    stop_presence_peer!(peer)
    _successor = start_presence_peer!(name)
    local = Identity.local()
    opts = RequestOptions.build(%{accepted_turn_state: key}, "/backend-api/codex/responses", %{})
    assert {:ok, attached} = RoutingContinuity.attach_codex_session(setup.auth, %{}, opts)
    assert attached.continuity.codex_session.id == session.id
    assert attached.continuity.codex_session.owner_instance_boot_id == local.boot_id
    refute attached.continuity.codex_session.owner_lease_token == before_lease.lease_token
    assert Repo.reload!(before_lease).status == "released"

    assert Repo.aggregate(
             from(l in BridgeOwnerLease,
               where: l.codex_session_id == ^session.id and l.status == "active"
             ),
             :count
           ) == 1

    assert :dispatched = SessionLeaseHeartbeat.run(attached, fn -> :dispatched end)
    replacement = Repo.reload!(session)
    replacement_lease = active_lease!(session.id)

    assert {:error, :stale_owner} =
             SessionContinuity.register_codex_session_continuity(
               session,
               %{},
               %{"id" => "resp_stale_after_takeover"},
               old_options
             )

    assert Repo.reload!(session) == replacement
    assert active_lease!(session.id) == replacement_lease

    assert Repo.aggregate(
             from(a in BridgeSessionAlias,
               where: a.codex_session_id == ^session.id
             ),
             :count
           ) == old_aliases
  end

  # A VM start mints one incarnation and the real heartbeat publishes it. Every
  # session below takes its owner from that same identity through the ordinary
  # start path, so nothing here supplies the ownership it then asserts.
  defp start_instance!(name) do
    _boot_id = Identity.mint_boot_id!()
    identity = InstancePresence.local_identity()

    pid =
      start_supervised!(
        {InstanceHeartbeat, enabled: true, interval_ms: :timer.minutes(5), name: name},
        id: name
      )

    # The publish runs in the process's own continue, so one synchronous state
    # read is enough to know it has happened; no timer is waited out.
    _state = :sys.get_state(pid)

    identity
  end

  defp end_instance!(name), do: :ok = stop_supervised!(name)

  defp start_presence_peer!(name), do: CodexPooler.InstancePresencePeer.start_presence_peer!(name)
  defp stop_presence_peer!(peer), do: CodexPooler.InstancePresencePeer.stop_presence_peer!(peer)

  defp start_session(setup, turn_state, owner \\ nil)

  defp start_session(setup, turn_state, nil) do
    Websocket.start_codex_session(setup.auth, %{accepted_turn_state: turn_state})
  end

  defp start_session(setup, turn_state, %Identity{} = owner) do
    Websocket.start_codex_session(setup.auth, %{
      accepted_turn_state: turn_state,
      owner_instance_id: owner.node_name,
      owner_instance_boot_id: owner.boot_id
    })
  end

  defp dispatch_open_attempt!(setup, dispatched_at) do
    {:ok, reserved} =
      Accounting.reserve(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "stream" => true, "max_output_tokens" => 10},
        %{
          correlation_id: "corr-session-owner-#{unique()}",
          now: dispatched_at,
          transport: "websocket"
        }
      )

    {:ok, attempt} =
      Accounting.create_attempt(reserved.request, setup.assignment, %{now: dispatched_at})

    %{request: reserved.request, attempt: attempt}
  end

  defp turn_row(session, request, attempt, started_at) do
    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      status: CodexTurn.in_progress_status(),
      final_attempt_id: attempt.id,
      started_at: started_at,
      created_at: started_at,
      updated_at: started_at
    }
    |> Repo.insert!()
  end

  defp strip_incarnation!(%CodexSession{} = session) do
    Repo.update_all(
      from(row in CodexSession, where: row.id == ^session.id),
      set: [owner_instance_boot_id: nil]
    )

    Repo.update_all(
      from(row in BridgeOwnerLease, where: row.codex_session_id == ^session.id),
      set: [owner_instance_boot_id: nil]
    )

    :ok
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active"
    )
  end

  defp turn_state, do: "session-owner-incarnation-#{unique()}"

  defp unique, do: System.unique_integer([:positive])

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
