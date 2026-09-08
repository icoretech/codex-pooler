defmodule CodexPooler.Gateway.Runtime.SessionLeaseHeartbeat do
  @moduledoc false

  use GenServer

  alias CodexPooler.Gateway.{OperationalSettings, OwnerRenewalSchedule}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness

  @call_timeout 1_000
  @http_transports ["http_json", "http_sse", "http_compact_json"]

  defstruct [
    :session_id,
    :owner_lease_token,
    :ttl_seconds,
    :renewal_interval_ms,
    :caller_pid,
    :caller_monitor,
    :renew,
    :renewal_delay,
    :renewal_ref,
    :renewal_token,
    :handoff_ref,
    :handoff_token
  ]

  @type result :: {:ok, pid()} | :ignore

  @spec start(RequestOptions.t()) :: result()
  def start(%RequestOptions{} = request_options), do: start(request_options, [])

  @spec start(RequestOptions.t(), keyword()) :: result()
  def start(%RequestOptions{} = request_options, opts) when is_list(opts) do
    case lifecycle(request_options, opts) do
      {:ok, lifecycle} -> GenServer.start(__MODULE__, lifecycle)
      :ignore -> :ignore
    end
  end

  @spec run(RequestOptions.t(), (-> term()) | (pid() | nil -> term())) ::
          term() | {:error, :stale_owner | :owner_unavailable}
  def run(%RequestOptions{} = request_options, callback) when is_function(callback, 0) do
    run(request_options, fn _heartbeat -> callback.() end)
  end

  def run(%RequestOptions{} = request_options, callback) when is_function(callback, 1) do
    case start(request_options, schedule?: false) do
      :ignore ->
        callback.(nil)

      {:ok, heartbeat} ->
        case renew_now(heartbeat) do
          :ok -> run_callback(heartbeat, callback)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.call(pid, :stop, @call_timeout)
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  @spec stream_started(pid() | nil) :: :ok
  def stream_started(nil), do: :ok

  def stream_started(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.call(pid, :stream_started, @call_timeout)
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  @impl GenServer
  def init(lifecycle) do
    caller_monitor = Process.monitor(lifecycle.caller_pid)

    state = %__MODULE__{
      session_id: lifecycle.session_id,
      owner_lease_token: lifecycle.owner_lease_token,
      ttl_seconds: lifecycle.ttl_seconds,
      renewal_interval_ms: lifecycle.renewal_interval_ms,
      caller_pid: lifecycle.caller_pid,
      caller_monitor: caller_monitor,
      renew: lifecycle.renew,
      renewal_delay: lifecycle.renewal_delay
    }

    if lifecycle.schedule? do
      {:ok, schedule_renewal(state)}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call(:renew_now, _from, state) do
    case renew(state) do
      :ok -> {:reply, :ok, schedule_renewal(state)}
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call(:stream_started, _from, state) do
    {:reply, :ok, cancel_handoff(state)}
  end

  def handle_call({:handoff, ttl_ms}, _from, state) when is_integer(ttl_ms) and ttl_ms > 0 do
    {:reply, :ok, schedule_handoff(state, ttl_ms)}
  end

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}

  @impl GenServer
  def handle_info({:session_lease_heartbeat_renew, token}, %{renewal_token: token} = state) do
    state = %{state | renewal_ref: nil, renewal_token: nil}

    case renew(state) do
      :ok -> {:noreply, schedule_renewal(state)}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  def handle_info(
        {:session_lease_heartbeat_handoff_timeout, token},
        %{handoff_token: token} = state
      ),
      do: {:stop, :normal, %{state | handoff_ref: nil, handoff_token: nil}}

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{caller_monitor: monitor, caller_pid: pid} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _state = state |> cancel_renewal() |> cancel_handoff() |> demonitor_caller()
    :ok
  end

  defp run_callback(heartbeat, callback) do
    result = callback.(heartbeat)

    if deferred_result?(result) do
      case begin_handoff(heartbeat) do
        :ok -> result
        {:error, reason} -> {:error, reason}
      end
    else
      :ok = stop(heartbeat)
      result
    end
  catch
    kind, reason ->
      :ok = stop(heartbeat)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp begin_handoff(heartbeat) do
    GenServer.call(heartbeat, {:handoff, ttl_ms(heartbeat)}, @call_timeout)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp renew_now(heartbeat) do
    GenServer.call(heartbeat, :renew_now, @call_timeout)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp lifecycle(%RequestOptions{} = request_options, opts) do
    with %CodexSession{id: session_id} <- request_options.continuity.codex_session,
         %OwnerWitness{session_id: ^session_id, lease_token: owner_lease_token} <-
           request_options.runtime.session_owner_witness,
         transport when transport in @http_transports <- request_options.transport.transport,
         true <- is_pid(Keyword.get(opts, :caller, self())) do
      ttl_seconds = ttl_seconds(request_options)
      renewal_interval_ms = renewal_interval_ms(opts)

      {:ok,
       %{
         session_id: session_id,
         owner_lease_token: owner_lease_token,
         ttl_seconds: ttl_seconds,
         renewal_interval_ms:
           OwnerRenewalSchedule.base_interval_ms(renewal_interval_ms, ttl_seconds * 1_000),
         caller_pid: Keyword.get(opts, :caller, self()),
         schedule?: Keyword.get(opts, :schedule?, true) == true,
         renew: Keyword.get(opts, :renew, &SessionContinuity.renew_owner_token/3),
         renewal_delay: Keyword.get(opts, :renewal_delay, &OwnerRenewalSchedule.staggered_delay/1)
       }}
    else
      _ineligible -> :ignore
    end
  end

  defp ttl_seconds(%RequestOptions{} = request_options) do
    case request_options.continuity.bridge_owner_lease_ttl_seconds do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _value -> OperationalSettings.current().bridge_owner_lease_ttl_seconds
    end
  end

  defp renewal_interval_ms(opts) do
    case Keyword.get(opts, :renewal_interval_ms) do
      interval when is_integer(interval) and interval > 0 -> interval
      _value -> OperationalSettings.current().bridge_owner_lease_renewal_seconds * 1_000
    end
  end

  defp ttl_ms(heartbeat) do
    case :sys.get_state(heartbeat) do
      %__MODULE__{ttl_seconds: ttl_seconds} -> ttl_seconds * 1_000
    end
  catch
    :exit, _reason -> 1
  end

  defp deferred_result?({:ok, %{stream: stream}}) when is_function(stream), do: true
  defp deferred_result?(%{stream: stream}) when is_function(stream), do: true
  defp deferred_result?(_result), do: false

  defp renew(state) do
    case state.renew.(state.session_id, state.owner_lease_token, renewal_options(state)) do
      {:ok, %CodexSession{}} -> :ok
      {:error, :stale_owner} -> {:error, :stale_owner}
      {:error, :owner_unavailable} -> {:error, :owner_unavailable}
      _other -> {:error, :owner_unavailable}
    end
  rescue
    _exception -> {:error, :owner_unavailable}
  catch
    _kind, _reason -> {:error, :owner_unavailable}
  end

  defp renewal_options(state) do
    RequestOptions.build(
      [bridge_owner_lease_ttl_seconds: state.ttl_seconds, transport: "http_json"],
      "/backend-api/codex/responses",
      %{}
    )
  end

  defp schedule_renewal(state) do
    state = cancel_renewal(state)
    token = make_ref()

    delay =
      state.renewal_interval_ms
      |> state.renewal_delay.()
      |> OwnerRenewalSchedule.bounded_delay(state.renewal_interval_ms)

    %{
      state
      | renewal_token: token,
        renewal_ref: Process.send_after(self(), {:session_lease_heartbeat_renew, token}, delay)
    }
  end

  defp schedule_handoff(state, ttl_ms) do
    state = cancel_handoff(state)
    token = make_ref()

    %{
      state
      | handoff_token: token,
        handoff_ref:
          Process.send_after(self(), {:session_lease_heartbeat_handoff_timeout, token}, ttl_ms)
    }
  end

  defp cancel_renewal(%{renewal_ref: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{state | renewal_ref: nil, renewal_token: nil}
  end

  defp cancel_renewal(state), do: state

  defp cancel_handoff(%{handoff_ref: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{state | handoff_ref: nil, handoff_token: nil}
  end

  defp cancel_handoff(state), do: state

  defp demonitor_caller(%{caller_monitor: ref} = state) when is_reference(ref) do
    _ = Process.demonitor(ref, [:flush])
    %{state | caller_monitor: nil}
  end

  defp demonitor_caller(state), do: state
end
