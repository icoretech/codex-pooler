defmodule CodexPoolerWeb.Plugs.RuntimeIngress do
  @moduledoc false

  import Plug.Conn

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Admission, as: GatewayAdmission
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Plugs.RuntimeIngress.{CompressedBody, Firewall}
  alias CodexPoolerWeb.V1.UnsupportedRoutes
  alias Plug.Conn.Query
  alias Plug.Conn.Utils

  @runtime_prefixes [
    ["backend-api", "codex"],
    ["backend-api", "files"],
    ["backend-api", "transcribe"],
    ["api", "codex", "usage"],
    ["wham", "usage"],
    ["backend-api", "wham", "agent-identities", "jwks"],
    ["backend-api", "wham", "usage"],
    ["v1"]
  ]

  @json_error_type "invalid_request_error"

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      mcp_request?(conn) ->
        settings = OperationalSettings.current()

        conn
        |> enforce_mcp_firewall(settings)
        |> admit_mcp_request()
        |> prepare_mcp_body(settings)

      runtime_path?(conn.path_info) ->
        settings = OperationalSettings.current()

        conn
        |> enforce_firewall(settings)
        |> authenticate_v1_request()
        |> reject_unsupported_v1_request()
        |> authenticate_multipart_transcribe_request()
        |> authenticate_protected_backend_raw_request()
        |> authenticate_protected_backend_json_request()
        |> maybe_decode_compressed_body(settings)

      true ->
        conn
    end
  end

  @spec send_parse_error(Plug.Conn.t()) :: Plug.Conn.t()
  def send_parse_error(conn) do
    send_runtime_error(conn, %{
      status: 400,
      code: "invalid_request",
      message: "request body must be valid JSON"
    })
  end

  @spec send_mcp_parse_error(Plug.Conn.t()) :: Plug.Conn.t()
  def send_mcp_parse_error(conn), do: send_mcp_error(conn, 400, -32_700, "parse error")

  @spec mcp_request?(Plug.Conn.t() | term()) :: boolean()
  def mcp_request?(%Plug.Conn{path_info: ["mcp"]}), do: true
  def mcp_request?(_conn), do: false

  defp enforce_mcp_firewall(conn, settings) do
    case Firewall.enforce(conn, settings) do
      {:ok, conn} -> conn
      {:error, reason} -> send_mcp_error(conn, reason.status, -32_600, reason.message)
    end
  end

  defp admit_mcp_request(%Plug.Conn{halted: true} = conn), do: conn

  defp admit_mcp_request(conn) do
    metadata = %{
      request_id: List.first(get_req_header(conn, "x-request-id")),
      method: conn.method,
      path: conn.request_path
    }

    case GatewayAdmission.admit_mcp(metadata) do
      {:ok, lease} ->
        register_before_send(conn, fn conn ->
          GatewayAdmission.release_admission(lease)
          conn
        end)

      {:error, _reason} ->
        send_mcp_error(conn, 503, -32_000, "MCP route class is temporarily overloaded")
    end
  end

  defp prepare_mcp_body(%Plug.Conn{halted: true} = conn, _settings), do: conn

  defp prepare_mcp_body(%Plug.Conn{method: method} = conn, _settings) when method != "POST",
    do: conn

  defp prepare_mcp_body(conn, settings) do
    with :ok <- reject_mcp_compressed_body(conn),
         :ok <- require_mcp_json_content_type(conn),
         {:ok, body, conn} <- read_mcp_body(conn, settings),
         {:ok, body_params} <- decode_mcp_body(body) do
      put_mcp_body_params(conn, body_params)
    else
      {:error, status, code, message} -> send_mcp_error(conn, status, code, message)
      {:error, status, code, message, conn} -> send_mcp_error(conn, status, code, message)
    end
  end

  defp reject_mcp_compressed_body(conn) do
    case CompressedBody.content_encoding(conn) do
      :none ->
        :ok

      {:ok, "identity"} ->
        :ok

      {:ok, _encoding} ->
        {:error, 415, -32_600, "compressed MCP request bodies are not supported"}
    end
  end

  defp require_mcp_json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _rest] ->
        if json_content_type?(content_type) do
          :ok
        else
          {:error, 415, -32_600, "content-type must be application/json"}
        end

      [] ->
        {:error, 415, -32_600, "content-type must be application/json"}
    end
  end

  defp json_content_type?(content_type) do
    case Utils.content_type(content_type) do
      {:ok, "application", subtype, _params} ->
        subtype == "json" or String.ends_with?(subtype, "+json")

      _other ->
        false
    end
  end

  defp read_mcp_body(conn, settings) do
    read_opts = [
      length: settings.max_decompressed_body_bytes,
      read_length: settings.max_decompressed_body_bytes,
      read_timeout: settings.decompression_timeout_ms
    ]

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, 413, -32_600, "request body is too large", conn}
      {:error, :timeout} -> {:error, 408, -32_600, "request body read timed out"}
      {:error, _reason} -> {:error, 400, -32_600, "request body could not be read"}
    end
  end

  defp decode_mcp_body(body) do
    case Jason.decode(body) do
      {:ok, value} when is_list(value) -> {:ok, %{"_json" => value}}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:ok, %{"_json_scalar" => true}}
      {:error, _reason} -> {:error, 400, -32_700, "parse error"}
    end
  end

  defp put_mcp_body_params(conn, body_params) do
    query_params = Query.decode(conn.query_string)
    path_params = make_empty_if_unfetched(conn.path_params)
    existing_params = make_empty_if_unfetched(conn.params)

    params =
      query_params
      |> Map.merge(existing_params)
      |> Map.merge(body_params)
      |> Map.merge(path_params)

    %{conn | body_params: body_params, params: params, query_params: query_params}
  end

  defp make_empty_if_unfetched(%Plug.Conn.Unfetched{}), do: %{}
  defp make_empty_if_unfetched(params), do: params

  defp enforce_firewall(conn, settings) do
    case Firewall.enforce(conn, settings) do
      {:ok, conn} -> conn
      {:error, reason} -> send_runtime_error(conn, reason)
    end
  end

  defp authenticate_v1_request(%Plug.Conn{halted: true} = conn), do: conn

  defp authenticate_v1_request(conn) do
    if v1_request?(conn) do
      case authenticate_runtime_api_request(conn) do
        {:ok, conn} -> ensure_v1_compatibility(conn)
        {:error, reason, conn} -> send_runtime_error(conn, reason)
      end
    else
      conn
    end
  end

  defp reject_unsupported_v1_request(%Plug.Conn{halted: true} = conn), do: conn

  defp reject_unsupported_v1_request(conn) do
    if UnsupportedRoutes.unsupported?(conn) do
      send_runtime_error(conn, unsupported_v1_error())
    else
      conn
    end
  end

  defp authenticate_multipart_transcribe_request(conn) do
    authenticate_when(conn, &multipart_transcribe_request?/1)
  end

  defp authenticate_protected_backend_raw_request(conn) do
    authenticate_when(conn, &protected_backend_raw_request?/1)
  end

  defp authenticate_protected_backend_json_request(conn) do
    authenticate_when(conn, &protected_backend_json_request?/1)
  end

  defp authenticate_when(%Plug.Conn{halted: true} = conn, _predicate), do: conn

  defp authenticate_when(conn, predicate) when is_function(predicate, 1) do
    if predicate.(conn) do
      case authenticate_runtime_api_request(conn) do
        {:ok, conn} -> conn
        {:error, reason, conn} -> send_runtime_error(conn, reason)
      end
    else
      conn
    end
  end

  defp maybe_decode_compressed_body(%Plug.Conn{halted: true} = conn, _settings), do: conn

  defp maybe_decode_compressed_body(conn, settings) do
    case CompressedBody.content_encoding(conn) do
      {:ok, "identity"} ->
        conn

      {:ok, _encoding} ->
        case authenticate_runtime_api_request(conn) do
          {:ok, conn} -> decode_or_send_compressed_body(conn, settings)
          {:error, reason, conn} -> send_runtime_error(conn, reason)
        end

      :none ->
        conn
    end
  end

  defp authenticate_runtime_api_request(%Plug.Conn{private: %{runtime_api_auth: _auth}} = conn),
    do: {:ok, conn}

  defp authenticate_runtime_api_request(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> authenticate_authorization_header(conn)
    |> case do
      {:ok, auth} -> {:ok, put_private(conn, :runtime_api_auth, auth)}
      {:error, reason} -> {:error, Map.put(reason, :status, 401), conn}
    end
  end

  defp authenticate_authorization_header(header, conn) do
    if v1_request?(conn) do
      Access.authenticate_v1_authorization_header(header)
    else
      Access.authenticate_authorization_header(header)
    end
  end

  defp ensure_v1_compatibility(%Plug.Conn{private: %{runtime_api_auth: %{pool: pool}}} = conn) do
    if pool.status == "active" and Pools.v1_compatibility_enabled?(pool) do
      conn
    else
      send_runtime_error(conn, %{
        status: 403,
        code: "v1_compatibility_disabled",
        message: "OpenAI /v1 compatibility is disabled for this pool"
      })
    end
  end

  defp ensure_v1_compatibility(conn), do: conn

  defp multipart_transcribe_request?(conn) do
    conn.method == "POST" and conn.path_info == ["backend-api", "transcribe"] and
      multipart_content_type?(conn)
  end

  defp multipart_content_type?(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> case do
      nil ->
        false

      content_type ->
        content_type |> String.downcase() |> String.starts_with?("multipart/form-data")
    end
  end

  @spec protected_backend_json_request?(Plug.Conn.t() | term()) :: boolean()
  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "responses"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "v1", "responses"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "v1", "chat", "completions"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "images", "generations"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "images", "edits"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "responses", "compact"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "v1", "responses", "compact"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "thread", "goal", action]
      })
      when action in ["get", "set", "clear"],
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "analytics-events", "events"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "memories", "trace_summarize"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "alpha", "search"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "safety", "arc"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "files"]
      }),
      do: true

  def protected_backend_json_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "files", file_id, "uploaded"]
      })
      when is_binary(file_id),
      do: true

  def protected_backend_json_request?(_conn), do: false

  @spec protected_backend_raw_request?(Plug.Conn.t() | term()) :: boolean()
  def protected_backend_raw_request?(%Plug.Conn{
        method: "POST",
        path_info: ["backend-api", "codex", "realtime", "calls"]
      }),
      do: true

  def protected_backend_raw_request?(_conn), do: false

  defp decode_or_send_compressed_body(conn, settings) do
    case CompressedBody.decode(conn, settings) do
      {:ok, conn} -> conn
      {:error, reason, conn} -> send_runtime_error(conn, reason)
      {:error, reason} -> send_runtime_error(conn, reason)
    end
  end

  defp runtime_path?(path_info) do
    Enum.any?(@runtime_prefixes, &List.starts_with?(path_info, &1))
  end

  defp v1_request?(conn), do: List.starts_with?(conn.path_info, ["v1"])

  defp unsupported_v1_error do
    %{
      status: 404,
      code: "unsupported_endpoint",
      message: "Unsupported OpenAI /v1 endpoint"
    }
  end

  defp send_runtime_error(conn, reason) do
    send_runtime_error(conn, reason.status, reason.code, reason.message)
  end

  defp send_runtime_error(conn, status, code, message) do
    body = %{
      "error" => %{
        "message" => message,
        "type" => @json_error_type,
        "code" => to_string(code),
        "param" => nil
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp send_mcp_error(conn, status, code, message) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => code, "message" => message}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
