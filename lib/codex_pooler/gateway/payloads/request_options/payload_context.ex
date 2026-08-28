defmodule CodexPooler.Gateway.Payloads.RequestOptions.PayloadContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext

  defstruct media_upload: nil,
            forced_transcription_model: nil,
            native_image_request?: false,
            image_generation_permission_required?: false,
            compaction_trigger_bridge?: false,
            compaction_input_mode: nil,
            compaction_result_transport: :buffered,
            compaction_result_mode: nil,
            compaction_projection_context: nil,
            compaction_projection: nil

  @type t :: %__MODULE__{
          media_upload: map() | nil,
          forced_transcription_model: String.t() | nil,
          native_image_request?: boolean(),
          image_generation_permission_required?: boolean(),
          compaction_trigger_bridge?: boolean(),
          compaction_input_mode: :incremental | :full_history | nil,
          compaction_result_transport: :buffered | :sse,
          compaction_result_mode: :native_websocket | :public_websocket | nil,
          compaction_projection_context: CompactionProjectionContext.t() | nil,
          compaction_projection: CompactionProjectionContext.safe_projection() | nil
        }

  @spec build(map() | keyword(), :incremental | :full_history) :: t()
  def build(opts, compaction_input_mode)
      when compaction_input_mode in [:incremental, :full_history] do
    opts = Map.new(opts)

    %__MODULE__{
      media_upload: Map.get(opts, :media_upload),
      forced_transcription_model: Map.get(opts, :forced_transcription_model),
      native_image_request?: Map.get(opts, :native_image_request?) === true,
      image_generation_permission_required?:
        Map.get(opts, :image_generation_permission_required?) === true,
      compaction_trigger_bridge?: Map.get(opts, :compaction_trigger_bridge?) === true,
      compaction_input_mode: compaction_input_mode,
      compaction_result_transport: compaction_result_transport(opts),
      compaction_result_mode: compaction_result_mode(opts),
      compaction_projection_context: compaction_projection_context(opts)
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = context, updates) do
    updates =
      updates
      |> Map.new()
      |> normalize_compaction_input_mode()

    struct!(context, updates)
  end

  defp normalize_compaction_input_mode(updates) do
    Map.delete(updates, :compaction_input_mode)
  end

  defp compaction_result_transport(opts) do
    if Map.get(opts, :compaction_result_transport) === :sse, do: :sse, else: :buffered
  end

  defp compaction_result_mode(opts) do
    case Map.get(opts, :compaction_result_mode) do
      mode when mode in [:native_websocket, :public_websocket] -> mode
      _mode -> nil
    end
  end

  defp compaction_projection_context(opts) do
    case Map.get(opts, :compaction_projection_context) do
      %CompactionProjectionContext{} = context -> context
      _value -> nil
    end
  end
end
