defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2 do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest

  @version 2
  @v1_fields [
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
  @fields [:version | @v1_fields] ++ [:websocket_delivery_mode, :effective_serving_mode]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          version: 2,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          payload: binary(),
          timeouts: CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig.t(),
          mapper: WebsocketOwnerRequest.mapper(),
          upstream_identity_id: Ecto.UUID.t(),
          observation: WebsocketOwnerRequest.observation(),
          reset_probe: CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe.t() | nil,
          native_codex_response_control:
            CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot.t() | nil,
          assignment_advertised?: boolean(),
          connection_bound_continuation?: boolean(),
          forward_error_body?: boolean(),
          submission_notification?: boolean(),
          websocket_delivery_mode: :collect_compaction,
          effective_serving_mode: :full | :lite
        }
  @type validation_error :: WebsocketOwnerRequest.validation_error()

  @spec new(map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_map(attrs) do
    with false <- is_struct(attrs),
         :ok <- reject_unknown_fields(attrs),
         :ok <- require_fields(attrs),
         request = struct!(__MODULE__, attrs),
         :ok <- validate(request) do
      {:ok, request}
    else
      true -> {:error, {:invalid_field, :envelope}}
      {:error, _reason} = error -> error
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :envelope}}

  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = request) do
    with :ok <- reject_unknown_fields(Map.delete(request, :__struct__)),
         :ok <- validate_closed_fields(request),
         {:ok, v1} <- WebsocketOwnerRequest.new(v1_attrs(request)) do
      WebsocketOwnerRequest.validate(v1)
    end
  end

  def validate(_request), do: {:error, {:invalid_field, :envelope}}

  defp validate_closed_fields(%__MODULE__{
         version: @version,
         websocket_delivery_mode: :collect_compaction,
         effective_serving_mode: mode
       })
       when mode in [:full, :lite],
       do: :ok

  defp validate_closed_fields(%__MODULE__{version: version}) when version != @version,
    do: {:error, {:invalid_field, :version}}

  defp validate_closed_fields(%__MODULE__{websocket_delivery_mode: mode})
       when mode != :collect_compaction,
       do: {:error, {:invalid_field, :websocket_delivery_mode}}

  defp validate_closed_fields(_request), do: {:error, {:invalid_field, :effective_serving_mode}}

  defp v1_attrs(request) do
    request
    |> Map.from_struct()
    |> Map.take(@v1_fields)
    |> Map.put(:version, 1)
  end

  defp reject_unknown_fields(attrs) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 in @fields))
      |> Enum.map(fn field ->
        if is_atom(field) or is_binary(field), do: field, else: :unsupported
      end)
      |> Enum.uniq()
      |> Enum.sort_by(&to_string/1)

    if unknown == [], do: :ok, else: {:error, {:unknown_fields, unknown}}
  end

  defp require_fields(attrs) do
    case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:invalid_field, field}}
    end
  end
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2 do
  import Inspect.Algebra

  def inspect(_request, _opts), do: concat(["#WebsocketOwnerRequestV2<version: 2>"])
end
