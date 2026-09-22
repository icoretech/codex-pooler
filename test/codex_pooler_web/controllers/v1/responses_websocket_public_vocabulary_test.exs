defmodule CodexPoolerWeb.V1.ResponsesWebsocketPublicVocabularyTest do
  # The public `GET /v1/responses` websocket relays only the public Responses
  # stream vocabulary, like the public SSE relay since findings#225 row 225-97:
  # `response.*` (unknown `response.*` types included), the `error` terminal and
  # `keepalive`. The Codex backend's websocket sends `codex.*` controls and
  # `responsesapi.websocket_timing` next to them; those are backend-internal and
  # are dropped before they take a sequence number, directly and through a
  # local owner (findings#254 row 254-14).
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      await_public_websocket_upgrade: 2,
      decode_public_websocket_data!: 2,
      gateway_setup: 1,
      mint_websocket_new!: 4,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @frame_timeout_ms 15_000
  @response_id "resp_public_ws_vocabulary_fixture"
  @marker "synthetic public websocket vocabulary marker"

  @tag :v1_websocket
  test "the direct public websocket relays only public event types with a contiguous sequence" do
    assert_public_vocabulary!(:direct)
  end

  @tag :v1_websocket
  test "the owner-forwarded public websocket relays only public event types with a contiguous sequence" do
    enable_owner_forwarding!()
    assert_public_vocabulary!(:local_owner)
  end

  defp assert_public_vocabulary!(topology) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames(Enum.map(upstream_events(), &CodexPooler.JSON.encode!/1)))
    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_v1_websocket_connect!(port, setup, topology)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => "synthetic public vocabulary turn", "stream" => true})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, texts} = receive_until_terminal!(conn, websocket, ref, [])

      events = Enum.map(texts, &CodexPooler.JSON.decode!/1)

      assert Enum.map(events, & &1["type"]) == [
               "response.created",
               "response.output_item.added",
               "response.content_part.added",
               "response.output_text.delta",
               "response.output_text.done",
               "response.content_part.done",
               "response.output_item.done",
               "response.future_public_event",
               "response.completed"
             ]

      assert Enum.map(events, & &1["sequence_number"]) == Enum.to_list(0..(length(events) - 1))

      wire = Enum.join(texts)
      refute wire =~ "codex."
      refute wire =~ "responsesapi."
      refute wire =~ "timing_metrics"

      assert_receive {Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @frame_timeout_ms

      if topology == :local_owner, do: assert([_owner_session_id | _rest] = registered_owner_session_ids())

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  defp upstream_events do
    item = %{"id" => "msg_public_ws_vocabulary", "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}
    part = %{"type" => "output_text", "text" => "", "annotations" => []}
    done_part = %{part | "text" => @marker}
    done_item = %{item | "status" => "completed", "content" => [done_part]}
    address = %{"item_id" => "msg_public_ws_vocabulary", "output_index" => 0, "content_index" => 0}

    [
      %{"type" => "response.created", "response" => response_body("in_progress", [])},
      %{"type" => "codex.rate_limits", "rate_limits" => %{}},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
      %{"type" => "codex.response.metadata", "metadata" => %{}},
      Map.merge(address, %{"type" => "response.content_part.added", "part" => part}),
      Map.merge(address, %{"type" => "response.output_text.delta", "delta" => @marker}),
      Map.merge(address, %{"type" => "response.output_text.done", "text" => @marker}),
      Map.merge(address, %{"type" => "response.content_part.done", "part" => done_part}),
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => done_item},
      %{"type" => "responsesapi.websocket_timing", "timing_metrics" => %{"engine_service_total_ms" => 457, "engine_service_ttft_total_ms" => 233}},
      %{"type" => "codex.future_control"},
      %{"type" => "response.future_public_event"},
      %{"type" => "response.completed", "response" => response_body("completed", [done_item])}
    ]
  end

  defp response_body(status, output) do
    %{
      "id" => @response_id,
      "object" => "response",
      "created_at" => 1_790_000_000,
      "model" => "provider-gpt-test-model",
      "status" => status,
      "output" => output,
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
    }
  end

  # Collects every text frame, internal controls included (the shared receive
  # helper skips `codex.*` controls, which is exactly what this test must see).
  defp receive_until_terminal!(conn, websocket, ref, texts) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, new_texts} = decode_texts(websocket, ref, responses)
            texts = texts ++ new_texts

            if Enum.any?(new_texts, &terminal_text?/1),
              do: {conn, texts},
              else: receive_until_terminal!(conn, websocket, ref, texts)

          {:error, _conn, reason, _responses} ->
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            receive_until_terminal!(conn, websocket, ref, texts)
        end
    after
      @frame_timeout_ms -> flunk("timed out waiting for the public terminal; received #{length(texts)} frames")
    end
  end

  defp decode_texts(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {websocket, acc} ->
        case decode_public_websocket_data!(websocket, data) do
          {:ok, websocket, texts} -> {websocket, acc ++ texts}
          {:cont, {:cont, websocket}} -> {websocket, acc}
        end

      _part, acc ->
        acc
    end)
  end

  defp terminal_text?(text) do
    match?({:ok, %{"type" => type}} when type in ["response.completed", "response.failed", "response.incomplete", "error"], CodexPooler.JSON.decode(text))
  end

  defp public_v1_websocket_connect!(port, setup, topology) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    turn_state = "public-ws-vocabulary-#{topology}-#{System.unique_integer([:positive])}"

    headers = [
      {"authorization", setup.authorization},
      {"x-codex-turn-state", turn_state},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref}
  end

  defp registered_owner_session_ids do
    Registry.select(WebsocketOwnerSession.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp enable_owner_forwarding! do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_owner_sessions()

      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)
  end

  defp stop_registered_owner_sessions do
    _logs =
      capture_log(fn ->
        Enum.each(registered_owner_session_ids(), fn codex_session_id ->
          try do
            with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
              _result = GenServer.stop(owner_pid, :shutdown, 1_000)
            end
          catch
            :exit, _reason -> :ok
          end
        end)
      end)

    :ok
  end
end
