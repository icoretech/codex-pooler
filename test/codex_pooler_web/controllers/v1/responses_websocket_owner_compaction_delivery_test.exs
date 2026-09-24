defmodule CodexPoolerWeb.V1.ResponsesWebsocketOwnerCompactionDeliveryTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      await_public_websocket_upgrade: 2,
      gateway_setup: 2,
      mint_websocket_new!: 4,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_session_owner!: 2]

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv

  # A public `/v1` websocket compaction anchored on the connection's lineage is
  # collected by the session's owner (`compaction_result_mode:
  # :public_websocket`, owner delivery `collect_compaction`) and returned whole
  # in its reply; the owner sends no `:complete` after it. Before `056995113`
  # the owner submission observer still marked the result as waiting for that
  # `:complete`, and the public socket finished the turn only once it came
  # (`public_turn_owner_complete?`), so the compaction reached the client and
  # every later `response.create` of the connection queued behind it. Unlike
  # the native socket, the public one has no local-owner release, so one node
  # with forwarding on stalled too (findings#206 row 206-398).
  #
  # Topology: owner forwarding on; the owner on this node (one node) or on a
  # peer VM sharing the committed database (two nodes), the public socket on
  # this node in both. Serving modes Full and Lite. Identifiers, prompts and
  # provider frames are synthetic.
  @detection_timeout_ms 15_000

  for topology <- [:local_owner, :peer_owner], mode <- ["full", "lite"] do
    @tag topology: topology, mode: mode
    test "#{topology} #{mode} anchored /v1 websocket compaction is delivered and the next turn is served on the same connection",
         %{topology: topology, mode: mode} do
      TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
      if topology == :peer_owner, do: enter_peer_owner_topology!()

      lineage = "resp_v1_owner_delivery_lineage_#{mode}"
      compacted = "resp_v1_owner_delivery_compact_#{mode}"
      next = "resp_v1_owner_delivery_next_#{mode}"
      item = %{"type" => "compaction", "encrypted_content" => "synthetic-v1-owner-delivery-#{mode}"}
      input = tool_output_compaction_trigger_input()

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            native_turn(completed_frames(lineage, []), forbidden: ["previous_response_id"]),
            native_turn(completed_frames(compacted, [item], [item]), equals: %{"previous_response_id" => lineage}),
            native_turn(completed_frames(next, []), forbidden: ["previous_response_id"])
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      turn_state = "v1-owner-compaction-delivery-#{topology}-#{mode}-#{System.unique_integer([:positive])}"
      peer = if topology == :peer_owner, do: start_peer_session_owner!(setup, %{accepted_turn_state: turn_state})
      put_serving_mode!(setup, mode)
      port = start_public_endpoint!()
      client = connect!(port, setup, turn_state)

      try do
        {client, frames} = client |> send_create!(setup, %{"input" => "synthetic lineage request"}) |> receive_until_terminal([])
        assert [%{"type" => "response.completed", "response" => %{"id" => ^lineage}}] = frames

        {client, frames} =
          client
          |> send_create!(setup, %{"previous_response_id" => lineage, "input" => input, "stream_id" => "compaction-#{mode}"})
          |> receive_until_terminal([])

        assert Enum.map(frames, & &1["type"]) == ["response.created", "response.output_item.added", "response.output_item.done", "response.completed"]
        assert Enum.all?(frames, &(&1["stream_id"] == "compaction-#{mode}"))
        assert get_in(List.last(frames), ["response", "output", Access.at(0), "type"]) == "compaction"

        # The compaction's turn was finished on its own result: the next turn
        # is answered on the same connection.
        {client, frames} = client |> send_create!(setup, %{"input" => "synthetic next request"}) |> receive_until_terminal([])
        assert [%{"type" => "response.completed", "response" => %{"id" => ^next}}] = frames

        requests = FakeUpstream.requests(upstream)
        assert Enum.map(requests, & &1.method) == ["WEBSOCKET", "WEBSOCKET", "WEBSOCKET"]
        assert requests |> Enum.map(& &1.websocket_connection_id) |> Enum.uniq() |> length() == 1
        assert FakeUpstream.http_request_count(upstream) == 0

        rows = await_settled!(setup.pool.id, 3)
        assert Enum.map(rows, &{&1.endpoint, &1.transport, &1.status}) == List.duplicate({"/v1/responses", "websocket", "succeeded"}, 3)

        for row <- rows do
          assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^row.id and entry.entry_kind == "settlement"), :count) == 1
        end

        if peer, do: assert_peer_owner_served!(peer)
        assert :ok = FakeUpstream.verify!(upstream)
        _client = client
      after
        Mint.HTTP.close(client.conn)
      end
    end
  end

  # The socket forwarded to the peer's owner instead of taking the session
  # over: the peer owner still holds the lease and the provider connection
  # (a public `/v1` turn detaches its downstream when it ends), and no owner of
  # the session runs here.
  defp assert_peer_owner_served!(peer) do
    assert %{upstream_pid: upstream_pid} = :sys.get_state(peer.owner_pid)
    assert is_pid(upstream_pid) and node(upstream_pid) == peer.node
    assert Repo.get!(CodexSession, peer.session.id).owner_instance_id == Atom.to_string(peer.node)
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(peer.session.id)
  end

  defp native_turn(respond, json_expectations) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: 1,
      json: Keyword.merge([valid: true, equals: %{"type" => "response.create"}], json_expectations, fn :equals, base, extra -> Map.merge(base, extra) end),
      respond: respond
    )
  end

  defp completed_frames(response_id, output, done_items \\ []) do
    FakeUpstream.websocket_text_frames(
      Enum.map(done_items, &CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => &1})) ++
        [
          CodexPooler.JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}}
          })
        ]
    )
  end

  defp tool_output_compaction_trigger_input do
    [
      %{"type" => "function_call_output", "call_id" => "call_v1_owner_compaction_delivery", "output" => "synthetic tool output"},
      %{"type" => "compaction_trigger"}
    ]
  end

  # Written before the public socket connects; the peer shares the committed
  # database, so in the two-node arm this row is committed (auto sandbox) and
  # removed with the Pool.
  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
  end

  defp connect!(port, setup, turn_state) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = [{"authorization", setup.authorization}, {"x-codex-turn-state", turn_state}, {"openai-beta", "responses_websockets=2026-02-06"}]
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    %{conn: conn, websocket: websocket, ref: ref}
  end

  defp send_create!(client, setup, attrs) do
    payload = Map.merge(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "stream" => false, "store" => true, "generate" => true}, attrs)
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, CodexPooler.JSON.encode!(payload))
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_until_terminal(client, seen) do
    {conn, websocket, text} = public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    client = %{client | conn: conn, websocket: websocket}
    frame = CodexPooler.JSON.decode!(text)
    seen = [frame | seen]

    if frame["type"] in ["response.completed", "response.failed", "error"],
      do: {client, Enum.reverse(seen)},
      else: receive_until_terminal(client, seen)
  end

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id]))

  # Each response task settles its request after its terminal reached the
  # client; no completion signal reaches the test, so poll the rows.
  defp await_settled!(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(fn -> pool_requests(pool_id) end)
    |> Enum.find(fn rows ->
      settled = length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"]))
      if not settled and System.monotonic_time(:millisecond) >= deadline, do: flunk("requests did not settle")
      settled or (Process.sleep(10) && false)
    end)
  end
end
