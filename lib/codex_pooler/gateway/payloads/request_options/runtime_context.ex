defmodule CodexPooler.Gateway.Payloads.RequestOptions.RuntimeContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization
  alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness
  alias CodexPooler.Gateway.RequestCompression.Metadata, as: RequestCompressionMetadata
  alias CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold

  defstruct [
    :now,
    :api_key_runtime_epoch,
    :interrupt_reason,
    :owner_cleanup,
    :direct_cleanup,
    :gateway_debug_payload,
    :payload_compression,
    :reasoning_effort_snapshot,
    :prompt_cache_controls_downgraded,
    :replay_authorization_binding,
    :replay_lifecycle_binding,
    :replay_generation,
    :native_replay_binding,
    :native_replay_proof,
    :replay_provisional_token,
    :compaction_retry_submit_hold,
    :session_owner_witness,
    :tenant_scope
  ]

  @type t :: %__MODULE__{
          now: DateTime.t() | nil,
          api_key_runtime_epoch: non_neg_integer() | nil,
          interrupt_reason: String.t() | nil,
          owner_cleanup: CodexPooler.Gateway.Websocket.OwnerCleanup.t() | nil,
          direct_cleanup: CodexPooler.Gateway.Websocket.DirectCleanup.t() | nil,
          gateway_debug_payload: map() | nil,
          payload_compression: map() | nil,
          reasoning_effort_snapshot: map() | nil,
          prompt_cache_controls_downgraded: boolean(),
          replay_authorization_binding: map() | nil,
          replay_lifecycle_binding: map() | nil,
          replay_generation: non_neg_integer() | nil,
          native_replay_binding: term(),
          native_replay_proof: term(),
          replay_provisional_token: binary() | nil,
          compaction_retry_submit_hold: CompactionRetrySubmitHold.t() | nil,
          session_owner_witness: OwnerWitness.t() | nil,
          tenant_scope: tenant_scope() | nil
        }

  # Trusted Pool and API key ids of the authenticated runtime principal. Only
  # `RequestOptions.capture_tenant_scope/2` sets it; controller opts and
  # runtime updates can never supply it.
  @type tenant_scope :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t()
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
      replay_provisional_token: Map.get(opts, :replay_provisional_token),
      session_owner_witness: nil,
      tenant_scope: nil
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = runtime, updates) do
    updates
    |> Map.new()
    |> Map.drop([:session_owner_witness, "session_owner_witness", :tenant_scope, "tenant_scope"])
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
