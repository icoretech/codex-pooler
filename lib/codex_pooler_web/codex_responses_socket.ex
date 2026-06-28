defmodule CodexPoolerWeb.CodexResponsesSocket do
  @moduledoc false

  @behaviour WebSock

  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.Adapter
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
         codex_session: _session,
         websocket_owner_lease_token: _owner_lease_token,
         websocket_owner_downstream: _downstream
       } = runtime} ->
        {:ok,
         state
         |> put_socket_lifecycle_state()
         |> put_response_task_state()
         |> Adapter.put_runtime(runtime)}

      {:ok, %{codex_session: session, upstream_websocket_session: upstream_websocket_session}} ->
        {:ok,
         state
         |> put_socket_lifecycle_state()
         |> put_response_task_state()
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
    {:push, {:text, Adapter.downstream_response_chunk(data)}, state}
  end

  def handle_info({:websocket_owner_frame, _correlation_id, _epoch, _payload} = message, state) do
    case Adapter.accept_downstream_message(message, state) do
      {:ok, {:data, data}} ->
        {:push, {:text, Adapter.downstream_response_chunk(data)}, state}

      {:ok, {:error, :owner_drained, payload}} ->
        state =
          state
          |> Map.put(:websocket_owner_drain_observed?, true)
          |> cancel_tracked_response_tasks(:owner_drained)

        {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}

      {:ok, {:error, _reason, payload}} ->
        {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}

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

  def handle_info(
        {:codex_response_done, pid, {:error, _reason}},
        %{websocket_owner_drain_observed?: true} = state
      ) do
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

    {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{websocket_owner_monitor: ref} = state) do
    case Adapter.handle_monitor_down(state, pid, reason) do
      {:ok, state} ->
        {:ok, state}

      {:stop, close_detail, state} ->
        {:stop, :normal, close_detail, state}
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

    cleanup_websocket_session(reason, state)

    close_upstream_websocket_session(state)

    _remaining_tasks = remaining_response_tasks_after_cleanup(state, remaining_tasks)

    :ok
  end

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
      |> Adapter.terminate_close_metadata()
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

  defp put_socket_lifecycle_state(state) do
    state
    |> Map.put(:connection_started_at_monotonic_ms, System.monotonic_time(:millisecond))
    |> Map.put(:request_response_work_started?, false)
  end

  defp put_response_task_state(state) do
    state
    |> Map.put(:tasks, MapSet.new())
    |> Map.put(:task_monitors, %{})
  end

  defp init_error(reason, state, started_at) do
    log_init_failed_before_request_reservation(reason, state, started_at)

    if Adapter.owner_error?(reason) do
      {:stop, :normal, Adapter.close_detail(reason), state}
    else
      {:stop, reason, state}
    end
  end

  defp log_init_failed_before_request_reservation(reason, state, started_at) do
    state
    |> Adapter.init_failure_metadata(started_at)
    |> WebsocketConnectionLogger.log_init_failed_before_request_reservation(reason)
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

      active_response_task?(state) and Adapter.continuity_ordered_payload?(payload) ->
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
    case Adapter.maybe_retarget_before_start(payload, state) do
      {:ok, state} ->
        state = maybe_mark_request_response_work_started(state, payload)
        parent = self()
        {:ok, pid} = start_response_task(parent, payload, state)
        monitor = Process.monitor(pid)

        track_response_task(state, pid, monitor)

      {:error, reason} ->
        start_owner_retarget_error_task(reason, state)
    end
  end

  defp queue_response_payload(state, payload) do
    Map.update(
      state,
      :queued_response_payloads,
      :queue.from_list([payload]),
      &:queue.in(payload, &1)
    )
  end

  defp start_owner_retarget_error_task(reason, state) do
    parent = self()
    {:ok, pid} = start_response_task(parent, {:owner_retarget_error, reason}, state)
    monitor = Process.monitor(pid)

    track_response_task(state, pid, monitor)
  end

  @spec maybe_mark_request_response_work_started(map(), term()) :: map()
  defp maybe_mark_request_response_work_started(state, payload) do
    if Adapter.request_row_producing_response_payload?(payload) do
      Map.put(state, :request_response_work_started?, true)
    else
      state
    end
  end

  defp owner_forwarded_socket?(state), do: Adapter.owner?(state)

  defp active_response_task?(state), do: MapSet.size(Map.get(state, :tasks, MapSet.new())) > 0

  defp suppress_owner_reconnect_replay?(payload, state) do
    owner_forwarded_socket?(state) and
      Map.get(state, :websocket_owner_active_turn_reconnect?) == true and
      Adapter.request_row_producing_response_payload?(payload)
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

  defp cancel_tracked_response_tasks(state, reason) do
    state
    |> Map.get(:tasks, MapSet.new())
    |> Enum.each(fn
      pid when is_pid(pid) -> Process.exit(pid, {:shutdown, reason})
      _value -> :ok
    end)

    state
  end

  defp pop_task_monitor(state, pid) do
    {monitor, task_monitors} =
      state
      |> Map.get(:task_monitors, %{})
      |> Map.pop(pid)

    {monitor, Map.put(state, :task_monitors, task_monitors)}
  end

  defp safe_run_response(_parent, {:owner_retarget_error, reason}, _state) do
    Adapter.retarget_error_payload(reason)
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
        if owner_drained_response_task_exit?(kind, reason, state) do
          Adapter.retarget_error_payload(:owner_drained)
        else
          log_response_task_failure(kind, reason, __STACKTRACE__, payload, state, opts)
          response_task_failure()
        end
    end
  end

  defp owner_drained_response_task_exit?(:exit, :normal, state),
    do: owner_forwarded_socket?(state)

  defp owner_drained_response_task_exit?(:exit, {:normal, _details}, state),
    do: owner_forwarded_socket?(state)

  defp owner_drained_response_task_exit?(_kind, _reason, _state), do: false

  defp response_task_opts(state) do
    Adapter.response_options(
      state,
      MapSet.size(Map.get(state, :tasks, MapSet.new())) == 0
    )
  end

  defp cleanup_websocket_session(reason, %{websocket_owner_downstream: downstream} = state)
       when is_map(downstream) do
    Adapter.cleanup_owner_session(state, reason)
  end

  defp cleanup_websocket_session(_reason, state) do
    state
    |> Map.get(:codex_session)
    |> Websocket.interrupt_codex_session(state.opts)
    |> log_interrupt_failure(state)
  end

  defp run_response(parent, auth, payload, opts) do
    Websocket.run_websocket_response(auth, payload, opts, fn data ->
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

  defp log_response_task_failure(kind, reason, stacktrace, payload, state, opts) do
    metadata =
      [
        failure_kind: failure_kind(kind),
        failure_reason: failure_reason(kind, reason),
        stacktrace_top: stacktrace_top(stacktrace),
        request_id: Adapter.request_id(opts),
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
