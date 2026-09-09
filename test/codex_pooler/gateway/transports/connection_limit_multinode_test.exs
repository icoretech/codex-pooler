defmodule CodexPooler.Gateway.Transports.ConnectionLimitMultinodeTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.AccountingTestSupport
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.OwnerCleanupPeer, as: Peer
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @budget 30_000
  setup do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start([
          :"connection_limit_multinode_#{System.unique_integer([:positive])}",
          :shortnames
        ])

      on_exit(fn -> :net_kernel.stop() end)
    end

    peers = Enum.map([:a, :b], &start_peer/1)
    {:ok, peers: peers}
  end

  for {owner_index, proxy_index} <- [{0, 1}, {1, 0}] do
    test "two real BEAM nodes preserve the replacement lease when owner/proxy roles are #{owner_index}->#{proxy_index}",
         %{peers: peers} do
      owner_node = Enum.at(peers, unquote(owner_index))
      proxy_node = Enum.at(peers, unquote(proxy_index))
      assert owner_node != proxy_node
      assert owner_node in Node.list(:connected)
      assert proxy_node in Node.list(:connected)
      assert true == :erpc.call(owner_node, :net_kernel, :connect_node, [proxy_node])
      assert proxy_node in :erpc.call(owner_node, Node, :list, [:connected])
      assert :erpc.call(owner_node, Node, :self, []) == owner_node
      assert :erpc.call(proxy_node, Node, :self, []) == proxy_node
      assert owner_node in :erpc.call(proxy_node, Node, :list, [:connected])

      IO.puts(
        "T7_NODE_TOPOLOGY owner=#{owner_node} proxy=#{proxy_node} coordinator=#{Node.self()} " <>
          "owner_peers=#{inspect(:erpc.call(owner_node, Node, :list, [:connected]))} " <>
          "proxy_peers=#{inspect(:erpc.call(proxy_node, Node, :list, [:connected]))}"
      )

      {setup, session} = fixture(owner_node)
      old = call(owner_node, :start_request, [setup, session, self()])
      await_accepted(old, owner_node)

      old_state = :erpc.call(owner_node, :sys, :get_state, [old.owner])
      assert is_pid(old_state.active_turn.task_pid)
      assert node(old_state.active_turn.task_pid) == owner_node

      delayed = call(owner_node, :delay_cleanup, [old.owner, self(), :current])
      assert_receive {:cleanup_waiting, ^delayed, witness, ^owner_node}, @budget
      assert witness.request_id == old.request.id

      replacement = call(proxy_node, :takeover, [session, proxy_node, false])
      current = call(proxy_node, :start_request, [setup, replacement, self()])
      await_accepted(current, proxy_node)

      before_cleanup = call(proxy_node, :facts, [current])
      assert_live_binding(before_cleanup, current, proxy_node)
      assert before_cleanup.session.owner_instance_id == Atom.to_string(proxy_node)
      assert node(current.owner) == proxy_node

      send(delayed, :release_cleanup)
      assert_receive {:cleanup_finished, ^delayed, {:error, :stale_owner_cleanup}}, @budget

      after_cleanup = call(proxy_node, :facts, [current])
      assert before_cleanup.request == after_cleanup.request
      assert before_cleanup.attempt == after_cleanup.attempt
      assert before_cleanup.turn == after_cleanup.turn
      assert before_cleanup.lease == after_cleanup.lease
      assert before_cleanup.ledger == after_cleanup.ledger
      assert_live_binding(after_cleanup, current, proxy_node)

      IO.puts(
        "T7_STALE_CLEANUP owner_task=#{inspect(old_state.active_turn.task_pid)} " <>
          "replacement_owner=#{inspect(current.owner)} request_unchanged=true attempt_unchanged=true " <>
          "turn_unchanged=true lease_unchanged=true ledger_unchanged=true"
      )

      finish(owner_node, old)
      finish(proxy_node, current)
    end
  end

  test "current owner cancellation settles only the current request across a real proxy hop", %{
    peers: [owner_node, proxy_node]
  } do
    assert owner_node != proxy_node
    assert proxy_node in Node.list(:connected)
    {setup, session} = fixture(proxy_node)
    current = call(proxy_node, :start_request, [setup, session, self()])
    await_accepted(current, proxy_node)

    delayed = call(proxy_node, :delay_cleanup, [current.owner, self(), :current])
    assert_receive {:cleanup_waiting, ^delayed, witness, ^proxy_node}, @budget
    assert witness.request_id == current.request.id

    send(delayed, :release_cleanup)
    assert_receive {:cleanup_finished, ^delayed, :ok}, @budget

    facts = call(proxy_node, :facts, [current])
    assert facts.request.status == "failed"
    assert facts.attempt.status == "failed"
    assert facts.turn.status == "interrupted"
    assert facts.settlements == 1
    assert Enum.count(facts.ledger, &(&1.entry_kind == "settlement")) == 1
    assert Enum.count(facts.ledger, &(&1.entry_kind == "release")) == 1
  end

  test "a delayed original cleanup cannot mutate a request after its generation changes on the peer",
       %{peers: [owner_node, proxy_node]} do
    {setup, session} = fixture(owner_node)
    current = call(owner_node, :start_request, [setup, session, self()])
    await_accepted(current, owner_node)

    delayed = call(owner_node, :delay_cleanup, [current.owner, self(), :current])
    assert_receive {:cleanup_waiting, ^delayed, witness, ^owner_node}, @budget
    assert witness.request_id == current.request.id

    before_cleanup = call(owner_node, :facts, [current])
    :ok = call(proxy_node, :invalidate, [current, :generation_changed])
    after_invalidation = call(owner_node, :facts, [current])

    assert after_invalidation.attempt.replay_generation ==
             before_cleanup.attempt.replay_generation + 1

    send(delayed, :release_cleanup)
    assert_receive {:cleanup_finished, ^delayed, {:error, :stale_owner_cleanup}}, @budget

    after_cleanup = call(owner_node, :facts, [current])
    assert after_cleanup.request.status == "in_progress"
    assert after_cleanup.attempt.status == "in_progress"
    assert after_cleanup.turn.status == "in_progress"
    assert after_cleanup.ledger == after_invalidation.ledger
    assert after_cleanup.lease == after_invalidation.lease

    finish(owner_node, current)
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

  defp start_peer(suffix) do
    name = :"connection_limit_#{suffix}_#{System.unique_integer([:positive])}"

    {:ok, pid, peer_node} =
      :peer.start_link(%{
        name: name,
        args: [~c"+S", ~c"2:2", ~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
      })

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :peer.stop(pid) end)

    assert {:ok, false} =
             :erpc.call(peer_node, :application, :get_env, [
               :kernel,
               :prevent_overlapping_partitions
             ])

    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    :ok =
      call(peer_node, :bootstrap, [
        Application.get_all_env(:codex_pooler),
        Repo.config()
      ])

    peer_node
  end

  defp call(peer_node, function, args),
    do: :erpc.call(peer_node, Peer, function, args, @budget)

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

  defp assert_live_binding(facts, current, owner_node) do
    assert facts.request.status == "in_progress"
    assert facts.attempt.status == "in_progress"
    assert facts.turn.status == "in_progress"
    assert facts.active.cleanup_witness.request_id == current.request.id
    assert facts.session.owner_instance_id == Atom.to_string(owner_node)
    assert facts.lease.owner_instance_id == Atom.to_string(owner_node)
    assert facts.lease.lease_token == facts.session.owner_lease_token
    assert DateTime.compare(facts.session.owner_lease_expires_at, DateTime.utc_now()) == :gt
  end
end
