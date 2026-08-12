defmodule CodexPoolerWeb.GatewayControllerHelpers do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  require Logger

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Admission, as: GatewayAdmission
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.ErrorSanitizer
  alias CodexPooler.Gateway.Facade.Error, as: FacadeError
  alias CodexPooler.Gateway.Facade.HeaderPolicy
  alias CodexPooler.Gateway.Facade.PublicProjection
  alias CodexPooler.Gateway.Metadata
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Path, as: IngressPath

  @overload_code "server_is_overloaded"

  @type conn :: Plug.Conn.t()
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  @type body_read_result :: {:ok, map()} | {:error, Contracts.gateway_error()}
  @type request_opts :: %{optional(atom()) => term()}
  @type websocket_upgrade_opts :: [
          openai_compatibility: keyword(),
          openai_compatibility_origin: {String.t(), String.t()},
          accepted_turn_state: String.t() | nil
        ]

  @spec admit(conn(), String.t(), (-> gateway_call_result())) :: gateway_call_result()
  @spec admit(conn(), String.t(), map(), (-> gateway_call_result())) :: gateway_call_result()
  def admit(conn, route_class, metadata \\ %{}, fun) when is_function(fun, 0) do
    metadata = Map.merge(metadata, request_metadata(conn))

    GatewayAdmission.run_admitted(route_class, metadata, fun)
  end

  @spec authenticate(conn()) :: {:ok, Access.auth_context()} | {:error, Contracts.gateway_error()}
  def authenticate(%Plug.Conn{private: %{runtime_api_auth: auth}}), do: {:ok, auth}

  def authenticate(conn) do
    case Access.authenticate_authorization_header(
           get_req_header(conn, "authorization")
           |> List.first()
         ) do
      {:ok, auth} -> {:ok, auth}
      {:error, reason} -> {:error, Map.put(reason, :status, 401)}
    end
  end

  @spec authenticate_v1(conn()) ::
          {:ok, Access.auth_context()} | {:error, Contracts.gateway_error()}
  def authenticate_v1(conn), do: authenticate_facade(conn)

  @spec authenticate_facade(conn()) ::
          {:ok, Access.auth_context()} | {:error, Contracts.gateway_error()}
  def authenticate_facade(%Plug.Conn{private: %{runtime_api_auth: auth}}) do
    authorize_facade_compatibility(auth)
  end

  def authenticate_facade(conn) do
    with {:ok, raw_key} <- facade_api_key(conn),
         {:ok, auth} <- authenticate_facade_api_key(raw_key) do
      authorize_facade_compatibility(auth)
    end
  end

  defp authenticate_facade_api_key(raw_key) do
    case Access.authenticate_v1_api_key(raw_key) do
      {:ok, auth} -> {:ok, auth}
      {:error, reason} -> {:error, Map.put(reason, :status, 401)}
    end
  end

  defp authorize_facade_compatibility(%{pool: %{status: "active"} = pool} = auth) do
    if PoolRouting.v1_compatibility_enabled?(pool) do
      {:ok, auth}
    else
      {:error,
       %{
         status: 403,
         code: "v1_compatibility_disabled",
         message: "Compatibility access is disabled for this Pool"
       }}
    end
  end

  defp authorize_facade_compatibility(_auth) do
    {:error,
     %{
       status: 403,
       code: "v1_compatibility_disabled",
       message: "Compatibility access is disabled for this Pool"
     }}
  end

  @spec read_json_body(conn()) :: body_read_result()
  def read_json_body(%Plug.Conn{private: %{runtime_json_parse_error: true}}) do
    {:error, %{status: 400, code: "invalid_request", message: "request body must be valid JSON"}}
  end

  def read_json_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:error, %{status: 400, code: "invalid_request", message: "request body must be JSON"}}

      params when is_map(params) ->
        {:ok, params}

      _params ->
        {:error,
         %{status: 400, code: "invalid_request", message: "request body must be a JSON object"}}
    end
  end

  @spec read_multipart_body(conn()) :: body_read_result()
  def read_multipart_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:error,
         %{
           status: 400,
           code: "invalid_request",
           message: "request body must be multipart/form-data"
         }}

      params when is_map(params) ->
        {:ok, params}

      _params ->
        {:error,
         %{
           status: 400,
           code: "invalid_request",
           message: "request body must be multipart/form-data"
         }}
    end
  end

  @spec request_opts(conn()) :: request_opts()
  def request_opts(conn) do
    {session_header_source, session_header} = session_header(conn)

    %{
      request_id: request_id(conn),
      client_request_id: client_request_id(conn),
      idempotency_key: get_req_header(conn, "idempotency-key") |> List.first(),
      accepted_turn_state: accepted_turn_state(conn),
      resolved_turn_state_assignment_id: resolved_turn_state_assignment_id(conn),
      resolved_turn_state_session_id: resolved_turn_state_session_id(conn),
      previous_response_id: previous_response_id(conn),
      session_header: session_header,
      session_header_source: session_header_source,
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      request_content_type: get_req_header(conn, "content-type") |> List.first(),
      forwarded_headers: forwarded_headers(conn),
      client_ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      persona: Persona.fixed(persona_protocol(conn))
    }
  end

  @spec websocket_upgrade_opts() :: keyword()
  def websocket_upgrade_opts do
    settings = OperationalSettings.current()

    [
      timeout: settings.websocket_idle_timeout_ms,
      max_frame_size: settings.max_decompressed_body_bytes,
      max_fragmented_message_size: settings.max_decompressed_body_bytes,
      compress: false
    ]
  end

  @spec upgrade_responses_websocket(conn(), Access.auth_context(), websocket_upgrade_opts()) ::
          conn()
  def upgrade_responses_websocket(conn, auth, opts \\ []) do
    turn_state = websocket_turn_state(conn)

    request_options =
      conn
      |> request_opts()
      |> RequestOptions.for_websocket()
      |> maybe_put_websocket_openai_compatibility(opts)
      |> RequestOptions.put_continuity(
        accepted_turn_state: websocket_continuity_turn_state(opts, turn_state)
      )
      |> maybe_mark_websocket_openai_origin(opts)

    case maybe_put_websocket_models_etag(conn, auth, request_options) do
      {:ok, conn} ->
        conn
        |> put_resp_header("x-codex-turn-state", turn_state)
        |> WebSockAdapter.upgrade(
          CodexPoolerWeb.CodexResponsesSocket,
          %{auth: auth, opts: request_options, firewall_client_ip: conn.remote_ip},
          websocket_upgrade_opts()
        )
        |> halt()

      {:error, reason} ->
        send_error(conn, reason)
    end
  rescue
    error in WebSockAdapter.UpgradeError ->
      send_error(conn, %{
        status: 400,
        code: "websocket_upgrade_required",
        message: Exception.message(error)
      })
  end

  defp maybe_put_websocket_models_etag(conn, auth, %RequestOptions{} = request_options) do
    source_endpoint = request_options.openai_compatibility.source_endpoint || conn.request_path

    if source_endpoint in [
         "/backend-api/codex/responses",
         "/backend-api/codex/v1/responses"
       ] do
      case Metadata.codex_catalog_snapshot(auth, source_endpoint, request_options) do
        {:ok, snapshot} -> {:ok, put_resp_header(conn, "x-models-etag", snapshot.etag)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, conn}
    end
  end

  @spec send_or_error(conn(), gateway_call_result()) :: conn()
  def send_or_error(%Plug.Conn{} = conn, {:ok, result}), do: send_gateway_result(conn, result)
  def send_or_error(%Plug.Conn{} = conn, {:error, reason}), do: send_error(conn, reason)

  @spec result_headers(Contracts.gateway_result() | map()) :: Contracts.response_headers()
  def result_headers(%{headers: headers}) when is_list(headers), do: headers
  def result_headers(_result), do: []

  @spec send_gateway_result(conn(), Contracts.gateway_result()) :: conn()
  def send_gateway_result(conn, %{stream: stream} = result) do
    conn = put_gateway_headers(conn, result_headers(result))
    conn = send_chunked(conn, result.status)

    case stream.(conn) do
      {:ok, streamed_conn} ->
        streamed_conn

      {:error, reason} ->
        # The response is already chunked, so a late stream error cannot be
        # translated into a structured JSON error for the client.
        Logger.warning([
          "late gateway stream failed",
          " path=#{conn.request_path}",
          " request_id=#{request_id(conn) || "unknown"}",
          " reason=#{ErrorSanitizer.safe_reason(reason)}"
        ])

        conn
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  def send_gateway_result(conn, %{raw_body: body} = result) do
    conn = put_gateway_headers(conn, result_headers(result))

    case facade_json_body(conn, body, result.status) do
      {:ok, projected} -> conn |> put_status(result.status) |> json(projected)
      :invalid -> send_projection_failure(conn)
      :passthrough -> send_resp(conn, result.status, body)
    end
  end

  def send_gateway_result(conn, %{body: body} = result) do
    conn = put_gateway_headers(conn, result_headers(result))

    case project_gateway_body_result(conn, body, result.status) do
      {:ok, projected} -> conn |> put_status(result.status) |> json(projected)
      :invalid -> send_projection_failure(conn)
      :passthrough -> conn |> put_status(result.status) |> json(body)
    end
  end

  @spec send_error(conn(), Contracts.gateway_error() | map()) :: conn()
  def send_error(conn, %{status: status, code: code, message: message} = error) do
    body = error_body(conn, status, code, message, error)

    conn
    |> put_gateway_headers(Contracts.recovery_response_headers(error))
    |> put_status(status)
    |> json(body)
  end

  def send_error(conn, %{code: code, message: message}) do
    send_error(conn, %{status: 401, code: code, message: message})
  end

  defp client_error_type(@overload_code), do: "server_error"
  defp client_error_type(_code), do: "invalid_request_error"

  defp forwarded_headers(conn) do
    conn.req_headers
    |> Enum.filter(fn {name, _value} ->
      name == "user-agent" or String.starts_with?(name, "x-openai-") or
        String.starts_with?(name, "x-codex-")
    end)
    |> Enum.reject(fn {name, _value} ->
      name == "x-codex-turn-state" and match?(%{runtime_turn_state: %{}}, conn.private)
    end)
    |> maybe_put_resolved_turn_state(conn)
  end

  defp maybe_put_resolved_turn_state(headers, %{private: %{runtime_turn_state: resolution}}) do
    [{"x-codex-turn-state", resolution.upstream} | headers]
  end

  defp maybe_put_resolved_turn_state(headers, _conn), do: headers

  defp facade_api_key(conn) do
    with {:ok, authorization} <- single_header(conn, "authorization"),
         {:ok, x_api_key} <- single_header(conn, "x-api-key"),
         {:ok, bearer_key} <- bearer_key(authorization),
         {:ok, anthropic_key} <- direct_key(x_api_key) do
      select_facade_key(bearer_key, anthropic_key)
    else
      {:error, :invalid_credentials} -> facade_authentication_error()
    end
  end

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [] -> {:ok, nil}
      [value] when is_binary(value) -> {:ok, value}
      _headers -> {:error, :invalid_credentials}
    end
  end

  defp bearer_key(nil), do: {:ok, nil}
  defp bearer_key("Bearer " <> raw_key) when byte_size(raw_key) > 0, do: {:ok, raw_key}
  defp bearer_key(_authorization), do: {:error, :invalid_credentials}

  defp direct_key(nil), do: {:ok, nil}
  defp direct_key(raw_key) when is_binary(raw_key) and byte_size(raw_key) > 0, do: {:ok, raw_key}
  defp direct_key(_raw_key), do: {:error, :invalid_credentials}

  defp select_facade_key(nil, nil), do: facade_authentication_error()
  defp select_facade_key(raw_key, nil), do: {:ok, raw_key}
  defp select_facade_key(nil, raw_key), do: {:ok, raw_key}

  defp select_facade_key(bearer_key, anthropic_key) do
    if byte_size(bearer_key) == byte_size(anthropic_key) and
         Plug.Crypto.secure_compare(bearer_key, anthropic_key) do
      {:ok, bearer_key}
    else
      facade_authentication_error()
    end
  end

  defp facade_authentication_error do
    {:error,
     %{
       status: 401,
       code: :api_key_missing,
       message: "Pool API key is required or invalid"
     }}
  end

  defp persona_protocol(conn) do
    case IngressPath.decoded_segments(conn) do
      ["api", "chat" | _rest] -> :ollama_chat
      ["api", "generate" | _rest] -> :ollama_generate
      ["v1", "messages" | _rest] -> :anthropic_messages
      ["v1", "responses" | _rest] -> :openai_responses
      ["v1", "chat", "completions" | _rest] -> :openai_chat
      ["v1", "completions" | _rest] -> :openai_completions
      ["v1", kind | _rest] when kind in ["audio", "files", "images"] -> :media
      ["v1" | _rest] -> :metadata
      ["backend-api", "codex", "images" | _rest] -> :media
      ["backend-api", "codex", "models" | _rest] -> :metadata
      ["backend-api", "codex" | _rest] -> :codex
      ["backend-api", kind | _rest] when kind in ["files", "transcribe"] -> :media
      _segments -> :metadata
    end
  end

  defp accepted_turn_state(conn) do
    case conn.private do
      %{runtime_turn_state: %{public: public}} -> public
      _private -> conn |> get_req_header("x-codex-turn-state") |> List.first() |> blank_to_nil()
    end
  end

  defp resolved_turn_state_assignment_id(%{private: %{runtime_turn_state: resolution}}),
    do: resolution.assignment_id

  defp resolved_turn_state_assignment_id(_conn), do: nil

  defp resolved_turn_state_session_id(%{private: %{runtime_turn_state: resolution}}),
    do: resolution.session_id

  defp resolved_turn_state_session_id(_conn), do: nil

  defp websocket_turn_state(conn), do: accepted_turn_state(conn) || Ecto.UUID.generate()

  defp websocket_continuity_turn_state(opts, turn_state) do
    case Keyword.fetch(opts, :accepted_turn_state) do
      {:ok, value} -> value
      :error -> turn_state
    end
  end

  defp maybe_put_websocket_openai_compatibility(%RequestOptions{} = request_options, opts) do
    case Keyword.get(opts, :openai_compatibility, []) do
      [] ->
        request_options

      compatibility when is_list(compatibility) ->
        RequestOptions.put_openai_compatibility(request_options, compatibility)
    end
  end

  defp maybe_mark_websocket_openai_origin(%RequestOptions{} = request_options, opts) do
    case Keyword.get(opts, :openai_compatibility_origin) do
      {public_endpoint, backend_endpoint} ->
        RequestOptions.mark_openai_compatibility_origin(
          request_options,
          public_endpoint,
          backend_endpoint
        )

      _origin ->
        request_options
    end
  end

  defp previous_response_id(conn) do
    conn
    |> get_req_header("x-codex-previous-response-id")
    |> List.first()
    |> blank_to_nil()
  end

  defp session_header(conn) do
    [
      "x-codex-window-id",
      "x-codex-session-id",
      "session-id",
      "x-session-id",
      "x-session-affinity",
      "session_id",
      "x-codex-conversation-id",
      "x-ollama-session-id"
    ]
    |> Enum.find_value({nil, nil}, fn header ->
      case conn |> get_req_header(header) |> List.first() |> blank_to_nil() do
        nil -> false
        value -> {header, value}
      end
    end)
  end

  defp request_id(conn) do
    List.first(get_req_header(conn, "x-request-id")) ||
      List.first(get_resp_header(conn, "x-request-id"))
  end

  defp client_request_id(conn), do: List.first(get_req_header(conn, "x-request-id"))

  defp request_metadata(conn) do
    %{
      request_id: request_id(conn),
      method: conn.method,
      path: "/" <> Enum.join(conn.path_info, "/")
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp put_gateway_headers(conn, headers) do
    headers =
      if facade_runtime?(conn) do
        HeaderPolicy.result_headers(IngressPath.protocol(conn), headers)
      else
        headers
      end

    Enum.reduce(headers, conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)
  end

  defp facade_json_body(conn, body, status) when is_binary(body) do
    if facade_runtime?(conn) do
      with {:ok, %{} = decoded} <- Jason.decode(body),
           {:ok, projected} <- project_gateway_body_result(conn, decoded, status) do
        {:ok, projected}
      else
        _invalid when status >= 400 ->
          {:ok,
           FacadeError.body(
             IngressPath.protocol(conn),
             status,
             %{code: "upstream_status", message: "upstream request failed"},
             origin: :untrusted
           )}

        _invalid ->
          :invalid
      end
    else
      :passthrough
    end
  end

  defp facade_json_body(_conn, _body, _status), do: :passthrough

  defp project_gateway_body_result(conn, %{} = body, status) do
    cond do
      not facade_runtime?(conn) ->
        {:ok, body}

      IngressPath.protocol(conn) == :runtime_metadata ->
        {:ok, body}

      status < 400 and IngressPath.protocol(conn) == :ollama ->
        case PublicProjection.ollama_body_result(conn.request_path, body) do
          {:ok, projected} -> {:ok, projected}
          :error -> :invalid
        end

      status < 400 and conn.request_path == "/backend-api/transcribe" ->
        case PublicProjection.transcription_body_result(body) do
          {:ok, projected} -> {:ok, projected}
          :error -> :invalid
        end

      true ->
        case PublicProjection.gateway_body_result(body, status) do
          {:ok, projected} -> {:ok, projected}
          :error -> :invalid
        end
    end
  end

  defp project_gateway_body_result(conn, _body, _status) do
    if facade_runtime?(conn), do: :invalid, else: :passthrough
  end

  defp send_projection_failure(conn) do
    send_error(conn, %{
      status: 502,
      code: "server_error",
      message: "gemma3 request failed"
    })
  end

  defp error_body(conn, status, code, message, error) do
    if facade_runtime?(conn) do
      IngressPath.protocol(conn)
      |> FacadeError.body(status, error)
      |> merge_recovery_error_fields(error)
    else
      %{
        "error" =>
          Map.merge(
            %{
              "message" => message,
              "type" => client_error_type(code),
              "code" => to_string(code),
              "param" => Map.get(error, :param)
            },
            Contracts.recovery_error_fields(error)
          )
      }
    end
  end

  defp merge_recovery_error_fields(%{"error" => %{} = public_error} = body, error) do
    case Contracts.recovery_error_fields(error) do
      recovery when map_size(recovery) > 0 ->
        Map.put(body, "error", Map.merge(public_error, recovery))

      _recovery ->
        body
    end
  end

  defp merge_recovery_error_fields(body, _error), do: body

  defp facade_runtime?(conn), do: IngressPath.fetch(conn).scope == :runtime
end
