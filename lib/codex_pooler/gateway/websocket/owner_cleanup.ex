defmodule CodexPooler.Gateway.Websocket.OwnerCleanup do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding

  @enforce_keys [
    :session_id,
    :owner_instance_id,
    :owner_lease_token,
    :request_id,
    :attempt_id,
    :replay_generation,
    :downstream_epoch
  ]
  defstruct @enforce_keys ++ [:native_replay_binding]

  @type t :: %__MODULE__{
          session_id: Ecto.UUID.t(),
          owner_instance_id: String.t(),
          owner_lease_token: Ecto.UUID.t(),
          request_id: Ecto.UUID.t(),
          attempt_id: Ecto.UUID.t(),
          replay_generation: non_neg_integer(),
          downstream_epoch: pos_integer(),
          native_replay_binding:
            CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding.t() | nil
        }

  @spec capture(map(), map(), map(), non_neg_integer()) :: t() | nil
  def capture(state, identity, downstream, generation) do
    values = %{
      session_id: Map.get(state, :codex_session_id),
      owner_instance_id: Map.get(state, :owner_instance_id),
      owner_lease_token: Map.get(state, :owner_lease_token),
      request_id: Map.get(identity, :request_id),
      attempt_id: Map.get(identity, :attempt_id),
      replay_generation: generation,
      downstream_epoch: Map.get(downstream, :epoch),
      native_replay_binding: Map.get(identity, :native_replay_binding)
    }

    if Enum.all?(
         [:session_id, :owner_instance_id, :owner_lease_token, :request_id, :attempt_id],
         &(is_binary(values[&1]) and values[&1] != "")
       ) and is_integer(generation) and generation >= 0 and
         is_integer(values.downstream_epoch) and values.downstream_epoch > 0 do
      struct!(__MODULE__, values)
    end
  end

  @spec from_owner_state(map()) :: t() | nil
  def from_owner_state(%{active_turn: %{cleanup_witness: %__MODULE__{} = witness}}),
    do: witness

  def from_owner_state(%{suspended_replay: %{cleanup_witness: %__MODULE__{} = witness}}),
    do: witness

  def from_owner_state(%{termination_cleanup_witness: %__MODULE__{} = witness}), do: witness

  def from_owner_state(_state), do: nil

  @spec resolve_owner_state(map()) :: map()
  def resolve_owner_state(
        %{
          active_turn: nil,
          suspended_replay: %{lifecycle: lifecycle, provisional_token: token} = suspended
        } = state
      )
      when is_binary(token) do
    reference = %{
      request_id: lifecycle.request_id,
      codex_turn_id: lifecycle.codex_turn_id,
      eligible_attempt_id: lifecycle.eligible_attempt_id,
      replay_generation: 1,
      owner_lease_digest: lifecycle.owner_lease_digest,
      provisional_token: token
    }

    case Accounting.replay_provisional_token_status(reference) do
      {:consumed, binding, phase, _deadline} when phase in [:committed_not_started, :started] ->
        cleanup = consumed_cleanup(state, suspended, binding)
        %{state | suspended_replay: Map.put(suspended, :cleanup_witness, cleanup)}

      _not_consumed ->
        state
    end
  end

  def resolve_owner_state(state), do: state

  defp consumed_cleanup(state, suspended, binding) do
    downstream = cleanup_downstream(suspended, state)

    if is_map(downstream) do
      replay =
        struct!(
          Binding,
          Map.merge(binding, %{
            semantic_turn_digest: suspended.semantic_turn_digest,
            replay_claim_digest: suspended.replay_claim_digest,
            downstream_epoch: downstream.epoch,
            owner_process_generation: state.process_generation
          })
        )

      capture(
        state,
        %{
          request_id: binding.request_id,
          attempt_id: binding.replay_attempt_id,
          native_replay_binding: replay
        },
        downstream,
        1
      )
    end
  end

  defp cleanup_downstream(%{cleanup_downstream_epoch: epoch}, _state)
       when is_integer(epoch) and epoch > 0,
       do: %{epoch: epoch}

  defp cleanup_downstream(suspended, state),
    do: suspended.downstream || Map.get(state, :downstream)

  @spec put_options(RequestOptions.t(), t() | nil) :: RequestOptions.t()
  def put_options(%RequestOptions{} = opts, witness),
    do: RequestOptions.put_runtime_context(opts, owner_cleanup: witness)
end

defimpl Inspect, for: CodexPooler.Gateway.Websocket.OwnerCleanup do
  def inspect(_witness, _opts), do: "#CodexPooler.Gateway.Websocket.OwnerCleanup<redacted>"
end
