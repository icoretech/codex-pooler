defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession do
  @moduledoc false

  use GenServer

  require Elixir.Logger

  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.Gateway.{OperationalSettings, OperationalStatus}
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionLifecycleObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission
  alias CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult
  alias CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.{
    Callbacks,
    DownstreamState,
    Logger,
    Persistence
  }

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket.OwnerCleanup

  defmodule ForwardedSendWitnessState do
    @moduledoc false

    @enforce_keys [:digest, :binding, :control_ref, :downstream, :status]
    defstruct [:digest, :binding, :control_ref, :downstream, :status]
  end

  @registry __MODULE__.Registry
  @dev_features_build_enabled Application.compile_env(
                                :codex_pooler,
                                :dev_features_build_enabled,
                                false
                              )
  @task_supervisor __MODULE__.TaskSupervisor
  @restore_downstream_keys [:correlation_id, :epoch, :pid]
  @stable_downstream_keys [:active_turn_reconnect? | @restore_downstream_keys]
  @public_per_call_downstream_keys [:owner_turn_id | @stable_downstream_keys]
  @terminal_delivery_timeout_ms 1_000
  @handoff_soft_timeout_ms 1_000
  @handoff_absolute_timeout_ms 5_000
  @terminal_result_types ["response.completed", "response.failed", "response.incomplete", "error"]

  # The one-shot collection result belongs to this existing owner lifecycle.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :first_compact_result,
    :ordinary_success_result,
    :codex_session_id,
    :owner_lease_token,
    :owner_instance_id,
    :downstream,
    :downstream_monitor,
    :downstream_epoch,
    :process_generation,
    :next_turn_descriptor,
    :upstream_pid,
    :callbacks,
    :active_turn,
    :termination_cleanup_witness,
    :terminal_winner_detach,
    :pending_handoff,
    :suspended_replay,
    :persistence,
    :request_id,
    :draining?,
    :retire_after_active_turn?,
    :owner_exit_cause,
    :idle_shutdown_ms,
    :idle_shutdown_ref,
    :owner_renewal_ms,
    :owner_renewal_delay,
    :owner_renewal_ref,
    :handoff_soft_timeout_ms,
    :handoff_absolute_timeout_ms,
    :native_compaction_trace_sensitivity,
    :native_compaction_admission,
    :native_compaction_admission_downstream,
    :forwarded_send_witness,
    provisional_issuances: []
  ]

  @type downstream :: %{
          required(:pid) => pid(),
          required(:epoch) => pos_integer(),
          required(:correlation_id) => binary(),
          optional(:active_turn_reconnect?) => boolean()
        }
  @type per_call_downstream :: %{
          required(:pid) => pid(),
          required(:epoch) => pos_integer(),
          required(:correlation_id) => binary(),
          required(:owner_turn_id) => pid(),
          optional(:active_turn_reconnect?) => boolean()
        }

  @type start_result :: {:ok, pid()} | {:ok, pid(), :existing} | {:error, term()}
  @type request_result ::
          :ok
          | {:ok, term()}
          | {:error, UpstreamWebsocketSession.request_failure()}
          | {:error, WebsocketOwnerContract.owner_error() | term()}
  @type submitted_request_result ::
          request_result() | {:websocket_owner_submission_accepted, request_result()}

  @type owner_status :: %{
          required(:codex_session_id) => binary(),
          required(:owner_lease_token) => binary(),
          required(:owner_instance_id) => binary(),
          required(:upstream_alive?) => boolean(),
          required(:draining?) => boolean(),
          required(:active_turn?) => boolean()
        }

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
    if OperationalStatus.draining?() do
      {:error, :owner_drained}
    else
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
  end

  defp start_owner(_opts, 0), do: {:error, :owner_unavailable}

  defp existing_owner_result(pid, opts, attempts) when is_pid(pid) do
    cond do
      OperationalStatus.draining?() ->
        {:error, :owner_drained}

      not Process.alive?(pid) ->
        Logger.owner_lookup_missed(Keyword.fetch!(opts, :codex_session_id), :dead_pid, pid, opts)
        :erlang.yield()
        start_owner(opts, attempts - 1)

      true ->
        case owner_reuse_status(pid, opts) do
          :draining ->
            {:error, :owner_drained}

          :reusable ->
            Logger.owner_reused(pid, opts)
            {:ok, pid, :existing}

          :stale ->
            Logger.owner_stale_replaced(pid, opts)
            :ok = stop_stale_owner(pid)
            :erlang.yield()
            start_owner(opts, attempts - 1)
        end
    end
  end

  @spec drain_owner(GenServer.server()) :: :ok | {:error, term()}
  def drain_owner(owner), do: GenServer.call(owner, :drain, owner_call_timeout())

  @spec begin_drain(GenServer.server()) :: :ok
  def begin_drain(owner), do: GenServer.cast(owner, :begin_drain)

  @spec owner_status(GenServer.server()) :: {:ok, owner_status()}
  def owner_status(owner), do: GenServer.call(owner, :owner_status, owner_call_timeout())

  @spec touch_replay_liveness(GenServer.server(), map(), timeout()) ::
          :ok | {:error, :owner_unavailable}
  def touch_replay_liveness(owner, reference, timeout \\ owner_call_timeout()),
    do: GenServer.call(owner, {:touch_replay_liveness, reference}, timeout)

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
  def attach_downstream(owner, downstream), do: attach_downstream(owner, downstream, [])

  @spec attach_downstream(GenServer.server(), map(), keyword()) ::
          {:ok, downstream()} | {:error, term()}
  def attach_downstream(owner, %{pid: pid, correlation_id: correlation_id}, opts)
      when is_pid(pid) and is_binary(correlation_id) and is_list(opts) do
    GenServer.call(
      owner,
      {:attach_downstream, pid, correlation_id, opts},
      owner_call_timeout()
    )
  end

  @spec restore_downstream(GenServer.server(), downstream()) ::
          {:ok, downstream()} | {:error, term()}
  def restore_downstream(
        owner,
        %{pid: pid, epoch: epoch, correlation_id: correlation_id} = downstream
      )
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) do
    if exact_keys?(downstream, @restore_downstream_keys) do
      GenServer.call(owner, {:restore_downstream, downstream}, owner_call_timeout())
    else
      {:error, :stale_downstream}
    end
  end

  def restore_downstream(_owner, _downstream), do: {:error, :stale_downstream}

  @spec detach_downstream(GenServer.server(), map()) ::
          WebsocketOwnerContract.detach_result()
  def detach_downstream(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id})
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) do
    GenServer.call(owner, {:detach_downstream, pid, epoch, correlation_id}, owner_call_timeout())
  end

  @spec cancel_downstream(GenServer.server(), per_call_downstream(), :owner_drained) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def cancel_downstream(
        owner,
        %{
          pid: pid,
          epoch: epoch,
          correlation_id: correlation_id,
          owner_turn_id: owner_turn_id
        },
        :owner_drained = reason
      )
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) and
             is_pid(owner_turn_id) do
    GenServer.call(
      owner,
      {:cancel_downstream, pid, epoch, correlation_id, owner_turn_id, reason},
      owner_call_timeout()
    )
  end

  @type reconnect_preflight_result ::
          {:ok, :dispatch | :same_turn_replay}
          | {:ok, :replacement_handoff | :duplicate_replacement, reference()}
          | {:error, WebsocketOwnerContract.owner_error()}

  @spec preflight_reconnect(GenServer.server(), downstream(), <<_::256>>, reference()) ::
          reconnect_preflight_result()
  def preflight_reconnect(owner, downstream, semantic_turn_key, control_ref)
      when is_map(downstream) and is_binary(semantic_turn_key) and
             byte_size(semantic_turn_key) == 32 and is_reference(control_ref) do
    GenServer.call(
      owner,
      {:preflight_reconnect, downstream, semantic_turn_key, control_ref},
      owner_call_timeout()
    )
  end

  def preflight_reconnect(_owner, _downstream, _semantic_turn_key, _control_ref),
    do: {:error, :owner_busy}

  @spec cancel_reconnect(GenServer.server(), downstream(), reference()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def cancel_reconnect(owner, downstream, control_ref)
      when is_map(downstream) and is_reference(control_ref) do
    GenServer.call(owner, {:cancel_reconnect, downstream, control_ref}, owner_call_timeout())
  end

  def cancel_reconnect(_owner, _downstream, _control_ref), do: {:error, :stale_downstream}

  @spec reconnect_control_v2(GenServer.server(), RemoteReconnectControlV2.t()) :: term()
  def reconnect_control_v2(owner, %RemoteReconnectControlV2{} = control),
    do: GenServer.call(owner, {:reconnect_control_v2, control}, owner_call_timeout())

  def reconnect_control_v2(_owner, _control), do: {:error, :owner_unavailable}

  @spec begin_suspend(GenServer.server(), map()) :: :ok | {:error, atom()}
  def begin_suspend(owner, descriptor) when is_map(descriptor),
    do: GenServer.call(owner, {:begin_suspend, descriptor}, owner_call_timeout())

  @spec record_active_downstream_loss(GenServer.server(), downstream()) ::
          :reattachable | {:error, atom()}
  def record_active_downstream_loss(owner, downstream) when is_map(downstream),
    do: GenServer.call(owner, {:record_active_downstream_loss, downstream}, owner_call_timeout())

  @spec prepare_next_replay_descriptor(GenServer.server(), downstream(), map()) ::
          :ok | {:error, atom()}
  def prepare_next_replay_descriptor(owner, downstream, descriptor)
      when is_map(downstream) and is_map(descriptor),
      do:
        GenServer.call(
          owner,
          {:prepare_next_replay_descriptor, downstream, descriptor},
          owner_call_timeout()
        )

  @type admission_result ::
          {:ok,
           NativeCompactionAdmission.t()
           | NativeCompactionAdmission.Capability.t()
           | NativeCompactionAdmission.FirstCompactCollection.t()
           | nil}
          | {:error, atom()}

  @spec admission_control(GenServer.server(), WebsocketOwnerAdmissionControlV1.t()) ::
          admission_result()
  def admission_control(owner, %WebsocketOwnerAdmissionControlV1{} = control) do
    GenServer.call(owner, {:admission_control_v1, control}, owner_call_timeout())
  end

  def admission_control(_owner, _control), do: {:error, :owner_unavailable}

  @spec issue_forwarded_send_witness(
          GenServer.server(),
          downstream(),
          NativeCompactionAdmission.Capability.t(),
          non_neg_integer()
        ) :: {:ok, ForwardedSendWitnessV1.t()} | {:error, atom()}
  def issue_forwarded_send_witness(owner, downstream, capability, now_ms)
      when is_map(downstream) and is_integer(now_ms) and now_ms >= 0 do
    GenServer.call(
      owner,
      {:issue_forwarded_send_witness_v1, downstream, capability, now_ms},
      owner_call_timeout()
    )
  end

  def issue_forwarded_send_witness(_owner, _downstream, _capability, _now_ms),
    do: {:error, :invalid_input}

  @spec redeem_forwarded_send(
          GenServer.server(),
          ForwardedSendWitnessV1.t(),
          UpstreamWebsocketSession.connection_lifecycle_state(),
          :full | :lite
        ) :: :ok | {:error, atom()}
  def redeem_forwarded_send(owner, witness, live_lifecycle_snapshot, serving_mode)
      when is_map(live_lifecycle_snapshot) and serving_mode in [:full, :lite] do
    redeem_forwarded_send(
      owner,
      witness,
      live_lifecycle_snapshot,
      serving_mode,
      owner_call_timeout()
    )
  end

  def redeem_forwarded_send(_owner, _witness, _snapshot, _mode),
    do: {:error, :invalid_input}

  @doc false
  @spec redeem_forwarded_send(
          GenServer.server(),
          ForwardedSendWitnessV1.t(),
          UpstreamWebsocketSession.connection_lifecycle_state(),
          :full | :lite,
          pos_integer()
        ) :: :ok | {:error, atom()}
  def redeem_forwarded_send(
        owner,
        witness,
        live_lifecycle_snapshot,
        serving_mode,
        timeout_ms
      )
      when is_map(live_lifecycle_snapshot) and serving_mode in [:full, :lite] and
             is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(
      owner,
      {:redeem_forwarded_send_v1, witness, live_lifecycle_snapshot, serving_mode},
      timeout_ms
    )
  catch
    :exit, reason ->
      if expected_redemption_call_exit?(reason) do
        {:error, :forwarded_send_witness_rejected}
      else
        :erlang.raise(:exit, reason, __STACKTRACE__)
      end
  end

  def redeem_forwarded_send(_owner, _witness, _snapshot, _mode, _timeout_ms),
    do: {:error, :invalid_input}

  defp expected_redemption_call_exit?({reason, {GenServer, :call, _details}}),
    do: expected_redemption_call_exit?(reason)

  defp expected_redemption_call_exit?(reason)
       when reason in [:noproc, :normal, :shutdown, :timeout, :nodedown],
       do: true

  defp expected_redemption_call_exit?({:shutdown, _details}), do: true
  defp expected_redemption_call_exit?({:nodedown, _node}), do: true
  defp expected_redemption_call_exit?({:timeout, _details}), do: true
  defp expected_redemption_call_exit?({:noproc, _details}), do: true
  defp expected_redemption_call_exit?(_reason), do: false

  defp apply_admission_control(state, %WebsocketOwnerAdmissionControlV1{} = control) do
    with :ok <- validate_admission_control(control),
         :ok <- require_admission_downstream(state, control.downstream) do
      execute_admission_control(state, control)
    else
      {:error, reason} ->
        observe_admission(state, state, :reject, reason)
        {:error, reason, state}
    end
  end

  defp apply_admission_control(state, _control),
    do: {:error, :owner_unavailable, clear_native_compaction_admission(state)}

  defp execute_admission_control(state, %{action: :snapshot}) do
    {:ok, state.native_compaction_admission, state}
  end

  defp execute_admission_control(state, %{
         action: :record_ordinary_success,
         binding: binding,
         expires_at_ms: expires_at_ms,
         first_compact_collection: %OrdinarySuccessResult{} = receipt,
         downstream: downstream
       }) do
    with :ok <- require_forwarded_binding(state, downstream, binding),
         true <- state.ordinary_success_result == receipt and receipt.owner == self(),
         true <- OrdinarySuccessResult.binding_matches?(receipt, binding),
         true <- is_nil(state.active_turn),
         true <-
           is_nil(state.native_compaction_admission) or
             state.native_compaction_admission.phase in [
               :cleared,
               :ordinary_success,
               :pending_compact,
               :consumed_final
             ],
         true <-
           UpstreamWebsocketSession.connection_lifecycle_snapshot(state.upstream_pid) ==
             receipt.lifecycle,
         {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
         {:ok, admission} <- NativeCompactionAdmission.arm_compact(admission, expires_at_ms) do
      {:ok, admission,
       %{
         state
         | native_compaction_admission: admission,
           first_compact_result: nil,
           ordinary_success_result: nil,
           native_compaction_admission_downstream: stable_downstream(downstream)
       }}
    else
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_transition, state}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :reserve} = control
       ) do
    with :ok <- require_forwarded_binding(state, control.downstream, control.binding),
         {:ok, next, capability} <-
           NativeCompactionAdmission.reserve(
             admission,
             control.phase,
             control.binding,
             control.control_ref,
             control.now_ms
           ) do
      :ok = emit_reservation_observations(capability)
      {:ok, capability, put_admission(state, next)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp execute_admission_control(state, %{
         action: :authorize_first_compact_collection,
         binding: binding,
         control_ref: control_ref,
         first_compact_collection: %NativeCompactionAdmission.FirstCompactResult{} = receipt,
         downstream: downstream
       }) do
    with :ok <- require_forwarded_binding(state, downstream, binding),
         true <- state.first_compact_result == receipt and receipt.owner == self(),
         true <- receipt.result_ref == control_ref,
         true <- NativeCompactionAdmission.FirstCompactResult.binding_matches?(receipt, binding),
         true <- is_nil(state.active_turn),
         true <-
           is_nil(state.native_compaction_admission) or
             state.native_compaction_admission.phase in [
               :cleared,
               :ordinary_success,
               :pending_compact
             ],
         true <-
           UpstreamWebsocketSession.connection_lifecycle_snapshot(state.upstream_pid) == %{
             lifecycle_id: binding.lifecycle_id,
             generation: binding.generation
           },
         {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
         {:ok, admission, provenance} <-
           NativeCompactionAdmission.authorize_first_compact_collection(
             admission,
             control_ref
           ) do
      {:ok, provenance,
       %{
         state
         | native_compaction_admission: %{admission | compaction_item_digest: receipt.item_digest},
           first_compact_result: nil,
           native_compaction_admission_downstream: stable_downstream(downstream)
       }}
    else
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_transition, state}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :record_first_compact_collected} = control
       ) do
    case NativeCompactionAdmission.record_first_compact_collected(
           admission,
           control.first_compact_collection
         ) do
      {:ok, next} ->
        {:ok, next, put_admission(state, next)}

      {:error, reason} ->
        {:error, reason, state}

      {:error, reason, next} ->
        {:error, reason,
         if(admission.first_compact_collection == control.first_compact_collection,
           do: put_admission(state, next),
           else: state
         )}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :mark_accounting_started} = control
       ) do
    case NativeCompactionAdmission.mark_accounting_started(
           admission,
           control.capability,
           control.now_ms
         ) do
      {:ok, next} ->
        :ok =
          NativeCompactionAuthorizationObservation.emit_capability(
            control.capability,
            :accounting_started
          )

        _trace =
          NativeCompactionTrace.emit_capability(:accounting_started, control.capability, %{
            pid_role: :owner_session,
            owner_pid: self()
          })

        {:ok, next, put_admission(state, next)}

      {:error, reason} ->
        :ok =
          NativeCompactionAuthorizationObservation.log_accounting_rejection(
            admission,
            control.capability,
            :forwarded,
            reason
          )

        {:error, reason, clear_rejected_capability(state, control.capability, reason)}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: nil} = state,
         %{action: :mark_accounting_started, capability: capability}
       ) do
    :ok =
      NativeCompactionAuthorizationObservation.log_accounting_rejection(
        nil,
        capability,
        :forwarded,
        :invalid_transition
      )

    {:error, :invalid_transition, clear_native_compaction_admission(state)}
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :cancel} = control
       ) do
    case NativeCompactionAdmission.cancel(
           admission,
           control.capability,
           control.disposition,
           control.now_ms
         ) do
      {:ok, next} ->
        {:ok, next, put_admission(state, next)}

      {:error, :committed, next} ->
        {:error, :committed, put_admission(state, next)}

      {:error, reason} ->
        {:error, reason, clear_rejected_capability(state, control.capability, reason)}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :finalization_ack, success?: true} = control
       ) do
    compact_capability = admission.capability

    case NativeCompactionAdmission.confirm_compact(
           admission,
           control.compaction_item_digest,
           control.confirmation,
           control.expires_at_ms
         ) do
      {:ok, next} ->
        :ok = emit_compact_acknowledged(compact_capability)

        {:ok, next, put_admission(state, next)}

      {:error, reason, next} ->
        {:error, reason,
         if(owns_confirmation?(admission, control.confirmation),
           do: put_admission(state, next),
           else: state
         )}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp execute_admission_control(state, %{action: :finalization_ack, success?: false}) do
    {:ok, nil, clear_native_compaction_admission(state)}
  end

  defp execute_admission_control(state, %{
         action: :clear,
         capability: %NativeCompactionAdmission.Capability{} = capability
       }) do
    case NativeCompactionAdmission.clear_owned(
           state.native_compaction_admission || %NativeCompactionAdmission{phase: :cleared},
           capability
         ) do
      {:ok, _cleared} ->
        {:ok, nil, clear_native_compaction_admission(state)}

      {:error, reason} ->
        observe_admission(state, state, :reject, :stale_capability)
        {:error, reason, state}
    end
  end

  defp execute_admission_control(state, %{action: :clear}) do
    {:ok, nil, clear_native_compaction_admission(state)}
  end

  defp execute_admission_control(state, _control),
    do: {:error, :invalid_transition, clear_native_compaction_admission(state)}

  defp validate_admission_control(control) do
    case WebsocketOwnerAdmissionControlV1.validate(control) do
      :ok -> :ok
      {:error, _reason} -> {:error, :owner_unavailable}
    end
  end

  defp require_admission_downstream(state, downstream) do
    if admission_downstream_matches?(state.downstream, downstream) and
         admission_downstream_matches?(state.native_compaction_admission_downstream, downstream) do
      :ok
    else
      {:error, :stale_downstream}
    end
  end

  defp admission_downstream_matches?(nil, _downstream), do: true

  defp admission_downstream_matches?(stored, downstream) do
    stored.pid == downstream.pid and stored.epoch == downstream.epoch
  end

  defp require_forwarded_binding(state, downstream, %NativeCompactionAdmission.Binding{
         topology: %NativeCompactionAdmission.Topology.Forwarded{} = topology
       }) do
    if WebsocketOwnerAdmissionControlV1.topology_matches?(
         topology,
         state.owner_instance_id,
         state.owner_lease_token,
         downstream.epoch
       ) do
      :ok
    else
      {:error, :binding_mismatch}
    end
  end

  defp require_forwarded_binding(_state, _downstream, _binding),
    do: {:error, :binding_mismatch}

  defp stable_downstream(downstream), do: Map.take(downstream, @restore_downstream_keys)

  defp put_admission(state, %NativeCompactionAdmission{} = admission) do
    next = %{state | native_compaction_admission: admission}

    operation =
      case admission.phase do
        phase when phase in [:reserved_compact, :reserved_final] ->
          :reserve

        phase when phase in [:accounting_started_compact, :accounting_started_final] ->
          :accounting

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
      do: remember_last_clear(next, observation),
      else: next
  end

  defp emit_reservation_observations(%NativeCompactionAdmission.Capability{} = capability) do
    # One successful owner reserve operation proves both issuance and the
    # immediately stored reserved state. Neither fact is emitted on failure.
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :owner_issued)
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :reserved)

    _trace =
      NativeCompactionTrace.emit_capability(:capability_reserved, capability, %{
        pid_role: :owner_session,
        owner_pid: self(),
        branch: :forwarded_owner
      })

    :ok
  end

  defp emit_final_completed(%{
         native_compaction_admission: %NativeCompactionAdmission{phase: :consumed_final}
       }),
       do: NativeCompactionAuthorizationObservation.emit(:final_acknowledged, :forwarded)

  defp emit_final_completed(_state), do: :ok

  defp clear_rejected_capability(state, capability, reason) do
    if NativeCompactionAdmission.owns_capability?(state.native_compaction_admission, capability),
      do: clear_native_compaction_admission(state, reason),
      else: state
  end

  defp owns_confirmation?(%{capability: %{control_ref: ref}}, %{source_control_ref: ref}),
    do: true

  defp owns_confirmation?(%{first_compact_collection: %{control_ref: ref}}, %{
         source_control_ref: ref
       }),
       do: true

  defp owns_confirmation?(_admission, _confirmation), do: false

  defp clear_native_compaction_admission(state, reason \\ :request_rejected) do
    next = %{
      state
      | native_compaction_admission: nil,
        first_compact_result: nil,
        ordinary_success_result: nil,
        native_compaction_admission_downstream: nil,
        forwarded_send_witness: nil
    }

    observation = observe_admission(state, next, :clear, reason)
    remember_last_clear(next, observation)
  end

  defp remember_last_clear(state, observation) do
    Process.put({__MODULE__, :native_compaction_last_clear}, observation)
    state
  end

  defp observe_admission(before_state, after_state, operation, reason) do
    observation =
      NativeCompactionLifecycleObservation.observe(
        before_state.native_compaction_admission,
        after_state.native_compaction_admission,
        operation,
        reason,
        :forwarded
      )

    Elixir.Logger.debug(fn -> "native compaction lifecycle " <> inspect(observation) end)

    :telemetry.execute(
      [:codex_pooler, :gateway, :native_compaction, :lifecycle],
      %{count: 1},
      observation
    )

    observation
  end

  defp issue_forwarded_send_witness_now(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         downstream,
         %NativeCompactionAdmission.Capability{} = capability,
         now_ms
       ) do
    with :ok <- require_admission_downstream(state, downstream),
         {:ok, consumed} <- NativeCompactionAdmission.consume(admission, capability, now_ms),
         {:ok, witness} <- ForwardedSendWitnessV1.issue(capability, downstream, now_ms) do
      :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :consumed)

      _trace =
        NativeCompactionTrace.emit_capability(:capability_consumed, capability, %{
          pid_role: :owner_session,
          owner_pid: self(),
          branch: :forwarded_owner
        })

      {:ok, witness,
       %{
         state
         | native_compaction_admission: consumed,
           forwarded_send_witness: %ForwardedSendWitnessState{
             digest: ForwardedSendWitnessV1.digest(witness),
             binding: capability.binding,
             control_ref: capability.control_ref,
             downstream: stable_downstream(downstream),
             status: :issued
           }
       }}
    else
      {:error, reason} -> {:error, reason, clear_native_compaction_admission(state, reason)}
    end
  end

  defp issue_forwarded_send_witness_now(state, _downstream, _capability, _now_ms),
    do: {:error, :invalid_transition, clear_native_compaction_admission(state)}

  defp redeem_forwarded_send_now(
         %{
           forwarded_send_witness: %ForwardedSendWitnessState{
             status: :issued,
             digest: expected_digest,
             binding: binding,
             control_ref: control_ref,
             downstream: downstream
           }
         } = state,
         %ForwardedSendWitnessV1{} = witness,
         live_lifecycle_snapshot,
         serving_mode
       ) do
    now_ms = System.system_time(:millisecond)

    if secure_digest_match?(expected_digest, ForwardedSendWitnessV1.digest(witness)) and
         ForwardedSendWitnessV1.authorizes?(
           witness,
           binding,
           control_ref,
           downstream,
           live_lifecycle_snapshot,
           serving_mode,
           now_ms
         ) and current_owner_binding?(state, binding, downstream) do
      {:ok, put_in(state.forwarded_send_witness.status, :redeemed)}
    else
      {:error, :forwarded_send_witness_rejected, clear_native_compaction_admission(state)}
    end
  end

  defp redeem_forwarded_send_now(state, _witness, _snapshot, _mode),
    do: {:error, :forwarded_send_witness_rejected, clear_native_compaction_admission(state)}

  defp current_owner_binding?(state, %NativeCompactionAdmission.Binding{} = binding, downstream) do
    require_forwarded_binding(state, downstream, binding) == :ok and
      admission_downstream_matches?(state.native_compaction_admission_downstream, downstream)
  end

  defp secure_digest_match?(expected, presented)
       when is_binary(expected) and is_binary(presented) and byte_size(expected) == 32 and
              byte_size(presented) == 32,
       do: Plug.Crypto.secure_compare(expected, presented)

  defp secure_digest_match?(_expected, _presented), do: false

  @spec submit_frame(GenServer.server(), downstream(), binary()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error() | term()}
  def submit_frame(owner, downstream, payload)
      when is_map(downstream) and is_binary(payload) do
    submit_upstream(owner, downstream, payload)
  end

  @spec submit_request(GenServer.server(), downstream(), UpstreamWebsocketSession.Request.t()) ::
          submitted_request_result()
  def submit_request(owner, downstream, %UpstreamWebsocketSession.Request{} = request)
      when is_map(downstream) do
    submit_request(owner, downstream, request, submission_observer?(request))
  end

  @spec submit_request(
          GenServer.server(),
          downstream(),
          UpstreamWebsocketSession.Request.t(),
          boolean()
        ) :: submitted_request_result()
  def submit_request(
        owner,
        downstream,
        %UpstreamWebsocketSession.Request{} = request,
        submission_notification?
      )
      when is_map(downstream) and is_boolean(submission_notification?) do
    GenServer.call(
      owner,
      {:submit_upstream, downstream, request, submission_notification?},
      :infinity
    )
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

  @doc false
  @spec consume_reserve_receipt(GenServer.server(), map()) ::
          {:ok, reference()} | {:error, :invalid}
  def consume_reserve_receipt(owner, proof) when is_map(proof),
    do: GenServer.call(owner, {:consume_reserve_receipt, proof}, owner_call_timeout())

  @doc false
  @spec validate_consumed_reserve_receipt(GenServer.server(), map(), reference()) ::
          :ok | {:error, :invalid}
  def validate_consumed_reserve_receipt(owner, proof, consume_fence)
      when is_map(proof) and is_reference(consume_fence),
      do:
        GenServer.call(
          owner,
          {:validate_consumed_reserve_receipt, proof, consume_fence},
          owner_call_timeout()
        )

  @doc false
  @spec release_consumed_reserve_receipt(GenServer.server(), map(), reference()) ::
          :ok | {:error, :invalid}
  def release_consumed_reserve_receipt(owner, proof, consume_fence)
      when is_map(proof) and is_reference(consume_fence),
      do:
        GenServer.call(
          owner,
          {:release_consumed_reserve_receipt, proof, consume_fence},
          owner_call_timeout()
        )

  @impl GenServer
  def init(opts) do
    sensitivity = NativeCompactionTrace.configure_process_sensitivity(:owner_session)
    Process.flag(:trap_exit, true)
    _trace = NativeCompactionTrace.enroll(:owner_session, self())

    codex_session_id = Keyword.fetch!(opts, :codex_session_id)
    owner_lease_token = Keyword.fetch!(opts, :owner_lease_token)
    owner_instance_id = Keyword.fetch!(opts, :owner_instance_id)
    request_id = Keyword.get(opts, :request_id)
    idle_shutdown_ms = Keyword.get(opts, :idle_shutdown_ms, 300_000)
    owner_renewal_ms = Keyword.get(opts, :owner_renewal_ms, owner_renewal_ms())

    monotonic_now_ms =
      Keyword.get(opts, :monotonic_now_ms, fn -> System.monotonic_time(:millisecond) end)

    handoff_soft_timeout_ms =
      Keyword.get(opts, :handoff_soft_timeout_ms, @handoff_soft_timeout_ms)

    handoff_absolute_timeout_ms =
      Keyword.get(opts, :handoff_absolute_timeout_ms, @handoff_absolute_timeout_ms)

    owner_renewal_delay =
      Keyword.get(opts, :owner_renewal_delay, &jittered_owner_renewal_delay/1)

    upstream = upstream_boundary(opts)
    persistence = persistence_boundary(opts)

    with {:ok, upstream_pid} <- upstream.start.() do
      {:ok,
       %__MODULE__{
         codex_session_id: codex_session_id,
         owner_lease_token: owner_lease_token,
         owner_instance_id: owner_instance_id,
         upstream_pid: upstream_pid,
         callbacks: %Callbacks{
           upstream_sender: upstream.send,
           upstream_closer: upstream.close,
           upstream_invalidator: Map.get(upstream, :invalidate, &invalidate_owner_upstream/1),
           downstream_sender: Keyword.get(opts, :downstream_sender, &send_downstream_message/2),
           monotonic_now_ms: monotonic_now_ms,
           replay_suspender:
             Keyword.get(opts, :replay_suspender, &CodexPooler.Accounting.arm_request_replay/1),
           replay_status_reader:
             Keyword.get(
               opts,
               :replay_status_reader,
               &CodexPooler.Accounting.replay_provisional_token_status/1
             )
         },
         persistence: persistence,
         request_id: request_id,
         idle_shutdown_ms: idle_shutdown_ms,
         owner_renewal_ms: owner_renewal_ms,
         owner_renewal_delay: owner_renewal_delay,
         native_compaction_trace_sensitivity: sensitivity,
         handoff_soft_timeout_ms: handoff_soft_timeout_ms,
         handoff_absolute_timeout_ms: handoff_absolute_timeout_ms,
         draining?: false,
         retire_after_active_turn?: false,
         native_compaction_admission: nil,
         native_compaction_admission_downstream: nil,
         forwarded_send_witness: nil,
         downstream_epoch: 0,
         process_generation: System.unique_integer([:positive, :monotonic]),
         suspended_replay: nil
       }
       |> schedule_owner_renewal()}
    end
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
             :owner_session,
             generation,
             authorization,
             restorer
           ) do
        {:ok, sensitivity} ->
          {:reply, :ok, %{state | native_compaction_trace_sensitivity: sensitivity}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  else
    def handle_call(
          {:native_compaction_trace_sensitivity, :observe, _generation, _authorization,
           _restorer},
          _from,
          state
        ),
        do: {:reply, {:error, :full_trace_unavailable}, state}
  end

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
        draining?: state.draining?,
        active_turn?: DownstreamState.active_turn?(state)
      }}, state}
  end

  def handle_call({:touch_replay_liveness, reference}, _from, state) do
    case state.suspended_replay do
      %{provisional_status: :started, consume_binding: ^reference} ->
        case CodexPooler.Accounting.touch_request_replay_liveness(reference) do
          {:ok, _entitlement} -> {:reply, :ok, state}
          {:error, _reason} -> {:reply, {:error, :owner_unavailable}, state}
        end

      _state ->
        {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call(:drain, _from, state) do
    state = %{
      state
      | termination_cleanup_witness: OwnerCleanup.from_owner_state(state)
    }

    state = state |> clear_native_compaction_admission() |> fail_pending_handoff(:owner_drained)

    state =
      if DownstreamState.active_turn?(state) do
        terminate_predecessor_task(state.active_turn)
        _result = Persistence.interrupt_codex_session(state, :owner_drained)
        reply_active_turn(state, {:error, :owner_drained})
        finish_active_turn(state, {:error, :owner_drained})
      else
        _result = send_owner_error(state, state.downstream, :owner_drained)
        state
      end

    {:stop, :normal, :ok, %{state | draining?: true, owner_exit_cause: :drain_cut}}
  end

  def handle_call(
        {:attach_downstream, _pid, _correlation_id, _opts},
        _from,
        %{draining?: true} = state
      ) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:preflight_reconnect, _downstream, _semantic_turn_key, _control_ref},
        _from,
        %{draining?: true} = state
      ) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:preflight_reconnect, downstream, semantic_turn_key, control_ref},
        _from,
        state
      ) do
    case preflight_reconnect_now(state, downstream, semantic_turn_key, control_ref) do
      {:reply, reply, next_state} -> {:reply, reply, next_state}
    end
  end

  def handle_call({:cancel_reconnect, downstream, control_ref}, _from, state) do
    {:reply, :ok, cancel_pending_handoff_by_ref(state, downstream, control_ref)}
  end

  def handle_call({:reconnect_control_v2, control}, _from, state) do
    case apply_reconnect_control_v2(state, control) do
      {:ok, result, next_state} -> {:reply, flatten_v2_result(result), next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_reserve_receipt, proof}, _from, state) do
    with :ok <- validate_reserve_receipt_proof(proof),
         true <- proof.owner_lease_token == state.owner_lease_token,
         true <- proof.owner_process_generation == state.process_generation,
         %{
           provisional_status: :consume_reserved,
           reserve_receipt_digest: digest,
           reserve_receipt_used?: false,
           owner_process_generation: generation,
           downstream: %{epoch: epoch},
           lifecycle: lifecycle
         } = replay <- state.suspended_replay,
         true <- generation == proof.owner_process_generation,
         true <- epoch == proof.downstream_epoch,
         true <- reserve_lifecycle_matches?(lifecycle, proof),
         true <- secure_digest_match?(digest, proof.reserve_receipt_digest) do
      consume_fence = make_ref()
      consume_monitor = Process.monitor(proof.consumer_pid)

      replay = %{
        replay
        | reserve_receipt_used?: true,
          consume_fence: consume_fence,
          consume_pid: proof.consumer_pid,
          consume_monitor: consume_monitor
      }

      {:reply, {:ok, consume_fence}, %{state | suspended_replay: replay}}
    else
      _invalid -> {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:release_consumed_reserve_receipt, proof, consume_fence}, _from, state) do
    case validate_consumed_reserve_receipt_now(state, proof, consume_fence) do
      :ok ->
        {:reply, :ok, clear_consume_reservation(state)}

      {:error, :invalid} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:validate_consumed_reserve_receipt, proof, consume_fence}, _from, state) do
    {:reply, validate_consumed_reserve_receipt_now(state, proof, consume_fence), state}
  end

  def handle_call({:begin_suspend, descriptor}, _from, state) do
    case cas_active_status(state, descriptor, :suspending) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_active_downstream_loss, downstream}, _from, state) do
    case mark_active_downstream_lost(state, downstream) do
      {:ok, next_state} -> {:reply, :reattachable, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prepare_next_replay_descriptor, downstream, descriptor}, _from, state) do
    if DownstreamState.downstream_status(state.downstream, downstream) == :active and
         valid_next_replay_descriptor?(descriptor) do
      next = Map.put(descriptor, :downstream, Map.take(downstream, @restore_downstream_keys))
      {:reply, :ok, %{state | next_turn_descriptor: next}}
    else
      {:reply, {:error, :owner_busy}, state}
    end
  end

  def handle_call({:admission_control_v1, control}, _from, %{draining?: true} = state) do
    if WebsocketOwnerAdmissionControlV1.validate(control) == :ok do
      {:reply, {:error, :owner_drained}, clear_native_compaction_admission(state)}
    else
      {:reply, {:error, :owner_unavailable}, clear_native_compaction_admission(state)}
    end
  end

  def handle_call({:admission_control_v1, control}, _from, state) do
    case apply_admission_control(state, control) do
      {:ok, reply, next_state} -> {:reply, {:ok, reply}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call(
        {:issue_forwarded_send_witness_v1, downstream, capability, now_ms},
        _from,
        state
      ) do
    case issue_forwarded_send_witness_now(state, downstream, capability, now_ms) do
      {:ok, witness, next_state} -> {:reply, {:ok, witness}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call(
        {:redeem_forwarded_send_v1, witness, live_lifecycle_snapshot, serving_mode},
        _from,
        state
      ) do
    case redeem_forwarded_send_now(state, witness, live_lifecycle_snapshot, serving_mode) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  # A bridged HTTP turn must never steal another turn's downstream. Each bridge
  # turn attaches a fresh downstream and detaches when done, so an already
  # attached downstream (or an active turn) means another bridge turn owns the
  # session: reject the attach atomically so the caller falls back to plain HTTP
  # instead of redirecting the running turn's frames.
  def handle_call({:attach_downstream, pid, correlation_id, opts}, _from, state) do
    cond do
      Keyword.get(opts, :reject_if_busy, false) and owner_occupied?(state) and
          not suspended_replay_attachable?(state.suspended_replay) ->
        {:reply, {:error, :owner_busy}, state}

      replay_active?(state, state.downstream) ->
        epoch = DownstreamState.next_downstream_epoch(state.downstream_epoch)

        candidate = %{
          pid: pid,
          epoch: epoch,
          correlation_id: correlation_id,
          active_turn_reconnect?: true
        }

        {:reply, {:ok, candidate}, state}

      suspended_replay_attachable?(state.suspended_replay) ->
        epoch = DownstreamState.next_downstream_epoch(state.downstream_epoch)

        candidate = %{
          pid: pid,
          epoch: epoch,
          correlation_id: correlation_id,
          active_turn_reconnect?: true
        }

        {:reply, {:ok, candidate}, state}

      true ->
        attach_downstream_now(state, pid, correlation_id)
    end
  end

  def handle_call({:restore_downstream, _downstream}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:restore_downstream, downstream},
        _from,
        %{downstream: nil, active_turn: nil} = state
      ) do
    attach_downstream_now(state, downstream)
  end

  def handle_call({:restore_downstream, downstream}, _from, state) do
    case DownstreamState.downstream_status(state.downstream, downstream) do
      :active -> {:reply, {:ok, state.downstream}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach_downstream, pid, epoch, correlation_id}, from, state) do
    case DownstreamState.downstream_status(state.downstream, %{
           pid: pid,
           epoch: epoch,
           correlation_id: correlation_id
         }) do
      :active ->
        requested_downstream = %{pid: pid, epoch: epoch, correlation_id: correlation_id}

        if replay_active?(state, requested_downstream) do
          detach_replay_downstream(state, requested_downstream, from)
        else
          state =
            state
            |> cancel_pending_handoff(requested_downstream, :socket_closed)
            |> DownstreamState.demonitor_downstream()
            |> DownstreamState.schedule_idle_shutdown()
            |> DownstreamState.cancel_active_turn_downstream(requested_downstream)
            |> Map.put(:downstream, nil)
            |> reconcile_disconnected_provisional()

          state =
            state
            |> clear_native_compaction_admission()
            |> maybe_settle_cancelled_without_pending_handoff(:client_disconnected)

          reply_or_retire(state, :ok)
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:cancel_downstream, pid, epoch, correlation_id, owner_turn_id, reason},
        _from,
        state
      ) do
    downstream = %{
      pid: pid,
      epoch: epoch,
      correlation_id: correlation_id,
      owner_turn_id: owner_turn_id
    }

    case DownstreamState.cancellation_status(state, downstream) do
      :active ->
        state =
          state
          |> DownstreamState.demonitor_downstream()
          |> DownstreamState.schedule_idle_shutdown()
          |> DownstreamState.cancel_active_turn_downstream(downstream, reason)
          |> Map.put(:downstream, nil)

        state =
          state |> clear_native_compaction_admission() |> settle_cancelled_active_turn(reason)

        reply_or_retire(state, :ok)

      {:error, status_reason} ->
        {:reply, {:error, status_reason}, state}
    end
  end

  def handle_call({:submit_upstream, _downstream, _payload}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:submit_upstream, _downstream, _payload, _submission_notification?},
        _from,
        %{draining?: true} = state
      ) do
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

  def handle_call(
        {:submit_upstream, downstream, _payload, _submission_notification?},
        _from,
        %{active_turn: active_turn} = state
      )
      when not is_nil(active_turn) do
    {:reply, DownstreamState.stale_or_busy(state.downstream, downstream), state}
  end

  def handle_call({:submit_upstream, downstream, upstream_payload}, from, state) do
    accept_or_consume_upstream_submission(state, from, downstream, upstream_payload, false)
  end

  def handle_call(
        {:submit_upstream, downstream, upstream_payload, submission_notification?},
        from,
        state
      )
      when is_boolean(submission_notification?) do
    accept_or_consume_upstream_submission(
      state,
      from,
      downstream,
      upstream_payload,
      submission_notification?
    )
  end

  def handle_call({:push_downstream, payload}, _from, state) do
    case send_downstream(state, state.downstream, payload) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp accept_upstream_submission(
         state,
         from,
         downstream,
         upstream_payload,
         submission_notification?
       ) do
    with {:ok, active_turn_downstream} <- active_turn_downstream(state.downstream, downstream),
         {:ok, upstream_payload, state, admission_phase} <-
           prepare_owner_admission_submission(state, active_turn_downstream, upstream_payload) do
      ref = make_ref()
      task = start_upstream_task(state, ref, upstream_payload)
      {submitter_pid, _tag} = from

      {descriptor, state} =
        take_next_turn_descriptor(state, active_turn_downstream, upstream_payload)

      cleanup_witness =
        OwnerCleanup.capture(
          state,
          if(is_struct(upstream_payload), do: Map.from_struct(upstream_payload), else: %{}),
          active_turn_downstream,
          cleanup_replay_generation(upstream_payload, descriptor)
        )

      if cleanup_witness do
        send(active_turn_downstream.pid, {
          :websocket_owner_cleanup_witness,
          active_turn_downstream.correlation_id,
          active_turn_downstream.epoch,
          Map.get(active_turn_downstream, :owner_turn_id),
          cleanup_witness
        })
      end

      active_turn = %{
        ref: ref,
        task_pid: task.pid,
        task_ref: task.ref,
        submitter_monitor: Process.monitor(submitter_pid),
        reply_to: from,
        downstream: active_turn_downstream,
        terminal_forwarded?: false,
        pending_result: nil,
        terminal_delivery_timeout: nil,
        terminal_delivery_timer_ref: nil,
        output_commit_probe: nil,
        collect?: collect_request?(upstream_payload),
        submission_observed?: submission_notification?,
        descriptor: descriptor,
        cleanup_witness: cleanup_witness,
        visible_output?: false,
        upstream_pid: state.upstream_pid,
        admission_phase: admission_phase,
        first_compact_request_identity:
          NativeCompactionAdmission.FirstCompactResult.request_identity(upstream_payload),
        ordinary_request_identity: ordinary_request_identity(upstream_payload),
        task_settled?: false,
        submitter_exited?: false,
        reply_sent?: false
      }

      {:noreply,
       %{
         state
         | active_turn: active_turn,
           first_compact_result: nil,
           ordinary_success_result: nil
       }}
    else
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{
           native_replay_binding: %NativeReplayAdmission.Binding{} = binding,
           native_replay_proof: %RuntimeAdmissionProof{
             kind: :native_replay
           },
           provisional_token: token,
           native_compaction_capability: nil,
           first_compact_collection: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: nil
         } = request
       )
       when is_binary(token) and byte_size(token) == 32 do
    with %{
           provisional_status: :committed_not_started,
           consume_binding: consume,
           provisional_token: expected_token,
           owner_process_generation: generation
         }
         when generation == binding.owner_process_generation <- state.suspended_replay,
         true <- secure_digest_match?(expected_token, token),
         true <- consume == NativeReplayAdmission.consume_binding(binding) do
      mark_owner_replay_started(state, request, consume)
    else
      _invalid -> {:error, :owner_unavailable, state}
    end
  end

  defp prepare_owner_admission_submission(
         state,
         downstream,
         %UpstreamWebsocketSession.Request{
           native_compaction_capability: %NativeCompactionAdmission.Capability{} = capability,
           forwarded_owner_send_handoff: nil
         } = request
       ) do
    now_ms = System.system_time(:millisecond)

    case issue_forwarded_send_witness_now(state, downstream, capability, now_ms) do
      {:ok, witness, next_state} ->
        handoff = ForwardedOwnerRequestHandoff.new(self(), witness)

        request = %{
          request
          | native_compaction_capability: nil,
            expected_connection_lifecycle: nil,
            forwarded_owner_send_handoff: handoff
        }

        {:ok, request, next_state, capability.phase}

      {:error, _reason, next_state} ->
        {:error, :native_compaction_capability_rejected, next_state}
    end
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{
           native_compaction_capability: nil,
           first_compact_collection:
             %NativeCompactionAdmission.FirstCompactCollection{} =
               provenance,
           expected_connection_lifecycle: expected_lifecycle,
           forwarded_owner_send_handoff: nil
         } = request
       ) do
    if expected_lifecycle == %{
         lifecycle_id: provenance.binding.lifecycle_id,
         generation: provenance.binding.generation
       } and NativeCompactionAdmission.FirstCompactCollection.valid?(provenance) do
      {:ok, request, state, {:first_full_history_compact, provenance}}
    else
      {:error, :native_compaction_capability_rejected, clear_native_compaction_admission(state)}
    end
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: expected_lifecycle,
           forwarded_owner_send_handoff: nil
         }
       )
       when not is_nil(expected_lifecycle) do
    {:error, :native_compaction_capability_rejected, clear_native_compaction_admission(state)}
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: nil
         } = request
       ) do
    {:ok, request, state, nil}
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{}
       ) do
    {:error, :native_compaction_capability_rejected, clear_native_compaction_admission(state)}
  end

  defp prepare_owner_admission_submission(state, _downstream, upstream_payload),
    do: {:ok, upstream_payload, state, nil}

  defp mark_owner_replay_started(state, request, consume) do
    case CodexPooler.Accounting.mark_request_replay_started(consume) do
      {:ok, _entitlement} ->
        suspended = %{state.suspended_replay | provisional_status: :started}
        next_state = %{state | suspended_replay: suspended}
        {:ok, request, next_state, :native_replay}

      {:error, _reason} ->
        _result = CodexPooler.Accounting.compensate_request_replay_no_send(consume)
        {:error, :owner_unavailable, state}
    end
  end

  defp accept_or_consume_upstream_submission(
         %{pending_handoff: %{status: :ready} = pending} = state,
         from,
         downstream,
         upstream_payload,
         submission_notification?
       ) do
    descriptor = pending_submission_descriptor(state, pending, downstream, upstream_payload)

    if handoff_downstream?(pending, downstream) and
         descriptor == %{kind: :native, semantic_turn_key: pending.semantic_turn_key} do
      state =
        state
        |> put_next_turn_descriptor(downstream, pending.semantic_turn_key)
        |> clear_pending_handoff()

      accept_upstream_submission(
        state,
        from,
        downstream,
        upstream_payload,
        submission_notification?
      )
    else
      {:reply, {:error, :owner_busy}, state}
    end
  end

  defp accept_or_consume_upstream_submission(
         state,
         from,
         downstream,
         upstream_payload,
         submission_notification?
       ) do
    accept_upstream_submission(
      state,
      from,
      downstream,
      upstream_payload,
      submission_notification?
    )
  end

  defp preflight_reconnect_now(
         %{active_turn: nil, pending_handoff: nil} = state,
         downstream,
         semantic_turn_key,
         _ref
       ) do
    case DownstreamState.downstream_status(state.downstream, downstream) do
      :active ->
        {:reply, {:ok, :dispatch}, put_next_turn_descriptor(state, downstream, semantic_turn_key)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp preflight_reconnect_now(
         %{pending_handoff: pending} = state,
         downstream,
         semantic_turn_key,
         _control_ref
       )
       when is_map(pending) do
    cond do
      not handoff_downstream?(pending, downstream) ->
        {:reply, {:error, :owner_busy}, state}

      pending.semantic_turn_key == semantic_turn_key ->
        {:reply, {:ok, :duplicate_replacement, pending.control_ref}, state}

      true ->
        {:reply, {:error, :owner_busy}, state}
    end
  end

  defp preflight_reconnect_now(
         %{active_turn: active_turn} = state,
         downstream,
         semantic_turn_key,
         control_ref
       )
       when is_map(active_turn) do
    descriptor = Map.get(active_turn, :descriptor, :unknown)
    cancelled? = Map.has_key?(active_turn, :canceled_result)

    case descriptor do
      %{kind: :native, semantic_turn_key: ^semantic_turn_key} when not cancelled? ->
        {:reply, {:ok, :same_turn_replay}, state}

      %{kind: :native, semantic_turn_key: active_key}
      when cancelled? and active_key != semantic_turn_key ->
        begin_pending_handoff(state, downstream, semantic_turn_key, control_ref)

      _descriptor ->
        {:reply, {:error, :owner_busy}, state}
    end
  end

  defp begin_pending_handoff(state, downstream, semantic_turn_key, control_ref) do
    case DownstreamState.downstream_status(state.downstream, downstream) do
      :active ->
        soft_token = make_ref()
        absolute_token = make_ref()

        pending = %{
          pid: downstream.pid,
          epoch: downstream.epoch,
          correlation_id: downstream.correlation_id,
          control_ref: control_ref,
          semantic_turn_key: semantic_turn_key,
          owner_turn_id: active_turn_owner_turn_id(state.active_turn),
          status: :waiting,
          soft_token: soft_token,
          soft_timer_ref:
            Process.send_after(
              self(),
              {:websocket_owner_handoff_soft_timeout, control_ref, soft_token},
              state.handoff_soft_timeout_ms
            ),
          absolute_token: absolute_token,
          absolute_timer_ref:
            Process.send_after(
              self(),
              {:websocket_owner_handoff_absolute_timeout, control_ref, absolute_token},
              state.handoff_absolute_timeout_ms
            )
        }

        state = %{state | pending_handoff: pending}
        state = put_next_turn_descriptor(state, downstream, semantic_turn_key)
        {:reply, {:ok, :replacement_handoff, control_ref}, maybe_ready_pending_handoff(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_cast(:begin_drain, state) do
    {:noreply,
     state
     |> clear_native_compaction_admission()
     |> fail_pending_handoff(:owner_drained)
     |> Map.put(:draining?, true)}
  end

  @impl GenServer
  def handle_info(
        {:websocket_owner_upstream_frame, ref, _payload},
        %{active_turn: %{ref: ref, collect?: true}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:websocket_owner_upstream_frame, ref, payload},
        %{active_turn: %{ref: ref}} = state
      ) do
    handle_upstream_frame(state, payload, terminal_frame?(payload))
  end

  def handle_info(
        {:websocket_owner_upstream_frame, ref, _payload,
         %TerminalDiscriminator{} = _discriminator},
        %{active_turn: %{ref: ref, collect?: true}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:websocket_owner_upstream_frame, ref, payload, %TerminalDiscriminator{} = discriminator},
        %{active_turn: %{ref: ref}} = state
      ) do
    handle_upstream_frame(state, payload, TerminalDiscriminator.terminal?(discriminator))
  end

  def handle_info({:websocket_owner_upstream_frame, _ref, _payload, _discriminator}, state),
    do: {:noreply, state}

  def handle_info({:websocket_owner_upstream_frame, _ref, _payload}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{active_turn: %{task_ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = put_in(state.active_turn.task_ref, nil)
    {result, state} = retain_first_compact_result(result, state)
    {result, state} = retain_ordinary_success_result(result, state)
    state = settle_owner_admission_transport(state, result)

    if Process.alive?(state.upstream_pid) do
      result = DownstreamState.effective_active_turn_result(state.active_turn, result)

      if is_map(state.pending_handoff) do
        state
        |> settle_predecessor_task(result)
        |> maybe_ready_pending_handoff()
        |> continue_or_retire()
      else
        state
        |> resolve_active_turn_result(result)
        |> continue_or_retire()
      end
    else
      retire_current_upstream(state, :owner_crashed)
    end
  end

  def handle_info(
        {:websocket_owner_output_commit_ack, _correlation_id, _epoch, _owner_turn_id,
         _active_turn_ref, _probe_ref, _committed?} = message,
        %{active_turn: %{output_commit_probe: probe}} = state
      )
      when is_map(probe) do
    case WebsocketOwnerContract.accept_output_commit_ack(
           message,
           probe.epoch,
           probe.correlation_id,
           probe.owner_turn_id,
           probe.active_turn_ref,
           probe.probe_ref
         ) do
      {:ok, committed?} ->
        state
        |> settle_output_commit_probe(committed?)
        |> continue_or_retire()

      _stale_or_invalid ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:websocket_owner_output_commit_timeout, active_turn_ref, probe_ref},
        %{
          active_turn: %{
            output_commit_probe: %{
              active_turn_ref: active_turn_ref,
              probe_ref: probe_ref
            }
          }
        } = state
      ) do
    state
    |> timeout_output_commit_probe()
    |> continue_or_retire()
  end

  def handle_info({:EXIT, upstream_pid, reason}, %{upstream_pid: upstream_pid} = state) do
    retire_current_upstream(clear_native_compaction_admission(state), reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_turn: %{task_ref: ref}} = state) do
    if Process.alive?(state.upstream_pid) do
      result =
        DownstreamState.effective_active_turn_result(
          state.active_turn,
          {:error, owner_error(reason)}
        )

      if is_map(state.pending_handoff) do
        state
        |> put_in([Access.key(:active_turn), Access.key(:task_ref)], nil)
        |> settle_predecessor_task(result)
        |> maybe_ready_pending_handoff()
        |> continue_or_retire()
      else
        state
        |> settle_active_turn(result)
        |> continue_or_retire()
      end
    else
      retire_current_upstream(state, :owner_crashed)
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active_turn: %{submitter_monitor: ref} = active_turn} = state
      ) do
    if is_map(state.pending_handoff) do
      state
      |> put_in([Access.key(:active_turn), Access.key(:submitter_monitor)], nil)
      |> put_in([Access.key(:active_turn), Access.key(:submitter_exited?)], true)
      |> maybe_ready_pending_handoff()
      |> continue_or_retire()
    else
      DownstreamState.cancel_active_turn_task(active_turn)

      state
      |> clear_native_compaction_admission()
      |> finish_active_turn({:error, :client_disconnected})
      |> continue_or_retire()
    end
  end

  def handle_info(
        {:websocket_owner_handoff_soft_timeout, control_ref, soft_token},
        %{
          pending_handoff: %{control_ref: control_ref, soft_token: soft_token, status: :waiting}
        } = state
      ) do
    pending = %{state.pending_handoff | soft_timer_ref: nil, soft_token: nil}
    _result = invalidate_upstream(state)
    terminate_predecessor_task(state.active_turn)

    {:noreply,
     state
     |> clear_native_compaction_admission()
     |> Map.put(:pending_handoff, pending)}
  end

  def handle_info(
        {:websocket_owner_handoff_absolute_timeout, control_ref, absolute_token},
        %{
          pending_handoff: %{
            control_ref: control_ref,
            absolute_token: absolute_token
          }
        } = state
      ) do
    state =
      state |> clear_native_compaction_admission() |> fail_pending_handoff(:owner_forward_timeout)

    state = settle_predecessor_before_retire(state)
    {:stop, :normal, %{state | draining?: true}}
  end

  def handle_info(
        {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token},
        %{
          active_turn: %{
            ref: turn_ref,
            pending_result: pending_result,
            terminal_forwarded?: false,
            terminal_delivery_timeout: {turn_ref, timer_token}
          }
        } = state
      )
      when not is_nil(pending_result) do
    result =
      case invalidate_upstream(state) do
        :ok -> terminal_delivery_timeout_result()
        {:error, reason} -> {:error, reason}
      end

    state
    |> settle_active_turn(result)
    |> continue_or_retire()
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{downstream_monitor: ref} = state) do
    state = state |> handle_monitored_downstream_loss() |> reconcile_disconnected_provisional()

    state =
      case state.active_turn do
        %{output_commit_probe: %{result: result}} ->
          settle_active_turn_without_downstream_delivery(state, result)

        %{pending_result: pending_result} when not is_nil(pending_result) ->
          settle_active_turn(state, pending_result)

        _active_turn ->
          state
      end

    continue_or_retire(state)
  end

  def handle_info(
        {:DOWN, ref, :process, consumer_pid, _reason},
        %{
          suspended_replay: %{
            provisional_status: :consume_reserved,
            reserve_receipt_used?: true,
            consume_pid: consumer_pid,
            consume_monitor: ref
          }
        } = state
      ) do
    state = clear_consume_reservation(state, demonitor?: false)
    suspended = state.suspended_replay

    case reconcile_provisional(state, suspended) do
      {:ok, :terminal, _reconciled} ->
        {:noreply, clear_terminal_reconciliation(state)}

      {:ok, status, reconciled} when status in [:committed_not_started, :started] ->
        {:noreply, maybe_cancel_replay_reconciliation(state, status, reconciled)}

      {:ok, :consume_reserved, reconciled} ->
        {:noreply, retire_replay_state(%{state | suspended_replay: reconciled})}

      {:ok, status, reconciled} ->
        {:noreply, maybe_cancel_replay_reconciliation(state, status, reconciled)}

      {:error, _reason} ->
        {:noreply, schedule_replay_reconciliation(%{state | suspended_replay: suspended})}
    end
  end

  def handle_info(
        {:websocket_owner_replay_reconcile, token},
        %{
          suspended_replay: %{
            provisional_status: :consume_reserved,
            reconciliation_token: token
          }
        } = state
      ) do
    state = cancel_replay_reconciliation(state)
    suspended = state.suspended_replay

    case reconcile_provisional(state, suspended) do
      {:ok, :terminal, _reconciled} ->
        {:noreply, clear_terminal_reconciliation(state)}

      {:ok, :consume_reserved, reconciled} ->
        next_state =
          if Map.get(reconciled, :reserve_receipt_used?, false) do
            schedule_replay_reconciliation(%{state | suspended_replay: reconciled})
          else
            retire_replay_state(%{state | suspended_replay: reconciled})
          end

        {:noreply, next_state}

      {:ok, status, reconciled} ->
        {:noreply, maybe_cancel_replay_reconciliation(state, status, reconciled)}

      {:error, _reason} ->
        {:noreply, schedule_replay_reconciliation(%{state | suspended_replay: suspended})}
    end
  end

  def handle_info({:websocket_owner_replay_reconcile, _token}, state), do: {:noreply, state}

  def handle_info(:idle_shutdown, %{downstream: nil, active_turn: nil} = state) do
    {:stop, :normal,
     %{state | idle_shutdown_ref: nil, draining?: true, owner_exit_cause: :idle_expiry}}
  end

  def handle_info(:idle_shutdown, state) do
    {:noreply, %{state | idle_shutdown_ref: nil}}
  end

  def handle_info(:renew_owner_lease, state) do
    state = %{state | owner_renewal_ref: nil}

    case Persistence.renew_owner_lease(state) do
      {:ok, state} ->
        state = touch_active_replay_liveness(state)
        {:noreply, schedule_owner_renewal(state)}

      {:error, reason} when reason in [:stale_owner, :owner_unavailable] ->
        Logger.owner_renewal_stale(reason, state)

        {:stop, {:shutdown, :stale_owner},
         state |> clear_native_compaction_admission() |> Map.put(:draining?, true)}

      {:error, reason} ->
        Logger.owner_renewal_failed(reason, state)
        {:noreply, schedule_owner_renewal(state)}
    end
  end

  def handle_info(
        {:native_compaction_trace_sensitivity, :restore, generation, authorization, restorer},
        state
      ) do
    sensitivity = state.native_compaction_trace_sensitivity

    if NativeCompactionTrace.authorized_restore?(
         sensitivity,
         generation,
         authorization,
         restorer
       ) do
      :ok = NativeCompactionTrace.restore_process_sensitivity(sensitivity)
      {:noreply, %{state | native_compaction_trace_sensitivity: :sensitive}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, restorer, _reason}, state) do
    sensitivity = state.native_compaction_trace_sensitivity

    case NativeCompactionTrace.restore_on_restorer_down(sensitivity, monitor, restorer) do
      :restored ->
        {:noreply, %{state | native_compaction_trace_sensitivity: :sensitive}}

      :unchanged ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, state) do
    state = cancel_owner_renewal(state)
    terminate_predecessor_task(state.active_turn)
    _state = clear_pending_handoff(state)
    owner_exit_reason = owner_exit_reason(reason, state)
    owner_exit_cause = owner_exit_cause(reason, state)
    Logger.owner_terminated(reason, owner_exit_reason, owner_exit_cause, state)

    try do
      state = OwnerCleanup.resolve_owner_state(state)

      case Persistence.interrupt_codex_session(state, owner_exit_reason) do
        :ok -> Persistence.release_owner_lease(state, owner_exit_reason, owner_exit_cause)
        {:error, _reason} -> :ok
      end
    after
      close_upstream(state.callbacks.upstream_closer, state.upstream_pid)
    end

    :ok
  end

  defp owner_reuse_status(pid, opts) do
    expected = %{
      codex_session_id: Keyword.fetch!(opts, :codex_session_id),
      owner_lease_token: Keyword.fetch!(opts, :owner_lease_token),
      owner_instance_id: Keyword.fetch!(opts, :owner_instance_id)
    }

    case GenServer.call(pid, :owner_status, owner_call_timeout()) do
      {:ok, %{draining?: true}} ->
        :draining

      {:ok, status} when not is_map_key(status, :draining?) ->
        :stale

      {:ok, status} ->
        cond do
          not uuid?(expected.codex_session_id) -> :reusable
          status.upstream_alive? and Map.take(status, Map.keys(expected)) == expected -> :reusable
          true -> :stale
        end

      _other ->
        :stale
    end
  catch
    :exit, _reason -> :stale
  end

  defp start_upstream_task(state, ref, upstream_payload) do
    reservation = %{
      owner: self(),
      ref: ref,
      upstream_pid: state.upstream_pid,
      upstream_sender: state.callbacks.upstream_sender,
      collect?: collect_request?(upstream_payload),
      forward_error_body?: forward_error_body?(upstream_payload)
    }

    Task.Supervisor.async_nolink(@task_supervisor, fn ->
      Process.flag(:sensitive, true)
      send_upstream(reservation, upstream_payload)
    end)
  end

  defp stop_stale_owner(pid) do
    GenServer.stop(pid, {:shutdown, :stale_owner}, owner_call_timeout())
  catch
    :exit, {:noproc, _details} -> :ok
  end

  defp submission_observer?(%UpstreamWebsocketSession.Request{submission_observer: observer}),
    do: is_function(observer, 0)

  defp handle_upstream_frame(state, payload, terminal?) do
    case classify_terminal_delivery_frame(state.active_turn.terminal_forwarded?, terminal?) do
      :duplicate_terminal ->
        {:noreply, state}

      {:forward, terminal?} ->
        case authorize_visible_delivery(state, payload) do
          {:ok, state} -> relay_authorized_frame(state, payload, terminal?)
          {:error, state} -> {:noreply, state}
        end
    end
  end

  defp relay_authorized_frame(state, payload, terminal?) do
    case deliver_authorized_frame(state, payload) do
      :ok ->
        state
        |> maybe_complete_terminal_delivery(terminal?)
        |> continue_or_retire()

      {:error, reason} ->
        state
        |> fail_terminal_delivery(terminal?, reason)
        |> continue_or_retire()

      :stale_generation ->
        {:noreply, state}
    end
  end

  defp deliver_authorized_frame(
         %{active_turn: %{visible_output?: true}} = state,
         payload
       ) do
    send_downstream(state, DownstreamState.active_turn_downstream(state), {:data, payload})
  end

  defp deliver_authorized_frame(
         %{active_turn: %{descriptor: %{request_id: request_id, attempt_id: attempt_id}}} = state,
         payload
       )
       when is_binary(request_id) and is_binary(attempt_id) do
    if StreamProtocol.internal_control_event?(payload) do
      deliver_internal_frame(state, request_id, attempt_id, payload)
    else
      send_downstream(
        state,
        DownstreamState.active_turn_downstream(state),
        {:data, payload}
      )
    end
  end

  defp deliver_authorized_frame(state, payload) do
    send_downstream(state, DownstreamState.active_turn_downstream(state), {:data, payload})
  end

  defp deliver_internal_frame(state, request_id, attempt_id, payload) do
    descriptor = state.active_turn.descriptor

    request = %CodexPooler.Accounting.Request{id: request_id}

    attempt = %CodexPooler.Accounting.Attempt{
      id: attempt_id,
      request_id: request_id,
      replay_generation: descriptor.replay_generation
    }

    case CodexPooler.Accounting.with_current_replay_generation(request, attempt, fn ->
           send_downstream(
             state,
             DownstreamState.active_turn_downstream(state),
             {:data, payload}
           )
         end) do
      {:ok, result} -> result
      {:error, _reason} -> :stale_generation
    end
  rescue
    Ecto.NoResultsError -> :stale_generation
  end

  defp authorize_visible_delivery(
         %{active_turn: %{visible_output?: true}} = state,
         _payload
       ),
       do: {:ok, state}

  defp authorize_visible_delivery(
         %{
           active_turn: %{
             descriptor: %{request_id: request_id, attempt_id: attempt_id} = descriptor
           }
         } = state,
         payload
       )
       when is_binary(request_id) and is_binary(attempt_id) do
    if Map.has_key?(descriptor, :replay_claim_digest) and
         StreamProtocol.downstream_visible_event?(payload) do
      attempt = %{
        id: attempt_id,
        request_id: request_id,
        replay_generation: descriptor.replay_generation
      }

      case SessionContinuity.authorize_codex_turn_visibility(request_id, attempt) do
        {:ok, :committed} ->
          state = put_in(state.active_turn.descriptor.visible_output?, true)
          {:ok, %{state | active_turn: %{state.active_turn | visible_output?: true}}}

        {:ok, _not_committed} ->
          {:ok, state}

        _failure ->
          {:error, state}
      end
    else
      {:ok, state}
    end
  end

  defp authorize_visible_delivery(state, _payload), do: {:ok, state}

  defp send_upstream(
         %{
           owner: owner,
           ref: ref,
           upstream_pid: upstream_pid,
           upstream_sender: sender,
           collect?: collect?,
           forward_error_body?: forward_error_body?
         },
         upstream_payload
       ) do
    writer =
      if collect? do
        nil
      else
        fn frame, discriminator ->
          send(owner, {:websocket_owner_upstream_frame, ref, frame, discriminator})
        end
      end

    case sender.(upstream_pid, upstream_payload, writer) do
      {:error, response} when is_map(response) ->
        {:error, Map.put(response, :forward_error_body?, forward_error_body?)}

      result ->
        result
    end
  end

  defp send_downstream(_state, nil, _payload), do: {:error, :owner_unavailable}

  defp send_downstream(
         state,
         %{
           pid: pid,
           epoch: epoch,
           correlation_id: correlation_id,
           owner_turn_id: owner_turn_id
         },
         payload
       )
       when is_pid(owner_turn_id) do
    message = {:websocket_owner_frame, correlation_id, epoch, owner_turn_id, payload}

    if WebsocketOwnerContract.downstream_message?(message) do
      state.callbacks.downstream_sender.(pid, message)
    else
      {:error, :invalid_downstream_message}
    end
  end

  defp send_downstream(_state, %{owner_turn_id: _invalid_owner_turn_id}, _payload),
    do: {:error, :invalid_downstream_message}

  defp send_downstream(
         state,
         %{pid: pid, epoch: epoch, correlation_id: correlation_id},
         payload
       ) do
    message = {:websocket_owner_frame, correlation_id, epoch, payload}

    if WebsocketOwnerContract.downstream_message?(message) do
      state.callbacks.downstream_sender.(pid, message)
    else
      {:error, :invalid_downstream_message}
    end
  end

  defp send_owner_error(state, downstream, reason) do
    error = owner_error(reason)

    with {:ok, payload} <- WebsocketOwnerContract.safe_error_payload(error, nil) do
      send_downstream(state, downstream, {:error, error, payload})
    end
  end

  defp send_downstream_message(pid, message) do
    send(pid, message)
    :ok
  end

  defp reply_active_turn(
         %{
           active_turn: %{reply_to: reply_to, submission_observed?: true}
         },
         result
       ) do
    GenServer.reply(reply_to, {:websocket_owner_submission_accepted, result})
  end

  defp reply_active_turn(%{active_turn: %{reply_to: reply_to}}, result) do
    GenServer.reply(reply_to, result)
  end

  defp owner_occupied?(state) do
    DownstreamState.active_turn?(state) or not is_nil(state.downstream)
  end

  defp suspended_replay_attachable?(%{provisional_status: status}),
    do: status in [:armed, :provisional, :consume_reserved, :committed_not_started]

  defp suspended_replay_attachable?(_suspended), do: false

  defp attach_downstream_now(state, pid, correlation_id) do
    state = settle_probe_before_reconnect(state)
    epoch = DownstreamState.next_downstream_epoch(state.downstream_epoch)

    downstream = %{
      pid: pid,
      epoch: epoch,
      correlation_id: correlation_id
    }

    attach_downstream_now(state, downstream)
  end

  defp attach_downstream_now(state, downstream) do
    state = settle_probe_before_reconnect(state)

    state =
      state
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.cancel_idle_shutdown()

    downstream = Map.take(downstream, @restore_downstream_keys)
    monitor = Process.monitor(downstream.pid)

    downstream =
      Map.put(downstream, :active_turn_reconnect?, DownstreamState.active_turn?(state))

    state =
      case state.active_turn do
        %{descriptor: %{downstream_status: :lost}} -> state
        _other -> DownstreamState.put_active_turn_downstream(state, downstream)
      end

    {:reply, {:ok, downstream},
     %{
       state
       | downstream: downstream,
         downstream_monitor: monitor,
         downstream_epoch: downstream.epoch
     }}
  end

  defp finish_active_turn(state, result) do
    downstream = DownstreamState.active_turn_downstream(state)
    clear_active_turn_resources(state.active_turn)
    state = clear_terminal_replay_state(state, result)

    state =
      if state.active_turn.collect? do
        state
        |> Map.put(:active_turn, nil)
        |> DownstreamState.maybe_schedule_idle_shutdown()
      else
        finish_relay_active_turn(state, downstream, result)
      end

    complete_terminal_winner_detach(state)
  end

  defp clear_terminal_replay_state(
         %{active_turn: %{descriptor: %{replay_generation: 1}}} = state,
         _result
       ) do
    clear_replay_state(state)
  end

  defp clear_terminal_replay_state(state, _result), do: state

  defp settle_owner_admission_transport(
         %{active_turn: %{admission_phase: :compact}} = state,
         result
       ) do
    if successful_upstream_result?(result) do
      case NativeCompactionAdmission.record_compact_collected(state.native_compaction_admission) do
        {:ok, admission} -> %{state | native_compaction_admission: admission}
        {:error, _reason} -> clear_native_compaction_admission(state)
      end
    else
      clear_native_compaction_admission(state)
    end
  end

  defp settle_owner_admission_transport(
         %{active_turn: %{admission_phase: {:first_full_history_compact, provenance}}} = state,
         result
       ) do
    if successful_upstream_result?(result) do
      case NativeCompactionAdmission.record_first_compact_collected(
             state.native_compaction_admission,
             provenance
           ) do
        {:ok, admission} -> %{state | native_compaction_admission: admission}
        {:error, _reason} -> clear_native_compaction_admission(state)
        {:error, _reason, admission} -> put_admission(state, admission)
      end
    else
      clear_native_compaction_admission(state)
    end
  end

  defp settle_owner_admission_transport(
         %{active_turn: %{admission_phase: :final}} = state,
         result
       ) do
    if successful_upstream_result?(result) do
      :ok = emit_final_completed(state)
      state
    else
      clear_native_compaction_admission(state)
    end
  end

  defp settle_owner_admission_transport(state, _result), do: state

  defp retain_first_compact_result(
         {:ok,
          %{first_compact_result: %NativeCompactionAdmission.FirstCompactResult{} = receipt} =
            result},
         %{active_turn: active_turn} = state
       ) do
    receipt_module = NativeCompactionAdmission.FirstCompactResult

    if receipt.owner == state.upstream_pid and
         not is_nil(active_turn.first_compact_request_identity) and
         receipt_module.identity(receipt) == active_turn.first_compact_request_identity do
      topology =
        WebsocketOwnerAdmissionControlV1.forwarded_topology(
          state.owner_instance_id,
          state.owner_lease_token,
          active_turn.downstream.epoch
        )

      receipt = %{
        receipt
        | owner: self(),
          result_ref: make_ref(),
          binding: %{receipt.binding | topology: topology}
      }

      {{:ok, Map.put(result, :first_compact_result, receipt)},
       %{state | first_compact_result: receipt}}
    else
      {{:ok, Map.delete(result, :first_compact_result)}, state}
    end
  end

  defp retain_first_compact_result(result, state), do: {result, state}

  defp retain_ordinary_success_result(
         {:ok, %{ordinary_success_result: %OrdinarySuccessResult{} = receipt} = result},
         %{active_turn: active} = state
       ) do
    if receipt.owner == state.upstream_pid and
         {receipt.request_id, receipt.attempt_id} == active.ordinary_request_identity do
      topology =
        WebsocketOwnerAdmissionControlV1.forwarded_topology(
          state.owner_instance_id,
          state.owner_lease_token,
          active.downstream.epoch
        )

      receipt = %{receipt | owner: self(), result_ref: make_ref(), topology: topology}

      {{:ok, Map.put(result, :ordinary_success_result, receipt)},
       %{state | ordinary_success_result: receipt}}
    else
      {{:ok, Map.delete(result, :ordinary_success_result)}, state}
    end
  end

  defp retain_ordinary_success_result(result, state), do: {result, state}

  defp ordinary_request_identity(%{request_id: request_id, attempt_id: attempt_id}),
    do: {request_id, attempt_id}

  defp ordinary_request_identity(_payload), do: nil

  defp cleanup_replay_generation(
         %{native_replay_binding: %NativeReplayAdmission.Binding{replay_generation: generation}},
         _descriptor
       ),
       do: generation

  defp cleanup_replay_generation(_request, %{replay_generation: generation}), do: generation
  defp cleanup_replay_generation(_request, _descriptor), do: 0

  defp emit_compact_acknowledged(%NativeCompactionAdmission.Capability{} = capability) do
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :acknowledged)

    _trace =
      NativeCompactionTrace.emit_capability(:capability_acknowledged, capability, %{
        pid_role: :owner_session,
        owner_pid: self()
      })

    :ok
  end

  defp emit_compact_acknowledged(nil),
    do: NativeCompactionAuthorizationObservation.emit(:compact_acknowledged, :forwarded)

  defp successful_upstream_result?(:ok), do: true
  defp successful_upstream_result?({:ok, _result}), do: true
  defp successful_upstream_result?(_result), do: false

  defp finish_relay_active_turn(state, downstream, result) do
    case result do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, %{body: body, forward_error_body?: true, reason: _reason}}
      when is_binary(body) and body != "" ->
        _result = send_downstream(state, downstream, {:data, body})

      {:error, %{body: _body, reason: _reason}} ->
        :ok

      {:error, %{reason: reason}} ->
        _result = send_owner_error(state, downstream, reason)

      {:error, reason} ->
        _result = send_owner_error(state, downstream, reason)

      _other ->
        _result = send_owner_error(state, downstream, :owner_crashed)
    end

    _result = send_downstream(state, downstream, :complete)

    state
    |> Map.put(:active_turn, nil)
    |> DownstreamState.maybe_schedule_idle_shutdown()
  end

  defp settle_cancelled_active_turn(state, reason) do
    case state.active_turn do
      %{output_commit_probe: probe} when is_map(probe) ->
        settle_active_turn_without_downstream_delivery(state, {:error, reason})

      %{pending_result: pending_result} when not is_nil(pending_result) ->
        settle_active_turn(state, {:error, reason})

      _active_turn ->
        state
    end
  end

  defp maybe_settle_cancelled_without_pending_handoff(
         %{pending_handoff: pending} = state,
         _reason
       )
       when is_map(pending),
       do: state

  defp maybe_settle_cancelled_without_pending_handoff(state, reason),
    do: settle_cancelled_active_turn(state, reason)

  defp settle_active_turn(state, result) do
    if output_commit_probe_required?(state, result) do
      retain_output_commit_probe(state, result)
    else
      reply_active_turn(state, result)
      finish_active_turn(state, result)
    end
  end

  defp resolve_active_turn_result(%{active_turn: %{collect?: true}} = state, result),
    do: settle_active_turn(state, result)

  defp resolve_active_turn_result(state, result) do
    if terminal_bearing_result?(result) and not state.active_turn.terminal_forwarded? do
      retain_terminal_result(state, result)
    else
      settle_active_turn(state, result)
    end
  end

  defp continue_or_retire(%{retire_after_active_turn?: true, active_turn: nil} = state),
    do: {:stop, :owner_crashed, state}

  defp continue_or_retire(state), do: {:noreply, state}

  defp reply_or_retire(%{retire_after_active_turn?: true, active_turn: nil} = state, reply),
    do: {:stop, :owner_crashed, reply, state}

  defp reply_or_retire(state, reply), do: {:reply, reply, state}

  defp retire_current_upstream(state, reason) do
    state = %{
      state
      | draining?: true,
        retire_after_active_turn?: true,
        termination_cleanup_witness: OwnerCleanup.from_owner_state(state)
    }

    case state.active_turn do
      %{output_commit_probe: probe} when is_map(probe) ->
        {:noreply, state}

      active_turn when is_map(active_turn) ->
        state = cancel_active_turn_for_upstream_exit(state)

        state
        |> settle_active_turn(upstream_exit_result(state, reason))
        |> continue_or_retire()

      nil ->
        {:stop, :owner_crashed, state}
    end
  end

  defp cancel_active_turn_for_upstream_exit(state) do
    %{task_ref: task_ref} = state.active_turn
    if is_reference(task_ref), do: Process.demonitor(task_ref, [:flush])
    DownstreamState.cancel_active_turn_task(state.active_turn)
    put_in(state.active_turn.task_ref, nil)
  end

  defp upstream_exit_result(
         %{active_turn: %{downstream: %{owner_turn_id: owner_turn_id}}},
         reason
       )
       when is_pid(owner_turn_id) do
    {:error,
     %{
       body: "",
       reason: owner_error(reason),
       transport_failure: %{"reason" => "owner_crashed"}
     }}
  end

  defp upstream_exit_result(_state, reason), do: {:error, owner_error(reason)}

  defp retain_output_commit_probe(state, result) do
    downstream = DownstreamState.active_turn_downstream(state)
    active_turn_ref = state.active_turn.ref
    probe_ref = make_ref()

    probe =
      {:websocket_owner_output_commit_probe, downstream.correlation_id, downstream.epoch,
       downstream.owner_turn_id, active_turn_ref, self(), probe_ref}

    timer_ref =
      Process.send_after(
        self(),
        {:websocket_owner_output_commit_timeout, active_turn_ref, probe_ref},
        WebsocketOwnerContract.default_forward_timeout_ms()
      )

    output_commit_probe = %{
      result: result,
      correlation_id: downstream.correlation_id,
      epoch: downstream.epoch,
      owner_turn_id: downstream.owner_turn_id,
      active_turn_ref: active_turn_ref,
      probe_ref: probe_ref,
      timer_ref: timer_ref
    }

    state = put_in(state.active_turn.output_commit_probe, output_commit_probe)

    case state.callbacks.downstream_sender.(downstream.pid, probe) do
      :ok -> state
      {:error, _reason} -> settle_active_turn_without_downstream_delivery(state, result)
    end
  end

  # The probe follows owner->socket frames on the same sender/receiver pair.
  # Retaining the result until the ack preserves that ordering; an unsolicited
  # socket notification would race in the opposite direction.
  defp settle_output_commit_probe(state, committed?) do
    %{result: result} = state.active_turn.output_commit_probe
    downstream = DownstreamState.active_turn_downstream(state)
    cancel_output_commit_probe_timer(state.active_turn)

    if committed? do
      _result = send_owner_error(state, downstream, :upstream_stream_error)
    end

    _result = send_downstream(state, downstream, :complete)
    reply_active_turn(state, result)
    clear_active_turn(state)
  end

  defp timeout_output_commit_probe(state) do
    %{result: result} = state.active_turn.output_commit_probe
    downstream = DownstreamState.active_turn_downstream(state)
    cancel_output_commit_probe_timer(state.active_turn)
    _result = send_owner_error(state, downstream, :owner_forward_timeout)
    _result = send_downstream(state, downstream, :complete)
    reply_active_turn(state, result)
    clear_active_turn(state)
  end

  defp settle_active_turn_without_downstream_delivery(state, result) do
    reply_active_turn(state, result)
    clear_active_turn(state)
  end

  defp settle_probe_before_reconnect(
         %{active_turn: %{output_commit_probe: %{result: result}}} = state
       ) do
    settle_active_turn_without_downstream_delivery(state, result)
  end

  defp settle_probe_before_reconnect(state), do: state

  defp clear_active_turn(state) do
    clear_active_turn_resources(state.active_turn)

    state
    |> Map.put(:active_turn, nil)
    |> DownstreamState.maybe_schedule_idle_shutdown()
  end

  defp clear_active_turn_resources(active_turn) do
    cancel_terminal_delivery_timer(active_turn)
    cancel_output_commit_probe_timer(active_turn)
    DownstreamState.clear_active_turn_monitors(active_turn)
  end

  defp settle_predecessor_task(state, result) do
    active_turn =
      state.active_turn
      |> cancel_predecessor_delivery_timers()
      |> Map.put(:task_settled?, true)
      |> Map.put(:pending_result, nil)
      |> Map.put(:output_commit_probe, nil)

    state = %{state | active_turn: active_turn}
    reply_predecessor_once(state, result)
  end

  defp reply_predecessor_once(%{active_turn: %{reply_sent?: true}} = state, _result), do: state

  defp reply_predecessor_once(state, result) do
    reply_active_turn(state, result)
    put_in(state.active_turn.reply_sent?, true)
  end

  defp cancel_predecessor_delivery_timers(active_turn) do
    cancel_terminal_delivery_timer(active_turn)
    cancel_output_commit_probe_timer(active_turn)

    active_turn
    |> Map.put(:terminal_delivery_timeout, nil)
    |> Map.put(:terminal_delivery_timer_ref, nil)
  end

  defp maybe_ready_pending_handoff(
         %{
           pending_handoff: %{status: :waiting} = pending,
           active_turn: %{
             task_settled?: true,
             submitter_exited?: true,
             downstream: nil,
             terminal_delivery_timer_ref: nil,
             output_commit_probe: nil
           }
         } = state
       ) do
    DownstreamState.clear_active_turn_monitors(state.active_turn)
    pending = %{pending | status: :ready}

    message =
      {:websocket_owner_handoff_ready, pending.correlation_id, pending.epoch,
       pending.owner_turn_id, pending.pid, pending.control_ref}

    _result = state.callbacks.downstream_sender.(pending.pid, message)
    %{state | active_turn: nil, pending_handoff: pending}
  end

  defp maybe_ready_pending_handoff(state), do: state

  defp handoff_downstream?(pending, downstream) do
    Map.take(pending, @restore_downstream_keys) == Map.take(downstream, @restore_downstream_keys)
  end

  defp cancel_pending_handoff(%{pending_handoff: nil} = state, _downstream, _reason), do: state

  defp cancel_pending_handoff(%{pending_handoff: pending} = state, downstream, _reason) do
    if is_map(downstream) and handoff_downstream?(pending, downstream) do
      state
      |> abort_pending_predecessor()
      |> clear_pending_handoff()
    else
      state
    end
  end

  defp cancel_pending_handoff_by_ref(
         %{pending_handoff: %{control_ref: control_ref} = pending} = state,
         downstream,
         control_ref
       ) do
    if is_map(downstream) and handoff_downstream?(pending, downstream) do
      state
      |> abort_pending_predecessor()
      |> clear_pending_handoff()
    else
      state
    end
  end

  defp cancel_pending_handoff_by_ref(state, _downstream, _control_ref), do: state

  defp abort_pending_predecessor(%{active_turn: active_turn} = state) when is_map(active_turn) do
    terminate_predecessor_task(active_turn)

    state
    |> reply_predecessor_once({:error, :client_disconnected})
    |> clear_active_turn()
  end

  defp abort_pending_predecessor(state), do: state

  defp fail_pending_handoff(%{pending_handoff: nil} = state, _reason), do: state

  defp fail_pending_handoff(%{pending_handoff: pending} = state, reason) do
    message =
      {:websocket_owner_handoff_failed, pending.correlation_id, pending.epoch,
       pending.owner_turn_id, pending.pid, pending.control_ref, reason}

    _result = state.callbacks.downstream_sender.(pending.pid, message)
    clear_pending_handoff(state)
  end

  defp clear_pending_handoff(%{pending_handoff: pending} = state) when is_map(pending) do
    Enum.each([pending.soft_timer_ref, pending.absolute_timer_ref], fn
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ref -> :ok
    end)

    %{state | pending_handoff: nil}
  end

  defp clear_pending_handoff(state), do: state

  defp terminate_predecessor_task(%{task_pid: task_pid}) when is_pid(task_pid) do
    if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)
    :ok
  end

  defp terminate_predecessor_task(_active_turn), do: :ok

  defp active_turn_owner_turn_id(%{task_pid: task_pid}) when is_pid(task_pid), do: task_pid

  defp settle_predecessor_before_retire(%{active_turn: active_turn} = state)
       when is_map(active_turn) do
    state
    |> reply_predecessor_once({:error, :client_disconnected})
    |> clear_active_turn()
  end

  defp settle_predecessor_before_retire(state), do: state

  defp upstream_turn_descriptor(state, %UpstreamWebsocketSession.Request{
         payload: payload,
         message_mapper: mapper
       }) do
    if native_message_mapper?(mapper) do
      with {:ok, decoded} when is_map(decoded) <- Jason.decode(payload),
           {:ok, %{semantic_turn_key: semantic_turn_key}} <-
             WebsocketTurnIdentity.resolve(decoded, state.codex_session_id) do
        %{kind: :native, semantic_turn_key: semantic_turn_key}
      else
        _missing_or_invalid -> :unknown
      end
    else
      %{kind: :public}
    end
  end

  defp upstream_turn_descriptor(_state, _payload), do: :unknown

  defp put_next_turn_descriptor(state, downstream, semantic_turn_key)
       when is_map(downstream) and is_binary(semantic_turn_key) and
              byte_size(semantic_turn_key) == 32 do
    next_turn_descriptor = %{
      downstream: Map.take(downstream, @restore_downstream_keys),
      semantic_turn_key: semantic_turn_key
    }

    %{state | next_turn_descriptor: next_turn_descriptor}
  end

  defp valid_next_replay_descriptor?(descriptor) do
    Map.keys(descriptor) |> Enum.sort() ==
      Enum.sort([
        :semantic_turn_key,
        :replay_claim_digest,
        :authorization_snapshot,
        :request_id,
        :codex_turn_id,
        :model_id,
        :endpoint,
        :attempt_id,
        :replay_generation
      ]) and
      valid_replay_descriptor_identity?(descriptor) and
      valid_replay_descriptor_context?(descriptor)
  end

  defp valid_replay_descriptor_identity?(descriptor) do
    is_binary(descriptor.semantic_turn_key) and byte_size(descriptor.semantic_turn_key) == 32 and
      is_binary(descriptor.replay_claim_digest) and
      byte_size(descriptor.replay_claim_digest) == 32 and
      is_map(descriptor.authorization_snapshot)
  end

  defp valid_replay_descriptor_context?(descriptor) do
    is_binary(descriptor.request_id) and
      (is_nil(descriptor.codex_turn_id) or is_binary(descriptor.codex_turn_id)) and
      is_binary(descriptor.model_id) and is_binary(descriptor.endpoint) and
      is_binary(descriptor.attempt_id) and descriptor.replay_generation in [0, 1]
  end

  defp take_next_turn_descriptor(
         %{
           next_turn_descriptor:
             %{downstream: expected, semantic_turn_key: semantic_turn_key} = next
         } =
           state,
         downstream,
         upstream_payload
       ) do
    if expected == Map.take(downstream, @restore_downstream_keys) do
      {%{
         kind: :native,
         semantic_turn_key: semantic_turn_key,
         semantic_turn_digest: semantic_turn_key,
         replay_claim_digest: Map.get(next, :replay_claim_digest),
         authorization_snapshot: Map.get(next, :authorization_snapshot),
         request_id: Map.get(next, :request_id),
         codex_turn_id: Map.get(next, :codex_turn_id),
         model_id: Map.get(next, :model_id),
         endpoint: Map.get(next, :endpoint),
         attempt_id: Map.get(next, :attempt_id),
         replay_generation: Map.get(next, :replay_generation, 0),
         visible_output?: false,
         downstream_status: :attached
       }, %{state | next_turn_descriptor: nil}}
    else
      {upstream_turn_descriptor(state, upstream_payload), state}
    end
  end

  defp take_next_turn_descriptor(state, _downstream, upstream_payload),
    do: {upstream_turn_descriptor(state, upstream_payload), state}

  defp pending_submission_descriptor(
         %{next_turn_descriptor: %{downstream: expected, semantic_turn_key: semantic_turn_key}},
         pending,
         downstream,
         _upstream_payload
       ) do
    if expected == Map.take(downstream, @restore_downstream_keys) and
         pending.semantic_turn_key == semantic_turn_key do
      %{kind: :native, semantic_turn_key: semantic_turn_key}
    else
      :unknown
    end
  end

  defp pending_submission_descriptor(state, _pending, _downstream, upstream_payload),
    do: upstream_turn_descriptor(state, upstream_payload)

  defp apply_reconnect_control_v2(state, %RemoteReconnectControlV2{} = control) do
    with :ok <- RemoteReconnectControlV2.validate(control),
         true <- control.codex_session_id == state.codex_session_id,
         true <- control.owner_lease_token == state.owner_lease_token do
      apply_valid_reconnect_control_v2(state, control)
    else
      _invalid -> {:error, :stale_owner}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{active_turn: nil, suspended_replay: nil} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :fresh} = control
       ),
       do: {:ok, {:fresh_dispatch, control.downstream}, state}

  defp apply_valid_reconnect_control_v2(
         %{active_turn: %{descriptor: descriptor} = active_turn} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :active_reattach} = control
       ) do
    with true <- control.downstream.epoch == state.downstream_epoch + 1,
         true <- replay_descriptor_match?(descriptor, control),
         true <- descriptor.downstream_status == :lost,
         false <- descriptor.visible_output?,
         true <- Process.alive?(active_turn.task_pid),
         true <-
           active_turn.upstream_pid == state.upstream_pid and Process.alive?(state.upstream_pid),
         false <- active_turn.terminal_forwarded?,
         nil <- active_turn.pending_result,
         {:ok, state} <- cas_active_status(state, descriptor, :reattaching) do
      epoch = DownstreamState.next_downstream_epoch(state.downstream_epoch)

      downstream =
        control.downstream
        |> Map.put(:epoch, epoch)
        |> Map.put(:active_turn_reconnect?, true)

      monitor = Process.monitor(downstream.pid)
      descriptor = %{state.active_turn.descriptor | downstream_status: :attached}

      active_turn = %{
        state.active_turn
        | downstream: Map.put(downstream, :owner_turn_id, active_turn.task_pid),
          descriptor: descriptor
      }

      {:ok, {:same_turn_reattach, downstream},
       %{
         state
         | active_turn: active_turn,
           downstream: downstream,
           downstream_monitor: monitor,
           downstream_epoch: epoch
       }}
    else
      _failure -> {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: %{provisional_status: :armed} = armed} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :suspended_replay} = control
       ) do
    if state.handoff_absolute_timeout_ms in 1_000..60_000 do
      issued_at_ms = state.callbacks.monotonic_now_ms.()
      state = prune_provisional_issuances(state, issued_at_ms)

      if length(state.provisional_issuances) < 6 and suspended_preflight_match?(armed, control) and
           control.downstream.epoch == state.downstream_epoch + 1 do
        token = :crypto.strong_rand_bytes(32)
        deadline = issued_at_ms + state.handoff_absolute_timeout_ms

        downstream = %{
          control.downstream
          | epoch: DownstreamState.next_downstream_epoch(state.downstream_epoch)
        }

        suspended =
          armed
          |> Map.put(:downstream, downstream)
          |> Map.put(:provisional_token, token)
          |> Map.put(:provisional_status, :provisional)
          |> Map.put(:deadline_ms, deadline)
          |> Map.put(:consume_binding, nil)
          |> Map.put(:reconciliation_timer_ref, nil)
          |> Map.put(:reconciliation_token, nil)

        next_state =
          state
          |> Map.update!(:provisional_issuances, &[issued_at_ms | &1])
          |> Map.put(:suspended_replay, suspended)
          |> attach_provisional_downstream(downstream)

        {:ok, {:provisional, token, 1, state.process_generation, downstream}, next_state}
      else
        {:error, :owner_busy}
      end
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: %{provisional_status: :provisional} = suspended} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :suspended_replay} = control
       ) do
    if suspended_preflight_match?(suspended, control) and
         control.downstream.epoch == state.downstream_epoch + 1 do
      downstream = %{
        control.downstream
        | epoch: DownstreamState.next_downstream_epoch(state.downstream_epoch)
      }

      {:ok,
       {:provisional, suspended.provisional_token, 1, suspended.owner_process_generation,
        downstream},
       state
       |> put_in([Access.key(:suspended_replay), Access.key(:downstream)], downstream)
       |> attach_provisional_downstream(downstream)}
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: %{provisional_status: :committed_not_started} = suspended} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :suspended_replay} = control
       ) do
    if suspended_preflight_match?(suspended, control) and
         control.downstream.epoch == state.downstream_epoch + 1 do
      downstream = %{
        control.downstream
        | epoch: DownstreamState.next_downstream_epoch(state.downstream_epoch)
      }

      {:ok,
       {:provisional, suspended.provisional_token, 1, suspended.owner_process_generation,
        downstream},
       state
       |> put_in([Access.key(:suspended_replay), Access.key(:downstream)], downstream)
       |> attach_provisional_downstream(downstream)}
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_reserve} = control
       )
       when is_map(suspended) do
    reserve_now_ms = state.callbacks.monotonic_now_ms.()

    cond do
      not provisional_match?(suspended, control) ->
        {:error, :owner_busy}

      suspended.provisional_status == :consume_reserved ->
        {:ok,
         {:consume_reserved, suspended.reserve_timeout_ms, suspended.reserve_receipt,
          suspended.reserve_receipt_digest}, state}

      suspended.provisional_status == :provisional and
          reserve_now_ms < suspended.deadline_ms ->
        reserve_timeout_ms = suspended.deadline_ms - reserve_now_ms

        if reserve_timeout_ms in 1..60_000 do
          reserve_receipt = :crypto.strong_rand_bytes(32)

          {:ok, reserve_receipt_digest} =
            RequestReplayEntitlement.reserve_receipt_digest(
              suspended.provisional_token,
              reserve_receipt,
              reserve_timeout_ms
            )

          suspended =
            suspended
            |> Map.put(:cleanup_downstream_epoch, suspended.downstream.epoch)
            |> Map.put(:provisional_status, :consume_reserved)
            |> Map.put(:consume_binding, token_reference(suspended))
            |> Map.put(:reserve_timeout_ms, reserve_timeout_ms)
            |> Map.put(:reserve_receipt, reserve_receipt)
            |> Map.put(:reserve_receipt_digest, reserve_receipt_digest)
            |> Map.put(:reserve_receipt_used?, false)
            |> Map.put(:consume_fence, nil)
            |> Map.put(:consume_pid, nil)
            |> Map.put(:consume_monitor, nil)

          next_state = schedule_replay_reconciliation(%{state | suspended_replay: suspended})

          {:ok, {:consume_reserved, reserve_timeout_ms, reserve_receipt, reserve_receipt_digest},
           next_state}
        else
          {:error, :owner_busy}
        end

      true ->
        {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_commit} = control
       )
       when is_map(suspended) do
    with true <- provisional_match?(suspended, control),
         true <-
           suspended.provisional_status in [:consume_reserved, :committed_not_started, :started],
         reference = control.consume_binding,
         {:consumed, binding, phase, _abandon_at}
         when phase in [:committed_not_started, :started] <-
           CodexPooler.Accounting.replay_provisional_binding_status(reference),
         true <- binding == reference do
      suspended = %{suspended | provisional_status: phase, consume_binding: binding}

      next_state =
        state
        |> Map.put(:suspended_replay, suspended)
        |> clear_consume_reservation()
        |> cancel_replay_reconciliation()

      {:ok, {phase, binding}, next_state}
    else
      _not_consumed -> {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_query} = control
       )
       when is_map(suspended) do
    if provisional_match?(suspended, control) do
      case reconcile_provisional(state, suspended) do
        {:ok, :terminal, _reconciled} ->
          {:ok, :cancelled, clear_terminal_reconciliation(state)}

        {:ok, status, reconciled} ->
          next_state = maybe_cancel_replay_reconciliation(state, status, reconciled)
          {:ok, status, next_state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_cancel} = control
       )
       when is_map(suspended) do
    if provisional_match?(suspended, control) do
      suspended = Map.put(suspended, :consume_binding, token_reference(suspended))

      case reconcile_provisional(state, suspended) do
        {:ok, :terminal, _reconciled} ->
          {:ok, :cancelled, clear_terminal_reconciliation(state)}

        {:ok, status, reconciled} when status in [:committed_not_started, :started] ->
          {:ok, status, maybe_cancel_replay_reconciliation(state, status, reconciled)}

        {:ok, status, reconciled} when status in [:provisional, :consume_reserved] ->
          cancel_uncommitted_provisional(state, reconciled)

        {:ok, status, reconciled} when status in [:cancelled, :expired] ->
          {:ok, status, maybe_cancel_replay_reconciliation(state, status, reconciled)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(_state, _control), do: {:error, :owner_unavailable}

  defp cancel_uncommitted_provisional(state, reconciled) do
    if Map.get(reconciled, :reserve_receipt_used?, false) do
      next_state = schedule_replay_reconciliation(%{state | suspended_replay: reconciled})
      {:ok, :consume_reserved, next_state}
    else
      cancelled = %{reconciled | provisional_status: :cancelled, downstream: nil}
      next_state = maybe_cancel_replay_reconciliation(state, :cancelled, cancelled)
      {:ok, :cancelled, next_state}
    end
  end

  defp reconcile_provisional(state, suspended) do
    case provisional_db_status(state, suspended) do
      {:consumed, binding, phase, _abandon_at}
      when phase in [:committed_not_started, :started] ->
        {:ok, phase, %{suspended | provisional_status: phase, consume_binding: binding}}

      :terminal ->
        {:ok, :terminal, suspended}

      status when status in [:armed, :absent] ->
        cond do
          suspended.provisional_status == :consume_reserved ->
            {:ok, :consume_reserved, suspended}

          suspended.provisional_status == :provisional and
              state.callbacks.monotonic_now_ms.() >= suspended.deadline_ms ->
            {:ok, :expired, %{suspended | provisional_status: :expired, downstream: nil}}

          true ->
            {:ok, suspended.provisional_status, suspended}
        end

      {:error, _reason} ->
        {:error, :owner_busy}
    end
  end

  defp provisional_db_status(
         %{callbacks: %{replay_status_reader: reader}},
         %{consume_binding: %{provisional_token: _token} = reference}
       ),
       do: reader.(reference)

  defp provisional_db_status(_state, %{consume_binding: binding}) when is_map(binding),
    do: CodexPooler.Accounting.replay_provisional_binding_status(binding)

  defp provisional_db_status(_state, _suspended), do: :armed

  defp schedule_replay_reconciliation(state) do
    state = cancel_replay_reconciliation(state)
    token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:websocket_owner_replay_reconcile, token},
        state.suspended_replay.reserve_timeout_ms
      )

    suspended =
      state.suspended_replay
      |> Map.put(:reconciliation_timer_ref, timer_ref)
      |> Map.put(:reconciliation_token, token)

    %{state | suspended_replay: suspended}
  end

  defp cancel_replay_reconciliation(%{suspended_replay: suspended} = state)
       when is_map(suspended) do
    case Map.get(suspended, :reconciliation_timer_ref) do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _no_timer -> :ok
    end

    %{state | suspended_replay: clear_replay_reconciliation(suspended)}
  end

  defp cancel_replay_reconciliation(state), do: state

  defp clear_replay_reconciliation(suspended) do
    suspended
    |> Map.put(:reconciliation_timer_ref, nil)
    |> Map.put(:reconciliation_token, nil)
  end

  defp maybe_cancel_replay_reconciliation(state, status, reconciled)
       when status in [:committed_not_started, :started] do
    state
    |> Map.put(:suspended_replay, reconciled)
    |> clear_consume_reservation()
    |> cancel_replay_reconciliation()
  end

  defp maybe_cancel_replay_reconciliation(state, status, reconciled)
       when status in [:cancelled, :expired] do
    retire_replay_state(%{state | suspended_replay: reconciled})
  end

  defp maybe_cancel_replay_reconciliation(state, _status, reconciled),
    do: %{state | suspended_replay: reconciled}

  defp clear_terminal_reconciliation(state) do
    retire_replay_state(state)
  end

  defp retire_replay_state(state) do
    state
    |> clear_replay_state()
    |> DownstreamState.demonitor_downstream()
    |> Map.put(:downstream, nil)
    |> DownstreamState.schedule_idle_shutdown()
  end

  defp clear_replay_state(state) do
    state
    |> clear_native_compaction_admission()
    |> clear_consume_reservation()
    |> cancel_replay_reconciliation()
    |> Map.put(:suspended_replay, nil)
  end

  defp reconcile_disconnected_provisional(
         %{suspended_replay: %{provisional_status: status} = suspended} = state
       )
       when status in [:provisional, :consume_reserved] do
    suspended =
      suspended
      |> Map.put(:consume_binding, token_reference(suspended))
      |> Map.put(:downstream, nil)

    case reconcile_provisional(state, suspended) do
      {:ok, :terminal, _reconciled} ->
        clear_terminal_reconciliation(state)

      {:ok, status, reconciled} when status in [:committed_not_started, :started] ->
        maybe_cancel_replay_reconciliation(state, status, reconciled)

      {:ok, status, reconciled} when status in [:consume_reserved, :provisional] ->
        if Map.get(reconciled, :reserve_receipt_used?, false) do
          schedule_replay_reconciliation(%{state | suspended_replay: reconciled})
        else
          cancel_replay_reconciliation(%{
            state
            | suspended_replay: %{reconciled | provisional_status: :cancelled}
          })
        end

      {:ok, status, reconciled} ->
        maybe_cancel_replay_reconciliation(state, status, reconciled)

      {:error, _reason} ->
        %{state | suspended_replay: suspended}
    end
  end

  defp reconcile_disconnected_provisional(state), do: state

  defp token_reference(%{lifecycle: lifecycle} = suspended) do
    %{
      request_id: lifecycle.request_id,
      codex_turn_id: lifecycle.codex_turn_id,
      eligible_attempt_id: lifecycle.eligible_attempt_id,
      replay_generation: 1,
      owner_lease_digest: lifecycle.owner_lease_digest,
      provisional_token: suspended.provisional_token
    }
  end

  defp flatten_v2_result({:fresh_dispatch, downstream}), do: {:ok, :fresh_dispatch, downstream}

  defp flatten_v2_result({:same_turn_reattach, downstream}),
    do: {:ok, :same_turn_reattach, downstream}

  defp flatten_v2_result({:provisional, token, 1, generation, downstream}),
    do: {:ok, :provisional, token, 1, generation, downstream}

  defp flatten_v2_result({:consume_reserved, timeout, receipt, digest}),
    do: {:ok, :consume_reserved, timeout, receipt, digest}

  defp flatten_v2_result({phase, binding}) when phase in [:committed_not_started, :started],
    do: {:ok, phase, binding}

  defp flatten_v2_result(status), do: {:ok, status}

  defp cas_active_status(%{active_turn: %{descriptor: current}} = state, expected, target)
       when target in [:reattaching, :suspending] do
    allowed_statuses = if target == :suspending, do: [:attached, :lost], else: [:lost]

    if current == expected and current.downstream_status in allowed_statuses do
      {:ok, put_in(state.active_turn.descriptor.downstream_status, target)}
    else
      {:error, :owner_busy}
    end
  end

  defp cas_active_status(_state, _expected, _target), do: {:error, :owner_busy}

  defp mark_active_downstream_lost(
         %{active_turn: %{descriptor: %{downstream_status: :attached}} = active_turn} = state,
         downstream
       ) do
    if DownstreamState.downstream_status(state.downstream, downstream) == :active and
         active_turn.downstream.pid == downstream.pid and
         active_turn.downstream.epoch == downstream.epoch and
         active_turn.downstream.correlation_id == downstream.correlation_id do
      state =
        state
        |> DownstreamState.demonitor_downstream()
        |> put_in([Access.key(:active_turn), Access.key(:downstream)], nil)
        |> put_in(
          [Access.key(:active_turn), Access.key(:descriptor), Access.key(:downstream_status)],
          :lost
        )
        |> Map.put(:downstream, nil)

      {:ok, state}
    else
      {:error, :stale_downstream}
    end
  end

  defp mark_active_downstream_lost(_state, _downstream), do: {:error, :owner_busy}

  defp replay_descriptor_match?(descriptor, control),
    do:
      descriptor.authorization_snapshot == control.authorization_binding and
        secure_digest_match?(descriptor.semantic_turn_digest, control.semantic_turn_digest) and
        secure_digest_match?(descriptor.replay_claim_digest, control.replay_claim_digest) and
        lifecycle_control_match?(descriptor, control.consume_binding)

  defp lifecycle_control_match?(descriptor, %{
         request_id: request_id,
         codex_turn_id: turn_id,
         eligible_attempt_id: attempt_id,
         replay_generation: generation
       }) do
    descriptor.request_id == request_id and descriptor.codex_turn_id == turn_id and
      descriptor.attempt_id == attempt_id and descriptor.replay_generation == generation
  end

  defp lifecycle_control_match?(_descriptor, _binding), do: false

  defp provisional_match?(suspended, control),
    do:
      secure_digest_match?(suspended.provisional_token, control.provisional_token) and
        secure_digest_match?(suspended.semantic_turn_digest, control.semantic_turn_digest) and
        secure_digest_match?(suspended.replay_claim_digest, control.replay_claim_digest) and
        provisional_downstream_match?(suspended, control)

  defp provisional_downstream_match?(suspended, %{downstream: nil}),
    do: is_map(suspended)

  defp provisional_downstream_match?(%{downstream: downstream}, %{downstream: downstream}),
    do: true

  defp provisional_downstream_match?(_suspended, _control), do: false

  defp validate_reserve_receipt_proof(proof) do
    required = [
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :entitlement_id,
      :owner_lease_token,
      :owner_process_generation,
      :downstream_epoch,
      :reserve_receipt_digest,
      :consumer_pid
    ]

    if Map.keys(proof) |> Enum.sort() == Enum.sort(required) and
         Enum.all?(
           [
             :request_id,
             :codex_turn_id,
             :eligible_attempt_id,
             :entitlement_id,
             :owner_lease_token
           ],
           &uuid?(proof[&1])
         ) and is_pid(proof.consumer_pid) and proof.owner_process_generation > 0 and
         proof.downstream_epoch > 0 and
         is_binary(proof.reserve_receipt_digest) and byte_size(proof.reserve_receipt_digest) == 32 do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp validate_consumed_reserve_receipt_now(state, proof, consume_fence) do
    with :ok <- validate_reserve_receipt_proof(proof),
         true <- proof.owner_lease_token == state.owner_lease_token,
         true <- proof.owner_process_generation == state.process_generation,
         %{
           provisional_status: :consume_reserved,
           reserve_receipt_digest: digest,
           reserve_receipt_used?: true,
           consume_fence: ^consume_fence,
           consume_pid: consumer_pid,
           owner_process_generation: generation,
           downstream: %{epoch: epoch},
           lifecycle: lifecycle
         } <- state.suspended_replay,
         true <- generation == proof.owner_process_generation,
         true <- consumer_pid == proof.consumer_pid,
         true <- epoch == proof.downstream_epoch,
         true <- reserve_lifecycle_matches?(lifecycle, proof),
         true <- secure_digest_match?(digest, proof.reserve_receipt_digest) do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp reserve_lifecycle_matches?(lifecycle, proof) do
    lifecycle.request_id == proof.request_id and
      lifecycle.codex_turn_id == proof.codex_turn_id and
      lifecycle.eligible_attempt_id == proof.eligible_attempt_id and
      lifecycle.entitlement_id == proof.entitlement_id
  end

  defp clear_consume_reservation(state, opts \\ []) do
    case state.suspended_replay do
      suspended when is_map(suspended) ->
        demonitor_consume_reservation(suspended, Keyword.get(opts, :demonitor?, true))

        suspended =
          suspended
          |> Map.put(:reserve_receipt_used?, false)
          |> Map.put(:consume_fence, nil)
          |> Map.put(:consume_pid, nil)
          |> Map.put(:consume_monitor, nil)

        %{state | suspended_replay: suspended}

      _no_replay ->
        state
    end
  end

  defp demonitor_consume_reservation(%{consume_monitor: monitor}, demonitor?)
       when is_reference(monitor) and demonitor? not in [false, nil] do
    Process.demonitor(monitor, [:flush])
  end

  defp demonitor_consume_reservation(_suspended, _demonitor?), do: :ok

  defp suspended_preflight_match?(suspended, control),
    do:
      suspended.authorization_snapshot == control.authorization_binding and
        secure_digest_match?(suspended.semantic_turn_digest, control.semantic_turn_digest) and
        secure_digest_match?(suspended.replay_claim_digest, control.replay_claim_digest)

  defp attach_provisional_downstream(state, downstream) do
    state =
      state |> DownstreamState.demonitor_downstream() |> DownstreamState.cancel_idle_shutdown()

    state = put_in(state.suspended_replay[:cleanup_downstream_epoch], downstream.epoch)

    monitor = Process.monitor(downstream.pid)
    downstream = Map.put(downstream, :active_turn_reconnect?, true)

    %{
      state
      | downstream: downstream,
        downstream_monitor: monitor,
        downstream_epoch: downstream.epoch
    }
  end

  defp replay_active?(
         %{
           active_turn: %{
             descriptor: %{
               downstream_status: :attached,
               replay_claim_digest: digest,
               authorization_snapshot: authorization,
               visible_output?: false
             }
           }
         },
         downstream
       )
       when is_binary(digest) and byte_size(digest) == 32 and is_map(authorization) and
              is_map(downstream),
       do: DownstreamState.downstream_status(downstream, downstream) == :active

  defp replay_active?(_state, _downstream), do: false

  defp suspend_or_detach_downstream(state) do
    if replay_active?(state, state.downstream) do
      case suspend_replay_downstream(state) do
        {:suspended, suspended} ->
          suspended

        {:terminal_won, terminal} ->
          settle_terminal_winner(terminal)

        {:failed, failed} ->
          terminate_predecessor_task(failed.active_turn)
          reply_active_turn(failed, {:error, :client_disconnected})

          failed
          |> DownstreamState.cancel_active_turn_downstream(state.downstream, :client_disconnected)
          |> Map.put(:downstream, nil)
          |> finish_active_turn({:error, :client_disconnected})
      end
    else
      state
      |> clear_native_compaction_admission()
      |> cancel_pending_handoff(state.downstream, :socket_closed)
      |> Map.put(:downstream, nil)
      |> Map.put(:downstream_monitor, nil)
      |> DownstreamState.maybe_schedule_idle_shutdown()
    end
  end

  defp handle_monitored_downstream_loss(state) do
    if replay_active?(state, state.downstream) do
      case mark_active_downstream_lost(state, state.downstream) do
        {:ok, lost} -> lost
        {:error, _reason} -> suspend_or_detach_downstream(state)
      end
    else
      suspend_or_detach_downstream(state)
    end
  end

  defp suspend_replay_downstream(%{active_turn: %{descriptor: descriptor}} = state) do
    if state.active_turn.terminal_forwarded? or not is_nil(state.active_turn.pending_result) do
      {:terminal_won, state}
    else
      case cas_active_status(state, descriptor, :suspending) do
        {:ok, suspending} -> arm_suspended_replay(suspending, descriptor)
        _failure -> {:failed, state}
      end
    end
  end

  defp arm_suspended_replay(suspending, descriptor) do
    case suspending.callbacks.replay_suspender.(suspend_input(suspending, descriptor)) do
      {:ok, lifecycle} ->
        reply_active_turn(suspending, {:error, :client_disconnected})
        terminate_predecessor_task(suspending.active_turn)
        clear_active_turn_resources(suspending.active_turn)

        suspended = %{
          cleanup_witness: OwnerCleanup.from_owner_state(suspending),
          semantic_turn_digest: descriptor.semantic_turn_digest,
          replay_claim_digest: descriptor.replay_claim_digest,
          authorization_snapshot: descriptor.authorization_snapshot,
          replay_generation: 1,
          downstream: nil,
          predecessor_epoch: suspending.downstream.epoch,
          owner_process_generation: suspending.process_generation,
          provisional_token: nil,
          provisional_status: :armed,
          deadline_ms: nil,
          consume_binding: nil,
          reserve_timeout_ms: nil,
          reserve_receipt: nil,
          reserve_receipt_digest: nil,
          reserve_receipt_used?: false,
          consume_fence: nil,
          consume_pid: nil,
          consume_monitor: nil,
          reconciliation_timer_ref: nil,
          reconciliation_token: nil,
          lifecycle: lifecycle
        }

        {:suspended,
         %{
           suspending
           | active_turn: nil,
             suspended_replay: suspended,
             downstream: nil,
             downstream_monitor: nil
         }}

      {:error, :terminal_won} ->
        {:terminal_won, restore_suspending_descriptor(suspending, descriptor)}

      {:error, _reason} ->
        {:failed, restore_suspending_descriptor(suspending, descriptor)}
    end
  end

  defp detach_replay_downstream(state, requested_downstream, from) do
    case suspend_replay_downstream(state) do
      {:suspended, %{suspended_replay: %{provisional_status: :armed}} = suspended} ->
        suspended = DownstreamState.demonitor_downstream(suspended)
        {:reply, :suspended, suspended}

      {:terminal_won, terminal} ->
        terminal =
          terminal
          |> Map.put(:terminal_winner_detach, %{
            reply_to: from,
            downstream: requested_downstream
          })
          |> settle_terminal_winner()

        {:noreply, terminal}

      {:failed, failed} ->
        terminate_predecessor_task(failed.active_turn)
        reply_active_turn(failed, {:error, :client_disconnected})

        failed =
          failed
          |> DownstreamState.demonitor_downstream()
          |> DownstreamState.cancel_active_turn_downstream(
            requested_downstream,
            :client_disconnected
          )
          |> Map.put(:downstream, nil)
          |> finish_active_turn({:error, :client_disconnected})

        reply_or_retire(failed, :ok)
    end
  end

  defp restore_suspending_descriptor(state, descriptor),
    do: put_in(state.active_turn.descriptor, descriptor)

  defp settle_terminal_winner(%{active_turn: %{pending_result: result}} = state)
       when not is_nil(result),
       do: settle_active_turn(state, result)

  defp settle_terminal_winner(state), do: state

  defp complete_terminal_winner_detach(
         %{terminal_winner_detach: %{reply_to: reply_to, downstream: downstream}} = state
       ) do
    GenServer.reply(reply_to, :ok)

    state
    |> DownstreamState.demonitor_downstream()
    |> Map.put(:terminal_winner_detach, nil)
    |> Map.put(:downstream, nil)
    |> DownstreamState.cancel_active_turn_downstream(downstream)
    |> DownstreamState.schedule_idle_shutdown()
  end

  defp complete_terminal_winner_detach(state), do: state

  defp suspend_input(state, descriptor) do
    authorization = descriptor.authorization_snapshot

    %{
      api_key_id: authorization.api_key_id,
      pool_id: authorization.pool_id,
      codex_session_id: state.codex_session_id,
      request_id: descriptor.request_id,
      codex_turn_id: descriptor.codex_turn_id,
      eligible_attempt_id: descriptor.attempt_id,
      api_key_runtime_epoch: authorization.api_key_runtime_epoch,
      model_id: descriptor.model_id,
      model_identifier: authorization.model_identifier,
      endpoint: descriptor.endpoint,
      semantic_turn_digest: descriptor.semantic_turn_digest,
      replay_claim_digest: descriptor.replay_claim_digest,
      owner_instance_id: state.owner_instance_id,
      owner_lease_token: state.owner_lease_token,
      predecessor_epoch: state.downstream.epoch,
      failure_reason: :client_disconnected,
      pre_visible_output: true
    }
  end

  defp prune_provisional_issuances(state, now_ms) do
    cutoff = now_ms - 30_000
    %{state | provisional_issuances: Enum.filter(state.provisional_issuances, &(&1 >= cutoff))}
  end

  defp native_message_mapper?(mapper) do
    mapper == (&StreamProtocol.canonicalize_native_codex_responses_json_message/1) or
      mapper == (&StreamProtocol.canonicalize_codex_responses_json_message/1)
  end

  defp output_commit_probe_required?(
         %{active_turn: %{downstream: %{owner_turn_id: owner_turn_id}}},
         {:error, %{transport_failure: transport_failure}}
       )
       when is_pid(owner_turn_id) and is_map(transport_failure) and
              map_size(transport_failure) > 0,
       do: true

  defp output_commit_probe_required?(_state, _result), do: false

  defp collect_request?(%UpstreamWebsocketSession.Request{
         websocket_delivery_mode: mode,
         writer: nil
       })
       when mode in [:collect_compaction, :collect_full_history],
       do: true

  defp collect_request?(_request), do: false

  defp maybe_complete_terminal_delivery(state, terminal?) do
    if terminal? do
      state = put_in(state.active_turn.terminal_forwarded?, true)

      case state.active_turn.pending_result do
        nil -> state
        result -> settle_active_turn(state, result)
      end
    else
      state
    end
  end

  defp fail_terminal_delivery(state, terminal?, reason) do
    if terminal? do
      settle_active_turn(state, {:error, reason})
    else
      state
    end
  end

  defp retain_terminal_result(state, result) do
    timer_token = make_ref()
    turn_ref = state.active_turn.ref

    timer_ref =
      Process.send_after(
        self(),
        {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token},
        @terminal_delivery_timeout_ms
      )

    active_turn = %{
      state.active_turn
      | pending_result: result,
        terminal_delivery_timeout: {turn_ref, timer_token},
        terminal_delivery_timer_ref: timer_ref
    }

    %{state | active_turn: active_turn}
  end

  defp terminal_bearing_result?({:ok, %{terminal: terminal}}),
    do: terminal in @terminal_result_types

  defp terminal_bearing_result?(_result), do: false

  defp classify_terminal_delivery_frame(true, true), do: :duplicate_terminal
  defp classify_terminal_delivery_frame(true, false), do: {:forward, false}

  defp classify_terminal_delivery_frame(false, terminal?), do: {:forward, terminal?}

  defp terminal_frame?(payload) when is_binary(payload),
    do: match?({:ok, _outcome}, StreamProtocol.terminal_outcome(payload))

  defp terminal_frame?(_payload), do: false

  defp cancel_terminal_delivery_timer(%{terminal_delivery_timer_ref: ref})
       when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_terminal_delivery_timer(_active_turn), do: :ok

  defp cancel_output_commit_probe_timer(%{output_commit_probe: %{timer_ref: ref}})
       when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_output_commit_probe_timer(_active_turn), do: :ok

  defp invalidate_upstream(state) do
    state.callbacks.upstream_invalidator.(state.upstream_pid)
  catch
    :exit, _reason -> {:error, :upstream_websocket_not_connected}
  end

  defp invalidate_owner_upstream(upstream_pid),
    do: UpstreamWebsocketSession.invalidate_connection(upstream_pid)

  defp terminal_delivery_timeout_result do
    {:error,
     %{
       reason: :upstream_websocket_terminal_delivery_timeout,
       transport_failure: %{
         "phase" => "terminal_delivery",
         "reason_class" => "owner_terminal_delivery_timeout",
         "reason" => "upstream_websocket_terminal_delivery_timeout",
         "pre_visible_output" => false,
         "upstream_committed" => true,
         "terminal_seen" => true,
         "terminal_forwarded" => false
       }
     }}
  end

  defp schedule_owner_renewal(
         %{
           owner_renewal_ms: timeout,
           owner_renewal_delay: renewal_delay,
           codex_session_id: session_id
         } = state
       )
       when is_integer(timeout) and timeout > 0 and is_function(renewal_delay, 1) do
    if uuid?(session_id) do
      delay = bounded_owner_renewal_delay(renewal_delay.(timeout), timeout)

      %{state | owner_renewal_ref: Process.send_after(self(), :renew_owner_lease, delay)}
    else
      state
    end
  end

  defp schedule_owner_renewal(state), do: state

  defp forward_error_body?(%UpstreamWebsocketSession.Request{forward_error_body?: value}),
    do: value

  defp forward_error_body?(_upstream_payload), do: false

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

      {:error, %{upstream_websocket_connection: connection} = response}
      when is_map(connection) ->
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

  defp touch_active_replay_liveness(%{suspended_replay: %{consume_binding: binding}} = state)
       when is_map(binding) do
    _result = CodexPooler.Accounting.touch_request_replay_liveness(binding)
    state
  end

  defp touch_active_replay_liveness(state), do: state

  defp jittered_owner_renewal_delay(timeout) when is_integer(timeout) and timeout > 0 do
    minimum = max(timeout - div(timeout, 5), 1)
    minimum + :rand.uniform(timeout - minimum + 1) - 1
  end

  defp bounded_owner_renewal_delay(delay, timeout)
       when is_integer(delay) and delay > 0 and delay <= timeout,
       do: delay

  defp bounded_owner_renewal_delay(_delay, timeout), do: timeout

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
        release_owner_lease: &SessionContinuity.release_owner_lease/4,
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

  defp owner_exit_cause(:normal, %{owner_exit_cause: cause})
       when cause in [:idle_expiry, :drain_cut],
       do: cause

  defp owner_exit_cause(_reason, _state), do: nil

  defp owner_error(error)
       when error in [
              :owner_unavailable,
              :stale_owner,
              :owner_forward_timeout,
              :owner_crashed,
              :owner_busy,
              :owner_drained,
              :client_disconnected,
              :upstream_stream_error,
              :upstream_websocket_terminal_delivery_timeout
            ],
       do: error

  defp owner_error({:error, error}), do: owner_error(error)
  defp owner_error(:normal), do: :owner_unavailable
  defp owner_error(_reason), do: :owner_crashed

  defp active_turn_downstream(stable_downstream, downstream) do
    case DownstreamState.downstream_status(stable_downstream, downstream) do
      :active -> validate_active_turn_downstream(stable_downstream, downstream)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_active_turn_downstream(stable_downstream, downstream) do
    cond do
      exact_keys?(stable_downstream, @stable_downstream_keys) and
        exact_keys?(downstream, @public_per_call_downstream_keys) and
        is_pid(Map.get(downstream, :owner_turn_id)) and
          Map.take(downstream, @stable_downstream_keys) == stable_downstream ->
        {:ok, downstream}

      exact_keys?(stable_downstream, @stable_downstream_keys) and
          (exact_keys?(downstream, @stable_downstream_keys) or
             exact_keys?(downstream, @restore_downstream_keys)) ->
        {:ok, stable_downstream}

      true ->
        {:error, :stale_downstream}
    end
  end

  defp exact_keys?(map, keys) when is_map(map) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp exact_keys?(_map, _keys), do: false

  defp owner_call_timeout, do: WebsocketOwnerContract.default_owner_call_timeout_ms()
end
