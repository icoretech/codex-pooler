defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionLifecycleObservation do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, as: Admission

  alias Admission.Binding
  alias Admission.Topology.Forwarded

  @operations [
    :reserve,
    :accounting,
    :consume,
    :confirm,
    :cancel,
    :clear,
    :ordinary_success,
    :collect,
    :reject
  ]
  @reasons [
    :success,
    :stale_downstream,
    :stale_capability,
    :invalid_transition,
    :binding_mismatch,
    :expired,
    :invalid_input,
    :owner_unavailable,
    :request_rejected,
    :connection_invalidated,
    :connection_closed,
    :final_success,
    :final_failure,
    :compact_failure,
    :send_failure,
    :caller_exit
  ]
  @phases [
    :ordinary_success,
    :pending_compact,
    :reserved_compact,
    :accounting_started_compact,
    :consumed_compact,
    :collected_unconfirmed,
    :pending_final,
    :reserved_final,
    :accounting_started_final,
    :consumed_final,
    :cleared
  ]
  @max_counter 9_223_372_036_854_775_807

  @type operation ::
          :reserve
          | :accounting
          | :consume
          | :confirm
          | :cancel
          | :clear
          | :ordinary_success
          | :collect
          | :reject
          | :unknown
  @type reason ::
          :success
          | :stale_downstream
          | :stale_capability
          | :invalid_transition
          | :binding_mismatch
          | :expired
          | :invalid_input
          | :owner_unavailable
          | :request_rejected
          | :connection_invalidated
          | :connection_closed
          | :final_success
          | :final_failure
          | :compact_failure
          | :send_failure
          | :caller_exit
          | :unknown
  @type topology :: :direct | :forwarded | :unknown
  @type t :: %{
          operation: operation(),
          reason: reason(),
          topology: topology(),
          phase_from: Admission.phase() | :unknown,
          phase_to: Admission.phase() | :unknown,
          native_lifecycle_id: Ecto.UUID.t() | nil,
          generation: pos_integer() | nil,
          downstream_epoch: non_neg_integer() | nil
        }

  @spec observe(Admission.t() | nil, Admission.t() | nil, operation(), reason(), topology()) ::
          t()
  def observe(before_state, after_state, operation, reason, topology) do
    binding = admission_binding(after_state) || admission_binding(before_state)

    %{
      operation: fixed(operation, @operations),
      reason: fixed(reason, @reasons),
      topology: fixed(topology, [:direct, :forwarded]),
      phase_from: phase(before_state),
      phase_to: phase(after_state),
      native_lifecycle_id: lifecycle_id(binding),
      generation: generation(binding),
      downstream_epoch: downstream_epoch(binding)
    }
  end

  defp fixed(value, allowed), do: if(value in allowed, do: value, else: :unknown)

  defp phase(nil), do: :cleared
  defp phase(%Admission{phase: phase}), do: fixed(phase, @phases)
  defp phase(_state), do: :unknown

  defp admission_binding(%Admission{binding: %Binding{} = binding}), do: binding
  defp admission_binding(_state), do: nil

  defp lifecycle_id(%Binding{lifecycle_id: value})
       when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp lifecycle_id(_binding), do: nil

  defp generation(%Binding{generation: value})
       when is_integer(value) and value > 0 and value <= @max_counter,
       do: value

  defp generation(_binding), do: nil

  defp downstream_epoch(%Binding{topology: %Forwarded{downstream_epoch: value}})
       when is_integer(value) and value >= 0 and value <= @max_counter,
       do: value

  defp downstream_epoch(_binding), do: nil
end
