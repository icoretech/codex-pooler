defmodule CodexPoolerWeb.PublicGatewayDispatch do
  @moduledoc false

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayResult

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
  @type authenticator :: (conn() -> {:ok, auth()} | {:error, term()})
  @type coercer :: (-> {:ok, coerced_request()} | {:error, Contracts.gateway_error()})
  @type gateway_executor :: (auth(), String.t(), map(), RequestOptions.t() ->
                               gateway_call_result())
  @type success_normalizer :: (map(), coerced_request() -> map())
  @type batch_coercer :: (-> {:ok,
                              %{
                                required(:requests) => [coerced_request()],
                                optional(atom()) => term()
                              }}
                             | {:error, Contracts.gateway_error()})
  @type batch_combiner ::
          ([Contracts.gateway_result()], map() -> gateway_call_result())
  @type auth_opts :: [
          authenticator: authenticator()
        ]
  @type dispatch_opts :: [
          authenticator: authenticator(),
          local_endpoint: String.t(),
          accounting_endpoint: String.t(),
          gateway_executor: gateway_executor()
        ]
  @type json_payload_dispatch_opts :: [
          admission_endpoint: String.t(),
          request_opts: GatewayHelpers.request_opts(),
          gateway_executor: gateway_executor()
        ]

  @spec authenticated(conn(), String.t(), String.t(), (auth() -> gateway_call_result())) :: conn()
  @spec authenticated(
          conn(),
          String.t(),
          String.t(),
          (auth() -> gateway_call_result()),
          auth_opts()
        ) ::
          conn()
  def authenticated(conn, route_class, endpoint, fun, opts \\ [])
      when is_binary(route_class) and is_binary(endpoint) and is_function(fun, 1) do
    authenticator = Keyword.get(opts, :authenticator, &GatewayHelpers.authenticate_v1/1)

    case authenticator.(conn) do
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
  @spec websocket(conn(), (auth() -> conn()), auth_opts()) :: conn()
  def websocket(conn, upgrade_fun, opts \\ []) when is_function(upgrade_fun, 1) do
    authenticator = Keyword.get(opts, :authenticator, &GatewayHelpers.authenticate_v1/1)

    case authenticator.(conn) do
      {:ok, auth} ->
        upgrade_fun.(auth)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  @spec dispatch_json_payload(
          conn(),
          auth(),
          String.t(),
          String.t(),
          String.t(),
          map(),
          json_payload_dispatch_opts()
        ) :: gateway_call_result()
  def dispatch_json_payload(
        conn,
        auth,
        local_endpoint,
        upstream_endpoint,
        accounting_endpoint,
        payload,
        opts \\ []
      )
      when is_binary(local_endpoint) and is_binary(upstream_endpoint) and
             is_binary(accounting_endpoint) and is_map(payload) do
    request_options =
      opts
      |> Keyword.get(:request_opts, GatewayHelpers.request_opts(conn))
      |> RequestOptions.from_conn_metadata(local_endpoint, payload)
      |> RequestOptions.put_transport(upstream_endpoint: upstream_endpoint)

    route_class = RequestOptions.route_class(request_options)
    gateway_executor = Keyword.get(opts, :gateway_executor, &Gateway.execute/4)
    admission_endpoint = Keyword.get(opts, :admission_endpoint, local_endpoint)

    GatewayHelpers.admit(conn, route_class, %{endpoint: admission_endpoint}, fn ->
      gateway_executor.(auth, accounting_endpoint, payload, request_options)
    end)
  end

  @spec coerced(conn(), coercer(), success_normalizer(), dispatch_opts()) :: conn()
  def coerced(conn, coercer, normalize_success, opts \\ [])
      when is_function(coercer, 0) and is_function(normalize_success, 2) do
    opts = Keyword.put_new(opts, :gateway_executor, &Gateway.execute/4)
    execute_coerced(conn, coercer, normalize_success, opts)
  end

  @spec coerced_multipart(conn(), coercer(), success_normalizer(), dispatch_opts()) :: conn()
  def coerced_multipart(conn, coercer, normalize_success, opts \\ [])
      when is_function(coercer, 0) and is_function(normalize_success, 2) do
    opts = Keyword.put(opts, :gateway_executor, &Gateway.execute_multipart/4)
    execute_coerced(conn, coercer, normalize_success, opts)
  end

  @spec coerced_batch(conn(), batch_coercer(), batch_combiner(), dispatch_opts()) :: conn()
  def coerced_batch(conn, coercer, combine, opts \\ [])
      when is_function(coercer, 0) and is_function(combine, 2) do
    authenticator = Keyword.get(opts, :authenticator, &GatewayHelpers.authenticate_v1/1)
    opts = Keyword.put_new(opts, :gateway_executor, &Gateway.execute/4)

    case authenticator.(conn) do
      {:ok, auth} ->
        with {:ok, %{requests: requests} = batch} <- coercer.(),
             {:ok, results} <- execute_coerced_batch(conn, auth, requests, opts),
             result <- combine.(results, batch) do
          GatewayHelpers.send_or_error(conn, result)
        else
          {:error, reason} -> GatewayHelpers.send_error(conn, reason)
        end

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  defp execute_coerced(conn, coercer, normalize_success, opts) do
    authenticator = Keyword.get(opts, :authenticator, &GatewayHelpers.authenticate_v1/1)

    case authenticator.(conn) do
      {:ok, auth} ->
        case coercer.() do
          {:ok, coerced} ->
            result = execute_coerced_service(conn, auth, coerced, opts)
            PublicGatewayResult.send(conn, result, &normalize_success.(&1, coerced))

          {:error, reason} ->
            GatewayHelpers.send_error(conn, reason)
        end

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  @spec execute_coerced_service(conn(), auth(), coerced_request(), dispatch_opts()) ::
          gateway_call_result()
  defp execute_coerced_service(
         conn,
         auth,
         %{
           endpoint: endpoint,
           payload: payload,
           request_options: %RequestOptions{} = request_options
         },
         opts
       ) do
    local_endpoint = Keyword.get(opts, :local_endpoint, endpoint)
    accounting_endpoint = Keyword.get(opts, :accounting_endpoint, endpoint)
    gateway_executor = Keyword.fetch!(opts, :gateway_executor)

    request_options =
      RequestOptions.mark_openai_compatibility_origin(
        request_options,
        conn.request_path,
        endpoint
      )

    route_class = RequestOptions.route_class(request_options)

    GatewayHelpers.admit(conn, route_class, %{endpoint: local_endpoint}, fn ->
      gateway_executor.(auth, accounting_endpoint, payload, request_options)
    end)
  end

  defp execute_coerced_batch(conn, auth, requests, opts) when is_list(requests) do
    Enum.reduce_while(requests, {:ok, []}, fn coerced, {:ok, results} ->
      case execute_coerced_service(conn, auth, coerced, opts) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end
end
