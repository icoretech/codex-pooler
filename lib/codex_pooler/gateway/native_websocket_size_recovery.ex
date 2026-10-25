defmodule CodexPooler.Gateway.NativeWebsocketSizeRecovery do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @spec handshake(Access.auth_context(), String.t(), RequestOptions.t()) :: :ok | :http_required | {:error, Contracts.gateway_error()}
  def handshake(auth, endpoint, %RequestOptions{} = opts) when endpoint in ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
    case window_digest(opts) do
      {:ok, digest} ->
        case Accounting.native_websocket_size_recovery(auth, digest) do
          {:ok, true} -> :http_required
          {:ok, false} -> :ok
          {:error, :storage_unavailable} -> {:error, Contracts.database_unavailable_error()}
        end

      :error ->
        :ok
    end
  end

  def handshake(_auth, _endpoint, %RequestOptions{}), do: :ok

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
