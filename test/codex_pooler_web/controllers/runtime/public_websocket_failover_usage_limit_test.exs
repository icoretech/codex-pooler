defmodule CodexPoolerWeb.Runtime.PublicWebsocketFailoverUsageLimitTest do
  # Every candidate refuses a public `/v1/responses` websocket turn with a
  # provider usage limit before any output: the first refusal fails over, the
  # last one is the turn's terminal, the wrapped `429` error event. With owner
  # forwarding on, the socket held that terminal about five seconds after the
  # last refusal while it went out at once with forwarding off, and the socket's
  # delivery receipt read `aborted` with a `response.failed` terminal although
  # the client got the error event (findings#206 row 206-598). When the
  # sibling served the failover instead, the owner-forwarded socket dropped the
  # sibling's frames and the client never got its terminal (row 206-599).
  #
  # One BEAM node, two assignments (the first refuses, the sibling refuses or
  # serves), FakeUpstream websocket; owner forwarding on (local owner) and off;
  # Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Websocket.DeliveryReceipt
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @provider_message "synthetic provider usage limit text"
  @reset_seconds 3_600
  # The terminal goes out right after the last refusal; the defect held it for
  # a fixed five seconds, so this bound separates the two without depending on
  # machine speed.
  @terminal_budget_ms 2_500

  for mode <- ["full", "lite"], forwarding <- [:forwarded, :direct] do
    @mode mode
    @forwarding forwarding

    test "public /v1 websocket #{mode} #{forwarding}: the last candidate's usage limit goes out at once and the receipt names the error event", _context do
      put_owner_forwarding!(@forwarding == :forwarded)
      raise_receipt_log_level!()
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
      pool = pool!(@mode, provider_frame(resets_at))

      {{event, elapsed_ms, receipt}, log} = ExUnit.CaptureLog.with_log([level: :info], fn -> turn_with_receipt!(pool) end)

      CodexPooler.TestDiagnostics.puts(fn -> "206-598 refused #{@mode} #{@forwarding}: #{elapsed_ms} ms #{CodexPooler.JSON.encode!(event)} receipt=#{inspect(receipt)}" end)

      assert %{"type" => "error", "status" => 429} = event
      refute CodexPooler.JSON.encode!(event) =~ @provider_message
      assert FakeUpstream.websocket_connection_count(pool.upstream) == 1
      assert FakeUpstream.websocket_connection_count(pool.sibling_upstream) == 1
      assert elapsed_ms < @terminal_budget_ms, "terminal took #{elapsed_ms} ms after the send"
      assert %{"outcome" => "delivered", "terminal_class" => "error"} = receipt
      assert log =~ ~r/websocket downstream terminal pushed .*outcome=delivered terminal_class=error /
      refute log =~ ~r/websocket downstream terminal pushed .*outcome=aborted/
    end

    # The same failover served by the sibling: the owner-forwarded socket
    # dropped every frame of the second attempt, so the client never got its
    # `response.completed` (row 206-599).
    test "public /v1 websocket #{mode} #{forwarding}: a failover the sibling serves reaches the client", _context do
      put_owner_forwarding!(@forwarding == :forwarded)
      pool = pool!(@mode, served_frames())

      {event, elapsed_ms, receipt} = turn_with_receipt!(pool)

      CodexPooler.TestDiagnostics.puts(fn -> "206-598 served #{@mode} #{@forwarding}: #{elapsed_ms} ms #{CodexPooler.JSON.encode!(event)} receipt=#{inspect(receipt)}" end)

      assert %{"type" => "response.completed", "response" => %{"id" => "resp_failover_served", "status" => "completed"}} = event
      assert FakeUpstream.websocket_connection_count(pool.upstream) == 1
      assert FakeUpstream.websocket_connection_count(pool.sibling_upstream) == 1
      assert elapsed_ms < @terminal_budget_ms, "terminal took #{elapsed_ms} ms after the send"
      assert %{"outcome" => "delivered", "terminal_class" => "response.completed"} = receipt
    end
  end

  defp turn_with_receipt!(pool) do
    {event, elapsed_ms} = public_websocket_turn!(pool)
    {event, elapsed_ms, final_receipt!(pool)}
  end

  defp provider_frame(resets_at) do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 429,
      "error" => %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team", "resets_at" => resets_at, "resets_in_seconds" => @reset_seconds}
    })
  end

  defp served_frames do
    [
      CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "synthetic", "item_id" => "msg_failover_served", "output_index" => 0, "content_index" => 0}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_failover_served", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ]
  end

  # The first candidate refuses with a usage limit; the sibling answers
  # `sibling_frames`.
  defp pool!(mode, sibling_frames) do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    upstream = start_upstream(FakeUpstream.websocket_text_frames([provider_frame(resets_at)]))
    sibling_upstream = start_upstream(FakeUpstream.websocket_text_frames(List.wrap(sibling_frames)))
    setup = gateway_setup(upstream, quota?: false)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-failover-sibling", compact?: false)
    # The refusing account routes first: quota-first routing and more quota
    # left than the sibling.
    use_routing_strategy!(setup.pool, "quota_first", 2)
    prime_routing_quota!(setup.identity, %{used_percent: Decimal.new("10")})
    prime_routing_quota!(sibling.identity, %{used_percent: Decimal.new("90")})
    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])
    setup = %{setup | model: model}
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    Map.merge(setup, %{mode: mode, upstream: upstream, sibling_upstream: sibling_upstream})
  end

  defp public_websocket_turn!(pool) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", pool.authorization},
      {"x-codex-turn-state", "failover-public-#{System.unique_integer([:positive])}"},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => pool.model.exposed_model_id, "input" => "synthetic failover prompt", "stream" => true})
      started = System.monotonic_time(:millisecond)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      event = public_terminal!(conn, websocket, ref)
      {event, System.monotonic_time(:millisecond) - started}
    after
      Mint.HTTP.close(conn)
    end
  end

  defp public_terminal!(conn, websocket, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, texts} =
              Enum.reduce(responses, {websocket, []}, fn
                {:data, ^ref, data}, {websocket, acc} ->
                  case decode_public_websocket_data!(websocket, data) do
                    {:ok, websocket, texts} -> {websocket, acc ++ texts}
                    {:cont, websocket} -> {websocket, acc}
                  end

                _part, acc ->
                  acc
              end)

            case Enum.find(texts, &match?({:ok, %{"type" => type}} when type in ["response.completed", "response.failed", "error"], CodexPooler.JSON.decode(&1))) do
              nil -> public_terminal!(conn, websocket, ref)
              text -> CodexPooler.JSON.decode!(text)
            end

          {:error, _conn, reason, _responses} ->
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            public_terminal!(conn, websocket, ref)
        end
    after
      15_000 -> flunk("timed out waiting for the public terminal")
    end
  end

  # The socket writes the turn's delivery receipt onto its last attempt after
  # it pushed the terminal and the gateway settled the turn.
  defp final_receipt!(pool) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn ->
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: r.id == a.request_id,
          where: r.pool_id == ^pool.pool.id and r.status not in ["accepted", "in_progress"],
          order_by: [desc: a.attempt_number],
          limit: 1,
          select: a.response_metadata
        )
      )
    end)
    |> Enum.reduce_while(nil, fn
      [%{"downstream_delivery" => receipt}], _acc ->
        {:halt, receipt}

      _rows, _acc ->
        if System.monotonic_time(:millisecond) >= deadline, do: {:halt, nil}, else: Process.sleep(10) && {:cont, nil}
    end)
  end

  defp raise_receipt_log_level! do
    :ok = Logger.put_module_level(DeliveryReceipt, :info)
    on_exit(fn -> Logger.delete_module_level(DeliveryReceipt) end)
  end

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end
end
