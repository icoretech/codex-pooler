defmodule CodexPoolerWeb.V1.ResponsesWebsocketUsageLimitTest do
  # The public `GET /v1/responses` websocket answers an all-exhausted Pool with
  # the same terminal refusal as HTTP and the native websocket (findings#206
  # rows 206-508, 206-530): one `{"type": "error", "status": 429, ...}` event
  # whose error carries `usage_limit_reached`, the Pooler's code and message,
  # `resets_at` and `resets_in_seconds`, and whose `headers` carry the
  # `retry-after` an HTTP client reads from the response.
  #
  # One BEAM node, two exhausted assignments, FakeUpstream never dispatched to;
  # direct socket and local owner forwarding; Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @frame_timeout_ms 15_000
  @message "upstream quota is exhausted until its reset time"
  @early_reset_seconds 900
  @late_reset_seconds 1_800

  for mode <- ["full", "lite"], topology <- [:direct, :local_owner] do
    @mode mode
    @topology topology

    test "public websocket #{topology} #{mode}: an all-exhausted Pool answers the wrapped 429 usage_limit_reached with retry-after", _context do
      if @topology == :local_owner, do: put_owner_forwarding!(true)
      pool = exhausted_pool!(@mode, [@late_reset_seconds, @early_reset_seconds])

      event = public_websocket_turn!(pool, @topology)

      assert %{"type" => "error", "status" => 429, "error" => error, "headers" => headers} = event
      assert %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => @message, "resets_at" => resets_at, "resets_in_seconds" => seconds} = error
      assert seconds in (@early_reset_seconds - 5)..@early_reset_seconds
      assert abs(resets_at - DateTime.to_unix(DateTime.utc_now()) - @early_reset_seconds) <= 5
      refute Map.has_key?(error, "plan_type")
      assert headers == %{"retry-after" => Integer.to_string(seconds)}
      assert Enum.all?(pool.upstreams, &(FakeUpstream.count(&1) == 0))

      assert [row] = settled_rows!(pool)
      assert {row.status, row.last_error_code, row.response_status_code} == {"rejected", "quota_exhausted", 429}
      assert Repo.aggregate(from(attempt in Attempt, where: attempt.request_id == ^row.id), :count) == 0
    end
  end

  defp exhausted_pool!(mode, [first_reset, second_reset]) do
    first_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    second_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(first_upstream, quota?: false, compact?: true)
    second = gateway_upstream(setup.pool, second_upstream, "upstream-token-exhausted-second", compact?: true)
    model = put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
    setup = %{setup | model: model}
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    prime_exhausted_routing_quota!(setup.identity, %{reset_at: reset_in(first_reset)})
    prime_exhausted_routing_quota!(second.identity, %{reset_at: reset_in(second_reset)})
    Map.merge(setup, %{mode: mode, upstreams: [first_upstream, second_upstream]})
  end

  defp reset_in(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp public_websocket_turn!(pool, topology) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", pool.authorization},
      {"x-codex-turn-state", "public-ws-usage-limit-#{topology}-#{System.unique_integer([:positive])}"},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => pool.model.exposed_model_id, "input" => "synthetic exhausted pool prompt", "stream" => true})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      receive_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_terminal!(conn, websocket, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, texts} = decode_texts(websocket, ref, responses)

            case Enum.find(texts, &terminal_text?/1) do
              nil ->
                receive_terminal!(conn, websocket, ref)

              text ->
                CodexPooler.TestDiagnostics.puts(fn -> "206-530 wire public websocket: " <> text end)
                CodexPooler.JSON.decode!(text)
            end

          {:error, _conn, reason, _responses} ->
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            receive_terminal!(conn, websocket, ref)
        end
    after
      @frame_timeout_ms -> flunk("timed out waiting for the public terminal")
    end
  end

  defp decode_texts(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {websocket, acc} ->
        case decode_public_websocket_data!(websocket, data) do
          {:ok, websocket, texts} -> {websocket, acc ++ texts}
          {:cont, websocket} -> {websocket, acc}
        end

      _part, acc ->
        acc
    end)
  end

  defp terminal_text?(text) do
    match?({:ok, %{"type" => type}} when type in ["response.completed", "response.failed", "response.incomplete", "error"], CodexPooler.JSON.decode(text))
  end

  # The socket writes the terminal before its task settles the row.
  defp settled_rows!(pool) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> Repo.all(from(request in Request, where: request.pool_id == ^pool.pool.id)) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        rows != [] and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end
end
