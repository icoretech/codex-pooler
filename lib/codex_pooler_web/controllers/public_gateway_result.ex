defmodule CodexPoolerWeb.PublicGatewayResult do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias CodexPooler.Gateway.Contracts
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

  def send(
        conn,
        {:ok, %{raw_body: body, status: status} = result},
        success_normalizer
      ) do
    case PublicResponse.normalize_raw_body(
           status,
           body,
           success_normalizer,
           input_file_upstream_404?: Map.get(result, :public_input_file_upstream_404?) === true,
           source_code: Map.get(result, :public_stream_startup_error_code)
         ) do
      {:ok, normalized} ->
        conn
        |> put_status(public_error_status(status, result))
        |> json(normalized)

      :passthrough ->
        GatewayHelpers.send_gateway_result(conn, result)
    end
  end

  def send(
        conn,
        {:ok, %{body: _body, status: status, public_input_file_upstream_404?: true}},
        _success_normalizer
      ) do
    conn
    |> put_status(404)
    |> json(%{
      "error" =>
        PublicResponse.normalize_error(%{}, status: status, input_file_upstream_404?: true)
    })
  end

  def send(conn, {:ok, %{body: _body} = result}, _success_normalizer),
    do: GatewayHelpers.send_gateway_result(conn, result)

  def send(conn, {:error, %{status: status} = reason}, _success_normalizer) do
    if PublicResponse.redacted_gateway_error?(reason) do
      conn
      |> put_status(status)
      |> json(%{"error" => PublicResponse.normalize_error(reason, status: status)})
    else
      GatewayHelpers.send_error(conn, reason)
    end
  end

  def send(conn, {:error, reason}, _success_normalizer),
    do: GatewayHelpers.send_error(conn, reason)

  defp public_error_status(_status, %{public_input_file_upstream_404?: true}), do: 404
  defp public_error_status(404, _result), do: 502
  defp public_error_status(status, _result), do: status
end
