defmodule CodexPoolerWeb.CodexResponsesSocket do
  @moduledoc false

  @behaviour WebSock

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata, as: FinalizationMetadata
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract

  require Logger

  @impl WebSock
  def init(state) do
    case Gateway.prepare_websocket_session(state.auth, state.opts) do
      {:ok,
       %{
         codex_session: session,
         websocket_owner_lease_token: owner_lease_token,
         websocket_owner_downstream: downstream
       }} ->
        {:ok,
         state
         |> Map.put(:tasks, MapSet.new())
         |> Map.put(:task_monitors, %{})
         |> Map.put(:codex_session, session)
         |> Map.put(:websocket_owner_lease_token, owner_lease_token)
         |> Map.put(:websocket_owner_downstream, downstream)}

      {:ok, %{codex_session: session, upstream_websocket_session: upstream_websocket_session}} ->
        {:ok,
         state
         |> Map.put(:tasks, MapSet.new())
         |> Map.put(:task_monitors, %{})
         |> Map.put(:codex_session, session)
         |> Map.put(:upstream_websocket_session, upstream_websocket_session)}

      {:error, reason} ->
        {:stop, reason, state}
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
    {:push, {:text, data}, state}
  end

  def handle_info({:websocket_owner_frame, _correlation_id, _epoch, _payload} = message, state) do
    case accept_owner_downstream_message(message, state) do
      {:ok, {:data, data}} ->
        {:push, {:text, data}, state}

      {:ok, {:error, _reason, payload}} ->
        {:push, {:text, Jason.encode!(websocket_error(payload))}, state}

      {:ok, :complete} ->
        {:ok, state}

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
      |> maybe_start_queued_owner_response_task()

    {:ok, state}
  end

  def handle_info({:codex_response_done, pid, {:error, reason}}, state) do
    state =
      state
      |> remove_tracked_response_task(pid)
      |> maybe_start_queued_owner_response_task()

    {:push, {:text, Jason.encode!(websocket_error(reason))}, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      state
      |> remove_tracked_response_task(pid, ref)
      |> maybe_start_queued_owner_response_task()

    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    remaining_tasks =
      state
      |> Map.get(:tasks, MapSet.new())
      |> await_response_tasks()

    cleanup_websocket_session(state)

    close_upstream_websocket_session(state)

    Enum.each(remaining_tasks, &Process.exit(&1, :shutdown))

    :ok
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

  defp failure_reason({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(%module{}), do: inspect(module)
  defp failure_reason(_reason), do: "unknown"

  defp start_response_task(parent, payload, state) do
    Task.start(fn ->
      Process.flag(:sensitive, true)
      send(parent, {:codex_response_done, self(), safe_run_response(parent, payload, state)})
    end)
  end

  defp start_or_queue_response_task(payload, state) do
    if owner_forwarded_socket?(state) and active_response_task?(state) do
      queue_owner_payload(state, payload)
    else
      start_tracked_response_task(payload, state)
    end
  end

  defp maybe_start_queued_owner_response_task(state) do
    if owner_forwarded_socket?(state) and not active_response_task?(state) do
      case Map.get(state, :queued_owner_payloads, :queue.new()) |> :queue.out() do
        {{:value, payload}, queue} ->
          state = Map.put(state, :queued_owner_payloads, queue)
          start_tracked_response_task(payload, state)

        {:empty, _queue} ->
          state
      end
    else
      state
    end
  end

  defp start_tracked_response_task(payload, state) do
    parent = self()
    {:ok, pid} = start_response_task(parent, payload, state)
    monitor = Process.monitor(pid)

    track_response_task(state, pid, monitor)
  end

  defp queue_owner_payload(state, payload) do
    Map.update(
      state,
      :queued_owner_payloads,
      :queue.from_list([payload]),
      &:queue.in(payload, &1)
    )
  end

  defp owner_forwarded_socket?(state), do: is_map(Map.get(state, :websocket_owner_downstream))

  defp active_response_task?(state), do: MapSet.size(Map.get(state, :tasks, MapSet.new())) > 0

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
      Gateway.websocket_owner_response_options(
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
    Gateway.websocket_response_options(
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
    |> Gateway.detach_websocket_owner_downstream(
      Map.get(state, :websocket_owner_lease_token),
      downstream,
      Map.get(state, :opts, %{})
    )
    |> after_owner_detach(state)
  end

  defp cleanup_websocket_session(state) do
    state
    |> Map.get(:codex_session)
    |> Gateway.interrupt_codex_session(state.opts)
    |> log_interrupt_failure(state)
  end

  defp log_owner_detach_failure(:ok, _state, _recovery_result), do: :ok

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
    _interrupt_result = interrupt_owner_downstream_session(result, state)
    log_owner_detach_failure(result, state, recovery_result)
  end

  defp interrupt_owner_downstream_session(:ok, state) do
    state
    |> Map.get(:codex_session)
    |> Gateway.interrupt_codex_session(owner_downstream_interrupt_opts(state))
    |> log_interrupt_failure(state)
  end

  defp interrupt_owner_downstream_session(_result, _state), do: :ok

  defp recover_owner_lifecycle_leftovers({:error, reason}, state)
       when reason in [:owner_unavailable, :owner_forward_timeout, :owner_crashed] do
    state
    |> Map.get(:codex_session)
    |> Gateway.recover_owner_lifecycle_leftovers(reason, owner_lifecycle_recovery_opts(state))
    |> log_owner_lifecycle_recovery_failure(state)
  end

  defp recover_owner_lifecycle_leftovers(_result, _state), do: :ok

  defp owner_lifecycle_recovery_opts(%{opts: %RequestOptions{} = opts}) do
    opts
    |> RequestOptions.put_runtime_context(interrupt_reason: "owner_unavailable")
    |> RequestOptions.put_continuity(reconnect_window_seconds: 300)
  end

  defp owner_lifecycle_recovery_opts(state) do
    state
    |> Map.get(:opts, %{})
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_runtime_context(interrupt_reason: "owner_unavailable")
    |> RequestOptions.put_continuity(reconnect_window_seconds: 300)
  end

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
    Gateway.run_websocket_response(auth, payload, opts, fn data ->
      send(parent, {:codex_response_chunk, data})
    end)
  end

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
    %{
      "message" => message,
      "type" => "invalid_request_error",
      "code" => to_string(code),
      "param" => Map.get(reason, :param)
    }
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

  defp await_response_tasks(tasks) do
    if MapSet.size(tasks) == 0 do
      tasks
    else
      monitors = Map.new(tasks, &{&1, Process.monitor(&1)})
      deadline = System.monotonic_time(:millisecond) + 250

      do_await_response_tasks(tasks, monitors, deadline)
    end
  end

  defp do_await_response_tasks(tasks, monitors, deadline) do
    if MapSet.size(tasks) == 0 do
      tasks
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

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
    |> Gateway.close_websocket_session()
  end
end
