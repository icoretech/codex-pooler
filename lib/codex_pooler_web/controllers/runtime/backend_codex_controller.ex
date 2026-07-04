defmodule CodexPoolerWeb.Runtime.BackendCodexController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Metadata
  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, ChatCompletions}
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

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
    PublicGatewayDispatch.websocket(
      conn,
      &GatewayHelpers.upgrade_responses_websocket(conn, &1),
      authenticator: &GatewayHelpers.authenticate/1
    )
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
        PublicGatewayDispatch.dispatch_json_payload(
          conn,
          auth,
          local_endpoint,
          upstream_endpoint,
          accounting_endpoint,
          payload,
          request_opts: opts
        )

      {:ok, compact_payload} ->
        proxy_compaction_trigger_bridge(conn, local_endpoint, auth, compact_payload, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proxy_compaction_trigger_bridge(conn, local_endpoint, auth, compact_payload, opts) do
    compact_endpoint = "/backend-api/codex/responses/compact"

    conn
    |> PublicGatewayDispatch.dispatch_json_payload(
      auth,
      compact_endpoint,
      compact_endpoint,
      compact_endpoint,
      compact_payload,
      admission_endpoint: local_endpoint,
      request_opts: opts
    )
    |> CompactionTrigger.adapt_gateway_result()
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
    PublicGatewayDispatch.coerced(
      conn,
      fn ->
        with {:ok, payload} <- GatewayHelpers.read_json_body(conn) do
          Chat.coerce(payload, chat_request_opts(conn, params))
        end
      end,
      fn decoded, %{chat_payload: chat_payload} ->
        ChatCompletions.normalize_response(decoded, chat_payload)
      end,
      authenticator: &GatewayHelpers.authenticate/1,
      local_endpoint: local_endpoint,
      accounting_endpoint: accounting_endpoint
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
end
