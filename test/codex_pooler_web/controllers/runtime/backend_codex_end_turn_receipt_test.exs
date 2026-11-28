defmodule CodexPoolerWeb.Runtime.BackendCodexEndTurnReceiptTest do
  # A native Codex client re-samples a turn whose `response.completed` carried `response.end_turn == false`; the
  # request that follows is refused as `duplicate_turn` on HTTP SSE today (findings#311). Whether providers send the
  # field on tool-free responses is not known, and a direct probe could not settle it, so the delivery receipt of a
  # pushed `response.completed` now names the class the provider sent (`true`, `false` or `absent`) and the question
  # is answered from attempt rows. Provenance: the field and the client reading are source-derived (codex-rs
  # `ResponseCompleted.end_turn`); the event sequences, ids and texts are synthetic.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      native_text_input: 1,
      public_websocket_connect_with_request_headers!: 5,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @path "/backend-api/codex/responses"
  @prompt_sentinel "end-turn-receipt-prompt-sentinel"
  @delta_sentinel "end-turn-receipt-delta-sentinel"
  @input_transformations [
    %{"type" => "reasoning", "id" => "rs_fixture_first", "action" => "removed", "reason" => "prefix_mismatch"},
    %{"type" => "reasoning", "id" => "rs_fixture_second", "action" => "removed", "reason" => "prefix_mismatch"}
  ]
  @arms [{"true", true}, {"false", false}, {"absent", :absent}]
  @moduletag capture_log: true

  for mode <- ["full", "lite"], {class, value} <- [{"true", true}, {"false", false}, {"absent", :absent}] do
    test "#{mode} HTTP SSE: end_turn #{class} on the provider completion is recorded as #{class} in the delivery receipt" do
      upstream = start_upstream(FakeUpstream.sse_stream(events("resp_end_turn_http", unquote(value)), done: false))
      setup = serving_setup(upstream, unquote(mode))

      {conn, logs} = with_info_log(fn -> post_native(setup, unquote(mode)) end)

      assert conn.status == 200
      assert conn.resp_body =~ ~s("type":"response.completed")

      {request, attempt} = settled_rows(setup)
      assert request.status == "succeeded"
      assert request.transport == "http_sse"

      assert %{"end_turn" => unquote(class), "terminal_class" => "response.completed", "outcome" => "delivered", "transport" => "http_sse"} = receipt = attempt.response_metadata["downstream_delivery"]
      assert Enum.sort(Map.keys(receipt)) == ~w(end_turn frames_after_visible outcome pushed_at terminal_class transport)
      assert logs =~ ~r/http_sse downstream terminal pushed request_id=#{request.id} .*frames_after_visible=\d+ end_turn=#{unquote(class)}$/m
      assert_metadata_only!(request, attempt, logs)
    end
  end

  test "HTTP SSE: a provider failure after output carries no end_turn class, whatever the failed response held" do
    failed = {"response.failed", %{"type" => "response.failed", "response" => %{"id" => "resp_end_turn_failed", "status" => "failed", "end_turn" => false, "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}}}
    upstream = start_upstream(FakeUpstream.sse_stream([created("resp_end_turn_failed"), delta(), failed], done: false))
    setup = gateway_setup(upstream)

    {conn, logs} = with_info_log(fn -> post_native(setup, "full") end)

    assert conn.status == 200
    {request, attempt} = settled_rows(setup)
    assert attempt.status == "failed"
    assert %{"terminal_class" => "response.failed"} = receipt = attempt.response_metadata["downstream_delivery"]
    refute Map.has_key?(receipt, "end_turn")
    refute logs =~ "end_turn="
    assert_metadata_only!(request, attempt, logs)
  end

  for mode <- ["full", "lite"], owner? <- [false, true] do
    test "#{mode} native websocket, owner forwarding #{owner?}: completions relay ordered input transformations and record the end_turn class" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(owner?))
      turns = Enum.map(@arms, fn {class, value} -> {class, FakeUpstream.websocket_text_frames(Enum.map(events("resp_end_turn_ws_#{class}", value), &frame/1))} end)
      upstream = start_upstream(FakeUpstream.strict_sequence(Enum.map(turns, &elem(&1, 1))))
      setup = serving_setup(upstream, unquote(mode))
      thread = Ecto.UUID.generate()
      headers = [{"session-id", thread}, {"thread-id", thread}, {"x-codex-window-id", "#{thread}:0"}]
      headers = if unquote(mode) == "lite", do: headers ++ [{"x-openai-internal-codex-responses-lite", "true"}], else: headers
      port = start_public_endpoint!()
      {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), @path, headers)
      on_exit(fn -> Mint.HTTP.close(conn) end)

      {conn, _websocket} =
        Enum.reduce(Enum.with_index(@arms, 1), {conn, websocket}, fn {{class, _value}, ordinal}, {conn, websocket} ->
          {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(turn_frame(setup, thread, class)))
          {conn, websocket, terminal} = receive_terminal(conn, websocket, ref)
          assert %{"type" => "response.completed", "response" => %{"id" => id, "input_transformations" => @input_transformations}} = terminal
          assert id == "resp_end_turn_ws_#{class}"
          assert length(await_receipts(setup, ordinal)) == ordinal
          {conn, websocket}
        end)

      Mint.HTTP.close(conn)
      attempts = await_receipts(setup, length(@arms))

      assert Enum.map(attempts, & &1.response_metadata["downstream_delivery"]["end_turn"]) == Enum.map(@arms, &elem(&1, 0))

      for attempt <- attempts do
        receipt = attempt.response_metadata["downstream_delivery"]
        assert %{"outcome" => "delivered", "terminal_class" => "response.completed", "transport" => "websocket"} = receipt
        assert Enum.sort(Map.keys(receipt)) == ~w(end_turn frames_after_visible highest_frame_class outcome pushed_at terminal_class transport)
        refute inspect(attempt.response_metadata) =~ @delta_sentinel
        refute Map.has_key?(attempt.response_metadata, "input_transformations")
      end
    end
  end

  test "websocket: a failed provider terminal carries no end_turn class" do
    failed = %{"type" => "response.failed", "response" => %{"id" => "resp_end_turn_ws_failed", "status" => "failed", "end_turn" => false, "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}}
    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame(created("resp_end_turn_ws_failed")), frame(delta()), CodexPooler.JSON.encode!(failed)]))
    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), @path, [])
    on_exit(fn -> Mint.HTTP.close(conn) end)

    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(turn_frame(setup, Ecto.UUID.generate(), "failed")))
    {conn, _websocket, terminal} = receive_terminal(conn, websocket, ref)
    assert terminal["type"] == "response.failed"
    Mint.HTTP.close(conn)

    assert [attempt] = await_receipts(setup, 1)
    assert %{"terminal_class" => "response.failed"} = receipt = attempt.response_metadata["downstream_delivery"]
    refute Map.has_key?(receipt, "end_turn")
  end

  defp serving_setup(upstream, mode) do
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    setup
  end

  defp post_native(setup, mode) do
    conn = build_conn() |> auth(setup)
    conn = if mode == "lite", do: put_req_header(conn, "x-openai-internal-codex-responses-lite", "true"), else: conn
    post(conn, @path, %{"model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true})
  end

  defp turn_frame(setup, thread, label) do
    metadata = CodexPooler.JSON.encode!(%{"thread_id" => thread, "session_id" => thread, "turn_id" => "synthetic_turn_#{label}", "request_kind" => "turn", "agent_name" => "/root", "window_id" => "#{thread}:0", "window_number" => 0})

    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("#{@prompt_sentinel} #{label}"),
      "stream" => true,
      "store" => false,
      "client_metadata" => %{"x-codex-turn-metadata" => metadata, "thread_id" => thread, "turn_id" => "synthetic_turn_#{label}", "x-codex-window-id" => "#{thread}:0"}
    }
  end

  defp receive_terminal(conn, websocket, ref, seen \\ 0) when seen < 12 do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    event = CodexPooler.JSON.decode!(text)

    if event["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, websocket, event},
      else: receive_terminal(conn, websocket, ref, seen + 1)
  end

  # Websocket receipts are merged after the turn settled, so the rows are polled until each attempt carries one.
  defp await_receipts(setup, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    attempts =
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: r.id == a.request_id,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: a.started_at, asc: a.attempt_number]
        )
      )

    cond do
      length(attempts) == expected and Enum.all?(attempts, &is_map(&1.response_metadata["downstream_delivery"])) ->
        attempts

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{expected} attempts with a delivery receipt, got #{inspect(Enum.map(attempts, &Map.keys(&1.response_metadata || %{})))}")

      true ->
        receive do
        after
          20 -> await_receipts(setup, expected, deadline)
        end
    end
  end

  defp settled_rows(setup) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    {request, attempt}
  end

  defp assert_metadata_only!(request, attempt, logs) do
    persisted = inspect({request.request_metadata, attempt.response_metadata})

    for sentinel <- [@prompt_sentinel, @delta_sentinel] do
      refute persisted =~ sentinel
      refute logs =~ sentinel
    end
  end

  defp events(response_id, end_turn), do: [created(response_id), delta(), completed(response_id, end_turn)]

  defp created(response_id), do: {"response.created", %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}}

  defp delta, do: {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => @delta_sentinel}}

  defp completed(response_id, end_turn) do
    response = %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}
    response = if end_turn == :absent, do: response, else: Map.put(response, "end_turn", end_turn)
    {"response.completed", %{"type" => "response.completed", "response" => response}}
  end

  defp frame({"response.completed", payload}) do
    payload
    |> put_in(["response", "input_transformations"], @input_transformations)
    |> CodexPooler.JSON.encode!()
  end

  defp frame({_type, payload}), do: CodexPooler.JSON.encode!(payload)
end
