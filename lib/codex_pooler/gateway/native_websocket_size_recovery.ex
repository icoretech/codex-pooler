defmodule CodexPooler.Gateway.NativeWebsocketSizeRecovery do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @native_endpoints ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"]

  @doc "The provider's whole-message websocket limit, the bound a native preclaim refusal applies."
  @spec limit_bytes() :: pos_integer()
  def limit_bytes, do: Accounting.native_websocket_message_limit_bytes()

  @doc """
  The value a native upgrade advertises in `x-codex-websocket-max-message-bytes`,
  as the provider's own `101` does: the smaller of the provider's limit and the
  socket's inbound frame limit, or `nil` off the native routes. Codex 0.170.0
  and later send a larger request over HTTP instead of the websocket.
  """
  @spec advertised_limit_bytes(String.t(), pos_integer()) :: pos_integer() | nil
  def advertised_limit_bytes(endpoint, max_frame_bytes) when endpoint in @native_endpoints and is_integer(max_frame_bytes) and max_frame_bytes > 0,
    do: min(limit_bytes(), max_frame_bytes)

  def advertised_limit_bytes(_endpoint, _max_frame_bytes), do: nil

  @spec handshake(Access.auth_context(), String.t(), RequestOptions.t()) :: :ok | :http_required | {:error, Contracts.gateway_error()}
  def handshake(auth, endpoint, %RequestOptions{} = opts) when endpoint in @native_endpoints do
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
