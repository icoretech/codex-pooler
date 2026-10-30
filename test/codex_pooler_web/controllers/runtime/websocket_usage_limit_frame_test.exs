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
  # assignment, FakeUpstream websocket; direct socket and local owner; the
  # Pool's default mode, which serves this fixture's model Full (Auto, from a
  # catalog source whose `use_responses_lite` is false).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @message "upstream quota is exhausted until its reset time"
  @provider_message "synthetic provider usage limit text"
  @header_sentinel "synthetic-provider-header-private"
  @conflicting_retry_after "7200"
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

  # No usable reset: only the bounded advice the released client reads from
  # error.headers, then the outer headers, may survive the native relay.
  @retry_cases [
    {:outer_without_nested, :absent, "17", "17"},
    {:outer_with_empty_nested, %{}, "17", "17"},
    {:outer_with_nonmap_nested, "malformed", "17", "17"},
    {:outer_with_malformed_nested, %{"retry-after" => "soon"}, "17", "17"},
    {:outer_with_oversized_nested, %{"retry-after" => String.duplicate("1", 129)}, "17", "17"},
    {:nested_precedence, %{"ReTrY-AfTeR" => "29"}, "17", "29"},
    {:outer_http_date, :absent, "Wed, 21 Oct 2015 07:28:00 GMT", "Wed, 21 Oct 2015 07:28:00 GMT"},
    {:outer_u64_max, :absent, "18446744073709551615", "18446744073709551615"},
    {:malformed_outer, :absent, "soon", nil},
    {:oversized_outer, :absent, String.duplicate("1", 129), nil},
    {:control_outer, :absent, "17\r\nx-synthetic: no", nil},
    {:overflow_outer, :absent, "18446744073709551616", nil},
    {:retry_after_ms_only, :absent, :absent, nil}
  ]

  for topology <- [:direct, :local_owner], {name, nested, outer, expected} <- @retry_cases do
    test "native websocket #{topology}: resetless usage-limit retry advice #{name}" do
      assert_native_retry_advice!(unquote(topology), unquote(Macro.escape(nested)), unquote(outer), unquote(expected))
    end
  end

  for topology <- [:direct, :local_owner] do
    test "native websocket #{topology}: a plain throttle keeps outer retry advice in the client-parsed nested error" do
      assert_native_retry_advice!(unquote(topology), %{"retry-after" => "soon"}, "17", "17", :throttle)
    end

    test "native websocket #{topology}: retained metadata before a quota refusal gets no retry advice" do
      assert_terminal_only_retry_advice!(unquote(topology))
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
    refute retry_after == @conflicting_retry_after
    assert_recorded_failure!(setup)
  end

  test "public /v1 websocket: an exhausted sibling that resets sooner sets the advice", _context do
    put_owner_forwarding!(false)
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    setup = sibling_setup!(resets_at)
    prime_exhausted_routing_quota!(setup.sibling.identity, %{reset_at: DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)})

    assert %{"type" => "error", "status" => 429, "error" => %{"resets_in_seconds" => seconds}} = public_turn!(setup)
    assert seconds in 895..900
    assert_recorded_failure!(setup)
  end

  test "native websocket: a sibling taken out by an open circuit withholds the advice and relays the classified 429", _context do
    put_owner_forwarding!(false)
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    setup = sibling_setup!(resets_at)
    open_sibling_circuit!(setup)
    {_server, port} = start_public_endpoint_with_server!()

    assert %{"type" => "error", "status" => 429, "error" => error} = event = native_turn!(port, setup)
    assert %{"type" => "usage_limit_reached", "message" => "upstream usage limit reached", "resets_at" => ^resets_at} = error
    assert %{"retry-after" => retry_after} = event["headers"]
    assert String.to_integer(retry_after) in 1..60
    refute retry_after == @conflicting_retry_after
    refute CodexPooler.JSON.encode!(event) =~ @provider_message
    assert_recorded_failure!(setup)
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
    {{event, rows}, log} = with_log([level: :info], fn -> {native_turn!(port, setup), settled_requests!(setup)} end)
    assert %{"retry-after" => retry_after} = event["headers"]
    assert String.to_integer(retry_after) in 1..60
    refute retry_after == @conflicting_retry_after

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
      "error" => %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team", "resets_at" => resets_at, "resets_in_seconds" => @reset_seconds, "headers" => %{"retry-after" => @conflicting_retry_after}},
      "headers" => %{"x-codex-rate-limit-reached-type" => "rate_limit_reached", "retry-after" => @conflicting_retry_after}
    })
  end

  defp frame_setup!(resets_at), do: raw_frame_setup!(provider_frame(resets_at))

  defp raw_frame_setup!(frame) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    # gateway_setup registers this Pool's owner-session stop and socket cleanup
    # fence before the native upgrade can start any fixture consumers.
    setup = gateway_setup(upstream)
    Map.put(setup, :upstream, upstream)
  end

  defp assert_terminal_only_retry_advice!(topology) do
    put_owner_forwarding!(topology == :local_owner)
    metadata = CodexPooler.JSON.encode!(%{"type" => "codex.response.metadata", "headers" => %{"openai-model" => "synthetic-metadata-model"}})
    upstream = start_upstream(FakeUpstream.websocket_text_frames([metadata, retry_advice_frame(%{}, "17", :usage_limit)]))
    setup = gateway_setup(upstream)
    {_server, port} = start_public_endpoint_with_server!()
    ref = make_ref()

    event = native_turn!(port, setup, fn decoded -> send(self(), {ref, decoded}) end)
    assert event["headers"] == %{"retry-after" => "17"}
    send(self(), {ref, :complete})

    events =
      Stream.repeatedly(fn ->
        receive do
          {^ref, event} -> event
        after
          @frame_timeout_ms -> flunk("native retry observation did not complete")
        end
      end)
      |> Enum.take_while(&(&1 != :complete))

    metadata = Enum.filter(events, &(&1["type"] == "codex.response.metadata"))
    assert Enum.any?(metadata, &(get_in(&1, ["headers", "openai-model"]) == "synthetic-metadata-model"))
    refute Enum.any?(metadata, &Map.has_key?(Map.get(&1, "headers", %{}), "retry-after"))
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
  end

  defp assert_native_retry_advice!(topology, nested, outer, expected, kind \\ :usage_limit) do
    put_owner_forwarding!(topology == :local_owner)
    setup = raw_frame_setup!(retry_advice_frame(nested, outer, kind))
    {_server, port} = start_public_endpoint_with_server!()
    event = native_turn!(port, setup)

    assert [%Request{status: "failed"} = request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [%Attempt{status: "failed", transport: "websocket"} = attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert FakeUpstream.websocket_connection_count(setup.upstream) == 1
    assert FakeUpstream.http_request_count(setup.upstream) == 0

    if topology == :local_owner do
      assert %{"enabled" => true, "owner_instance_id" => owner, "proxy_instance_id" => owner} = request.request_metadata["websocket_owner_forwarding"]
      assert owner == Atom.to_string(node())
    else
      refute get_in(request.request_metadata, ["websocket_owner_forwarding", "enabled"])
    end

    assert event["status"] == 429
    assert Map.get(event, "headers", %{}) == if(expected, do: %{"retry-after" => expected}, else: %{})

    case kind do
      :usage_limit ->
        assert request.response_status_code == 429
        assert attempt.upstream_status_code == 429
        refute Map.has_key?(attempt.response_metadata, "usage_limit")
        assert event["type"] == "error"
        assert event["error"] == %{"type" => "usage_limit_reached", "code" => "upstream_rate_limited", "message" => "upstream usage limit reached"}
        refute Map.has_key?(event, "response")

      :throttle ->
        assert event["type"] == "response.failed"
        assert get_in(event, ["response", "error", "code"]) == "rate_limit_exceeded"
        assert get_in(event, ["response", "error", "headers"]) == %{"retry-after" => expected}
        assert get_in(event, ["error", "headers"]) == %{"retry-after" => expected}
        refute Map.has_key?(event["response"], "headers")
    end

    refute CodexPooler.JSON.encode!(event) =~ @header_sentinel
    refute CodexPooler.JSON.encode!(%{request: request.request_metadata, attempt: attempt.response_metadata}) =~ @header_sentinel
  end

  defp retry_advice_frame(nested, outer, kind) do
    error =
      case kind do
        :usage_limit -> %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team"}
        :throttle -> %{"type" => "rate_limit_error", "code" => "rate_limit_exceeded", "message" => "synthetic provider throttle"}
      end

    error = if nested == :absent, do: error, else: Map.put(error, "headers", with_private_headers(nested))
    headers = with_private_headers(%{"retry-after-ms" => "17000"})
    headers = if outer == :absent, do: headers, else: Map.put(headers, "ReTrY-AfTeR", outer)

    CodexPooler.JSON.encode!(%{"type" => "error", "status" => 429, "error" => error, "headers" => headers, "response" => %{"headers" => with_private_headers(%{"x-private" => @header_sentinel})}})
  end

  defp with_private_headers(headers) when map_size(headers) == 0, do: headers
  defp with_private_headers(%{} = headers), do: Map.merge(headers, %{"Authorization" => @header_sentinel, "Set-Cookie" => @header_sentinel, "x-private-debug" => @header_sentinel})
  defp with_private_headers(other), do: other

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
    deadline = System.monotonic_time(:millisecond) + @frame_timeout_ms

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

  defp native_turn!(port, setup, observe \\ fn _event -> :ok end) do
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
      event = terminal!(conn, websocket, ref, "native", observe)
      assert_recorded_failure!(setup)
      event
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

  defp terminal!(conn, websocket, ref, label, observe \\ fn _event -> :ok end) do
    message = receive_mint_socket_message!(conn, @frame_timeout_ms, "timed out waiting for the #{label} terminal")

    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {websocket, texts} = decode_texts(websocket, ref, responses)
        Enum.each(texts, &observe.(CodexPooler.JSON.decode!(&1)))

        case Enum.find(texts, &terminal_text?/1) do
          nil -> terminal!(conn, websocket, ref, label, observe)
          text -> CodexPooler.JSON.decode!(text)
        end

      {:error, _conn, reason, _responses} ->
        flunk("websocket receive failed: #{inspect(reason)}")

      :unknown ->
        terminal!(conn, websocket, ref, label, observe)
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
