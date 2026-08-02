defmodule CodexPoolerWeb.V1.AudioController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Audio
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  def transcriptions(conn, params) do
    PublicGatewayDispatch.coerced_multipart(
      conn,
      fn -> Audio.coerce_transcription(params, GatewayHelpers.request_opts(conn)) end,
      fn decoded, _coerced -> Audio.normalize_response(decoded) end
    )
  end
end
