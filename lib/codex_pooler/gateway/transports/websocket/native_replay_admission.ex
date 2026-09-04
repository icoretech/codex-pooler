defmodule CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission do
  @moduledoc false

  defmodule Binding do
    @moduledoc false
    @fields [
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :replay_attempt_id,
      :replay_generation,
      :semantic_turn_digest,
      :replay_claim_digest,
      :provisional_binding_digest,
      :owner_lease_digest,
      :downstream_epoch,
      :owner_process_generation
    ]
    @enforce_keys @fields
    defstruct @fields
    @type t :: %__MODULE__{}
  end

  defmodule Redeemed do
    @moduledoc false
    @enforce_keys [:correlation_id, :binding_digest]
    defstruct [:correlation_id, :binding_digest]
    @type t :: %__MODULE__{correlation_id: Ecto.UUID.t(), binding_digest: <<_::256>>}
  end

  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability
  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof

  @spec binding_digest(Binding.t()) :: {:ok, <<_::256>>} | {:error, :invalid_binding}
  def binding_digest(%Binding{} = binding) do
    if valid_binding?(binding) do
      {:ok,
       :crypto.hash(
         :sha256,
         :erlang.term_to_binary({"native_websocket_replay_admission_v1", binding}, [
           :deterministic
         ])
       )}
    else
      {:error, :invalid_binding}
    end
  end

  def binding_digest(_binding), do: {:error, :invalid_binding}

  @spec consume_binding(Binding.t()) :: map()
  def consume_binding(%Binding{} = binding) do
    Map.take(binding, [
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :replay_attempt_id,
      :replay_generation,
      :provisional_binding_digest,
      :owner_lease_digest
    ])
  end

  @spec redeem(RuntimeAdmissionProof.t(), Binding.t()) ::
          {:ok, Redeemed.t()} | {:error, :invalid | :replayed}
  def redeem(%RuntimeAdmissionProof{kind: :native_replay} = proof, %Binding{} = binding) do
    with {:ok, digest} <- binding_digest(binding),
         {:ok, correlation_id} <-
           Capability.redeem_runtime_admission(proof, digest, :native_replay) do
      {:ok, %Redeemed{correlation_id: correlation_id, binding_digest: digest}}
    else
      {:error, :invalid_binding} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def redeem(%RuntimeAdmissionProof{}, %Binding{}), do: {:error, :invalid}

  defp valid_binding?(binding) do
    Enum.all?(
      [
        binding.request_id,
        binding.codex_turn_id,
        binding.eligible_attempt_id,
        binding.replay_attempt_id
      ],
      &uuid?/1
    ) and binding.replay_generation == 1 and digest?(binding.semantic_turn_digest) and
      digest?(binding.replay_claim_digest) and digest?(binding.provisional_binding_digest) and
      digest?(binding.owner_lease_digest) and positive?(binding.downstream_epoch) and
      positive?(binding.owner_process_generation)
  end

  defp uuid?(value), do: is_binary(value) and Ecto.UUID.cast(value) == {:ok, value}
  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp positive?(value), do: is_integer(value) and value > 0
end

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding do
  def inspect(_binding, _opts), do: "#NativeReplayAdmission.Binding<redacted>"
end

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Redeemed do
  def inspect(_redeemed, _opts), do: "#NativeReplayAdmission.Redeemed<redacted>"
end
