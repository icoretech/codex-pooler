defmodule CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof do
  @moduledoc false

  @enforce_keys [:server, :reference, :nonce, :binding_digest]
  defstruct [:server, :reference, :nonce, :binding_digest]

  @type t :: %__MODULE__{
          server: pid(),
          reference: reference(),
          nonce: reference(),
          binding_digest: <<_::256>>
        }

  @doc false
  @spec new(pid(), reference(), reference(), <<_::256>>) :: t()
  def new(server, reference, nonce, binding_digest)
      when is_pid(server) and is_reference(reference) and is_reference(nonce) and
             is_binary(binding_digest) and byte_size(binding_digest) == 32 do
    %__MODULE__{
      server: server,
      reference: reference,
      nonce: nonce,
      binding_digest: binding_digest
    }
  end
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof do
  def inspect(_proof, _opts), do: "#RuntimeAdmissionProof<redacted>"
end
