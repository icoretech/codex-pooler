defmodule CodexPooler.Upstreams.Auth.JwtPayload do
  @moduledoc false

  @type decode_result :: {:ok, map()} | {:error, :invalid_jwt}

  @spec decode(term()) :: decode_result()
  def decode(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _invalid -> {:error, :invalid_jwt}
    end
  end

  def decode(_token), do: {:error, :invalid_jwt}
end
