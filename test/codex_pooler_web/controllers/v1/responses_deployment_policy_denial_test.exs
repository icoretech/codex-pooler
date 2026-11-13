defmodule CodexPoolerWeb.V1.ResponsesDeploymentPolicyDenialTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect_with_request_headers!: 5, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [pool_owner_pids: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @moduletag capture_log: true
  @detection_timeout_ms 15_000
  @provider_sentinel "private synthetic deployment policy detail: do not relay"
  @prompt_sentinel "private-synthetic-deployment-policy-prompt-sentinel"
  @provider_headers [{"x-provider-policy-secret", @provider_sentinel}]
  @expected_error %{
    "code" => "model_request_policy_denied",
    "type" => "invalid_request_error",
    "message" => "The deployment rejected this model request. Ask the administrator to check the model access policy and request settings."
  }
  @input [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => @prompt_sentinel}]}]
  @tools [%{"type" => "function", "name" => "synthetic_policy_lookup", "strict" => true, "parameters" => %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}}]

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok
  end

  # provenance: synthetic_contract, OpenClaw 9211ea8272d0b774bbcfc2d8db7767442b3b98bc usage-limit-error.ts.
  # No real deployment denial was observed. These provider-shaped fixtures are not the native Codex
  # app-server tag OpenClaw classifies, and the public error does not claim to satisfy that classifier.
  for mode <- ~w(full lite), transport <- [:http_stream, :http_json, :sse, :collected_sse, :websocket, :bridged_sse, :bridged_rejection], diagnostic <- [:matched, :incomplete, :wrong_status] do
    @tag serving_mode: mode, transport: transport, diagnostic: diagnostic
    test "#{mode} #{transport}: #{diagnostic} deployment diagnostic has a narrow, redacted public result", context do
      assert_public_denial!(context)
    end
  end

  for mode <- ~w(full lite), topology <- [:direct, :local_owner], extras? <- [false, true] do
    test "#{mode} #{topology}: a raw WebSocket response.failed denial retains generic accounting with extras=#{extras?}" do
      assert_raw_websocket_accounting!(unquote(mode), unquote(topology), unquote(extras?))
    end
  end

  defp assert_public_denial!(%{serving_mode: mode, transport: transport, diagnostic: fixture}) do
    {status, diagnostic} = diagnostic(fixture)
    method = if transport in [:websocket, :bridged_sse, :bridged_rejection], do: "WEBSOCKET", else: "POST"
    if transport in [:bridged_sse, :bridged_rejection], do: Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial; diagnostic signature from pinned OpenClaw source, invented transport wrappers and private sentinels.
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: method,
            path: "/backend-api/codex/responses",
            json: [valid: true, forbidden: ["previous_response_id"]],
            respond: upstream_reply(transport, status, diagnostic)
          )
        ])
      )

    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    assert :ok = Events.subscribe_pool(setup.pool)
    body = request_body(setup, transport)

    if transport == :websocket do
      assert_websocket_result!(setup, body, fixture, status)
    else
      assert_http_result!(setup, body, transport, fixture, status, mode)
    end

    assert_dispatch!(upstream, setup, mode, method)
    if transport in [:bridged_sse, :bridged_rejection], do: assert([_owner | _rest] = pool_owner_pids(setup.pool))
    assert_failed_accounting!(setup, mode, transport, status)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp assert_raw_websocket_accounting!(mode, topology, extras?) do
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, topology == :local_owner)

    signatures =
      for fixture <- [:matched, :incomplete] do
        {status, diagnostic} = diagnostic(fixture)
        diagnostic = if extras?, do: Map.merge(diagnostic, %{"code" => "invalid_value", "type" => "invalid_request_error", "param" => "model"}), else: diagnostic
        {_type, terminal} = List.last(denial_events(status, diagnostic))
        reply = FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(terminal)])

        upstream =
          start_upstream(
            # provenance: synthetic_adversarial; matching and incomplete diagnostic siblings use the same invented raw terminal.
            FakeUpstream.strict_sequence([
              FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, forbidden: ["previous_response_id"]], respond: reply)
            ])
          )

        setup = gateway_setup(upstream)
        set_model_serving_mode!(model_serving_scope(), setup, mode)
        assert :ok = Events.subscribe_pool(setup.pool)
        assert_websocket_result!(setup, request_body(setup, :websocket), fixture, status, "response.failed")
        assert_dispatch!(upstream, setup, mode, "WEBSOCKET")

        if topology == :local_owner,
          do: assert([_owner | _rest] = pool_owner_pids(setup.pool)),
          else: assert(pool_owner_pids(setup.pool) == [])

        {request, attempt} = assert_failed_accounting!(setup, mode, :websocket, status)
        assert request.response_status_code == 200
        expected_code = if extras?, do: "invalid_value", else: "upstream_error"
        assert request.last_error_code == expected_code
        assert attempt.network_error_code == expected_code
        assert :ok = FakeUpstream.verify!(upstream)

        refute Enum.any?(Map.keys(attempt.response_metadata), &String.starts_with?(&1, "rejection_"))
        {Map.take(request, [:status, :response_status_code, :last_error_code, :usage_status, :retry_count]), Map.take(attempt, [:status, :upstream_status_code, :network_error_code, :usage_status, :retryable, :transport])}
      end

    assert [matched, incomplete] = signatures
    assert matched == incomplete
  end

  defp request_body(setup, transport),
    do: %{"model" => setup.model.exposed_model_id, "input" => @input, "tools" => @tools, "stream" => transport not in [:http_json, :collected_sse]}

  defp diagnostic(fixture) do
    diagnostic = %{"error" => "middleware_denied", "reason_code" => "request_credential_denied", "layer" => "l7", "detail" => @provider_sentinel}

    case fixture do
      :matched -> {403, diagnostic}
      :incomplete -> {403, Map.delete(diagnostic, "reason_code")}
      :wrong_status -> {400, diagnostic}
    end
  end

  defp upstream_reply(transport, status, diagnostic) when transport in [:http_stream, :http_json],
    do: FakeUpstream.json_response_with_headers(diagnostic, @provider_headers, status)

  defp upstream_reply(transport, status, diagnostic) when transport in [:websocket, :bridged_rejection] do
    frame = %{"type" => "error", "status" => status, "error" => diagnostic, "headers" => Map.new(@provider_headers)}
    FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(frame)])
  end

  defp upstream_reply(:bridged_sse, status, diagnostic) do
    FakeUpstream.websocket_text_frames(Enum.map(denial_events(status, diagnostic), fn {_type, event} -> CodexPooler.JSON.encode!(event) end))
  end

  defp upstream_reply(_transport, status, diagnostic),
    do: FakeUpstream.sse_stream(denial_events(status, diagnostic), headers: @provider_headers)

  defp denial_events(status, diagnostic) do
    response = %{"id" => "resp_synthetic_deployment_policy", "object" => "response", "status" => "in_progress", "output" => [], "headers" => Map.new(@provider_headers)}

    [
      {"response.created", %{"type" => "response.created", "response" => response, "headers" => Map.new(@provider_headers)}},
      {"response.failed", %{"type" => "response.failed", "status" => status, "error" => diagnostic, "response" => Map.merge(response, %{"status" => "failed", "error" => diagnostic}), "headers" => Map.new(@provider_headers)}}
    ]
  end

  defp assert_http_result!(setup, body, transport, fixture, upstream_status, mode) do
    port = start_public_endpoint!()
    headers = [{"authorization", setup.authorization}]
    headers = if transport in [:bridged_sse, :bridged_rejection], do: [{"x-session-id", Ecto.UUID.generate()} | headers], else: headers

    response =
      Req.post!("http://127.0.0.1:#{port}/v1/responses",
        headers: headers,
        json: body,
        retry: false,
        decode_body: false,
        receive_timeout: @detection_timeout_ms
      )

    assert_public_privacy!(response.body)
    assert_public_privacy!(inspect(response.headers))

    if transport in [:sse, :bridged_sse] do
      assert response.status == 200
      assert [content_type] = Req.Response.get_header(response, "content-type")
      assert content_type =~ "text/event-stream"
      events = sse_events(response.body)
      assert Enum.any?(events, &(&1["type"] == "response.created"))
      assert [terminal] = Enum.filter(events, &terminal?/1)
      assert terminal["type"] == "response.failed"
      assert terminal["response"]["status"] == "failed"
      assert_error!(terminal["error"], fixture, :sse, upstream_status)
      assert_error!(terminal["response"]["error"], fixture, :sse, upstream_status)
    else
      expected_status = if transport == :collected_sse and fixture != :matched, do: 502, else: upstream_status
      assert response.status == expected_status
      assert [content_type] = Req.Response.get_header(response, "content-type")
      assert content_type =~ "application/json"
      assert %{"error" => error} = decoded = CodexPooler.JSON.decode!(response.body)
      assert Map.keys(decoded) == ["error"]
      projection = if mode == "full" and transport in [:http_stream, :http_json, :bridged_rejection], do: :full_http, else: transport
      assert_error!(error, fixture, projection, expected_status)
    end

    await_failed_request!(setup)
  end

  defp assert_websocket_result!(setup, body, fixture, upstream_status, terminal_type \\ "error") do
    port = start_public_endpoint!()
    before = WebsocketCleanupFence.listener_sockets()
    headers = [{"openai-beta", "responses_websockets=2026-02-06"}]
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/v1/responses", headers)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)

    try do
      payload = CodexPooler.JSON.encode!(Map.put(body, "type", "response.create"))
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
      assert_public_privacy!(text)
      event = CodexPooler.JSON.decode!(text)

      case terminal_type do
        "error" ->
          assert %{"type" => "error", "status" => ^upstream_status, "error" => error} = event
          assert_error!(error, fixture, :websocket, upstream_status)

        "response.failed" ->
          assert %{"type" => "response.failed", "error" => error, "response" => %{"status" => "failed", "error" => nested_error}} = event
          assert_error!(error, fixture, :sse, upstream_status)
          assert_error!(nested_error, fixture, :sse, upstream_status)
      end

      await_failed_request!(setup)
    after
      Mint.HTTP.close(conn)
      assert :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(socket)
    end
  end

  defp assert_error!(error, :matched, _transport, _status), do: assert(error == @expected_error)

  defp assert_error!(error, _fixture, transport, status) do
    assert error["message"] == "upstream request failed"
    expected_type = if transport in [:sse, :collected_sse, :full_http] or status == 403, do: "server_error", else: "invalid_request_error"
    assert error["type"] == expected_type
    refute error["code"] == @expected_error["code"]
    assert Enum.sort(Map.keys(error)) == ~w(code message type)
  end

  defp await_failed_request!(setup) do
    pool_id = setup.pool.id

    assert_receive {Events, %{pool_id: ^pool_id, reason: "request_finalized", payload: %{"request_id" => request_id, "status" => "failed"}}}, @detection_timeout_ms
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^pool_id))
    assert request.id == request_id
  end

  defp assert_dispatch!(upstream, setup, mode, method) do
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == method
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == setup.model.upstream_model_id
    assert captured.json["stream"] == true

    if method == "WEBSOCKET" do
      assert %{http_generation: 0, websocket_generation: 1} = FakeUpstream.physical_counts(upstream)
      assert FakeUpstream.websocket_steers(upstream) == []
    end

    if mode == "full" do
      assert captured.json["tools"] == @tools
      assert captured.json["input"] == @input
    else
      refute Map.has_key?(captured.json, "tools")
      assert captured.json["input"] == [%{"type" => "additional_tools", "role" => "developer", "tools" => @tools} | @input]
    end

    marker =
      if method == "WEBSOCKET",
        do: get_in(captured.json, ["client_metadata", "ws_request_header_x_openai_internal_codex_responses_lite"]),
        else: Map.new(captured.headers)["x-openai-internal-codex-responses-lite"]

    assert marker == if(mode == "lite", do: "true")
  end

  defp assert_failed_accounting!(setup, mode, transport, upstream_status) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.completed_at != nil
    assert request.request_metadata["routing"]["model_serving_mode"] == mode
    assert request.transport == if(transport == :websocket, do: "websocket", else: "http_sse")
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.completed_at != nil
    assert attempt.response_metadata["routing"]["model_serving_mode"] == mode
    assert attempt.transport == if(transport in [:websocket, :bridged_sse, :bridged_rejection], do: "websocket", else: "http_sse")

    if transport in [:bridged_sse, :bridged_rejection] do
      assert attempt.response_metadata["upstream_websocket_bridge"] == true
      assert attempt.response_metadata["upstream_transport"] == "websocket"
    end

    if transport in [:http_stream, :http_json, :bridged_rejection] do
      assert request.response_status_code == upstream_status
      assert request.last_error_code == "upstream_status"
      assert attempt.network_error_code == "upstream_status"
      assert attempt.upstream_status_code == upstream_status
    else
      assert attempt.upstream_status_code == 200
    end

    persisted = inspect({request, attempt}, limit: :infinity, printable_limit: :infinity)
    refute persisted =~ @provider_sentinel
    refute persisted =~ @prompt_sentinel
    refute persisted =~ @expected_error["code"]
    {request, attempt}
  end

  defp assert_public_privacy!(wire) do
    for private <- [@provider_sentinel, @prompt_sentinel, "middleware_denied", "request_credential_denied", "reason_code", "x-provider-policy-secret"] do
      refute wire =~ private
    end
  end

  defp sse_events(body) do
    for block <- String.split(body, "\n\n", trim: true), "data: " <> data <- String.split(block, "\n"), data != "[DONE]", do: CodexPooler.JSON.decode!(data)
  end

  defp terminal?(event), do: event["type"] in ~w(response.completed response.failed response.incomplete error)
end
