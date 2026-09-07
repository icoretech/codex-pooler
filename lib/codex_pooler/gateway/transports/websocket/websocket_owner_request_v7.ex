defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV7 do
  @moduledoc false

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV6

  @base_fields [
    :assignment_advertised?,
    :connection_bound_continuation?,
    :effective_serving_mode,
    :forward_error_body?,
    :headers,
    :mapper,
    :native_codex_response_control,
    :native_compaction_metadata,
    :observation,
    :payload,
    :reset_probe,
    :submission_notification?,
    :timeouts,
    :upstream_identity_id,
    :url,
    :version,
    :websocket_delivery_mode
  ]
  @fields @base_fields ++ [:client_retry_dispatch_authority, :compaction_retry_submit_hold]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}
  @type validation_error :: WebsocketOwnerRequestV6.validation_error()

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
    with :ok <- exact_keys(Map.from_struct(request)),
         true <- request.version == 7,
         true <- ClientRetry.dispatch_authority_shape?(request.client_retry_dispatch_authority),
         true <- CompactionRetrySubmitHold.valid_shape?(request.compaction_retry_submit_hold),
         {:ok, _full_history} <- full_history_request(request) do
      :ok
    else
      false -> {:error, {:invalid_field, invalid_field(request)}}
      {:error, _reason} = error -> error
    end
  end

  def validate(_request), do: {:error, {:invalid_field, :envelope}}

  @spec full_history_request(t()) ::
          {:ok, WebsocketOwnerRequestV6.t()} | {:error, validation_error()}
  def full_history_request(%__MODULE__{} = request) do
    request
    |> Map.from_struct()
    |> Map.take(@base_fields)
    |> Map.put(:version, 6)
    |> WebsocketOwnerRequestV6.new()
  end

  defp invalid_field(%{version: version}) when version != 7, do: :version

  defp invalid_field(request) do
    if ClientRetry.dispatch_authority_shape?(request.client_retry_dispatch_authority),
      do: :compaction_retry_submit_hold,
      else: :client_retry_dispatch_authority
  end

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

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV7 do
  def inspect(_request, _opts), do: "#WebsocketOwnerRequestV7<version: 7, client_retry: redacted>"
end
