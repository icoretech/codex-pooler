defmodule CodexPooler.Gateway.Websocket.OwnerCleanupPostgresTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.AccountingTestSupport
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.OwnerCleanupPeer, as: Peer
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @budget 30_000
  @moduletag capture_log: true

  setup do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start([:"owner_cleanup_#{System.unique_integer([:positive])}", :shortnames])

      on_exit(fn -> :net_kernel.stop() end)
    end

    peers = Enum.map([:a, :b], &start_peer/1)
    {:ok, peers: peers}
  end

  for {source, target} <- [{0, 1}, {1, 0}],
      mode <- [:stale_token, :same_token, :absent_witness] do
    test "delayed #{mode} cleanup #{source} to #{target} preserves accepted live replacement", %{
      peers: peers
    } do
      source = Enum.at(peers, unquote(source))
      target = Enum.at(peers, unquote(target))
      mode = unquote(mode)
      {setup, session} = fixture(source)
      old = call(source, :start_request, [setup, session, self()])
      await_accepted(old, source)
      delayed = call(source, :delay_cleanup, [old.owner, self(), mode])
      assert_receive {:cleanup_waiting, ^delayed, witness, ^source}, @budget
      assert_witness(mode, witness, old.request.id)

      replacement = call(target, :takeover, [session, target, unquote(mode == :same_token)])
      current = call(target, :start_request, [setup, replacement, self()])
      await_accepted(current, target)
      before_cleanup = call(target, :facts, [current])
      assert_live_binding(before_cleanup, current, target)
      assert node(delayed) == source
      assert source != target
      send(delayed, :release_cleanup)
      assert_receive {:cleanup_finished, ^delayed, {:error, :stale_owner_cleanup}}, @budget
      after_cleanup = call(target, :facts, [current])
      assert_live_binding(after_cleanup, current, target)
      assert before_cleanup.request == after_cleanup.request
      assert before_cleanup.attempt == after_cleanup.attempt
      assert before_cleanup.turn == after_cleanup.turn
      assert before_cleanup.lease == after_cleanup.lease
      assert before_cleanup.session == after_cleanup.session
      assert before_cleanup.ledger == after_cleanup.ledger
      finish(source, old)
      finish(target, current)
    end
  end

  for mode <- [:expired_lease, :generation_changed] do
    test "accepted owner snapshot rejects #{mode}", %{peers: [source, target]} do
      {setup, session} = fixture(source)
      current = call(source, :start_request, [setup, session, self()])
      await_accepted(current, source)
      delayed = call(source, :delay_cleanup, [current.owner, self(), :current])
      assert_receive {:cleanup_waiting, ^delayed, _, ^source}, @budget
      assert_live_binding(call(source, :facts, [current]), current, source)
      :ok = call(target, :invalidate, [current, unquote(mode)])
      before_cleanup = call(source, :facts, [current])
      send(delayed, :release_cleanup)
      assert_receive {:cleanup_finished, ^delayed, {:error, :stale_owner_cleanup}}, @budget
      facts = call(source, :facts, [current])
      assert facts.request.status == "in_progress"
      assert facts.attempt.status == "in_progress"
      assert facts.turn.status == "in_progress"
      assert facts.active.cleanup_witness.request_id == current.request.id
      assert before_cleanup.ledger == facts.ledger
      finish(source, current)
    end
  end

  test "current accepted owner witness interrupts exactly its request", %{peers: [source, _]} do
    {setup, session} = fixture(source)
    current = call(source, :start_request, [setup, session, self()])
    await_accepted(current, source)
    delayed = call(source, :delay_cleanup, [current.owner, self(), :current])
    assert_receive {:cleanup_waiting, ^delayed, witness, ^source}, @budget
    assert witness.request_id == current.request.id
    assert_live_binding(call(source, :facts, [current]), current, source)
    send(delayed, :release_cleanup)
    assert_receive {:cleanup_finished, ^delayed, :ok}, @budget
    facts = call(source, :facts, [current])
    assert facts.request.status == "failed"
    assert facts.attempt.status == "failed"
    assert facts.turn.status == "interrupted"
    assert {:ok, correction} = call(source, :correct_usage, [current])
    assert correction.finalization_disposition == :replaced
    assert correction.request.status == "succeeded"
    assert correction.attempt.usage_status == "usage_known"
    assert correction.settlement.correction_of_entry_id
    corrected = call(source, :facts, [current])
    assert {:ok, repeated} = call(source, :correct_usage, [current])
    assert repeated.settlement.id == correction.settlement.id
    assert corrected.ledger == call(source, :facts, [current]).ledger
    assert_effective_disposition(corrected.ledger)
    finish(source, current)
  end

  test "same owner token cleanup of a completed request preserves the next accepted request",
       %{peers: [source, _]} do
    {setup, session} = fixture(source)
    old = call(source, :start_request, [setup, session, self()])
    await_accepted(old, source)
    delayed = call(source, :delay_cleanup, [old.owner, self(), :current])
    delayed_release = call(source, :delay_release, [old.owner, self()])
    assert_receive {:release_waiting, ^delayed_release}, @budget
    assert_receive {:cleanup_waiting, ^delayed, old_witness, ^source}, @budget
    finish(source, old)
    assert {:ok, _} = call(source, :correct_usage, [old])
    current = call(source, :start_request, [setup, session, self()])
    await_accepted(current, source)
    before_cleanup = call(source, :facts, [current])
    assert_live_binding(before_cleanup, current, source)
    assert old.owner == current.owner

    assert old_witness.owner_lease_token ==
             before_cleanup.active.cleanup_witness.owner_lease_token

    refute old_witness.request_id == before_cleanup.active.cleanup_witness.request_id
    send(delayed, :release_cleanup)
    assert_receive {:cleanup_finished, ^delayed, {:error, :stale_owner_cleanup}}, @budget
    after_cleanup = call(source, :facts, [current])
    assert_live_binding(after_cleanup, current, source)
    assert before_cleanup.request == after_cleanup.request
    assert before_cleanup.attempt == after_cleanup.attempt
    assert before_cleanup.turn == after_cleanup.turn
    assert before_cleanup.ledger == after_cleanup.ledger
    send(delayed_release, :release_cleanup)
    assert_receive {:release_finished, ^delayed_release, :ok}, @budget
    assert before_cleanup.lease == call(source, :facts, [current]).lease
    assert before_cleanup.ledger == call(source, :facts, [current]).ledger
    finish(source, current)
  end

  test "draining the actual owner retains its accepted witness through termination",
       %{peers: [source, _]} do
    {setup, session} = fixture(source)
    current = call(source, :start_request, [setup, session, self()])
    await_accepted(current, source)
    facts = call(source, :facts, [current])
    task = facts.active.task_pid
    owner_monitor = Process.monitor(current.owner)
    task_monitor = Process.monitor(task)

    assert :ok =
             :erpc.call(
               source,
               CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession,
               :drain_owner,
               [current.owner],
               @budget
             )

    assert_receive {:DOWN, ^owner_monitor, :process, _, :normal}, @budget
    assert_receive {:DOWN, ^task_monitor, :process, ^task, _}, @budget
    ref = current.ref
    assert_receive {:submission_finished, ^ref, {:error, :owner_drained}}, @budget
    settled = call(source, :facts, [current])
    assert settled.request.status == "failed"
    assert settled.attempt.status == "failed"
    assert settled.turn.status == "interrupted"
    assert settled.settlements == 1
    assert_effective_disposition(settled.ledger)
    assert is_nil(settled.active)
  end

  defp assert_witness(:absent_witness, witness, _request_id), do: assert(is_nil(witness))
  defp assert_witness(_mode, witness, request_id), do: assert(witness.request_id == request_id)

  defp assert_effective_disposition(ledger) do
    for kind <- ["settlement", "release"] do
      assert [_entry] =
               Enum.filter(ledger, &(&1.entry_kind == kind and &1.amount_status != "voided"))
    end
  end

  defp fixture(owner_node) do
    Sandbox.unboxed_run(Repo, fn ->
      setup = AccountingTestSupport.accounting_setup()

      {:ok, session} =
        Gateway.start_codex_session(
          setup.auth,
          RequestOptions.for_websocket(%{
            accepted_turn_state: Ecto.UUID.generate(),
            owner_instance_id: Atom.to_string(owner_node)
          })
        )

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete!(setup.pool)
          Repo.delete!(setup.identity)
          Repo.delete!(setup.pricing)
        end)
      end)

      {Map.take(setup, [:auth, :model, :assignment]), session}
    end)
  end

  defp assert_live_binding(facts, current, owner_node) do
    assert facts.request.status == "in_progress"
    assert facts.attempt.status == "in_progress"
    assert facts.turn.status == "in_progress"
    assert facts.active.cleanup_witness.request_id == current.request.id
    assert facts.active.cleanup_witness.attempt_id == current.attempt.id
    assert facts.session.owner_instance_id == Atom.to_string(owner_node)
    assert facts.lease.owner_instance_id == facts.session.owner_instance_id
    assert facts.lease.lease_token == facts.session.owner_lease_token
    assert DateTime.compare(facts.session.owner_lease_expires_at, DateTime.utc_now()) == :gt

    assert facts.request.request_metadata["websocket_owner_forwarding"] == %{
             "owner_instance_id" => facts.session.owner_instance_id,
             "downstream_epoch" => current.downstream.epoch
           }
  end

  defp await_accepted(turn, peer_node) do
    ref = turn.ref
    assert_receive {:upstream_waiting, ^ref, _, ^peer_node}, @budget
    request_id = turn.request.id

    assert_receive {:websocket_owner_cleanup_witness, _, _, _, %{request_id: ^request_id}},
                   @budget
  end

  defp finish(peer_node, turn) do
    :ok = call(peer_node, :finish, [turn])
    ref = turn.ref
    assert_receive {:submission_finished, ^ref, :ok}, @budget
  end

  defp start_peer(suffix) do
    name = :"owner_cleanup_#{suffix}_#{System.unique_integer([:positive])}"
    {:ok, pid, peer_node} = :peer.start_link(%{name: name, args: [~c"+S", ~c"2:2"]})
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :peer.stop(pid) end)
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    :ok = call(peer_node, :bootstrap, [Application.get_all_env(:codex_pooler), Repo.config()])
    peer_node
  end

  defp call(peer_node, function, args), do: :erpc.call(peer_node, Peer, function, args, @budget)
end
