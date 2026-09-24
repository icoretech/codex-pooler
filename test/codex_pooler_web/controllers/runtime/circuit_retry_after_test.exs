defmodule CodexPoolerWeb.Runtime.CircuitRetryAfterTest do
  # A retryable `503` of a Pool with an open-circuit candidate carries
  # `Retry-After` with the seconds until the earliest such circuit admits a
  # probe, clamped to 1..60, and no `x-should-retry` (findings#206 row
  # 206-532): the state is retryable, and the wait is bounded by the circuit,
  # not by the client's own backoff ladder. The websocket error event carries
  # it in `headers`, as it does for a usage limit.
  #
  # One BEAM node, two assignments, FakeUpstream never dispatched to; native
  # HTTP SSE, `/v1/responses` JSON, `/v1/chat/completions` SSE, native
  # websocket (direct), public `/v1/responses` websocket; Full.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @frame_timeout_ms 15_000
  @route_classes ["proxy_http", "proxy_stream", "proxy_websocket"]

  describe "an open circuit next to an exhausted sibling (the retryable quota 503)" do
    test "native http sse answers Retry-After with the seconds to the circuit's probe", %{conn: conn} do
      pool = circuit_and_exhausted_pool!(40)

      conn = post_native(conn, pool)

      assert_retryable_503!(conn, pool, "quota_exhausted", 40)
    end

    for {route, stream?} <- [{"/v1/responses", false}, {"/v1/chat/completions", true}] do
      @route route
      @stream stream?

      test "#{route} stream=#{stream?} keeps the Retry-After on the redacted 503", %{conn: conn} do
        pool = circuit_and_exhausted_pool!(40)

        conn = post_v1(conn, pool, @route, @stream)

        assert_retryable_503!(conn, pool, "quota_exhausted", 40)
      end
    end

    test "native websocket answers the wrapped 503 with headers retry-after", _context do
      pool = circuit_and_exhausted_pool!(40)
      {_server, port} = start_public_endpoint_with_server!()

      event = native_websocket_turn!(port, pool)

      assert %{"type" => "error", "status" => 503, "error" => %{"code" => "quota_exhausted"}, "headers" => %{"retry-after" => seconds}} = event
      assert String.to_integer(seconds) in 35..40
      assert_no_dispatch!(pool)
    end

    test "public /v1/responses websocket answers the wrapped 503 with headers retry-after", _context do
      pool = circuit_and_exhausted_pool!(40)

      event = public_websocket_turn!(pool)

      assert %{"type" => "error", "status" => 503, "headers" => %{"retry-after" => seconds}} = event
      assert String.to_integer(seconds) in 35..40
      assert_no_dispatch!(pool)
    end
  end

  test "every candidate circuit-open: no_eligible_backend advises the earliest probe", %{conn: conn} do
    pool = two_candidate_pool!()
    prime_routing_quota!(pool.first.identity)
    prime_routing_quota!(pool.second.identity)
    open_circuit!(pool, pool.first.assignment, 50)
    open_circuit!(pool, pool.second.assignment, 25)

    conn = post_native(conn, pool)

    assert_retryable_503!(conn, pool, "no_eligible_backend", 25)
  end

  test "a probe further away than a minute is advised as 60 s", %{conn: conn} do
    pool = circuit_and_exhausted_pool!(300)

    conn = post_native(conn, pool)

    assert_retryable_503!(conn, pool, "quota_exhausted", 60)
  end

  test "a 503 with no open-circuit candidate carries no Retry-After", %{conn: conn} do
    pool = two_candidate_pool!()
    prime_exhausted_routing_quota!(pool.first.identity, %{reset_at: reset_in(900)})
    prime_resetless_routing_quota!(pool.second.identity)

    conn = post_native(conn, pool)

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == []
    assert get_resp_header(conn, "x-should-retry") == []
  end

  test "the compatibility matrix names the advice measured here" do
    fixture = CodexPooler.CompatibilityMatrix.fixture!(:exhausted_pool_usage_limit)

    assert fixture.circuit_retry_after == %{status: 503, header: "retry-after", seconds: :earliest_circuit_probe, clamp: {1, 60}, x_should_retry: :absent}
  end

  defp circuit_and_exhausted_pool!(probe_in_seconds) do
    pool = two_candidate_pool!()
    prime_routing_quota!(pool.first.identity)
    open_circuit!(pool, pool.first.assignment, probe_in_seconds)
    prime_exhausted_routing_quota!(pool.second.identity, %{reset_at: reset_in(900)})
    pool
  end

  defp two_candidate_pool! do
    first_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    second_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(first_upstream, quota?: false, compact?: true)
    second = gateway_upstream(setup.pool, second_upstream, "upstream-token-circuit-second", compact?: true)
    model = put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
    setup = %{setup | model: model}
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "full")

    Map.merge(setup, %{
      first: %{identity: setup.identity, assignment: setup.assignment},
      second: second,
      upstreams: [first_upstream, second_upstream]
    })
  end

  defp reset_in(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp open_circuit!(pool, assignment, probe_in_seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- @route_classes do
      %RoutingCircuitState{
        pool_id: pool.pool.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        model_identifier: pool.model.exposed_model_id,
        route_class: route_class,
        status: "open",
        reason_code: "upstream_rate_limited",
        failure_count: 3,
        success_count: 0,
        opened_at: now,
        last_failure_at: now,
        next_probe_at: DateTime.add(now, probe_in_seconds, :second),
        metadata: %{"probe_in_flight_count" => 0},
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()
    end
  end

  defp post_native(conn, pool) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post(@turn_endpoint, CodexPooler.JSON.encode!(native_body(pool)))
  end

  defp post_v1(conn, pool, "/v1/responses", stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/responses", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => "synthetic circuit prompt", "stream" => stream?}))
  end

  defp post_v1(conn, pool, "/v1/chat/completions", stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/chat/completions", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic circuit prompt"}], "stream" => stream?}))
  end

  defp native_body(pool) do
    %{
      "model" => pool.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic circuit prompt"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true
    }
  end

  defp assert_retryable_503!(conn, pool, code, expected_seconds) do
    CodexPooler.TestDiagnostics.puts(fn -> "206-532 wire: #{conn.status} #{inspect(Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry"] end))} #{conn.resp_body}" end)

    assert conn.status == 503
    assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
    refute Map.has_key?(error, "resets_at")
    assert [seconds] = get_resp_header(conn, "retry-after")
    assert String.to_integer(seconds) in (expected_seconds - 5)..expected_seconds
    assert get_resp_header(conn, "x-should-retry") == []
    if code, do: assert(error["code"] in [code, "server_error"])
    assert_no_dispatch!(pool)
  end

  defp assert_no_dispatch!(pool), do: assert(Enum.all?(pool.upstreams, &(FakeUpstream.count(&1) == 0)))

  defp native_websocket_turn!(port, pool) do
    thread_id = Ecto.UUID.generate()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", pool.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    frame =
      pool
      |> native_body()
      |> Map.put("type", "response.create")
      |> Map.put("client_metadata", %{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "#{thread_id}-turn"})
      |> CodexPooler.JSON.encode!()

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      native_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp native_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] ->
        CodexPooler.TestDiagnostics.puts(fn -> "206-532 wire native websocket: " <> text end)
        terminal

      _progress ->
        native_terminal!(conn, websocket, ref)
    end
  end

  defp public_websocket_turn!(pool) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", pool.authorization},
      {"x-codex-turn-state", "public-ws-circuit-#{System.unique_integer([:positive])}"},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => pool.model.exposed_model_id, "input" => "synthetic circuit prompt", "stream" => true})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      public_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp public_terminal!(conn, websocket, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, texts} = decode_texts(websocket, ref, responses)

            case Enum.find(texts, &terminal_text?/1) do
              nil ->
                public_terminal!(conn, websocket, ref)

              text ->
                CodexPooler.TestDiagnostics.puts(fn -> "206-532 wire public websocket: " <> text end)
                CodexPooler.JSON.decode!(text)
            end

          {:error, _conn, reason, _responses} ->
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            public_terminal!(conn, websocket, ref)
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
end
