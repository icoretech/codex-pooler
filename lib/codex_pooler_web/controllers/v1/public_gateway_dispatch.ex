defmodule CodexPoolerWeb.V1.PublicGatewayDispatch do
  @moduledoc false

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.Runtime.PublicGatewayResult

  @type auth :: CodexPooler.Access.auth_context()
  @type conn :: Plug.Conn.t()
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  @type coerced_request :: %{
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          required(:request_options) => RequestOptions.t(),
          optional(atom()) => term()
        }
  @type coercer :: (-> {:ok, coerced_request()} | {:error, Contracts.gateway_error()})
  @type gateway_executor :: (auth(), String.t(), map(), RequestOptions.t() ->
                               gateway_call_result())
  @type success_normalizer :: (map(), coerced_request() -> map())

  @spec authenticated(conn(), String.t(), String.t(), (auth() -> gateway_call_result())) :: conn()
  def authenticated(conn, route_class, endpoint, fun)
      when is_binary(route_class) and is_binary(endpoint) and is_function(fun, 1) do
    case GatewayHelpers.authenticate_v1(conn) do
      {:ok, auth} ->
        result =
          GatewayHelpers.admit(conn, route_class, %{endpoint: endpoint}, fn ->
            fun.(auth)
          end)

        GatewayHelpers.send_or_error(conn, result)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  @spec websocket(conn(), (auth() -> conn())) :: conn()
  def websocket(conn, upgrade_fun) when is_function(upgrade_fun, 1) do
    case GatewayHelpers.authenticate_v1(conn) do
      {:ok, auth} ->
        upgrade_fun.(auth)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  @spec coerced(conn(), coercer(), success_normalizer()) :: conn()
  def coerced(conn, coercer, normalize_success)
      when is_function(coercer, 0) and is_function(normalize_success, 2) do
    execute_coerced(conn, coercer, normalize_success, &Gateway.execute/4)
  end

  @spec coerced_multipart(conn(), coercer(), success_normalizer()) :: conn()
  def coerced_multipart(conn, coercer, normalize_success)
      when is_function(coercer, 0) and is_function(normalize_success, 2) do
    execute_coerced(conn, coercer, normalize_success, &Gateway.execute_multipart/4)
  end

  defp execute_coerced(conn, coercer, normalize_success, gateway_executor) do
    case GatewayHelpers.authenticate_v1(conn) do
      {:ok, auth} ->
        case coercer.() do
          {:ok, coerced} ->
            result = execute_coerced_service(conn, auth, coerced, gateway_executor)
            PublicGatewayResult.send(conn, result, &normalize_success.(&1, coerced))

          {:error, reason} ->
            GatewayHelpers.send_error(conn, reason)
        end

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  @spec execute_coerced_service(conn(), auth(), coerced_request(), gateway_executor()) ::
          gateway_call_result()
  defp execute_coerced_service(
         conn,
         auth,
         %{
           endpoint: endpoint,
           payload: payload,
           request_options: %RequestOptions{} = request_options
         },
         gateway_executor
       ) do
    request_options =
      RequestOptions.mark_openai_compatibility_origin(
        request_options,
        conn.request_path,
        endpoint
      )

    route_class = RequestOptions.route_class(request_options)

    GatewayHelpers.admit(conn, route_class, %{endpoint: endpoint}, fn ->
      gateway_executor.(auth, endpoint, payload, request_options)
    end)
  end
end
