defmodule CodexPoolerWeb.V1.ResponsesWebsocketDeliveryReceiptTest do
  # An SDK on the public `GET /v1/responses` websocket closes its socket as soon
  # as the last turn's `response.completed` arrives, while that turn's response
  # task is still settling. The socket then acknowledges the task `aborted` (it
  # never saw the task's result), and the delivery receipt used to reuse that
  # outcome: `aborted terminal_class=response.completed` for a terminal the
  # client had received (openai-node 7.21.0 `ResponsesWS`, production, 2 of 2;
  # findings#225 row 225-240). The native route records `delivered` since
  # findings#225 row 225-130; the public route now does the same. Only the
  # receipt changes.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
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

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @frame_timeout_ms 15_000
  @response_id "resp_public_ws_delivery_receipt"

  for topology <- [:direct, :local_owner] do
    @tag :v1_websocket
    @tag topology: topology
    test "a #{topology} public websocket turn whose completed terminal reached the client before it closed records a delivered receipt", %{topology: topology} do
      if topology == :local_owner, do: enable_owner_forwarding!()
      release_ref = make_ref()
      events = Enum.map(upstream_events(), &CodexPooler.JSON.encode!/1)
      upstream = start_upstream(FakeUpstream.barrier_websocket_frames(events, notify: self(), release_ref: release_ref))
      setup = gateway_setup(upstream)
      assert :ok = Events.subscribe_pool(setup.pool)
      port = start_public_endpoint!()
      {conn, websocket, ref} = public_v1_websocket_connect!(port, setup, topology)

      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => "synthetic public receipt turn", "stream" => true})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      last = length(events) - 1

      for ordinal <- 0..(last - 1) do
        assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @frame_timeout_ms
        assert :ok = FakeUpstream.release_frame(upstream, release_ref)
      end

      assert_receive {:fake_upstream_frame_barrier, ^last, _handler, ^release_ref}, @frame_timeout_ms
      assert :ok = FakeUpstream.release_frame(upstream, release_ref)
      {conn, texts} = receive_until_terminal!(conn, websocket, ref, [])
      assert %{"type" => "response.completed"} = texts |> List.last() |> CodexPooler.JSON.decode!()
      # The SDK closes the moment its last turn completes.
      _closed = Mint.HTTP.close(conn)

      assert_receive {Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @frame_timeout_ms
      assert [attempt] = await_delivery_receipt(setup.pool.id, System.monotonic_time(:millisecond) + @frame_timeout_ms)

      assert %{"outcome" => "delivered", "terminal_class" => "response.completed"} = attempt.response_metadata["downstream_delivery"]
    end
  end

  defp await_delivery_receipt(pool_id, deadline_ms) do
    attempts =
      Repo.all(
        from attempt in Attempt,
          join: request in Request,
          on: request.id == attempt.request_id,
          where: request.pool_id == ^pool_id
      )

    cond do
      attempts != [] and Enum.all?(attempts, &is_map(&1.response_metadata["downstream_delivery"])) ->
        attempts

      System.monotonic_time(:millisecond) >= deadline_ms ->
        attempts

      true ->
        Process.sleep(20)
        await_delivery_receipt(pool_id, deadline_ms)
    end
  end

  defp upstream_events do
    item = %{"id" => "msg_public_ws_receipt", "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}
    part = %{"type" => "output_text", "text" => "", "annotations" => []}
    done_part = %{part | "text" => "synthetic receipt answer"}
    done_item = %{item | "status" => "completed", "content" => [done_part]}
    address = %{"item_id" => "msg_public_ws_receipt", "output_index" => 0, "content_index" => 0}

    [
      %{"type" => "response.created", "response" => response_body("in_progress", [])},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
      Map.merge(address, %{"type" => "response.output_text.delta", "delta" => "synthetic receipt answer"}),
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => done_item},
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

    headers = [
      {"authorization", setup.authorization},
      {"x-codex-turn-state", "public-ws-receipt-#{topology}-#{System.unique_integer([:positive])}"},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref}
  end

  defp enable_owner_forwarding! do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      _logs = capture_log(&stop_registered_owner_sessions/0)

      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)
  end

  defp stop_registered_owner_sessions do
    for session_id <- Registry.select(WebsocketOwnerSession.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        {:ok, pid} <- [WebsocketOwnerSession.lookup(session_id)] do
      GenServer.stop(pid, :normal)
    end
  end
end
