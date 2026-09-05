defmodule CodexPooler.Gateway.Websocket.DownstreamSession do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Transports.Websocket.{
    RolloutDrain,
    WebsocketOwnerContract,
    WebsocketOwnerForwarder,
    WebsocketOwnerSession
  }

  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.OwnerCleanup

  @type socket_state :: map()
  @type monitor_result ::
          {:ok, socket_state()} | {:stop, {pos_integer(), String.t()}, socket_state()}

  @owner_recovery_reasons [
    :owner_unavailable,
    :owner_forward_timeout,
    :owner_crashed,
    :owner_drained
  ]

  @spec owner?(socket_state()) :: boolean()
  def owner?(state), do: is_map(Map.get(state, :websocket_owner_downstream))

  @spec put_runtime(socket_state(), Websocket.websocket_runtime()) :: socket_state()
  def put_runtime(
        state,
        %{
          codex_session: session,
          websocket_owner_lease_token: owner_lease_token,
          websocket_owner_downstream: downstream
        } = runtime
      ) do
    state
    |> Map.delete(:websocket_owner_cleanup_witness)
    |> Map.delete(:websocket_owner_cleanup_task)
    |> Map.put(:codex_session, session)
    |> Map.put(:websocket_owner_lease_token, owner_lease_token)
    |> Map.put(:websocket_owner_downstream, downstream)
    |> Map.put(
      :websocket_owner_active_turn_reconnect?,
      Map.get(runtime, :websocket_owner_active_turn_reconnect?, false)
    )
    |> put_monitor(session)
  end

  @spec accept_cleanup_witness(term(), socket_state()) :: socket_state()
  def accept_cleanup_witness(
        {:websocket_owner_cleanup_witness, correlation, epoch, task, %OwnerCleanup{} = witness},
        %{
          codex_session: %{id: session_id, owner_instance_id: owner},
          websocket_owner_lease_token: lease,
          websocket_owner_downstream: %{correlation_id: correlation, epoch: epoch},
          tasks: tasks
        } = state
      ) do
    if MapSet.member?(tasks, task) and witness.session_id == session_id and
         witness.owner_instance_id == owner and witness.owner_lease_token == lease and
         witness.downstream_epoch == epoch do
      state
      |> Map.put(:websocket_owner_cleanup_witness, witness)
      |> Map.put(:websocket_owner_cleanup_task, task)
    else
      state
    end
  end

  def accept_cleanup_witness(_message, state), do: state

  @spec clear_cleanup_witness(socket_state(), pid()) :: socket_state()
  def clear_cleanup_witness(%{websocket_owner_cleanup_task: task} = state, task) do
    state
    |> Map.delete(:websocket_owner_cleanup_witness)
    |> Map.delete(:websocket_owner_cleanup_task)
  end

  def clear_cleanup_witness(state, _task), do: state

  @spec handle_monitor_down(socket_state(), pid(), term()) :: monitor_result()
  def handle_monitor_down(state, owner_pid, reason) when is_pid(owner_pid) do
    state = clear_monitor(state, owner_pid)

    case effective_monitor_down_reason(state, reason) do
      :stale_owner ->
        {:ok, state}

      :owner_drained ->
        handle_owner_exit(:owner_drained, state, reason)

      :owner_crashed ->
        {:ok, state} = handle_owner_exit(:owner_crashed, state, reason)
        {:stop, close_detail(:owner_crashed), state}
    end
  end

  @spec clear_monitor(socket_state(), pid()) :: socket_state()
  def clear_monitor(state, owner_pid) when is_pid(owner_pid) do
    if Map.get(state, :websocket_owner_pid) == owner_pid do
      state
      |> Map.delete(:websocket_owner_pid)
      |> Map.delete(:websocket_owner_monitor)
    else
      state
    end
  end

  @spec clear_monitor(socket_state()) :: socket_state()
  def clear_monitor(state) do
    if owner_monitor = Map.get(state, :websocket_owner_monitor) do
      Process.demonitor(owner_monitor, [:flush])
    end

    state
    |> Map.delete(:websocket_owner_pid)
    |> Map.delete(:websocket_owner_monitor)
  end

  @spec close_detail(term()) :: {pos_integer(), String.t()}
  def close_detail(:owner_crashed), do: {1011, "websocket owner crashed"}
  def close_detail(:owner_forward_timeout), do: {1011, "websocket owner forwarding timed out"}
  def close_detail(:owner_unavailable), do: {1011, "websocket owner is unavailable"}
  def close_detail(:owner_drained), do: {1001, "websocket owner is draining"}
  def close_detail(:stale_owner), do: {1011, "websocket owner lease is stale"}
  def close_detail(_reason), do: {1011, "websocket owner unavailable"}

  @spec maybe_retarget_before_start(binary(), socket_state()) ::
          {:ok, socket_state()} | {:error, WebsocketOwnerContract.owner_error()}
  def maybe_retarget_before_start(payload, %{websocket_owner_downstream: downstream} = state)
      when is_binary(payload) and is_map(downstream) do
    with {:ok, %{} = decoded_payload} <- Jason.decode(payload),
         {:ok, runtime} <-
           Websocket.retarget_websocket_owner_runtime(
             state.auth,
             runtime_state(state),
             decoded_payload,
             Map.get(state, :opts, %{})
           ) do
      {:ok, maybe_put_retargeted_runtime(state, runtime)}
    else
      {:error, %Jason.DecodeError{}} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  def maybe_retarget_before_start(_payload, state), do: {:ok, state}

  @spec accept_downstream_message(term(), socket_state()) ::
          WebsocketOwnerContract.downstream_match_result() | :drop
  def accept_downstream_message(
        message,
        %{
          opts: %RequestOptions{
            openai_compatibility: %{public_openai_responses_stream: true}
          },
          public_response_task_pid: owner_turn_id,
          websocket_owner_downstream: downstream
        }
      )
      when is_pid(owner_turn_id) and is_map(downstream) do
    WebsocketOwnerContract.accept_downstream_message(
      message,
      Map.get(downstream, :epoch),
      Map.get(downstream, :correlation_id),
      owner_turn_id
    )
  end

  def accept_downstream_message(
        _message,
        %{
          opts: %RequestOptions{
            openai_compatibility: %{public_openai_responses_stream: true}
          }
        }
      ),
      do: :drop

  def accept_downstream_message(
        {:websocket_owner_frame, _correlation_id, _epoch, owner_turn_id, _payload} = message,
        %{websocket_owner_downstream: downstream, tasks: tasks} = state
      )
      when is_pid(owner_turn_id) and is_map(downstream) do
    if MapSet.member?(tasks, owner_turn_id) or reconnect_owner_turn?(state, owner_turn_id) do
      WebsocketOwnerContract.accept_downstream_message(
        message,
        Map.get(downstream, :epoch),
        Map.get(downstream, :correlation_id),
        owner_turn_id
      )
    else
      :drop
    end
  end

  def accept_downstream_message(message, %{websocket_owner_downstream: downstream})
      when is_map(downstream) do
    WebsocketOwnerContract.accept_downstream_message(
      message,
      Map.get(downstream, :epoch),
      Map.get(downstream, :correlation_id)
    )
  end

  def accept_downstream_message(_message, _state), do: :drop

  @spec accept_handoff_message(term(), socket_state()) ::
          {:ok, WebsocketOwnerContract.handoff_outcome()}
          | {:ok, {:ready, pid()}}
          | {:ok, {{:failed, :owner_forward_timeout | :owner_drained}, pid()}}
          | :drop
  def accept_handoff_message(
        message,
        %{
          websocket_owner_downstream: %{
            pid: downstream_pid,
            epoch: epoch,
            correlation_id: correlation_id
          },
          websocket_owner_pending_handoff: %{
            owner_turn_id: owner_turn_id,
            control_ref: control_ref
          }
        }
      )
      when is_pid(downstream_pid) and is_integer(epoch) and epoch > 0 and
             is_binary(correlation_id) and is_pid(owner_turn_id) and is_reference(control_ref) do
    case WebsocketOwnerContract.accept_handoff_message(
           message,
           downstream_pid,
           epoch,
           correlation_id,
           owner_turn_id,
           control_ref
         ) do
      {:error, :invalid_handoff_message} -> :drop
      result -> result
    end
  end

  def accept_handoff_message(
        {:websocket_owner_handoff_ready, correlation_id, epoch, owner_turn_id, downstream_pid,
         control_ref} = message,
        %{
          websocket_owner_downstream: %{
            pid: downstream_pid,
            epoch: epoch,
            correlation_id: correlation_id
          },
          websocket_owner_pending_handoff: %{
            owner_turn_id: nil,
            control_ref: control_ref
          }
        }
      )
      when is_pid(owner_turn_id) do
    case WebsocketOwnerContract.accept_handoff_message(
           message,
           downstream_pid,
           epoch,
           correlation_id,
           owner_turn_id,
           control_ref
         ) do
      {:ok, :ready} -> {:ok, {:ready, owner_turn_id}}
      _other -> :drop
    end
  end

  def accept_handoff_message(
        {:websocket_owner_handoff_failed, correlation_id, epoch, owner_turn_id, downstream_pid,
         control_ref, reason} = message,
        %{
          websocket_owner_downstream: %{
            pid: downstream_pid,
            epoch: epoch,
            correlation_id: correlation_id
          },
          websocket_owner_pending_handoff: %{
            owner_turn_id: nil,
            control_ref: control_ref
          }
        }
      )
      when is_pid(owner_turn_id) do
    case WebsocketOwnerContract.accept_handoff_message(
           message,
           downstream_pid,
           epoch,
           correlation_id,
           owner_turn_id,
           control_ref
         ) do
      {:ok, {:failed, ^reason}} -> {:ok, {{:failed, reason}, owner_turn_id}}
      _other -> :drop
    end
  end

  def accept_handoff_message(_message, _state), do: :drop

  @spec preflight_reconnect(socket_state(), <<_::256>>, reference()) ::
          WebsocketOwnerSession.reconnect_preflight_result()
  def preflight_reconnect(state, semantic_turn_key, control_ref)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_reference(control_ref) do
    Websocket.preflight_websocket_owner_reconnect(
      Map.get(state, :codex_session),
      Map.get(state, :websocket_owner_lease_token),
      Map.get(state, :websocket_owner_downstream),
      semantic_turn_key,
      control_ref,
      Map.get(state, :opts, %{})
    )
  end

  @spec reconnect_control_v2(
          socket_state(),
          CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2.t()
        ) :: term()
  def reconnect_control_v2(state, control) do
    WebsocketOwnerForwarder.reconnect_control_v2(
      Map.get(state, :codex_session),
      Map.get(state, :websocket_owner_lease_token),
      control,
      forwarder_opts(Map.get(state, :opts))
    )
  end

  defp forwarder_opts(%RequestOptions{transport: %{websocket_owner: owner}}),
    do: owner.forwarder_opts

  defp forwarder_opts(opts) when is_map(opts),
    do: Map.get(opts, :websocket_owner_forwarder_opts, [])

  defp forwarder_opts(opts) when is_list(opts),
    do: Keyword.get(opts, :websocket_owner_forwarder_opts, [])

  defp forwarder_opts(_opts), do: []

  @spec cancel_reconnect(socket_state(), <<_::256>>, reference()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def cancel_reconnect(state, semantic_turn_key, control_ref)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_reference(control_ref) do
    Websocket.cancel_websocket_owner_reconnect(
      Map.get(state, :codex_session),
      Map.get(state, :websocket_owner_lease_token),
      Map.get(state, :websocket_owner_downstream),
      semantic_turn_key,
      control_ref,
      Map.get(state, :opts, %{})
    )
  end

  defp reconnect_owner_turn?(state, owner_turn_id) do
    Map.get(state, :websocket_owner_active_turn_reconnect?, false) and
      Map.get(state, :websocket_owner_reconnect_turn_pid) == owner_turn_id
  end

  @spec accept_recovered_runtime(term(), socket_state()) :: {:ok, socket_state()} | :drop
  def accept_recovered_runtime(
        {:websocket_owner_runtime_recovered, correlation_id, epoch,
         %{
           codex_session: %{owner_lease_token: owner_lease_token},
           websocket_owner_lease_token: owner_lease_token,
           websocket_owner_downstream: %{
             correlation_id: correlation_id,
             epoch: epoch
           }
         } = runtime},
        %{
          websocket_owner_downstream: %{
            correlation_id: correlation_id,
            epoch: epoch
          }
        } = state
      )
      when is_binary(correlation_id) and is_integer(epoch) and epoch > 0 and
             is_binary(owner_lease_token) do
    {:ok, state |> clear_monitor() |> put_runtime(runtime)}
  end

  def accept_recovered_runtime(_message, _state), do: :drop

  @spec retarget_error_payload(term()) :: {:error, term()}
  def retarget_error_payload(reason) do
    case WebsocketOwnerContract.safe_error_payload(reason, nil) do
      {:ok, payload} -> {:error, payload}
      {:error, _reason} -> {:error, reason}
    end
  end

  @spec response_options(socket_state(), pid() | nil) :: RequestOptions.t()
  def response_options(state, owner_turn_id \\ nil) do
    Websocket.websocket_owner_response_options(
      Map.get(state, :opts, %{}),
      Map.get(state, :codex_session),
      Map.get(state, :websocket_owner_lease_token),
      per_call_downstream(state, owner_turn_id)
    )
  end

  @spec cleanup(socket_state(), term()) :: :ok
  def cleanup(state, reason \\ :closed) do
    if rollout_drain_cleanup?(state, reason) do
      record_owner_drained_cleanup(state)
    else
      detach_downstream(state)
    end
  end

  @spec cancel_owner_turn(socket_state(), pid(), :owner_drained) :: :ok
  def cancel_owner_turn(state, owner_turn_id, :owner_drained)
      when is_pid(owner_turn_id) do
    session = Map.get(state, :codex_session)
    owner_lease_token = Map.get(state, :websocket_owner_lease_token)
    downstream = per_call_downstream(state, owner_turn_id)
    opts = Map.get(state, :opts, %{})

    _result =
      Websocket.cancel_websocket_owner_turn(
        session,
        owner_lease_token,
        downstream,
        :owner_drained,
        opts
      )

    :ok
  end

  defp detach_downstream(state) do
    state
    |> Map.get(:codex_session)
    |> Websocket.detach_websocket_owner_downstream(
      Map.get(state, :websocket_owner_lease_token),
      Map.get(state, :websocket_owner_downstream),
      Map.get(state, :opts, %{})
    )
    |> after_detach(state)
  end

  defp rollout_drain_cleanup?(state, reason) do
    local_owner?(state) and (RolloutDrain.draining?() or shutdown_reason?(reason))
  end

  defp local_owner?(%{codex_session: %{owner_instance_id: owner_instance_id}} = state)
       when is_binary(owner_instance_id) do
    owner?(state) and owner_instance_id == Atom.to_string(node())
  end

  defp local_owner?(_state), do: false

  defp shutdown_reason?(:shutdown), do: true
  defp shutdown_reason?({:shutdown, _details}), do: true
  defp shutdown_reason?(_reason), do: false

  defp record_owner_drained_cleanup(state) do
    _owner_drain_result = drain_owner_session(state)
    recovery_result = recover_leftovers({:error, :owner_drained}, state)

    if match?({:ok, _result}, recovery_result) do
      "owner_drained"
      |> release_lease(state)
      |> log_monitor_lease_release(state, :owner_drained)
    end
  end

  defp drain_owner_session(%{websocket_owner_pid: owner_pid}) when is_pid(owner_pid) do
    if Process.alive?(owner_pid) do
      WebsocketOwnerSession.drain_owner(owner_pid)
    else
      {:error, :owner_unavailable}
    end
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp drain_owner_session(_state), do: {:error, :owner_unavailable}

  defp put_monitor(state, session) do
    case Websocket.monitor_websocket_owner(session) do
      {:ok, owner_pid, owner_monitor} ->
        state
        |> Map.put(:websocket_owner_pid, owner_pid)
        |> Map.put(:websocket_owner_monitor, owner_monitor)

      {:error, _reason} ->
        state
    end
  end

  defp monitor_down_reason(:stale_owner), do: :stale_owner
  defp monitor_down_reason({:shutdown, :stale_owner}), do: :stale_owner
  defp monitor_down_reason(:normal), do: :owner_drained
  defp monitor_down_reason(:shutdown), do: :owner_drained
  defp monitor_down_reason({:shutdown, _details}), do: :owner_drained
  defp monitor_down_reason(_reason), do: :owner_crashed

  defp effective_monitor_down_reason(%{websocket_owner_drain_observed?: true}, reason) do
    case monitor_down_reason(reason) do
      :owner_crashed -> :owner_drained
      owner_reason -> owner_reason
    end
  end

  defp effective_monitor_down_reason(_state, reason), do: monitor_down_reason(reason)

  defp handle_owner_exit(owner_reason, state, raw_reason) do
    recovery_result =
      {:error, owner_reason}
      |> recover_leftovers(state)

    log_monitor_recovery(recovery_result, state, raw_reason)

    if match?({:ok, _recovered}, recovery_result) do
      owner_reason
      |> Atom.to_string()
      |> release_lease(state)
      |> log_monitor_lease_release(state, raw_reason)
    end

    {:ok, state}
  end

  defp runtime_state(state) do
    %{
      codex_session: Map.get(state, :codex_session),
      websocket_owner_lease_token: Map.get(state, :websocket_owner_lease_token),
      websocket_owner_downstream: Map.get(state, :websocket_owner_downstream),
      websocket_owner_active_turn_reconnect?:
        Map.get(state, :websocket_owner_active_turn_reconnect?, false)
    }
  end

  defp maybe_put_retargeted_runtime(state, runtime) do
    if runtime == runtime_state(state) do
      state
    else
      state
      |> clear_monitor()
      |> put_runtime(runtime)
    end
  end

  defp per_call_downstream(state, owner_turn_id) do
    downstream = Map.get(state, :websocket_owner_downstream)

    if is_map(downstream) and is_pid(owner_turn_id) do
      Map.put(downstream, :owner_turn_id, owner_turn_id)
    else
      downstream
    end
  end

  defp after_detach(result, state) do
    recovery_result = recover_leftovers(result, state)

    _interrupt_result =
      if result in [:reattachable, :suspended],
        do: :ok,
        else: interrupt_downstream_turn(result, state)

    log_detach_failure(result, state, recovery_result)
  end

  defp interrupt_downstream_turn(:ok, state) do
    unless idle_without_cleanup_authority?(state) do
      state
      |> Map.get(:codex_session)
      |> Websocket.interrupt_detached_codex_turn(downstream_interrupt_opts(state))
      |> log_interrupt_failure(state)
    end

    :ok
  end

  defp interrupt_downstream_turn(_result, _state), do: :ok

  defp recover_leftovers({:error, reason}, state) when reason in @owner_recovery_reasons do
    if idle_without_cleanup_authority?(state) do
      {:ok, %{interrupted_turn_count: 0}}
    else
      state
      |> Map.get(:codex_session)
      |> Websocket.recover_owner_lifecycle_leftovers(
        reason,
        lifecycle_recovery_opts(state, reason)
      )
      |> log_lifecycle_recovery_failure(state)
    end
  end

  defp recover_leftovers(_result, _state), do: :ok

  defp idle_without_cleanup_authority?(state) do
    Enum.all?(
      [
        :websocket_owner_cleanup_witness,
        :websocket_owner_cleanup_task,
        :websocket_owner_reconnect_turn_pid,
        :websocket_owner_pending_handoff,
        :public_response_task_pid
      ],
      &is_nil(Map.get(state, &1))
    ) and Map.get(state, :websocket_owner_active_turn_reconnect?, false) != true and
      MapSet.size(Map.get(state, :tasks, MapSet.new())) == 0 and
      map_size(Map.get(state, :direct_cleanup_contexts, %{})) == 0 and
      map_size(Map.get(state, :direct_cleanup_receipts, %{})) == 0 and
      :queue.is_empty(Map.get(state, :queued_response_payloads, :queue.new()))
  end

  defp lifecycle_recovery_opts(state, reason) do
    interrupt_reason = reason |> failure_reason() |> lifecycle_interrupt_reason()

    put_lifecycle_recovery_opts(state, interrupt_reason)
  end

  defp put_lifecycle_recovery_opts(state, interrupt_reason) do
    state
    |> Map.get(:opts, %{})
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_runtime_context(interrupt_reason: interrupt_reason)
    |> RequestOptions.put_continuity(reconnect_window_seconds: 300)
    |> RequestOptions.put_transport(
      websocket_owner_lease_token: Map.get(state, :websocket_owner_lease_token)
    )
    |> OwnerCleanup.put_options(Map.get(state, :websocket_owner_cleanup_witness))
  end

  defp lifecycle_interrupt_reason(reason)
       when reason in [
              "owner_unavailable",
              "owner_forward_timeout",
              "owner_crashed",
              "owner_drained"
            ],
       do: reason

  defp lifecycle_interrupt_reason(_reason), do: "owner_unavailable"

  defp downstream_interrupt_opts(state) do
    put_lifecycle_recovery_opts(state, "client_disconnected")
  end

  defp release_lease(reason, state) do
    Websocket.release_websocket_owner_lease(
      Map.get(state, :codex_session),
      Map.get(state, :websocket_owner_lease_token),
      reason
    )
  end

  defp log_monitor_recovery({:ok, _result}, _state, _reason), do: :ok

  defp log_monitor_recovery({:error, recovery_reason}, state, owner_reason) do
    Logger.warning(
      "websocket owner monitor recovery failed " <>
        "codex_session_id=#{codex_session_id(state)} " <>
        "owner_instance_id=#{owner_instance_id(state)} " <>
        "request_id=#{request_id(Map.get(state, :opts))} " <>
        "owner_reason=#{failure_reason(owner_reason)} " <>
        "failure_reason=#{failure_reason(recovery_reason)}"
    )

    :ok
  end

  defp log_monitor_lease_release(:ok, _state, _reason), do: :ok

  defp log_monitor_lease_release({:error, :stale_owner}, _state, _reason), do: :ok

  defp log_monitor_lease_release({:error, release_reason}, state, owner_reason) do
    Logger.warning(
      "websocket owner monitor lease release failed " <>
        "codex_session_id=#{codex_session_id(state)} " <>
        "owner_instance_id=#{owner_instance_id(state)} " <>
        "request_id=#{request_id(Map.get(state, :opts))} " <>
        "owner_reason=#{failure_reason(owner_reason)} " <>
        "failure_reason=#{failure_reason(release_reason)}"
    )

    :ok
  end

  defp log_detach_failure(:ok, _state, _recovery_result), do: :ok
  defp log_detach_failure(:reattachable, _state, _recovery_result), do: :ok
  defp log_detach_failure(:suspended, _state, _recovery_result), do: :ok
  defp log_detach_failure(:detached_stale_downstream, _state, _recovery_result), do: :ok

  defp log_detach_failure({:error, reason}, state, {:ok, recovery}) do
    if interrupted_turn_count(recovery) > 0 do
      log_detach_failure({:error, reason}, state, :log_warning)
    else
      :ok
    end
  end

  defp log_detach_failure({:error, reason}, state, :log_warning) do
    Logger.warning(
      "websocket owner detach failed " <>
        "codex_session_id=#{codex_session_id(state)} " <>
        "owner_instance_id=#{owner_instance_id(state)} " <>
        "request_id=#{request_id(Map.get(state, :opts))} " <>
        "downstream_epoch=#{downstream_epoch(Map.get(state, :websocket_owner_downstream))} " <>
        "failure_reason=#{failure_reason(reason)}"
    )

    :ok
  end

  defp log_detach_failure({:error, reason}, state, {:error, _recovery_failure}) do
    log_detach_failure({:error, reason}, state, :log_warning)
  end

  defp interrupted_turn_count(%{interrupted_turn_count: count}) when is_integer(count), do: count
  defp interrupted_turn_count(_recovery), do: 0

  defp log_lifecycle_recovery_failure({:ok, _result} = result, _state), do: result

  defp log_lifecycle_recovery_failure({:error, reason}, state) do
    Logger.warning(
      "websocket owner lifecycle recovery failed " <>
        "codex_session_id=#{codex_session_id(state)} " <>
        "owner_instance_id=#{owner_instance_id(state)} " <>
        "request_id=#{request_id(Map.get(state, :opts))} " <>
        "downstream_epoch=#{downstream_epoch(Map.get(state, :websocket_owner_downstream))} " <>
        "failure_reason=#{failure_reason(reason)}"
    )

    {:error, reason}
  end

  defp log_interrupt_failure({:ok, _result}, _state), do: :ok

  defp log_interrupt_failure({:error, reason}, state) do
    Logger.warning(
      "websocket interrupt cleanup failed " <>
        "codex_session_id=#{codex_session_id(state)} " <>
        "failure_reason=#{failure_reason(reason)}"
    )

    :ok
  end

  defp codex_session_id(%{codex_session: %{id: id}}) when is_binary(id), do: id
  defp codex_session_id(_state), do: "none"

  defp owner_instance_id(%{codex_session: %{owner_instance_id: owner_instance_id}})
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp owner_instance_id(_state), do: "none"

  defp downstream_epoch(%{epoch: epoch}) when is_integer(epoch), do: Integer.to_string(epoch)
  defp downstream_epoch(_downstream), do: "none"

  defp request_id(%RequestOptions{} = opts), do: opts.request_metadata.request_id
  defp request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id
  defp request_id(_opts), do: "none"

  defp failure_reason({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(%module{}), do: inspect(module)
  defp failure_reason(_reason), do: "unknown"
end
