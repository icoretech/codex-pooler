defmodule CodexPoolerWeb.Runtime.CodexUsageController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Usage
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers

  def show(conn, _params) do
    endpoint = conn.request_path
    opts = usage_request_opts(conn)

    result =
      conn
      |> GatewayHelpers.authenticate()
      |> admit_usage_request(conn, endpoint, opts)

    GatewayHelpers.send_or_error(conn, result)
  end

  defp admit_usage_request({:ok, auth}, conn, endpoint, opts) do
    GatewayHelpers.admit(conn, RouteClass.proxy_http(), %{endpoint: endpoint}, fn ->
      Usage.codex_usage(auth, endpoint, opts)
    end)
  end

  defp admit_usage_request({:error, reason}, _conn, _endpoint, _opts), do: {:error, reason}

  defp usage_request_opts(conn) do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.from_conn_metadata(conn.request_path, %{})
  end
end
