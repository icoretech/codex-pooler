defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession do
  @moduledoc false

  use GenServer

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.{
    DownstreamState,
    Logger,
    Persistence
  }

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
          required(:correlation_id) => binary(),
          optional(:active_turn_reconnect?) => boolean()
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
        Logger.owner_started(pid, opts)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        existing_owner_result(pid, opts, attempts)

      {:error, {:already_registered, pid}} ->
        existing_owner_result(pid, opts, attempts)

      {:error, reason} ->
        Logger.owner_start_failed(reason, opts)
        {:error, reason}
    end
  end

  defp start_owner(_opts, 0), do: {:error, :owner_unavailable}

  defp existing_owner_result(pid, opts, attempts) when is_pid(pid) do
    cond do
      not Process.alive?(pid) ->
        Logger.owner_lookup_missed(Keyword.fetch!(opts, :codex_session_id), :dead_pid, pid, opts)
        :erlang.yield()
        start_owner(opts, attempts - 1)

      not uuid?(Keyword.fetch!(opts, :codex_session_id)) or owner_reusable?(pid, opts) ->
        Logger.owner_reused(pid, opts)
        {:ok, pid, :existing}

      true ->
        Logger.owner_stale_replaced(pid, opts)
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
          Logger.owner_lookup_missed(codex_session_id, :dead_pid, pid, metadata)
          {:error, :owner_unavailable}
        end

      [] ->
        Logger.owner_lookup_missed(codex_session_id, :not_registered, nil, metadata)
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

  @spec submit_request(GenServer.server(), downstream(), UpstreamWebsocketSession.Request.t()) ::
          :ok
          | {:ok, term()}
          | {:error, UpstreamWebsocketSession.request_failure()}
          | {:error, WebsocketOwnerContract.owner_error() | term()}
  def submit_request(owner, downstream, %UpstreamWebsocketSession.Request{} = request)
      when is_map(downstream) do
    submit_upstream(owner, downstream, request)
  end

  defp submit_upstream(owner, downstream, upstream_payload)
       when is_map(downstream) do
    GenServer.call(owner, {:submit_upstream, downstream, upstream_payload}, :infinity)
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
    state =
      if DownstreamState.active_turn?(state) do
        finish_active_turn(state, {:error, :owner_drained})
      else
        _result = send_owner_error(state.downstream, :owner_drained)
        state
      end

    {:stop, :normal, :ok, %{state | draining?: true}}
  end

  def handle_call({:attach_downstream, _pid, _correlation_id}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call({:attach_downstream, pid, correlation_id}, _from, state) do
    state =
      state
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.cancel_idle_shutdown()

    epoch = DownstreamState.next_downstream_epoch(state.downstream)
    monitor = Process.monitor(pid)

    downstream = %{
      pid: pid,
      epoch: epoch,
      correlation_id: correlation_id,
      active_turn_reconnect?: DownstreamState.active_turn?(state)
    }

    state = DownstreamState.put_active_turn_downstream(state, downstream)

    {:reply, {:ok, downstream}, %{state | downstream: downstream, downstream_monitor: monitor}}
  end

  def handle_call({:detach_downstream, pid, epoch, correlation_id}, _from, state) do
    case DownstreamState.downstream_status(state.downstream, %{
           pid: pid,
           epoch: epoch,
           correlation_id: correlation_id
         }) do
      :active ->
        state =
          state
          |> DownstreamState.demonitor_downstream()
          |> DownstreamState.schedule_idle_shutdown()
          |> DownstreamState.cancel_active_turn_downstream(%{
            pid: pid,
            epoch: epoch,
            correlation_id: correlation_id
          })

        {:reply, :ok, %{state | downstream: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit_upstream, _downstream, _payload}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:submit_upstream, downstream, _payload},
        _from,
        %{active_turn: active_turn} = state
      )
      when not is_nil(active_turn) do
    {:reply, DownstreamState.stale_or_busy(state.downstream, downstream), state}
  end

  def handle_call({:submit_upstream, downstream, upstream_payload}, from, state) do
    case DownstreamState.downstream_status(state.downstream, downstream) do
      :active ->
        ref = make_ref()
        task = start_upstream_task(state, ref, upstream_payload)
        {submitter_pid, _tag} = from

        active_turn = %{
          ref: ref,
          task_pid: task.pid,
          task_ref: task.ref,
          submitter_monitor: Process.monitor(submitter_pid),
          reply_to: from,
          downstream: state.downstream
        }

        {:noreply, %{state | active_turn: active_turn}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:push_downstream, payload}, _from, state) do
    case send_downstream(state.downstream, payload) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(
        {:websocket_owner_upstream_frame, ref, payload},
        %{active_turn: %{ref: ref}} = state
      ) do
    _result = send_downstream(DownstreamState.active_turn_downstream(state), {:data, payload})
    {:noreply, state}
  end

  def handle_info({:websocket_owner_upstream_frame, _ref, _payload}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{active_turn: %{task_ref: ref}} = state) do
    result = DownstreamState.effective_active_turn_result(state.active_turn, result)
    reply_active_turn(state, result)

    {:noreply, finish_active_turn(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_turn: %{task_ref: ref}} = state) do
    result =
      DownstreamState.effective_active_turn_result(
        state.active_turn,
        {:error, owner_error(reason)}
      )

    reply_active_turn(state, result)

    {:noreply, finish_active_turn(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active_turn: %{submitter_monitor: ref} = active_turn} = state
      ) do
    DownstreamState.cancel_active_turn_task(active_turn)

    {:noreply, finish_active_turn(state, {:error, :client_disconnected})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{downstream_monitor: ref} = state) do
    state =
      state
      |> Map.put(:downstream, nil)
      |> Map.put(:downstream_monitor, nil)
      |> DownstreamState.maybe_schedule_idle_shutdown()

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

    case Persistence.renew_owner_lease(state) do
      {:ok, state} ->
        {:noreply, schedule_owner_renewal(state)}

      {:error, reason} when reason in [:stale_owner, :owner_unavailable] ->
        Logger.owner_renewal_stale(reason, state)
        {:stop, {:shutdown, :stale_owner}, %{state | draining?: true}}

      {:error, reason} ->
        Logger.owner_renewal_failed(reason, state)
        {:noreply, schedule_owner_renewal(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, state) do
    state = cancel_owner_renewal(state)
    owner_exit_reason = owner_exit_reason(reason, state)
    Logger.owner_terminated(reason, owner_exit_reason, state)
    _result = Persistence.release_owner_lease(state, owner_exit_reason)
    _result = Persistence.interrupt_codex_session(state, owner_exit_reason)
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

  defp start_upstream_task(state, ref, upstream_payload) do
    reservation = %{
      owner: self(),
      ref: ref,
      upstream_pid: state.upstream_pid,
      upstream_sender: state.upstream_sender
    }

    Task.Supervisor.async_nolink(@task_supervisor, fn ->
      Process.flag(:sensitive, true)
      send_upstream(reservation, upstream_payload)
    end)
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

  defp reply_active_turn(%{active_turn: %{reply_to: reply_to}}, result) do
    GenServer.reply(reply_to, result)
  end

  defp finish_active_turn(state, result) do
    downstream = DownstreamState.active_turn_downstream(state)
    DownstreamState.clear_active_turn_monitors(state.active_turn)

    case result do
      :ok -> _result = send_downstream(downstream, :complete)
      {:ok, _result} -> _result = send_downstream(downstream, :complete)
      {:error, %{body: _body, reason: _reason}} -> :ok
      {:error, reason} -> _result = send_owner_error(downstream, reason)
      _other -> _result = send_owner_error(downstream, :owner_crashed)
    end

    state
    |> Map.put(:active_turn, nil)
    |> DownstreamState.maybe_schedule_idle_shutdown()
  end

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

  defp send_owner_upstream(upstream_pid, payload, _writer) when is_binary(payload) do
    case UpstreamWebsocketSession.send_request_frame(upstream_pid, payload) do
      {:ok, :sent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_owner_upstream(upstream_pid, %UpstreamWebsocketSession.Request{} = request, writer) do
    request = %{request | writer: writer}

    case UpstreamWebsocketSession.request(upstream_pid, request) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{transport_failure: transport_failure} = response}
      when is_map(transport_failure) and map_size(transport_failure) > 0 ->
        {:error, response}

      {:error, %{reason: reason}} when is_atom(reason) ->
        {:error, reason}

      {:error, response} when is_map(response) ->
        {:error, response}
    end
  end

  defp close_upstream(close, upstream_pid) when is_function(close, 1) and is_pid(upstream_pid) do
    close.(upstream_pid)
  catch
    :exit, _reason -> :ok
  end

  defp close_upstream(_close, _upstream_pid), do: :ok

  defp owner_renewal_ms do
    OperationalSettings.current().bridge_owner_lease_renewal_seconds * 1_000
  end

  defp upstream_boundary(opts) do
    Keyword.get_lazy(opts, :upstream, fn ->
      %{
        start: fn -> UpstreamWebsocketSession.start_link([]) end,
        send: fn upstream_pid, upstream_payload, writer ->
          send_owner_upstream(upstream_pid, upstream_payload, writer)
        end,
        close: &UpstreamWebsocketSession.close/1
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
       when error in [
              :owner_unavailable,
              :stale_owner,
              :owner_busy,
              :owner_drained,
              :client_disconnected
            ],
       do: error

  defp owner_error({:error, error}), do: owner_error(error)
  defp owner_error(:normal), do: :owner_unavailable
  defp owner_error(_reason), do: :owner_crashed

  defp owner_call_timeout, do: WebsocketOwnerContract.default_owner_call_timeout_ms()
end
