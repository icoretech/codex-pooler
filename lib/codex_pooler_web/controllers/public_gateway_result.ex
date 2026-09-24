defmodule CodexPoolerWeb.PublicGatewayResult do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Platform.ExecutionIdentity
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers

  @type success_normalizer :: (map() -> map())
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}

  @type send_opts :: [validation_param: (String.t() -> String.t())]

  @spec send(Plug.Conn.t(), gateway_call_result(), success_normalizer(), send_opts()) ::
          Plug.Conn.t()
  def send(conn, result, success_normalizer, opts \\ []) do
    response = do_send(conn, result, success_normalizer, opts)
    ExecutionIdentity.complete()
    response
  end

  defp do_send(conn, {:ok, %{stream: _stream} = result}, _success_normalizer, _opts) do
    GatewayHelpers.send_gateway_result(conn, %{
      result
      | headers: PublicResponse.stream_headers(GatewayHelpers.result_headers(result))
    })
  end

  defp do_send(
         conn,
         {:ok, %{public_validation_rejection: %{} = validation_rejection, status: status}},
         _success_normalizer,
         opts
       ) do
    param_mapper = Keyword.get(opts, :validation_param, &Function.identity/1)

    conn
    |> put_status(status)
    |> json(%{
      "error" => PublicResponse.validation_rejection_error(validation_rejection, param_mapper)
    })
  end

  defp do_send(
         conn,
         {:ok, %{raw_body: body, status: status} = result},
         success_normalizer,
         _opts
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

  defp do_send(
         conn,
         {:ok, %{body: _body, status: status, public_input_file_upstream_404?: true}},
         _success_normalizer,
         _opts
       ) do
    conn
    |> put_status(404)
    |> json(%{
      "error" => PublicResponse.normalize_error(%{}, status: status, input_file_upstream_404?: true)
    })
  end

  # A Full validation rejection carries its structured rejection next to the
  # native body, so the public `param` and `message` are rebuilt together from
  # the caller-facing parameter mapper (codex-pooler-findings#219). The relayed
  # `type` and `code` stay as the Full body rendered them; only the two fields
  # that name the parameter are re-rendered, and both from one constructor.
  defp do_send(
         conn,
         {:ok,
          %{body: %{"error" => %{} = error} = body, public_full_rejection: %{} = rejection} =
            result},
         _success_normalizer,
         opts
       ) do
    param_mapper = Keyword.get(opts, :validation_param, &Function.identity/1)
    public = PublicResponse.validation_rejection_error(rejection, param_mapper)

    error =
      error
      |> Map.put("param", public["param"])
      |> Map.put("message", public["message"])

    GatewayHelpers.send_gateway_result(conn, %{result | body: Map.put(body, "error", error)})
  end

  defp do_send(conn, {:ok, %{body: _body} = result}, _success_normalizer, _opts) do
    GatewayHelpers.send_gateway_result(conn, result)
  end

  defp do_send(conn, {:error, %{status: status} = reason}, _success_normalizer, _opts) do
    if PublicResponse.redacted_gateway_error?(reason) do
      # The redacted body keeps the retry advice a retryable `503` carries
      # (findings#206 row 206-532): a number, never upstream detail.
      conn
      |> put_retry_headers(Contracts.circuit_retry_response_headers(reason))
      |> put_status(status)
      |> json(%{"error" => PublicResponse.normalize_error(reason, status: status)})
    else
      GatewayHelpers.send_error(conn, reason)
    end
  end

  defp do_send(conn, {:error, reason}, _success_normalizer, _opts),
    do: GatewayHelpers.send_error(conn, reason)

  defp put_retry_headers(conn, headers), do: Enum.reduce(headers, conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)

  defp public_error_status(_status, %{public_input_file_upstream_404?: true}), do: 404
  defp public_error_status(404, _result), do: 502
  defp public_error_status(status, _result), do: status
end
