defmodule CodexPooler.Gateway.Payloads.RequestOptions.RuntimeContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization
  alias CodexPooler.Gateway.RequestCompression.Metadata, as: RequestCompressionMetadata

  defstruct [
    :now,
    :api_key_runtime_epoch,
    :interrupt_reason,
    :gateway_debug_payload,
    :payload_compression,
    :reasoning_effort_snapshot,
    :prompt_cache_controls_downgraded
  ]

  @type t :: %__MODULE__{
          now: DateTime.t() | nil,
          api_key_runtime_epoch: non_neg_integer() | nil,
          interrupt_reason: String.t() | nil,
          gateway_debug_payload: map() | nil,
          payload_compression: map() | nil,
          reasoning_effort_snapshot: map() | nil,
          prompt_cache_controls_downgraded: boolean()
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      now: Map.get(opts, :now),
      api_key_runtime_epoch:
        Normalization.optional_non_negative_integer(Map.get(opts, :api_key_runtime_epoch)),
      interrupt_reason: Map.get(opts, :interrupt_reason) || Map.get(opts, :reason),
      gateway_debug_payload: Map.get(opts, :gateway_debug_payload),
      payload_compression:
        RequestCompressionMetadata.runtime_metadata(Map.get(opts, :payload_compression)),
      reasoning_effort_snapshot: Map.get(opts, :reasoning_effort_snapshot),
      prompt_cache_controls_downgraded: false
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = runtime, updates) do
    updates
    |> Map.new()
    |> Normalization.normalize_optional_update(
      :api_key_runtime_epoch,
      &Normalization.optional_non_negative_integer/1
    )
    |> Normalization.normalize_optional_update(
      :payload_compression,
      &RequestCompressionMetadata.runtime_metadata/1
    )
    |> Normalization.normalize_optional_update(
      :prompt_cache_controls_downgraded,
      &boolean/1
    )
    |> then(&struct!(runtime, &1))
  end

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: nil
end
