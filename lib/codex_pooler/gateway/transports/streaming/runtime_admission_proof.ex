defmodule CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof do
  @moduledoc false

  @enforce_keys [:server, :reference, :nonce, :binding_digest, :kind]
  defstruct [:server, :reference, :nonce, :binding_digest, :kind]

  @type t :: %__MODULE__{
          server: pid(),
          reference: reference(),
          nonce: reference(),
          binding_digest: <<_::256>>,
          kind: :native_compaction | :native_replay
        }

  @doc false
  @spec new(pid(), reference(), reference(), <<_::256>>, :native_compaction | :native_replay) ::
          t()
  def new(server, reference, nonce, binding_digest, kind \\ :native_compaction)
      when is_pid(server) and is_reference(reference) and is_reference(nonce) and
             is_binary(binding_digest) and byte_size(binding_digest) == 32 and
             kind in [:native_compaction, :native_replay] do
    %__MODULE__{
      server: server,
      reference: reference,
      nonce: nonce,
      binding_digest: binding_digest,
      kind: kind
    }
  end
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof do
  def inspect(_proof, _opts), do: "#RuntimeAdmissionProof<redacted>"
end
