defmodule CodexPoolerWeb.PublicGatewayResult do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_resp_header: 3, put_status: 2]

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Facade.Error, as: FacadeError
  alias CodexPooler.Gateway.Facade.PublicProjection
  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Path, as: IngressPath

  @type success_normalizer :: (map() -> map())
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}

  @spec send(Plug.Conn.t(), gateway_call_result(), success_normalizer()) :: Plug.Conn.t()
  def send(conn, {:ok, %{stream: _stream} = result}, _success_normalizer) do
    content_type =
      if IngressPath.protocol(conn) == :ollama,
        do: "application/x-ndjson",
        else: "text/event-stream"

    GatewayHelpers.send_gateway_result(conn, %{
      result
      | headers:
          PublicResponse.stream_headers(
            GatewayHelpers.result_headers(result),
            content_type
          )
    })
  end

  def send(conn, {:ok, %{raw_body: body, status: status} = result}, success_normalizer) do
    if status >= 400 and IngressPath.protocol(conn) == :anthropic do
      GatewayHelpers.send_error(conn, %{
        status: status,
        code: "upstream_error",
        message: "upstream request failed"
      })
    else
      case PublicResponse.normalize_raw_body(status, body, success_normalizer) do
        {:ok, normalized} ->
          conn
          |> put_status(status)
          |> json(PublicProjection.gateway_body(normalized))

        :passthrough ->
          GatewayHelpers.send_gateway_result(conn, result)
      end
    end
  end

  def send(conn, {:ok, %{body: _body} = result}, _success_normalizer),
    do: GatewayHelpers.send_gateway_result(conn, result)

  def send(conn, {:error, %{status: status} = reason}, _success_normalizer) do
    body =
      conn
      |> IngressPath.protocol()
      |> FacadeError.body(status, reason)
      |> merge_recovery_error_fields(reason)

    conn
    |> put_recovery_headers(reason)
    |> put_status(status)
    |> json(body)
  end

  def send(conn, {:error, reason}, _success_normalizer),
    do: GatewayHelpers.send_error(conn, reason)

  defp put_recovery_headers(conn, reason) do
    Enum.reduce(Contracts.recovery_response_headers(reason), conn, fn {key, value}, conn ->
      put_resp_header(conn, key, value)
    end)
  end

  defp merge_recovery_error_fields(%{"error" => %{} = public_error} = body, reason) do
    case Contracts.recovery_error_fields(reason) do
      recovery when map_size(recovery) > 0 ->
        Map.put(body, "error", Map.merge(public_error, recovery))

      _recovery ->
        body
    end
  end

  defp merge_recovery_error_fields(body, _reason), do: body
end
