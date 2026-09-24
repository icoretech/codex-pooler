defmodule CodexPoolerWeb.Runtime.WebsocketUsageLimitFrameTest do
  # A provider usage limit that arrives as the upstream websocket's wrapped
  # error frame (`{"type":"error","status":429,"error":{"type":
  # "usage_limit_reached","resets_at":...},"headers":{...}}`, the shape the
  # released client's own parser tests use) on the last eligible candidate
  # gets the same terminal answer as its HTTP twin (findings#206 rows 206-531,
  # 206-546):
  #
  # - the native websocket and the public `/v1/responses` websocket send the
  #   wrapped `429` error event with `usage_limit_reached`, the Pooler's code
  #   and message, `resets_at`, `resets_in_seconds` and `headers.retry-after`,
  #   which the released client maps to its terminal usage limit (a
  #   `response.failed` naming `usage_limit_reached` is a retryable stream
  #   error to it).
  #
  # A streaming `/v1` HTTP turn bridged onto the upstream websocket is covered
  # by `responses_websocket_bridge_usage_limit_test.exs` (row 206-582).
  #
  # The provider's message and plan never travel. One BEAM node, one
  # assignment, FakeUpstream websocket; direct socket and local owner; Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @message "upstream quota is exhausted until its reset time"
  @provider_message "synthetic provider usage limit text"
  @reset_seconds 3_600
  @frame_timeout_ms 15_000
  @turn_endpoint "/backend-api/codex/responses"

  for topology <- [:direct, :local_owner] do
    @topology topology

    test "native websocket #{topology}: a provider usage-limit frame answers the wrapped terminal 429 with its reset", _context do
      put_owner_forwarding!(@topology == :local_owner)
      raise_answer_log_level!()
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
      setup = frame_setup!(resets_at)
      {_server, port} = start_public_endpoint_with_server!()

      event = native_turn!(port, setup)

      assert_wrapped_usage_limit!(event, resets_at)
      assert_recorded_failure!(setup)
    end

    test "public /v1 websocket #{topology}: a provider usage-limit frame answers the wrapped terminal 429 with its reset", _context do
      put_owner_forwarding!(@topology == :local_owner)
      raise_answer_log_level!()
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
      setup = frame_setup!(resets_at)

      event = public_turn!(setup)

      assert_wrapped_usage_limit!(event, resets_at)
      assert_recorded_failure!(setup)
    end
  end

  # The advice is the Pool's (row 206-545): an exhausted sibling that resets
  # sooner sets it. A sibling with no known return (taken out by an open
  # circuit) withholds it, and the refusal goes out as the classified wrapped
  # 429 native HTTP relays, with the provider's reset (row 206-592).
  test "native websocket: an exhausted sibling that resets sooner sets the advice", _context do
    put_owner_forwarding!(false)
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    setup = sibling_setup!(resets_at)
    prime_exhausted_routing_quota!(setup.sibling.identity, %{reset_at: DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)})
    {_server, port} = start_public_endpoint_with_server!()

    assert %{"type" => "error", "status" => 429, "error" => %{"resets_in_seconds" => seconds}, "headers" => %{"retry-after" => retry_after}} = native_turn!(port, setup)
    assert seconds in 895..900
    assert retry_after == Integer.to_string(seconds)
  end

  test "public /v1 websocket: an exhausted sibling that resets sooner sets the advice", _context do
    put_owner_forwarding!(false)
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    setup = sibling_setup!(resets_at)
    prime_exhausted_routing_quota!(setup.sibling.identity, %{reset_at: DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)})

    assert %{"type" => "error", "status" => 429, "error" => %{"resets_in_seconds" => seconds}} = public_turn!(setup)
    assert seconds in 895..900
  end

  test "native websocket: a sibling taken out by an open circuit withholds the advice and relays the classified 429", _context do
    put_owner_forwarding!(false)
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    setup = sibling_setup!(resets_at)
    open_sibling_circuit!(setup)
    {_server, port} = start_public_endpoint_with_server!()

    assert %{"type" => "error", "status" => 429, "error" => error} = event = native_turn!(port, setup)
    assert %{"type" => "usage_limit_reached", "message" => "upstream usage limit reached", "resets_at" => ^resets_at} = error
    refute Map.has_key?(event, "headers")
    refute CodexPooler.JSON.encode!(event) =~ @provider_message
  end

  # The refused turn's row and log name what the client was told
  # (findings#206 row 206-596): the request and attempt record the 429 the
  # socket answered, the attempt keeps the advised reset like its HTTP twin
  # (row 206-553), and one info line names the refusal and the reset. The
  # suite runs at :warning; the line is an :info the production default level
  # emits, so it is raised for its module only.
  for topology <- [:direct, :local_owner] do
    @topology topology

    test "native websocket #{topology}: the refused turn records the 429 and the advised reset, and logs them", _context do
      put_owner_forwarding!(@topology == :local_owner)
      raise_answer_log_level!()
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
      setup = frame_setup!(resets_at)
      {_server, port} = start_public_endpoint_with_server!()

      {event, log} =
        with_log([level: :info], fn ->
          event = native_turn!(port, setup)
          assert_recorded_failure!(setup)
          event
        end)

      assert %{"status" => 429, "error" => %{"resets_at" => ^resets_at, "resets_in_seconds" => seconds}} = event
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.response_status_code == 429
      assert [attempt] = Repo.all(from(a in CodexPooler.Accounting.Attempt, where: a.request_id == ^request.id))
      assert attempt.response_metadata["usage_limit"] == %{"resets_at" => resets_at, "resets_in_seconds" => seconds}
      assert log =~ ~r/websocket usage limit answered .*status=429.*resets_at=#{resets_at} resets_in_seconds=#{seconds}/
      refute log =~ @provider_message
    end
  end

  test "native websocket: a withheld-advice refusal records the 429 it relayed, without advice", _context do
    put_owner_forwarding!(false)
    raise_answer_log_level!()
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    setup = sibling_setup!(resets_at)
    open_sibling_circuit!(setup)
    {_server, port} = start_public_endpoint_with_server!()

    # The line is logged after the frame went out: the capture waits for the
    # settled row.
    {rows, log} = with_log([level: :info], fn -> native_turn!(port, setup) && settled_requests!(setup) end)

    assert [request] = rows
    assert request.response_status_code == 429
    assert [attempt] = Repo.all(from(a in CodexPooler.Accounting.Attempt, where: a.request_id == ^request.id))
    refute Map.has_key?(attempt.response_metadata, "usage_limit")
    assert log =~ ~r/websocket usage limit answered .*status=429.*advice=withheld/
  end

  defp raise_answer_log_level! do
    :ok = Logger.put_module_level(CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt, :info)
    on_exit(fn -> Logger.delete_module_level(CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt) end)
  end

  defp sibling_setup!(resets_at) do
    sibling_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = frame_setup!(resets_at)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-sibling", compact?: false)
    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])
    Map.merge(%{setup | model: model}, %{sibling: sibling, sibling_upstream: sibling_upstream})
  end

  defp open_sibling_circuit!(setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- ["proxy_websocket", "proxy_stream", "proxy_http"] do
      %CodexPooler.Gateway.Persistence.RoutingCircuitState{
        pool_id: setup.pool.id,
        pool_upstream_assignment_id: setup.sibling.assignment.id,
        upstream_identity_id: setup.sibling.identity.id,
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

  defp provider_frame(resets_at) do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 429,
      "error" => %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team", "resets_at" => resets_at, "resets_in_seconds" => @reset_seconds},
      "headers" => %{"x-codex-rate-limit-reached-type" => "rate_limit_reached"}
    })
  end

  defp frame_setup!(resets_at) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames([provider_frame(resets_at)]))
    setup = gateway_setup(upstream)
    Map.put(setup, :upstream, upstream)
  end

  defp assert_wrapped_usage_limit!(event, resets_at) do
    assert %{"type" => "error", "status" => 429, "error" => error, "headers" => headers} = event
    assert_usage_limit_error!(error, resets_at)
    assert headers == %{"retry-after" => Integer.to_string(error["resets_in_seconds"])}
  end

  defp assert_usage_limit_error!(error, resets_at) do
    assert %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => @message, "resets_at" => ^resets_at, "resets_in_seconds" => seconds} = error
    assert seconds in (@reset_seconds - 5)..@reset_seconds
    refute Map.has_key?(error, "plan_type")
    refute inspect(error) =~ @provider_message
  end

  defp settled_requests!(setup) do
    assert_recorded_failure!(setup)
    Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
  end

  # The turn settles on the provider's refusal.
  defp assert_recorded_failure!(setup) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    rows =
      Stream.repeatedly(fn -> Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id)) end)
      |> Enum.reduce_while(nil, fn rows, _acc ->
        cond do
          rows != [] and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
          System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
          true -> Process.sleep(10) && {:cont, nil}
        end
      end)

    assert [%Request{status: "failed"}] = rows
  end

  defp native_turn!(port, setup) do
    thread_id = Ecto.UUID.generate()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "instructions" => "synthetic instructions",
        "input" => native_text_input("synthetic websocket usage limit prompt"),
        "tools" => [],
        "tool_choice" => "auto",
        "parallel_tool_calls" => true,
        "store" => false,
        "stream" => true,
        "client_metadata" => %{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "#{thread_id}-turn"}
      })

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      terminal!(conn, websocket, ref, "native")
    after
      Mint.HTTP.close(conn)
    end
  end

  defp public_turn!(setup) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"x-codex-turn-state", "public-ws-usage-frame-#{System.unique_integer([:positive])}"},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => "synthetic websocket usage limit prompt", "stream" => true})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      terminal!(conn, websocket, ref, "public")
    after
      Mint.HTTP.close(conn)
    end
  end

  defp terminal!(conn, websocket, ref, label) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, texts} = decode_texts(websocket, ref, responses)

            case Enum.find(texts, &terminal_text?/1) do
              nil ->
                terminal!(conn, websocket, ref, label)

              text ->
                CodexPooler.TestDiagnostics.puts(fn -> "206-546 wire #{label} websocket: " <> text end)
                CodexPooler.JSON.decode!(text)
            end

          {:error, _conn, reason, _responses} ->
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            terminal!(conn, websocket, ref, label)
        end
    after
      @frame_timeout_ms -> flunk("timed out waiting for the #{label} terminal")
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

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end
end
