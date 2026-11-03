defmodule CodexPoolerWeb.Plugs.RuntimeIngressRawHTTPTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo

  @connect_timeout 1_000
  @receive_timeout 2_000
  @max_response_bytes 32_768
  @max_json_bytes 16_384

  setup context do
    previous_settings = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)

    settings = %OperationalSettings{
      firewall_allowlist: ["198.51.100.20", "2001:db8::7"],
      trusted_proxies: ["127.0.0.1"]
    }

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous_settings
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )

    {:ok, upstream} =
      FakeUpstream.start_link(FakeUpstream.json_response(%{"id" => "unexpected_dispatch"}))

    on_exit(fn ->
      FakeUpstream.stop(upstream)
      refute Process.alive?(upstream.supervisor)
    end)

    gateway = gateway_setup(upstream)
    {:ok, sockets} = Agent.start(fn -> MapSet.new() end)

    on_exit(fn ->
      if Process.alive?(sockets) do
        open_sockets = Agent.get(sockets, &MapSet.to_list/1)
        Enum.each(open_sockets, &:gen_tcp.close/1)
        assert open_sockets == []
        Agent.stop(sockets)
        refute Process.alive?(sockets)
      end
    end)

    {:ok, listener} =
      Bandit.start_link(
        plug: upload_probe(context),
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    on_exit(fn ->
      safe_stop_listener(listener)
      refute Process.alive?(listener)
    end)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    {:ok, port: port, sockets: sockets, upstream: upstream, gateway: gateway}
  end

  for form <- [:origin, :absolute],
      route <- ["/v1/responses", "/backend-api/codex/responses"],
      upgrade? <- [false, true],
      values <- [:identical, :conflicting] do
    @tag :capture_log
    test "rejects #{form} #{route} duplicate Host fields (upgrade=#{upgrade?}, #{values})", ctx do
      assert_duplicate_host_rejected(ctx, unquote(form), unquote(route), unquote(upgrade?), unquote(values))
    end
  end

  @tag :capture_log
  test "duplicate Host fields reject an authenticated incomplete body before reading it", ctx do
    for form <- [:origin, :absolute],
        route <- ["/v1/responses", "/backend-api/codex/responses"],
        upgrade? <- [false, true] do
      headers =
        [
          {"authorization", ctx.gateway.authorization},
          {"x-forwarded-for", "198.51.100.20"},
          {"content-type", "application/json"}
        ] ++ upgrade_headers(upgrade?)

      response = raw_request(ctx, request_method(upgrade?), request_target(form, route), headers, host_fields: duplicate_hosts(:conflicting), content_length: 100)

      assert response.status == 400
      refute List.keymember?(response.headers, "x-request-id", 0)
      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  test "single Host ordinary and upgrade controls still reach runtime authentication", ctx do
    for form <- [:origin, :absolute],
        route <- ["/v1/responses", "/backend-api/codex/responses"],
        upgrade? <- [false, true] do
      headers = [{"x-forwarded-for", "198.51.100.20"}] ++ upgrade_headers(upgrade?)
      response = raw_request(ctx, request_method(upgrade?), request_target(form, route), headers, host_fields: [{"hOsT", "example.com"}])

      assert response.status == 401
      assert json_field(response, ["error", "code"]) == "api_key_missing"
      assert List.keymember?(response.headers, "x-request-id", 0)
    end

    assert_no_gateway_side_effects(ctx.upstream)
  end

  for encoding <- [:identity, :gzip, :deflate] do
    @tag :capture_log
    test "#{encoding} incomplete JSON returns a structured body timeout and closes keepalive", ctx do
      set_body_read_settings(body_read_timeout_ms: 100, decompression_timeout_ms: 100)
      plain = CodexPooler.JSON.encode!(%{"probe" => "unfinished upload"})
      body = encode_upload(plain, unquote(encoding))

      response =
        raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, unquote(encoding)),
          body: binary_part(body, 0, 1),
          content_length: byte_size(body),
          expect_closed: true
        )

      assert response.status == 408
      assert json_field(response, ["error", "code"]) == "request_body_read_timeout"
      assert json_field(response, ["error", "message"]) == "request body read timed out"
      assert {"connection", " close"} in response.headers
      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  for {encoding, framing, decompression_timeout} <- [{:identity, :content_length, 500}, {:gzip, :content_length, 500}, {:deflate, :content_length, 500}, {:identity, :chunked, 500}, {:gzip, :chunked, 500}, {:identity, :content_length, 0}] do
    @tag :capture_log
    @tag :observe_body_read
    @tag slow: "paced upload must exceed a 500 ms read budget while completing bounded chunks"
    test "#{encoding} #{framing} body progresses beyond one read budget with decompression timeout #{decompression_timeout}", ctx do
      read_timeout = 500
      set_body_read_settings(body_read_timeout_ms: read_timeout, decompression_timeout_ms: unquote(decompression_timeout))
      plain = invalid_upload_body()
      body = encode_upload(plain, unquote(encoding))
      started = System.monotonic_time(:millisecond)

      response =
        raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, unquote(encoding)),
          content_length: byte_size(body),
          framing: unquote(framing),
          after_send: fn socket ->
            assert_receive {:trace, _request, :call, {Plug.Conn, :read_body, 2}}, 5_000
            send_paced_body(socket, body, unquote(framing))
          end
        )

      assert System.monotonic_time(:millisecond) - started > read_timeout
      assert response.status == 400
      assert json_field(response, ["error", "code"]) == "invalid_request"
      assert json_field(response, ["error", "message"]) == parse_error_message(unquote(encoding))
      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  test "a completed compressed upload retains its distinct decompression timeout", ctx do
    set_body_read_settings(body_read_timeout_ms: 500, decompression_timeout_ms: 0)
    body = encode_upload(CodexPooler.JSON.encode!(%{"probe" => "complete upload"}), :gzip)

    response = raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, :gzip), body: body)

    assert response.status == 408
    assert json_field(response, ["error", "code"]) == "request_decompression_timeout"
    assert_no_gateway_side_effects(ctx.upstream)
  end

  for encoding <- [:identity, :gzip, :deflate] do
    @tag :capture_log
    test "#{encoding} upload accepts its exact byte limit and rejects one byte over it", ctx do
      plain = CodexPooler.JSON.encode!(%{"probe" => "exact boundary"}) <> "!"
      body = encode_upload(plain, unquote(encoding))
      limit = if unquote(encoding) == :identity, do: :max_decompressed_body_bytes, else: :max_compressed_body_bytes
      set_body_read_settings([{limit, byte_size(body)}, {:body_read_timeout_ms, 500}])

      exact = raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, unquote(encoding)), body: body)
      assert exact.status == 400
      assert json_field(exact, ["error", "message"]) == parse_error_message(unquote(encoding))

      set_body_read_settings([{limit, byte_size(body) - 1}])
      over = raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, unquote(encoding)), body: body)
      assert over.status == 413

      assert json_field(over, ["error", "code"]) ==
               if(unquote(encoding) == :identity, do: "decompressed_request_too_large", else: "compressed_request_too_large")

      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  for encoding <- [:identity, :gzip] do
    @tag :capture_log
    test "#{encoding} over-limit partial upload returns 413 and closes without draining", ctx do
      limit = if unquote(encoding) == :identity, do: :max_decompressed_body_bytes, else: :max_compressed_body_bytes
      set_body_read_settings([{limit, 100}, {:body_read_timeout_ms, 500}])

      response =
        raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, unquote(encoding)),
          body: String.duplicate("a", 101),
          content_length: 1_000,
          expect_closed: true
        )

      assert response.status == 413
      assert {"connection", " close"} in response.headers
      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  test "missing credentials reject an incomplete JSON upload before its read budget", ctx do
    set_body_read_settings(body_read_timeout_ms: 100, decompression_timeout_ms: 100)
    headers = upload_headers(ctx, :identity) |> List.keydelete("authorization", 0)

    response = raw_request(ctx, "POST", "/v1/responses", headers, content_length: 100)

    assert response.status == 401
    assert json_field(response, ["error", "code"]) == "api_key_missing"
    assert_no_gateway_side_effects(ctx.upstream)
  end

  test "timeout diagnostics report completed chunks without body, credentials or dynamic path data", ctx do
    set_body_read_settings(body_read_timeout_ms: 100, decompression_timeout_ms: 5_000)
    body = "private-body-marker" <> String.duplicate(" ", 65_537 - byte_size("private-body-marker"))
    headers = [{"x-request-id", "raw-http-timeout-probe"} | upload_headers(ctx, :identity)]

    {response, log} =
      ExUnit.CaptureLog.with_log(fn ->
        raw_request(ctx, "POST", "/backend-api/files/private-file-marker/uploaded?probe=private-query-marker", headers,
          body: body,
          content_length: 100_000,
          expect_closed: true
        )
      end)

    assert response.status == 408
    [diagnostic] = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "ingress body read timed out"))
    assert diagnostic =~ "route=/backend-api/files/:file_id/uploaded"
    assert diagnostic =~ "method=POST"
    assert diagnostic =~ "request_id=raw-http-timeout-probe"
    assert diagnostic =~ "content_encoding=identity framing=content_length"
    assert diagnostic =~ "declared_content_length=100000"
    assert diagnostic =~ "timeout_ms=100 completed_body_bytes=65536"
    refute diagnostic =~ "private-body-marker"
    refute diagnostic =~ "private-file-marker"
    refute diagnostic =~ "private-query-marker"
    refute diagnostic =~ ctx.gateway.authorization
    assert_no_gateway_side_effects(ctx.upstream)
  end

  test "malformed HTTP chunks retain their protocol failure instead of a body timeout", ctx do
    set_body_read_settings(body_read_timeout_ms: 100)

    {response, log} =
      ExUnit.CaptureLog.with_log(fn ->
        raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, :identity),
          framing: :chunked,
          after_send: fn socket -> assert :ok = :gen_tcp.send(socket, "not-a-chunk-size\r\n") end,
          expect_closed: true
        )
      end)

    assert response.status == 400
    refute log =~ "ingress body read timed out"
    assert_no_gateway_side_effects(ctx.upstream)
  end

  test "a disconnected body sender is not classified as a body-read timeout", ctx do
    set_body_read_settings(body_read_timeout_ms: 100)

    {response, log} =
      ExUnit.CaptureLog.with_log(fn ->
        raw_request(ctx, "POST", "/v1/responses", upload_headers(ctx, :identity),
          body: "{",
          content_length: 100,
          after_send: fn socket -> assert :ok = :gen_tcp.shutdown(socket, :write) end,
          raw_response: true,
          expect_closed: :after_write_shutdown
        )
      end)

    refute String.starts_with?(response, "HTTP/1.1 408 ")
    refute log =~ "ingress body read timed out"
    assert_no_gateway_side_effects(ctx.upstream)
  end

  for {label, host_fields} <- [{"absent", []}, {"invalid", [{"Host", "example.com, example.net"}]}],
      form <- [:origin, :absolute] do
    @tag :capture_log
    test "#{form} rejects #{label} Host before endpoint dispatch", ctx do
      response = raw_request(ctx, "POST", request_target(unquote(form), "/v1/responses"), [{"x-forwarded-for", "198.51.100.20"}], host_fields: unquote(Macro.escape(host_fields)))

      assert response.status == 400
      refute List.keymember?(response.headers, "x-request-id", 0)
      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  for authority <- ["example.com@example.net", "ex#ample.com", "[invalid::1]", "example.com:65536"],
      form <- [:origin, :absolute] do
    @tag :capture_log
    test "#{form} rejects malformed authority #{authority} before endpoint dispatch", ctx do
      {target, host_fields} =
        case unquote(form) do
          :origin -> {"/v1/responses", [{"Host", unquote(authority)}]}
          :absolute -> {"http://#{unquote(authority)}/v1/responses", [{"Host", "example.com"}]}
        end

      response = raw_request(ctx, "POST", target, [{"x-forwarded-for", "198.51.100.20"}], host_fields: host_fields)

      assert response.status == 400
      refute List.keymember?(response.headers, "x-request-id", 0)
      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  @tag :capture_log
  test "malformed absolute authority rejects an authenticated incomplete body before reading it", ctx do
    headers = [
      {"authorization", ctx.gateway.authorization},
      {"x-forwarded-for", "198.51.100.20"},
      {"content-type", "application/json"}
    ]

    response = raw_request(ctx, "POST", "http://example.com@example.net/v1/responses", headers, content_length: 100)

    assert response.status == 400
    refute List.keymember?(response.headers, "x-request-id", 0)
    assert_no_gateway_side_effects(ctx.upstream)
  end

  for route <- ["/login", "/v1/responses"] do
    @tag :capture_log
    test "malformed JSON on #{route} retains its error response after reading the body", ctx do
      headers = [
        {"authorization", ctx.gateway.authorization},
        {"x-forwarded-for", "198.51.100.20"},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ]

      response = raw_request(ctx, "POST", unquote(route), headers, body: "{")

      assert response.status == 400

      case unquote(route) do
        "/login" ->
          assert json_field(response, ["errors", "detail"]) == "Bad Request"

        "/v1/responses" ->
          assert List.keymember?(response.headers, "x-request-id", 0)
          assert json_field(response, ["error", "code"]) == "invalid_request"
          assert json_field(response, ["error", "message"]) == "request body could not be parsed"
      end

      assert_no_gateway_side_effects(ctx.upstream)
    end
  end

  @tag :capture_log
  test "literal encoded v1 and encoded websocket upgrades are denied before side effects", ctx do
    for {target, headers} <- [
          {"/%76%31/responses", []},
          {"/%76%31/responses",
           [
             {"connection", "upgrade"},
             {"upgrade", "websocket"},
             {"sec-websocket-version", "13"},
             {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}
           ]}
        ] do
      response = raw_request(ctx, "GET", target, headers)

      assert response.status == 403
      assert json_field(response, ["error", "code"]) == "access_denied"
    end

    assert_no_gateway_side_effects(ctx.upstream)
  end

  test "encoded backend files multipart authenticates before the multipart guard", ctx do
    response =
      raw_request(ctx, "POST", "/backend-api/%66iles", [
        {"authorization", ctx.gateway.authorization},
        {"x-forwarded-for", "198.51.100.20:43123, 127.0.0.1:443"},
        {"content-type", "multipart/form-data; boundary=raw-http-boundary"}
      ])

    assert response.status == 400
    assert json_field(response, ["error", "code"]) == "unsupported_multipart_file_create"
    assert_no_gateway_side_effects(ctx.upstream)
  end

  test "unsafe runtime and MCP path bytes return their fixed envelopes", ctx do
    for target <- ["/v1%2Fresponses", "/backend-api%5Cfiles", "/api/codex%00/usage"] do
      response = raw_request(ctx, "GET", target)

      assert response.status == 400
      assert json_field(response, ["error", "code"]) == "invalid_request"
      assert json_field(response, ["error", "message"]) == "request path is invalid"
      assert json_field(response, ["error", "type"]) == "invalid_request_error"
      assert json_field(response, ["error", "param"]) == nil
    end

    for target <- ["/mcp%00%2Ftail", "/mcp%00%5Ctail", "/mcp%00tail"] do
      response = raw_request(ctx, "POST", target)

      assert response.status == 400
      assert json_field(response, ["jsonrpc"]) == "2.0"
      assert json_field(response, ["id"]) == nil
      assert json_field(response, ["error", "code"]) == -32_600
      assert json_field(response, ["error", "message"]) == "invalid request"
    end

    assert_no_gateway_side_effects(ctx.upstream)
  end

  test "double encoded separators are decoded only once", ctx do
    response =
      raw_request(ctx, "GET", "/v1/value%252Ftail", [
        {"x-forwarded-for", "198.51.100.20"}
      ])

    assert response.status == 401
    assert json_field(response, ["error", "code"]) == "api_key_missing"
    assert_no_gateway_side_effects(ctx.upstream)
  end

  @tag :capture_log
  test "trusted peers fail runtime requests closed on non-UTF8 forwarded headers", ctx do
    for header <- ["x-forwarded-for", "x-real-ip"] do
      runtime = raw_request(ctx, "GET", "/v1/models", [{header, <<0xFF>>}])

      assert runtime.status == 403
      assert json_field(runtime, ["error", "code"]) == "access_denied"

      for target <- ["/login", "/healthz"] do
        passthrough = raw_request(ctx, "GET", target, [{header, <<0xFF>>}])
        assert passthrough.status < 500
      end
    end

    assert_no_gateway_side_effects(ctx.upstream)
  end

  test "forwarded chains accept IPv4 ports and bracketed IPv6 ports", ctx do
    for forwarded <- [
          "198.51.100.20:43123, 127.0.0.1:443",
          "[2001:db8::7]:43123, 127.0.0.1:443"
        ] do
      response = raw_request(ctx, "GET", "/v1/models", [{"x-forwarded-for", forwarded}])

      assert response.status == 401
      assert json_field(response, ["error", "code"]) == "api_key_missing"
    end

    assert_no_gateway_side_effects(ctx.upstream)
  end

  defp assert_duplicate_host_rejected(ctx, form, route, upgrade?, values) do
    headers = [{"x-forwarded-for", "198.51.100.20"}] ++ upgrade_headers(upgrade?)
    response = raw_request(ctx, request_method(upgrade?), request_target(form, route), headers, host_fields: duplicate_hosts(values))

    assert response.status == 400
    refute List.keymember?(response.headers, "x-request-id", 0)
    assert response.body == ""
    assert {"content-length", " 0"} in response.headers
    assert_no_gateway_side_effects(ctx.upstream)
  end

  defp duplicate_hosts(:identical), do: [{"Host", "example.com"}, {"hOsT", "example.com"}]
  defp duplicate_hosts(:conflicting), do: [{"HOST", "example.com"}, {"host", "example.net"}]
  defp request_target(:origin, route), do: route
  defp request_target(:absolute, route), do: "http://example.com" <> route
  defp request_method(true), do: "GET"
  defp request_method(false), do: "POST"
  defp upgrade_headers(false), do: []

  defp upgrade_headers(true) do
    [
      {"connection", "upgrade"},
      {"upgrade", "websocket"},
      {"sec-websocket-version", "13"},
      {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}
    ]
  end

  defp raw_request(ctx, method, target, headers \\ [], opts \\ []) do
    {:ok, socket} =
      :gen_tcp.connect(
        ~c"127.0.0.1",
        ctx.port,
        [:binary, active: false, nodelay: true],
        @connect_timeout
      )

    Agent.update(ctx.sockets, &MapSet.put(&1, socket))
    body = Keyword.get(opts, :body, "")

    request = [
      method,
      " ",
      target,
      " HTTP/1.1\r\n",
      Enum.map(Keyword.get(opts, :host_fields, [{"host", "127.0.0.1:#{ctx.port}"}]), fn {name, value} -> [name, ": ", value, "\r\n"] end),
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      upload_framing(opts, body),
      if(List.keymember?(headers, "connection", 0), do: [], else: "connection: close\r\n"),
      "\r\n",
      body
    ]

    try do
      :ok = :gen_tcp.send(socket, request)
      if after_send = Keyword.get(opts, :after_send), do: after_send.(socket)
      raw_response = receive_response(socket, "")
      response = if Keyword.get(opts, :raw_response, false), do: raw_response, else: parse_response(raw_response)

      case Keyword.get(opts, :expect_closed, false) do
        true ->
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, @receive_timeout)

        :after_write_shutdown ->
          assert {:error, reason} = :gen_tcp.recv(socket, 0, @receive_timeout)
          assert reason in [:closed, :enotconn]

        false ->
          :ok
      end

      response
    after
      :gen_tcp.close(socket)

      if Process.alive?(ctx.sockets) do
        Agent.update(ctx.sockets, &MapSet.delete(&1, socket))
      end
    end
  end

  defp set_body_read_settings(overrides) do
    config = Application.fetch_env!(:codex_pooler, OperationalSettings)
    settings = config |> Keyword.fetch!(:settings) |> Map.merge(Map.new(overrides))
    Application.put_env(:codex_pooler, OperationalSettings, Keyword.put(config, :settings, settings))
  end

  defp upload_probe(%{observe_body_read: true}) do
    observer = self()
    Code.ensure_loaded!(Plug.Conn)
    on_exit(fn -> :erlang.trace_pattern({Plug.Conn, :read_body, 2}, false, [:local]) end)
    assert :erlang.trace_pattern({Plug.Conn, :read_body, 2}, true, [:local]) == 1

    fn conn, opts ->
      :erlang.trace(self(), true, [:call, :arity, {:tracer, observer}])

      try do
        CodexPoolerWeb.Endpoint.call(conn, opts)
      after
        :erlang.trace(self(), false, [:call])
      end
    end
  end

  defp upload_probe(_context), do: CodexPoolerWeb.Endpoint

  defp upload_framing(opts, body) do
    case Keyword.get(opts, :framing, :content_length) do
      :content_length -> ["content-length: ", Integer.to_string(Keyword.get(opts, :content_length, byte_size(body))), "\r\n"]
      :chunked -> "transfer-encoding: chunked\r\n"
    end
  end

  defp send_paced_body(socket, <<>>, :chunked), do: assert(:ok = :gen_tcp.send(socket, "0\r\n\r\n"))
  defp send_paced_body(_socket, <<>>, :content_length), do: :ok

  defp send_paced_body(socket, body, framing) do
    chunk_size = min(byte_size(body), 65_536)
    <<chunk::binary-size(^chunk_size), remaining::binary>> = body
    wire = if framing == :chunked, do: [Integer.to_string(chunk_size, 16), "\r\n", chunk, "\r\n"], else: chunk
    assert :ok = :gen_tcp.send(socket, wire)

    if remaining != <<>> do
      timer = make_ref()
      Process.send_after(self(), {:next_upload_chunk, timer}, 200)
      assert_receive {:next_upload_chunk, ^timer}, 5_000
    end

    send_paced_body(socket, remaining, framing)
  end

  defp parse_error_message(:identity), do: "request body could not be parsed"
  defp parse_error_message(_encoding), do: "request body must be JSON"

  defp invalid_upload_body do
    bytes = for index <- 1..8_192, into: <<>>, do: :crypto.hash(:sha256, Integer.to_string(index))
    CodexPooler.JSON.encode!(%{"probe" => Base.encode64(bytes)}) <> "!"
  end

  defp upload_headers(ctx, encoding) do
    headers = [
      {"authorization", ctx.gateway.authorization},
      {"x-forwarded-for", "198.51.100.20"},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"connection", "keep-alive"}
    ]

    if encoding == :identity, do: headers, else: [{"content-encoding", Atom.to_string(encoding)} | headers]
  end

  defp encode_upload(body, :identity), do: body
  defp encode_upload(body, :gzip), do: :zlib.gzip(body)
  defp encode_upload(body, :deflate), do: :zlib.compress(body)

  defp receive_response(socket, acc) when byte_size(acc) <= @max_response_bytes do
    case :gen_tcp.recv(socket, 0, @receive_timeout) do
      {:ok, bytes} when byte_size(acc) + byte_size(bytes) <= @max_response_bytes ->
        response = acc <> bytes

        if response_complete?(response) do
          response
        else
          receive_response(socket, response)
        end

      {:ok, _bytes} ->
        flunk("raw HTTP response exceeded #{@max_response_bytes} bytes")

      {:error, :closed} ->
        acc

      {:error, reason} ->
        flunk("raw HTTP response did not finish: #{inspect(reason)}")
    end
  end

  defp parse_response(response) do
    case :binary.split(response, "\r\n\r\n") do
      [head, body] ->
        [status_line | headers] = :binary.split(head, "\r\n", [:global])

        case :binary.split(status_line, " ", [:global]) do
          [version, status, _reason | _rest] when version in ["HTTP/1.0", "HTTP/1.1"] ->
            %{status: String.to_integer(status), body: body, headers: Enum.map(headers, &split_header/1)}

          _other ->
            flunk("raw HTTP response had an invalid status line")
        end

      _other ->
        flunk("raw HTTP response did not contain a complete header block")
    end
  end

  defp response_complete?(response) do
    case :binary.split(response, "\r\n\r\n") do
      [head, body] ->
        case content_length(head) do
          {:ok, length} -> byte_size(body) >= length
          :error -> false
        end

      _other ->
        false
    end
  end

  defp content_length(head) do
    head
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value(:error, &parse_content_length_header/1)
  end

  defp parse_content_length_header(header) do
    case split_header(header) do
      {"content-length", value} -> parse_content_length(value)
      _other -> nil
    end
  end

  defp split_header(header) do
    case :binary.match(header, ":") do
      {separator_offset, 1} ->
        name = binary_part(header, 0, separator_offset)
        value_offset = separator_offset + 1
        value = binary_part(header, value_offset, byte_size(header) - value_offset)
        {String.downcase(name), value}

      :nomatch ->
        :error
    end
  end

  defp parse_content_length(value) do
    case Integer.parse(String.trim(value)) do
      {length, ""} when length >= 0 -> {:ok, length}
      _other -> :error
    end
  end

  defp json_field(%{body: body}, path) when byte_size(body) <= @max_json_bytes do
    body
    |> CodexPooler.JSON.decode!()
    |> get_in(Enum.map(path, &Access.key/1))
  end

  defp json_field(%{body: body}, _path) do
    flunk("raw HTTP JSON body exceeded #{@max_json_bytes} bytes (#{byte_size(body)} bytes)")
  end

  defp assert_no_gateway_side_effects(upstream) do
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp safe_stop_listener(listener) do
    ThousandIsland.stop(listener)
  catch
    :exit, _reason -> :ok
  end
end
