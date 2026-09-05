defmodule CodexPooler.Gateway.Payloads.RequestOptions.RuntimeContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization
  alias CodexPooler.Gateway.RequestCompression.Metadata, as: RequestCompressionMetadata

  defstruct [
    :now,
    :api_key_runtime_epoch,
    :interrupt_reason,
    :owner_cleanup,
    :gateway_debug_payload,
    :payload_compression,
    :reasoning_effort_snapshot,
    :prompt_cache_controls_downgraded,
    :replay_authorization_binding,
    :replay_lifecycle_binding,
    :replay_generation,
    :native_replay_binding,
    :native_replay_proof,
    :replay_provisional_token
  ]

  @type t :: %__MODULE__{
          now: DateTime.t() | nil,
          api_key_runtime_epoch: non_neg_integer() | nil,
          interrupt_reason: String.t() | nil,
          owner_cleanup: CodexPooler.Gateway.Websocket.OwnerCleanup.t() | nil,
          gateway_debug_payload: map() | nil,
          payload_compression: map() | nil,
          reasoning_effort_snapshot: map() | nil,
          prompt_cache_controls_downgraded: boolean(),
          replay_authorization_binding: map() | nil,
          replay_lifecycle_binding: map() | nil,
          replay_generation: non_neg_integer() | nil,
          native_replay_binding: term(),
          native_replay_proof: term(),
          replay_provisional_token: binary() | nil
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
      prompt_cache_controls_downgraded: false,
      replay_authorization_binding: Map.get(opts, :replay_authorization_binding),
      replay_lifecycle_binding: Map.get(opts, :replay_lifecycle_binding),
      replay_generation: Map.get(opts, :replay_generation),
      native_replay_binding: Map.get(opts, :native_replay_binding),
      native_replay_proof: Map.get(opts, :native_replay_proof),
      replay_provisional_token: Map.get(opts, :replay_provisional_token)
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
