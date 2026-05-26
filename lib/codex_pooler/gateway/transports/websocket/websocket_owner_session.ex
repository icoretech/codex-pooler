defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.{Interruption, Metadata}
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract

  @registry __MODULE__.Registry
  @task_supervisor __MODULE__.TaskSupervisor

  defstruct [
    :codex_session_id,
    :owner_lease_token,
    :owner_instance_id,
    :downstream,
    :downstream_monitor,
    :upstream_pid,
    :upstream_sender,
    :upstream_closer,
    :active_turn,
    :persistence,
    :request_id,
    :draining?,
    :idle_shutdown_ms,
    :idle_shutdown_ref,
    :owner_renewal_ms,
    :owner_renewal_ref
  ]

  @type downstream :: %{
          required(:pid) => pid(),
          required(:epoch) => pos_integer(),
          required(:correlation_id) => binary()
        }

  @type start_result :: {:ok, pid()} | {:ok, pid(), :existing} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    codex_session_id = Keyword.fetch!(opts, :codex_session_id)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, codex_session_id}})
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    codex_session_id = Keyword.fetch!(opts, :codex_session_id)

    GenServer.start(__MODULE__, opts, name: {:via, Registry, {@registry, codex_session_id}})
  end

  @spec start_owner(keyword()) :: start_result()
  def start_owner(opts), do: start_owner(opts, 100)

  defp start_owner(opts, attempts) when attempts > 0 do
    case start(opts) do
      {:ok, pid} ->
        log_owner_started(pid, opts)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        existing_owner_result(pid, opts, attempts)

      {:error, {:already_registered, pid}} ->
        existing_owner_result(pid, opts, attempts)

      {:error, reason} ->
        log_owner_start_failed(reason, opts)
        {:error, reason}
    end
  end

  defp start_owner(_opts, 0), do: {:error, :owner_unavailable}

  defp existing_owner_result(pid, opts, attempts) when is_pid(pid) do
    cond do
      not Process.alive?(pid) ->
        log_owner_lookup_missed(Keyword.fetch!(opts, :codex_session_id), :dead_pid, pid, opts)
        :erlang.yield()
        start_owner(opts, attempts - 1)

      not uuid?(Keyword.fetch!(opts, :codex_session_id)) or owner_reusable?(pid, opts) ->
        log_owner_reused(pid, opts)
        {:ok, pid, :existing}

      true ->
        log_owner_stale_replaced(pid, opts)
        _result = GenServer.stop(pid, {:shutdown, :stale_owner}, owner_call_timeout())
        :erlang.yield()
        start_owner(opts, attempts - 1)
    end
  end

  @spec drain_owner(GenServer.server()) :: :ok | {:error, term()}
  def drain_owner(owner), do: GenServer.call(owner, :drain, owner_call_timeout())

  @spec lookup(binary(), keyword()) :: {:ok, pid()} | {:error, :owner_unavailable}
  def lookup(codex_session_id, metadata \\ []) when is_binary(codex_session_id) do
    case Registry.lookup(@registry, codex_session_id) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          log_owner_lookup_missed(codex_session_id, :dead_pid, pid, metadata)
          {:error, :owner_unavailable}
        end

      [] ->
        log_owner_lookup_missed(codex_session_id, :not_registered, nil, metadata)
        {:error, :owner_unavailable}
    end
  end

  @spec attach_downstream(GenServer.server(), map()) :: {:ok, downstream()} | {:error, term()}
  def attach_downstream(owner, %{pid: pid, correlation_id: correlation_id})
      when is_pid(pid) and is_binary(correlation_id) do
    GenServer.call(owner, {:attach_downstream, pid, correlation_id}, owner_call_timeout())
  end

  @spec detach_downstream(GenServer.server(), map()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def detach_downstream(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id})
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) do
    GenServer.call(owner, {:detach_downstream, pid, epoch, correlation_id}, owner_call_timeout())
  end

  @spec submit_frame(GenServer.server(), downstream(), binary()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error() | term()}
  def submit_frame(owner, downstream, payload)
      when is_map(downstream) and is_binary(payload) do
    submit_upstream(owner, downstream, payload)
  end

  @spec submit_request(GenServer.server(), downstream(), UpstreamWebSocketSession.Request.t()) ::
          :ok | {:ok, term()} | {:error, WebsocketOwnerContract.owner_error() | term()}
  def submit_request(owner, downstream, %UpstreamWebSocketSession.Request{} = request)
      when is_map(downstream) do
    submit_upstream(owner, downstream, request)
  end

  defp submit_upstream(owner, downstream, upstream_payload)
       when is_map(downstream) do
    case reserve_frame(owner, downstream) do
      {:ok, reservation} ->
        task =
          Task.Supervisor.async_nolink(@task_supervisor, fn ->
            Process.flag(:sensitive, true)
            send_upstream(reservation, upstream_payload)
          end)

        :ok = activate_reserved_frame(owner, reservation.ref, task.ref)

        result =
          case Task.yield(task, :infinity) || Task.shutdown(task, :brutal_kill) do
            {:ok, task_result} -> task_result
            {:exit, _reason} -> {:error, :owner_crashed}
            nil -> {:error, :owner_crashed}
          end

        finish_reserved_frame(owner, reservation.ref, result)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec push_downstream(GenServer.server(), WebsocketOwnerContract.downstream_payload()) ::
          :ok | {:error, :invalid_downstream_message | :owner_unavailable}
  def push_downstream(owner, payload) do
    GenServer.call(owner, {:push_downstream, payload}, owner_call_timeout())
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)

    codex_session_id = Keyword.fetch!(opts, :codex_session_id)
    owner_lease_token = Keyword.fetch!(opts, :owner_lease_token)
    owner_instance_id = Keyword.fetch!(opts, :owner_instance_id)
    request_id = Keyword.get(opts, :request_id)
    idle_shutdown_ms = Keyword.get(opts, :idle_shutdown_ms, 300_000)
    owner_renewal_ms = Keyword.get(opts, :owner_renewal_ms, owner_renewal_ms())
    upstream = upstream_boundary(opts)
    persistence = persistence_boundary(opts)

    with {:ok, upstream_pid} <- upstream.start.() do
      {:ok,
       %__MODULE__{
         codex_session_id: codex_session_id,
         owner_lease_token: owner_lease_token,
         owner_instance_id: owner_instance_id,
         upstream_pid: upstream_pid,
         upstream_sender: upstream.send,
         upstream_closer: upstream.close,
         persistence: persistence,
         request_id: request_id,
         idle_shutdown_ms: idle_shutdown_ms,
         owner_renewal_ms: owner_renewal_ms,
         draining?: false
       }
       |> schedule_owner_renewal()}
    end
  end

  @impl GenServer
  def handle_call(:owner_identity, _from, state) do
    {:reply,
     {:ok,
      %{
        codex_session_id: state.codex_session_id,
        owner_lease_token: state.owner_lease_token,
        owner_instance_id: state.owner_instance_id
      }}, state}
  end

  def handle_call(:owner_status, _from, state) do
    {:reply,
     {:ok,
      %{
        codex_session_id: state.codex_session_id,
        owner_lease_token: state.owner_lease_token,
        owner_instance_id: state.owner_instance_id,
        upstream_alive?: Process.alive?(state.upstream_pid),
        draining?: state.draining?
      }}, state}
  end

  def handle_call(:drain, _from, state) do
    _result = send_owner_error(state.downstream, :owner_drained)
    {:stop, :normal, :ok, %{state | draining?: true}}
  end

  def handle_call({:attach_downstream, _pid, _correlation_id}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call({:attach_downstream, pid, correlation_id}, _from, state) do
    state =
      state
      |> demonitor_downstream()
      |> cancel_idle_shutdown()

    epoch = next_downstream_epoch(state.downstream)
    monitor = Process.monitor(pid)
    downstream = %{pid: pid, epoch: epoch, correlation_id: correlation_id}
    state = put_active_turn_downstream(state, downstream)

    {:reply, {:ok, downstream}, %{state | downstream: downstream, downstream_monitor: monitor}}
  end

  def handle_call({:detach_downstream, pid, epoch, correlation_id}, _from, state) do
    case downstream_status(state.downstream, %{
           pid: pid,
           epoch: epoch,
           correlation_id: correlation_id
         }) do
      :active ->
        state =
          state
          |> demonitor_downstream()
          |> schedule_idle_shutdown()

        {:reply, :ok, %{state | downstream: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reserve_frame, _downstream}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call({:reserve_frame, downstream}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    {:reply, stale_or_busy(state.downstream, downstream), state}
  end

  def handle_call({:reserve_frame, downstream}, _from, state) do
    case downstream_status(state.downstream, downstream) do
      :active ->
        ref = make_ref()

        reservation = %{
          ref: ref,
          owner: self(),
          upstream_pid: state.upstream_pid,
          upstream_sender: state.upstream_sender
        }

        active_turn = %{ref: ref, task_ref: nil, downstream: state.downstream}
        {:reply, {:ok, reservation}, %{state | active_turn: active_turn}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:activate_reserved_frame, ref, task_ref},
        _from,
        %{active_turn: %{ref: ref}} = state
      ) do
    active_turn = %{state.active_turn | task_ref: task_ref}
    {:reply, :ok, %{state | active_turn: active_turn}}
  end

  def handle_call({:activate_reserved_frame, _ref, _task_ref}, _from, state) do
    {:reply, {:error, :stale_owner}, state}
  end

  def handle_call({:push_downstream, payload}, _from, state) do
    case send_downstream(state.downstream, payload) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:finish_reserved_frame, ref, result},
        _from,
        %{active_turn: %{ref: ref}} = state
      ) do
    {:reply, :ok, finish_active_turn(state, result)}
  end

  def handle_call({:finish_reserved_frame, _ref, _result}, _from, state) do
    {:reply, {:error, :stale_owner}, state}
  end

  @impl GenServer
  def handle_info(
        {:websocket_owner_upstream_frame, ref, payload},
        %{active_turn: %{ref: ref}} = state
      ) do
    _result = send_downstream(active_turn_downstream(state), {:data, payload})
    {:noreply, state}
  end

  def handle_info({:websocket_owner_upstream_frame, _ref, _payload}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{active_turn: %{task_ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, finish_active_turn(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_turn: %{task_ref: ref}} = state) do
    {:noreply, finish_active_turn(state, {:error, owner_error(reason)})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{downstream_monitor: ref} = state) do
    state =
      state
      |> Map.put(:downstream, nil)
      |> Map.put(:downstream_monitor, nil)
      |> maybe_schedule_idle_shutdown()

    {:noreply, state}
  end

  def handle_info(:idle_shutdown, %{downstream: nil, active_turn: nil} = state) do
    {:stop, :normal, %{state | idle_shutdown_ref: nil, draining?: true}}
  end

  def handle_info(:idle_shutdown, state) do
    {:noreply, %{state | idle_shutdown_ref: nil}}
  end

  def handle_info(:renew_owner_lease, state) do
    state = %{state | owner_renewal_ref: nil}

    case renew_owner_lease(state) do
      {:ok, state} ->
        {:noreply, schedule_owner_renewal(state)}

      {:error, reason} when reason in [:stale_owner, :owner_unavailable] ->
        log_owner_renewal_stale(reason, state)
        {:stop, {:shutdown, :stale_owner}, %{state | draining?: true}}

      {:error, reason} ->
        log_owner_renewal_failed(reason, state)
        {:noreply, schedule_owner_renewal(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, state) do
    state = cancel_owner_renewal(state)
    owner_exit_reason = owner_exit_reason(reason, state)
    log_owner_terminated(reason, owner_exit_reason, state)
    _result = release_owner_lease(state, owner_exit_reason)
    _result = interrupt_codex_session(state, owner_exit_reason)
    close_upstream(state.upstream_closer, state.upstream_pid)
    :ok
  end

  defp owner_reusable?(pid, opts) do
    expected = %{
      codex_session_id: Keyword.fetch!(opts, :codex_session_id),
      owner_lease_token: Keyword.fetch!(opts, :owner_lease_token),
      owner_instance_id: Keyword.fetch!(opts, :owner_instance_id)
    }

    case GenServer.call(pid, :owner_status, owner_call_timeout()) do
      {:ok, %{upstream_alive?: true, draining?: false} = status} ->
        Map.take(status, Map.keys(expected)) == expected

      _other ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp reserve_frame(owner, downstream) do
    GenServer.call(owner, {:reserve_frame, downstream}, owner_call_timeout())
  end

  defp activate_reserved_frame(owner, ref, task_ref) do
    GenServer.call(owner, {:activate_reserved_frame, ref, task_ref}, owner_call_timeout())
  end

  defp finish_reserved_frame(owner, ref, result) do
    GenServer.call(owner, {:finish_reserved_frame, ref, result}, owner_call_timeout())
  end

  defp send_upstream(
         %{owner: owner, ref: ref, upstream_pid: upstream_pid, upstream_sender: sender},
         upstream_payload
       ) do
    writer = fn frame -> send(owner, {:websocket_owner_upstream_frame, ref, frame}) end
    sender.(upstream_pid, upstream_payload, writer)
  end

  defp send_downstream(nil, _payload), do: {:error, :owner_unavailable}

  defp send_downstream(%{pid: pid, epoch: epoch, correlation_id: correlation_id}, payload) do
    message = {:websocket_owner_frame, correlation_id, epoch, payload}

    if WebsocketOwnerContract.downstream_message?(message) do
      send(pid, message)
      :ok
    else
      {:error, :invalid_downstream_message}
    end
  end

  defp send_owner_error(downstream, reason) do
    error = owner_error(reason)

    with {:ok, payload} <- WebsocketOwnerContract.safe_error_payload(error, nil) do
      send_downstream(downstream, {:error, error, payload})
    end
  end

  defp downstream_status(nil, _downstream), do: {:error, :stale_downstream}

  defp downstream_status(
         %{pid: pid, epoch: epoch, correlation_id: correlation_id},
         %{pid: pid, epoch: epoch, correlation_id: correlation_id}
       ),
       do: :active

  defp downstream_status(%{epoch: current_epoch}, %{epoch: epoch})
       when is_integer(epoch) and epoch < current_epoch,
       do: {:error, :duplicate_downstream}

  defp downstream_status(_current, _downstream), do: {:error, :stale_downstream}

  defp active_turn_downstream(%{active_turn: %{downstream: downstream}}) when is_map(downstream),
    do: downstream

  defp active_turn_downstream(state), do: state.downstream

  defp finish_active_turn(state, result) do
    downstream = active_turn_downstream(state)

    case result do
      :ok -> _result = send_downstream(downstream, :complete)
      {:ok, _result} -> _result = send_downstream(downstream, :complete)
      {:error, reason} -> _result = send_owner_error(downstream, reason)
      _other -> _result = send_owner_error(downstream, :owner_crashed)
    end

    state
    |> Map.put(:active_turn, nil)
    |> maybe_schedule_idle_shutdown()
  end

  defp put_active_turn_downstream(%{active_turn: active_turn} = state, downstream)
       when is_map(active_turn) and is_map(downstream) do
    %{state | active_turn: %{active_turn | downstream: downstream}}
  end

  defp put_active_turn_downstream(state, _downstream), do: state

  defp stale_or_busy(current_downstream, downstream) do
    case downstream_status(current_downstream, downstream) do
      :active -> {:error, :owner_busy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_downstream_epoch(nil), do: 1
  defp next_downstream_epoch(%{epoch: epoch}), do: epoch + 1

  defp demonitor_downstream(%{downstream_monitor: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | downstream_monitor: nil}
  end

  defp demonitor_downstream(state), do: state

  defp maybe_schedule_idle_shutdown(%{downstream: nil, active_turn: nil} = state),
    do: schedule_idle_shutdown(state)

  defp maybe_schedule_idle_shutdown(state), do: state

  defp schedule_idle_shutdown(%{idle_shutdown_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_idle_shutdown(%{idle_shutdown_ms: timeout} = state)
       when is_integer(timeout) and timeout >= 0 do
    %{state | idle_shutdown_ref: Process.send_after(self(), :idle_shutdown, timeout)}
  end

  defp schedule_idle_shutdown(state), do: state

  defp schedule_owner_renewal(%{owner_renewal_ms: timeout, codex_session_id: session_id} = state)
       when is_integer(timeout) and timeout > 0 do
    if uuid?(session_id) do
      %{state | owner_renewal_ref: Process.send_after(self(), :renew_owner_lease, timeout)}
    else
      state
    end
  end

  defp schedule_owner_renewal(state), do: state

  defp cancel_owner_renewal(%{owner_renewal_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | owner_renewal_ref: nil}
  end

  defp cancel_owner_renewal(state), do: state

  defp cancel_idle_shutdown(%{idle_shutdown_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_shutdown_ref: nil}
  end

  defp cancel_idle_shutdown(state), do: state

  defp upstream_boundary(opts) do
    Keyword.get_lazy(opts, :upstream, fn ->
      %{
        start: fn -> UpstreamWebSocketSession.start_link([]) end,
        send: fn upstream_pid, upstream_payload, writer ->
          send_owner_upstream(upstream_pid, upstream_payload, writer)
        end,
        close: &UpstreamWebSocketSession.close/1
      }
    end)
  end

  defp persistence_boundary(opts) do
    Keyword.get_lazy(opts, :persistence, fn ->
      %{
        release_owner_lease: &SessionContinuity.release_owner_lease/3,
        renew_owner_token: &SessionContinuity.renew_owner_token/3,
        interrupt_codex_session: &Interruption.interrupt_codex_session/2
      }
    end)
  end

  defp renew_owner_lease(state) do
    opts = RequestOptions.for_websocket(%{})

    case state.persistence.renew_owner_token.(
           state.codex_session_id,
           state.owner_lease_token,
           opts
         ) do
      {:ok, %{owner_lease_token: owner_lease_token, owner_instance_id: owner_instance_id}} ->
        {:ok,
         %{state | owner_lease_token: owner_lease_token, owner_instance_id: owner_instance_id}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    _kind, reason -> {:error, reason}
  end

  defp send_owner_upstream(upstream_pid, payload, _writer) when is_binary(payload) do
    case UpstreamWebSocketSession.send_request_frame(upstream_pid, payload) do
      {:ok, :sent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_owner_upstream(upstream_pid, %UpstreamWebSocketSession.Request{} = request, writer) do
    request = %{request | writer: writer}

    case UpstreamWebSocketSession.request(upstream_pid, request) do
      {:ok, result} -> {:ok, result}
      {:error, %{reason: reason}} -> {:error, reason}
    end
  end

  defp close_upstream(close, upstream_pid) when is_function(close, 1) and is_pid(upstream_pid) do
    close.(upstream_pid)
  catch
    :exit, _reason -> :ok
  end

  defp close_upstream(_close, _upstream_pid), do: :ok

  defp release_owner_lease(state, reason) do
    safe_persist_owner_exit(:release_owner_lease, state, reason, fn ->
      if reason == :stale_owner or not uuid?(state.codex_session_id) do
        :ok
      else
        state.persistence.release_owner_lease.(
          state.codex_session_id,
          state.owner_lease_token,
          Atom.to_string(reason)
        )
      end
    end)
  end

  defp interrupt_codex_session(state, reason) do
    safe_persist_owner_exit(:interrupt_codex_session, state, reason, fn ->
      if reason == :stale_owner or not uuid?(state.codex_session_id) do
        :ok
      else
        opts =
          %{
            interrupt_reason: Atom.to_string(reason),
            reconnect_window_seconds: 300
          }
          |> RequestOptions.for_websocket()

        state.persistence.interrupt_codex_session.(state.codex_session_id, opts)
      end
    end)
  end

  defp owner_renewal_ms do
    OperationalSettings.current().bridge_owner_lease_renewal_seconds * 1_000
  end

  defp safe_persist_owner_exit(operation, state, owner_exit_reason, fun) do
    case fun.() do
      {:error, reason} ->
        log_owner_exit_persistence_failure(operation, state, owner_exit_reason, reason)
        recover_owner_lifecycle_leftovers(state, owner_exit_reason)
        :ok

      _result ->
        :ok
    end
  rescue
    exception ->
      log_owner_exit_persistence_failure(operation, state, owner_exit_reason, exception)
      recover_owner_lifecycle_leftovers(state, owner_exit_reason)
      :ok
  catch
    _kind, reason ->
      log_owner_exit_persistence_failure(operation, state, owner_exit_reason, reason)
      recover_owner_lifecycle_leftovers(state, owner_exit_reason)
      :ok
  end

  defp recover_owner_lifecycle_leftovers(state, owner_exit_reason) do
    if uuid?(state.codex_session_id) do
      opts =
        %{
          interrupt_reason: Atom.to_string(owner_exit_reason),
          reconnect_window_seconds: 300
        }
        |> RequestOptions.for_websocket()

      _result =
        Interruption.recover_owner_lifecycle_leftovers(
          state.codex_session_id,
          owner_exit_reason,
          opts
        )

      :ok
    else
      :ok
    end
  end

  defp log_owner_exit_persistence_failure(operation, state, owner_exit_reason, reason) do
    Logger.warning(
      "websocket owner exit persistence failed " <>
        "codex_session_id=#{safe_log_value(state.codex_session_id)} " <>
        "operation=#{operation} " <>
        "reason_class=#{safe_log_value(Metadata.safe_reason(reason))} " <>
        "owner_exit_reason=#{owner_exit_reason} " <>
        "recovery_hint=task_7_owner_exit_recovery"
    )

    :ok
  end

  defp log_owner_started(pid, opts) do
    log_owner_event(:info, "websocket owner started",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      owner_pid: pid,
      request_id: Keyword.get(opts, :request_id)
    )
  end

  defp log_owner_reused(pid, opts) do
    log_owner_event(:info, "websocket owner reused",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      owner_pid: pid,
      request_id: Keyword.get(opts, :request_id)
    )
  end

  defp log_owner_stale_replaced(pid, opts) do
    log_owner_event(:info, "websocket owner stale replaced",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      owner_pid: pid,
      request_id: Keyword.get(opts, :request_id)
    )
  end

  defp log_owner_start_failed(reason, opts) do
    log_owner_event(:warning, "websocket owner start failed",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      reason: Metadata.safe_reason(reason),
      request_id: Keyword.get(opts, :request_id)
    )
  end

  defp log_owner_lookup_missed(codex_session_id, reason, pid, metadata) do
    log_owner_event(:info, "websocket owner lookup missed",
      codex_session_id: codex_session_id,
      owner_instance_id: Keyword.get(metadata, :owner_instance_id),
      owner_pid: pid,
      reason: reason,
      request_id: Keyword.get(metadata, :request_id)
    )
  end

  defp log_owner_renewal_stale(reason, state) do
    log_owner_event(:warning, "websocket owner renewal stale",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      reason: Metadata.safe_reason(reason),
      request_id: state.request_id
    )
  end

  defp log_owner_renewal_failed(reason, state) do
    log_owner_event(:warning, "websocket owner renewal failed",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      reason: Metadata.safe_reason(reason),
      request_id: state.request_id
    )
  end

  defp log_owner_terminated(reason, owner_exit_reason, state) do
    log_owner_event(:info, "websocket owner terminated",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      reason: Metadata.safe_reason(reason),
      owner_exit_reason: owner_exit_reason,
      request_id: state.request_id,
      downstream_epoch: downstream_epoch(state.downstream)
    )
  end

  defp log_owner_event(level, message, metadata) do
    log_line =
      metadata
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{safe_log_value(value)}" end)

    Logger.log(level, message <> " " <> log_line)
  end

  defp downstream_epoch(%{epoch: epoch}) when is_integer(epoch), do: epoch
  defp downstream_epoch(_downstream), do: nil

  defp safe_log_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_log_value(value) when is_pid(value), do: inspect(value)

  defp safe_log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  defp safe_log_value(_value), do: "unknown"

  defp uuid?(value) when is_binary(value) do
    String.match?(
      value,
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
    )
  end

  defp uuid?(_value), do: false

  defp owner_exit_reason(:owner_drained, _state), do: :owner_drained
  defp owner_exit_reason(:stale_owner, _state), do: :stale_owner
  defp owner_exit_reason({:shutdown, :stale_owner}, _state), do: :stale_owner
  defp owner_exit_reason(:normal, %{draining?: true}), do: :owner_drained
  defp owner_exit_reason(:normal, _state), do: :owner_drained
  defp owner_exit_reason(:shutdown, _state), do: :owner_drained
  defp owner_exit_reason({:shutdown, _details}, _state), do: :owner_drained
  defp owner_exit_reason(_reason, _state), do: :owner_crashed

  defp owner_error(error)
       when error in [:owner_unavailable, :stale_owner, :owner_busy, :owner_drained],
       do: error

  defp owner_error({:error, error}), do: owner_error(error)
  defp owner_error(:normal), do: :owner_unavailable
  defp owner_error(_reason), do: :owner_crashed

  defp owner_call_timeout, do: WebsocketOwnerContract.default_owner_call_timeout_ms()
end
