defmodule CodexPooler.Gateway.Payloads.RequestOptions.PayloadContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext

  defstruct media_upload: nil,
            forced_transcription_model: nil,
            native_image_request?: false,
            image_generation_permission_required?: false,
            compaction_trigger_bridge?: false,
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
          compaction_result_transport: :buffered | :sse,
          compaction_result_mode: :native_websocket | nil,
          compaction_projection_context: CompactionProjectionContext.t() | nil,
          compaction_projection: CompactionProjectionContext.safe_projection() | nil
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      media_upload: Map.get(opts, :media_upload),
      forced_transcription_model: Map.get(opts, :forced_transcription_model),
      native_image_request?: Map.get(opts, :native_image_request?) === true,
      image_generation_permission_required?:
        Map.get(opts, :image_generation_permission_required?) === true,
      compaction_trigger_bridge?: Map.get(opts, :compaction_trigger_bridge?) === true,
      compaction_result_transport: compaction_result_transport(opts),
      compaction_result_mode: compaction_result_mode(opts),
      compaction_projection_context: compaction_projection_context(opts)
    }
  end

  defp compaction_result_transport(opts) do
    if Map.get(opts, :compaction_result_transport) === :sse, do: :sse, else: :buffered
  end

  defp compaction_result_mode(opts) do
    if Map.get(opts, :compaction_result_mode) === :native_websocket,
      do: :native_websocket,
      else: nil
  end

  defp compaction_projection_context(opts) do
    case Map.get(opts, :compaction_projection_context) do
      %CompactionProjectionContext{} = context -> context
      _value -> nil
    end
  end
end
