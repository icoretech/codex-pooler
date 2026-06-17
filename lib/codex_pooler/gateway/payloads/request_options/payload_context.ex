defmodule CodexPooler.Gateway.Payloads.RequestOptions.PayloadContext do
  @moduledoc false

  defstruct [:media_upload, :forced_transcription_model]

  @type t :: %__MODULE__{
          media_upload: map() | nil,
          forced_transcription_model: String.t() | nil
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      media_upload: Map.get(opts, :media_upload),
      forced_transcription_model: Map.get(opts, :forced_transcription_model)
    }
  end
end
