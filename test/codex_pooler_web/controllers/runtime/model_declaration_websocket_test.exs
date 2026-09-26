defmodule CodexPoolerWeb.Runtime.ModelDeclarationWebsocketTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_session_owner!: 2]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv

  @moduletag capture_log: true

  for topology <- [:direct, :owner, :peer], mode <- ~w(full lite), route <- ["/backend-api/codex/responses", "/v1/responses"] do
    @tag topology: topology, mode: mode, route: route
    test "#{topology} #{mode} #{route} isolates model evidence across turns on a real socket", ctx do
      TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, ctx.topology != :direct)
      if ctx.topology == :peer, do: enter_peer_owner_topology!()

      first = frames("resp_model_first", ["model-a", "model-b", "model-c", "model-a"])
      second = frames("resp_model_second", ["model-b", "model-b"])

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "WEBSOCKET", respond: FakeUpstream.websocket_text_frames(first)),
            FakeUpstream.expect_request(method: "WEBSOCKET", respond: FakeUpstream.websocket_text_frames(second))
          ])
        )

      setup = gateway_setup(upstream)
      timestamp = DateTime.utc_now()
      Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: ctx.mode, created_at: timestamp, updated_at: timestamp})
      turn_state = Ecto.UUID.generate()
      peer = if ctx.topology == :peer, do: start_peer_session_owner!(setup, %{accepted_turn_state: turn_state})
      port = start_public_endpoint!()
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state, ctx.route)
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic model observation"}]}]})

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, websocket, received} = receive_terminal(conn, websocket, ref, [])
        assert CodexPooler.JSON.decode!(List.last(received))["type"] == "response.completed"
        if ctx.route == "/backend-api/codex/responses", do: assert(received == first)
        [first_attempt] = await_attempts(setup.pool.id, 1)
        assert first_attempt.served_model == "model-a"
        assert first_attempt.model_observation == %{"version" => 1, "coverage" => "full", "conflict" => true, "first_conflicting_model" => "model-b", "terminal_model" => "model-a", "terminal_status" => "completed"}

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {_conn, _websocket, received} = receive_terminal(conn, websocket, ref, [])
        if ctx.route == "/backend-api/codex/responses", do: assert(received == second)
        [_, second_attempt] = await_attempts(setup.pool.id, 2)
        assert second_attempt.served_model == "model-b"
        assert second_attempt.model_observation["conflict"] == false
        assert second_attempt.model_observation["first_conflicting_model"] == nil
        assert second_attempt.model_observation["terminal_model"] == "model-b"
        assert FakeUpstream.count(upstream) == 2
        assert :ok = FakeUpstream.verify!(upstream)

        for attempt <- [first_attempt, second_attempt] do
          assert [settlement] = Repo.all(from(l in LedgerEntry, where: l.request_id == ^attempt.request_id and l.entry_kind == "settlement"))
          assert settlement.total_tokens == 5
          assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(70))
        end

        if peer do
          assert Repo.get!(CodexSession, peer.session.id).owner_instance_id == Atom.to_string(peer.node)
          assert node(peer.owner_pid) != node()
        end
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp receive_terminal(conn, websocket, ref, acc) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
    type = CodexPooler.JSON.decode!(frame)["type"]
    acc = if type == "codex.response.metadata", do: acc, else: [frame | acc]
    if type in ~w(response.completed response.failed error), do: {conn, websocket, Enum.reverse(acc)}, else: receive_terminal(conn, websocket, ref, acc)
  end

  defp await_attempts(pool_id, count), do: await_attempts(pool_id, count, System.monotonic_time(:millisecond) + 15_000)

  defp await_attempts(pool_id, count, deadline) do
    attempts = Repo.all(from(a in Attempt, join: r in Request, on: r.id == a.request_id, where: r.pool_id == ^pool_id and not is_nil(a.completed_at), order_by: [asc: a.started_at]))

    cond do
      length(attempts) == count ->
        attempts

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("attempt settlement did not complete")

      true ->
        receive do
        after
          1 -> await_attempts(pool_id, count, deadline)
        end
    end
  end

  defp frames(id, models) do
    for {model, index} <- Enum.with_index(models) do
      terminal? = index == length(models) - 1

      type =
        cond do
          terminal? -> "response.completed"
          index == 0 -> "response.created"
          true -> "response.in_progress"
        end

      response = %{"id" => id, "model" => model, "status" => if(terminal?, do: "completed", else: "in_progress"), "output" => []}
      response = if terminal?, do: Map.put(response, "usage", %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}), else: response
      CodexPooler.JSON.encode!(%{"type" => type, "response" => response})
    end
  end
end
