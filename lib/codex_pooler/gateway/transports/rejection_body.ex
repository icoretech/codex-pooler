defmodule CodexPooler.Gateway.Transports.RejectionBody do
  @moduledoc false

  @private_key :codex_pooler_rejection_body

  @spec put(Req.Response.t(), binary()) :: Req.Response.t()
  def put(%Req.Response{} = response, body) when is_binary(body),
    do: Req.Response.put_private(response, @private_key, body)

  @spec fetch(Req.Response.t()) :: binary() | nil
  def fetch(%Req.Response{} = response),
    do: Req.Response.get_private(response, @private_key)
end
