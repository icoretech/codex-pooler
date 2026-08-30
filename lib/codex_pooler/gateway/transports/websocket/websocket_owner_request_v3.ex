defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3 do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.FirstCompactCollection
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest

  @version 3
  @v2_fields [
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
    :submission_notification?,
    :websocket_delivery_mode,
    :effective_serving_mode
  ]
  @fields [:version | @v2_fields] ++ [:owner_admission_capability, :first_compact_collection]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          version: 3,
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
          websocket_delivery_mode: :relay | :collect_compaction,
          effective_serving_mode: :full | :lite,
          owner_admission_capability: Capability.t() | nil,
          first_compact_collection: FirstCompactCollection.t() | nil
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
         :ok <- validate_version(request.version),
         :ok <- validate_admission(request),
         :ok <- validate_delivery(request),
         {:ok, v1} <- WebsocketOwnerRequest.new(v1_attrs(request)) do
      WebsocketOwnerRequest.validate(v1)
    end
  end

  def validate(_request), do: {:error, {:invalid_field, :envelope}}

  defp validate_version(@version), do: :ok
  defp validate_version(_version), do: {:error, {:invalid_field, :version}}

  defp validate_delivery(%__MODULE__{
         websocket_delivery_mode: mode,
         effective_serving_mode: serving_mode
       })
       when mode in [:relay, :collect_compaction] and serving_mode in [:full, :lite],
       do: :ok

  defp validate_delivery(%__MODULE__{websocket_delivery_mode: mode})
       when mode not in [:relay, :collect_compaction],
       do: {:error, {:invalid_field, :websocket_delivery_mode}}

  defp validate_delivery(_request), do: {:error, {:invalid_field, :effective_serving_mode}}

  defp validate_admission(%__MODULE__{
         owner_admission_capability: %Capability{},
         first_compact_collection: nil
       }),
       do: :ok

  defp validate_admission(%__MODULE__{
         owner_admission_capability: nil,
         first_compact_collection: %FirstCompactCollection{}
       }),
       do: :ok

  defp validate_admission(_request), do: {:error, {:invalid_field, :owner_admission_capability}}

  defp v1_attrs(request) do
    request
    |> Map.from_struct()
    |> Map.take(@v2_fields -- [:websocket_delivery_mode, :effective_serving_mode])
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
  for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3 do
  def inspect(_request, _opts), do: "#WebsocketOwnerRequestV3<version: 3, capability: redacted>"
end
