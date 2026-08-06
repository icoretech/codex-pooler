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

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings, [])

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

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous_settings) end)

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
        plug: CodexPoolerWeb.Endpoint,
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

  defp raw_request(ctx, method, target, headers \\ []) do
    {:ok, socket} =
      :gen_tcp.connect(
        ~c"127.0.0.1",
        ctx.port,
        [:binary, active: false, nodelay: true],
        @connect_timeout
      )

    Agent.update(ctx.sockets, &MapSet.put(&1, socket))

    request = [
      method,
      " ",
      target,
      " HTTP/1.1\r\n",
      "host: 127.0.0.1:",
      Integer.to_string(ctx.port),
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "content-length: 0\r\n",
      "connection: close\r\n\r\n"
    ]

    try do
      :ok = :gen_tcp.send(socket, request)
      socket |> receive_response("") |> parse_response()
    after
      :gen_tcp.close(socket)

      if Process.alive?(ctx.sockets) do
        Agent.update(ctx.sockets, &MapSet.delete(&1, socket))
      end
    end
  end

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
        [status_line | _headers] = :binary.split(head, "\r\n", [:global])

        case :binary.split(status_line, " ", [:global]) do
          ["HTTP/1.1", status, _reason | _rest] ->
            %{status: String.to_integer(status), body: body}

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
    |> Enum.find_value(:error, fn header ->
      case :binary.match(header, ":") do
        {separator_offset, 1} ->
          name = binary_part(header, 0, separator_offset)
          value_offset = separator_offset + 1
          value = binary_part(header, value_offset, byte_size(header) - value_offset)

          if String.downcase(name) == "content-length" do
            case Integer.parse(String.trim(value)) do
              {length, ""} when length >= 0 -> {:ok, length}
              _other -> :error
            end
          end

        :nomatch ->
          nil
      end
    end)
  end

  defp json_field(%{body: body}, path) when byte_size(body) <= @max_json_bytes do
    body
    |> Jason.decode!()
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
    try do
      ThousandIsland.stop(listener)
    catch
      :exit, _reason -> :ok
    end
  end
end
