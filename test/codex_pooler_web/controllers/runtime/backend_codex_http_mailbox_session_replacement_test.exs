defmodule CodexPoolerWeb.Runtime.BackendCodexHttpMailboxSessionReplacementTest do
  # A root agent's opening turn streams a commentary note, then waits on its
  # subagents. The client drops the stream when a subagent mail arrives and
  # resends the turn with the delivered note and the mail appended. When the
  # owner lease of the codex session lapsed meanwhile, the start path closes
  # that session and opens a replacement under the same session key, so the
  # resend reaches the predecessor from another codex session.
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      gateway_setup: 2,
      native_text_input: 1,
      public_websocket_connect_with_request_headers!: 5,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      register_unboxed_pool_cleanup!: 1,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @path "/backend-api/codex/responses"
  @budget 15_000

  setup context do
    CodexPooler.DataCase.stop_sandbox(context.sandbox_owner, context.sandbox_settings_cache)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok = Sandbox.mode(Repo, :auto)
  end

  describe "native HTTP opening turn resent with a subagent mail" do
    for engaged? <- [false, true] do
      @tag engaged?: engaged?
      test "is admitted in the same codex session (engaged session #{engaged?})", %{engaged?: engaged?} do
        run = run_http(engaged?: engaged?, lapse?: false, successor: :mailbox)

        assert run.status == 200, run.body
        assert [_ | _] = run.rows
        assert {"succeeded", session_id, "succeeded"} = last_row(run.rows)
        assert session_id == run.predecessor_session_id
      end

      @tag engaged?: engaged?
      test "is admitted after the lapsed codex session was replaced (engaged session #{engaged?})", %{engaged?: engaged?} do
        run = run_http(engaged?: engaged?, lapse?: true, successor: :mailbox)

        assert run.status == 200, run.body
        assert {"succeeded", session_id, "succeeded"} = last_row(run.rows)
        assert session_id != run.predecessor_session_id
        assert %CodexSession{status: "closed"} = Repo.get!(CodexSession, run.predecessor_session_id)
        assert %CodexSession{status: status} = Repo.get!(CodexSession, session_id)
        assert CodexSession.reconnectable?(status)
      end
    end

    test "keeps the duplicate_turn fence for an identical resend into the replacement session" do
      run = run_http(engaged?: false, lapse?: true, successor: :identical)

      assert run.status == 409, run.body
      assert run.body =~ "duplicate_turn"
    end

    test "keeps the duplicate_turn fence when the resent note differs from the delivered one" do
      run = run_http(engaged?: false, lapse?: true, successor: :rewritten)

      assert run.status == 409, run.body
      assert run.body =~ "duplicate_turn"
    end
  end

  describe "native websocket opening turn resent with a subagent mail" do
    for lapse? <- [false, true] do
      @tag lapse?: lapse?
      test "is admitted on a new connection (lease lapsed #{lapse?})", %{lapse?: lapse?} do
        gate = make_ref()

        upstream =
          start_upstream(
            FakeUpstream.strict_sequence([
              FakeUpstream.delayed_terminal_sse_stream(commentary_frames(), completed("resp_synthetic_predecessor"), notify: self(), release_ref: gate),
              FakeUpstream.sse_stream([{"response.completed", completed("resp_synthetic_successor")}])
            ])
          )

        setup = gateway_setup(upstream, [])
        register_unboxed_pool_cleanup!(setup)
        port = start_public_endpoint!()
        thread = Ecto.UUID.generate()
        turn_state = "synthetic-turn-state-" <> Ecto.UUID.generate()
        input = native_text_input("synthetic")

        {conn, ws, ref} = websocket_connect!(port, setup, thread, turn_state)
        {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(websocket_payload(setup, thread, input)))
        assert_receive {:fake_upstream_timeout_barrier, :before_terminal, handler, ^gate}, @budget
        {conn, _ws, types} = receive_types!(conn, ws, ref, 3)
        assert types == ["response.created", "response.output_item.added", "response.output_item.done"]
        _closed = Mint.HTTP.close(conn)
        send(handler, {:fake_upstream_release_timeout, gate})

        predecessor = await_settled!(setup, System.monotonic_time(:millisecond) + @budget)
        predecessor_turn = Repo.get_by!(CodexTurn, request_id: predecessor.id)
        if lapse?, do: lapse_lease!(predecessor_turn.codex_session_id)

        {conn, ws, ref} = websocket_connect!(port, setup, thread, turn_state)
        successor = websocket_payload(setup, thread, input ++ [client_item(commentary()), mail()])
        {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(successor))
        {conn, _ws, text} = receive_terminal!(conn, ws, ref)
        _closed = Mint.HTTP.close(conn)

        assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(text), text
      end
    end
  end

  defp run_http(opts) do
    engaged? = Keyword.fetch!(opts, :engaged?)
    gate = make_ref()

    chunk =
      Enum.map_join(commentary_frames(), &event/1)

    tail = event(%{"type" => "response.reasoning_text.delta", "delta" => "synthetic"})
    earlier = FakeUpstream.sse_stream(Enum.map(earlier_frames(), &{&1["type"], &1}))
    terminal = FakeUpstream.sse_stream([{"response.completed", completed("resp_synthetic_successor")}])
    opening = {:gated_terminal_sse, [chunk], [tail], self(), gate}
    upstream = start_upstream(FakeUpstream.strict_sequence(if(engaged?, do: [earlier, opening, terminal], else: [opening, terminal])))
    setup = gateway_setup(upstream, compact?: true)
    register_unboxed_pool_cleanup!(setup)
    setup = Map.put(setup, :turn_state, "synthetic-turn-state-" <> Ecto.UUID.generate())
    port = start_public_endpoint!()
    thread = Ecto.UUID.generate()

    input =
      if engaged? do
        history = native_text_input("synthetic earlier")
        {200, _body} = post_turn(port, setup, payload(setup, thread, history, "synthetic_turn_1"))
        _earlier = await_settled!(setup, System.monotonic_time(:millisecond) + @budget)
        history ++ [client_item(earlier_note())] ++ native_text_input("synthetic")
      else
        native_text_input("synthetic")
      end

    opening_payload = payload(setup, thread, input, "synthetic_turn_2")
    {conn, ref} = start_request(port, setup, opening_payload)
    conn = until_item_done(conn, ref, "")
    assert_receive {:fake_upstream_gate, :before_terminal, handler, ^gate}, @budget
    :ok = :inet.setopts(Mint.HTTP.get_socket(conn), linger: {true, 0})
    Mint.HTTP.close(conn)
    send(handler, {:fake_upstream_release_gate, gate})

    predecessor = await_settled!(setup, System.monotonic_time(:millisecond) + @budget)
    assert {predecessor.status, predecessor.last_error_code} == {"failed", "client_disconnected"}
    predecessor_session_id = Repo.get_by!(CodexTurn, request_id: predecessor.id).codex_session_id
    if Keyword.fetch!(opts, :lapse?), do: lapse_lease!(predecessor_session_id)

    successor =
      case Keyword.fetch!(opts, :successor) do
        :mailbox -> Map.put(opening_payload, "input", input ++ [client_item(commentary()), mail()])
        :identical -> opening_payload
        :rewritten -> Map.put(opening_payload, "input", input ++ [client_item(commentary("Synthetic rewritten note.")), mail()])
      end

    {status, body} = post_turn(port, setup, successor)

    rows =
      Repo.all(
        from(request in Request,
          join: turn in CodexTurn,
          on: turn.request_id == request.id,
          where: request.pool_id == ^setup.pool.id,
          order_by: [asc: request.admitted_at],
          select: {request.status, turn.codex_session_id, turn.status}
        )
      )

    %{status: status, body: body, rows: rows, predecessor_session_id: predecessor_session_id}
  end

  defp last_row(rows), do: List.last(rows)

  # The heartbeat renews the lease while the stream runs; a client that waits
  # on its subagents longer than the lease TTL finds it expired.
  defp lapse_lease!(session_id) do
    CodexSession
    |> Repo.get!(session_id)
    |> Ecto.Changeset.change(owner_lease_expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond))
    |> Repo.update!()
  end

  defp commentary(text \\ "Synthetic progress note.") do
    %{
      "type" => "message",
      "id" => "msg_synthetic_note",
      "status" => "completed",
      "role" => "assistant",
      "phase" => "commentary",
      "content" => [%{"type" => "output_text", "annotations" => [], "logprobs" => [], "text" => text}]
    }
  end

  defp earlier_note do
    %{
      "type" => "message",
      "id" => "msg_synthetic_earlier",
      "status" => "completed",
      "role" => "assistant",
      "phase" => "final_answer",
      "content" => [%{"type" => "output_text", "annotations" => [], "logprobs" => [], "text" => "Synthetic earlier answer."}]
    }
  end

  defp mail do
    %{"type" => "agent_message", "id" => "amsg_synthetic_1", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic update"}]}
  end

  # Codex keeps id, role, content type and text, and phase of a completed
  # assistant message.
  defp client_item(%{"type" => "message"} = item) do
    item
    |> Map.drop(["status"])
    |> Map.update!("content", fn parts -> Enum.map(parts, &Map.take(&1, ["type", "text"])) end)
  end

  defp commentary_frames do
    note = commentary()

    [
      %{"type" => "response.created", "response" => %{"id" => "resp_synthetic_predecessor", "status" => "in_progress", "output" => []}},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.merge(note, %{"status" => "in_progress", "content" => []})},
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => note}
    ]
  end

  defp earlier_frames do
    note = earlier_note()

    [
      %{"type" => "response.created", "response" => %{"id" => "resp_synthetic_earlier", "status" => "in_progress", "output" => []}},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.merge(note, %{"status" => "in_progress", "content" => []})},
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => note},
      completed("resp_synthetic_earlier")
    ]
  end

  defp completed(id),
    do: %{"type" => "response.completed", "response" => %{"id" => id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 10, "output_tokens" => 1, "total_tokens" => 11}}}

  defp turn_metadata(thread, turn_id),
    do: encode(%{"thread_id" => thread, "session_id" => thread, "turn_id" => turn_id, "request_kind" => "turn", "agent_name" => "/root", "window_id" => "#{thread}:0", "window_number" => 0})

  defp payload(setup, thread, input, turn_id) do
    metadata = %{"x-codex-turn-metadata" => turn_metadata(thread, turn_id), "x-codex-turn-state" => setup.turn_state}
    %{"model" => setup.model.exposed_model_id, "input" => input, "stream" => true, "store" => false, "client_metadata" => metadata}
  end

  defp websocket_payload(setup, thread, input) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "stream" => true,
      "store" => false,
      "client_metadata" => %{"x-codex-window-id" => "#{thread}:0", "x-codex-turn-metadata" => turn_metadata(thread, "synthetic_turn_2")},
      "input" => input
    }
  end

  defp event(data), do: "event: #{data["type"]}\ndata: " <> encode(data) <> "\n\n"
  defp encode(map), do: CodexPooler.JSON.encode!(map)

  defp websocket_connect!(port, setup, thread, turn_state) do
    headers = [{"session-id", thread}, {"thread-id", thread}, {"x-codex-window-id", "#{thread}:0"}, {"x-codex-turn-metadata", turn_metadata(thread, "synthetic_turn_2")}]
    {conn, ws, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, turn_state, @path, headers)
    {conn, ws, ref}
  end

  defp receive_types!(conn, ws, ref, count) do
    Enum.reduce(1..count, {conn, ws, []}, fn _index, {conn, ws, types} ->
      {conn, ws, text} = public_websocket_receive_text!(conn, ws, ref)
      {conn, ws, types ++ [CodexPooler.JSON.decode!(text)["type"]]}
    end)
  end

  defp receive_terminal!(conn, ws, ref) do
    {conn, ws, text} = public_websocket_receive_text!(conn, ws, ref)

    if CodexPooler.JSON.decode!(text)["type"] in ["response.completed", "response.failed", "error"],
      do: {conn, ws, text},
      else: receive_terminal!(conn, ws, ref)
  end

  defp start_request(port, setup, payload) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)
    on_exit(fn -> Mint.HTTP.close(conn) end)
    metadata = payload["client_metadata"]["x-codex-turn-metadata"]
    thread = CodexPooler.JSON.decode!(metadata)["thread_id"]

    headers = [
      {"authorization", setup.authorization},
      {"content-type", "application/json"},
      {"session-id", thread},
      {"thread-id", thread},
      {"x-codex-window-id", "#{thread}:0"},
      {"x-codex-turn-metadata", metadata},
      {"x-codex-turn-state", setup.turn_state},
      {"originator", "codex_cli_rs"}
    ]

    {:ok, conn, ref} = Mint.HTTP.request(conn, "POST", @path, headers, encode(payload))
    {conn, ref}
  end

  defp until_item_done(conn, ref, acc) do
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @budget)

    bytes =
      Enum.reduce(responses, acc, fn
        {:data, ^ref, data}, bytes -> bytes <> data
        _response, bytes -> bytes
      end)

    if String.contains?(bytes, "event: response.output_item.done"), do: conn, else: until_item_done(conn, ref, bytes)
  end

  defp post_turn(port, setup, payload) do
    {conn, ref} = start_request(port, setup, payload)

    try do
      read_all(conn, ref, nil, "")
    after
      Mint.HTTP.close(conn)
    end
  end

  defp read_all(conn, ref, status, body) do
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @budget)

    {status, body, done?} =
      Enum.reduce(responses, {status, body, false}, fn
        {:status, ^ref, status}, {_status, body, done?} -> {status, body, done?}
        {:data, ^ref, data}, {status, body, done?} -> {status, body <> data, done?}
        {:done, ^ref}, {status, body, _done?} -> {status, body, true}
        _response, acc -> acc
      end)

    if done?, do: {status, body}, else: read_all(conn, ref, status, body)
  end

  defp await_settled!(setup, deadline) do
    row = Repo.one(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [desc: request.admitted_at], limit: 1))

    cond do
      row && row.completed_at ->
        row

      System.monotonic_time(:millisecond) > deadline ->
        flunk("request never finalized")

      true ->
        Process.sleep(10)
        await_settled!(setup, deadline)
    end
  end
end
