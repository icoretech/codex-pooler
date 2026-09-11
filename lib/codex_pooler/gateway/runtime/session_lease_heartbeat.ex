defmodule CodexPooler.Gateway.Runtime.SessionLeaseHeartbeat do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexPooler.Gateway.{OperationalSettings, OwnerRenewalSchedule}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy

  @call_timeout 1_000
  # The caller waits this long for the synchronous pre-dispatch renewal before
  # it gives the renewal up as owner_unavailable. Production keeps the 1 s
  # bound: a longer wait would hold the renewal's pool connection behind a
  # locked session row. A start option overrides it.
  @renew_call_timeout_ms 1_000
  # The synchronous renewal's database lock wait ends this long before the call
  # bound, so a held session or lease row lock fails inside PostgreSQL and the
  # heartbeat replies, rather than the caller killing it mid-transaction. The
  # margin covers pool checkout, BEGIN, and the lock-timeout statements.
  @renew_lock_timeout_margin_ms 200
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
    :handoff_token,
    :renew_call_timeout_ms,
    :test_observer
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
    start_opts = [schedule?: false] ++ test_start_options()

    case start(request_options, start_opts) do
      :ignore ->
        callback.(nil)

      {:ok, heartbeat} ->
        session_id = request_options.continuity.codex_session.id

        case renew_now(heartbeat, renew_call_timeout_ms(start_opts), session_id) do
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
      renewal_delay: lifecycle.renewal_delay,
      renew_call_timeout_ms: lifecycle.renew_call_timeout_ms,
      test_observer: lifecycle.test_observer
    }

    notify_test_observer(state, :started)

    if lifecycle.schedule? do
      {:ok, schedule_renewal(state)}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call(:renew_now, _from, state) do
    case renew(state, :synchronous) do
      :ok -> {:reply, :ok, schedule_renewal(state)}
      {:error, reason, reason_class} -> {:stop, :normal, {:error, reason, reason_class}, state}
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

    case renew(state, :scheduled) do
      :ok ->
        {:noreply, schedule_renewal(state)}

      {:error, _reason, reason_class} ->
        log_renewal_failure(state.session_id, :scheduled, reason_class)
        {:stop, :normal, state}
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
    notify_test_observer(state, :stopped)
    :ok
  end

  defp run_callback(heartbeat, callback) do
    result = callback.(heartbeat)

    if deferred_result?(result) do
      _ = begin_handoff(heartbeat)
      result
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

  # The caller logs every synchronous failure exactly once: the heartbeat replies
  # with its reason class, or is killed after the call bound without logging.
  defp renew_now(heartbeat, timeout, session_id) do
    case GenServer.call(heartbeat, :renew_now, timeout) do
      :ok ->
        :ok

      {:error, reason, reason_class} ->
        log_renewal_failure(session_id, :synchronous, reason_class)
        {:error, reason}
    end
  catch
    :exit, reason ->
      terminate_after_call_failure(heartbeat)
      log_renewal_failure(session_id, :synchronous, call_exit_reason_class(reason))
      {:error, :owner_unavailable}
  end

  defp call_exit_reason_class({:timeout, _call}), do: :call_timeout
  defp call_exit_reason_class(_reason), do: :heartbeat_exit

  defp terminate_after_call_failure(heartbeat) do
    monitor = Process.monitor(heartbeat)

    if Process.alive?(heartbeat) do
      Process.exit(heartbeat, :kill)
    end

    receive do
      {:DOWN, ^monitor, :process, ^heartbeat, _reason} -> :ok
    after
      @call_timeout ->
        Process.demonitor(monitor, [:flush])
        :ok
    end
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
         renew: Keyword.get(opts, :renew, &SessionContinuity.renew_owner_token/4),
         renewal_delay:
           Keyword.get(opts, :renewal_delay, &OwnerRenewalSchedule.staggered_delay/1),
         renew_call_timeout_ms: renew_call_timeout_ms(opts),
         test_observer: test_observer(request_options)
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

  defp renew_call_timeout_ms(opts) do
    case Keyword.get(opts, :renew_call_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _value -> @renew_call_timeout_ms
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

  defp renew(state, phase) do
    state
    |> invoke_renew(phase)
    |> classify_renewal()
  rescue
    exception -> {:error, :owner_unavailable, exception_reason_class(exception)}
  catch
    kind, _reason -> {:error, :owner_unavailable, caught_reason_class(kind)}
  end

  defp invoke_renew(%{renew: renew} = state, phase) when is_function(renew, 4) do
    renew.(
      state.session_id,
      state.owner_lease_token,
      renewal_options(state),
      renewal_lock_options(state, phase)
    )
  end

  defp invoke_renew(%{renew: renew} = state, _phase),
    do: renew.(state.session_id, state.owner_lease_token, renewal_options(state))

  # Only the synchronous pre-dispatch renewal has a caller waiting on a bound.
  # A scheduled renewal keeps waiting for the lock: its lease is still live, and
  # failing it on a transient wait would stop the heartbeat mid-request.
  defp renewal_lock_options(state, :synchronous),
    do: [lock_timeout_ms: renew_lock_timeout_ms(state.renew_call_timeout_ms)]

  defp renewal_lock_options(_state, :scheduled), do: []

  defp renew_lock_timeout_ms(call_timeout_ms),
    do: max(call_timeout_ms - @renew_lock_timeout_margin_ms, max(div(call_timeout_ms, 2), 1))

  defp classify_renewal({:ok, %CodexSession{}}), do: :ok
  defp classify_renewal({:error, :stale_owner}), do: {:error, :stale_owner, :stale_owner}

  defp classify_renewal({:error, :owner_unavailable}),
    do: {:error, :owner_unavailable, :owner_unavailable}

  defp classify_renewal({:error, :lock_timeout}), do: {:error, :owner_unavailable, :lock_timeout}
  defp classify_renewal(_other), do: {:error, :owner_unavailable, :unexpected_result}

  defp exception_reason_class(%DBConnection.ConnectionError{}), do: :database_unavailable
  defp exception_reason_class(%Postgrex.Error{}), do: :database_error
  defp exception_reason_class(_exception), do: :exception

  defp caught_reason_class(:exit), do: :exit
  defp caught_reason_class(_kind), do: :throw

  # One bounded line per failed renewal: fixed phase and reason vocabularies and
  # the trusted internal session correlator, never the lease token.
  defp log_renewal_failure(session_id, phase, reason_class) do
    Logger.warning(
      "session lease renewal failed phase=#{phase} reason=#{reason_class} " <>
        "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(session_id)}"
    )
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

  if Mix.env() == :test do
    # Controller tests set this in the request process, the only place a
    # synchronous renewal's start options can come from on that path.
    defp test_start_options do
      timeout_options =
        case Process.get({__MODULE__, :renew_call_timeout_ms}) do
          timeout when is_integer(timeout) and timeout > 0 -> [renew_call_timeout_ms: timeout]
          _value -> []
        end

      case Process.get({__MODULE__, :renew}) do
        renew when is_function(renew, 3) or is_function(renew, 4) ->
          [renew: renew] ++ timeout_options

        _value ->
          timeout_options
      end
    end

    defp test_observer(%RequestOptions{extra: %{session_lease_heartbeat_test_observer: observer}})
         when is_pid(observer),
         do: observer

    defp test_observer(%RequestOptions{}), do: nil

    defp notify_test_observer(%{test_observer: observer}, event)
         when is_pid(observer) and event in [:started, :stopped],
         do: send(observer, {:session_lease_heartbeat, event, self()})

    defp notify_test_observer(_state, _event), do: :ok
  else
    defp test_start_options, do: []
    defp test_observer(%RequestOptions{}), do: nil
    defp notify_test_observer(_state, _event), do: :ok
  end
end
