defmodule CodexPoolerWeb.V1.ResponsesController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.RequestOptions
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
      turn_state = accepted_turn_state(conn)

      request_options =
        conn
        |> GatewayHelpers.request_opts()
        |> RequestOptions.for_websocket()
        |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
        |> RequestOptions.put_continuity(accepted_turn_state: nil)
        |> RequestOptions.mark_openai_compatibility_origin(
          @public_responses_endpoint,
          @backend_responses_endpoint
        )

      conn
      |> put_resp_header("x-codex-turn-state", turn_state)
      |> WebSockAdapter.upgrade(
        CodexPoolerWeb.CodexResponsesSocket,
        %{auth: auth, opts: request_options},
        GatewayHelpers.websocket_upgrade_opts()
      )
      |> halt()
    end)
  rescue
    error in WebSockAdapter.UpgradeError ->
      GatewayHelpers.send_error(conn, %{
        status: 400,
        code: "websocket_upgrade_required",
        message: Exception.message(error)
      })
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
end
