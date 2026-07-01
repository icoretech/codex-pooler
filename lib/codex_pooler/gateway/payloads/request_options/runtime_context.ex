defmodule CodexPooler.Gateway.Payloads.RequestOptions.RuntimeContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization
  alias CodexPooler.Gateway.RequestCompression.Metadata, as: RequestCompressionMetadata

  defstruct [
    :now,
    :interrupt_reason,
    :gateway_debug_payload,
    :payload_compression,
    :reasoning_effort_snapshot
  ]

  @type t :: %__MODULE__{
          now: DateTime.t() | nil,
          interrupt_reason: String.t() | nil,
          gateway_debug_payload: map() | nil,
          payload_compression: map() | nil,
          reasoning_effort_snapshot: map() | nil
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      now: Map.get(opts, :now),
      interrupt_reason: Map.get(opts, :interrupt_reason) || Map.get(opts, :reason),
      gateway_debug_payload: Map.get(opts, :gateway_debug_payload),
      payload_compression:
        RequestCompressionMetadata.runtime_metadata(Map.get(opts, :payload_compression)),
      reasoning_effort_snapshot: Map.get(opts, :reasoning_effort_snapshot)
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = runtime, updates) do
    updates
    |> Map.new()
    |> Normalization.normalize_optional_update(
      :payload_compression,
      &RequestCompressionMetadata.runtime_metadata/1
    )
    |> then(&struct!(runtime, &1))
  end
end
