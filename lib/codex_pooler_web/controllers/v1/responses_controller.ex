defmodule CodexPoolerWeb.V1.ResponsesController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  @public_responses_endpoint "/v1/responses"
  @backend_responses_endpoint "/backend-api/codex/responses"

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
      fn decoded, _coerced -> normalize_response_success(decoded) end
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
