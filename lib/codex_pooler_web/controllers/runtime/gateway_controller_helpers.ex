defmodule CodexPoolerWeb.Runtime.GatewayControllerHelpers do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  require Logger

  alias CodexPooler.Access
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata, as: FinalizationMetadata

  @type conn :: Plug.Conn.t()
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  @type body_read_result :: {:ok, map()} | {:error, Contracts.gateway_error()}
  @type request_opts :: %{optional(atom()) => term()}

  @spec admit(conn(), String.t(), (-> gateway_call_result())) :: gateway_call_result()
  @spec admit(conn(), String.t(), map(), (-> gateway_call_result())) :: gateway_call_result()
  def admit(conn, route_class, metadata \\ %{}, fun) when is_function(fun, 0) do
    metadata = Map.merge(metadata, request_metadata(conn))

    Gateway.run_admitted(route_class, metadata, fun)
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
  def authenticate_v1(%Plug.Conn{private: %{runtime_api_auth: auth}}), do: {:ok, auth}

  def authenticate_v1(conn) do
    case Access.authenticate_v1_authorization_header(
           get_req_header(conn, "authorization")
           |> List.first()
         ) do
      {:ok, auth} -> {:ok, auth}
      {:error, reason} -> {:error, Map.put(reason, :status, 401)}
    end
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
    %{
      request_id: request_id(conn),
      client_request_id: client_request_id(conn),
      idempotency_key: get_req_header(conn, "idempotency-key") |> List.first(),
      accepted_turn_state: accepted_turn_state(conn),
      previous_response_id: previous_response_id(conn),
      session_header: session_header(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      request_content_type: get_req_header(conn, "content-type") |> List.first(),
      forwarded_headers: forwarded_headers(conn),
      client_ip: conn.remote_ip |> :inet.ntoa() |> to_string()
    }
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
          " reason=#{FinalizationMetadata.safe_reason(reason)}"
        ])

        conn
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  def send_gateway_result(conn, %{raw_body: body} = result) do
    conn
    |> put_gateway_headers(result_headers(result))
    |> send_resp(result.status, body)
  end

  def send_gateway_result(conn, %{body: body} = result) do
    conn
    |> put_gateway_headers(result_headers(result))
    |> put_status(result.status)
    |> json(body)
  end

  @spec send_error(conn(), Contracts.gateway_error() | map()) :: conn()
  def send_error(conn, %{status: status, code: code, message: message} = error) do
    body = %{
      "error" => %{
        "message" => message,
        "type" => "invalid_request_error",
        "code" => to_string(code),
        "param" => Map.get(error, :param)
      }
    }

    conn
    |> put_status(status)
    |> json(body)
  end

  def send_error(conn, %{code: code, message: message}) do
    send_error(conn, %{status: 401, code: code, message: message})
  end

  defp forwarded_headers(conn) do
    Enum.filter(conn.req_headers, fn {name, _value} ->
      name == "user-agent" or String.starts_with?(name, "x-openai-") or
        String.starts_with?(name, "x-codex-")
    end)
  end

  defp accepted_turn_state(conn) do
    conn
    |> get_req_header("x-codex-turn-state")
    |> List.first()
    |> blank_to_nil()
  end

  defp previous_response_id(conn) do
    conn
    |> get_req_header("x-codex-previous-response-id")
    |> List.first()
    |> blank_to_nil()
  end

  defp session_header(conn) do
    [
      "x-codex-session-id",
      "session-id",
      "x-session-affinity",
      "session_id",
      "x-codex-conversation-id"
    ]
    |> Enum.find_value(fn header ->
      conn
      |> get_req_header(header)
      |> List.first()
      |> blank_to_nil()
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
    Enum.reduce(headers, conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)
  end
end
