defmodule CodexPoolerWeb.Plugs.RuntimeIngress do
  @moduledoc false

  import Plug.Conn

  alias CodexPooler.Gateway.Admission, as: GatewayAdmission
  alias CodexPooler.Gateway.ErrorClassification
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPoolerWeb.GatewayControllerHelpers
  alias CodexPoolerWeb.Mcp.Authentication
  alias CodexPoolerWeb.Plugs.BackendFilesMultipartGuard
  alias CodexPoolerWeb.Plugs.RuntimeIngress.{BodyReader, CompressedBody, Firewall, Path}
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall.Decision
  alias CodexPoolerWeb.V1.UnsupportedRoutes
  alias Plug.Conn.Query
  alias Plug.Conn.Utils

  @parser_settings_private_key :codex_pooler_runtime_ingress_settings
  @parser_error_scope_private_key :codex_pooler_json_parse_error_scope

  @pruned_runtime_helper_routes [
    {"GET", ["backend-api", "codex", "agent-identities", "jwks"]},
    {"GET", ["backend-api", "wham", "agent-identities", "jwks"]},
    {"POST", ["api", "codex", "rate-limit-reset-credits", "consume"]},
    {"POST", ["wham", "rate-limit-reset-credits", "consume"]},
    {"POST", ["backend-api", "wham", "rate-limit-reset-credits", "consume"]},
    {"POST", ["backend-api", "codex", "thread", "goal", "get"]},
    {"POST", ["backend-api", "codex", "thread", "goal", "set"]},
    {"POST", ["backend-api", "codex", "thread", "goal", "clear"]},
    {"POST", ["backend-api", "codex", "analytics-events", "events"]},
    {"POST", ["backend-api", "codex", "memories", "trace_summarize"]},
    {"POST", ["backend-api", "codex", "alpha", "search"]},
    {"POST", ["backend-api", "codex", "realtime", "calls"]},
    {"POST", ["backend-api", "codex", "safety", "arc"]}
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = Path.populate(conn)
    route_request(conn, Path.fetch(conn))
  end

  defp route_request(conn, %{scope: :mcp, unsafe_segment?: true}) do
    send_mcp_error(conn, 400, -32_600, "invalid request")
  end

  defp route_request(conn, %{scope: :runtime, unsafe_segment?: true}) do
    send_runtime_error(conn, 400, "invalid_request", "request path is invalid")
  end

  defp route_request(conn, %{scope: :mcp}) do
    settings = operational_settings(conn)

    conn
    |> put_json_parser_context(settings, :mcp)
    |> enforce_mcp_firewall(settings)
    |> respond_to_mcp_method()
    |> authenticate_mcp_request()
    |> admit_mcp_request()
    |> prepare_mcp_body(settings)
  end

  defp route_request(conn, path) do
    if path.scope == :runtime do
      settings = operational_settings(conn)

      conn
      |> put_json_parser_context(settings, json_parse_error_scope(conn))
      |> enforce_firewall(settings)
      |> reject_pruned_runtime_helper()
      |> authenticate_v1_request()
      |> reject_unsupported_v1_request()
      |> authenticate_protected_backend_json_request()
      |> enforce_image_generation_permission()
      |> enforce_audio_transcription_permission()
      |> BackendFilesMultipartGuard.call([])
      |> maybe_decode_compressed_body(settings)
    else
      conn
    end
  end

  @spec handle_parser_error(Plug.Conn.t(), Exception.t()) :: {:ok, Plug.Conn.t()} | :unhandled
  def handle_parser_error(conn, %Plug.Parsers.ParseError{}) do
    send_scoped_parser_error(conn, 400, "invalid_request", "request body could not be parsed", -32_700)
  end

  def handle_parser_error(conn, %Plug.Conn.InvalidQueryError{}) do
    send_scoped_parser_error(conn, 400, "invalid_request", "request query is invalid", -32_600)
  end

  def handle_parser_error(conn, %Plug.Parsers.RequestTooLargeError{}) do
    conn = put_resp_header(conn, "connection", "close")

    case {Path.fetch(conn).scope, Enum.any?(get_req_header(conn, "content-type"), &json_content_type?/1)} do
      {:passthrough, _json?} ->
        :unhandled

      {_scope, true} ->
        limit = operational_settings(conn).max_decompressed_body_bytes
        message = "decompressed request body exceeds the #{limit}-byte limit; ask the operator to increase ingress.max_decompressed_body_bytes in System > Firewall before retrying"
        send_scoped_parser_error(conn, 413, "decompressed_request_too_large", message, -32_600)

      {_scope, false} ->
        send_scoped_parser_error(conn, 413, "request_too_large", "request body is too large", -32_600)
    end
  end

  @spec handle_body_read_timeout(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_body_read_timeout(%Plug.Conn{private: %{codex_pooler_body_read_timeout: true}} = conn) do
    error = BodyReader.timeout_error()
    {:ok, conn} = send_scoped_parser_error(conn, error.status, error.code, error.message, -32_600)
    conn
  end

  def handle_body_read_timeout(conn), do: conn

  defp send_scoped_parser_error(conn, status, code, message, mcp_code) do
    case Path.fetch(conn).scope do
      :runtime ->
        {:ok, send_runtime_error(conn, status, code, message)}

      :mcp ->
        message = if mcp_code == -32_700, do: "parse error", else: message
        {:ok, send_mcp_error(conn, status, mcp_code, message)}

      :passthrough ->
        :unhandled
    end
  end

  defp enforce_mcp_firewall(conn, settings) do
    case Firewall.evaluate(conn, settings) do
      {conn, %Decision{outcome: :allow}} ->
        conn

      {conn, %Decision{outcome: :deny} = decision} ->
        :ok = Firewall.observe_denial(decision, :mcp)
        send_mcp_firewall_error(conn, decision)
    end
  end

  defp respond_to_mcp_method(%Plug.Conn{halted: true} = conn), do: conn
  defp respond_to_mcp_method(%Plug.Conn{method: "POST"} = conn), do: conn

  defp respond_to_mcp_method(conn) do
    status = if conn.method == "OPTIONS", do: 204, else: 405

    conn
    |> put_resp_header("allow", "POST, OPTIONS")
    |> send_resp(status, "")
    |> halt()
  end

  defp authenticate_mcp_request(%Plug.Conn{halted: true} = conn), do: conn

  defp authenticate_mcp_request(%Plug.Conn{method: "POST"} = conn) do
    case Authentication.authenticate(conn) do
      {:ok, auth} -> put_private(conn, :codex_pooler_mcp_auth, auth)
      {:error, status, code, message, nil} -> send_mcp_error(conn, status, code, message)
    end
  end

  defp authenticate_mcp_request(conn), do: conn

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

  defp json_parse_error_scope(conn) do
    if protected_backend_json_request?(conn), do: :protected_backend, else: :passthrough
  end

  defp put_json_parser_context(conn, settings, error_scope) do
    conn
    |> put_private(@parser_settings_private_key, settings)
    |> put_private(@parser_error_scope_private_key, error_scope)
  end

  defp operational_settings(%Plug.Conn{
         private: %{@parser_settings_private_key => %OperationalSettings{} = settings}
       }),
       do: settings

  defp operational_settings(_conn), do: OperationalSettings.current()

  defp read_mcp_body(conn, settings) do
    timeout_ms = Map.get(settings, :body_read_timeout_ms) || settings.decompression_timeout_ms

    case BodyReader.read(conn, settings.max_decompressed_body_bytes, timeout_ms) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, 413, -32_600, "request body is too large", conn}
      {:error, :timeout, conn} -> {:error, 408, -32_600, "request body read timed out", conn}
      {:error, _reason, conn} -> {:error, 400, -32_600, "request body could not be read", conn}
    end
  end

  defp decode_mcp_body(body) do
    case CodexPooler.JSON.decode(body) do
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
  rescue
    error in Plug.Conn.InvalidQueryError ->
      {:ok, conn} = handle_parser_error(conn, error)
      conn
  end

  defp make_empty_if_unfetched(%Plug.Conn.Unfetched{}), do: %{}
  defp make_empty_if_unfetched(params), do: params

  defp enforce_firewall(conn, settings) do
    case Firewall.evaluate(conn, settings) do
      {conn, %Decision{outcome: :allow}} ->
        conn

      {conn, %Decision{outcome: :deny} = decision} ->
        :ok = Firewall.observe_denial(decision, :runtime)
        send_runtime_error(conn, firewall_error(decision))
    end
  end

  defp firewall_error(%Decision{reason: :settings_unavailable}) do
    %{
      status: 503,
      code: "settings_unavailable",
      message: "runtime settings are temporarily unavailable"
    }
  end

  defp firewall_error(%Decision{}) do
    %{status: 403, code: "access_denied", message: "client IP is not allowed"}
  end

  defp send_mcp_firewall_error(conn, %Decision{reason: :settings_unavailable}) do
    send_mcp_error(conn, 503, -32_000, "runtime settings are temporarily unavailable")
  end

  defp send_mcp_firewall_error(conn, %Decision{}) do
    send_mcp_error(conn, 403, -32_600, "client IP is not allowed")
  end

  defp authenticate_v1_request(%Plug.Conn{halted: true} = conn), do: conn

  defp authenticate_v1_request(conn) do
    if v1_request?(conn) do
      case GatewayControllerHelpers.authenticate_v1(conn) do
        {:ok, auth} -> put_private(conn, :runtime_api_auth, auth)
        {:error, reason} -> send_runtime_error(conn, reason)
      end
    else
      conn
    end
  end

  defp reject_unsupported_v1_request(%Plug.Conn{halted: true} = conn), do: conn

  defp reject_unsupported_v1_request(conn) do
    cond do
      UnsupportedRoutes.unsupported?(conn) -> send_runtime_error(conn, unsupported_v1_error())
      UnsupportedRoutes.agents_family?(conn) -> send_runtime_error(conn, unsupported_agents_error())
      true -> conn
    end
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
    case GatewayControllerHelpers.authenticate(conn) do
      {:ok, auth} -> {:ok, put_private(conn, :runtime_api_auth, auth)}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp enforce_image_generation_permission(%Plug.Conn{halted: true} = conn), do: conn

  defp enforce_image_generation_permission(%Plug.Conn{private: %{runtime_api_auth: %{pool: pool}}} = conn) do
    if image_generation_request?(conn) and not PoolRouting.allow_image_generation?(pool) do
      send_runtime_error(conn, %{
        status: 403,
        code: "image_generation_disabled",
        message: "Image generation is disabled for this pool"
      })
    else
      conn
    end
  end

  defp enforce_image_generation_permission(conn), do: conn

  defp image_generation_request?(%Plug.Conn{method: "POST"} = conn) do
    Path.decoded_segments(conn) in [
      ["backend-api", "codex", "images", "generations"],
      ["backend-api", "codex", "images", "edits"],
      ["v1", "images", "generations"],
      ["v1", "images", "edits"]
    ]
  end

  defp image_generation_request?(_conn), do: false

  defp enforce_audio_transcription_permission(%Plug.Conn{halted: true} = conn), do: conn

  defp enforce_audio_transcription_permission(%Plug.Conn{method: "POST", private: %{runtime_api_auth: %{pool: pool}}} = conn) do
    if Path.decoded_segments(conn) in [["backend-api", "transcribe"], ["v1", "audio", "transcriptions"]] and not PoolRouting.allow_audio_transcription?(pool) do
      send_runtime_error(conn, %{
        status: 403,
        code: "audio_transcription_disabled",
        message: "Audio transcription is disabled for this pool"
      })
    else
      conn
    end
  end

  defp enforce_audio_transcription_permission(conn), do: conn

  @spec authenticated_multipart_media_request?(Plug.Conn.t()) :: boolean()
  def authenticated_multipart_media_request?(%Plug.Conn{method: "POST", private: %{runtime_api_auth: %{api_key: _key, pool: _pool}}} = conn) do
    Path.decoded_segments(conn) in [
      ["backend-api", "transcribe"],
      ["v1", "files"],
      ["v1", "audio", "transcriptions"],
      ["v1", "images", "edits"]
    ]
  end

  def authenticated_multipart_media_request?(_conn), do: false

  @spec protected_backend_json_request?(Plug.Conn.t() | term()) :: boolean()
  def protected_backend_json_request?(%Plug.Conn{method: method} = conn) when method in ["POST", "PUT", "PATCH", "DELETE"] do
    path_info = Path.decoded_segments(conn)

    path_info in [
      ["backend-api", "codex", "responses"],
      ["backend-api", "codex", "v1", "responses"],
      ["backend-api", "codex", "v1", "chat", "completions"],
      ["backend-api", "codex", "images", "generations"],
      ["backend-api", "codex", "images", "edits"],
      ["backend-api", "codex", "responses", "compact"],
      ["backend-api", "codex", "v1", "responses", "compact"],
      ["backend-api", "transcribe"],
      ["backend-api", "files"]
    ] or match?(["backend-api", "files", file_id, "uploaded"] when is_binary(file_id), path_info)
  end

  def protected_backend_json_request?(_conn), do: false

  @spec pruned_runtime_helper_request?(Plug.Conn.t()) :: boolean()
  defp pruned_runtime_helper_request?(%Plug.Conn{method: method} = conn) do
    {method, Path.decoded_segments(conn)} in @pruned_runtime_helper_routes
  end

  defp reject_pruned_runtime_helper(%Plug.Conn{halted: true} = conn), do: conn

  defp reject_pruned_runtime_helper(conn) do
    if pruned_runtime_helper_request?(conn) do
      send_pruned_runtime_helper_absent(conn)
    else
      conn
    end
  end

  defp decode_or_send_compressed_body(conn, settings) do
    case CompressedBody.decode(conn, settings) do
      {:ok, conn} -> conn
      {:error, reason, conn} -> send_runtime_error(conn, reason)
      {:error, reason} -> send_runtime_error(conn, reason)
    end
  rescue
    error in Plug.Conn.InvalidQueryError ->
      {:ok, conn} = handle_parser_error(conn, error)
      conn
  end

  defp send_pruned_runtime_helper_absent(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(404, "Not Found")
    |> halt()
  end

  defp v1_request?(conn), do: List.starts_with?(Path.decoded_segments(conn), ["v1"])

  defp unsupported_v1_error do
    %{
      status: 404,
      code: "unsupported_endpoint",
      message: "Unsupported OpenAI /v1 endpoint"
    }
  end

  defp unsupported_agents_error do
    %{
      status: 404,
      code: "unsupported_endpoint",
      message: "Unsupported OpenAI /v1 endpoint: the beta Agents API is not supported"
    }
  end

  defp send_runtime_error(conn, reason) do
    send_runtime_error(conn, reason.status, reason.code, reason.message)
  end

  # findings#191: this plug answers before the controller does, so it authors
  # its own envelope. It used to hardcode the client class, which typed the
  # `settings_unavailable` 503 as the caller's fault; the classification is
  # shared with every other Codex Pooler-authored error instead.
  defp send_runtime_error(conn, status, code, message) do
    body = %{
      "error" => %{
        "message" => message,
        "type" => ErrorClassification.error_type(code, status),
        "code" => to_string(code),
        "param" => nil
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, CodexPooler.JSON.encode!(body))
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
    |> send_resp(status, CodexPooler.JSON.encode!(body))
    |> halt()
  end
end
