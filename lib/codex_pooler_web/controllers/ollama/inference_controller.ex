defmodule CodexPoolerWeb.Ollama.InferenceController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.Facade.Ollama.{Chat, Generate, Request, Response}
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  def chat(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn -> Chat.coerce(params, request_opts(conn)) end,
      fn decoded, %{ollama_formatting: formatting} -> Response.chat(decoded, formatting) end,
      local_endpoint: "/api/chat"
    )
  end

  def generate(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn -> Generate.coerce(params, request_opts(conn)) end,
      fn decoded, %{ollama_formatting: formatting} -> Response.generate(decoded, formatting) end,
      local_endpoint: "/api/generate"
    )
  end

  defp request_opts(conn) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.put(:upstream_endpoint, Request.backend_endpoint())
  end
end
