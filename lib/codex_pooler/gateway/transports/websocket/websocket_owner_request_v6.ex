defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV6 do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.CompactionTrigger
  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest

  @version 6
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
  @fields [:version | @v1_fields] ++
            [:websocket_delivery_mode, :effective_serving_mode, :native_compaction_metadata]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          version: 6,
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
          websocket_delivery_mode: :collect_full_history,
          effective_serving_mode: :full | :lite,
          native_compaction_metadata: NativeCodexTurnMetadata.t()
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
         :ok <- validate_full_history(request),
         :ok <- validate_native_metadata(request.native_compaction_metadata),
         {:ok, v1} <- WebsocketOwnerRequest.new(v1_attrs(request)) do
      WebsocketOwnerRequest.validate(v1)
    end
  end

  def validate(_request), do: {:error, {:invalid_field, :envelope}}

  defp validate_closed_fields(%__MODULE__{
         version: @version,
         websocket_delivery_mode: :collect_full_history,
         effective_serving_mode: mode
       })
       when mode in [:full, :lite],
       do: :ok

  defp validate_closed_fields(%__MODULE__{version: version}) when version != @version,
    do: {:error, {:invalid_field, :version}}

  defp validate_closed_fields(%__MODULE__{websocket_delivery_mode: mode})
       when mode != :collect_full_history,
       do: {:error, {:invalid_field, :websocket_delivery_mode}}

  defp validate_closed_fields(_request), do: {:error, {:invalid_field, :effective_serving_mode}}

  @doc false
  @spec unanchored_full_history_payload?(term()) :: boolean()
  def unanchored_full_history_payload?(encoded) when is_binary(encoded) do
    with {:ok, %{"input" => input} = payload} <- Jason.decode(encoded),
         true <- is_list(input) and length(input) >= 2,
         true <- Enum.all?(input, &history_item?/1),
         true <- is_nil(payload["previous_response_id"]),
         true <- payload["type"] in [nil, "response.create"],
         true <- payload["generate"] in [nil, true],
         %{"type" => "compaction_trigger"} <- List.last(input),
         true <- Enum.count(input, &match?(%{"type" => "compaction_trigger"}, &1)) == 1,
         :ok <- CompactionTrigger.validate_projection(payload) do
      true
    else
      _invalid -> false
    end
  end

  def unanchored_full_history_payload?(_encoded), do: false

  defp history_item?(%{"type" => type}) when is_binary(type), do: String.trim(type) != ""

  defp history_item?(%{"role" => role, "content" => content}) when is_binary(role),
    do: String.trim(role) != "" and (is_binary(content) or is_list(content))

  defp history_item?(item) when is_binary(item), do: String.trim(item) != ""
  defp history_item?(_item), do: false

  defp validate_full_history(%{connection_bound_continuation?: value}) when value != false,
    do: {:error, {:invalid_field, :connection_bound_continuation?}}

  defp validate_full_history(%{payload: payload}) do
    if unanchored_full_history_payload?(payload),
      do: :ok,
      else: {:error, {:invalid_field, :payload}}
  end

  defp validate_native_metadata(
         %NativeCodexTurnMetadata{
           request_kind: :compaction,
           semantic_turn_key: semantic,
           window_id_digest: window,
           context_window_id_digest: context,
           window_number: number,
           compaction: compaction
         } = metadata
       ) do
    valid? =
      map_size(metadata) == 7 and digest?(semantic) and digest?(window) and digest?(context) and
        valid_window_number?(number) and valid_compaction?(compaction)

    if valid?, do: :ok, else: {:error, {:invalid_field, :native_compaction_metadata}}
  end

  defp validate_native_metadata(_metadata),
    do: {:error, {:invalid_field, :native_compaction_metadata}}

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp valid_window_number?(nil), do: true

  defp valid_window_number?(value),
    do: is_integer(value) and value in 0..18_446_744_073_709_551_615

  defp valid_compaction?(
         %NativeCodexTurnMetadata.Compaction{
           trigger: trigger,
           reason: reason,
           implementation: implementation,
           phase: phase,
           strategy: strategy
         } = compaction
       ) do
    map_size(compaction) == 6 and trigger in [:auto, :manual] and
      reason in [:user_requested, :context_limit, :model_downshift, :comp_hash_changed] and
      implementation in [:responses, :responses_compaction_v2, :responses_compact] and
      phase in [:standalone_turn, :pre_turn, :mid_turn] and
      strategy in [:memento, :prefix_compaction]
  end

  defp valid_compaction?(_compaction), do: false

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
  for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV6 do
  import Inspect.Algebra

  def inspect(_request, _opts), do: concat(["#WebsocketOwnerRequestV6<version: 6>"])
end
