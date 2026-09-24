defmodule CodexPoolerWeb.Runtime.WithheldAdviceUsageLimitTest do
  # A provider usage limit on the last eligible candidate while the Pool's
  # return is not known (a sibling was taken out by an open circuit): the Pooler
  # withholds its own terminal advice (row 206-545) and relays the refusal
  # classified, with the provider's reset, the way native HTTP answers it
  # (`NativeRateLimitRelay`, row 206-589):
  #
  # - the native websocket sends the wrapped `429` error event with that error
  #   object, which the released client stops on, instead of a `response.failed`
  #   it reconnects on and then falls back to HTTP for (findings#206 row 206-592);
  # - a streaming `/v1` turn bridged onto the upstream websocket answers what the
  #   same `/v1` turn answers over HTTP (row 206-593).
  #
  # One BEAM node, two assignments (the sibling behind an open circuit),
  # FakeUpstream; owner forwarding on and off; Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @lite_header "x-openai-internal-codex-responses-lite"
  @provider_message "synthetic provider usage limit text"
  @reset_seconds 3_600

  for mode <- ["full", "lite"], forwarding <- [:forwarded, :direct] do
    @mode mode
    @forwarding forwarding

    test "native websocket #{mode} #{forwarding}: the withheld-advice usage limit is the classified wrapped 429 of its HTTP twin", _context do
      put_owner_forwarding!(@forwarding == :forwarded)
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds

      http_pool = pool!(@mode, {:json_headers, 429, %{"error" => provider_error(resets_at)}, []})
      http = post_native(http_pool)
      assert http.status == 429
      assert %{"error" => http_error} = CodexPooler.JSON.decode!(http.resp_body)

      ws_pool = pool!(@mode, FakeUpstream.websocket_text_frames([provider_frame(resets_at)]))
      {_server, port} = start_public_endpoint_with_server!()
      event = native_websocket_turn!(port, ws_pool)

      CodexPooler.TestDiagnostics.puts(fn -> "206-592 wire #{@mode} #{@forwarding}: http=#{http.resp_body} ws=#{CodexPooler.JSON.encode!(event)}" end)

      assert %{"type" => "error", "status" => 429, "error" => ws_error} = event
      assert ws_error == http_error
      assert %{"type" => "usage_limit_reached", "message" => "upstream usage limit reached", "resets_at" => ^resets_at} = ws_error
      refute CodexPooler.JSON.encode!(event) =~ @provider_message
      refute Map.has_key?(ws_error, "plan_type")
      assert_settled!(ws_pool)
    end
  end

  for mode <- ["full", "lite"] do
    @mode mode

    test "bridged /v1 #{mode}: the withheld-advice usage limit answers what the same /v1 turn answers over HTTP", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds

      put_owner_forwarding!(false)
      http_pool = pool!(@mode, {:json_headers, 429, %{"error" => provider_error(resets_at)}, []})
      http = post_v1(conn, http_pool)

      put_owner_forwarding!(true)
      bridge_pool = pool!(@mode, FakeUpstream.websocket_text_frames([provider_frame(resets_at)]))
      bridged = post_v1(build_conn(), bridge_pool)

      CodexPooler.TestDiagnostics.puts(fn ->
        "206-593 wire #{@mode}: http=#{http.status} #{inspect(retry_headers(http))} #{http.resp_body} bridged=#{bridged.status} #{inspect(retry_headers(bridged))} #{bridged.resp_body}"
      end)

      assert FakeUpstream.websocket_connection_count(bridge_pool.upstream) == 1
      assert FakeUpstream.http_request_count(bridge_pool.upstream) == 0
      assert {bridged.status, CodexPooler.JSON.decode!(bridged.resp_body)} == {http.status, CodexPooler.JSON.decode!(http.resp_body)}
      assert %{"error" => %{"type" => "rate_limit_error", "code" => "upstream_rate_limited"}} = CodexPooler.JSON.decode!(bridged.resp_body)
      # Each Pool's sibling circuit probes about a minute after it opened.
      assert_retry_after_close!(bridged, http)
      assert get_resp_header(bridged, "x-should-retry") == []
      refute bridged.resp_body =~ @provider_message
      assert_settled!(bridge_pool)
    end
  end

  for forwarding <- [:forwarded, :direct] do
    @forwarding forwarding

    test "public /v1 websocket #{forwarding}: the withheld-advice usage limit is the /v1 HTTP answer's error event with its retry-after", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds

      put_owner_forwarding!(false)
      http_pool = pool!("lite", {:json_headers, 429, %{"error" => provider_error(resets_at)}, []})
      http = post_v1(conn, http_pool)

      put_owner_forwarding!(@forwarding == :forwarded)
      ws_pool = pool!("lite", FakeUpstream.websocket_text_frames([provider_frame(resets_at)]))
      event = public_websocket_turn!(ws_pool)

      CodexPooler.TestDiagnostics.puts(fn -> "206-593 wire public websocket #{@forwarding}: #{CodexPooler.JSON.encode!(event)}" end)

      assert %{"type" => "error", "status" => 429, "error" => error, "headers" => %{"retry-after" => retry_after}} = event
      assert error == CodexPooler.JSON.decode!(http.resp_body)["error"]
      assert [http_retry_after] = get_resp_header(http, "retry-after")
      assert abs(String.to_integer(retry_after) - String.to_integer(http_retry_after)) <= 2
      refute CodexPooler.JSON.encode!(event) =~ @provider_message
      assert_settled!(ws_pool)
    end
  end

  defp provider_error(resets_at), do: %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team", "resets_at" => resets_at, "resets_in_seconds" => @reset_seconds}

  defp provider_frame(resets_at), do: CodexPooler.JSON.encode!(%{"type" => "error", "status" => 429, "error" => provider_error(resets_at)})

  defp assert_retry_after_close!(conn, reference) do
    assert [seconds] = get_resp_header(conn, "retry-after")
    assert [reference_seconds] = get_resp_header(reference, "retry-after")
    assert String.to_integer(seconds) in 55..60
    assert abs(String.to_integer(seconds) - String.to_integer(reference_seconds)) <= 2
  end

  defp retry_headers(conn), do: Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry"] end)

  # The refusing account and a sibling behind an open circuit, so the Pool's
  # return is not known.
  defp pool!(mode, refusing_mode) do
    upstream = start_upstream(refusing_mode)
    sibling_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-withheld-sibling", compact?: false)
    prime_routing_quota!(sibling.identity)
    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])
    setup = %{setup | model: model}
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    open_circuit!(setup, sibling.assignment)
    Map.merge(setup, %{mode: mode, upstream: upstream, sibling_upstream: sibling_upstream})
  end

  defp open_circuit!(setup, assignment) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- ["proxy_http", "proxy_stream", "proxy_websocket"] do
      %RoutingCircuitState{
        pool_id: setup.pool.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        model_identifier: setup.model.exposed_model_id,
        route_class: route_class,
        status: "open",
        reason_code: "upstream_5xx",
        failure_count: 3,
        success_count: 0,
        opened_at: now,
        last_failure_at: now,
        next_probe_at: DateTime.add(now, 60, :second),
        metadata: %{"probe_in_flight_count" => 0},
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()
    end
  end

  defp post_native(pool) do
    build_conn()
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> maybe_lite(pool)
    |> post(@turn_endpoint, CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => native_text_input("synthetic withheld prompt"), "stream" => true}))
  end

  defp post_v1(conn, pool) do
    conn
    |> auth(pool)
    |> put_req_header("x-session-id", "withheld-#{System.unique_integer([:positive])}")
    |> post("/v1/responses", %{"model" => pool.model.exposed_model_id, "input" => "synthetic withheld prompt", "stream" => true})
  end

  defp maybe_lite(conn, %{mode: "lite"}), do: put_req_header(conn, @lite_header, "true")
  defp maybe_lite(conn, _pool), do: conn

  defp native_websocket_turn!(port, pool) do
    thread_id = Ecto.UUID.generate()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers =
      [
        {"authorization", pool.authorization},
        {"session-id", thread_id},
        {"thread-id", thread_id},
        {"x-client-request-id", thread_id},
        {"x-codex-window-id", "#{thread_id}:0"}
      ] ++ if(pool.mode == "lite", do: [{@lite_header, "true"}], else: [])

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => pool.model.exposed_model_id,
        "instructions" => "synthetic instructions",
        "input" => native_text_input("synthetic withheld prompt"),
        "tools" => [],
        "tool_choice" => "auto",
        "parallel_tool_calls" => true,
        "store" => false,
        "stream" => true,
        "client_metadata" => %{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "#{thread_id}-turn"}
      })

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      receive_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp public_websocket_turn!(pool) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", pool.authorization},
      {"x-codex-turn-state", "withheld-public-#{System.unique_integer([:positive])}"},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => pool.model.exposed_model_id, "input" => "synthetic withheld prompt", "stream" => true})
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

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> terminal
      _progress -> receive_terminal!(conn, websocket, ref)
    end
  end

  defp assert_settled!(pool) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    rows =
      Stream.repeatedly(fn -> Repo.all(from(r in Request, where: r.pool_id == ^pool.pool.id)) end)
      |> Enum.reduce_while(nil, fn rows, _acc ->
        cond do
          rows != [] and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
          System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
          true -> Process.sleep(10) && {:cont, nil}
        end
      end)

    # The row records the 429 the client was answered (row 206-596).
    assert [%Request{status: "failed", response_status_code: 429}] = rows
    assert FakeUpstream.count(pool.sibling_upstream) == 0
  end

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end
end
