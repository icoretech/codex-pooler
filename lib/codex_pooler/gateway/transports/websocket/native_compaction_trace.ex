defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace do
  @moduledoc """
  Opt-in trace events for native websocket compaction.

  Safe mode exports the existing bounded metadata projection. Full mode is a
  development/test-only diagnostic surface that retains operational terms at
  the local collector after recursively removing credentials and secrets.
  """

  @event [:codex_pooler, :gateway, :native_compaction, :trace]
  @control_event [:codex_pooler, :gateway, :native_compaction, :trace_control]
  @active_mode_key {__MODULE__, :active_mode}
  @sensitivity_control_key {__MODULE__, :sensitivity_control}
  @full_build_enabled Application.compile_env(
                        :codex_pooler,
                        :dev_features_build_enabled,
                        false
                      )
  @events [
    :prepared_frame,
    :capability_reserve_started,
    :capability_reserve_finished,
    :capability_reserved,
    :accounting_started,
    :runtime_proof_redeemed,
    :capability_consumed,
    :capability_acknowledged,
    :response_task_started,
    :physical_send_started,
    :physical_send_finished,
    :owner_terminal,
    :finalization_finished,
    :delivery_finished,
    :cleanup_finished
  ]
  @enum_keys [:branch, :disposition, :outcome, :phase, :pid_role, :stage, :topology]
  @integer_keys [:generation, :owner_epoch, :window_number]
  @fingerprint_keys [
    :activity_token,
    :control_ref,
    :correlation_id,
    :lifecycle_id,
    :owner_pid,
    :response_task_pid,
    :semantic_turn_key,
    :socket_pid,
    :upstream_pid
  ]
  @allowed_enums [
    :compact,
    :final,
    :direct,
    :forwarded,
    :socket,
    :response_task,
    :owner_session,
    :upstream_session,
    :reserved,
    :accounting_started,
    :runtime_proof_redeemed,
    :consumed,
    :acknowledged,
    :ok,
    :error,
    :cancelled,
    :timeout,
    :normal,
    :aborted,
    :completed,
    :delivered,
    :queued,
    :started,
    :finished,
    :direct_owner,
    :forwarded_owner
  ]

  @type event_name :: atom()
  @type mode :: :off | :safe | :full

  @spec event() :: [atom()]
  def event, do: @event

  @spec control_event() :: [atom()]
  def control_event, do: @control_event

  @spec events() :: [event_name()]
  def events, do: @events

  @spec enabled?() :: boolean()
  def enabled?, do: mode() != :off

  @spec mode() :: mode()
  def mode do
    case :persistent_term.get(@active_mode_key, :configured) do
      :configured -> configured_mode()
      mode when mode in [:off, :safe, :full] -> mode
    end
  end

  @spec full_allowed?() :: boolean()
  def full_allowed?, do: @full_build_enabled

  @spec runtime_mode(String.t() | nil, atom()) :: mode()
  def runtime_mode(_value, environment) when environment not in [:dev, :test], do: :off

  def runtime_mode(value, environment) when environment in [:dev, :test] do
    case value do
      value when value in ~w(1 true safe) -> :safe
      "full" -> full_runtime_mode(environment)
      _value -> :off
    end
  end

  if @full_build_enabled do
    defp full_runtime_mode(environment) when environment in [:dev, :test], do: :full
  else
    defp full_runtime_mode(_environment), do: :off
  end

  @doc false
  @spec activate_mode(mode()) :: :ok | {:error, :full_trace_unavailable}
  if @full_build_enabled do
    def activate_mode(mode) when mode in [:off, :safe, :full] do
      :persistent_term.put(@active_mode_key, mode)
      :ok
    end
  else
    def activate_mode(:full), do: {:error, :full_trace_unavailable}

    def activate_mode(_mode) do
      :persistent_term.put(@active_mode_key, :off)
      :ok
    end
  end

  @doc false
  @spec deactivate_mode() :: :ok
  def deactivate_mode do
    :persistent_term.put(@active_mode_key, :off)
    :persistent_term.erase(@sensitivity_control_key)
    :ok
  end

  @doc false
  @spec deactivate_sensitivity_control() :: :ok
  def deactivate_sensitivity_control do
    :persistent_term.erase(@sensitivity_control_key)
    :ok
  end

  @doc false
  @spec activate_sensitivity_control(reference(), reference(), pid(), pid()) :: :ok
  def activate_sensitivity_control(generation, authorization, restorer, collector)
      when is_reference(generation) and is_reference(authorization) and is_pid(restorer) and
             is_pid(collector) do
    if mode() == :full do
      :persistent_term.put(
        @sensitivity_control_key,
        {generation, authorization, restorer, collector}
      )
    end

    :ok
  end

  @doc false
  @spec sensitivity_control() :: {reference(), reference(), pid(), pid()} | :inactive
  def sensitivity_control do
    if mode() == :full do
      :persistent_term.get(@sensitivity_control_key, :inactive)
    else
      :inactive
    end
  end

  @doc false
  @spec configure_process_sensitivity(atom()) :: :sensitive | tuple()
  if @full_build_enabled do
    alias CodexPooler.Dev.NativeCompactionTrace.SensitivityWatchdog

    def configure_process_sensitivity(role) when is_atom(role) do
      case sensitivity_control() do
        {generation, authorization, restorer, collector}
        when is_pid(restorer) and is_pid(collector) ->
          case GenServer.call(
                 restorer,
                 {:register_process, generation, authorization, self(), role},
                 5_000
               ) do
            :ok ->
              monitor = Process.monitor(restorer)

              {:ok, watchdog} =
                Task.start(
                  SensitivityWatchdog,
                  :run,
                  [
                    self(),
                    role,
                    generation,
                    authorization,
                    restorer,
                    collector
                  ]
                )

              Process.flag(:sensitive, false)
              {:observable, generation, monitor, authorization, restorer, collector, watchdog}

            {:error, reason} ->
              raise "native compaction full trace sensitivity registration failed: #{inspect(reason)}"
          end

        :inactive ->
          Process.flag(:sensitive, true)
          :sensitive
      end
    end

    def restore_process_sensitivity(
          {:observable, generation, monitor, authorization, restorer, _collector, watchdog}
        )
        when is_reference(generation) and is_reference(monitor) do
      Process.flag(:sensitive, true)
      Process.demonitor(monitor, [:flush])
      send(watchdog, {:native_compaction_trace_sensitivity_restored, self()})

      if Process.alive?(restorer) do
        GenServer.cast(restorer, {:process_restored, generation, authorization, self()})
      end

      :ok
    end

    def restore_process_sensitivity(:sensitive), do: :ok

    def configure_existing_process_sensitivity(role, generation, authorization, restorer)
        when is_atom(role) and is_reference(generation) and is_reference(authorization) and
               is_pid(restorer) do
      if valid_sensitivity_control?(generation, authorization, restorer) do
        {^generation, ^authorization, ^restorer, collector} = sensitivity_control()

        case GenServer.call(
               restorer,
               {:register_process, generation, authorization, self(), role},
               5_000
             ) do
          :ok ->
            monitor = Process.monitor(restorer)

            {:ok, watchdog} =
              Task.start(
                SensitivityWatchdog,
                :run,
                [
                  self(),
                  role,
                  generation,
                  authorization,
                  restorer,
                  collector
                ]
              )

            Process.flag(:sensitive, false)

            {:ok,
             {:observable, generation, monitor, authorization, restorer, collector, watchdog}}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :unauthorized}
      end
    end
  else
    def configure_process_sensitivity(_role) do
      Process.flag(:sensitive, true)
      :sensitive
    end

    def restore_process_sensitivity(_state) do
      Process.flag(:sensitive, true)
      :ok
    end

    def configure_existing_process_sensitivity(
          _role,
          _generation,
          _authorization,
          _restorer
        ),
        do: {:error, :full_trace_unavailable}
  end

  @doc false
  @spec valid_sensitivity_control?(reference(), reference(), pid()) :: boolean()
  def valid_sensitivity_control?(generation, authorization, restorer) do
    case sensitivity_control() do
      {^generation, ^authorization, ^restorer, _collector} -> true
      _other -> false
    end
  end

  @doc false
  @spec restore_on_restorer_down(term(), reference(), pid()) :: :restored | :unchanged
  def restore_on_restorer_down(
        {:observable, generation, monitor, _authorization, restorer, collector, _watchdog},
        monitor,
        restorer
      ) do
    Process.flag(:sensitive, true)
    send(collector, {:native_compaction_trace_sensitivity_restored, generation, self()})
    :restored
  end

  def restore_on_restorer_down(_sensitivity, _monitor, _restorer), do: :unchanged

  @doc false
  @spec authorized_restore?(term(), reference(), reference(), pid()) :: boolean()
  def authorized_restore?(
        {:observable, generation, _monitor, authorization, restorer, _collector, _watchdog},
        generation,
        authorization,
        restorer
      ),
      do: true

  def authorized_restore?(_sensitivity, _generation, _authorization, _restorer), do: false

  @spec emit(event_name(), map() | keyword()) :: :ok | :ignored
  def emit(name, metadata \\ %{})

  def emit(name, metadata) when name in @events and (is_map(metadata) or is_list(metadata)) do
    case mode() do
      :off ->
        :ignored

      :safe ->
        :telemetry.execute(@event, %{count: 1}, %{event: name, fields: sanitize(metadata)})
        :ok

      :full ->
        fields = metadata |> Map.new() |> Map.put_new(:emitter_pid, self())
        :telemetry.execute(@event, %{count: 1}, %{event: name, fields: fields})
        :ok
    end
  end

  def emit(_name, _metadata), do: :ignored

  @spec emit_full(atom(), map() | keyword()) :: :ok | :ignored
  def emit_full(name, metadata) when is_atom(name) and (is_map(metadata) or is_list(metadata)) do
    if mode() == :full do
      fields = metadata |> Map.new() |> Map.put_new(:emitter_pid, self())
      :telemetry.execute(@event, %{count: 1}, %{event: name, fields: fields})
      :ok
    else
      :ignored
    end
  end

  def emit_full(_name, _metadata), do: :ignored

  @spec enroll(atom(), pid()) :: :ok | :ignored
  def enroll(role, pid)
      when role in [:socket, :response_task, :owner_session, :upstream_session] and is_pid(pid) do
    if enabled?() do
      :telemetry.execute(@control_event, %{count: 1}, %{action: :enroll, role: role, pid: pid})
      :ok
    else
      :ignored
    end
  end

  def enroll(_role, _pid), do: :ignored

  @spec emit_capability(event_name(), struct(), map() | keyword()) :: :ok | :ignored
  def emit_capability(
        name,
        %{phase: phase, binding: binding, control_ref: control_ref},
        extra \\ %{}
      ) do
    emit(
      name,
      Map.merge(Map.new(extra), %{
        phase: phase,
        topology: topology(binding.topology),
        owner_epoch: topology_epoch(binding.topology),
        control_ref: control_ref,
        semantic_turn_key: binding.semantic_turn_key,
        lifecycle_id: binding.lifecycle_id,
        generation: binding.generation,
        window_number: binding.window_number
      })
    )
  end

  @spec sanitize(map() | keyword()) :: map()
  def sanitize(metadata) do
    metadata
    |> Map.new()
    |> Enum.reduce(%{}, fn
      {key, value}, acc when key in @enum_keys -> maybe_put_enum(acc, key, value)
      {key, value}, acc when key in @integer_keys -> maybe_put_integer(acc, key, value)
      {key, value}, acc when key in @fingerprint_keys -> Map.put(acc, key, fingerprint(value))
      {_key, _value}, acc -> acc
    end)
  end

  @spec fingerprint(term()) :: String.t()
  def fingerprint(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp maybe_put_enum(acc, key, value) when value in @allowed_enums,
    do: Map.put(acc, key, value)

  defp maybe_put_enum(acc, _key, _value), do: acc

  defp maybe_put_integer(acc, key, value)
       when is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991,
       do: Map.put(acc, key, value)

  defp maybe_put_integer(acc, _key, _value), do: acc

  defp topology(%{__struct__: module}) do
    case Module.split(module) |> List.last() do
      "Direct" -> :direct
      "Forwarded" -> :forwarded
      _other -> :unknown
    end
  end

  defp topology(_topology), do: :unknown

  defp topology_epoch(%{downstream_epoch: epoch}) when is_integer(epoch), do: epoch
  defp topology_epoch(_topology), do: nil

  defp configured_mode do
    config = Application.get_env(:codex_pooler, __MODULE__, [])

    case Keyword.get(config, :mode) do
      mode when mode in [:off, :safe] -> mode
      :full -> configured_full_mode()
      nil -> if(Keyword.get(config, :enabled, false), do: :safe, else: :off)
      _unknown -> :off
    end
  end

  if @full_build_enabled do
    defp configured_full_mode, do: :full
  else
    defp configured_full_mode, do: :off
  end
end
