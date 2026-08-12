defmodule CodexPoolerWeb.PublicGatewayResult do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Facade.PublicProjection
  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers

  @type success_normalizer :: (map() -> map())
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}

  @spec send(Plug.Conn.t(), gateway_call_result(), success_normalizer()) :: Plug.Conn.t()
  def send(conn, {:ok, %{stream: _stream} = result}, _success_normalizer) do
    GatewayHelpers.send_gateway_result(conn, %{
      result
      | headers: PublicResponse.stream_headers(GatewayHelpers.result_headers(result))
    })
  end

  def send(conn, {:ok, %{raw_body: body, status: status} = result}, success_normalizer) do
    case PublicResponse.normalize_raw_body(status, body, success_normalizer) do
      {:ok, normalized} ->
        conn
        |> put_status(status)
        |> json(PublicProjection.gateway_body(normalized))

      :passthrough ->
        GatewayHelpers.send_gateway_result(conn, result)
    end
  end

  def send(conn, {:ok, %{body: _body} = result}, _success_normalizer),
    do: GatewayHelpers.send_gateway_result(conn, result)

  def send(conn, {:error, %{status: _status} = reason}, _success_normalizer),
    do: GatewayHelpers.send_error(conn, reason)

  def send(conn, {:error, reason}, _success_normalizer),
    do: GatewayHelpers.send_error(conn, reason)
end
