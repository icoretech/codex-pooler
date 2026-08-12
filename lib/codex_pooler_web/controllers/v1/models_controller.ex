defmodule CodexPoolerWeb.V1.ModelsController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.Metadata
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  def index(conn, _params) do
    PublicGatewayDispatch.authenticated(conn, RouteClass.proxy_http(), "/v1/models", fn auth ->
      Metadata.serve_openai_models(auth, request_options(conn))
    end)
  end

  def show(conn, _params) do
    PublicGatewayDispatch.authenticated(
      conn,
      RouteClass.proxy_http(),
      "/v1/models",
      fn auth -> Metadata.serve_openai_model(auth, request_options(conn, "/v1/models")) end
    )
  end

  defp request_options(conn, endpoint \\ "/v1/models") do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.from_conn_metadata(endpoint, %{})
  end
end
