defmodule CodexPoolerWeb.Ollama.DiscoveryController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.Facade.Dispatch, as: FacadeDispatch
  alias CodexPooler.Gateway.Facade.Ollama.Catalog
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.PublicGatewayDispatch

  def tags(conn, _params) do
    authenticated(conn, "/api/tags", fn auth ->
      with {:ok, resolution} <- Catalog.resolve(auth) do
        json_result(Catalog.tags_body(resolution))
      end
    end)
  end

  def show(conn, _params) do
    authenticated(conn, "/api/show", fn auth ->
      with {:ok, resolution} <- Catalog.resolve(auth) do
        case Catalog.show_body(resolution) do
          %{} = body -> json_result(body)
          nil -> {:error, FacadeDispatch.unavailable_error()}
        end
      end
    end)
  end

  def ps(conn, _params) do
    authenticated(conn, "/api/ps", fn auth ->
      with {:ok, resolution} <- Catalog.resolve(auth) do
        json_result(Catalog.ps_body(resolution))
      end
    end)
  end

  def version(conn, _params) do
    authenticated(conn, "/api/version", fn _auth -> json_result(Catalog.version_body()) end)
  end

  defp authenticated(conn, endpoint, fun) do
    PublicGatewayDispatch.authenticated(
      conn,
      RouteClass.proxy_control(),
      endpoint,
      fun
    )
  end

  defp json_result(body) do
    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end
end
