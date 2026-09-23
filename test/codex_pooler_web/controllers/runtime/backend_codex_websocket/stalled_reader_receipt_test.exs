defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.StalledReaderReceiptTest do
  # A native websocket client that stops reading in the middle of a large turn
  # (findings#232 row 232-256, measured by P42 on a real listener: 70 of 4005
  # frames reached the peer, the connection closed after the 30 s send timeout,
  # yet the receipt read `delivered response.completed frames_after_visible=4005`
  # because Bandit discards the result of every pushed frame's write). The resend
  # of that turn was then refused as a delivered one. The receipt now records
  # only what was written before the first failed write: `aborted`, no terminal,
  # the frames and class written before it and a fixed-vocabulary
  # `write_failure`, so the released client's identical resend is admitted as
  # one successor. A client that did read the terminal keeps its `delivered`
  # receipt, even when its connection then dies abruptly, and its resend stays a
  # duplicate.
  #
  # Real listener and real owner (forwarding on) or direct task (forwarding
  # off). The listener's own send timeout and send buffer are shortened
  # (production keeps ThousandIsland's 30 s default) and the client's receive
  # buffer is shrunk, so the stall shows within a second.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_send_text!: 4, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, stop_registered_websocket_owner_sessions: 0]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @timeout_ms 15_000
  @poll_ms 100
  # A stalled write fails after this long on the test listener instead of
  # ThousandIsland's 30 s default.
  @send_timeout_ms 300
  @buffer_bytes 4_096
  # About 1 MB of deltas: far more than the shrunk socket buffers hold, so the
  # listener's write blocks once the client stops reading.
  @deltas 128
  @delta_bytes 8_192
  # created, in_progress, output_item.added, content_part.added, deltas,
  # output_text.done, content_part.done, output_item.done, completed
  @total_frames @deltas + 8

  for forwarding <- [true, false] do
    @tag forwarding: forwarding
    @tag slow: "a real listener write that has to time out after the client stopped reading, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: a client that stopped reading mid-turn gets an aborted receipt and its identical resend is served", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding)
      # The client sends its turn and never reads again, without closing (a
      # frozen client, or a proxy whose own client stopped reading).
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      :ok = :inet.setopts(Mint.HTTP.get_socket(conn), recbuf: @buffer_bytes)
      {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

      %Request{id: request_id} = await_request!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
      receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
      # Everything the listener managed to write is still in the connection:
      # the client reads it all now, up to the close that followed the failure.
      {_conn, received} = read_text_frames!(conn, websocket, ref, :close)
      _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "delta", "write_failure" => "timeout", "pushed_at" => nil} = receipt
      refute Map.has_key?(receipt, "completed_items")
      # The receipt counts exactly the frames the client could read.
      counted = Enum.reject(received, &StreamProtocol.internal_control_event?/1)
      assert receipt["frames_after_visible"] == length(counted)
      assert length(counted) < @total_frames
      assert counted |> List.last() |> CodexPooler.JSON.decode!() |> Map.fetch!("type") == "response.output_text.delta"

      resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2
    end

    # The production shape of the same stall: the client stops reading, the
    # listener's write blocks on the full connection (the default 30 s send
    # timeout is kept), and the connection is then reset (the client, or a
    # proxy in front of the Pooler, drops it). The blocked write fails at once,
    # so the released client's reconnect resend arrives well inside the 30 s
    # client-retry window, which a resend after a 30 s send timeout never does.
    @tag forwarding: forwarding
    test "owner forwarding #{forwarding}: a client dropped while the listener's write is blocked gets an aborted receipt and its identical resend is served", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding, send_timeout: :default)
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      :ok = :inet.setopts(Mint.HTTP.get_socket(conn), recbuf: @buffer_bytes)
      {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
      {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

      %Request{id: request_id} = await_request!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
      :ok = await_blocked_listener_write!(conn, System.monotonic_time(:millisecond) + @timeout_ms)
      # A reset, not a close handshake.
      :ok = :inet.setopts(Mint.HTTP.get_socket(conn), linger: {true, 0})
      _closed = Mint.HTTP.close(conn)

      receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
      _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "delta", "pushed_at" => nil} = receipt
      assert receipt["write_failure"] in ["closed", "other"]
      assert receipt["frames_after_visible"] < @total_frames

      resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert FakeUpstream.count(upstream) == 2
    end

    # The other direction: the client read the whole turn, terminal included,
    # and its connection then died without a close handshake. The receipt stays
    # `delivered` and names no write failure, so the resend (which the released
    # client would not send, having seen the terminal) is still a duplicate:
    # no second generation for a turn the client received.
    @tag forwarding: forwarding
    test "owner forwarding #{forwarding}: a client that read the terminal and then dropped its connection keeps a delivered receipt", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding)
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
      {conn, received} = read_text_frames!(conn, websocket, ref, :terminal)
      assert received |> List.last() |> CodexPooler.JSON.decode!() |> Map.fetch!("type") == "response.completed"
      # A reset, not a close handshake: the connection just dies.
      :ok = :inet.setopts(Mint.HTTP.get_socket(conn), linger: {true, 0})
      _closed = Mint.HTTP.close(conn)

      assert [%Request{id: request_id}] = pool_requests(setup.pool.id)
      receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
      _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"outcome" => "delivered", "terminal_class" => "response.completed", "highest_frame_class" => "terminal", "frames_after_visible" => @total_frames} = receipt
      refute Map.has_key?(receipt, "write_failure")

      resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = resend
      assert [%Request{id: ^request_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert Repo.all(RequestClientRetryLink) == []
      assert FakeUpstream.count(upstream) == 1
    end
  end

  defp scenario!(forwarding, opts \\ []) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)
    if forwarding, do: on_exit(&stop_registered_websocket_owner_sessions/0)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(stream_frames("resp_stalled_original"))),
          native_request(FakeUpstream.websocket_text_frames(stream_frames("resp_stalled_successor")))
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    raw_payload = CodexPooler.JSON.encode!(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id))
    port = start_stalling_endpoint!(Keyword.get(opts, :send_timeout, @send_timeout_ms))
    %{setup: setup, upstream: upstream, port: port, turn_state: Ecto.UUID.generate(), raw_payload: raw_payload}
  end

  # The shared helper's listener with a small send buffer and, unless
  # `:default`, a short send timeout; the client side's receive buffer is
  # shrunk after the connect.
  defp start_stalling_endpoint!(send_timeout) do
    :ok = WebsocketCleanupFence.install!()
    transport_options = if send_timeout == :default, do: [sndbuf: @buffer_bytes], else: [send_timeout: send_timeout, sndbuf: @buffer_bytes]

    {:ok, server} =
      Bandit.start_link(
        plug: CodexPoolerWeb.Endpoint,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false,
        thousand_island_options: [transport_options: transport_options]
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _reason -> :ok
      end
    end)

    :ok = WebsocketCleanupFence.install!(server: server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # The listener's side of this connection has data queued in its port that
  # the full connection does not take: its writer is blocked.
  defp await_blocked_listener_write!(conn, deadline_ms) do
    {:ok, client_address} = :inet.sockname(Mint.HTTP.get_socket(conn))
    await_blocked_port!(client_address, deadline_ms)
  end

  defp await_blocked_port!(client_address, deadline_ms) do
    blocked? =
      Enum.any?(Port.list(), fn port ->
        Port.info(port, :name) == {:name, ~c"tcp_inet"} and :inet.peername(port) == {:ok, client_address} and
          match?({:queue_size, size} when size > 0, :erlang.port_info(port, :queue_size))
      end)

    cond do
      blocked? -> :ok
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("the listener's write never blocked")
      true -> Process.sleep(10) && await_blocked_port!(client_address, deadline_ms)
    end
  end

  defp assert_one_settlement_each!(request_ids) do
    for id <- request_ids do
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^id and l.amount_status == "recorded", select: l.entry_kind)) |> Enum.frequencies() ==
               %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end
  end

  defp native_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp stream_frames(response_id) do
    item_id = "msg_" <> response_id
    chunk = String.duplicate("a", @delta_bytes)
    text = String.duplicate(chunk, 2)
    item = %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}},
        %{"type" => "response.content_part.added", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => "", "annotations" => []}}
      ] ++
        for(_delta <- 1..@deltas, do: %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => chunk}) ++
        [
          %{"type" => "response.output_text.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "text" => text},
          %{"type" => "response.content_part.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => text, "annotations" => []}},
          %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
          %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
        ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp native_turn_payload(thread_id, model) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => "stalled-reader-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "stalled-reader-turn", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100,
        "ws_request_header_x_openai_internal_codex_responses_lite" => "true"
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic stalled reader turn"}]}]
    }
  end

  defp send_and_receive_terminal!(port, setup, turn_state, raw_payload) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    {conn, received} = read_text_frames!(conn, websocket, ref, :terminal)
    _closed = Mint.HTTP.close(conn)
    received |> Enum.find(&terminal_text?/1) |> CodexPooler.JSON.decode!()
  end

  # Reads the passive connection's complete text frames, in order, up to the
  # turn's terminal or up to the listener's close (a partly written frame at
  # the end stays undecoded). The large frames of this turn are decoded here
  # rather than through the shared receive helper.
  defp read_text_frames!(conn, websocket, ref, until, acc \\ []) do
    case Mint.WebSocket.recv(conn, 0, @timeout_ms) do
      {:ok, conn, responses} ->
        {websocket, texts} = decode_texts!(websocket, ref, responses)
        acc = acc ++ texts

        if until == :terminal and Enum.any?(texts, &terminal_text?/1),
          do: {conn, acc},
          else: read_text_frames!(conn, websocket, ref, until, acc)

      {:error, conn, closed, responses} when until == :close and closed in [:closed, %Mint.TransportError{reason: :closed}] ->
        {_websocket, texts} = decode_texts!(websocket, ref, responses)
        _closed = Mint.HTTP.close(conn)
        {conn, acc ++ texts}
    end
  end

  defp terminal_text?(text), do: CodexPooler.JSON.decode!(text)["type"] in ["response.completed", "response.failed", "response.incomplete", "error"]

  defp decode_texts!(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {websocket, texts} ->
        {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
        {websocket, texts ++ for({:text, text} <- frames, do: text)}

      _other, acc ->
        acc
    end)
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  defp await_receipt!(request_id, deadline_ms) do
    case safe_all(from(a in Attempt, where: a.request_id == ^request_id)) do
      [%Attempt{response_metadata: %{"downstream_delivery" => %{} = receipt}}] ->
        receipt

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("no delivery receipt for #{request_id} within the budget"),
          else: Process.sleep(@poll_ms) && await_receipt!(request_id, deadline_ms)
    end
  end

  defp await_request!(pool_id, deadline_ms) do
    case safe_all(from(r in Request, where: r.pool_id == ^pool_id)) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("the turn was never admitted"),
          else: Process.sleep(@poll_ms) && await_request!(pool_id, deadline_ms)
    end
  end

  defp await_settled!(request_id, deadline_ms) do
    case safe_all(from(r in Request, where: r.id == ^request_id and r.status != "in_progress")) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("request never settled"),
          else: Process.sleep(@poll_ms) && await_settled!(request_id, deadline_ms)
    end
  end

  defp await_all_settled!(pool_id, deadline_ms) do
    requests = safe_all(from(r in Request, where: r.pool_id == ^pool_id))

    cond do
      requests != [] and Enum.all?(requests, &(&1.status != "in_progress")) -> :ok
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("requests never settled")
      true -> Process.sleep(@poll_ms) && await_all_settled!(pool_id, deadline_ms)
    end
  end

  defp safe_all(query) do
    Repo.all(query)
  rescue
    DBConnection.ConnectionError -> []
  end
end
