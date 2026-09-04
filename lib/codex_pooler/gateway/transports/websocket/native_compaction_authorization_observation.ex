defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias NativeCompactionAdmission.Capability
  alias NativeCompactionAdmission.Topology.Direct
  alias NativeCompactionAdmission.Topology.Forwarded

  @event [:codex_pooler, :gateway, :native_compaction, :authorization_transition]
  @transitions [
    :compact_owner_issued,
    :compact_reserved,
    :compact_accounting_started,
    :compact_runtime_proof_redeemed,
    :compact_consumed,
    :compact_acknowledged,
    :final_owner_issued,
    :final_reserved,
    :final_accounting_started,
    :final_runtime_proof_redeemed,
    :final_consumed,
    :final_acknowledged
  ]
  @topologies [:direct, :forwarded]

  @type transition ::
          :compact_owner_issued
          | :compact_reserved
          | :compact_accounting_started
          | :compact_runtime_proof_redeemed
          | :compact_consumed
          | :compact_acknowledged
          | :final_owner_issued
          | :final_reserved
          | :final_accounting_started
          | :final_runtime_proof_redeemed
          | :final_consumed
          | :final_acknowledged
  @type topology :: :direct | :forwarded
  @type stage ::
          :owner_issued
          | :reserved
          | :accounting_started
          | :runtime_proof_redeemed
          | :consumed
          | :acknowledged

  @spec transitions() :: [transition()]
  def transitions, do: @transitions

  @spec topologies() :: [topology()]
  def topologies, do: @topologies

  @spec emit(transition(), topology()) :: :ok | :ignored
  def emit(transition, topology) when transition in @transitions and topology in @topologies do
    :telemetry.execute(@event, %{count: 1}, %{transition: transition, topology: topology})
    :ok
  end

  def emit(_transition, _topology), do: :ignored

  @spec emit_capability(Capability.t(), stage()) :: :ok
  def emit_capability(%Capability{} = capability, stage) do
    transition = transition(capability.phase, stage)
    topology = topology(capability.binding.topology)
    :ok = emit(transition, topology)
  end

  @spec log_accounting_rejection(
          NativeCompactionAdmission.t() | nil,
          Capability.t(),
          topology(),
          atom()
        ) :: :ok
  def log_accounting_rejection(
        admission,
        %Capability{phase: phase, binding: binding},
        topology,
        reason
      )
      when topology in @topologies do
    phase = if phase in [:compact, :final], do: phase, else: :unknown
    current_state = if admission, do: NativeCompactionAdmission.phase(admission), else: :cleared

    expected_state =
      case phase do
        :compact -> :reserved_compact
        :final -> :reserved_final
        :unknown -> :unknown
      end

    Logger.error([
      "native compaction admission rejected",
      " step=mark_accounting_started",
      " phase=#{phase}",
      " current_state=#{DiagnosticTaxonomy.identifier(current_state)}",
      " expected_state=#{expected_state}",
      " topology=#{topology}",
      " native_lifecycle_id=#{safe_lifecycle_id(binding)}",
      " reason=#{DiagnosticTaxonomy.identifier(reason)}"
    ])

    :ok
  end

  defp safe_lifecycle_id(%{lifecycle_id: lifecycle_id})
       when is_binary(lifecycle_id) and byte_size(lifecycle_id) == 36 do
    case Ecto.UUID.cast(lifecycle_id) do
      {:ok, uuid} -> DiagnosticTaxonomy.safe_correlator(uuid)
      :error -> "none"
    end
  end

  defp safe_lifecycle_id(_binding), do: "none"

  defp transition(:compact, :owner_issued), do: :compact_owner_issued
  defp transition(:compact, :reserved), do: :compact_reserved
  defp transition(:compact, :accounting_started), do: :compact_accounting_started
  defp transition(:compact, :runtime_proof_redeemed), do: :compact_runtime_proof_redeemed
  defp transition(:compact, :consumed), do: :compact_consumed
  defp transition(:compact, :acknowledged), do: :compact_acknowledged
  defp transition(:final, :owner_issued), do: :final_owner_issued
  defp transition(:final, :reserved), do: :final_reserved
  defp transition(:final, :accounting_started), do: :final_accounting_started
  defp transition(:final, :runtime_proof_redeemed), do: :final_runtime_proof_redeemed
  defp transition(:final, :consumed), do: :final_consumed
  defp transition(:final, :acknowledged), do: :final_acknowledged

  defp topology(%Direct{}), do: :direct
  defp topology(%Forwarded{}), do: :forwarded
end
