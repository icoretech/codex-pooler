defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Status do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission

  @type projection :: %{optional(atom()) => term()}

  # OTP's sensitive-process flag protects process inspection, but its GenServer
  # termination report still formats the last message through this callback.
  @spec format(projection()) :: projection()
  def format(status) do
    Map.new(status, fn
      {:state, state} -> {:state, state_summary(state)}
      {:message, message} -> {:message, message_class(message)}
      {:reason, reason} -> {:reason, reason_class(reason)}
      {:log, _events} -> {:log, []}
      {key, _value} -> {key, :redacted}
    end)
  end

  defp state_summary(state) when is_map(state) do
    %{
      active_turn?: is_map(Map.get(state, :active_turn)),
      downstream_attached?: is_map(Map.get(state, :downstream)),
      upstream_alive?: local_process_alive?(Map.get(state, :upstream_pid)),
      draining?: Map.get(state, :draining?) == true,
      retiring?: Map.get(state, :retire_after_active_turn?) == true,
      handoff_pending?: is_map(Map.get(state, :pending_handoff)),
      replay_pending?: is_map(Map.get(state, :suspended_replay)),
      admission_phase: admission_phase(Map.get(state, :native_compaction_admission)),
      pending_admission_count: admission_count(Map.get(state, :pending_admissions))
    }
  end

  defp state_summary(_state), do: :unavailable

  defp local_process_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)
  defp local_process_alive?(_pid), do: false

  defp admission_phase(%NativeCompactionAdmission{phase: phase}) when is_atom(phase), do: phase
  defp admission_phase(nil), do: :cleared
  defp admission_phase(_admission), do: :unknown

  defp admission_count(admissions) when is_map(admissions), do: map_size(admissions)
  defp admission_count(_admissions), do: 0

  defp message_class({:websocket_owner_upstream_frame, _ref, _payload}), do: :upstream_frame
  defp message_class({:websocket_owner_upstream_frame, _ref, _payload, _discriminator}), do: :upstream_frame
  defp message_class({ref, _result}) when is_reference(ref), do: :task_result
  defp message_class({:DOWN, _ref, :process, _pid, _reason}), do: :process_down
  defp message_class({:EXIT, _pid, _reason}), do: :process_exit
  defp message_class({:"$gen_call", _from, _request}), do: :call
  defp message_class({:"$gen_cast", _request}), do: :cast
  defp message_class(:renew_owner_lease), do: :renew_owner_lease
  defp message_class(:idle_shutdown), do: :idle_shutdown
  defp message_class(_message), do: :owner_message

  defp reason_class({%module{}, _stacktrace}), do: {:exception, module}
  defp reason_class(%module{}), do: {:exception, module}
  defp reason_class({:shutdown, _detail}), do: :shutdown
  defp reason_class(reason) when reason in [:normal, :shutdown, :owner_crashed, :owner_drained, :stale_owner], do: reason
  defp reason_class(_reason), do: :unknown
end
