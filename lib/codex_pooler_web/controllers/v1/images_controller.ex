defmodule CodexPoolerWeb.V1.ImagesController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Images
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  def generations(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn ->
        Images.coerce_generation(
          params,
          request_opts(conn, image_generation_permission_required?: true)
        )
      end,
      &normalize_success/2
    )
  end

  def edits(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn ->
        Images.coerce_edit(
          params,
          request_opts(conn, image_generation_permission_required?: true)
        )
      end,
      &normalize_success/2
    )
  end

  defp normalize_success(decoded, _coerced), do: decoded

  defp request_opts(conn, private_opts) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.merge(Map.new(private_opts))
    |> Map.put(:upstream_endpoint, "/backend-api/codex/responses")
    |> Map.put(:collect_openai_image_stream, true)
  end
end
