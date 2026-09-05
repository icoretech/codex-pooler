defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV5 do
  @moduledoc false

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest

  @base_fields [
    :url,
    :headers,
    :payload,
    :timeouts,
    :mapper,
    :upstream_identity_id,
    :observation,
    :reset_probe,
    :native_codex_response_control,
    :assignment_advertised?,
    :connection_bound_continuation?,
    :forward_error_body?,
    :submission_notification?
  ]
  @fields [:version | @base_fields] ++ [:client_retry_dispatch_authority]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}
  @type validation_error :: WebsocketOwnerRequest.validation_error()

  @spec new(map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_keys(attrs),
         request = struct!(__MODULE__, attrs),
         :ok <- validate(request) do
      {:ok, request}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :envelope}}

  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = request) do
    with true <- request.version == 5,
         true <- ClientRetry.dispatch_authority_shape?(request.client_retry_dispatch_authority),
         {:ok, v1} <- WebsocketOwnerRequest.new(v1_attrs(request)) do
      WebsocketOwnerRequest.validate(v1)
    else
      false -> {:error, {:invalid_field, invalid_field(request)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_request), do: {:error, {:invalid_field, :envelope}}

  defp invalid_field(%{version: version}) when version != 5, do: :version
  defp invalid_field(_request), do: :client_retry_dispatch_authority

  defp v1_attrs(request),
    do: request |> Map.from_struct() |> Map.take(@base_fields) |> Map.put(:version, 1)

  defp exact_keys(attrs) do
    unknown = Map.keys(attrs) -- @fields
    missing = @fields -- Map.keys(attrs)

    cond do
      unknown != [] -> {:error, {:unknown_fields, Enum.sort_by(unknown, &to_string/1)}}
      missing != [] -> {:error, {:invalid_field, hd(missing)}}
      true -> :ok
    end
  end
end

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV5 do
  def inspect(_request, _opts), do: "#WebsocketOwnerRequestV5<version: 5, client_retry: redacted>"
end
