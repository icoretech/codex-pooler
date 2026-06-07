defmodule CodexPoolerWeb.CodexResponsesSocket do
  @moduledoc false

  @behaviour WebSock

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.ToolResultShape
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata, as: FinalizationMetadata
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket
  alias CodexPoolerWeb.WebsocketConnectionLogger

  require Logger

  @pre_cleanup_response_task_drain_ms 250
  @post_cleanup_owner_response_task_drain_ms 1_000
  @post_cleanup_response_task_drain_ms 5_000

  @impl WebSock
  def init(state) do
    started_at = System.monotonic_time(:millisecond)

    case Websocket.prepare_websocket_session(state.auth, state.opts) do
      {:ok,
       %{
         codex_session: session,
         websocket_owner_lease_token: owner_lease_token,
         websocket_owner_downstream: downstream
       } = runtime} ->
        {:ok, put_owner_runtime_state(state, session, owner_lease_token, downstream, runtime)}

      {:ok, %{codex_session: session, upstream_websocket_session: upstream_websocket_session}} ->
        {:ok,
         state
         |> put_socket_lifecycle_state()
         |> Map.put(:tasks, MapSet.new())
         |> Map.put(:task_monitors, %{})
         |> Map.put(:codex_session, session)
         |> Map.put(:upstream_websocket_session, upstream_websocket_session)}

      {:error, reason} ->
        init_error(reason, state, started_at)
    end
  end

  @impl WebSock
  def handle_in({payload, [opcode: :text]}, state) when is_binary(payload) do
    {:ok, start_or_queue_response_task(payload, state)}
  end

  def handle_in({_payload, [opcode: :binary]}, state) do
    {:stop, :unsupported_binary_frame, {1003, "binary frames are not supported"}, state}
  end

  @impl WebSock
  def handle_info({:codex_response_chunk, data}, state) when is_binary(data) do
    {:push, {:text, downstream_response_chunk(data)}, state}
  end

  def handle_info({:websocket_owner_frame, _correlation_id, _epoch, _payload} = message, state) do
    case accept_owner_downstream_message(message, state) do
      {:ok, {:data, data}} ->
        {:push, {:text, downstream_response_chunk(data)}, state}

      {:ok, {:error, _reason, payload}} ->
        {:push, {:text, Jason.encode!(websocket_error(payload))}, state}

      {:ok, :complete} ->
        {:ok, Map.put(state, :websocket_owner_active_turn_reconnect?, false)}

      :drop ->
        {:ok, state}

      {:error, _reason} ->
        {:ok, state}
    end
  end

  def handle_info({:codex_response_done, pid, :ok}, state) do
    state =
      state
      |> remove_tracked_response_task(pid)
      |> maybe_start_queued_response_task()

    {:ok, state}
  end

  def handle_info({:codex_response_done, pid, {:error, reason}}, state) do
    state =
      state
      |> remove_tracked_response_task(pid)
      |> maybe_start_queued_response_task()

    {:push, {:text, Jason.encode!(websocket_error(reason))}, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{websocket_owner_monitor: ref} = state) do
    state = clear_websocket_owner_monitor(state, pid)

    case owner_monitor_down_reason(reason) do
      :stale_owner ->
        {:ok, state}

      :owner_drained ->
        {:error, :owner_drained}
        |> recover_owner_lifecycle_leftovers(state)
        |> log_owner_monitor_recovery(state, reason)

        state
        |> release_owner_lease("owner_drained")
        |> log_owner_monitor_lease_release(state, reason)

        {:ok, state}

      :owner_crashed ->
        {:error, :owner_crashed}
        |> recover_owner_lifecycle_leftovers(state)
        |> log_owner_monitor_recovery(state, reason)

        state
        |> release_owner_lease("owner_crashed")
        |> log_owner_monitor_lease_release(state, reason)

        {:stop, :normal, owner_close_detail(:owner_crashed), state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      state
      |> remove_tracked_response_task(pid, ref)
      |> maybe_start_queued_response_task()

    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(reason, state) do
    log_closed_before_request_reservation(reason, state)

    remaining_tasks =
      state
      |> Map.get(:tasks, MapSet.new())
      |> await_response_tasks(@pre_cleanup_response_task_drain_ms)

    cleanup_websocket_session(state)

    close_upstream_websocket_session(state)

    _remaining_tasks = remaining_response_tasks_after_cleanup(state, remaining_tasks)

    :ok
  end

  defp downstream_response_chunk(data) when is_binary(data),
    do: StreamProtocol.canonicalize_codex_responses_json_message(data)

  defp remaining_response_tasks_after_cleanup(state, remaining_tasks) do
    if owner_forwarded_socket?(state) do
      await_response_tasks(remaining_tasks, @post_cleanup_owner_response_task_drain_ms)
    else
      await_response_tasks(remaining_tasks, @post_cleanup_response_task_drain_ms)
    end
  end

  defp log_closed_before_request_reservation(
         reason,
         %{request_response_work_started?: false} = state
       ) do
    unless clean_pre_request_close_reason?(reason) do
      state
      |> terminate_close_metadata()
      |> WebsocketConnectionLogger.log_closed_before_request_reservation(reason)
    end

    :ok
  end

  defp log_closed_before_request_reservation(_reason, _state), do: :ok

  defp clean_pre_request_close_reason?(:normal), do: true
  defp clean_pre_request_close_reason?(:shutdown), do: true
  defp clean_pre_request_close_reason?({:shutdown, _reason}), do: true
  defp clean_pre_request_close_reason?(_reason), do: false

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

  defp failure_reason({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(%module{}), do: inspect(module)
  defp failure_reason(_reason), do: "unknown"

  defp put_owner_runtime_state(state, session, owner_lease_token, downstream, runtime) do
    state
    |> put_socket_lifecycle_state()
    |> Map.put(:tasks, MapSet.new())
    |> Map.put(:task_monitors, %{})
    |> Map.put(:codex_session, session)
    |> Map.put(:websocket_owner_lease_token, owner_lease_token)
    |> Map.put(:websocket_owner_downstream, downstream)
    |> Map.put(
      :websocket_owner_active_turn_reconnect?,
      Map.get(runtime, :websocket_owner_active_turn_reconnect?, false)
    )
    |> put_websocket_owner_monitor(session)
  end

  defp put_socket_lifecycle_state(state) do
    state
    |> Map.put(:connection_started_at_monotonic_ms, System.monotonic_time(:millisecond))
    |> Map.put(:request_response_work_started?, false)
  end

  defp put_websocket_owner_monitor(state, session) do
    case Websocket.monitor_websocket_owner(session) do
      {:ok, owner_pid, owner_monitor} ->
        state
        |> Map.put(:websocket_owner_pid, owner_pid)
        |> Map.put(:websocket_owner_monitor, owner_monitor)

      {:error, _reason} ->
        state
    end
  end

  defp clear_websocket_owner_monitor(state, owner_pid) do
    if Map.get(state, :websocket_owner_pid) == owner_pid do
      state
      |> Map.delete(:websocket_owner_pid)
      |> Map.delete(:websocket_owner_monitor)
    else
      state
    end
  end

  defp owner_monitor_down_reason(:stale_owner), do: :stale_owner
  defp owner_monitor_down_reason({:shutdown, :stale_owner}), do: :stale_owner
  defp owner_monitor_down_reason(:normal), do: :owner_drained
  defp owner_monitor_down_reason(:shutdown), do: :owner_drained
  defp owner_monitor_down_reason({:shutdown, _details}), do: :owner_drained
  defp owner_monitor_down_reason(_reason), do: :owner_crashed

  defp init_error(reason, state, started_at) do
    log_init_failed_before_request_reservation(reason, state, started_at)

    if WebsocketOwnerContract.owner_error?(reason) do
      {:stop, :normal, owner_close_detail(reason), state}
    else
      {:stop, reason, state}
    end
  end

  defp log_init_failed_before_request_reservation(reason, state, started_at) do
    state
    |> init_failure_metadata(started_at)
    |> WebsocketConnectionLogger.log_init_failed_before_request_reservation(reason)
  end

  defp init_failure_metadata(state, started_at) do
    opts = Map.get(state, :opts)

    %{
      request_id: request_id(opts),
      endpoint: metadata_endpoint(opts),
      transport: metadata_transport(opts),
      route_class: metadata_route_class(opts),
      phase: "init",
      elapsed_ms: socket_elapsed_ms(started_at),
      codex_session_id: metadata_codex_session_id(state, opts),
      owner_instance_id: metadata_owner_instance_id(state, opts),
      proxy_instance_id: metadata_proxy_instance_id(opts),
      downstream_epoch: metadata_downstream_epoch(state, opts)
    }
  end

  defp terminate_close_metadata(state) do
    opts = Map.get(state, :opts)

    %{
      request_id: request_id(opts),
      endpoint: metadata_endpoint(opts),
      transport: metadata_transport(opts),
      route_class: metadata_route_class(opts),
      phase: "terminate",
      elapsed_ms: socket_elapsed_ms(Map.get(state, :connection_started_at_monotonic_ms)),
      codex_session_id: metadata_codex_session_id(state, opts),
      owner_instance_id: metadata_owner_instance_id(state, opts),
      proxy_instance_id: metadata_proxy_instance_id(opts),
      downstream_epoch: metadata_downstream_epoch(state, opts)
    }
  end

  defp owner_close_detail(:owner_crashed), do: {1011, "websocket owner crashed"}

  defp owner_close_detail(:owner_forward_timeout),
    do: {1011, "websocket owner forwarding timed out"}

  defp owner_close_detail(:owner_unavailable), do: {1011, "websocket owner is unavailable"}
  defp owner_close_detail(:owner_drained), do: {1001, "websocket owner is draining"}
  defp owner_close_detail(:stale_owner), do: {1011, "websocket owner lease is stale"}
  defp owner_close_detail(_reason), do: {1011, "websocket owner unavailable"}

  defp log_owner_monitor_recovery({:ok, _result}, _state, _reason), do: :ok

  defp log_owner_monitor_recovery({:error, recovery_reason}, state, owner_reason) do
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

  defp release_owner_lease(state, reason) do
    Websocket.release_websocket_owner_lease(
      Map.get(state, :codex_session),
      Map.get(state, :websocket_owner_lease_token),
      reason
    )
  end

  defp log_owner_monitor_lease_release(:ok, _state, _reason), do: :ok

  defp log_owner_monitor_lease_release({:error, :stale_owner}, _state, _reason), do: :ok

  defp log_owner_monitor_lease_release({:error, release_reason}, state, owner_reason) do
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

  defp start_response_task(parent, payload, state) do
    Task.start(fn ->
      Process.flag(:sensitive, true)
      send(parent, {:codex_response_done, self(), safe_run_response(parent, payload, state)})
    end)
  end

  defp start_or_queue_response_task(payload, state) do
    cond do
      owner_forwarded_socket?(state) and active_response_task?(state) ->
        queue_response_payload(state, payload)

      active_response_task?(state) and continuity_ordered_payload?(payload) ->
        queue_response_payload(state, payload)

      suppress_owner_reconnect_replay?(payload, state) ->
        state

      true ->
        start_tracked_response_task(payload, state)
    end
  end

  defp maybe_start_queued_response_task(state) do
    if active_response_task?(state) do
      state
    else
      case Map.get(state, :queued_response_payloads, :queue.new()) |> :queue.out() do
        {{:value, payload}, queue} ->
          state = Map.put(state, :queued_response_payloads, queue)
          start_tracked_response_task(payload, state)

        {:empty, _queue} ->
          state
      end
    end
  end

  defp start_tracked_response_task(payload, state) do
    state = maybe_mark_request_response_work_started(state, payload)
    parent = self()
    {:ok, pid} = start_response_task(parent, payload, state)
    monitor = Process.monitor(pid)

    track_response_task(state, pid, monitor)
  end

  defp queue_response_payload(state, payload) do
    Map.update(
      state,
      :queued_response_payloads,
      :queue.from_list([payload]),
      &:queue.in(payload, &1)
    )
  end

  @spec maybe_mark_request_response_work_started(map(), term()) :: map()
  defp maybe_mark_request_response_work_started(state, payload) do
    if request_row_producing_response_payload?(payload) do
      Map.put(state, :request_response_work_started?, true)
    else
      state
    end
  end

  @spec request_row_producing_response_payload?(term()) :: boolean()
  defp request_row_producing_response_payload?(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "response.processed"}} -> true
      {:ok, %{"generate" => false}} -> false
      {:ok, %{"type" => "response.create"}} -> true
      {:ok, %{"model" => model}} when is_binary(model) and model != "" -> true
      _payload -> false
    end
  end

  defp request_row_producing_response_payload?(_payload), do: false

  defp continuity_ordered_payload?(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "response.processed"}} ->
        true

      {:ok,
       %{"type" => "response.create", "previous_response_id" => previous_response_id} = decoded}
      when is_binary(previous_response_id) ->
        decoded
        |> Map.get("input")
        |> ToolResultShape.items()
        |> Enum.any?()

      _payload ->
        false
    end
  end

  defp owner_forwarded_socket?(state), do: is_map(Map.get(state, :websocket_owner_downstream))

  defp active_response_task?(state), do: MapSet.size(Map.get(state, :tasks, MapSet.new())) > 0

  defp suppress_owner_reconnect_replay?(payload, state) do
    owner_forwarded_socket?(state) and
      Map.get(state, :websocket_owner_active_turn_reconnect?) == true and
      request_row_producing_response_payload?(payload)
  end

  defp track_response_task(state, pid, monitor) when is_pid(pid) and is_reference(monitor) do
    state
    |> Map.update(:tasks, MapSet.new([pid]), &MapSet.put(&1, pid))
    |> Map.update(:task_monitors, %{pid => monitor}, &Map.put(&1, pid, monitor))
  end

  defp remove_tracked_response_task(state, pid) when is_pid(pid) do
    {monitor, state} = pop_task_monitor(state, pid)

    if monitor do
      Process.demonitor(monitor, [:flush])
    end

    Map.update(state, :tasks, MapSet.new(), &MapSet.delete(&1, pid))
  end

  defp remove_tracked_response_task(state, pid, monitor)
       when is_pid(pid) and is_reference(monitor) do
    case Map.get(Map.get(state, :task_monitors, %{}), pid) do
      ^monitor -> remove_tracked_response_task(state, pid)
      _unknown -> state
    end
  end

  defp pop_task_monitor(state, pid) do
    {monitor, task_monitors} =
      state
      |> Map.get(:task_monitors, %{})
      |> Map.pop(pid)

    {monitor, Map.put(state, :task_monitors, task_monitors)}
  end

  defp safe_run_response(parent, payload, state) do
    opts = response_task_opts(state)

    try do
      run_response(parent, state.auth, payload, opts)
    rescue
      exception ->
        log_response_task_failure(:error, exception, __STACKTRACE__, payload, state, opts)
        response_task_failure()
    catch
      kind, reason ->
        log_response_task_failure(kind, reason, __STACKTRACE__, payload, state, opts)
        response_task_failure()
    end
  end

  defp accept_owner_downstream_message(message, %{websocket_owner_downstream: downstream})
       when is_map(downstream) do
    WebsocketOwnerContract.accept_downstream_message(
      message,
      Map.get(downstream, :epoch),
      Map.get(downstream, :correlation_id)
    )
  end

  defp accept_owner_downstream_message(_message, _state), do: :drop

  defp response_task_opts(state) do
    if Map.has_key?(state, :websocket_owner_downstream) do
      Websocket.websocket_owner_response_options(
        Map.get(state, :opts, %{}),
        Map.get(state, :codex_session),
        Map.get(state, :websocket_owner_lease_token),
        Map.get(state, :websocket_owner_downstream)
      )
    else
      local_response_task_opts(state)
    end
  end

  defp local_response_task_opts(state) do
    Websocket.websocket_response_options(
      Map.get(state, :opts, %{}),
      Map.get(state, :codex_session),
      Map.get(state, :upstream_websocket_session),
      MapSet.size(Map.get(state, :tasks, MapSet.new())) == 0
    )
  end

  defp cleanup_websocket_session(%{websocket_owner_downstream: downstream} = state)
       when is_map(downstream) do
    state
    |> Map.get(:codex_session)
    |> Websocket.detach_websocket_owner_downstream(
      Map.get(state, :websocket_owner_lease_token),
      downstream,
      Map.get(state, :opts, %{})
    )
    |> after_owner_detach(state)
  end

  defp cleanup_websocket_session(state) do
    state
    |> Map.get(:codex_session)
    |> Websocket.interrupt_codex_session(state.opts)
    |> log_interrupt_failure(state)
  end

  defp log_owner_detach_failure(:ok, _state, _recovery_result), do: :ok
  defp log_owner_detach_failure(:detached_stale_downstream, _state, _recovery_result), do: :ok

  defp log_owner_detach_failure({:error, reason}, state, {:ok, recovery}) do
    if interrupted_turn_count(recovery) > 0 do
      log_owner_detach_failure({:error, reason}, state, :log_warning)
    else
      :ok
    end
  end

  defp log_owner_detach_failure({:error, reason}, state, :log_warning) do
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

  defp log_owner_detach_failure({:error, reason}, state, {:error, _recovery_failure}) do
    log_owner_detach_failure({:error, reason}, state, :log_warning)
  end

  defp interrupted_turn_count(%{interrupted_turn_count: count}) when is_integer(count), do: count
  defp interrupted_turn_count(_recovery), do: 0

  defp after_owner_detach(result, state) do
    recovery_result = recover_owner_lifecycle_leftovers(result, state)
    _interrupt_result = interrupt_owner_downstream_turn(result, state)
    log_owner_detach_failure(result, state, recovery_result)
  end

  defp interrupt_owner_downstream_turn(:ok, state) do
    state
    |> Map.get(:codex_session)
    |> Websocket.interrupt_codex_turn(owner_downstream_interrupt_opts(state))
    |> log_interrupt_failure(state)
  end

  defp interrupt_owner_downstream_turn(_result, _state), do: :ok

  defp recover_owner_lifecycle_leftovers({:error, reason}, state)
       when reason in [:owner_unavailable, :owner_forward_timeout, :owner_crashed, :owner_drained] do
    state
    |> Map.get(:codex_session)
    |> Websocket.recover_owner_lifecycle_leftovers(
      reason,
      owner_lifecycle_recovery_opts(state, reason)
    )
    |> log_owner_lifecycle_recovery_failure(state)
  end

  defp recover_owner_lifecycle_leftovers(_result, _state), do: :ok

  defp owner_lifecycle_recovery_opts(state, reason) do
    interrupt_reason = reason |> failure_reason() |> owner_lifecycle_interrupt_reason()

    put_owner_lifecycle_recovery_opts(state, interrupt_reason)
  end

  defp put_owner_lifecycle_recovery_opts(%{opts: %RequestOptions{} = opts}, interrupt_reason) do
    opts
    |> RequestOptions.put_runtime_context(interrupt_reason: interrupt_reason)
    |> RequestOptions.put_continuity(reconnect_window_seconds: 300)
  end

  defp put_owner_lifecycle_recovery_opts(state, interrupt_reason) do
    state
    |> Map.get(:opts, %{})
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_runtime_context(interrupt_reason: interrupt_reason)
    |> RequestOptions.put_continuity(reconnect_window_seconds: 300)
  end

  defp owner_lifecycle_interrupt_reason(reason)
       when reason in [
              "owner_unavailable",
              "owner_forward_timeout",
              "owner_crashed",
              "owner_drained"
            ],
       do: reason

  defp owner_lifecycle_interrupt_reason(_reason), do: "owner_unavailable"

  defp owner_downstream_interrupt_opts(%{opts: %RequestOptions{} = opts}) do
    opts
    |> RequestOptions.put_runtime_context(interrupt_reason: "client_disconnected")
    |> RequestOptions.put_continuity(reconnect_window_seconds: 300)
  end

  defp owner_downstream_interrupt_opts(state) do
    state
    |> Map.get(:opts, %{})
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_runtime_context(interrupt_reason: "client_disconnected")
    |> RequestOptions.put_continuity(reconnect_window_seconds: 300)
  end

  defp log_owner_lifecycle_recovery_failure({:ok, _result} = result, _state), do: result

  defp log_owner_lifecycle_recovery_failure({:error, reason}, state) do
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

  defp run_response(parent, auth, payload, opts) do
    with {:ok, payload, opts} <- maybe_coerce_public_v1_response_create(payload, opts) do
      Websocket.run_websocket_response(auth, payload, opts, fn data ->
        send(parent, {:codex_response_chunk, data})
      end)
    end
  end

  defp maybe_coerce_public_v1_response_create(payload, %RequestOptions{} = opts)
       when is_binary(payload) do
    with true <- public_openai_responses_websocket?(opts),
         {:ok, %{} = decoded} <- Jason.decode(payload),
         true <- public_v1_response_create_frame?(decoded) do
      decoded
      |> Map.delete("type")
      |> Responses.coerce(opts)
      |> case do
        {:ok, %{payload: coerced_payload, request_options: request_options}} ->
          websocket_payload = Map.put_new(coerced_payload, "generate", true)
          {:ok, Jason.encode!(websocket_payload), request_options}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:ok, payload, opts}
      {:error, _reason} -> {:ok, payload, opts}
    end
  end

  defp maybe_coerce_public_v1_response_create(payload, opts), do: {:ok, payload, opts}

  defp public_v1_response_create_frame?(%{"type" => "response.create"} = payload),
    do: not Map.has_key?(payload, "generate")

  defp public_v1_response_create_frame?(_payload), do: false

  defp public_openai_responses_websocket?(%RequestOptions{
         openai_compatibility: %{source_endpoint: "/v1/responses"},
         transport: %{transport: "websocket"}
       }),
       do: true

  defp public_openai_responses_websocket?(_opts), do: false

  defp response_task_failure do
    {:error,
     %{
       status: 500,
       code: :websocket_response_task_failed,
       message: "websocket response task failed",
       param: nil
     }}
  end

  defp error_payload(%{code: code, message: message} = reason) do
    Map.merge(
      %{
        "message" => message,
        "type" => "invalid_request_error",
        "code" => to_string(code),
        "param" => Map.get(reason, :param)
      },
      Contracts.recovery_error_fields(reason)
    )
  end

  defp error_payload(reason) do
    %{
      "message" => "websocket request failed: #{FinalizationMetadata.safe_reason(reason)}",
      "type" => "invalid_request_error",
      "code" => "websocket_request_failed",
      "param" => nil
    }
  end

  defp websocket_error(%{status: status} = reason) do
    %{
      "type" => "error",
      "status" => status,
      "error" => error_payload(reason)
    }
  end

  defp websocket_error(reason) do
    %{
      "type" => "error",
      "status" => 500,
      "error" => error_payload(reason)
    }
  end

  defp request_id(%RequestOptions{} = opts), do: opts.request_metadata.request_id
  defp request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id
  defp request_id(_opts), do: "none"

  defp owner_instance_id(%{codex_session: %{owner_instance_id: owner_instance_id}})
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp owner_instance_id(_state), do: "none"

  defp downstream_epoch(%{epoch: epoch}) when is_integer(epoch), do: Integer.to_string(epoch)
  defp downstream_epoch(_downstream), do: "none"

  defp metadata_endpoint(%RequestOptions{transport: %{upstream_endpoint: endpoint}})
       when is_binary(endpoint),
       do: endpoint

  defp metadata_endpoint(%{endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp metadata_endpoint(%{upstream_endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp metadata_endpoint(_opts), do: nil

  defp metadata_transport(%RequestOptions{transport: %{transport: transport}})
       when is_binary(transport),
       do: transport

  defp metadata_transport(%{transport: transport}) when is_binary(transport), do: transport
  defp metadata_transport(_opts), do: nil

  defp metadata_route_class(%RequestOptions{} = opts), do: RequestOptions.route_class(opts)

  defp metadata_route_class(%{route_class: route_class}) when is_binary(route_class),
    do: route_class

  defp metadata_route_class(_opts), do: nil

  defp metadata_codex_session_id(%{codex_session: %{id: id}}, _opts) when is_binary(id), do: id

  defp metadata_codex_session_id(_state, %RequestOptions{continuity: %{codex_session: %{id: id}}})
       when is_binary(id),
       do: id

  defp metadata_codex_session_id(_state, _opts), do: nil

  defp metadata_owner_instance_id(
         %{codex_session: %{owner_instance_id: owner_instance_id}},
         _opts
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(
         _state,
         %RequestOptions{transport: %{websocket_owner_instance_id: owner_instance_id}}
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(
         _state,
         %RequestOptions{continuity: %{owner_instance_id: owner_instance_id}}
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(_state, %{owner_instance_id: owner_instance_id})
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(_state, _opts), do: nil

  defp metadata_proxy_instance_id(%RequestOptions{
         transport: %{websocket_owner_proxy_instance_id: proxy_instance_id}
       })
       when is_binary(proxy_instance_id),
       do: proxy_instance_id

  defp metadata_proxy_instance_id(%{websocket_owner_proxy_instance_id: proxy_instance_id})
       when is_binary(proxy_instance_id),
       do: proxy_instance_id

  defp metadata_proxy_instance_id(_opts), do: nil

  defp metadata_downstream_epoch(%{websocket_owner_downstream: downstream}, _opts)
       when is_map(downstream),
       do: downstream_epoch(downstream)

  defp metadata_downstream_epoch(
         _state,
         %RequestOptions{transport: %{websocket_owner_downstream_epoch: epoch}}
       )
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(_state, %{websocket_owner_downstream_epoch: epoch})
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(_state, _opts), do: nil

  defp socket_elapsed_ms(started_at) when is_integer(started_at) do
    max(System.monotonic_time(:millisecond) - started_at, 0)
  end

  defp socket_elapsed_ms(_started_at), do: nil

  defp log_response_task_failure(kind, reason, stacktrace, payload, state, opts) do
    metadata =
      [
        failure_kind: failure_kind(kind),
        failure_reason: failure_reason(kind, reason),
        stacktrace_top: stacktrace_top(stacktrace),
        request_id: request_id(opts),
        codex_session_id: session_id(Map.get(state, :codex_session)),
        active_task_count: MapSet.size(Map.get(state, :tasks, MapSet.new()))
      ] ++ safe_payload_metadata(payload)

    Logger.error(
      "websocket response task failed #{format_log_metadata(metadata)}",
      metadata
    )

    :ok
  end

  defp format_log_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{format_log_value(value)}" end)
  end

  defp format_log_value(value) when is_binary(value), do: value
  defp format_log_value(value), do: inspect(value)

  defp failure_kind(:error), do: "exception"
  defp failure_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp failure_kind(_kind), do: "unknown"

  defp failure_reason(:error, %{__struct__: module}) when is_atom(module), do: inspect(module)
  defp failure_reason(_kind, reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_kind, {reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_kind, _reason), do: "non_atom_reason"

  defp stacktrace_top([{module, function, arity_or_args, location} | _stacktrace]) do
    [
      inspect(module),
      ".",
      to_string(function),
      "/",
      to_string(stacktrace_arity(arity_or_args)),
      ":",
      to_string(location[:file]),
      ":",
      to_string(location[:line])
    ]
    |> IO.iodata_to_binary()
  end

  defp stacktrace_top(_stacktrace), do: nil

  defp stacktrace_arity(arity) when is_integer(arity), do: arity
  defp stacktrace_arity(args) when is_list(args), do: length(args)

  defp session_id(%{id: id}) when is_binary(id), do: id
  defp session_id(_session), do: nil

  defp safe_payload_metadata(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} ->
        [
          payload_type: safe_payload_field(decoded, "type"),
          payload_model: safe_payload_field(decoded, "model"),
          payload_stream: Map.get(decoded, "stream"),
          payload_generate: Map.get(decoded, "generate"),
          payload_has_previous_response_id: is_binary(Map.get(decoded, "previous_response_id")),
          payload_input_count: payload_input_count(Map.get(decoded, "input"))
        ]

      _not_json ->
        [payload_type: "invalid_json"]
    end
  end

  defp safe_payload_field(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> String.slice(value, 0, 120)
      _value -> nil
    end
  end

  defp payload_input_count(input) when is_list(input), do: length(input)
  defp payload_input_count(nil), do: nil
  defp payload_input_count(_input), do: 1

  defp await_response_tasks(tasks, timeout_ms) do
    if MapSet.size(tasks) == 0 do
      tasks
    else
      monitors = Map.new(tasks, &{&1, Process.monitor(&1)})
      deadline = response_task_deadline(timeout_ms)

      do_await_response_tasks(tasks, monitors, deadline)
    end
  end

  defp response_task_deadline(timeout_ms) when is_integer(timeout_ms) do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp do_await_response_tasks(tasks, monitors, deadline) do
    if MapSet.size(tasks) == 0 do
      tasks
    else
      timeout = response_task_wait_timeout(deadline)

      receive do
        {:codex_response_done, pid, _result} ->
          do_await_response_tasks(remove_response_task(tasks, monitors, pid), monitors, deadline)

        {:DOWN, _ref, :process, pid, _reason} ->
          do_await_response_tasks(remove_response_task(tasks, monitors, pid), monitors, deadline)
      after
        timeout ->
          tasks
      end
    end
  end

  defp response_task_wait_timeout(deadline) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp remove_response_task(tasks, monitors, pid) do
    if ref = Map.get(monitors, pid) do
      Process.demonitor(ref, [:flush])
      MapSet.delete(tasks, pid)
    else
      tasks
    end
  end

  defp close_upstream_websocket_session(state) do
    state
    |> Map.get(:upstream_websocket_session)
    |> Websocket.close_websocket_session()
  end
end
