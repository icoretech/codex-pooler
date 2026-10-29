defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage
  alias CodexPooler.Gateway.Runtime.NativeResponseSteering
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Runtime.Streaming.ModelDeclarationObserver
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.ProviderCreditsAdmission
  alias CodexPooler.Gateway.Transports.Streaming.CollectedBody
  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody
  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesToolCompletion
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Confirmation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.FirstCompactCollection
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.FirstCompactResult
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionLifecycleObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission
  alias CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult
  alias CodexPooler.Gateway.Transports.Websocket.ResponseInterrupt
  alias CodexPooler.Gateway.Transports.Websocket.ResponseSteer
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.CloseDiagnostics
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState.Delivery
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketFrameWriter
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV6
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Platform.ExecutionIdentity
  alias CodexPooler.RouteClass

  @default_keepalive_interval_ms 25_000
  @dev_features_build_enabled Application.compile_env(
                                :codex_pooler,
                                :dev_features_build_enabled,
                                false
                              )
  @connection_lifecycle_keys [:lifecycle_id, :generation]
  # The terminals of a response the provider completed. Only these record a
  # response id or a collected compaction; they, and a response the client
  # interrupted (`context_kept_terminal?/2`), record a serving mode.
  @completed_terminals ["response.completed", "response.done"]
  # The budget of a caller's call to the session's compaction admission.
  @admission_call_timeout_ms 1_000
  @five_seconds_ms :timer.seconds(5)
  @thirty_seconds_ms :timer.seconds(30)
  @one_minute_ms :timer.minutes(1)
  @two_minutes_ms :timer.minutes(2)
  @five_minutes_ms :timer.minutes(5)
  @ten_minutes_ms :timer.minutes(10)
  @fifteen_minutes_ms :timer.minutes(15)
  @thirty_minutes_ms :timer.minutes(30)
  @type response_headers :: [{binary(), binary()}]
  @type decoded_frame :: map() | :non_object_json | :undecodable
  @type message_mapper :: (binary() -> binary()) | nil
  @type connection_lifecycle_state :: %{
          required(:lifecycle_id) => Ecto.UUID.t(),
          required(:generation) => non_neg_integer()
        }
  @type connection_usage :: %{
          required(:reused) => boolean(),
          required(:reconnected) => boolean()
        }
  @type upstream_websocket_connection :: %{
          required(:lifecycle_id) => Ecto.UUID.t(),
          required(:generation) => pos_integer(),
          required(:reused) => boolean(),
          required(:reconnected) => boolean()
        }
  @type request_success :: %{
          required(:body) => binary(),
          required(:terminal) => binary(),
          required(:status) => 200,
          required(:headers) => response_headers(),
          required(:provider_credits_admission) => ProviderCreditsAdmission.Receipt.t(),
          optional(:response_id) => String.t(),
          optional(:response_usage) => ResponseUsage.usage() | nil,
          optional(:ordinary_success_result) => OrdinarySuccessResult.t(),
          optional(:native_client_retry_observation) => ClientRetry.Observation.t() | nil,
          optional(:first_compact_result) => FirstCompactResult.t(),
          optional(:upstream_websocket_connection) => upstream_websocket_connection(),
          optional(:websocket_frame_headers) => map(),
          optional(:upstream_error_code) => String.t() | nil,
          optional(:upstream_error_param) => String.t() | nil
        }
  @type request_failure :: %{
          required(:body) => binary(),
          required(:reason) => term(),
          required(:headers) => response_headers(),
          optional(:upstream_websocket_connection) => upstream_websocket_connection(),
          optional(:websocket_frame_headers) => map(),
          optional(:upstream_error_param) => String.t() | nil,
          optional(:transport_failure) => TransportFailureReason.transport_failure_metadata(),
          optional(:native_client_retry_observation) => ClientRetry.Observation.t() | nil
        }
  @type request_result :: {:ok, request_success()} | {:error, request_failure()}
  @type send_result :: {:ok, :sent} | {:error, term()}
  @type invalidation_result :: :ok | {:error, :upstream_websocket_not_connected}
  @type connection_closed_signal ::
          {:upstream_websocket_connection_closed, pid(),
           %{
             required(:cause) => CloseDiagnostics.cause(),
             required(:lifecycle_id) => Ecto.UUID.t(),
             required(:generation) => pos_integer(),
             required(:connection_requests) => pos_integer(),
             optional(:steering_peer_close) => {pid(), integer(), binary()}
           }}

  # `connection_close_subscriber: pid` names the one process that learns when
  # a connection that carried at least one request closes outside a request
  # for a cause in `CloseDiagnostics.anchor_invalidating_causes/0`, as a
  # `t:connection_closed_signal/0` sent right after the connection closed.
  # `generation` names the closed connection (the next one is
  # `generation + 1`) and `connection_requests` counts the requests sent on
  # it. The provider closes an idle connection (its 60-minute limit, a
  # restart) without the downstream client seeing it, and the client's next
  # request then carries a `previous_response_id` only the closed connection
  # could resolve (findings#270). The subscriber survives every close and
  # reconnect; the session neither links to nor monitors it, so a subscriber
  # that is gone only misses the message.
  #
  # `admission_topology: :forwarded` marks the session a websocket owner
  # holds: the owner keeps the native compaction admission, and the lifecycle
  # observations this session still emits for its connections (a clear with
  # nothing to clear, a rejected capability) name the owner's topology
  # instead of `:direct` (findings#270 row 270-163). It survives every
  # reconnect.
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    init_arg = {:new, Keyword.get(opts, :connection_close_subscriber), Keyword.get(opts, :admission_topology, :direct)}

    case GenServer.start_link(__MODULE__, init_arg) do
      {:ok, pid} = result ->
        _trace = NativeCompactionTrace.enroll(:upstream_session, pid)
        result

      other ->
        other
    end
  end

  @spec request(pid(), Request.t()) :: request_result()
  def request(pid, %Request{} = request) do
    GenServer.call(pid, {:request, request}, :infinity)
  catch
    :exit, _reason ->
      request_error(:upstream_websocket_session_unavailable, %{})
  end

  # A frame waits for the session like a request does. The session serves one
  # call at a time and holds a request's call until its turn settles, so a frame
  # sent while a turn is still collecting upstream frames is served right after
  # it, on the same connection; the turn's own connect and receive timeouts end
  # a stalled turn. A fixed call bound only abandoned the reply: the queued
  # frame still went upstream once the turn ended, while the caller had already
  # answered its client that the forward failed and recorded nothing
  # (findings#206 row 206-322). A session that stops still ends the call at
  # once, as `upstream_websocket_session_unavailable`.
  @spec send_request_frame(pid(), binary()) :: send_result()
  def send_request_frame(pid, payload) when is_pid(pid) and is_binary(payload) do
    GenServer.call(pid, {:send_text, payload}, :infinity)
  catch
    :exit, _reason -> {:error, :upstream_websocket_session_unavailable}
  end

  @doc """
  Hands the session a client's `response.interrupt` for the response it names
  (`ResponseInterrupt`, findings#270 row 270-272). The session writes it only
  while that response is in flight on its connection as a relayed turn and no
  terminal of it has been read; otherwise it drops it. Either way it logs the
  one line the interrupt leaves. The call never waits: a session serving a
  turn reads the message inside that turn's receive loop.
  """
  @spec interrupt(pid(), ResponseInterrupt.t()) :: :ok
  def interrupt(pid, %{response_id: response_id, mode: mode} = interrupt)
      when is_pid(pid) and is_binary(response_id) and is_binary(mode) do
    send(pid, {:upstream_websocket_interrupt, interrupt})
    :ok
  end

  @spec steer(pid(), ResponseSteer.t()) :: :ok
  def steer(pid, %{} = steer) when is_pid(pid) do
    send(pid, {:upstream_websocket_steer, steer})
    :ok
  end

  @spec connection_lifecycle_snapshot(pid()) ::
          connection_lifecycle_state() | {:error, :unavailable}
  def connection_lifecycle_snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :connection_lifecycle_snapshot, 1_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def connection_lifecycle_snapshot(_pid), do: {:error, :invalid_input}

  # The connection a native compaction admission names is usable only while
  # it is this session's open connection: a compaction's final, or the next
  # compaction, sent after the provider closed it cannot reach the provider
  # (findings#275). `generation` is the open connection's, nil between two
  # connections.
  @spec live_connection(pid()) ::
          {:ok, %{lifecycle_id: Ecto.UUID.t(), generation: pos_integer() | nil}} | {:error, :unavailable | :invalid_input}
  def live_connection(pid) when is_pid(pid) do
    GenServer.call(pid, :live_connection, 1_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def live_connection(_pid), do: {:error, :invalid_input}

  @spec producer_identity(pid()) :: map() | :unknown
  def producer_identity(pid) when is_pid(pid) do
    GenServer.call(pid, :producer_identity, 1_000)
  catch
    :exit, _reason -> :unknown
  end

  @spec compaction_reservation_snapshot(pid()) ::
          {:ok, %{lifecycle_id: Ecto.UUID.t(), generation: pos_integer(), serving_mode: :full | :lite}}
          | {:error, atom()}
  def compaction_reservation_snapshot(pid) when is_pid(pid),
    do: admission_call(pid, :compaction_reservation_snapshot)

  def compaction_reservation_snapshot(_pid), do: {:error, :invalid_input}

  @spec arm_compact(pid(), Binding.t(), non_neg_integer()) :: :ok | {:error, atom()}
  def arm_compact(_pid, _binding, _expires_at_ms), do: {:error, :invalid_input}

  @spec arm_compact(pid(), Binding.t(), non_neg_integer(), OrdinarySuccessResult.t()) ::
          :ok | {:error, atom()}
  def arm_compact(pid, %Binding{} = binding, expires_at_ms, %OrdinarySuccessResult{} = receipt)
      when is_pid(pid) and is_integer(expires_at_ms) and expires_at_ms >= 0 do
    admission_call(pid, {:arm_compact, binding, expires_at_ms, receipt})
  end

  def arm_compact(_pid, _binding, _expires_at_ms, _receipt), do: {:error, :invalid_input}

  @spec authorize_first_compact_collection(pid(), Binding.t(), FirstCompactResult.t()) ::
          {:ok, FirstCompactCollection.t()} | {:error, atom()}
  def authorize_first_compact_collection(
        pid,
        %Binding{} = binding,
        %FirstCompactResult{} = result
      )
      when is_pid(pid) do
    confirmation_call(pid, {:authorize_first_compact_collection, binding, result})
  end

  def authorize_first_compact_collection(_pid, _binding, _control_ref),
    do: {:error, :invalid_input}

  @spec record_first_compact_collected(pid(), FirstCompactCollection.t()) ::
          :ok | {:error, atom()}
  def record_first_compact_collected(pid, %FirstCompactCollection{} = provenance)
      when is_pid(pid) do
    confirmation_call(pid, {:record_first_compact_collected, provenance})
  end

  def record_first_compact_collected(_pid, _provenance), do: {:error, :invalid_input}

  @spec reserve_compaction(
          pid(),
          :compact | :final,
          Binding.t(),
          reference(),
          non_neg_integer()
        ) :: {:ok, Capability.t()} | {:error, atom()}
  def reserve_compaction(pid, phase, %Binding{} = binding, control_ref, now_ms)
      when is_pid(pid) and phase in [:compact, :final] and is_reference(control_ref) and
             is_integer(now_ms) and now_ms >= 0 do
    admission_call(pid, {:reserve_compaction, phase, binding, control_ref, now_ms})
  end

  def reserve_compaction(_pid, _phase, _binding, _control_ref, _now_ms),
    do: {:error, :invalid_input}

  @spec mark_compaction_accounting_started(pid(), Capability.t(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def mark_compaction_accounting_started(pid, %Capability{} = capability, now_ms)
      when is_pid(pid) and is_integer(now_ms) and now_ms >= 0 do
    admission_call(pid, {:mark_compaction_accounting_started, capability, now_ms})
  end

  def mark_compaction_accounting_started(_pid, _capability, _now_ms),
    do: {:error, :invalid_input}

  @spec cancel_compaction_reservation(pid(), Capability.t(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def cancel_compaction_reservation(pid, %Capability{} = capability, now_ms)
      when is_pid(pid) and is_integer(now_ms) and now_ms >= 0 do
    admission_call(pid, {:cancel_compaction_reservation, capability, now_ms})
  end

  def cancel_compaction_reservation(_pid, _capability, _now_ms),
    do: {:error, :invalid_input}

  @spec acknowledge_compact_finalization(
          pid(),
          {:success, <<_::256>>, Confirmation.t(), non_neg_integer()} | :failure
        ) :: :ok | {:error, atom()}
  def acknowledge_compact_finalization(pid, acknowledgement) when is_pid(pid) do
    confirmation_call(pid, {:acknowledge_compact_finalization, acknowledgement})
  end

  def acknowledge_compact_finalization(_pid, _acknowledgement),
    do: {:error, :invalid_input}

  @spec clear_compaction_admission(pid()) :: :ok | {:error, :unavailable}
  def clear_compaction_admission(pid) when is_pid(pid) do
    admission_call(pid, :clear_compaction_admission)
  end

  def clear_compaction_admission(_pid), do: {:error, :invalid_input}

  @spec clear_compaction_admission(pid(), Capability.t()) :: :ok | {:error, atom()}
  def clear_compaction_admission(pid, %Capability{} = capability) when is_pid(pid),
    do: admission_call(pid, {:clear_compaction_admission, capability})

  def clear_compaction_admission(_pid, _capability), do: {:error, :invalid_input}

  @spec compaction_admission_phase(pid()) ::
          NativeCompactionAdmission.phase() | {:error, :unavailable}
  def compaction_admission_phase(pid) when is_pid(pid) do
    admission_call(pid, :compaction_admission_phase)
  end

  def compaction_admission_phase(_pid), do: {:error, :invalid_input}

  defp admission_call(pid, message) do
    GenServer.call(pid, message, @admission_call_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # The steps that confirm a compaction the provider already served keep a
  # session that did not answer within the call budget (`timeout`: it may
  # still apply the step when it does) apart from one that is gone
  # (`unavailable`), which the runtime tells apart when it decides whether the
  # client still gets that compaction (findings#270 row 270-249).
  defp confirmation_call(pid, message) do
    GenServer.call(pid, message, @admission_call_timeout_ms)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  @spec invalidate_connection(pid()) :: invalidation_result()
  def invalidate_connection(pid) when is_pid(pid) do
    GenServer.call(pid, :invalidate_connection, 1_000)
  catch
    :exit, _reason -> {:error, :upstream_websocket_not_connected}
  end

  @spec request_once(Request.t()) :: request_result()
  def request_once(%Request{} = request) do
    key = request_key(request)
    state = new_connection_lifecycle_state()

    case request_once_on_connection(state, key, request, %{
           reused: false,
           reconnected: false
         }) do
      {:ok, result, state} ->
        close_state(state)
        result

      {:error, reason, state} ->
        error = request_error(reason, state)
        close_state(state)
        error
    end
  end

  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(:new), do: init({:new, nil, :direct})
  def init({:new, subscriber}), do: init({:new, subscriber, :direct})

  def init({:new, subscriber, admission_topology}) do
    sensitivity = NativeCompactionTrace.configure_process_sensitivity(:upstream_session)
    _producer_identity = ExecutionIdentity.producer()

    state =
      new_connection_lifecycle_state()
      |> put_trace_sensitivity(sensitivity)
      |> put_connection_close_subscriber(subscriber)
      |> put_admission_topology(admission_topology)

    {:ok, state}
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, status_reason_class(reason)}
      {:message, message} -> {:message, status_message_class(message)}
      {:state, state} -> {:state, status_state(state)}
      {:log, _log} -> {:log, []}
    end)
  end

  @doc false
  @spec connection_lifecycle_state(map()) :: connection_lifecycle_state()
  def connection_lifecycle_state(state), do: Map.take(state, @connection_lifecycle_keys)

  @spec new_connection_lifecycle_state() :: connection_lifecycle_state()
  defp new_connection_lifecycle_state do
    %{lifecycle_id: Ecto.UUID.generate(), generation: 0}
  end

  @impl GenServer
  def handle_call(:native_compaction_trace_cooperative?, _from, state),
    do: {:reply, true, state}

  if @dev_features_build_enabled do
    def handle_call(
          {:native_compaction_trace_sensitivity, :observe, generation, authorization, restorer},
          _from,
          state
        ) do
      case NativeCompactionTrace.configure_existing_process_sensitivity(
             :upstream_session,
             generation,
             authorization,
             restorer
           ) do
        {:ok, sensitivity} ->
          {:reply, :ok, Map.put(state, :native_compaction_trace_sensitivity, sensitivity)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  else
    def handle_call(
          {:native_compaction_trace_sensitivity, :observe, _generation, _authorization, _restorer},
          _from,
          state
        ),
        do: {:reply, {:error, :full_trace_unavailable}, state}
  end

  def handle_call({:request, %Request{} = request}, {caller_pid, _tag}, state)
      when is_pid(caller_pid) do
    key = request_key(request)
    state = drain_pending_native_steering(state)
    state = Map.delete(state, :native_response_steering_receive)
    caller_monitor = Process.monitor(caller_pid)

    {lane, owner} = request_native_steering(request)

    try do
      case NativeResponseSteering.select_request(lane, request.request_id, request.attempt_id, self(), owner) do
        :ok ->
          {:ok, result, state} = request_on_connection(state, key, request, {caller_pid, caller_monitor})
          {:reply, result, maybe_schedule_keepalive(state)}

        {:error, reason} ->
          {:reply, {:error, %{reason: reason, body: "", headers: [], started: false}}, state}
      end
    after
      Process.demonitor(caller_monitor, [:flush])
    end
  end

  def handle_call(:connection_lifecycle_snapshot, _from, state) do
    {:reply, connection_lifecycle_state(state), state}
  end

  def handle_call(:live_connection, _from, state), do: {:reply, {:ok, live_connection_state(state)}, state}

  def handle_call(:producer_identity, _from, state), do: {:reply, ExecutionIdentity.producer(), state}

  # An armed compaction has no bound, and a final or a collection past its
  # own has ended (findings#270 rows 270-317 and 270-289). A snapshot of one
  # that ended answers `expired`, the reason it did: read through
  # `admission_state/1` it was an empty admission, and the reservation it
  # refused was logged `cause=owner_unavailable` like every other refusal
  # (row 270-334).
  def handle_call(:compaction_reservation_snapshot, _from, state) do
    stored = Map.get(state, :native_compaction_admission, %NativeCompactionAdmission{phase: :cleared})

    result =
      case NativeCompactionAdmission.expire_unconsumed(stored, System.system_time(:millisecond)) do
        {:expired, _cleared} -> {:error, :expired}
        {:active, admission} -> reservation_snapshot(state, admission)
      end

    {:reply, result, state}
  end

  def handle_call(
        {:arm_compact, %Binding{} = binding, expires_at_ms, %OrdinarySuccessResult{} = receipt},
        _from,
        state
      ) do
    result =
      with :ok <- validate_direct_binding(state, binding),
           true <- Map.get(state, :ordinary_success_result) == receipt and receipt.owner == self(),
           true <- OrdinarySuccessResult.binding_matches?(receipt, binding),
           true <-
             admission_state(state).phase in [
               :cleared,
               :ordinary_success,
               :pending_compact,
               :consumed_final
             ],
           {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
           do: NativeCompactionAdmission.arm_compact(admission, expires_at_ms)

    case result do
      {:ok, admission} ->
        {:reply, :ok,
         state
         |> Map.delete(:ordinary_success_result)
         |> Map.delete(:first_compact_result)
         |> put_admission(admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      false ->
        {:reply, {:error, :invalid_transition}, state}
    end
  end

  def handle_call({:arm_compact, _binding, _expires}, _from, state),
    do: {:reply, {:error, :invalid_input}, state}

  def handle_call(
        {:authorize_first_compact_collection, %Binding{} = binding, %FirstCompactResult{} = receipt},
        _from,
        state
      ) do
    result =
      with :ok <- validate_direct_binding(state, binding),
           true <- Map.get(state, :first_compact_result) == receipt and receipt.owner == self(),
           true <- FirstCompactResult.binding_matches?(receipt, binding),
           true <- admission_state(state).phase in [:cleared, :ordinary_success, :pending_compact],
           {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
           do:
             NativeCompactionAdmission.authorize_first_compact_collection(
               admission,
               receipt.result_ref
             )

    case result do
      {:ok, admission, provenance} ->
        admission = %{admission | compaction_item_digest: receipt.item_digest}

        {:reply, {:ok, provenance}, state |> Map.delete(:first_compact_result) |> put_admission(admission)}

      {:error, reason} ->
        authorize_closed_connection_first_compact(state, binding, receipt, {:error, reason})

      false ->
        authorize_closed_connection_first_compact(state, binding, receipt, {:error, :invalid_transition})
    end
  end

  def handle_call({:record_first_compact_collected, provenance}, _from, %{closed_connection_collection: %NativeCompactionAdmission{phase: :ordinary_success, first_compact_collection: %FirstCompactCollection{}}} = state)
      when not is_map_key(state, :native_compaction_admission) do
    record_closed_connection_first_collection(state, provenance)
  end

  def handle_call({:record_first_compact_collected, provenance}, _from, state) do
    admission = admission_state(state)

    case NativeCompactionAdmission.record_first_compact_collected(admission, provenance, System.system_time(:millisecond)) do
      {:ok, admission} ->
        {:reply, :ok, put_admission(state, admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason, admission} ->
        {:reply, {:error, reason},
         if(admission_state(state).first_compact_collection == provenance,
           do: put_admission(state, admission),
           else: state
         )}
    end
  end

  def handle_call({:reserve_compaction, phase, binding, control_ref, now_ms}, _from, state) do
    with :ok <- validate_direct_binding(state, binding),
         {:ok, admission, capability} <-
           NativeCompactionAdmission.reserve(
             admission_state(state),
             phase,
             binding,
             control_ref,
             now_ms
           ) do
      :ok = emit_reservation_observations(capability)
      {:reply, {:ok, capability}, put_admission(state, admission)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mark_compaction_accounting_started, capability, now_ms}, _from, state) do
    case NativeCompactionAdmission.mark_accounting_started(
           admission_state(state),
           capability,
           now_ms
         ) do
      {:ok, admission} ->
        :ok =
          NativeCompactionAuthorizationObservation.emit_capability(
            capability,
            :accounting_started
          )

        _trace =
          NativeCompactionTrace.emit_capability(:accounting_started, capability, %{
            pid_role: :upstream_session,
            upstream_pid: self()
          })

        {:reply, :ok, put_admission(state, admission)}

      {:error, reason} ->
        if closed_under_capability?(state, capability) do
          {:reply, {:error, :connection_closed}, state}
        else
          :ok =
            NativeCompactionAuthorizationObservation.log_accounting_rejection(
              admission_state(state),
              capability,
              :direct,
              reason
            )

          {:reply, {:error, reason}, clear_rejected_capability(state, capability, reason)}
        end
    end
  end

  def handle_call({:cancel_compaction_reservation, capability, now_ms}, _from, state) do
    case NativeCompactionAdmission.cancel(
           admission_state(state),
           capability,
           :pre_accounting,
           now_ms
         ) do
      {:ok, admission} ->
        {:reply, :ok, put_admission(state, admission)}

      {:error, :committed, admission} ->
        {:reply, {:error, :committed}, put_admission(state, admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, clear_rejected_capability(state, capability, reason)}
    end
  end

  def handle_call({:acknowledge_compact_finalization, :failure}, _from, state),
    do: {:reply, :ok, clear_admission(state, :compact_failure)}

  def handle_call(
        {:acknowledge_compact_finalization, {:success, digest, %Confirmation{} = confirmation, expires_at_ms}},
        _from,
        state
      ) do
    compact_capability = admission_state(state).capability

    case NativeCompactionAdmission.confirm_compact(
           admission_state(state),
           digest,
           confirmation,
           expires_at_ms
         ) do
      {:ok, admission} ->
        :ok = emit_compact_acknowledged(compact_capability)

        {:reply, :ok, put_admission(state, admission)}

      {:error, reason} ->
        confirm_closed_connection_collection(state, reason, digest, confirmation, expires_at_ms)

      {:error, reason, admission} ->
        {:reply, {:error, reason},
         if(admission_state(state).binding == confirmation.binding,
           do: put_admission(state, admission),
           else: state
         )}
    end
  end

  def handle_call({:acknowledge_compact_finalization, _invalid}, _from, state),
    do: {:reply, {:error, :invalid_input}, clear_admission(state, :invalid_input)}

  # The explicit clear control: the runtime rejected the request the
  # admission was reserved for (`Service.clear_native_compaction_admission`).
  def handle_call(:clear_compaction_admission, _from, state),
    do: {:reply, :ok, clear_admission(state, :request_rejected)}

  def handle_call({:clear_compaction_admission, %Capability{} = capability}, _from, state) do
    case NativeCompactionAdmission.clear_owned(admission_state(state), capability) do
      {:ok, _cleared} ->
        {:reply, :ok, clear_admission(state, :request_rejected)}

      {:error, reason} ->
        if closed_under_capability?(state, capability) do
          {:reply, :ok, state}
        else
          observe_admission(state, state, :reject, :stale_capability)
          {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:compaction_admission_phase, _from, state),
    do: {:reply, NativeCompactionAdmission.phase(admission_state(state)), state}

  def handle_call({:send_text, payload}, _from, %{conn: _conn} = state) do
    case send_text(state, payload) do
      {:ok, state} ->
        {:reply, {:ok, :sent}, maybe_schedule_keepalive(state)}

      {:error, reason, state} ->
        {:reply, {:error, reason}, close_between_requests(state, :send_failed, transport_reason: reason)}
    end
  end

  def handle_call({:send_text, _payload}, _from, state),
    do: {:reply, {:error, :upstream_websocket_not_connected}, state}

  def handle_call(:invalidate_connection, _from, %{conn: _conn} = state) do
    :ok = CloseDiagnostics.log_close(state, :invalidated)
    {:reply, :ok, close_and_signal(state, :invalidated, &invalidate_state/1)}
  end

  def handle_call(:invalidate_connection, _from, state),
    do: {:reply, {:error, :upstream_websocket_not_connected}, state}

  @impl GenServer
  def handle_info(
        {:upstream_websocket_keepalive, token},
        %{keepalive_token: token, keepalive_pong_token: _pong_token} = state
      ) do
    {:noreply, schedule_keepalive(state)}
  end

  def handle_info({:upstream_websocket_keepalive, token}, %{keepalive_token: token} = state) do
    payload = unique_keepalive_payload()

    state =
      case send_frame(state, {:ping, payload}) do
        {:ok, state} ->
          state
          |> mark_ping_sent()
          |> schedule_pong_deadline(payload)
          |> schedule_keepalive()

        {:error, reason, state} ->
          close_between_requests(state, :ping_send_failed, transport_reason: reason)
      end

    {:noreply, state}
  end

  def handle_info({:upstream_websocket_keepalive, _token}, state), do: {:noreply, state}

  def handle_info(
        {:upstream_websocket_pong_deadline, token},
        %{keepalive_pong_token: token} = state
      ) do
    {:noreply, close_between_requests(state, :pong_deadline)}
  end

  def handle_info({:upstream_websocket_pong_deadline, _token}, state), do: {:noreply, state}

  def handle_info(
        {:native_compaction_trace_sensitivity, :restore, generation, authorization, restorer},
        state
      ) do
    sensitivity = Map.get(state, :native_compaction_trace_sensitivity, :sensitive)

    if NativeCompactionTrace.authorized_restore?(
         sensitivity,
         generation,
         authorization,
         restorer
       ) do
      :ok = NativeCompactionTrace.restore_process_sensitivity(sensitivity)
      {:noreply, Map.put(state, :native_compaction_trace_sensitivity, :sensitive)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, restorer, _reason}, state) do
    sensitivity = Map.get(state, :native_compaction_trace_sensitivity, :sensitive)

    case NativeCompactionTrace.restore_on_restorer_down(sensitivity, monitor, restorer) do
      :restored ->
        {:noreply, Map.put(state, :native_compaction_trace_sensitivity, :sensitive)}

      :unchanged ->
        {:noreply, state}
    end
  end

  def handle_info({:upstream_websocket_steer, steer}, %{conn: _conn, native_response_steering_receive: receive_state} = state) do
    case write_steer(state, receive_state, steer) do
      {:ok, state, receive_state} -> {:noreply, Map.put(state, :native_response_steering_receive, receive_state)}
      {:error, state} -> {:noreply, close_state(state)}
    end
  end

  def handle_info({:upstream_websocket_steer, _steer}, state) do
    :ok = ResponseSteer.log(:session_idle, interrupt_topology(state))
    {:noreply, state}
  end

  def handle_info({:upstream_websocket_steering_frames, frames}, state), do: {:noreply, handle_async_frames(state, frames, :idle)}

  def handle_info({:upstream_websocket_cancel_steering, lane, {request_id, attempt_id}, _reason}, %{native_response_steering_receive: %ReceiveState{native_response_steering: lane, request_id: request_id, attempt_id: attempt_id} = receive_state} = state) do
    if receive_state.steering_requested? or receive_state.steering_successor?,
      do: {:noreply, close_state(state)},
      else: {:noreply, Map.delete(state, :native_response_steering_receive)}
  end

  def handle_info({:upstream_websocket_cancel_steering, _lane, _identity, _reason}, state), do: {:noreply, state}

  def handle_info({:upstream_websocket_release_steering, lane, {request_id, attempt_id}}, %{native_response_steering_receive: %ReceiveState{native_response_steering: lane, request_id: request_id, attempt_id: attempt_id, steering_requested?: false, steering_successor?: false}} = state) do
    state = Map.delete(state, :native_response_steering_receive)

    state =
      case Map.get(state, :native_response_steering_current_request) do
        %Request{request_id: ^request_id, attempt_id: ^attempt_id} = request ->
          if request_native_steering_lane(request) == lane, do: Map.delete(state, :native_response_steering_current_request), else: state

        _other_request ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:upstream_websocket_release_steering, _lane, _identity}, state), do: {:noreply, state}

  # An interrupt that reaches a session with no turn in flight names a response
  # that already ended, or one that never ran here.
  def handle_info({:upstream_websocket_interrupt, _interrupt}, state) do
    :ok = ResponseInterrupt.log(:session_idle, interrupt_topology(state))
    {:noreply, state}
  end

  # A completed/cancelled request never acknowledges a queued wait challenge.
  def handle_info({:compaction_pending_probe, _receiver, _challenge, _token, _request_id, _attempt_id, _sequence}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        {:noreply, handle_async_parts(state, responses)}

      {:error, conn, reason, _responses} ->
        state = %{state | conn: conn}
        {:noreply, close_between_requests(state, idle_transport_cause(reason), transport_reason: reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    close_state(state)
    :ok
  end

  defp ensure_connection(
         %{key: key, conn: _conn} = state,
         key,
         _url,
         _headers,
         _timeouts,
         _request_caller
       ),
       do: {:ok, state}

  defp ensure_connection(state, key, url, headers, timeouts, request_caller) do
    state = close_replaced_connection(state, key)

    ConnectionUpgrade.connect_state(state, key, url, headers, timeouts, request_caller)
  end

  # Like the Codex client, a connection keeps the routing hint of the handshake
  # that opened it: a later turn's tier or model hint never forces a reconnect.
  # Every other header still scopes the connection, including the provider
  # session headers (`session-id`, `thread-id`, `x-client-request-id`): a
  # reusable owner can serve several downstream sockets and API keys of one
  # Pool, so a turn whose values differ or are absent opens its own connection
  # instead of riding one whose handshake carried another client's session.
  defp request_key(%Request{} = request),
    do: {request.url, Enum.reject(request.headers, &routing_hint_header?/1)}

  defp routing_hint_header?({name, _value}) when is_binary(name),
    do: String.downcase(name) == "x-codex-routing-hint"

  defp routing_hint_header?(_header), do: false

  defp drain_pending_native_steering(%{conn: conn, native_response_steering_receive: %ReceiveState{steering_requested?: true}} = state) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      {:upstream_websocket_steering_frames, frames} ->
        state |> handle_async_frames(frames, :idle) |> drain_pending_native_steering()

      {tag, ^socket, _data_or_reason} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
        {:noreply, state} = handle_info(message, state)
        drain_pending_native_steering(state)

      {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
        {:noreply, state} = handle_info(message, state)
        drain_pending_native_steering(state)
    after
      0 -> state
    end
  end

  defp drain_pending_native_steering(state), do: state

  defp request_on_connection(state, key, %Request{} = request, request_caller) do
    reused_connection? = reusable_connection?(state, key)
    reconnect_pending? = Map.get(state, :reconnect_pending?, false)
    connection_usage = %{reused: reused_connection?, reconnected: reconnect_pending?}

    case request_once_on_connection(state, key, request, connection_usage, request_caller) do
      {:ok, result, state} ->
        {:ok, result, state}

      {:error, reason, state} ->
        result = request_error(reason, state)
        state = close_state(state)
        {:ok, result, state}
    end
  end

  defp collect_compaction?(%Request{websocket_delivery_mode: mode})
       when mode in [:collect_compaction, :collect_full_history],
       do: true

  defp collect_compaction?(%Request{}), do: false

  # Only a collecting turn pays for the larger accumulator; a relayed turn keeps
  # the bounded diagnostic retention alone.
  defp new_collected_body(%Request{} = request) do
    if collect_compaction?(request), do: CollectedBody.empty(), else: CollectedBody.disabled()
  end

  # The mapper names the authenticated native origin. A TurnSnapshot carries
  # an optional model ETag and is intentionally absent on compact requests.
  defp compaction_pending_observer(%Request{websocket_delivery_mode: mode, request_id: request_id, attempt_id: attempt_id} = request)
       when mode in [:collect_compaction, :collect_full_history] do
    observer = Map.get(request, :compaction_pending_observer)

    if is_function(observer, 1) and request.message_mapper == (&StreamProtocol.canonicalize_native_codex_responses_json_message/1) and
         match?({:ok, _}, Ecto.UUID.cast(request_id)) and match?({:ok, _}, Ecto.UUID.cast(attempt_id)),
       do: observer
  end

  defp compaction_pending_observer(%Request{}), do: nil

  defp reusable_connection?(%{key: key, conn: _conn}, key), do: true
  defp reusable_connection?(_state, _key), do: false

  defp request_once_on_connection(
         state,
         key,
         %Request{} = request,
         connection_usage,
         request_caller \\ nil
       ) do
    {request_caller_pid, request_caller_monitor} = request_caller || {nil, nil}

    receive_state = %ReceiveState{
      writer: request.writer,
      compaction_pending_observer: compaction_pending_observer(request),
      timeouts: request.timeouts,
      message_mapper: request.message_mapper,
      public_tool_completion: new_public_tool_completion(request),
      frame_observer: request.frame_observer,
      native_codex_response_control: Map.get(request, :native_codex_response_control),
      delivery: %Delivery{
        mode: request.websocket_delivery_mode,
        effective_serving_mode: request.effective_serving_mode
      },
      collected_body: new_collected_body(request),
      request_caller_pid: request_caller_pid,
      request_caller_monitor: request_caller_monitor,
      request_id: request.request_id,
      attempt_id: request.attempt_id,
      native_client_retry_observation: request.native_client_retry_observation,
      native_response_steering: request_native_steering_lane(request),
      # Tolerant access: during a rolling deploy an owner-forwarded request may
      # have been built by a replica that predates this field. nil keeps the
      # pre-provenance classification semantics for that request instead of
      # crashing the session.
      assignment_advertised?: Map.get(request, :assignment_advertised?)
    }

    WebsocketRequestCallbacks.begin_request(
      request.request_id,
      request.attempt_id
    )

    try do
      connect_and_send_request(
        state,
        key,
        request.url,
        request.headers,
        request.timeouts,
        request,
        receive_state,
        connection_usage
      )
    after
      WebsocketRequestCallbacks.end_request()
    end
  end

  defp connect_and_send_request(
         state,
         key,
         url,
         headers,
         timeouts,
         request,
         receive_state,
         connection_usage
       ) do
    if (public_openai_responses_mapper?(request.message_mapper) and Map.get(request, :connection_bound_continuation?, false) and not reusable_connection?(state, key)) or
         (collect_compaction?(request) and
            not collect_connection_eligible?(state, key, request, connection_usage)) do
      reason = if connection_use(connection_usage) == :reused and Map.get(state, :last_successful_effective_serving_mode) != request.effective_serving_mode, do: :previous_response_serving_mode_mismatch, else: :previous_response_generation_mismatch
      guard_connection_bound_continuation(state, receive_state, connection_usage, reason)
    else
      connect_and_send_eligible_request(
        state,
        key,
        url,
        headers,
        timeouts,
        request,
        receive_state,
        connection_usage
      )
    end
  end

  defp connect_and_send_eligible_request(
         state,
         key,
         url,
         headers,
         timeouts,
         request,
         receive_state,
         connection_usage
       ) do
    case ensure_connection(state, key, url, headers, timeouts, request_caller(receive_state)) do
      {:ok, state} ->
        {lane, owner} = request_native_steering(request)
        state = Map.put(state, :native_response_steering_owner, owner)
        state = if is_pid(lane), do: Map.put(state, :native_response_steering_current_request, %{request | headers: [], writer: nil, frame_observer: nil, payload: native_steering_model_payload(request.payload)}), else: Map.delete(state, :native_response_steering_current_request)
        {upgrade_frames, state} = Map.pop(state, :upgrade_frames, [])

        case settle_upgrade_frames(state, receive_state, upgrade_frames, connection_usage) do
          {:ok, state, receive_state} ->
            send_on_connection(state, request, receive_state, connection_usage)

          {:failed, result, state} ->
            {:ok, put_result_connection_metadata(result, state, connection_usage), state}
        end

      {:error, :client_disconnected, state} ->
        result = request_caller_down_result(state, receive_state)
        state = invalidate_cancelled_request(state, receive_state, :connect)
        {:ok, put_result_connection_metadata(result, state, connection_usage), state}

      {:error, reason, state} ->
        state =
          state
          |> Map.put(:transport_failure_phase, :connect)
          |> Map.put(:transport_failure_source, :connection_establish_error)

        {:error, reason, state}
    end
  end

  defp send_on_connection(state, request, receive_state, connection_usage) do
    connection_use = connection_use(connection_usage)

    cond do
      not Map.get(request, :connection_bound_continuation?, false) ->
        send_request_payload(state, request, receive_state, connection_usage)

      connection_use != :reused ->
        guard_connection_bound_continuation(state, receive_state, connection_usage)

      lite_anchor_on_full_context?(state, request) ->
        guard_connection_bound_continuation(state, receive_state, connection_usage, :previous_response_serving_mode_mismatch)

      true ->
        send_request_payload(state, request, receive_state, connection_usage)
    end
  end

  # Frames that arrived in the same read as the `101` come out of the upgrade already decoded and in order
  # (`ConnectionUpgrade`), by the websocket that holds that read's decoder state. The peer wrote them before this
  # request existed, so what ends the connection ends the request before its payload is written, through the
  # `handle_frame/2` clauses a frame read during the request takes: a Close fails it with the peer's own code and
  # reason size, a frame the decoder rejected or a binary frame fails it as it would later, and a Ping gets its Pong.
  # The failure says the payload never left (`upstream_committed` false) and keeps the phase of the same failure read
  # later, never `connect`: that phase takes the same-assignment retry and the `/v1` bridge's HTTP fallback. Text
  # frames wait in the receive state and fold through `handle_frames/3` ahead of the first read
  # (`await_sent_request/2`), the path they take when they arrive in a read of their own; nothing is relayed before
  # the payload is written. One bounded info line records what the upgrade carried (findings#304).
  defp settle_upgrade_frames(state, %ReceiveState{} = receive_state, [], _connection_usage), do: {:ok, state, receive_state}

  defp settle_upgrade_frames(state, %ReceiveState{} = receive_state, frames, connection_usage) do
    receive_state = %{receive_state | connection_use: connection_use(connection_usage)}
    outcome = Enum.reduce_while(frames, {:continue, state, receive_state, []}, &settle_upgrade_frame/2)
    :ok = Logger.info(upgrade_frames_line(state, frames))

    case outcome do
      {:continue, state, receive_state, text_frames} ->
        {:ok, state, %{receive_state | upgrade_frames: Enum.reverse(text_frames)}}

      {:failure, _state, _receive_state, _reason} = halted ->
        {{:error, failure}, state} = finish_receive_result(halted)
        {:failed, {:error, put_in(failure, [:transport_failure, "upstream_committed"], false)}, state}
    end
  end

  defp settle_upgrade_frame({:text, _text} = frame, {:continue, state, receive_state, text_frames}),
    do: {:cont, {:continue, state, receive_state, [frame | text_frames]}}

  defp settle_upgrade_frame(frame, {:continue, state, receive_state, text_frames}) do
    case handle_frame(frame, {:continue, state, receive_state}) do
      {:cont, {:continue, state, receive_state}} -> {:cont, {:continue, state, receive_state, text_frames}}
      {:halt, halted} -> {:halt, halted}
    end
  end

  # Counts by frame kind and the first Close's code only, never a payload, a close reason or a Ping's bytes.
  defp upgrade_frames_line(state, frames) do
    counts = Enum.frequencies_by(frames, &elem(&1, 0))

    close_code =
      Enum.find_value(frames, "none", fn
        {:close, code, _reason} -> coalesced_close_code(code)
        _frame -> nil
      end)

    lifecycle = connection_lifecycle_state(state)

    "upstream websocket upgrade frames handled frames=#{length(frames)} " <>
      Enum.map_join(~w(ping pong text binary close error)a, " ", &"#{&1}=#{Map.get(counts, &1, 0)}") <>
      " close_code=#{close_code} lifecycle_id=#{lifecycle.lifecycle_id} generation=#{lifecycle.generation}"
  end

  defp collect_connection_eligible?(
         _state,
         _key,
         %Request{websocket_delivery_mode: :collect_full_history} = request,
         _connection_usage
       ) do
    request.effective_serving_mode in ["full", "lite"] and
      not request.connection_bound_continuation? and
      WebsocketOwnerRequestV6.unanchored_full_history_payload?(request.payload)
  end

  defp collect_connection_eligible?(state, key, request, connection_usage) do
    connection_use(connection_usage) == :reused and reusable_connection?(state, key) and
      Map.get(state, :last_successful_effective_serving_mode) == request.effective_serving_mode and
      request.effective_serving_mode in ["full", "lite"]
  end

  defp request_caller(%ReceiveState{
         request_caller_pid: request_caller_pid,
         request_caller_monitor: request_caller_monitor
       })
       when is_pid(request_caller_pid) and is_reference(request_caller_monitor),
       do: {request_caller_pid, request_caller_monitor}

  defp request_caller(%ReceiveState{}), do: nil

  # A connection-bound anchor is refused before anything is sent when the
  # context it continues cannot be the one the request expects: the connection
  # is not the one that produced the anchor, or the anchor is Lite and the
  # provider context was built under Full. Lite sends its tool manifest and
  # instructions message only on a request that opens a context (findings#232
  # row 232-184), so an anchored Lite delta on a context opened under Full would
  # reach the provider with no tools and no base instructions (row 232-210).
  # The client answers `previous_response_not_found` with a full request
  # without the anchor, which opens a Lite context with the prefix.
  #
  # A public `/v1` bridged anchor has no client that retries
  # `previous_response_not_found`; it gets the refusal the provider sends for
  # the same request on a connection that did not produce the anchor (a
  # codeless 400 `invalid_request_error`, findings#232 row 232-277, live probe
  # 2026-09-23), which the bridge answers like the provider's own refusal.
  defp guard_connection_bound_continuation(state, receive_state, connection_usage, reason \\ :previous_response_generation_mismatch) do
    {terminal, decoded, mapped, mapped_decoded} = connection_bound_miss_frame(receive_state.message_mapper)

    {:halt, {:terminal, state, receive_state, "error"}} =
      handle_text_frame(state, receive_state, terminal, decoded, mapped, mapped_decoded)

    # The guard's own refusal: the provider never received the request, so the
    # connection stays usable and is not retired like after a provider refusal.
    receive_state = %{receive_state | provider_refusal?: false}

    {{:ok, result}, state} =
      finish_receive_result({:terminal, state, receive_state, "error"})

    result =
      result
      |> Map.put(:upstream_error_param, "previous_response_id")
      |> Map.put(
        :transport_failure,
        TransportFailureReason.transport_failure_metadata(
          reason,
          %{connection_use: connection_use(connection_usage)}
        )
      )

    {:ok, put_result_connection_metadata({:ok, result}, state, connection_usage), state}
  end

  defp connection_bound_miss_frame(mapper) do
    if public_openai_responses_mapper?(mapper) do
      terminal =
        CodexPooler.JSON.encode!(%{
          "type" => "error",
          "status" => 400,
          "error" => %{"type" => "invalid_request_error", "message" => ErrorCodes.invalid_previous_response_id_message()}
        })

      decoded = decode_text_frame(terminal)
      {mapped, mapped_decoded} = map_message(terminal, decoded, mapper)
      {terminal, decoded, mapped, mapped_decoded}
    else
      terminal =
        StreamProtocol.canonicalize_native_codex_responses_json_message(~s({"type":"error","error":{"code":"previous_response_not_found"}}))

      decoded = decode_text_frame(terminal)
      {terminal, decoded, terminal, decoded}
    end
  end

  defp public_openai_responses_mapper?(mapper),
    do: mapper == (&StreamProtocol.normalize_public_openai_responses_json_message/1)

  # Only a Lite anchor on a context opened under Full lacks anything: the Full
  # context holds no tool manifest and no instructions message, and the Lite
  # anchored request carries neither. The reverse flip is sent: a Full anchored
  # request carries its tools and instructions at top level, so the provider
  # gets them whatever the context holds, and a replay kept in the mode it
  # started with may legitimately be followed by a Full turn on its connection.
  # The mode is known only for a context whose last response on this connection
  # completed (`maybe_record_successful_serving_mode/3`); without one the plain
  # reuse rule applies.
  #
  # A public `/v1` bridged anchor is bound to its connection too (findings#232
  # row 232-277) but is never refused for the mode: it carries the declared
  # Lite prefix, which gives the Full context what it lacks
  # (`PayloadNormalizer.responses_lite_prefix/6`, row 232-270), while an anchor
  # off its connection has no such remedy.
  defp lite_anchor_on_full_context?(state, %Request{effective_serving_mode: "lite", message_mapper: mapper}),
    do: not public_openai_responses_mapper?(mapper) and Map.get(state, :last_successful_effective_serving_mode) == "full"

  defp lite_anchor_on_full_context?(_state, %Request{}), do: false

  defp send_request_payload(state, %Request{} = request, receive_state, connection_usage) do
    state = state |> Map.delete(:first_compact_result) |> Map.delete(:ordinary_success_result)

    if request_caller_down?(receive_state) do
      result = request_caller_down_result(state, receive_state)
      state = state |> invalidate_cancelled_request(receive_state, :before_payload) |> complete_connection_request()
      {:ok, put_result_connection_metadata(result, state, connection_usage), state}
    else
      send_authorized_request_payload(state, request, receive_state, connection_usage)
    end
  end

  defp send_authorized_request_payload(state, request, receive_state, connection_usage) do
    with {:ok, receipt} <- ProviderCreditsAdmission.admit(request.provider_credits_context),
         :ok <- require_live_request_caller(receive_state),
         {:ok, request} <- authorize_forwarded_generation(request, receipt),
         :ok <- require_live_request_caller(receive_state),
         :ok <- observe_payload_write(request),
         {state, receive_state} <- begin_connection_request(state, receive_state, connection_usage),
         {:ok, state, consumed_phase} <- consume_request_capability(state, request),
         :ok <- require_live_request_caller(receive_state),
         :ok <- trace_physical_send(:physical_send_started, request, :started),
         {:ok, state} <- send_text(state, request.payload),
         :ok <- trace_physical_send(:physical_send_finished, request, :ok) do
      receive_state = %{receive_state | provider_credits_admission: receipt}
      {:ok, result, state} = await_sent_request(state, receive_state)
      {result, state} = retain_first_compact_result(result, state, request)
      {result, state} = retain_ordinary_success_result(result, state, request)

      state =
        state
        |> finalize_consumed_request(result, consumed_phase, request)
        |> maybe_record_successful_serving_mode(result, receive_state)
        |> complete_connection_request()

      result = put_admission_receipt(result, receipt)
      {:ok, put_result_connection_metadata(result, state, connection_usage), state}
    else
      {:error, :client_disconnected} ->
        result = request_caller_down_result(state, receive_state)
        state = state |> invalidate_cancelled_request(receive_state, :before_payload) |> complete_connection_request()
        {:ok, put_result_connection_metadata(result, state, connection_usage), state}

      {:error, %{reason: :provider_credits_policy_denied} = denial} ->
        {:ok, {:error, Map.merge(denial, %{body: "", headers: []})}, state}

      {:error, reason} when reason in [:owner_unavailable, :payload_write_refused] ->
        {:ok, {:error, %{reason: :owner_unavailable, body: "", headers: [], started: false}}, state}

      {:error, state} ->
        :ok =
          trace_physical_send(:physical_send_finished, request, {:error, :capability_rejected})

        {:error, :native_compaction_capability_rejected, state}

      {:error, reason, state} ->
        :ok = trace_physical_send(:physical_send_finished, request, {:error, reason})

        state =
          state
          |> clear_admission(:send_failure)
          |> Map.put(:transport_failure_phase, :send_payload)
          |> Map.put(:transport_failure_source, :payload_send_error)

        {:error, reason, state}
    end
  end

  defp require_live_request_caller(receive_state),
    do: if(request_caller_down?(receive_state), do: {:error, :client_disconnected}, else: :ok)

  # The forwarder that submitted the request through an owner learns here,
  # before the payload can leave, that it is about to (findings#327): an owner
  # that dies from now on may have handed the turn to the provider, so the
  # forwarder settles it instead of submitting it to a replacement owner. A
  # refusal means the forwarder already took the turn back from a dead owner,
  # so this request ends unsent, with one line (findings#329 row J). A failing
  # observer is logged and the write goes ahead, as a failing frame observer
  # is.
  defp observe_payload_write(%Request{payload_write_observer: observer} = request) when is_function(observer, 0) do
    case run_payload_write_observer(observer) do
      :ok ->
        :ok

      :refused ->
        Logger.info(
          "upstream websocket payload write refused reason_code=turn_claimed " <>
            "request_id=#{DiagnosticTaxonomy.safe_correlator(request.request_id)} " <>
            "attempt_id=#{DiagnosticTaxonomy.safe_correlator(request.attempt_id)}"
        )

        {:error, :payload_write_refused}
    end
  end

  defp observe_payload_write(%Request{}), do: :ok

  defp run_payload_write_observer(observer) do
    case observer.() do
      :ok -> :ok
      _refused -> :refused
    end
  rescue
    exception -> report_payload_write_observer_failure(:error, exception.__struct__)
  catch
    kind, _reason when kind in [:throw, :exit] -> report_payload_write_observer_failure(kind, nil)
  end

  defp report_payload_write_observer_failure(failure_kind, exception_class) do
    Logger.warning(
      "upstream websocket payload write observer failed operation=observe_payload_write " <>
        "failure_kind=#{failure_kind} exception_class=#{exception_class || "none"}"
    )
  end

  defp authorize_forwarded_generation(%Request{forwarded_owner: owner} = request, receipt) when is_pid(owner),
    do: WebsocketOwnerSession.authorize_generation_send(owner, request, receipt)

  defp authorize_forwarded_generation(%Request{} = request, _receipt), do: {:ok, request}

  defp put_admission_receipt({tag, result}, receipt) when tag in [:ok, :error] and is_map(result),
    do: {tag, Map.put(result, :provider_credits_admission, receipt)}

  defp retain_first_compact_result({:ok, result} = response, state, request) do
    case FirstCompactResult.from_collection(request, result, connection_lifecycle_state(state)) do
      {:ok, receipt} ->
        {{:ok, Map.put(result, :first_compact_result, receipt)}, Map.put(state, :first_compact_result, receipt)}

      :error ->
        {response, state}
    end
  end

  defp retain_first_compact_result(response, state, _request), do: {response, state}

  defp retain_ordinary_success_result({:ok, %{native_response_steering_finalized: _finalized}} = result, state, _request), do: {result, state}
  defp retain_ordinary_success_result({:ok, %{native_response_steering_terminal_failure: _reason}} = result, state, _request), do: {result, state}

  defp retain_ordinary_success_result(result, state, request) do
    case OrdinarySuccessResult.from_response(request, result, connection_lifecycle_state(state)) do
      {:ok, receipt} ->
        {:ok, response} = result

        {{:ok, Map.put(response, :ordinary_success_result, receipt)}, Map.put(state, :ordinary_success_result, receipt)}

      :error ->
        {result, state}
    end
  end

  defp emit_compact_acknowledged(%Capability{} = capability) do
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :acknowledged)

    _trace =
      NativeCompactionTrace.emit_capability(:capability_acknowledged, capability, %{
        pid_role: :upstream_session,
        upstream_pid: self()
      })

    :ok
  end

  defp emit_compact_acknowledged(nil),
    do: NativeCompactionAuthorizationObservation.emit(:compact_acknowledged, :direct)

  @type consumed_admission_phase :: :compact | :final | :native_replay | nil

  @spec consume_request_capability(map(), Request.t()) ::
          {:ok, map(), consumed_admission_phase()} | {:error, map()}
  defp consume_request_capability(
         state,
         %Request{
           native_replay_binding: %NativeReplayAdmission.Binding{} = binding,
           native_replay_proof: %RuntimeAdmissionProof{} = proof,
           native_compaction_capability: nil,
           forwarded_owner_send_handoff: nil
         }
       ) do
    case NativeReplayAdmission.redeem(proof, binding) do
      {:ok, _redeemed} -> {:ok, state, :native_replay}
      {:error, reason} -> {:error, clear_admission(state, reason)}
    end
  end

  defp consume_request_capability(
         state,
         %Request{
           native_compaction_capability: %Capability{} = capability,
           expected_connection_lifecycle: expected_lifecycle,
           forwarded_owner_send_handoff: nil
         }
       ) do
    now_ms = System.system_time(:millisecond)

    with true <- expected_lifecycle == connection_lifecycle_state(state),
         {:ok, admission} <-
           NativeCompactionAdmission.consume(admission_state(state), capability, now_ms) do
      :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :consumed)

      :ok =
        trace_capability(:capability_consumed, capability, %{
          pid_role: :upstream_session,
          upstream_pid: self()
        })

      {:ok, put_admission(state, admission), capability.phase}
    else
      _rejected -> {:error, clear_admission(state, :stale_capability)}
    end
  end

  defp consume_request_capability(
         state,
         %Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: %ForwardedOwnerRequestHandoff{} = handoff,
           effective_serving_mode: effective_serving_mode
         }
       ) do
    with {:ok, serving_mode} <- normalized_forwarded_serving_mode(effective_serving_mode),
         :ok <-
           ForwardedOwnerRequestHandoff.redeem(
             handoff,
             connection_lifecycle_state(state),
             serving_mode
           ) do
      {:ok, state, nil}
    else
      _rejected -> {:error, clear_admission(state, :stale_capability)}
    end
  end

  defp consume_request_capability(
         state,
         %Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: nil
         }
       ),
       do: {:ok, state, nil}

  defp consume_request_capability(state, %Request{}),
    do: {:error, clear_admission(state, :invalid_input)}

  defp normalized_forwarded_serving_mode("full"), do: {:ok, :full}
  defp normalized_forwarded_serving_mode("lite"), do: {:ok, :lite}
  defp normalized_forwarded_serving_mode(_mode), do: {:error, :invalid_serving_mode}

  # A consumed compaction is collected only when the provider completed it. A
  # provider failure (`response.failed`, an error frame) ends the request with a
  # terminal result as well, and counting it as collected left the admission
  # `collected_unconfirmed`: the released client's full-history retry of the
  # failed compaction was then served and billed, and refused its first-compact
  # authorization with `502 invalid_compaction_response` (findings#281). It ends
  # the admission as any failed compaction does.
  defp finalize_consumed_request(state, {:ok, %{terminal: terminal}}, :compact, request) when terminal in @completed_terminals do
    case NativeCompactionAdmission.record_compact_collected(admission_state(state), System.system_time(:millisecond)) do
      {:ok, admission} -> put_admission(state, admission)
      {:error, reason} -> state |> clear_admission(reason) |> collect_closed_connection_compaction(request)
    end
  end

  defp finalize_consumed_request(state, _result, :native_replay, _request), do: state

  defp finalize_consumed_request(
         state,
         {:ok, _result},
         :final,
         %Request{native_compaction_capability: %Capability{} = capability}
       ) do
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :acknowledged)
    :ok = trace_capability(:capability_acknowledged, capability, %{pid_role: :upstream_session})
    state
  end

  defp finalize_consumed_request(state, _result, :compact, _request),
    do: clear_admission(state, :compact_failure)

  defp finalize_consumed_request(state, {:error, _result}, :final, _request),
    do: clear_admission(state, :final_failure)

  defp finalize_consumed_request(state, _result, nil, _request), do: state

  defp maybe_record_successful_serving_mode(
         %{conn: _conn} = state,
         {:ok, %{terminal: terminal} = result},
         %ReceiveState{delivery: %Delivery{effective_serving_mode: mode}}
       )
       when mode in ["full", "lite"] do
    if context_kept_terminal?(terminal, Map.get(result, :upstream_error_code)),
      do: Map.put(state, :last_successful_effective_serving_mode, mode),
      else: state
  end

  defp maybe_record_successful_serving_mode(state, _result, %ReceiveState{}), do: state

  # The idle keepalive only runs between requests, while this process waits in
  # its GenServer loop. A submitted turn blocks that loop in `receive_events/2`
  # for as long as the provider stays silent (a long reasoning pause, a held
  # turn), so without an in-flight ping the peer or an intermediary sees no
  # client data and can close the socket on its own idle timeout, failing a
  # turn that was still running upstream (Bandit's default 60 s, the smoke
  # proxy-drain lane, icoretech/codex-pooler-findings#206 row 206-142). The
  # keepalive clock restarts at the submission and keeps pinging on the same
  # interval until the request ends; the reply re-arms the idle keepalive.
  defp await_sent_request(state, receive_state) do
    :erlang.garbage_collect(self())
    state = schedule_keepalive(state)
    receive_state = receive_state |> renew_receive_deadline() |> arm_compaction_pending()

    {result, state} =
      case receive_state.upgrade_frames do
        [] ->
          receive_events(state, receive_state)

        # Text frames the peer wrote behind the `101` come before anything this loop reads, in the order they came
        # (`settle_upgrade_frames/4`).
        frames ->
          state |> handle_frames(frames, %{receive_state | upgrade_frames: []}) |> finish_receive_result()
      end

    {:ok, result, state}
  end

  # Only response data renews this idle deadline. Local keepalive ticks and
  # peer control frames prove connection liveness, not response progress.
  defp renew_receive_deadline(%ReceiveState{} = receive_state) do
    %{receive_state | receive_deadline_ms: System.monotonic_time(:millisecond) + receive_state.timeouts.receive_timeout_ms}
  end

  defp request_error(reason, state) do
    {:error,
     %{
       body: "",
       reason: reason,
       headers: Map.get(state, :headers, []),
       websocket_frame_headers: %{},
       transport_failure: request_error_transport_failure(reason, state)
     }}
  end

  defp put_result_connection_metadata({status, result}, state, connection_usage)
       when status in [:ok, :error] do
    {status,
     Map.put(
       result,
       :upstream_websocket_connection,
       upstream_websocket_connection(state, connection_usage)
     )}
  end

  @spec upstream_websocket_connection(map(), connection_usage()) ::
          upstream_websocket_connection()
  defp upstream_websocket_connection(
         %{lifecycle_id: lifecycle_id, generation: generation},
         %{reused: reused, reconnected: reconnected}
       ) do
    %{
      lifecycle_id: lifecycle_id,
      generation: generation,
      reused: reused,
      reconnected: reconnected
    }
  end

  defp request_error_transport_failure(reason, state) do
    phase = Map.get(state, :transport_failure_phase, :request)

    attrs =
      %{
        phase: phase,
        termination_source: Map.get(state, :transport_failure_source) || request_failure_source(reason),
        pre_visible_output: true,
        terminal_seen: false,
        text_frame_count: 0
      }
      |> maybe_mark_pre_submission_failure(phase)
      |> Map.merge(Map.get(state, :current_request_diagnostics, %{}))

    TransportFailureReason.transport_failure_metadata(reason, attrs)
  end

  defp maybe_mark_pre_submission_failure(attrs, :connect),
    do: Map.put(attrs, :upstream_committed, false)

  defp maybe_mark_pre_submission_failure(attrs, _phase), do: attrs

  defp request_failure_source(:upstream_websocket_session_unavailable), do: :session_unavailable
  defp request_failure_source(_reason), do: nil

  defp begin_connection_request(state, %ReceiveState{} = receive_state, connection_usage) do
    now = System.monotonic_time(:millisecond)
    request_ordinal = Map.get(state, :connection_request_count, 0) + 1
    connection_started_at = Map.get(state, :connection_started_at_monotonic_ms, now)
    last_request_completed_at = Map.get(state, :last_request_completed_at_monotonic_ms)

    diagnostics = %{
      connection_use: connection_use(connection_usage),
      connection_request_bucket: connection_request_bucket(request_ordinal),
      connection_age_bucket: connection_age_bucket(now - connection_started_at),
      connection_idle_bucket: connection_idle_bucket(last_request_completed_at, now)
    }

    state =
      state
      |> Map.put(:connection_request_count, request_ordinal)
      |> Map.put(:current_request_diagnostics, diagnostics)

    receive_state =
      struct!(receive_state, %{
        connection_use: diagnostics.connection_use,
        connection_request_bucket: diagnostics.connection_request_bucket,
        connection_age_bucket: diagnostics.connection_age_bucket,
        connection_idle_bucket: diagnostics.connection_idle_bucket
      })

    {state, receive_state}
  end

  defp complete_connection_request(%{conn: _conn} = state) do
    state
    |> Map.put(:last_request_completed_at_monotonic_ms, System.monotonic_time(:millisecond))
    |> clear_current_request_diagnostics()
  end

  defp complete_connection_request(state), do: clear_current_request_diagnostics(state)

  defp clear_current_request_diagnostics(state) do
    state
    |> Map.delete(:current_request_diagnostics)
    |> Map.delete(:transport_failure_phase)
    |> Map.delete(:transport_failure_source)
  end

  defp connection_use(%{reconnected: true}), do: :reconnected
  defp connection_use(%{reused: true}), do: :reused
  defp connection_use(_connection_usage), do: :fresh

  defp connection_request_bucket(1), do: :first
  defp connection_request_bucket(value) when value in 2..5, do: :requests_2_5
  defp connection_request_bucket(value) when value in 6..20, do: :requests_6_20
  defp connection_request_bucket(value) when value in 21..50, do: :requests_21_50
  defp connection_request_bucket(_value), do: :requests_51_plus

  defp connection_age_bucket(value) when value < @one_minute_ms, do: :under_1m
  defp connection_age_bucket(value) when value < @five_minutes_ms, do: :minutes_1_5
  defp connection_age_bucket(value) when value < @fifteen_minutes_ms, do: :minutes_5_15
  defp connection_age_bucket(value) when value < @thirty_minutes_ms, do: :minutes_15_30
  defp connection_age_bucket(_value), do: :minutes_30_plus

  defp connection_idle_bucket(nil, _now), do: :first_request

  defp connection_idle_bucket(last_request_completed_at, now) do
    case max(now - last_request_completed_at, 0) do
      value when value < @five_seconds_ms -> :under_5s
      value when value < @thirty_seconds_ms -> :seconds_5_30
      value when value < @two_minutes_ms -> :seconds_30_to_2m
      value when value < @ten_minutes_ms -> :minutes_2_10
      value when value < @thirty_minutes_ms -> :minutes_10_30
      _value -> :minutes_30_plus
    end
  end

  defp send_text(%{conn: conn, ref: ref, websocket: websocket} = state, text) do
    _trace =
      NativeCompactionTrace.emit_full(:upstream_websocket_frame_sent, %{
        direction: :pooler_to_upstream,
        upstream_pid: self(),
        frame_json: decode_text_frame(text),
        frame_text: text
      })

    case Mint.WebSocket.encode(websocket, {:text, text}) do
      {:ok, websocket, data} ->
        stream_request_body(%{state | websocket: websocket}, conn, ref, data)

      {:error, websocket, reason} ->
        _trace =
          NativeCompactionTrace.emit_full(:upstream_websocket_frame_send_failed, %{
            direction: :pooler_to_upstream,
            upstream_pid: self(),
            reason: reason
          })

        {:error, reason, %{state | websocket: websocket}}
    end
  end

  defp trace_physical_send(
         event,
         %Request{native_compaction_capability: %Capability{} = capability},
         outcome
       ),
       do:
         trace_capability(event, capability, %{
           pid_role: :upstream_session,
           upstream_pid: self(),
           outcome: trace_send_outcome(outcome),
           reason: trace_send_reason(outcome)
         })

  defp trace_physical_send(_event, _request, _outcome), do: :ok

  defp trace_send_outcome({:error, _reason}), do: :error
  defp trace_send_outcome(outcome), do: outcome
  defp trace_send_reason({:error, reason}), do: reason
  defp trace_send_reason(_outcome), do: nil

  defp trace_capability(event, capability, metadata) do
    case NativeCompactionTrace.emit_capability(event, capability, metadata) do
      :ignored -> :ok
      :ok -> :ok
    end
  end

  defp stream_request_body(state, conn, ref, data) do
    case Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, conn, reason} -> {:error, reason, %{state | conn: conn}}
    end
  end

  defp receive_events(state, %ReceiveState{compaction_pending_observer: nil} = receive_state), do: receive_live_events(state, receive_state)

  defp receive_events(state, %ReceiveState{} = receive_state) do
    if request_caller_down?(receive_state) do
      {request_caller_down_result(state, receive_state), invalidate_cancelled_request(state, receive_state, :receive)}
    else
      receive_live_events(state, receive_state)
    end
  end

  defp receive_live_events(%{conn: conn} = state, %ReceiveState{} = receive_state) do
    receive_state = maybe_observe_compaction_pending(receive_state)
    socket = mint_socket(conn)
    request_caller_pid = receive_state.request_caller_pid
    request_caller_monitor = receive_state.request_caller_monitor
    keepalive_token = Map.get(state, :keepalive_token)

    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason}
      when is_reference(request_caller_monitor) and is_pid(request_caller_pid) ->
        {request_caller_down_result(state, receive_state), invalidate_cancelled_request(state, receive_state, :receive)}

      {:tcp, ^socket, _data} = message ->
        handle_event_message(state, receive_state, message)

      {:ssl, ^socket, _data} = message ->
        handle_event_message(state, receive_state, message)

      {:tcp_closed, ^socket} = message ->
        handle_event_message(state, receive_state, message)

      {:ssl_closed, ^socket} = message ->
        handle_event_message(state, receive_state, message)

      {:tcp_error, ^socket, _reason} = message ->
        handle_event_message(state, receive_state, message)

      {:ssl_error, ^socket, _reason} = message ->
        handle_event_message(state, receive_state, message)

      {:compaction_pending_probe, receiver, challenge, token, request_id, attempt_id, sequence} ->
        receive_state = acknowledge_compaction_pending(receive_state, receiver, challenge, token, request_id, attempt_id, sequence)
        receive_events(state, receive_state)

      {:upstream_websocket_pong_deadline, token} ->
        handle_pong_deadline_message(state, receive_state, token)

      {:upstream_websocket_keepalive, ^keepalive_token} when is_reference(keepalive_token) ->
        send_in_flight_keepalive(state, receive_state)

      {:upstream_websocket_interrupt, interrupt} ->
        handle_interrupt_message(state, receive_state, interrupt)

      {:upstream_websocket_steer, steer} ->
        case write_steer(state, receive_state, steer) do
          {:ok, state, receive_state} -> receive_events(state, receive_state)
          {:error, state} -> finish_receive_result({:failure, state, receive_state, :upstream_websocket_session_unavailable})
        end

      {:upstream_websocket_cancel_steering, lane, {request_id, attempt_id}, reason} when lane == receive_state.native_response_steering and request_id == receive_state.request_id and attempt_id == receive_state.attempt_id ->
        finish_receive_result({:failure, state, receive_state, reason})
    after
      receive_wait_ms(receive_state) ->
        if System.monotonic_time(:millisecond) < receive_state.receive_deadline_ms,
          do: receive_events(state, receive_state),
          else: receive_timeout(state, receive_state)
    end
  end

  defp receive_timeout(state, receive_state) do
    result =
      {:error,
       %{
         body: receive_body(receive_state),
         response_usage: receive_model_usage(receive_state),
         reason: :upstream_websocket_receive_timeout,
         headers: state.headers,
         upstream_error_param: receive_state.terminal_upstream_error_param,
         websocket_frame_headers: receive_state.websocket_frame_headers,
         transport_failure:
           transport_failure_metadata(
             :upstream_websocket_receive_timeout,
             state,
             receive_state,
             phase: :receive_timeout,
             termination_source: :pooler_receive_timeout
           )
       }}

    result = finalize_native_steering_failure(result, receive_state)
    {result, invalidate_state(state)}
  end

  # Only this submitted request's receive loop emits pending controls. There
  # is no autonomous timer process and no provider-progress or writer call.
  # A paused/dead receive loop emits nothing; its original deadline still wins
  # when it resumes. Missed intervals are coalesced into one notification.
  defp arm_compaction_pending(%ReceiveState{compaction_pending_observer: observer} = receive_state) when is_function(observer, 1),
    do: %{receive_state | compaction_pending_token: make_ref(), compaction_pending_next_ms: System.monotonic_time(:millisecond) + compaction_pending_interval_ms()}

  defp arm_compaction_pending(receive_state), do: receive_state

  defp maybe_observe_compaction_pending(%ReceiveState{compaction_pending_next_ms: next_ms} = receive_state) when is_integer(next_ms) do
    now_ms = System.monotonic_time(:millisecond)
    remaining_ms = receive_state.receive_deadline_ms - now_ms

    if now_ms >= next_ms and remaining_ms > 0 do
      sequence = receive_state.compaction_pending_sequence + 1

      receive_state.compaction_pending_observer.(%{
        request_id: receive_state.request_id,
        attempt_id: receive_state.attempt_id,
        upstream_pid: self(),
        token: receive_state.compaction_pending_token,
        sequence: sequence,
        remaining_ms: remaining_ms
      })

      %{receive_state | compaction_pending_sequence: sequence, compaction_pending_next_ms: now_ms + compaction_pending_interval_ms()}
    else
      receive_state
    end
  end

  defp maybe_observe_compaction_pending(receive_state), do: receive_state

  # The socket challenges the actual receive loop before using a notification.
  # A delayed pulse cannot keep a stalled owner alive. The token is unique per
  # submitted request, each sequence grants at most one acknowledgement, and
  # neither probing nor acknowledgement changes the upstream receive deadline.
  defp acknowledge_compaction_pending(
         %ReceiveState{compaction_pending_token: token, request_id: request_id, attempt_id: attempt_id, compaction_pending_sequence: sequence} = receive_state,
         receiver,
         challenge,
         token,
         request_id,
         attempt_id,
         sequence
       )
       when is_reference(token) and is_reference(challenge) and is_pid(receiver) and sequence > 0 do
    remaining_ms = receive_state.receive_deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms > 0 and sequence > receive_state.compaction_pending_ack_sequence do
      send(receiver, {:compaction_pending_ack, challenge, token, request_id, attempt_id, sequence, remaining_ms})
      %{receive_state | compaction_pending_ack_sequence: sequence}
    else
      receive_state
    end
  end

  defp acknowledge_compaction_pending(receive_state, _receiver, _challenge, _token, _request_id, _attempt_id, _sequence), do: receive_state

  defp receive_wait_ms(receive_state) do
    deadline_ms =
      case receive_state.compaction_pending_next_ms do
        pending_ms when is_integer(pending_ms) -> min(receive_state.receive_deadline_ms, pending_ms)
        nil -> receive_state.receive_deadline_ms
      end

    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp compaction_pending_interval_ms do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:compaction_pending_interval_ms, 15_000)
    |> case do
      interval when is_integer(interval) and interval > 0 and interval <= 15_000 -> interval
      _invalid -> 15_000
    end
  end

  # An in-flight ping only keeps the connection visibly alive; it arms no pong
  # deadline, so a provider that answers late never fails a running turn that
  # the receive timeout still covers. A pong deadline armed by an idle ping
  # before the request keeps its existing meaning. A ping that cannot be written
  # fails the turn exactly like a Pong that cannot be written.
  defp send_in_flight_keepalive(state, %ReceiveState{} = receive_state) do
    case send_frame(state, {:ping, unique_keepalive_payload()}) do
      {:ok, state} ->
        receive_events(state |> mark_ping_sent() |> schedule_keepalive(), receive_state)

      {:error, reason, state} ->
        receive_state = %{receive_state | termination_source: :websocket_control_send_error}
        finish_receive_result({:failure, state, receive_state, {:websocket_control_send_failed, reason}})
    end
  end

  # The provider resolves an interrupt only on the connection that carries the
  # response it names, and only while that response runs: it answers with
  # `response.interrupt.accepted`, `response.output_item.interrupted` for an
  # item it had open and the terminal `response.incomplete` (reason
  # `interrupted`), which this loop reads and relays like any other frame. A
  # collected turn (a compaction) is never interrupted: the released client
  # sends no interrupt for one, and its result is not relayed as it arrives.
  # An interrupt that cannot be written does what a ping that cannot be
  # written does: the connection is gone, and the turn fails with it.
  defp handle_interrupt_message(state, %ReceiveState{} = receive_state, interrupt) do
    case interrupt_disposition(receive_state, interrupt) do
      :write ->
        case send_text(state, ResponseInterrupt.frame(interrupt)) do
          {:ok, state} ->
            :ok = ResponseInterrupt.log(:written, interrupt_topology(state))
            receive_events(state, receive_state)

          {:error, reason, state} ->
            :ok = ResponseInterrupt.log(:session_unavailable, interrupt_topology(state))
            receive_state = %{receive_state | termination_source: :websocket_control_send_error}
            finish_receive_result({:failure, state, receive_state, {:websocket_control_send_failed, reason}})
        end

      outcome ->
        :ok = ResponseInterrupt.log(outcome, interrupt_topology(state))
        receive_events(state, receive_state)
    end
  end

  defp interrupt_disposition(%ReceiveState{delivery: %Delivery{mode: mode}}, _interrupt) when mode != :relay, do: :not_relay

  defp interrupt_disposition(%ReceiveState{message_mapper: mapper} = receive_state, interrupt) do
    cond do
      public_openai_responses_mapper?(mapper) -> :not_relay
      receive_state.terminal_seen? -> :terminal_seen
      is_binary(receive_state.response_id) and receive_state.response_id == interrupt.response_id -> :write
      true -> :response_mismatch
    end
  end

  defp interrupt_topology(state), do: if(Map.get(state, :admission_topology) == :forwarded, do: :owner, else: :direct)

  @spec request_native_steering(Request.t()) :: {pid() | nil, pid() | nil}
  defp request_native_steering(request) do
    case Map.get(request, :native_response_steering) do
      {lane, owner} when is_pid(lane) and is_pid(owner) -> {lane, owner}
      lane when is_pid(lane) -> {lane, nil}
      nil -> {nil, nil}
    end
  end

  defp request_native_steering_lane(request), do: elem(request_native_steering(request), 0)

  defp write_steer(state, %ReceiveState{native_response_steering: lane, delivery: %Delivery{mode: :relay}, message_mapper: mapper} = receive_state, steer) when is_pid(lane) do
    if public_openai_responses_mapper?(mapper) do
      :ok = ResponseSteer.log(:not_relay, interrupt_topology(state))
      {:ok, state, receive_state}
    else
      with :ok <- NativeResponseSteering.activate(lane, self(), Map.get(state, :native_response_steering_owner)),
           {:ok, state} <- send_text(state, ResponseSteer.frame(steer)) do
        :ok = ResponseSteer.log(:written, interrupt_topology(state))
        {:ok, state, %{receive_state | steering_requested?: true, steering_targets: Enum.take([steer.previous_response_id | receive_state.steering_targets], 64)}}
      else
        _refused ->
          :ok = ResponseSteer.log(:session_unavailable, interrupt_topology(state))
          NativeResponseSteering.closed(lane, {receive_state.request_id, receive_state.attempt_id}, :owner_unavailable)
          {:error, state}
      end
    end
  end

  defp write_steer(state, receive_state, _steer) do
    :ok = ResponseSteer.log(:not_relay, interrupt_topology(state))
    {:ok, state, receive_state}
  end

  defp request_caller_down?(%ReceiveState{
         request_caller_pid: request_caller_pid,
         request_caller_monitor: request_caller_monitor
       })
       when is_pid(request_caller_pid) and is_reference(request_caller_monitor) do
    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason} -> true
    after
      0 -> false
    end
  end

  defp request_caller_down?(%ReceiveState{}), do: false

  defp request_caller_down_result(state, %ReceiveState{} = receive_state) do
    {:error,
     %{
       body: receive_body(receive_state),
       response_usage: receive_model_usage(receive_state),
       reason: :client_disconnected,
       headers: Map.get(state, :headers, []),
       upstream_error_param: receive_state.terminal_upstream_error_param,
       websocket_frame_headers: receive_state.websocket_frame_headers,
       transport_failure:
         transport_failure_metadata(:client_disconnected, state, receive_state,
           phase: :receive,
           termination_source: :request_caller_down
         ),
       native_client_retry_observation: final_client_retry_observation(receive_state)
     }}
  end

  defp handle_event_message(
         %{conn: conn} = state,
         %ReceiveState{} = receive_state,
         message
       ) do
    receive_state = %{receive_state | transport_signal: transport_signal(message)}

    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_parts(state, responses, receive_state)

      {:error, conn, reason, responses} ->
        handle_transport_error_parts(%{state | conn: conn}, responses, receive_state, reason)

      :unknown ->
        receive_events(state, %{receive_state | transport_signal: nil})
    end
  end

  # Mint can hand back responses that were fully parsed before the transport
  # error surfaced (mint_web_socket returns the pending data batch when
  # re-arming the socket fails because the peer already closed). A terminal in
  # that batch is a completed upstream turn; anything short of a halting
  # outcome still fails with the original reason over the updated state.
  defp handle_transport_error_parts(state, responses, %ReceiveState{} = receive_state, reason) do
    responses
    |> Enum.reduce_while({:continue, state, receive_state}, &handle_part/2)
    |> case do
      {:continue, state, receive_state} ->
        result = finalize_native_steering_failure(transport_error_result(state, receive_state, reason), receive_state)
        {result, close_state(state)}

      halted ->
        {result, state} = finish_receive_result(halted)
        {result, close_after_transport_error(state, halted, reason)}
    end
  end

  # A terminal decoded beside the transport error completed its request, so
  # the connection closes after that request like any close between requests:
  # one close line, and the subscriber is told, since the client now holds the
  # terminal's response as an anchor (findings#270). A retryable pre-visible
  # first frame also ends its exchange and would have kept the connection, as
  # its coalesced Close shows, so it closes the same way. Both closes used to
  # leave no trace. Any other halt failed its request, which records the close.
  defp close_after_transport_error(state, {:terminal, _state, _receive_state, _terminal, _trailing}, reason),
    do: close_after_exchange(state, idle_transport_cause(reason), transport_reason: reason)

  defp close_after_transport_error(
         state,
         {:failure, _state, %ReceiveState{termination_source: :upstream_terminal_event}, _failure, _trailing},
         reason
       ),
       do: close_after_exchange(state, idle_transport_cause(reason), transport_reason: reason)

  defp close_after_transport_error(state, _halted, _reason), do: close_state(state)

  # A close at the end of an exchange is logged before the request call records
  # the exchange's completion, so it records it first: the line's `idle_ms`
  # then counts from this exchange, not from the one before it or `none`.
  defp close_after_exchange(state, cause, details) do
    state
    |> mark_exchange_completed()
    |> close_between_requests(cause, details)
  end

  defp mark_exchange_completed(%{conn: _conn} = state),
    do: Map.put(state, :last_request_completed_at_monotonic_ms, System.monotonic_time(:millisecond))

  defp mark_exchange_completed(state), do: state

  defp transport_error_result(state, %ReceiveState{} = receive_state, reason) do
    {:error,
     %{
       body: receive_body(receive_state),
       response_usage: receive_model_usage(receive_state),
       reason: reason,
       headers: state.headers,
       upstream_error_param: receive_state.terminal_upstream_error_param,
       websocket_frame_headers: receive_state.websocket_frame_headers,
       transport_failure:
         transport_failure_metadata(reason, state, receive_state,
           phase: :receive,
           termination_source: :mint_transport_error
         ),
       native_client_retry_observation: final_client_retry_observation(receive_state)
     }}
  end

  defp handle_pong_deadline_message(
         %{keepalive_pong_token: token} = state,
         %ReceiveState{} = receive_state,
         token
       ) do
    result =
      {:error,
       %{
         body: receive_body(receive_state),
         response_usage: receive_model_usage(receive_state),
         reason: :upstream_websocket_pong_deadline,
         headers: state.headers,
         upstream_error_param: receive_state.terminal_upstream_error_param,
         websocket_frame_headers: receive_state.websocket_frame_headers,
         transport_failure:
           transport_failure_metadata(
             :upstream_websocket_pong_deadline,
             state,
             receive_state,
             phase: :receive,
             termination_source: :pooler_pong_deadline
           )
       }}

    result = finalize_native_steering_failure(result, receive_state)
    {result, close_state(state)}
  end

  defp handle_pong_deadline_message(state, %ReceiveState{} = receive_state, _token) do
    receive_events(state, receive_state)
  end

  defp handle_parts(state, responses, %ReceiveState{} = receive_state) do
    responses
    |> Enum.reduce_while({:continue, state, receive_state}, &handle_part/2)
    |> finish_receive_result()
  end

  defp handle_part({:data, ref, data}, {:continue, %{ref: ref} = state, receive_state}) do
    state
    |> handle_data(data, receive_state)
    |> reduce_receive_result()
  end

  defp handle_part({:done, _ref}, {:continue, state, receive_state}) do
    receive_state = %{receive_state | termination_source: :mint_stream_done}
    {:halt, {:failure, state, receive_state, :upstream_websocket_closed_before_terminal}}
  end

  defp handle_part(_part, result), do: {:cont, result}

  defp finish_receive_result(result) do
    case result do
      {:continue, state, receive_state} ->
        receive_events(state, %{receive_state | transport_signal: nil})

      {:terminal, state, receive_state, terminal} ->
        finish_terminal_result(state, receive_state, terminal, [])

      {:terminal, state, receive_state, terminal, trailing_frames} ->
        finish_terminal_result(state, receive_state, terminal, trailing_frames)

      {:failure, state, receive_state, reason} ->
        finish_failure_result(state, receive_state, reason, [])

      {:failure, state, receive_state, reason, trailing_frames} ->
        finish_failure_result(state, receive_state, reason, trailing_frames)
    end
  end

  # A retryable pre-visible first frame fails the request with
  # `upstream_terminal_event` and keeps the connection for reuse, so a Close or
  # Ping decoded behind it in the same read gets the same drain the terminal
  # gives its trailing frames (icoretech/codex-pooler-findings#203). Every other
  # failure retires or invalidates the connection and carries no trailing frames.
  # The error result is built from the pre-drain state, like the terminal's.
  defp finish_failure_result(state, %ReceiveState{steering_successor?: true, native_lane_error?: false} = receive_state, reason, _trailing_frames) do
    failure = %{body: receive_body(receive_state), response_usage: receive_model_usage(receive_state), reason: reason, headers: Map.get(state, :headers, []), websocket_frame_headers: receive_state.websocket_frame_headers, transport_failure: transport_failure_metadata(reason, state, receive_state, phase: failure_phase(reason))}
    failure = put_native_steering_terminal_result(receive_state, failure)
    {{:error, failure}, close_state(state)}
  end

  defp finish_failure_result(state, %ReceiveState{native_lane_error?: true} = receive_state, _reason, _trailing_frames) do
    result = %{body: receive_body(receive_state), terminal: "error", status: 200, headers: Map.get(state, :headers, []), response_usage: receive_model_usage(receive_state), upstream_error_code: "unsupported_native_inflight_message", websocket_frame_headers: receive_state.websocket_frame_headers, provider_credits_admission: receive_state.provider_credits_admission}
    result = put_native_steering_terminal_result(receive_state, result)
    complete_native_steering_original(state, receive_state, result)
    {code, close_reason} = receive_state.native_lane_peer_close || {1000, ""}
    NativeResponseSteering.peer_close(receive_state.native_response_steering, code, close_reason)
    {{:ok, result}, close_state(state)}
  end

  defp finish_failure_result(state, receive_state, reason, trailing_frames) do
    next_state =
      if receive_state.termination_source == :upstream_terminal_event and not exhausted_connection?(receive_state),
        do: drain_trailing_frames(state, trailing_frames, :retryable_first_frame),
        else: retire_exhausted_connection(state, receive_state)

    {{:error,
      %{
        body: receive_body(receive_state),
        response_usage: receive_model_usage(receive_state),
        reason: reason,
        headers: Map.get(state, :headers, []),
        upstream_error_param: receive_state.terminal_upstream_error_param,
        websocket_frame_headers: receive_state.websocket_frame_headers,
        transport_failure: transport_failure_metadata(reason, state, receive_state, phase: failure_phase(reason)),
        native_client_retry_observation: final_client_retry_observation(receive_state)
      }}, next_state}
  end

  # Only an actual steer can introduce a provider-driven successor before
  # the owner's normal terminal/task-result arbitration ends.
  defp complete_native_steering_original(state, %ReceiveState{steering_requested?: true, steering_successor?: false} = receive_state, result) do
    if owner = Map.get(state, :native_response_steering_owner),
      do: WebsocketOwnerSession.complete_steering_original(owner, receive_state.request_id, result)
  end

  defp complete_native_steering_original(_state, _receive_state, _result), do: :ok

  defp finalize_native_steering_failure({:error, failure}, %ReceiveState{steering_successor?: true} = receive_state), do: {:error, put_native_steering_terminal_result(receive_state, failure)}

  defp finalize_native_steering_failure(result, _receive_state), do: result

  defp put_native_steering_terminal_result(receive_state, result) do
    case NativeResponseSteering.terminal(receive_state.native_response_steering, receive_state.request_id, result) do
      {:ok, finalized, acknowledgement} -> result |> Map.put(:native_response_steering_finalized, finalized) |> Map.put(:native_response_steering_acknowledgement, acknowledgement)
      {:error, reason} -> Map.put(result, :native_response_steering_terminal_failure, reason)
    end
  end

  # A peer may coalesce its Close with the terminal frame in a single TCP write,
  # and `Mint.WebSocket.decode/2` then hands this session both frames in one
  # decoded batch. The terminal ends the request, so every frame decoded behind
  # it used to be discarded and a coalesced Close was never answered: the peer
  # waited on an acknowledgement that never arrived, and the next request reused
  # a socket the peer had already closed
  # (icoretech/codex-pooler-findings#251). The trailing frames now go through
  # the same `handle_async_frames/2` the idle path uses, so a Close closes the
  # connection and takes it out of reuse, and a Ping still gets its Pong,
  # exactly as when either arrives in a read of its own. The success result is
  # built from the pre-drain state so the upgrade response headers survive the
  # close. Trailing data frames keep the behaviour they have always had: a text
  # or binary frame decoded after the terminal is not mapped, not written
  # downstream, not appended to the retained body, and not counted.
  defp finish_terminal_result(state, receive_state, terminal, trailing_frames) do
    result =
      %{
        body: terminal_body(receive_state),
        terminal: terminal,
        native_client_retry_observation: final_client_retry_observation(receive_state),
        response_usage: receive_model_usage(receive_state),
        status: 200,
        headers: Map.get(state, :headers, []),
        upstream_error_code: receive_state.terminal_upstream_error_code,
        upstream_error_param: receive_state.terminal_upstream_error_param,
        public_tool_completion_reason: receive_state.public_tool_completion_reason,
        websocket_frame_headers: receive_state.websocket_frame_headers
      }
      |> maybe_put_success_response_id(terminal, receive_state.response_id)

    {result, state} = retain_native_steering_terminal(state, receive_state, result)

    state = finish_native_steering_connection(state, receive_state, result, trailing_frames)

    state = if receive_state.public_tool_completion_reason, do: close_and_signal(state, :invalidated, &invalidate_state/1), else: state

    {{:ok, result}, maybe_retire_exhausted_connection(state, receive_state)}
  end

  defp finish_native_steering_connection(state, receive_state, result, trailing_frames) do
    case result do
      %{native_response_steering_finalized: {:error, %{code: "gateway_accounting_failed"}}} ->
        NativeResponseSteering.peer_close(receive_state.native_response_steering, 1011, "")
        close_state(state)

      %{native_response_steering_finalized: {:error, _failure}} ->
        close_state(state)

      %{native_response_steering_finalized: {:ok, %{stale_generation?: true}}} ->
        close_state(state)

      %{native_response_steering_terminal_failure: _reason} ->
        NativeResponseSteering.peer_close(receive_state.native_response_steering, 1011, "")
        close_state(state)

      _result ->
        drain_native_steering_terminal_frames(state, receive_state, trailing_frames)
    end
  end

  defp drain_native_steering_terminal_frames(state, receive_state, trailing_frames) do
    cond do
      receive_state.steering_accepted? -> handle_async_frames(state, trailing_frames, :idle)
      receive_state.steering_requested? or receive_state.steering_successor? -> defer_native_steering_frames(state, trailing_frames)
      true -> drain_trailing_frames(state, trailing_frames, :terminal)
    end
  end

  defp retain_native_steering_terminal(state, receive_state, result) do
    if is_pid(receive_state.native_response_steering) do
      result = result |> Map.put(:provider_credits_admission, receive_state.provider_credits_admission) |> Map.put(:upstream_websocket_connection, upstream_websocket_connection(state, %{reused: receive_state.connection_use == :reused, reconnected: false}))

      result = native_steering_success_receipt(state, receive_state, result)

      result =
        if receive_state.steering_requested? or receive_state.steering_successor? do
          result = put_native_steering_terminal_result(receive_state, result)

          complete_native_steering_original(state, receive_state, result)

          result
        else
          result
        end

      idle = %{receive_state | body: RetainedBody.empty(), response_usage: nil, request_caller_pid: nil, request_caller_monitor: nil, terminal_upstream_error_code: nil, terminal_upstream_error_param: nil}
      state = apply_native_steering_success(state, result)
      {result, Map.put(state, :native_response_steering_receive, idle)}
    else
      {result, state}
    end
  end

  defp defer_native_steering_frames(state, []), do: state

  defp defer_native_steering_frames(state, frames) do
    send(self(), {:upstream_websocket_steering_frames, frames})
    state
  end

  defp native_steering_success_receipt(state, receive_state, result) do
    if request = Map.get(state, :native_response_steering_current_request) do
      request = %{request | request_id: receive_state.request_id, attempt_id: receive_state.attempt_id}

      case OrdinarySuccessResult.from_response(request, {:ok, result}, connection_lifecycle_state(state)) do
        {:ok, receipt} -> Map.put(result, :ordinary_success_result, receipt)
        :error -> result
      end
    else
      result
    end
  end

  defp apply_native_steering_success(state, %{native_response_steering_finalized: {:ok, %{stale_generation?: true}}}), do: state

  defp apply_native_steering_success(state, %{native_response_steering_finalized: {:ok, %{}}, native_response_steering_acknowledgement: {:ok, %Binding{topology: %Direct{}} = binding, %OrdinarySuccessResult{} = receipt}}) do
    state = Map.put(state, :ordinary_success_result, receipt)
    {:reply, _reply, state} = handle_call({:arm_compact, binding, System.system_time(:millisecond) + NativeCompactionAdmission.reservation_ttl_ms(), receipt}, nil, state)
    state
  end

  defp apply_native_steering_success(state, _acknowledgement), do: state

  defp native_steering_model_payload(payload) do
    case CodexPooler.JSON.decode(payload) do
      {:ok, %{"model" => model}} -> CodexPooler.JSON.encode!(%{"model" => model})
      _invalid -> "{}"
    end
  end

  # Drains the frames decoded behind a halting frame through the idle path and,
  # when one of them is a peer Close, records one bounded info line so an
  # operator can see the drain run: which halt it followed, the close code and
  # the connection lifecycle it retired (icoretech/codex-pooler-findings#225).
  defp drain_trailing_frames(state, [], _halt), do: state

  defp drain_trailing_frames(state, trailing_frames, halt) when halt in [:terminal, :retryable_first_frame] do
    state
    |> mark_exchange_completed()
    |> handle_async_frames(trailing_frames, {:trailing, halt})
  end

  defp coalesced_close_code(code) when is_integer(code) and code in 1000..4999, do: code
  defp coalesced_close_code(nil), do: "none"
  defp coalesced_close_code(_code), do: "invalid"

  defp maybe_retire_exhausted_connection(state, receive_state) do
    cond do
      exhausted_connection?(receive_state) -> retire_exhausted_connection(state, receive_state)
      receive_state.provider_refusal? and Map.has_key?(state, :conn) -> retire_refused_connection(state)
      true -> state
    end
  end

  # The provider refuses a request it will not generate for with the wrapped
  # `{"type": "error", "status": 400, ...}` frame and, for the refusals it
  # sends before validating the payload (an unsupported parameter or tool
  # type, an anchor it cannot resolve), answers nothing more on that
  # connection and drops it without a Close frame about 3 s later (direct
  # probe 2026-10-06, findings#333, Full and Lite). A request sent on it in
  # that window is lost: it failed `502 upstream_request_failed` when the drop
  # came. The connection is retired at the refusal, so the next request of
  # the socket opens a fresh one; an anchor that connection produced is lost
  # with it, as the provider's drop loses it.
  defp retire_refused_connection(state) do
    lifecycle = connection_lifecycle_state(state)

    Logger.info(
      "websocket connection retirement decision " <>
        "reason_code=provider_refusal " <>
        "lifecycle_id=#{lifecycle.lifecycle_id} old_generation=#{lifecycle.generation}"
    )

    close_state(state)
  end

  defp provider_refusal_frame?(%{"type" => "error"} = decoded),
    do: Map.get(decoded, "status", Map.get(decoded, "status_code")) == 400

  defp provider_refusal_frame?(_decoded), do: false

  defp retire_exhausted_connection(state, receive_state) do
    if exhausted_connection?(receive_state) do
      lifecycle = connection_lifecycle_state(state)

      Logger.info(
        "websocket connection retirement decision " <>
          "reason_code=websocket_connection_limit_reached " <>
          "lifecycle_id=#{lifecycle.lifecycle_id} old_generation=#{lifecycle.generation}"
      )
    end

    close_state(state)
  end

  defp exhausted_connection?(%ReceiveState{
         terminal_upstream_error_code: "websocket_connection_limit_reached"
       }),
       do: true

  defp exhausted_connection?(%ReceiveState{}), do: false

  defp reduce_receive_result({:continue, _state, _receive_state} = result), do: {:cont, result}

  # Only `handle_part/2` folds through here, so every terminal that reaches
  # this function came from `reduce_frames/2` and carries the frames decoded
  # behind it in the same read. The four-element terminal exists solely for
  # `guard_connection_bound_continuation/3`, which hands its synthetic terminal
  # straight to `finish_receive_result/1` and never passes through this fold.
  defp reduce_receive_result({:terminal, _state, _receive_state, _terminal, _trailing} = result),
    do: {:halt, result}

  defp reduce_receive_result({:failure, _state, _receive_state, _reason} = result),
    do: {:halt, result}

  defp reduce_receive_result({:failure, _state, _receive_state, _reason, _trailing} = result),
    do: {:halt, result}

  defp handle_data(state, data, %ReceiveState{} = receive_state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        handle_frames(state, frames, receive_state)

      {:error, websocket, reason} ->
        state = %{state | websocket: websocket}

        receive_state = %{receive_state | termination_source: :websocket_decode_error}
        {:failure, state, receive_state, {:websocket_decode_failed, reason}}
    end
  end

  defp handle_async_parts(state, responses) do
    Enum.reduce_while(responses, state, fn
      {:data, ref, data}, %{ref: ref, websocket: websocket} = state ->
        case Mint.WebSocket.decode(websocket, data) do
          {:ok, websocket, frames} ->
            state = %{state | websocket: websocket}
            {:cont, handle_async_frames(state, frames, :idle)}

          {:error, websocket, reason} ->
            state = %{state | websocket: websocket}
            {:halt, close_between_requests(state, :decode_error, transport_reason: reason)}
        end

      {:done, _ref}, state ->
        {:halt, close_between_requests(state, :transport_closed, transport_reason: :closed)}

      _part, state ->
        {:cont, state}
    end)
  end

  # `context` is `:idle` for a read the session takes between requests and
  # `{:trailing, halt}` for frames decoded behind a halting frame of a request.
  # Only the frame that actually retires the connection supplies the close cause.
  defp handle_async_frames(%{native_response_steering_receive: %ReceiveState{steering_accepted?: true} = receive_state} = state, [{:text, text} | trailing] = frames, context) do
    case decode_text_frame(text) do
      %{"type" => "response.created", "response" => %{"id" => response_id}} ->
        receive_native_steering_successor(state, receive_state, response_id, frames)

      _other ->
        state |> handle_native_steering_idle_text(text) |> handle_async_frames(trailing, context)
    end
  end

  defp handle_async_frames(state, [], _context), do: state

  defp handle_async_frames(state, [frame | trailing], context) do
    case frame do
      {:ping, payload} ->
        case send_frame(state, {:pong, payload}) do
          {:ok, state} -> handle_async_frames(state, trailing, context)
          {:error, reason, state} -> close_async(state, context, :pong_send_failed, transport_reason: reason)
        end

      {:pong, payload} ->
        handle_async_frames(clear_matching_pong(state, payload), trailing, context)

      {:close, code, reason} ->
        notify_native_steering_peer_close(state, code, reason)

        close_async(state, context, :peer_close_frame, close_code: code, close_reason: reason)

      {:text, text} ->
        handle_async_frames(handle_native_steering_idle_text(state, text), trailing, context)

      {:binary, _data} ->
        handle_async_frames(state, trailing, context)

      {:error, reason} ->
        close_async(state, context, :frame_error, transport_reason: reason)
    end
  end

  defp receive_native_steering_successor(state, receive_state, response_id, frames) do
    case NativeResponseSteering.open_successor(receive_state.native_response_steering, response_id) do
      {:ok, prepared} ->
        successor = %ReceiveState{writer: prepared.writer, frame_observer: prepared.frame_observer, message_mapper: receive_state.message_mapper, timeouts: receive_state.timeouts, delivery: receive_state.delivery, request_id: prepared.request_id, attempt_id: prepared.attempt_id, native_response_steering: receive_state.native_response_steering, native_codex_response_control: receive_state.native_codex_response_control, provider_credits_admission: prepared.provider_credits_admission, steering_requested?: true, steering_accepted?: false, steering_successor?: true, connection_use: :reused}
        WebsocketRequestCallbacks.begin_request(prepared.request_id, prepared.attempt_id)
        {_result, state} = state |> handle_frames(frames, renew_receive_deadline(successor)) |> finish_receive_result()
        WebsocketRequestCallbacks.end_request()
        state

      {:error, _reason} ->
        close_state(state)
    end
  end

  defp notify_native_steering_peer_close(%{native_response_steering_receive: %ReceiveState{steering_requested?: true} = receive_state}, code, reason),
    do: NativeResponseSteering.peer_close(receive_state.native_response_steering, code, reason)

  defp notify_native_steering_peer_close(_state, _code, _reason), do: :ok

  defp handle_native_steering_idle_text(%{native_response_steering_receive: %ReceiveState{} = receive_state} = state, text) do
    decoded = decode_text_frame(text)
    type = if is_map(decoded), do: decoded["type"]

    cond do
      type in ["response.steer.accepted", "response.steer.failed"] ->
        receive_state = observe_steer_control(receive_state, decoded, interrupt_topology(state))
        NativeResponseSteering.control(receive_state.native_response_steering, text)
        Map.put(state, :native_response_steering_receive, receive_state)

      ResponseSteer.native_lane_error?(decoded) ->
        ResponseSteer.log(:native_lane_error, interrupt_topology(state), "error")
        NativeResponseSteering.control(receive_state.native_response_steering, text)
        state

      true ->
        state
    end
  end

  defp handle_native_steering_idle_text(state, _text), do: state

  defp close_async(state, :idle, cause, details), do: close_between_requests(state, cause, details)

  # A provider Close sent right after a response (its connection-age limit, a
  # restart) can arrive in the same read as the terminal (findings#270), so
  # the subscriber is told here too, inside the request call: before its reply
  # and after every frame the request relayed.
  defp close_async(state, {:trailing, halt}, :peer_close_frame, details) do
    lifecycle = connection_lifecycle_state(state)
    Logger.info("upstream websocket coalesced close drained reason_code=peer_close_frame halt=#{halt} close_code=#{coalesced_close_code(Keyword.get(details, :close_code))} lifecycle_id=#{lifecycle.lifecycle_id} generation=#{lifecycle.generation}")
    close_and_signal(state, :peer_close_frame, &close_state/1, details)
  end

  defp close_async(state, {:trailing, _halt}, cause, details), do: close_between_requests(state, cause, details)

  # Every close of a live connection outside a request leaves one bounded
  # diagnostic line before the connection state is dropped (findings#206 row
  # 206-356); a close inside a request is recorded on the attempt instead.
  defp close_between_requests(state, cause, details \\ []) do
    :ok = CloseDiagnostics.log_close(state, cause, details)
    close_and_signal(state, cause, &close_state/1, details)
  end

  # The signal is built from the state before the close, which drops the
  # connection's request count, and sent once the connection is closed.
  defp close_and_signal(state, cause, close, details \\ []) do
    signal = connection_closed_signal(state, cause, details)
    closed = close.(state)
    :ok = send_connection_closed_signal(signal)
    closed
  end

  # Nothing to tell without a subscriber or a live connection, for a cause
  # that ends no anchor, or for a connection that never carried a request: a
  # connection that sent nothing produced no response to anchor on.
  defp connection_closed_signal(%{conn: _conn, connection_close_subscriber: subscriber} = state, cause, details)
       when is_pid(subscriber) do
    requests = Map.get(state, :connection_request_count, 0)

    if is_integer(requests) and requests > 0 and CloseDiagnostics.anchor_invalidating_cause?(cause) do
      signal = %{cause: cause, lifecycle_id: state.lifecycle_id, generation: state.generation, connection_requests: requests}
      signal = put_steering_peer_close(signal, state, details)
      {subscriber, {:upstream_websocket_connection_closed, self(), signal}}
    else
      nil
    end
  end

  defp connection_closed_signal(_state, _cause, _details), do: nil

  # The lane forwards this same close asynchronously. Carry its authority on
  # the lifecycle signal too, so an idle downstream cannot race it with 1001.
  defp put_steering_peer_close(%{cause: :peer_close_frame} = signal, %{native_response_steering_receive: %ReceiveState{steering_requested?: true, native_response_steering: lane}}, details) when is_pid(lane),
    do: Map.put(signal, :steering_peer_close, {lane, Keyword.get(details, :close_code) || 1000, Keyword.get(details, :close_reason) || ""})

  defp put_steering_peer_close(signal, _state, _details), do: signal

  defp send_connection_closed_signal({subscriber, message}) do
    send(subscriber, message)
    :ok
  end

  defp send_connection_closed_signal(nil), do: :ok

  defp close_replaced_connection(%{conn: _conn, key: old_key} = state, key) do
    close_between_requests(state, :request_key_changed, key_change: {old_key, key})
  end

  defp close_replaced_connection(state, _key), do: close_state(state)

  defp idle_transport_cause(%Mint.TransportError{reason: :closed}), do: :transport_closed
  defp idle_transport_cause(_reason), do: :transport_error

  defp mark_ping_sent(state), do: Map.put(state, :last_ping_sent_at_monotonic_ms, System.monotonic_time(:millisecond))

  defp handle_frames(state, frames, %ReceiveState{} = receive_state) do
    reduce_frames(frames, {:continue, state, receive_state})
  end

  # Folded by hand rather than with `Enum.reduce_while/3` so the terminal can
  # hand the frames decoded behind it in the same read to the caller instead of
  # dropping them (icoretech/codex-pooler-findings#251); `finish_terminal_result/4`
  # drains them. A retryable pre-visible first frame (`upstream_terminal_event`)
  # also keeps the connection, so its failure carries them the same way
  # (icoretech/codex-pooler-findings#203). Every other halt ends the receive for
  # a reason that retires or invalidates the connection anyway, so it carries
  # nothing.
  defp reduce_frames([], result), do: result

  defp reduce_frames([frame | trailing_frames], {:continue, _state, _receive_state} = result) do
    case handle_frame(frame, result) do
      {:cont, next_result} ->
        reduce_frames(trailing_frames, next_result)

      {:halt, {:terminal, state, receive_state, terminal}} ->
        {:terminal, state, receive_state, terminal, trailing_frames}

      {:halt, {:failure, state, %ReceiveState{termination_source: :upstream_terminal_event} = receive_state, reason}} ->
        {:failure, state, receive_state, reason, trailing_frames}

      {:halt, halted_result} ->
        halted_result
    end
  end

  defp handle_frame({:text, raw_text}, {:continue, state, receive_state}) do
    receive_state = renew_receive_deadline(receive_state)
    raw_decoded = decode_text_frame(raw_text)

    {source_text, source_decoded, receive_state} =
      guard_public_tool_completion(raw_text, raw_decoded, receive_state)

    {mapped_text, mapped_decoded} =
      if receive_state.public_tool_completion_reason,
        do: {source_text, source_decoded},
        else: map_message(source_text, source_decoded, receive_state.message_mapper)

    handle_text_frame(
      state,
      receive_state,
      if(receive_state.public_tool_completion_reason, do: raw_text, else: source_text),
      if(receive_state.public_tool_completion_reason, do: raw_decoded, else: source_decoded),
      mapped_text,
      mapped_decoded
    )
  end

  defp handle_frame({:ping, payload}, {:continue, state, receive_state}) do
    case send_frame(state, {:pong, payload}) do
      {:ok, state} ->
        {:cont, {:continue, state, receive_state}}

      {:error, reason, state} ->
        receive_state = %{
          receive_state
          | termination_source: :websocket_control_send_error
        }

        {:halt, {:failure, state, receive_state, {:websocket_control_send_failed, reason}}}
    end
  end

  defp handle_frame({:pong, payload}, {:continue, state, receive_state}),
    do: {:cont, {:continue, clear_matching_pong(state, payload), receive_state}}

  defp handle_frame({:close, code, reason}, {:continue, state, receive_state}) do
    if receive_state.steering_requested? and not receive_state.native_lane_error? do
      NativeResponseSteering.peer_close(receive_state.native_response_steering, code, reason)
    end

    receive_state = %{
      receive_state
      | peer_close_metadata: TransportFailureReason.peer_close_metadata(code, reason),
        termination_source: :peer_close_frame,
        native_lane_peer_close: if(receive_state.native_lane_error?, do: {code, reason})
    }

    {:halt, {:failure, state, receive_state, :upstream_websocket_closed_before_terminal}}
  end

  defp handle_frame({:binary, _data}, {:continue, state, receive_state}) do
    receive_state = %{receive_state | termination_source: :unexpected_binary_frame}
    {:halt, {:failure, state, receive_state, :unexpected_upstream_websocket_binary}}
  end

  # The decoder reports a frame it cannot read in-band as `{:error, reason}`. It fails the request like the decode
  # error of `handle_data/3`; without this clause the session crashed on it (findings#304). Only the leading atom of
  # the reason is kept, because Mint's frame errors can carry the frame's own bytes.
  defp handle_frame({:error, reason}, {:continue, state, receive_state}) do
    receive_state = %{receive_state | termination_source: :websocket_decode_error}
    {:halt, {:failure, state, receive_state, {:websocket_decode_failed, frame_error_class(reason)}}}
  end

  defp frame_error_class(reason) when is_atom(reason), do: reason
  defp frame_error_class(reason) when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp frame_error_class(_reason), do: :unreadable_frame

  defp new_public_tool_completion(%Request{message_mapper: mapper, websocket_delivery_mode: :relay}) do
    if mapper == (&StreamProtocol.normalize_public_openai_responses_json_message/1),
      do: PublicResponsesToolCompletion.new_state()
  end

  defp new_public_tool_completion(%Request{}), do: nil

  defp guard_public_tool_completion(text, decoded, %ReceiveState{public_tool_completion: nil} = receive_state),
    do: {text, decoded, receive_state}

  defp guard_public_tool_completion(text, %{"type" => type, "response" => response} = decoded, receive_state)
       when type in ["response.failed", "response.incomplete", "error"] and not is_map(response) and not is_nil(response) do
    tracker = PublicResponsesToolCompletion.observe(receive_state.public_tool_completion, decoded)
    repaired_text = StreamProtocol.normalize_public_openai_responses_json_message(text)
    {repaired_text, CodexPooler.JSON.decode!(repaired_text), %{receive_state | public_tool_completion: tracker}}
  end

  defp guard_public_tool_completion(text, decoded, receive_state) do
    tracker = PublicResponsesToolCompletion.observe(receive_state.public_tool_completion, decoded)
    receive_state = %{receive_state | public_tool_completion: tracker}

    with %{} <- decoded,
         false <- decoded["type"] in ["response.failed", "response.incomplete", "error"],
         {:ok, %{kind: :completed}} <- StreamProtocol.terminal_outcome(nil, decoded),
         {:error, reason} <- PublicResponsesToolCompletion.completion_verdict(tracker) do
      event = Adapter.websocket_error(%{status: 500, code: :server_error, message: StreamProtocol.synthetic_public_openai_responses_failure_message(), param: nil})
      receive_state = %{receive_state | public_tool_completion_reason: reason, terminal_upstream_error_code: "upstream_stream_error"}
      {CodexPooler.JSON.encode!(event), event, receive_state}
    else
      _outcome -> {text, decoded, receive_state}
    end
  end

  defp append_receive_body(
         %ReceiveState{body: body, collected_body: collected_body} = receive_state,
         text
       ) do
    data = sse_data_block(text)
    telemetry_opts = buffer_telemetry_opts(receive_state)

    %{
      receive_state
      | body: RetainedBody.append(body, data, telemetry_opts),
        collected_body: append_collected_body(collected_body, data, telemetry_opts)
    }
  end

  # The retained and collected bodies are SSE, and the finalizer reads the
  # turn's terminal back out of them (usage, terminal code, provider rejection
  # fields), so a multi-line frame gets one `data:` line per text line
  # (findings#254 row 254-60).
  defp sse_data_block(text), do: [SSEParser.data_lines(text), "\n\n"]

  defp append_collected_body(collected_body, data, telemetry_opts) do
    appended = CollectedBody.append(collected_body, data)

    if CollectedBody.overflow?(appended) and not CollectedBody.overflow?(collected_body) do
      BufferTelemetry.record_oversized_incomplete(
        "collected_body",
        CollectedBody.bytes(appended),
        CollectedBody.max_bytes(),
        telemetry_opts
      )
    end

    appended
  end

  # A truncated retained body can only be attributed once the metric says which
  # transport and route class produced it. A collecting turn is admitted as
  # `proxy_compact` inside the outer websocket route class.
  defp buffer_telemetry_opts(%ReceiveState{delivery: %Delivery{mode: mode}}) do
    [transport: "websocket", route_class: buffer_route_class(mode)]
  end

  defp buffer_route_class(mode) when mode in [:collect_compaction, :collect_full_history],
    do: RouteClass.proxy_compact()

  defp buffer_route_class(_mode), do: RouteClass.proxy_websocket()

  defp handle_text_frame(
         state,
         %ReceiveState{} = receive_state,
         raw_text,
         raw_decoded,
         mapped_text,
         mapped_decoded
       ) do
    _trace =
      NativeCompactionTrace.emit_full(:upstream_websocket_frame_received, %{
        direction: :upstream_to_pooler,
        upstream_pid: self(),
        raw_frame_json: raw_decoded,
        raw_frame_text: raw_text,
        mapped_frame_json: mapped_decoded,
        mapped_frame_text: mapped_text
      })

    native_lane_error? = native_steering_lane_error?(receive_state, raw_decoded)
    terminal_discriminator = if native_lane_error?, do: %TerminalDiscriminator{last_upstream_event_type: "error", last_upstream_event_class: "terminal_failure_candidate"}, else: TerminalDiscriminator.classify(mapped_decoded)
    receive_state = observe_steer_control(receive_state, raw_decoded, interrupt_topology(state))

    receive_state =
      if native_lane_error? do
        ResponseSteer.log(:native_lane_error, interrupt_topology(state), "error")
        %{receive_state | native_lane_error?: true}
      else
        receive_state
      end

    collected_text =
      collected_text(
        receive_state,
        raw_text,
        mapped_text,
        terminal_discriminator
      )

    receive_state =
      raw_decoded
      |> maybe_put_terminal_upstream_error(receive_state)
      |> maybe_put_response_id(raw_decoded)
      |> maybe_put_served_model(raw_decoded)
      |> put_websocket_frame_headers(raw_decoded)
      |> increment_text_frame_count()
      |> capture_terminal_usage(raw_decoded, terminal_discriminator)
      |> append_receive_body(collected_text)
      |> put_terminal_discriminator(terminal_discriminator)

    case retryable_first_text_frame(raw_decoded, receive_state) do
      {:ok, reason} ->
        receive_state = %{receive_state | termination_source: :upstream_terminal_event}
        {:halt, {:failure, state, receive_state, reason}}

      :error ->
        receive_state = maybe_mark_downstream_output_started(receive_state, raw_decoded)
        receive_state = observe_native_client_retry(receive_state, raw_decoded)
        observe_frame(receive_state, raw_text, raw_decoded)
        receive_state = maybe_write_native_metadata(state, receive_state)

        {text, _decoded} =
          sanitize_downstream_text(
            {mapped_text, mapped_decoded},
            receive_state.native_codex_response_control
          )

        write_frame(receive_state.writer, text, terminal_discriminator)

        case terminal_discriminator.terminal do
          nil -> {:cont, {:continue, state, receive_state}}
          terminal -> {:halt, {:terminal, state, mark_terminal_seen(receive_state), terminal}}
        end
    end
  end

  # Preparing a native lane does not mean this request steered. The requested
  # flag is set only after that lane accepts activation and the steer is sent;
  # its pid may belong to the proxy node of a remote owner.
  defp native_steering_lane_error?(%ReceiveState{native_response_steering: lane, steering_requested?: true, delivery: %Delivery{mode: :relay}, message_mapper: mapper}, decoded) when is_pid(lane) do
    not public_openai_responses_mapper?(mapper) and ResponseSteer.native_lane_error?(decoded)
  end

  defp native_steering_lane_error?(_receive_state, _decoded), do: false

  defp observe_steer_control(receive_state, %{"type" => "response.steer.accepted"} = decoded, topology) do
    accepted = get_in(decoded, ["steer", "previous_response_id"]) in receive_state.steering_targets
    id = get_in(decoded, ["steer", "id"])

    if accepted and is_binary(id) and MapSet.size(receive_state.accepted_steer_ids) < 64 and not MapSet.member?(receive_state.accepted_steer_ids, id) do
      ResponseSteer.log(:accepted, topology, "response.steer.accepted", id)
      %{receive_state | steering_accepted?: true, accepted_steer_ids: MapSet.put(receive_state.accepted_steer_ids, id)}
    else
      receive_state
    end
  end

  defp observe_steer_control(receive_state, %{"type" => "response.steer.failed"} = decoded, topology) do
    ResponseSteer.log(:failed, topology, "response.steer.failed", get_in(decoded, ["steer", "id"]))
    receive_state
  end

  defp observe_steer_control(receive_state, _decoded, _topology), do: receive_state

  defp collected_text(
         %ReceiveState{delivery: %Delivery{mode: :collect_full_history}},
         raw_text,
         mapped_text,
         %TerminalDiscriminator{terminal: terminal}
       )
       when terminal in ["response.failed", "response.incomplete", "error"] and
              raw_text != mapped_text,
       do: mapped_text

  defp collected_text(
         %ReceiveState{delivery: %Delivery{mode: :collect_full_history}},
         raw_text,
         _mapped_text,
         _terminal_discriminator
       ),
       do: raw_text

  defp collected_text(
         %ReceiveState{},
         _raw_text,
         mapped_text,
         _terminal_discriminator
       ),
       do: mapped_text

  defp capture_terminal_usage(receive_state, decoded, %TerminalDiscriminator{terminal: terminal})
       when is_binary(terminal) do
    usage = ResponseUsage.from_stream_event(decoded)

    # The first response object declared the served model; the terminal event
    # repeats it, so the earlier declaration wins when both exist.
    usage =
      case receive_state.served_model do
        nil -> usage
        model -> Map.put(usage, :served_model, model)
      end

    %{receive_state | response_usage: usage}
  end

  defp capture_terminal_usage(receive_state, _decoded, _discriminator), do: receive_state

  defp transport_failure_metadata(
         reason,
         state,
         %ReceiveState{} = receive_state,
         attrs
       ) do
    TransportFailureReason.transport_failure_metadata(
      reason,
      Map.merge(
        %{
          termination_source: receive_state.termination_source,
          transport_signal: receive_state.transport_signal,
          connection_use: receive_state.connection_use,
          connection_request_bucket: receive_state.connection_request_bucket,
          connection_age_bucket: receive_state.connection_age_bucket,
          connection_idle_bucket: receive_state.connection_idle_bucket,
          pre_visible_output: not receive_state.downstream_output_started?,
          upstream_committed: true,
          terminal_seen: receive_state.terminal_seen?,
          last_upstream_event_type: receive_state.last_upstream_event_type,
          last_upstream_event_class: receive_state.last_upstream_event_class,
          terminal_candidate_seen: receive_state.terminal_candidate_seen?,
          terminal_candidate_type: receive_state.terminal_candidate_type,
          terminal_candidate_class: receive_state.terminal_candidate_class,
          terminal_candidate_rejection: receive_state.terminal_candidate_rejection,
          text_frame_count: receive_state.text_frame_count
        },
        state
        |> websocket_decoder_metadata()
        |> Map.merge(receive_state.peer_close_metadata)
        |> Map.merge(Map.new(attrs))
      )
    )
  end

  defp failure_phase({:websocket_decode_failed, _reason}), do: :decode
  defp failure_phase({:websocket_control_send_failed, _reason}), do: :send_control
  defp failure_phase(:upstream_websocket_closed_before_terminal), do: :upstream_close
  defp failure_phase(:unexpected_upstream_websocket_binary), do: :unexpected_frame
  defp failure_phase(_reason), do: :receive

  defp transport_signal({:tcp, _socket, _data}), do: :tcp_data
  defp transport_signal({:ssl, _socket, _data}), do: :ssl_data
  defp transport_signal({:tcp_closed, _socket}), do: :tcp_closed
  defp transport_signal({:ssl_closed, _socket}), do: :ssl_closed
  defp transport_signal({:tcp_error, _socket, _reason}), do: :tcp_error
  defp transport_signal({:ssl_error, _socket, _reason}), do: :ssl_error

  defp websocket_decoder_metadata(%{websocket: websocket}) when is_map(websocket) do
    # Mint.WebSocket.t/0 is opaque. These defensive projections retain only
    # bounded state and disappear safely if a future dependency removes a field.
    %{
      websocket_buffer_bucket: websocket_buffer_bucket(Map.get(websocket, :buffer)),
      websocket_fragment_open:
        if(Map.has_key?(websocket, :fragment),
          do: not is_nil(Map.get(websocket, :fragment)),
          else: nil
        )
    }
  end

  defp websocket_decoder_metadata(_state), do: %{}

  defp websocket_buffer_bucket(buffer) when is_binary(buffer) do
    case byte_size(buffer) do
      0 -> :empty
      value when value <= 125 -> :bytes_1_125
      value when value <= 1_024 -> :bytes_126_1024
      _value -> :bytes_1025_plus
    end
  end

  defp websocket_buffer_bucket(_buffer), do: nil

  defp retryable_first_text_frame(_decoded, %ReceiveState{steering_successor?: true}), do: :error

  defp retryable_first_text_frame(
         %{} = decoded,
         %ReceiveState{downstream_output_started?: false} = receive_state
       ) do
    retryable_pre_visible_terminal_event(
      StreamProtocol.event_summary(decoded),
      receive_state,
      decoded
    )
  end

  defp retryable_first_text_frame(_raw_text, %ReceiveState{}), do: :error

  defp retryable_pre_visible_terminal_event(event, receive_state, decoded) do
    case quota_exhausted_first_event(event, decoded) do
      {:ok, failure} -> {:ok, {:quota_exhausted_first_event, failure}}
      :error -> retryable_auth_first_event(event, receive_state)
    end
  end

  defp quota_exhausted_first_event(event, decoded) do
    with {:ok, %{code: code} = failure} <- StreamProtocol.terminal_failure_event(event),
         true <- code in ["usage_limit_reached", "usage_limit_exceeded"],
         true <- valid_quota_usage_shape?(decoded) do
      {:ok, Map.put(failure, :quota_rejection_before_output?, true)}
    else
      _other -> :error
    end
  end

  defp valid_quota_usage_shape?(%{} = decoded) do
    valid_quota_usage_field?(decoded) and
      case Map.get(decoded, "response") do
        %{} = response -> valid_quota_usage_field?(response)
        _absent -> true
      end
  end

  defp valid_quota_usage_field?(envelope) do
    case Map.fetch(envelope, "usage") do
      :error ->
        true

      {:ok, nil} ->
        true

      {:ok, %{} = usage} ->
        match?(
          %{status: "usage_known", total_tokens: 0},
          ResponseUsage.from_stream_event(%{"usage" => usage})
        )

      _malformed ->
        false
    end
  end

  defp retryable_auth_first_event(event, receive_state) do
    case StreamProtocol.auth_refresh_first_terminal_failure(event) do
      {:ok, failure} -> {:ok, {:auth_refresh_first_event, failure}}
      :error -> retryable_assignment_model_unavailable_event(event, receive_state)
    end
  end

  defp retryable_assignment_model_unavailable_event(event, receive_state) do
    case StreamProtocol.retryable_first_terminal_failure(
           event,
           receive_state.assignment_advertised?
         ) do
      {:ok, %{code: code} = failure}
      when code in ["model_not_found", "invalid_request_error"] ->
        {:ok, {:assignment_model_unavailable_first_event, failure}}

      _other ->
        retryable_connection_limit_event(event)
    end
  end

  defp retryable_connection_limit_event(event) do
    case StreamProtocol.retryable_first_terminal_failure(event) do
      {:ok, %{code: "websocket_connection_limit_reached"} = failure} ->
        {:ok, {:retryable_first_event, failure}}

      _other ->
        :error
    end
  end

  defp maybe_mark_downstream_output_started(
         %ReceiveState{delivery: %Delivery{mode: mode}} = receive_state,
         _decoded
       )
       when mode in [:collect_compaction, :collect_full_history],
       do: receive_state

  defp maybe_mark_downstream_output_started(%ReceiveState{} = receive_state, decoded) do
    if StreamProtocol.internal_control_event?(decoded) do
      receive_state
    else
      %{receive_state | downstream_output_started?: true}
    end
  end

  defp increment_text_frame_count(%ReceiveState{text_frame_count: count} = receive_state) do
    %{receive_state | text_frame_count: count + 1}
  end

  defp put_terminal_discriminator(
         %ReceiveState{} = receive_state,
         %TerminalDiscriminator{} = terminal_discriminator
       ) do
    receive_state = %{
      receive_state
      | last_upstream_event_type: terminal_discriminator.last_upstream_event_type,
        last_upstream_event_class: terminal_discriminator.last_upstream_event_class
    }

    if terminal_discriminator.terminal_candidate? do
      %{
        receive_state
        | terminal_candidate_seen?: true,
          terminal_candidate_type: terminal_discriminator.terminal_candidate_type,
          terminal_candidate_class: terminal_discriminator.terminal_candidate_class,
          terminal_candidate_rejection: terminal_discriminator.terminal_candidate_rejection
      }
    else
      receive_state
    end
  end

  defp mark_terminal_seen(%ReceiveState{} = receive_state),
    do: %{receive_state | terminal_seen?: true}

  defp maybe_put_terminal_upstream_error(%{} = decoded, %ReceiveState{} = receive_state) do
    case Map.get(decoded, "type") do
      type when type in ["response.failed", "response.incomplete", "error"] ->
        %{
          receive_state
          | terminal_upstream_error_code:
              receive_state.terminal_upstream_error_code ||
                StreamProtocol.upstream_error_code(decoded),
            terminal_upstream_error_param: receive_state.terminal_upstream_error_param || UpstreamErrorParam.extract(decoded),
            provider_refusal?: receive_state.provider_refusal? or provider_refusal_frame?(decoded)
        }

      _other ->
        receive_state
    end
  end

  defp maybe_put_terminal_upstream_error(_decoded, %ReceiveState{} = receive_state),
    do: receive_state

  defp maybe_put_success_response_id(result, terminal, response_id)
       when terminal in ["response.completed", "response.done"] and is_binary(response_id),
       do: Map.put(result, :response_id, response_id)

  defp maybe_put_success_response_id(%{upstream_error_code: reason} = result, "response.incomplete", response_id) when reason in ["interrupted", "steered"] and is_binary(response_id), do: Map.put(result, :response_id, response_id)

  defp maybe_put_success_response_id(result, _terminal, _response_id), do: result

  # A response whose provider context stays on its connection for the next
  # request anchored on it: one the provider completed, and one the client
  # interrupted, whose follow-up the provider resolves on the same connection
  # (findings#270 row 270-272). Every other terminal ends the response for good.
  defp context_kept_terminal?(terminal, _upstream_error_code) when terminal in @completed_terminals, do: true
  defp context_kept_terminal?("response.incomplete", "interrupted"), do: true
  defp context_kept_terminal?("response.incomplete", "steered"), do: true
  defp context_kept_terminal?(_terminal, _upstream_error_code), do: false

  @response_identity_event_types [
    "response.created",
    "response.in_progress",
    "response.queued",
    "response.completed",
    "response.done"
  ]
  @max_response_id_bytes 1_024

  defp maybe_put_response_id(%ReceiveState{response_id: nil} = receive_state, %{} = decoded) do
    response_id =
      case Map.fetch(decoded, "type") do
        {:ok, type} when type in @response_identity_event_types ->
          get_in(decoded, ["response", "id"])

        :error ->
          Map.get(decoded, "id")

        _typed_or_invalid ->
          nil
      end

    case bounded_response_id(response_id) do
      nil -> receive_state
      response_id -> %{receive_state | response_id: response_id}
    end
  end

  defp maybe_put_response_id(%ReceiveState{} = receive_state, _decoded), do: receive_state

  defp maybe_put_served_model(%ReceiveState{} = receive_state, %{} = decoded) do
    observer = ModelDeclarationObserver.observe(receive_state.model_observer || ModelDeclarationObserver.new(), decoded)
    %{receive_state | served_model: observer.first_model, model_observer: observer}
  end

  defp maybe_put_served_model(%ReceiveState{} = receive_state, _decoded),
    do: %{receive_state | model_observer: ModelDeclarationObserver.partial(receive_state.model_observer || ModelDeclarationObserver.new())}

  defp receive_model_usage(receive_state) do
    usage = receive_state.response_usage || ResponseUsage.from_websocket_body(receive_body(receive_state))
    ModelDeclarationObserver.put_usage(usage, receive_state.model_observer || ModelDeclarationObserver.new())
  end

  defp bounded_response_id(response_id) when is_binary(response_id) do
    response_id = String.trim(response_id)

    if response_id != "" and byte_size(response_id) <= @max_response_id_bytes,
      do: response_id
  end

  defp bounded_response_id(_response_id), do: nil

  defp put_websocket_frame_headers(%ReceiveState{} = receive_state, decoded) do
    case StreamProtocol.websocket_error_frame_headers(decoded) do
      headers when map_size(headers) > 0 ->
        %{
          receive_state
          | websocket_frame_headers: Map.merge(receive_state.websocket_frame_headers, headers)
        }

      _headers ->
        receive_state
    end
  end

  defp receive_body(%ReceiveState{body: body}), do: websocket_body(body)

  # A collected turn's body is the authoritative compact result rather than
  # error diagnostics, so a completed or provider-terminal collection reads the
  # whole accumulated turn. Every other result keeps the bounded diagnostic
  # suffix.
  defp terminal_body(%ReceiveState{collected_body: :disabled} = receive_state),
    do: receive_body(receive_state)

  defp terminal_body(%ReceiveState{collected_body: collected_body}),
    do: CollectedBody.read(collected_body)

  defp observe_native_client_retry(
         %ReceiveState{native_client_retry_observation: nil} = receive_state,
         _decoded
       ),
       do: receive_state

  defp observe_native_client_retry(
         %ReceiveState{native_client_retry_observation: observation} = receive_state,
         decoded
       ) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      receive_state
      | native_client_retry_observation: ClientRetry.observe_frame(observation, decoded, observed_at)
    }
  end

  defp final_client_retry_observation(%ReceiveState{native_client_retry_observation: nil}),
    do: nil

  defp final_client_retry_observation(%ReceiveState{
         native_client_retry_observation: observation
       }),
       do: ClientRetry.complete_without_terminal(observation)

  defp observe_frame(%ReceiveState{frame_observer: observer}, text, decoded) do
    case observer_arity(observer) do
      2 -> observe_frame_observer(fn -> observer.(text, decoded) end)
      1 -> observe_frame_observer(fn -> observer.(text) end)
      nil -> :ok
    end
  end

  defp observer_arity(observer) when is_function(observer, 2), do: 2
  defp observer_arity(observer) when is_function(observer, 1), do: 1
  defp observer_arity(_observer), do: nil

  defp observe_frame_observer(observer) do
    observer.()
  rescue
    exception -> report_frame_observer_failure(:error, exception.__struct__)
  catch
    kind, _reason when kind in [:throw, :exit] -> report_frame_observer_failure(kind, nil)
  end

  defp report_frame_observer_failure(failure_kind, exception_class) do
    Logger.warning(
      "upstream websocket frame observer failed operation=observe_frame " <>
        "failure_kind=#{failure_kind} exception_class=#{exception_class || "none"}"
    )
  end

  defp maybe_write_native_metadata(
         state,
         %ReceiveState{
           native_codex_response_control: %TurnSnapshot{models_etag: models_etag},
           native_metadata_emitted?: false
         } = receive_state
       ) do
    metadata = NativeCodexResponseControl.pooler_metadata_event(models_etag, state.headers)

    write_frame(
      receive_state.writer,
      CodexPooler.JSON.encode!(metadata),
      %TerminalDiscriminator{}
    )

    %{receive_state | native_metadata_emitted?: true}
  end

  defp maybe_write_native_metadata(_state, %ReceiveState{} = receive_state), do: receive_state

  defp write_frame(writer, text, terminal_discriminator) when is_function(writer, 2),
    do: writer.(text, terminal_discriminator)

  defp write_frame(writer, text, _terminal_discriminator) when is_function(writer, 1),
    do: writer.(text)

  defp write_frame(nil, _text, _terminal_discriminator), do: :ok

  defp map_message(text, %{} = decoded, mapper) when is_function(mapper, 1) do
    cond do
      mapper == (&StreamProtocol.normalize_public_openai_responses_json_message/1) ->
        StreamProtocol.normalize_public_openai_responses_json_message(text, decoded)

      mapper == (&StreamProtocol.canonicalize_native_codex_responses_json_message/1) ->
        StreamProtocol.canonicalize_native_codex_responses_json_message(text, decoded)

      mapper == (&StreamProtocol.canonicalize_codex_responses_json_message/1) ->
        StreamProtocol.canonicalize_codex_responses_json_message(text, decoded)

      true ->
        mapped = mapper.(text)
        {mapped, if(mapped == text, do: decoded, else: decode_text_frame(mapped))}
    end
  end

  defp map_message(text, decoded, mapper) when is_function(mapper, 1) do
    mapped = mapper.(text)
    {mapped, if(mapped == text, do: decoded, else: decode_text_frame(mapped))}
  end

  defp map_message(text, decoded, _mapper), do: {text, decoded}

  defp sanitize_downstream_text({text, %{"type" => "error", "error" => %{"code" => "unsupported_native_inflight_message"}} = decoded}, _snapshot), do: {text, decoded}

  defp sanitize_downstream_text({text, %{} = decoded}, %TurnSnapshot{}) when is_binary(text) do
    case NativeCodexResponseControl.sanitize_websocket_event(decoded) do
      :unchanged -> {text, decoded}
      {:changed, sanitized} -> {CodexPooler.JSON.encode!(sanitized), sanitized}
      {:error, :invalid_event} -> {text, decoded}
    end
  end

  # Without a Pooler snapshot the turn is a public /v1 origin (the snapshot is
  # built only for native Responses origins), and the public contract carries
  # no native controls: `headers` and `response.headers` are dropped on every
  # relayed event, not only the terminal (findings#239). A terminal event is
  # always re-encoded canonically, dropped headers or not, because the
  # retained terminal body is pinned to `encode!(decode!(text))` (usage
  # attribution); a non-terminal event keeps its bytes when nothing was
  # dropped. A relayed `codex.response.metadata` keeps only its ETag strip
  # because its header object is the event's payload.
  defp sanitize_downstream_text({text, %{} = decoded}, _native_snapshot) when is_binary(text) do
    case Map.get(decoded, "type") do
      type
      when type in ["response.completed", "response.failed", "response.incomplete", "error"] ->
        sanitized = public_event_without_headers(decoded)
        {CodexPooler.JSON.encode!(sanitized), sanitized}

      "codex.response.metadata" ->
        decoded
        |> NativeCodexResponseControl.strip_untrusted_models_etag()
        |> reencode_when_changed(text, decoded)

      _other ->
        decoded
        |> NativeCodexResponseControl.drop_event_headers()
        |> reencode_when_changed(text, decoded)
    end
  end

  defp sanitize_downstream_text({text, decoded}, _native_snapshot), do: {text, decoded}

  defp public_event_without_headers(decoded) do
    case NativeCodexResponseControl.drop_event_headers(decoded) do
      {:changed, sanitized} -> sanitized
      _unchanged -> decoded
    end
  end

  defp reencode_when_changed({:changed, sanitized}, _text, _decoded),
    do: {CodexPooler.JSON.encode!(sanitized), sanitized}

  defp reencode_when_changed(_unchanged, text, decoded), do: {text, decoded}

  defp decode_text_frame(text) do
    case CodexPooler.JSON.decode(text) do
      {:ok, %{} = decoded} -> decoded
      {:ok, _decoded} -> :non_object_json
      {:error, _reason} -> :undecodable
    end
  end

  defp send_frame(state, frame), do: WebsocketFrameWriter.send_frame(state, frame)

  defp websocket_body(body), do: RetainedBody.read(body)

  defp mint_socket(conn), do: Mint.HTTP.get_socket(conn)

  defp maybe_schedule_keepalive(%{conn: _conn} = state), do: schedule_keepalive(state)
  defp maybe_schedule_keepalive(state), do: state

  defp schedule_keepalive(state) do
    state = cancel_keepalive(state)
    token = make_ref()

    ref =
      Process.send_after(
        self(),
        {:upstream_websocket_keepalive, token},
        keepalive_interval_ms()
      )

    state
    |> Map.put(:keepalive_ref, ref)
    |> Map.put(:keepalive_token, token)
  end

  # `request_once/1` runs a turn in the caller's process, so a keepalive that
  # fired while that turn was finishing must not stay behind in the caller's
  # mailbox.
  defp cancel_keepalive(%{keepalive_ref: ref, keepalive_token: token} = state)
       when is_reference(ref) do
    if Process.cancel_timer(ref) == false do
      receive do
        {:upstream_websocket_keepalive, ^token} -> :ok
      after
        0 -> :ok
      end
    end

    state
    |> Map.delete(:keepalive_ref)
    |> Map.delete(:keepalive_token)
  end

  defp cancel_keepalive(state), do: state

  @spec unique_keepalive_payload() :: binary()
  defp unique_keepalive_payload do
    "codex-pooler:" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  @spec schedule_pong_deadline(map(), binary()) :: map()
  defp schedule_pong_deadline(state, payload) when is_binary(payload) do
    state = cancel_pong_deadline(state)
    token = make_ref()

    ref =
      Process.send_after(
        self(),
        {:upstream_websocket_pong_deadline, token},
        keepalive_pong_timeout_ms()
      )

    state
    |> Map.put(:keepalive_pong_ref, ref)
    |> Map.put(:keepalive_pong_token, token)
    |> Map.put(:keepalive_pong_payload, payload)
  end

  @spec cancel_pong_deadline(map()) :: map()
  defp cancel_pong_deadline(%{keepalive_pong_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)

    state
    |> Map.delete(:keepalive_pong_ref)
    |> Map.delete(:keepalive_pong_token)
    |> Map.delete(:keepalive_pong_payload)
  end

  defp cancel_pong_deadline(state), do: state

  @spec clear_matching_pong(map(), binary()) :: map()
  defp clear_matching_pong(%{keepalive_pong_payload: payload} = state, payload),
    do: cancel_pong_deadline(state)

  defp clear_matching_pong(state, _payload), do: state

  defp keepalive_interval_ms do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:keepalive_interval_ms, @default_keepalive_interval_ms)
    |> case do
      interval when is_integer(interval) and interval > 0 -> interval
      _interval -> @default_keepalive_interval_ms
    end
  end

  @spec keepalive_pong_timeout_ms() :: pos_integer()
  defp keepalive_pong_timeout_ms do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:keepalive_pong_timeout_ms, keepalive_interval_ms())
    |> case do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> keepalive_interval_ms()
    end
  end

  defp close_state(%{conn: conn} = state) do
    retire_socket(Mint.HTTP.get_socket(conn))
    {:ok, _conn} = Mint.HTTP.close(conn)
    close_connection_state(state)
  end

  defp close_state(state), do: close_connection_state(state)

  defp retire_socket(socket) when is_port(socket) do
    :inet.setopts(socket, linger: {true, 0})
  end

  # This connection is being retired. Do not wait for its queued output or
  # a TLS close notification behind that output; active sends keep their
  # original options. Shutdown marks TLS closed before Mint releases it.
  defp retire_socket(socket) do
    :ssl.setopts(socket, linger: {true, 0}, send_timeout: 50, send_timeout_close: true)
    :ssl.shutdown(socket, :read_write)
  end

  # A compaction collected on the closing connection and not confirmed yet
  # keeps its admission as the one confirmation it can still accept
  # (`confirm_closed_connection_collection/5`, findings#275). A Close that
  # arrives in the compaction's own terminal read closes the connection
  # before the collection is recorded, so a consumed compaction is kept too
  # and recorded as collected once its request succeeded
  # (`collect_closed_connection_compaction/2`). A first full-history
  # compaction not authorized yet keeps its result as the one authorization it
  # can still accept (`authorize_closed_connection_first_compact/4`, findings#270
  # row 270-200).
  defp close_connection_state(state) do
    if receive_state = Map.get(state, :native_response_steering_receive), do: NativeResponseSteering.closed(receive_state.native_response_steering, {receive_state.request_id, receive_state.attempt_id}, :upstream_websocket_closed_before_terminal)
    collection = admission_state(state)
    first_compact = Map.get(state, :first_compact_result)

    state
    |> cancel_keepalive()
    |> cancel_pong_deadline()
    |> clear_admission(:connection_closed)
    |> disconnected_state()
    |> then(&if(collection.phase in [:consumed_compact, :collected_unconfirmed], do: Map.put(&1, :closed_connection_collection, collection), else: &1))
    |> then(&if(match?(%FirstCompactResult{}, first_compact), do: Map.put(&1, :closed_connection_first_compact, first_compact), else: &1))
  end

  defp invalidate_state(state) do
    state
    |> close_state()
    |> Map.put(:reconnect_pending?, true)
  end

  defp invalidate_cancelled_request(state, receive_state, phase) do
    closed = invalidate_state(state)
    :ok = CloseDiagnostics.log_cancelled_request_close(state, receive_state, phase)
    closed
  end

  defp disconnected_state(state) do
    lifecycle =
      state
      |> connection_lifecycle_state()
      |> preserve_trace_sensitivity(state)
      |> preserve_connection_close_subscriber(state)
      |> preserve_admission_topology(state)
      |> preserve_closed_connection_collection(state)
      |> preserve_closed_connection_first_compact(state)

    if Map.get(state, :reconnect_pending?, false) do
      Map.put(lifecycle, :reconnect_pending?, true)
    else
      lifecycle
    end
  end

  # A collection that no acknowledgement confirmed within its bound reads as
  # ended, so an acknowledgement lost with its caller no longer refuses the
  # connection's next ordinary success and first full-history compaction after
  # the provider served and billed them (findings#270 row 270-249). A final
  # that did not come within its bound reads as ended too, so the ordinary
  # turn a late final runs as arms the next compaction again (row 270-289).
  # The next admission written replaces it.
  defp admission_state(state) do
    admission = Map.get(state, :native_compaction_admission, %NativeCompactionAdmission{phase: :cleared})

    case NativeCompactionAdmission.expire_unconsumed(admission, System.system_time(:millisecond)) do
      {:expired, cleared} -> cleared
      {:active, admission} -> admission
    end
  end

  defp put_admission(state, admission) do
    next = Map.put(state, :native_compaction_admission, admission)

    operation =
      case admission.phase do
        phase when phase in [:reserved_compact, :reserved_final] ->
          :reserve

        phase when phase in [:accounting_started_compact, :accounting_started_final] ->
          :accounting

        phase when phase in [:consumed_compact, :consumed_final] ->
          :consume

        :collected_unconfirmed ->
          :collect

        :pending_final ->
          :confirm

        :cleared ->
          :clear

        _ ->
          :ordinary_success
      end

    observation = observe_admission(state, next, operation, :success)

    if admission.phase == :cleared,
      do: Map.put(next, :native_compaction_last_clear, observation),
      else: next
  end

  # The provider closed the connection a compaction ran on between its
  # collection and its confirmation (findings#275). The close cleared the
  # admission, which kept only the collection it waited to confirm; a
  # confirmation that collection accepts is answered `:ok` with nothing armed,
  # so the client gets the compaction it was billed for and its final runs as
  # an ordinary turn on the next connection. Any other confirmation is refused
  # as before.
  defp confirm_closed_connection_collection(state, reason, digest, confirmation, expires_at_ms) do
    with %NativeCompactionAdmission{phase: :cleared} <- admission_state(state),
         %NativeCompactionAdmission{phase: :collected_unconfirmed} = collection <- Map.get(state, :closed_connection_collection),
         {:ok, _unarmed} <- NativeCompactionAdmission.confirm_compact(collection, digest, confirmation, expires_at_ms) do
      :ok = emit_compact_acknowledged(collection.capability)
      {:reply, :ok, Map.delete(state, :closed_connection_collection)}
    else
      _refused -> {:reply, {:error, reason}, state}
    end
  end

  # The provider closed the connection a first full-history compaction ran on
  # between its collection and its authorization (findings#270 row 270-200).
  # The close kept the compaction's result as the one authorization it can
  # still accept: that authorization succeeds once, and the admission it opens
  # stays with the closed connection (`closed_connection_collection`), never
  # the session's, where the collection is recorded
  # (`record_closed_connection_first_collection/2`) and confirmed with nothing
  # armed (`confirm_closed_connection_collection/5`). Any other authorization
  # is refused as before.
  defp authorize_closed_connection_first_compact(state, binding, receipt, refusal) do
    with %FirstCompactResult{} = kept <- Map.get(state, :closed_connection_first_compact),
         true <- kept == receipt and receipt.owner == self() and FirstCompactResult.binding_matches?(receipt, binding),
         {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
         {:ok, admission, provenance} <- NativeCompactionAdmission.authorize_first_compact_collection(admission, receipt.result_ref) do
      collection = %{admission | compaction_item_digest: receipt.item_digest}
      {:reply, {:ok, provenance}, state |> Map.delete(:closed_connection_first_compact) |> Map.put(:closed_connection_collection, collection)}
    else
      _refused -> {:reply, refusal, state}
    end
  end

  defp record_closed_connection_first_collection(state, provenance) do
    case NativeCompactionAdmission.record_first_compact_collected(state.closed_connection_collection, provenance, System.system_time(:millisecond)) do
      {:ok, collected} -> {:reply, :ok, Map.put(state, :closed_connection_collection, collected)}
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, _cleared} -> {:reply, {:error, reason}, state}
    end
  end

  defp collect_closed_connection_compaction(state, %Request{native_compaction_capability: %Capability{} = capability}) do
    with %NativeCompactionAdmission{phase: :consumed_compact} = consumed <- Map.get(state, :closed_connection_collection),
         true <- NativeCompactionAdmission.owns_capability?(consumed, capability),
         {:ok, collected} <- NativeCompactionAdmission.record_compact_collected(consumed, System.system_time(:millisecond)) do
      Map.put(state, :closed_connection_collection, collected)
    else
      _other -> state
    end
  end

  defp collect_closed_connection_compaction(state, _request), do: state

  # The connection a reserved compaction was bound to closed before the
  # reservation's accounting started, and the close ended the admission with it
  # (`close_connection_state/1`, `connection_closed`). Starting that accounting
  # used to answer `invalid_transition`, which the runtime turned into `500
  # gateway_reservation_failed` with two `[error]` lines for what is the close
  # the reservation's own check answers with the retryable 503 (findings#275,
  # findings#284). The step now says `connection_closed`, and the runtime's
  # clear of that capability finds nothing left to clear.
  #
  # `Capability.t()` narrows the binding to a `Binding`, so Dialyzer marks the
  # fallback unreachable, but a malformed capability (no binding) still reaches
  # this step at runtime and must keep the session alive.
  @dialyzer {:no_match, closed_under_capability?: 2}
  defp closed_under_capability?(state, %Capability{binding: %Binding{lifecycle_id: lifecycle_id, generation: generation}} = capability),
    do: not NativeCompactionAdmission.owns_capability?(admission_state(state), capability) and live_connection_state(state) != %{lifecycle_id: lifecycle_id, generation: generation}

  defp closed_under_capability?(_state, _capability), do: false

  # The open connection, generation nil between connections.
  defp live_connection_state(state) do
    generation = if Map.has_key?(state, :conn) and state.generation > 0, do: state.generation
    %{lifecycle_id: state.lifecycle_id, generation: generation}
  end

  defp clear_rejected_capability(state, capability, reason) do
    if NativeCompactionAdmission.owns_capability?(admission_state(state), capability) do
      clear_admission(state, reason)
    else
      observe_admission(state, state, :reject, :stale_capability)
      state
    end
  end

  # No default reason: every clear names its cause, so a lifecycle `:clear`
  # observation never reports a request rejection that did not happen
  # (findings#258 rows 258-50/258-60).
  defp clear_admission(state, reason) do
    next =
      state
      |> Map.delete(:native_compaction_admission)
      |> Map.delete(:first_compact_result)
      |> Map.delete(:ordinary_success_result)

    observation = observe_admission(state, next, :clear, reason)
    Map.put(next, :native_compaction_last_clear, observation)
  end

  defp observe_admission(before_state, after_state, operation, reason) do
    observation =
      NativeCompactionLifecycleObservation.observe(
        Map.get(before_state, :native_compaction_admission),
        Map.get(after_state, :native_compaction_admission),
        operation,
        reason,
        Map.get(before_state, :admission_topology, :direct)
      )

    Logger.debug(fn -> "native compaction lifecycle " <> inspect(observation) end)

    :telemetry.execute(
      [:codex_pooler, :gateway, :native_compaction, :lifecycle],
      %{count: 1},
      observation
    )

    observation
  end

  defp put_trace_sensitivity(state, sensitivity) do
    if sensitivity == :sensitive,
      do: state,
      else: Map.put(state, :native_compaction_trace_sensitivity, sensitivity)
  end

  defp preserve_trace_sensitivity(lifecycle, state) do
    case Map.fetch(state, :native_compaction_trace_sensitivity) do
      {:ok, sensitivity} -> Map.put(lifecycle, :native_compaction_trace_sensitivity, sensitivity)
      :error -> lifecycle
    end
  end

  # Only a pid subscribes, so a session started without one keeps exactly the
  # state it always had.
  defp put_connection_close_subscriber(state, subscriber) when is_pid(subscriber),
    do: Map.put(state, :connection_close_subscriber, subscriber)

  defp put_connection_close_subscriber(state, _subscriber), do: state

  defp preserve_connection_close_subscriber(lifecycle, state) do
    case Map.fetch(state, :connection_close_subscriber) do
      {:ok, subscriber} -> Map.put(lifecycle, :connection_close_subscriber, subscriber)
      :error -> lifecycle
    end
  end

  # Only an owner's session carries the key, so every other session keeps
  # exactly the state it always had.
  defp put_admission_topology(state, :forwarded), do: Map.put(state, :admission_topology, :forwarded)
  defp put_admission_topology(state, _admission_topology), do: state

  defp preserve_admission_topology(lifecycle, state) do
    case Map.fetch(state, :admission_topology) do
      {:ok, admission_topology} -> Map.put(lifecycle, :admission_topology, admission_topology)
      :error -> lifecycle
    end
  end

  defp preserve_closed_connection_collection(lifecycle, state) do
    case Map.fetch(state, :closed_connection_collection) do
      {:ok, collection} -> Map.put(lifecycle, :closed_connection_collection, collection)
      :error -> lifecycle
    end
  end

  defp preserve_closed_connection_first_compact(lifecycle, state) do
    case Map.fetch(state, :closed_connection_first_compact) do
      {:ok, first_compact} -> Map.put(lifecycle, :closed_connection_first_compact, first_compact)
      :error -> lifecycle
    end
  end

  defp emit_reservation_observations(%Capability{} = capability) do
    # One successful owner reserve operation proves both issuance and the
    # immediately stored reserved state. Neither fact is emitted on failure.
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :owner_issued)
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :reserved)

    _trace =
      NativeCompactionTrace.emit_capability(:capability_reserved, capability, %{
        pid_role: :upstream_session,
        upstream_pid: self(),
        branch: :direct_owner
      })

    :ok
  end

  defp reservation_snapshot(state, admission) do
    with %{phase: phase, binding: %Binding{} = binding} when phase in [:pending_compact, :pending_final] <- admission,
         :ok <- validate_direct_binding(state, binding),
         true <- binding.serving_mode in [:full, :lite] do
      {:ok, Map.take(binding, [:lifecycle_id, :generation, :serving_mode])}
    else
      _invalid -> {:error, :owner_unavailable}
    end
  end

  defp validate_direct_binding(state, %Binding{topology: %Direct{}} = binding) do
    if binding.lifecycle_id == state.lifecycle_id and binding.generation == state.generation and
         state.generation > 0 do
      :ok
    else
      {:error, :binding_mismatch}
    end
  end

  defp validate_direct_binding(_state, %Binding{}), do: {:error, :binding_mismatch}

  defp status_reason_class(%module{}) when is_atom(module), do: {:exception, module}
  defp status_reason_class(reason) when is_atom(reason), do: {:reason, reason}
  defp status_reason_class({reason, _detail}) when is_atom(reason), do: {:reason, reason}
  defp status_reason_class(_reason), do: :unknown

  defp status_message_class({:request, %Request{}}), do: :request
  defp status_message_class({:send_text, _payload}), do: :send_text
  defp status_message_class(:invalidate_connection), do: :invalidate_connection
  defp status_message_class(:connection_lifecycle_snapshot), do: :lifecycle_snapshot
  defp status_message_class(:live_connection), do: :live_connection
  defp status_message_class(:compaction_admission_phase), do: :admission_phase
  defp status_message_class(:clear_compaction_admission), do: :admission_clear

  defp status_message_class({operation, _arg})
       when operation in [
              :record_first_compact_collected,
              :acknowledge_compact_finalization
            ],
       do: operation

  defp status_message_class({operation, _arg1, _arg2})
       when operation in [
              :arm_compact,
              :authorize_first_compact_collection,
              :mark_compaction_accounting_started,
              :cancel_compaction_reservation
            ],
       do: operation

  defp status_message_class({:reserve_compaction, _phase, _binding, _control_ref, _now_ms}),
    do: :reserve_compaction

  defp status_message_class({:upstream_websocket_keepalive, _token}),
    do: :keepalive

  defp status_message_class({:upstream_websocket_pong_deadline, _token}),
    do: :pong_deadline

  defp status_message_class(_message), do: :transport_message

  defp status_state(state) do
    lifecycle = connection_lifecycle_state(state)

    Map.merge(lifecycle, %{
      connected?: Map.has_key?(state, :conn),
      reconnect_pending?: Map.get(state, :reconnect_pending?, false) == true,
      request_active?: Map.has_key?(state, :current_request_diagnostics),
      keepalive_pending?: Map.has_key?(state, :keepalive_ref),
      pong_pending?: Map.has_key?(state, :keepalive_pong_ref),
      admission_phase: NativeCompactionAdmission.phase(admission_state(state))
    })
  end
end
