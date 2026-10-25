defmodule CodexPooler.Gateway.NativeWebsocketSizeRecovery do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

  @spec window_digest(RequestOptions.t() | [{String.t(), String.t()}]) :: {:ok, String.t()} | :error
  def window_digest(%RequestOptions{transport: transport}), do: window_digest(transport.forwarded_metadata_headers)

  def window_digest(headers) when is_list(headers) do
    case for({"x-codex-window-id", value} <- headers, do: value) do
      [value] when is_binary(value) -> canonical_digest(value)
      _missing_or_ambiguous -> :error
    end
  end

  defp canonical_digest(value) do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> :error
        canonical -> {:ok, :sha256 |> :crypto.hash(canonical) |> Base.encode16(case: :lower)}
      end
    else
      :error
    end
  end
end
