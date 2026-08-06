defmodule CodexPoolerWeb.McpController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.MCP
  alias CodexPooler.MCP.{ToolDispatch, ToolRegistry}
  alias CodexPoolerWeb.Mcp.{Envelope, Headers, Protocol}

  @allow "POST, OPTIONS"
  @server_name "codex-pooler"

  def get(conn, _params), do: method_not_allowed(conn)
  def delete(conn, _params), do: method_not_allowed(conn)

  def options(conn, _params) do
    conn
    |> put_resp_header("allow", @allow)
    |> send_resp(204, "")
  end

  def post(conn, _params) do
    with :ok <- ensure_origin(conn),
         :ok <- ensure_content_type(conn),
         :ok <- ensure_accept(conn),
         {:ok, message} <- read_message(conn),
         :ok <- validate_message(message),
         {:ok, era} <- ensure_protocol_version(conn, message),
         {:ok, auth} <- authenticate(conn) do
      dispatch_message(conn, message, auth, era)
    else
      {:error, status, body} when is_map(body) -> send_json_rpc_body(conn, status, body)
      {:error, status, code, message, id} -> send_json_rpc_error(conn, status, code, message, id)
    end
  end

  defp method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", @allow)
    |> send_resp(405, "")
  end

  defp ensure_origin(conn) do
    case List.first(get_req_header(conn, "origin")) do
      nil ->
        :ok

      "" ->
        :ok

      origin ->
        if trusted_origin?(origin) do
          :ok
        else
          {:error, 403, -32_600, "origin is not allowed", nil}
        end
    end
  end

  defp trusted_origin?(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    uri.scheme in ["http", "https"] and
      uri.host in ["localhost", "127.0.0.1", "::1"]
  end

  defp ensure_content_type(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> case do
      nil ->
        {:error, 415, -32_600, "content-type must be application/json", nil}

      content_type ->
        content_type = String.downcase(content_type)

        if String.starts_with?(content_type, "application/json") or
             String.contains?(content_type, "+json") do
          :ok
        else
          {:error, 415, -32_600, "content-type must be application/json", nil}
        end
    end
  end

  defp ensure_accept(conn) do
    accepted =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(
        &(&1
          |> String.split(";")
          |> List.first()
          |> String.trim()
          |> String.downcase())
      )
      |> MapSet.new()

    if MapSet.member?(accepted, "application/json") and
         MapSet.member?(accepted, "text/event-stream") do
      :ok
    else
      {:error, 406, -32_600, "accept must include application/json and text/event-stream", nil}
    end
  end

  defp ensure_protocol_version(_conn, %{"method" => _method} = message)
       when not is_map_key(message, "id"),
       do: {:ok, :legacy}

  defp ensure_protocol_version(conn, %{"method" => "initialize"} = message) do
    with :ok <- ensure_protocol_header(conn) do
      params = Map.get(message, "params", %{})
      request_id = id(message)

      initialize_protocol_version(Map.get(params, "protocolVersion"), request_id)
    end
  end

  defp ensure_protocol_version(
         conn,
         %{"method" => method, "id" => _request_id} = message
       ) do
    params = Map.get(message, "params", %{})

    with {:ok, protocol_header} <- Headers.protocol_version(conn),
         {:ok, era} <- Protocol.detect_era(method, params, protocol_header),
         :ok <- validate_modern_request(conn, era, method, params) do
      {:ok, era}
    else
      {:error, :header_mismatch} ->
        {:error, 400, Envelope.header_mismatch_error(id(message))}

      {:error, :unsupported_protocol_version} ->
        {:error, 400, Envelope.unsupported_protocol_version_error(id(message))}

      {:error, :invalid_params} ->
        {:error, 400, -32_602, "invalid params", id(message)}
    end
  end

  defp ensure_protocol_version(conn, _message) do
    case ensure_protocol_header(conn) do
      :ok -> {:ok, :legacy}
      error -> error
    end
  end

  defp validate_modern_request(_conn, :legacy, _method, _params), do: :ok

  defp validate_modern_request(conn, {:modern, _version}, method, params) do
    with :ok <- Protocol.validate_modern_meta(params) do
      Headers.validate_modern(conn, method, params)
    end
  end

  defp ensure_protocol_header(conn) do
    case List.first(get_req_header(conn, "mcp-protocol-version")) do
      nil ->
        :ok

      version ->
        if legacy_protocol_version?(version) do
          :ok
        else
          {:error, 400, -32_600, "unsupported MCP protocol version", nil}
        end
    end
  end

  defp initialize_protocol_version(version, request_id) when is_binary(version) do
    if legacy_protocol_version?(version) do
      {:ok, :legacy}
    else
      initialize_protocol_error(request_id)
    end
  end

  defp initialize_protocol_version(_version, request_id),
    do: initialize_protocol_error(request_id)

  defp initialize_protocol_error(request_id) do
    {:error, 400, -32_600, "unsupported initialize protocol version", request_id}
  end

  defp legacy_protocol_version?(version), do: version in Protocol.legacy_protocol_versions()

  defp authenticate(conn) do
    conn
    |> bearer_token()
    |> MCP.authenticate_token()
    |> case do
      {:ok, auth} -> {:ok, auth}
      {:error, reason} -> mcp_auth_error(reason)
    end
  end

  defp bearer_token(conn) do
    with [authorization | _rest] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- authorization do
      String.trim(token)
    else
      _other -> nil
    end
  end

  defp mcp_auth_error(%{code: code, message: message})
       when code in [
              :mcp_service_disabled,
              :mcp_account_disabled,
              :mcp_operator_deleted,
              :mcp_operator_disabled,
              :mcp_operator_password_change_required
            ] do
    {:error, 403, -32_000, message, nil}
  end

  defp mcp_auth_error(_reason) do
    {:error, 401, -32_000, "MCP bearer token is required", nil}
  end

  defp read_message(%Plug.Conn{private: %{mcp_json_parse_error: true}}) do
    {:error, 400, -32_700, "parse error", nil}
  end

  defp read_message(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}) do
    {:error, 400, -32_600, "request body must be JSON", nil}
  end

  defp read_message(%Plug.Conn{body_params: %{"_json" => value}}) when is_list(value) do
    {:error, 400, -32_600, "batch JSON-RPC is not supported", nil}
  end

  defp read_message(%Plug.Conn{body_params: %{"_json_scalar" => true}}) do
    {:error, 400, -32_600, "request body must be a JSON-RPC object", nil}
  end

  defp read_message(%Plug.Conn{body_params: params}) when is_map(params), do: {:ok, params}

  defp validate_message(%{"jsonrpc" => "2.0", "method" => method} = message)
       when is_binary(method) do
    cond do
      Map.has_key?(message, "result") or Map.has_key?(message, "error") ->
        {:error, 400, -32_600, "JSON-RPC message cannot mix request and response fields",
         id(message)}

      Map.has_key?(message, "id") and not valid_id?(Map.get(message, "id")) ->
        {:error, 400, -32_600, "request id must be a string or number", nil}

      Map.has_key?(message, "params") and not is_map(Map.get(message, "params")) ->
        {:error, 400, -32_602, "params must be an object", id(message)}

      true ->
        :ok
    end
  end

  defp validate_message(%{"jsonrpc" => "2.0"} = message) do
    cond do
      Map.has_key?(message, "id") and valid_id?(Map.get(message, "id")) and
          (Map.has_key?(message, "result") or Map.has_key?(message, "error")) ->
        :ok

      Map.has_key?(message, "id") and not valid_id?(Map.get(message, "id")) ->
        {:error, 400, -32_600, "request id must be a string or number", nil}

      true ->
        {:error, 400, -32_600,
         "request body must be a JSON-RPC request, notification, or response", nil}
    end
  end

  defp validate_message(_message) do
    {:error, 400, -32_600, "request body must be a JSON-RPC object", nil}
  end

  defp dispatch_message(
         conn,
         %{"method" => "server/discover", "id" => request_id},
         _auth,
         {:modern, _version}
       ) do
    send_json_rpc_result(conn, request_id, Envelope.discover_result(app_version()))
  end

  defp dispatch_message(
         conn,
         %{"method" => "tools/list", "id" => request_id} = message,
         _auth,
         {:modern, _version}
       ) do
    params = Map.get(message, "params", %{})

    {:ok, %{tools: tools}} = ToolRegistry.list_tools(params)

    result = Envelope.tools_list_result(%{"tools" => tools}, app_version())
    send_json_rpc_result(conn, request_id, result)
  end

  defp dispatch_message(
         conn,
         %{"method" => "tools/call", "id" => request_id} = message,
         auth,
         {:modern, _version}
       ) do
    params = Map.get(message, "params", %{})

    with {:ok, name, arguments} <- tool_call_params(params),
         {:ok, result} <- ToolDispatch.call(name, arguments, %{auth: auth}) do
      result = Envelope.tools_call_result(result, app_version())
      send_json_rpc_result(conn, request_id, result)
    else
      {:error, %{code: :tool_not_found, message: message}} ->
        send_json_rpc_error(conn, 200, -32_602, message, request_id)

      {:error, message} when is_binary(message) ->
        send_json_rpc_error(conn, 200, -32_602, message, request_id)
    end
  end

  defp dispatch_message(
         conn,
         %{"method" => _method, "id" => request_id},
         _auth,
         {:modern, _version}
       ) do
    send_json_rpc_error(conn, 404, -32_601, "method not found", request_id)
  end

  defp dispatch_message(conn, message, auth, _era), do: dispatch_message(conn, message, auth)

  defp dispatch_message(
         conn,
         %{"method" => "initialize", "id" => request_id, "params" => params},
         _auth
       ) do
    case Map.get(params, "protocolVersion") do
      version when is_binary(version) ->
        if legacy_protocol_version?(version) do
          send_json_rpc_result(conn, request_id, %{
            "protocolVersion" => version,
            "serverInfo" => %{"name" => @server_name, "version" => app_version()},
            "capabilities" => %{"tools" => %{"listChanged" => false}}
          })
        else
          send_json_rpc_error(
            conn,
            400,
            -32_600,
            "unsupported initialize protocol version",
            request_id
          )
        end

      _version ->
        send_json_rpc_error(
          conn,
          400,
          -32_600,
          "unsupported initialize protocol version",
          request_id
        )
    end
  end

  defp dispatch_message(conn, %{"method" => "ping", "id" => request_id}, _auth) do
    send_json_rpc_result(conn, request_id, %{})
  end

  defp dispatch_message(conn, %{"method" => "tools/list", "id" => request_id} = message, _auth) do
    params = Map.get(message, "params", %{})

    {:ok, %{tools: tools}} = ToolRegistry.list_tools(params)
    send_json_rpc_result(conn, request_id, %{"tools" => tools})
  end

  defp dispatch_message(conn, %{"method" => "tools/call", "id" => request_id} = message, auth) do
    params = Map.get(message, "params", %{})

    with {:ok, name, arguments} <- tool_call_params(params),
         {:ok, result} <- ToolDispatch.call(name, arguments, %{auth: auth}) do
      send_json_rpc_result(conn, request_id, result)
    else
      {:error, %{code: :tool_not_found, message: message}} ->
        send_json_rpc_error(conn, 200, -32_602, message, request_id)

      {:error, message} when is_binary(message) ->
        send_json_rpc_error(conn, 200, -32_602, message, request_id)
    end
  end

  defp dispatch_message(conn, %{"method" => "notifications/initialized"}, _auth) do
    send_resp(conn, 202, "")
  end

  defp dispatch_message(conn, %{"method" => _method, "id" => request_id}, _auth) do
    send_json_rpc_error(conn, 200, -32_601, "method not found", request_id)
  end

  defp dispatch_message(conn, %{"method" => _method}, _auth) do
    send_resp(conn, 202, "")
  end

  defp dispatch_message(conn, %{"result" => _result}, _auth), do: send_resp(conn, 202, "")
  defp dispatch_message(conn, %{"error" => _error}, _auth), do: send_resp(conn, 202, "")

  defp tool_call_params(%{"name" => name} = params) when is_binary(name) and name != "" do
    arguments = Map.get(params, "arguments", %{})

    if is_map(arguments) do
      {:ok, name, arguments}
    else
      {:error, "tools/call arguments must be an object"}
    end
  end

  defp tool_call_params(_params), do: {:error, "tools/call name is required"}

  defp send_json_rpc_result(conn, request_id, result) do
    conn
    |> put_resp_content_type("application/json")
    |> json(%{"jsonrpc" => "2.0", "id" => request_id, "result" => result})
  end

  defp send_json_rpc_error(conn, status, code, message, request_id) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{"code" => code, "message" => message}
    }

    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(body)
  end

  defp send_json_rpc_body(conn, status, body) do
    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(body)
  end

  defp id(%{"id" => id}) do
    if valid_id?(id), do: id, else: nil
  end

  defp id(_message), do: nil

  defp valid_id?(id) when is_binary(id), do: id != ""
  defp valid_id?(id) when is_integer(id), do: true
  defp valid_id?(id) when is_float(id), do: true
  defp valid_id?(_id), do: false

  defp app_version do
    case Application.spec(:codex_pooler, :vsn) do
      nil -> "0.0.0"
      version -> List.to_string(version)
    end
  end
end
