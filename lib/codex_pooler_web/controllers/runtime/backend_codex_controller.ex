defmodule CodexPoolerWeb.Runtime.BackendCodexController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.ControlPlaneRoutes
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.ControlPlaneProxy
  alias CodexPooler.Gateway.Metadata
  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, ChatCompletions}
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.Pools
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Runtime.ControlPlaneJson
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.Runtime.PublicGatewayResult

  def models(conn, _params) do
    serve_models(conn, "/backend-api/codex/models")
  end

  def v1_models(conn, _params) do
    serve_models(conn, "/backend-api/codex/v1/models", "/backend-api/codex/models")
  end

  def image_generations(conn, _params) do
    proxy(conn, "/backend-api/codex/images/generations", "/backend-api/codex/images/generations")
  end

  def image_edits(conn, _params) do
    proxy(conn, "/backend-api/codex/images/edits", "/backend-api/codex/images/edits")
  end

  def responses(conn, _params) do
    proxy(conn, "/backend-api/codex/responses", "/backend-api/codex/responses")
  end

  def v1_responses(conn, _params) do
    proxy(
      conn,
      "/backend-api/codex/v1/responses",
      "/backend-api/codex/responses",
      "/backend-api/codex/responses"
    )
  end

  def compact_responses(conn, _params) do
    proxy(conn, "/backend-api/codex/responses/compact", "/backend-api/codex/responses/compact")
  end

  def v1_compact_responses(conn, _params) do
    proxy(
      conn,
      "/backend-api/codex/v1/responses/compact",
      "/backend-api/codex/responses/compact",
      "/backend-api/codex/responses/compact"
    )
  end

  def v1_chat_completions(conn, params) do
    chat_completions(
      conn,
      params,
      "/backend-api/codex/v1/chat/completions",
      "/backend-api/codex/responses"
    )
  end

  def thread_goal_get(conn, params), do: control_plane_proxy(conn, params, :thread_goal_get)

  def thread_goal_get_post(conn, params),
    do: control_plane_proxy(conn, params, :thread_goal_get_post)

  def thread_goal_set(conn, params), do: control_plane_proxy(conn, params, :thread_goal_set)

  def thread_goal_clear(conn, params),
    do: control_plane_proxy(conn, params, :thread_goal_clear)

  def analytics_events(conn, params), do: control_plane_proxy(conn, params, :analytics_events)

  def memories_trace_summarize(conn, params),
    do: control_plane_proxy(conn, params, :memories_trace_summarize)

  def alpha_search(conn, params), do: control_plane_proxy(conn, params, :alpha_search)

  def realtime_calls(conn, params), do: control_plane_proxy(conn, params, :realtime_calls)

  def safety_arc(conn, params), do: control_plane_proxy(conn, params, :safety_arc)

  def agent_identities_jwks(conn, params),
    do: control_plane_proxy(conn, params, :agent_identities_jwks)

  def wham_agent_identities_jwks(conn, params),
    do: control_plane_proxy(conn, params, :wham_agent_identities_jwks)

  defp control_plane_proxy(conn, _params, action) do
    endpoint = request_path(conn)
    route = ControlPlaneRoutes.fetch_by_action!(action)

    result =
      with {:ok, auth} <- GatewayHelpers.authenticate(conn),
           {:ok, body, conn} <- read_control_plane_body(conn, route.body_mode) do
        dispatch_control_plane_proxy(conn, auth, endpoint, route, body)
      end

    GatewayHelpers.send_or_error(conn, result)
  end

  defp dispatch_control_plane_proxy(conn, auth, endpoint, route, body) do
    GatewayHelpers.admit(conn, RouteClass.proxy_control(), %{endpoint: endpoint}, fn ->
      request =
        ControlPlaneProxy.build_request!(%{
          local_endpoint: endpoint,
          upstream_endpoint: route.upstream_path,
          method: conn.method,
          query_string: conn.query_string,
          body: body,
          body_mode: route.body_mode,
          request_headers: conn.req_headers,
          request_opts: GatewayHelpers.request_opts(conn)
        })

      routing_settings = Pools.routing_settings_with_defaults(auth.pool)

      if endpoint == "/backend-api/codex/analytics-events/events" and
           analytics_forwarding_disabled?(routing_settings) do
        ControlPlaneProxy.record_disabled_analytics(auth, request)
      else
        ControlPlaneProxy.execute(auth, request, routing_settings: routing_settings)
      end
    end)
  end

  def transcribe(conn, _params) do
    with {:ok, auth} <- GatewayHelpers.authenticate(conn),
         {:ok, payload} <- GatewayHelpers.read_multipart_body(conn) do
      result =
        GatewayHelpers.admit(
          conn,
          RouteClass.audio_transcription(),
          %{endpoint: "/backend-api/transcribe"},
          fn ->
            opts =
              conn
              |> GatewayHelpers.request_opts()
              |> Map.put(:upstream_endpoint, "/backend-api/transcribe")
              |> Map.put(:forced_transcription_model, Gateway.backend_transcription_model())
              |> RequestOptions.from_conn_metadata("/backend-api/transcribe", payload)

            Gateway.execute_multipart(auth, "/backend-api/transcribe", payload, opts)
          end
        )

      GatewayHelpers.send_or_error(conn, result)
    else
      {:error, reason} -> GatewayHelpers.send_error(conn, reason)
    end
  end

  def responses_stream(conn, _params) do
    case GatewayHelpers.authenticate(conn) do
      {:ok, auth} ->
        turn_state = accepted_turn_state(conn)

        request_options =
          conn
          |> GatewayHelpers.request_opts()
          |> RequestOptions.for_websocket()
          |> RequestOptions.put_continuity(accepted_turn_state: turn_state)

        conn
        |> put_resp_header("x-codex-turn-state", turn_state)
        |> WebSockAdapter.upgrade(
          CodexPoolerWeb.CodexResponsesSocket,
          %{auth: auth, opts: request_options},
          timeout: :timer.minutes(5),
          max_frame_size: 10_000_000,
          compress: false
        )
        |> halt()

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  rescue
    error in WebSockAdapter.UpgradeError ->
      GatewayHelpers.send_error(conn, %{
        status: 400,
        code: "websocket_upgrade_required",
        message: Exception.message(error)
      })
  end

  defp proxy(conn, local_endpoint, upstream_endpoint) do
    proxy(conn, local_endpoint, upstream_endpoint, local_endpoint)
  end

  defp proxy(conn, local_endpoint, upstream_endpoint, accounting_endpoint) do
    result =
      with {:ok, auth} <- GatewayHelpers.authenticate(conn),
           {:ok, payload} <- GatewayHelpers.read_json_body(conn) do
        proxy_json_payload(
          conn,
          local_endpoint,
          upstream_endpoint,
          accounting_endpoint,
          auth,
          payload
        )
      end

    GatewayHelpers.send_or_error(conn, result)
  end

  defp proxy_json_payload(
         conn,
         local_endpoint,
         upstream_endpoint,
         accounting_endpoint,
         auth,
         payload
       ) do
    opts =
      conn
      |> GatewayHelpers.request_opts()

    case CompactionTrigger.prepare_bridge(local_endpoint, payload) do
      :passthrough ->
        proxy_gateway_json_payload(
          conn,
          local_endpoint,
          upstream_endpoint,
          accounting_endpoint,
          auth,
          payload,
          opts
        )

      {:ok, compact_payload} ->
        proxy_compaction_trigger_bridge(conn, local_endpoint, auth, compact_payload, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proxy_gateway_json_payload(
         conn,
         local_endpoint,
         upstream_endpoint,
         accounting_endpoint,
         auth,
         payload,
         opts
       ) do
    request_options =
      opts
      |> RequestOptions.from_conn_metadata(local_endpoint, payload)
      |> RequestOptions.put_transport(upstream_endpoint: upstream_endpoint)

    route_class = RequestOptions.route_class(request_options)

    GatewayHelpers.admit(conn, route_class, %{endpoint: local_endpoint}, fn ->
      Gateway.execute(auth, accounting_endpoint, payload, request_options)
    end)
  end

  defp proxy_compaction_trigger_bridge(conn, local_endpoint, auth, compact_payload, opts) do
    compact_endpoint = "/backend-api/codex/responses/compact"

    request_options =
      opts
      |> RequestOptions.from_conn_metadata(compact_endpoint, compact_payload)
      |> RequestOptions.put_transport(upstream_endpoint: compact_endpoint)

    route_class = RequestOptions.route_class(request_options)

    GatewayHelpers.admit(conn, route_class, %{endpoint: local_endpoint}, fn ->
      auth
      |> Gateway.execute(compact_endpoint, compact_payload, request_options)
      |> CompactionTrigger.adapt_gateway_result()
    end)
  end

  defp serve_models(conn, endpoint) do
    serve_models(conn, endpoint, endpoint)
  end

  defp serve_models(conn, endpoint, accounting_endpoint) do
    case GatewayHelpers.authenticate(conn) do
      {:ok, auth} ->
        result =
          GatewayHelpers.admit(
            conn,
            RouteClass.proxy_http(),
            %{endpoint: endpoint},
            fn ->
              Metadata.serve_codex_models(
                auth,
                metadata_request_options(conn, accounting_endpoint)
              )
            end
          )

        GatewayHelpers.send_or_error(conn, result)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  defp chat_completions(conn, params, local_endpoint, accounting_endpoint) do
    case GatewayHelpers.authenticate(conn) do
      {:ok, auth} ->
        chat_completions_authenticated(conn, auth, params, local_endpoint, accounting_endpoint)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  defp chat_completions_authenticated(conn, auth, params, local_endpoint, accounting_endpoint) do
    with {:ok, payload} <- GatewayHelpers.read_json_body(conn),
         {:ok, coerced} <- Chat.coerce(payload, chat_request_opts(conn, params)) do
      result = chat_completions_dispatch(conn, auth, coerced, local_endpoint, accounting_endpoint)

      PublicGatewayResult.send(conn, result, fn decoded ->
        ChatCompletions.normalize_response(decoded, coerced.chat_payload)
      end)
    else
      {:error, reason} -> GatewayHelpers.send_error(conn, reason)
    end
  end

  defp chat_completions_dispatch(conn, auth, coerced, local_endpoint, accounting_endpoint) do
    GatewayHelpers.admit(
      conn,
      RequestOptions.route_class(coerced.request_options),
      %{endpoint: local_endpoint},
      fn ->
        Gateway.execute(auth, accounting_endpoint, coerced.payload, coerced.request_options)
      end
    )
  end

  defp chat_request_opts(conn, params) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.put(:upstream_endpoint, "/backend-api/codex/responses")
    |> maybe_mark_chat_stream(params)
  end

  defp maybe_mark_chat_stream(opts, %{"stream" => true} = params),
    do: opts |> Map.put(:public_openai_chat_stream, true) |> Map.put(:openai_chat_payload, params)

  defp maybe_mark_chat_stream(opts, params),
    do:
      opts
      |> Map.put(:collect_openai_response_stream, true)
      |> Map.put(:openai_chat_payload, params)

  defp metadata_request_options(conn, endpoint) do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.from_conn_metadata(endpoint, %{})
  end

  defp accepted_turn_state(conn) do
    conn
    |> get_req_header("x-codex-turn-state")
    |> List.first()
    |> trimmed_header_value()
    |> case do
      nil -> Ecto.UUID.generate()
      value -> value
    end
  end

  defp trimmed_header_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trimmed_header_value(_value), do: nil

  defp request_path(conn), do: "/" <> Enum.join(conn.path_info, "/")

  defp analytics_forwarding_disabled?(%{control_plane_analytics_forwarding_enabled: false}),
    do: true

  defp analytics_forwarding_disabled?(_routing_settings), do: false

  defp read_control_plane_body(conn, :no_body), do: {:ok, "", conn}

  defp read_control_plane_body(conn, {:json, _contract} = body_mode) do
    ControlPlaneJson.read_body(conn, body_mode)
  end

  defp read_control_plane_body(conn, :sdp) do
    if sdp_content_type?(conn) do
      read_raw_body(conn)
    else
      {:error,
       %{status: 400, code: "invalid_request", message: "request body must be application/sdp"}}
    end
  end

  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:more, _body, _conn} ->
        {:error, %{status: 413, code: "request_too_large", message: "request body is too large"}}

      {:error, _reason} ->
        {:error,
         %{status: 400, code: "invalid_request", message: "request body could not be read"}}
    end
  end

  defp sdp_content_type?(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> case do
      nil ->
        false

      content_type ->
        content_type |> String.downcase() |> String.split(";", parts: 2) |> hd() ==
          "application/sdp"
    end
  end
end
