defmodule CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1 do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias NativeCompactionAdmission.{Binding, Capability}

  @version 1
  @salt "forwarded_send_witness:v1"

  @enforce_keys [
    :version,
    :phase,
    :binding,
    :control_ref,
    :capability_digest,
    :correlation_digest,
    :downstream_epoch,
    :expires_at_ms,
    :nonce,
    :signature
  ]
  defstruct [
    :version,
    :phase,
    :binding,
    :control_ref,
    :capability_digest,
    :correlation_digest,
    :downstream_epoch,
    :expires_at_ms,
    :nonce,
    :signature
  ]

  @type t :: %__MODULE__{
          version: 1,
          phase: :compact | :final,
          binding: Binding.t(),
          control_ref: reference(),
          capability_digest: <<_::256>>,
          correlation_digest: <<_::256>>,
          downstream_epoch: pos_integer(),
          expires_at_ms: non_neg_integer(),
          nonce: <<_::256>>,
          signature: <<_::256>>
        }

  @spec issue(Capability.t(), map(), non_neg_integer()) :: {:ok, t()} | {:error, :invalid_input}
  def issue(
        %Capability{} = capability,
        %{correlation_id: correlation_id, epoch: epoch},
        now_ms
      )
      when is_binary(correlation_id) and is_integer(epoch) and epoch > 0 and
             is_integer(now_ms) and now_ms >= 0 do
    witness = %__MODULE__{
      version: @version,
      phase: capability.phase,
      binding: capability.binding,
      control_ref: capability.control_ref,
      capability_digest: capability_digest(capability),
      correlation_digest: digest(:correlation, correlation_id),
      downstream_epoch: epoch,
      expires_at_ms: capability.expires_at_ms,
      nonce: :crypto.strong_rand_bytes(32),
      signature: <<>>
    }

    {:ok, %{witness | signature: signature(witness)}}
  end

  def issue(_capability, _downstream, _now_ms), do: {:error, :invalid_input}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{version: @version, signature: signature} = witness)
      when is_binary(signature) and byte_size(signature) == 32 do
    Plug.Crypto.secure_compare(signature, signature(%{witness | signature: <<>>}))
  end

  def valid?(_witness), do: false

  @spec digest(t()) :: <<_::256>>
  def digest(%__MODULE__{} = witness), do: digest(:witness, encoded(witness))

  @spec authorizes?(
          t(),
          Binding.t(),
          reference(),
          map(),
          map(),
          atom(),
          non_neg_integer()
        ) :: boolean()
  def authorizes?(
        %__MODULE__{} = witness,
        %Binding{} = binding,
        control_ref,
        downstream,
        lifecycle,
        serving_mode,
        now_ms
      )
      when is_reference(control_ref) and is_atom(serving_mode) and is_integer(now_ms) and
             now_ms >= 0 do
    case {downstream_identity(downstream), lifecycle_identity(lifecycle)} do
      {{:ok, correlation_id, epoch}, {:ok, lifecycle_id, generation}} ->
        authorizes_binding?(witness, binding, control_ref) and
          authorizes_runtime?(
            witness,
            binding,
            correlation_id,
            epoch,
            lifecycle_id,
            generation,
            serving_mode,
            now_ms
          )

      _invalid ->
        false
    end
  end

  def authorizes?(_witness, _binding, _control_ref, _downstream, _lifecycle, _mode, _now_ms),
    do: false

  defp downstream_identity(%{correlation_id: correlation_id, epoch: epoch})
       when is_binary(correlation_id) and is_integer(epoch),
       do: {:ok, correlation_id, epoch}

  defp downstream_identity(_downstream), do: :error

  defp lifecycle_identity(%{lifecycle_id: lifecycle_id, generation: generation})
       when is_binary(lifecycle_id) and is_integer(generation),
       do: {:ok, lifecycle_id, generation}

  defp lifecycle_identity(_lifecycle), do: :error

  defp authorizes_binding?(witness, binding, control_ref) do
    valid?(witness) and witness.binding == binding and witness.control_ref == control_ref
  end

  defp authorizes_runtime?(
         witness,
         binding,
         correlation_id,
         epoch,
         lifecycle_id,
         generation,
         serving_mode,
         now_ms
       ) do
    witness.downstream_epoch == epoch and
      secure_match?(witness.correlation_digest, digest(:correlation, correlation_id)) and
      binding.lifecycle_id == lifecycle_id and binding.generation == generation and
      binding.serving_mode == serving_mode and now_ms <= witness.expires_at_ms
  end

  defp capability_digest(%Capability{} = capability) do
    digest(
      :capability,
      :erlang.term_to_binary(
        {capability.phase, capability.binding, capability.control_ref, capability.token,
         capability.expires_at_ms},
        [:deterministic]
      )
    )
  end

  defp signature(witness), do: :crypto.mac(:hmac, :sha256, key(), encoded(witness))

  defp encoded(witness) do
    :erlang.term_to_binary(
      {witness.version, witness.phase, witness.binding, witness.control_ref,
       witness.capability_digest, witness.correlation_digest, witness.downstream_epoch,
       witness.expires_at_ms, witness.nonce},
      [:deterministic]
    )
  end

  defp digest(domain, value),
    do: :crypto.mac(:hmac, :sha256, key(), [Atom.to_string(domain), 0, value])

  defp key do
    secret =
      :codex_pooler
      |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.hash(:sha256, [secret, 0, @salt])
  end

  defp secure_match?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_match?(_left, _right), do: false
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1 do
  def inspect(witness, _opts), do: "#ForwardedSendWitnessV1<#{witness.phase}:redacted>"
end
