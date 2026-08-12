defmodule CodexPooler.Gateway.Payloads.RequestOptions.PayloadContext do
  @moduledoc false

  defstruct media_upload: nil,
            forced_image_model: nil,
            forced_transcription_model: nil,
            native_image_request?: false,
            image_generation_permission_required?: false,
            compaction_trigger_bridge?: false

  @type t :: %__MODULE__{
          media_upload: map() | nil,
          forced_image_model: String.t() | nil,
          forced_transcription_model: String.t() | nil,
          native_image_request?: boolean(),
          image_generation_permission_required?: boolean(),
          compaction_trigger_bridge?: boolean()
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      media_upload: Map.get(opts, :media_upload),
      forced_image_model: Map.get(opts, :forced_image_model),
      forced_transcription_model: Map.get(opts, :forced_transcription_model),
      native_image_request?: Map.get(opts, :native_image_request?) === true,
      image_generation_permission_required?:
        Map.get(opts, :image_generation_permission_required?) === true,
      compaction_trigger_bridge?: Map.get(opts, :compaction_trigger_bridge?) === true
    }
  end
end
