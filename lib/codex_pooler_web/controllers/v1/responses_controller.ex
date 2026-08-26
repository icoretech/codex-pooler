defmodule CodexPoolerWeb.V1.ResponsesController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  @public_responses_endpoint "/v1/responses"
  @backend_responses_endpoint "/backend-api/codex/responses"
  @compact_responses_endpoint "/backend-api/codex/responses/compact"

  @compact_unsupported %{
    status: 404,
    code: "unsupported_endpoint",
    message: "Unsupported OpenAI /v1 endpoint",
    param: nil
  }

  def create(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn -> Responses.coerce(params, request_opts(conn, params)) end,
      fn decoded, _coerced -> normalize_response_success(decoded) end,
      dispatcher: fn auth, coerced -> dispatch_response(conn, auth, coerced) end
    )
  end

  def websocket(conn, _params) do
    PublicGatewayDispatch.websocket(conn, fn auth ->
      GatewayHelpers.upgrade_responses_websocket(conn, auth,
        accepted_turn_state: nil,
        openai_compatibility: [public_openai_responses_stream: true],
        openai_compatibility_origin: {@public_responses_endpoint, @backend_responses_endpoint}
      )
    end)
  end

  def compact(conn, _params), do: GatewayHelpers.send_error(conn, @compact_unsupported)

  defp dispatch_response(conn, auth, %{payload: payload} = coerced) do
    case CompactionTrigger.prepare_bridge(@public_responses_endpoint, payload) do
      :passthrough ->
        PublicGatewayDispatch.dispatch_coerced(conn, auth, coerced)

      {:ok, compact_payload} ->
        request_options =
          coerced.request_options
          |> RequestOptions.retarget(@compact_responses_endpoint, compact_payload)
          |> RequestOptions.put_transport(
            transport: "http_compact_json",
            upstream_endpoint: @backend_responses_endpoint,
            route_class: RouteClass.proxy_compact()
          )
          |> RequestOptions.put_payload_context(
            compaction_trigger_bridge?: true,
            compaction_projection_context:
              CompactionProjectionContext.new(payload, compact_payload)
          )

        PublicGatewayDispatch.dispatch_coerced(
          conn,
          auth,
          %{
            coerced
            | endpoint: @compact_responses_endpoint,
              payload: compact_payload,
              request_options: request_options
          },
          admission_endpoint: @public_responses_endpoint,
          translated_endpoint: @backend_responses_endpoint,
          result_adapter: &CompactionTrigger.adapt_gateway_result(&1, public_result_mode(coerced))
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp public_result_mode(%{
         request_options: %RequestOptions{
           openai_compatibility: %{public_openai_responses_stream: true}
         }
       }),
       do: :public_sse

  defp public_result_mode(_coerced), do: :response

  defp request_opts(conn, params) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.put(:upstream_endpoint, @backend_responses_endpoint)
    |> maybe_mark_public_stream(params)
  end

  defp maybe_mark_public_stream(opts, %{"stream" => true}),
    do: Map.put(opts, :public_openai_responses_stream, true)

  defp maybe_mark_public_stream(opts, _params),
    do: Map.put(opts, :collect_openai_response_stream, true)

  defp normalize_response_success(decoded) do
    decoded
    |> Map.put_new("object", "response")
  end
end
