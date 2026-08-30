defmodule CodexPooler.Gateway.Payloads.RequestOptions.NativeCompactionAdmission do
  @moduledoc false

  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Forwarded

  @enforce_keys [:capability, :owner, :expected_connection_lifecycle]
  defstruct [:capability, :owner, :expected_connection_lifecycle]

  @type direct_owner :: {:direct, pid()}
  @type forwarded_owner ::
          {:forwarded, CodexSession.t(), binary(), map(), keyword()}
  @type owner :: direct_owner() | forwarded_owner()
  @type lifecycle :: %{
          required(:lifecycle_id) => Ecto.UUID.t(),
          required(:generation) => pos_integer()
        }

  @type t :: %__MODULE__{
          capability: Capability.t(),
          owner: owner(),
          expected_connection_lifecycle: lifecycle()
        }

  @spec new(Capability.t(), owner(), lifecycle()) :: {:ok, t()} | {:error, :invalid_input}
  def new(%Capability{} = capability, owner, lifecycle) do
    if valid_owner?(owner) and valid_lifecycle?(lifecycle) and
         lifecycle.lifecycle_id == capability.binding.lifecycle_id and
         lifecycle.generation == capability.binding.generation do
      {:ok,
       %__MODULE__{
         capability: capability,
         owner: owner,
         expected_connection_lifecycle: lifecycle
       }}
    else
      {:error, :invalid_input}
    end
  end

  def new(_capability, _owner, _lifecycle), do: {:error, :invalid_input}

  @spec unwrap(t()) ::
          {:ok, Capability.t(), owner(), lifecycle()} | {:error, :invalid_input}
  def unwrap(%__MODULE__{} = admission) do
    case new(admission.capability, admission.owner, admission.expected_connection_lifecycle) do
      {:ok, _validated} ->
        {:ok, admission.capability, admission.owner, admission.expected_connection_lifecycle}

      {:error, :invalid_input} ->
        {:error, :invalid_input}
    end
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = admission),
    do: match?({:ok, _capability, _owner, _life}, unwrap(admission))

  @spec binding_digest(t(), <<_::256>>, String.t(), atom(), atom(), :direct | :forwarded) ::
          {:ok, <<_::256>>} | {:error, :invalid_input}
  def binding_digest(
        %__MODULE__{} = admission,
        semantic_turn_key,
        turn_claim_key,
        variant,
        expected_serving_mode,
        expected_topology
      )
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_binary(turn_claim_key) and is_atom(variant) and
             expected_serving_mode in [:full, :lite] and
             expected_topology in [:direct, :forwarded] do
    with {:ok, capability, owner, lifecycle} <- unwrap(admission),
         true <- capability.binding.semantic_turn_key == semantic_turn_key,
         true <- capability.binding.serving_mode == expected_serving_mode,
         true <- topology_matches?(capability.binding.topology, owner, expected_topology),
         true <- lifecycle.lifecycle_id == capability.binding.lifecycle_id,
         true <- lifecycle.generation == capability.binding.generation do
      {:ok,
       :crypto.hash(
         :sha256,
         :erlang.term_to_binary(
           {
             :native_compaction_runtime_admission_v1,
             variant,
             semantic_turn_key,
             turn_claim_key,
             expected_serving_mode,
             expected_topology,
             capability.phase,
             capability.binding,
             capability.control_ref,
             :crypto.hash(:sha256, capability.token),
             owner_digest(owner),
             lifecycle
           },
           [:deterministic]
         )
       )}
    else
      false -> {:error, :invalid_input}
      {:error, :invalid_input} = error -> error
    end
  end

  defp valid_owner?({:direct, pid}), do: is_pid(pid)

  defp valid_owner?({:forwarded, %CodexSession{}, lease_token, downstream, opts}) do
    is_binary(lease_token) and is_map(downstream) and is_list(opts)
  end

  defp valid_owner?(_owner), do: false

  defp valid_lifecycle?(%{lifecycle_id: lifecycle_id, generation: generation}) do
    match?({:ok, _uuid}, Ecto.UUID.cast(lifecycle_id)) and is_integer(generation) and
      generation > 0
  end

  defp valid_lifecycle?(_lifecycle), do: false

  defp owner_digest({:direct, pid}), do: {:direct, pid}

  defp owner_digest({:forwarded, %CodexSession{} = session, lease_token, downstream, opts}) do
    {
      :forwarded,
      session.id,
      :crypto.hash(:sha256, lease_token),
      Map.take(downstream, [:pid, :epoch, :correlation_id]),
      :crypto.hash(:sha256, :erlang.term_to_binary(opts, [:deterministic]))
    }
  end

  defp topology_matches?(%Direct{}, {:direct, _pid}, :direct), do: true

  defp topology_matches?(
         %Forwarded{},
         {:forwarded, %CodexSession{}, _lease, _down, _opts},
         :forwarded
       ),
       do: true

  defp topology_matches?(_binding_topology, _owner, _expected_topology), do: false
end

defimpl Inspect,
  for: CodexPooler.Gateway.Payloads.RequestOptions.NativeCompactionAdmission do
  def inspect(_admission, _opts), do: "#RequestOptions.NativeCompactionAdmission<redacted>"
end
