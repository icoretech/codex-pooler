defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream do
  @moduledoc """
  StreamRelay source that feeds a downstream HTTP SSE relay from an upstream
  Codex websocket turn.

  A relay process owns the blocking owner-session submit, receives the owner's
  `{:websocket_owner_frame, correlation_id, epoch, payload}` messages as the
  attached downstream, converts each upstream JSON event into an SSE block, and
  forwards it to the dispatching HTTP process as `{ref, part}` messages —
  exactly the message shape `StreamRelay` already consumes for Req async
  responses. The struct travels as the fabricated `Req.Response` body so the
  relay can parse and cancel it without knowing about websockets.

  Before streaming, the relay emits exactly one out-of-band
  `{ref, {:preflight, decision}}` message so the dispatcher can commit to the
  websocket path or fall back to HTTP without consuming (and thereby
  reordering) any real stream part. The dispatcher only ever commits on an
  meaningful upstream event or structurally valid terminal commits the bridge.
  The four lifecycle-only event types are buffered and flushed after commit;
  a failure, owner error, or timeout before commitment reports a fallback.
  """

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  # The submit task must NOT be linked to the relay: an abnormal task exit
  # would kill the relay through the link before its :DOWN branch could run,
  # leaving the dispatcher waiting for a preflight decision that never comes.
  # async_nolink under the owner-session task supervisor monitors only.
  @submit_task_supervisor WebsocketOwnerSession.TaskSupervisor

  @enforce_keys [:ref, :relay, :correlation_id, :settle_timeout_ms]
  defstruct [:ref, :relay, :correlation_id, :settle_timeout_ms]

  @type t :: %__MODULE__{
          ref: reference(),
          relay: pid(),
          correlation_id: String.t(),
          settle_timeout_ms: non_neg_integer()
        }
  @type decision :: :stream | {:fallback, term()}
  @type part :: {:data, binary()} | :done | {:bridge_error, term()}
  @type attempt_metadata :: %{
          upstream_websocket_connection: map() | nil,
          transport_failure: map() | nil
        }

  @default_settle_timeout_ms 5_000
  @max_precommit_frames 64
  @max_precommit_bytes 1_048_576
  @buffered_event_types [
    "response.created",
    "response.in_progress",
    "response.queued",
    "codex.rate_limits"
  ]

  @spec start(String.t(), keyword()) :: t()
  def start(correlation_id, opts \\ []) when is_binary(correlation_id) do
    parent = self()
    ref = make_ref()
    settle_timeout_ms = Keyword.get(opts, :settle_timeout_ms, @default_settle_timeout_ms)

    relay =
      spawn(fn ->
        idle_loop(%{
          parent: parent,
          parent_monitor: Process.monitor(parent),
          ref: ref,
          correlation_id: correlation_id,
          settle_timeout_ms: settle_timeout_ms,
          epoch: nil,
          task: nil,
          pending: [],
          pending_count: 0,
          pending_bytes: 0,
          upstream_websocket_connection: nil,
          transport_failure: nil,
          upstream_committed: false
        })
      end)

    %__MODULE__{
      ref: ref,
      relay: relay,
      correlation_id: correlation_id,
      settle_timeout_ms: settle_timeout_ms
    }
  end

  @doc """
  Arms the relay after the owner downstream attach: fixes the accepted frame
  epoch and starts the blocking submit task inside the relay process. The relay
  answers with one `{ref, {:preflight, decision}}` message.
  """
  @spec arm(t(), non_neg_integer() | nil, (-> term())) :: :ok
  def arm(%__MODULE__{relay: relay}, epoch, submit_fun) when is_function(submit_fun, 0) do
    send(relay, {:arm, epoch, submit_fun})
    :ok
  end

  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{relay: relay, ref: ref}) do
    send(relay, :cancel)
    flush(ref)
  end

  @doc "Atomically returns and clears safe metadata retained for one bridge attempt."
  @spec take_upstream_websocket_attempt_metadata(t()) :: attempt_metadata()
  def take_upstream_websocket_attempt_metadata(%__MODULE__{
        relay: relay,
        settle_timeout_ms: settle_timeout_ms
      }) do
    query_ref = make_ref()
    monitor_ref = Process.monitor(relay)
    send(relay, {:take_upstream_websocket_attempt_metadata, self(), query_ref})

    receive do
      {^query_ref, metadata} ->
        Process.demonitor(monitor_ref, [:flush])
        metadata

      {:DOWN, ^monitor_ref, :process, ^relay, _reason} ->
        empty_attempt_metadata()
    after
      settle_timeout_ms + 1_000 ->
        Process.demonitor(monitor_ref, [:flush])
        send(relay, :cancel)
        empty_attempt_metadata()
    end
  end

  @spec parse_message(t(), term()) :: {:ok, [term()]} | {:error, term()} | :unknown
  def parse_message(%__MODULE__{ref: ref}, {ref, {:data, data}}), do: {:ok, [{:data, data}]}
  def parse_message(%__MODULE__{ref: ref}, {ref, :done}), do: {:ok, [:done]}

  def parse_message(%__MODULE__{ref: ref}, {ref, {:bridge_error, reason}}),
    do: {:error, {:upstream_websocket_bridge, reason}}

  def parse_message(%__MODULE__{}, _message), do: :unknown

  @doc "Converts one canonical upstream JSON event into an SSE block."
  @spec sse_block(binary()) :: binary()
  def sse_block(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => type}} when is_binary(type) and type != "" ->
        "event: " <> type <> "\ndata: " <> text <> "\n\n"

      _other ->
        "data: " <> text <> "\n\n"
    end
  end

  defp flush(ref) do
    receive do
      {^ref, _part} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp idle_loop(state) do
    %{parent_monitor: parent_monitor} = state

    receive do
      {:arm, epoch, submit_fun} ->
        task =
          Task.Supervisor.async_nolink(@submit_task_supervisor, fn -> run_submit(submit_fun) end)

        preflight_loop(%{state | epoch: epoch, task: task})

      :cancel ->
        :ok

      {:DOWN, ^parent_monitor, :process, _pid, _reason} ->
        :ok
    end
  end

  # The submit fun blocks in a GenServer.call that carries the full upstream
  # request — payload and authorization headers. An abnormal exit (the owner
  # dying mid-call) would copy those call arguments verbatim into the task's
  # crash report, so the task catches every kind and settles with a scrubbed
  # error value instead of crashing. The sensitive flag additionally hides the
  # in-flight arguments from tracing and process inspection.
  defp run_submit(submit_fun) do
    :erlang.process_flag(:sensitive, true)
    submit_fun.()
  catch
    kind, reason -> {:error, submit_crash_reason(kind, reason)}
  end

  defp submit_crash_reason(:exit, {reason, {GenServer, :call, _args}}),
    do: submit_exit_reason(reason)

  defp submit_crash_reason(:exit, reason), do: submit_exit_reason(reason)
  defp submit_crash_reason(_kind, _reason), do: :bridge_submit_crash

  defp submit_exit_reason(:timeout), do: :owner_call_timeout
  defp submit_exit_reason(:noproc), do: :owner_not_running
  defp submit_exit_reason(reason) when is_atom(reason), do: reason
  defp submit_exit_reason(_reason), do: :bridge_submit_crash

  # The preflight phase resolves the first upstream signal WITHOUT emitting any
  # real stream part until it has told the dispatcher to commit. Lifecycle-only
  # frames stay buffered; meaningful, unknown, malformed, and successful
  # terminal frames commit conservatively. Recognized failures still fall back.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp preflight_loop(state) do
    %{
      parent: parent,
      parent_monitor: parent_monitor,
      ref: ref,
      correlation_id: correlation_id,
      epoch: epoch,
      task: %Task{ref: task_ref} = task
    } = state

    receive do
      {:websocket_owner_frame, ^correlation_id, ^epoch, {:data, text}} when is_binary(text) ->
        case preflight_class(text) do
          :commit -> commit_stream(state, text)
          :terminal -> commit_terminal(state, text)
          :buffer -> buffer_preflight(state, text, &preflight_loop/1)
          :failure -> fall_back(state, :bridge_failed_before_visible)
        end

      {:websocket_owner_frame, ^correlation_id, ^epoch, :complete} ->
        fall_back(state, :bridge_no_first_event)

      {:websocket_owner_frame, ^correlation_id, ^epoch, {:error, error, _payload}} ->
        preflight_owner_error(state, error)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} ->
        preflight_loop(state)

      {^task_ref, {:error, reason} = result} ->
        state = put_submit_result_and_clear_task(state, result)

        if committed_failure?(state.transport_failure) do
          report_stream_error(parent, ref, error_reason(reason))
          metadata_loop(state)
        else
          report_fallback(parent, ref, error_reason(reason))
        end

      {^task_ref, result} ->
        state
        |> put_submit_result_and_clear_task(result)
        |> preflight_after_result()

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        report_fallback(parent, ref, {:task_down, safe_reason(reason)})

      {:DOWN, ^parent_monitor, :process, _pid, _reason} ->
        Task.shutdown(task, :brutal_kill)

      :cancel ->
        Task.shutdown(task, :brutal_kill)
    end
  end

  # The submit task settled successfully before any frame arrived. Give the
  # owner a brief window to deliver the first visible frame; otherwise fall
  # back so the dispatcher can still retry over HTTP.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp preflight_after_result(state) do
    %{
      parent: parent,
      parent_monitor: parent_monitor,
      ref: ref,
      correlation_id: correlation_id,
      epoch: epoch
    } = state

    receive do
      {:websocket_owner_frame, ^correlation_id, ^epoch, {:data, text}} when is_binary(text) ->
        case preflight_class(text) do
          :commit ->
            report_stream(parent, ref, state.pending, text)
            relay_after_result(%{state | pending: [], upstream_committed: true}, :ok)

          :terminal ->
            report_terminal(parent, ref, state.pending, text)
            metadata_loop(%{state | pending: [], upstream_committed: true})

          :buffer ->
            buffer_preflight(state, text, &preflight_after_result/1)

          :failure ->
            report_fallback(parent, ref, :bridge_failed_before_visible)
        end

      {:websocket_owner_frame, ^correlation_id, ^epoch, :complete} ->
        report_fallback(parent, ref, :bridge_no_first_event)

      {:websocket_owner_frame, ^correlation_id, ^epoch, {:error, error, _payload}} ->
        report_fallback(parent, ref, owner_error_reason(error))

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} ->
        preflight_after_result(state)

      {:DOWN, ^parent_monitor, :process, _pid, _reason} ->
        :ok

      :cancel ->
        :ok
    after
      state.settle_timeout_ms ->
        report_fallback(parent, ref, :bridge_no_first_event)
    end
  end

  defp commit_stream(%{task: nil} = state, text) do
    report_stream(state.parent, state.ref, state.pending, text)
    relay_after_result(%{state | pending: [], upstream_committed: true}, :ok)
  end

  defp commit_stream(state, text) do
    report_stream(state.parent, state.ref, state.pending, text)
    relay_loop(%{state | pending: [], upstream_committed: true})
  end

  defp commit_terminal(state, text) do
    report_terminal(state.parent, state.ref, state.pending, text)

    state
    |> Map.put(:pending, [])
    |> Map.put(:upstream_committed, true)
    |> settle_task()
    |> metadata_loop()
  end

  defp buffer_preflight(state, text, continue) when is_function(continue, 1) do
    pending_count = state.pending_count + 1
    pending_bytes = state.pending_bytes + byte_size(text)

    if pending_count > @max_precommit_frames or pending_bytes > @max_precommit_bytes do
      :telemetry.execute(
        [:codex_pooler, :gateway, :websocket_bridge, :precommit_overflow],
        %{count: 1, frames: pending_count, bytes: pending_bytes},
        %{max_frames: @max_precommit_frames, max_bytes: @max_precommit_bytes}
      )

      commit_stream(state, text)
    else
      continue.(%{
        state
        | pending: [text | state.pending],
          pending_count: pending_count,
          pending_bytes: pending_bytes
      })
    end
  end

  # Committing flushes the buffered internal frames ahead of the visible one:
  # the public normalization drops them downstream, but the relay pipeline
  # still records their rate-limit snapshots, keeping parity with HTTP.
  defp report_stream(parent, ref, pending, text) do
    send(parent, {ref, {:preflight, :stream}})

    pending
    |> Enum.reverse()
    |> Enum.each(fn earlier -> send(parent, {ref, {:data, sse_block(earlier)}}) end)

    send(parent, {ref, {:data, sse_block(text)}})
  end

  defp report_terminal(parent, ref, pending, text) do
    report_stream(parent, ref, pending, text)
    send(parent, {ref, :done})
  end

  defp report_fallback(parent, ref, reason) do
    send(parent, {ref, {:preflight, {:fallback, reason}}})
  end

  defp report_stream_error(parent, ref, reason) do
    send(parent, {ref, {:preflight, :stream}})
    send(parent, {ref, {:bridge_error, reason}})
  end

  defp committed_failure?(%{"upstream_committed" => true}), do: true
  defp committed_failure?(_transport_failure), do: false

  defp preflight_owner_error(state, :upstream_websocket_terminal_delivery_timeout) do
    state = settle_task(state)

    if committed_failure?(state.transport_failure) do
      report_stream_error(state.parent, state.ref, :upstream_websocket_terminal_delivery_timeout)
      metadata_loop(state)
    else
      report_fallback(state.parent, state.ref, :upstream_websocket_terminal_delivery_timeout)
    end
  end

  defp preflight_owner_error(state, error),
    do: fall_back(state, owner_error_reason(error))

  defp fall_back(state, reason) do
    report_fallback(state.parent, state.ref, reason)
    _state = settle_task(state)
    :ok
  end

  # Post-commit streaming still watches the submit task so its settlement is
  # drained, and forwards data frames until the terminal frame.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp relay_loop(state) do
    %{
      parent: parent,
      parent_monitor: parent_monitor,
      ref: ref,
      correlation_id: correlation_id,
      epoch: epoch,
      task: %Task{ref: task_ref} = task
    } = state

    receive do
      {:websocket_owner_frame, ^correlation_id, ^epoch, {:data, text}} when is_binary(text) ->
        relay_committed_frame(state, text, &relay_loop/1)

      {:websocket_owner_frame, ^correlation_id, ^epoch, :complete} ->
        send(parent, {ref, :done})

        state
        |> settle_task()
        |> metadata_loop()

      {:websocket_owner_frame, ^correlation_id, ^epoch, {:error, error, _payload}} ->
        send(parent, {ref, {:bridge_error, owner_error_reason(error)}})

        state
        |> settle_task()
        |> metadata_loop()

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} ->
        relay_loop(state)

      {^task_ref, {:error, reason} = result} ->
        state
        |> put_submit_result_and_clear_task(result)
        |> relay_after_result({:failed, error_reason(reason)})

      {^task_ref, result} ->
        state
        |> put_submit_result_and_clear_task(result)
        |> relay_after_result(:ok)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        relay_after_result(state, {:failed, {:task_down, safe_reason(reason)}})

      {:DOWN, ^parent_monitor, :process, _pid, _reason} ->
        Task.shutdown(task, :brutal_kill)

      :cancel ->
        state
        |> settle_task()
        |> metadata_loop()
    end
  end

  # Streaming after the submit task already settled: no task left to watch. A
  # failed settlement is preserved — when no terminal frame arrives within the
  # settle window, the stream fails instead of synthesizing a successful :done
  # for a turn whose upstream died.
  defp relay_after_result(state, settle) do
    %{
      parent: parent,
      parent_monitor: parent_monitor,
      ref: ref,
      correlation_id: correlation_id,
      epoch: epoch
    } = state

    receive do
      {:websocket_owner_frame, ^correlation_id, ^epoch, {:data, text}} when is_binary(text) ->
        relay_committed_frame(state, text, &relay_after_result(&1, settle))

      {:websocket_owner_frame, ^correlation_id, ^epoch, :complete} ->
        send(parent, {ref, :done})
        metadata_loop(state)

      {:websocket_owner_frame, ^correlation_id, ^epoch, {:error, error, _payload}} ->
        send(parent, {ref, {:bridge_error, owner_error_reason(error)}})
        metadata_loop(state)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} ->
        relay_after_result(state, settle)

      {:DOWN, ^parent_monitor, :process, _pid, _reason} ->
        :ok

      :cancel ->
        metadata_loop(state)
    after
      state.settle_timeout_ms ->
        case settle do
          :ok -> send(parent, {ref, :done})
          {:failed, reason} -> send(parent, {ref, {:bridge_error, reason}})
        end

        metadata_loop(state)
    end
  end

  defp settle_task(%{task: %Task{} = task} = state) do
    state =
      case Task.yield(task, state.settle_timeout_ms) do
        {:ok, result} ->
          put_submit_result_connection(state, result)

        {:exit, _reason} ->
          state

        nil ->
          Task.shutdown(task, :brutal_kill)
          state
      end

    %{state | task: nil}
  end

  defp settle_task(%{task: nil} = state), do: state

  defp relay_committed_frame(state, text, continue) when is_function(continue, 1) do
    send(state.parent, {state.ref, {:data, sse_block(text)}})

    case terminal_class(text) do
      :terminal ->
        send(state.parent, {state.ref, :done})

        state
        |> settle_task()
        |> metadata_loop()

      _nonterminal ->
        continue.(state)
    end
  end

  defp metadata_loop(state) do
    receive do
      {:take_upstream_websocket_attempt_metadata, caller, query_ref}
      when is_pid(caller) and is_reference(query_ref) ->
        send(caller, {query_ref, attempt_metadata(state)})

      {:DOWN, parent_monitor, :process, _pid, _reason}
      when parent_monitor == state.parent_monitor ->
        :ok

      :cancel ->
        metadata_loop(state)
    after
      state.settle_timeout_ms -> :ok
    end

    :ok
  end

  defp put_submit_result_connection(state, {status, result})
       when status in [:ok, :error] and is_map(result) do
    connection = safe_connection(Map.get(result, :upstream_websocket_connection))

    transport_failure =
      result
      |> Map.get(:transport_failure)
      |> TransportFailureReason.sanitize_transport_failure_metadata()
      |> committed_transport_failure(state.upstream_committed)

    %{
      state
      | upstream_websocket_connection: connection || state.upstream_websocket_connection,
        transport_failure: nonempty_map(transport_failure) || state.transport_failure
    }
  end

  defp put_submit_result_connection(state, _result), do: state

  defp put_submit_result_and_clear_task(%{task: %Task{ref: task_ref}} = state, result) do
    Process.demonitor(task_ref, [:flush])

    state
    |> put_submit_result_connection(result)
    |> Map.put(:task, nil)
  end

  defp preflight_class(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} ->
        case StreamProtocol.terminal_outcome(nil, decoded) do
          {:ok, %{kind: :failed}} -> :failure
          {:ok, %{kind: kind}} when kind in [:completed, :incomplete] -> :terminal
          _outcome -> nonterminal_preflight_class(decoded)
        end

      _other ->
        :commit
    end
  end

  defp nonterminal_preflight_class(%{"type" => type}) when type in @buffered_event_types,
    do: :buffer

  defp nonterminal_preflight_class(_decoded), do: :commit

  defp terminal_class(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} ->
        case StreamProtocol.terminal_outcome(nil, decoded) do
          {:ok, %{kind: kind}} when kind in [:completed, :incomplete, :failed] -> :terminal
          _outcome -> :nonterminal
        end

      _other ->
        :nonterminal
    end
  end

  defp owner_error_reason(error) when is_atom(error), do: error

  defp owner_error_reason(error) do
    if WebsocketOwnerContract.owner_error?(error), do: error, else: :upstream_websocket_error
  end

  defp error_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp error_reason(reason) when is_atom(reason), do: reason
  defp error_reason(_reason), do: :upstream_websocket_error

  defp attempt_metadata(state) do
    %{
      upstream_websocket_connection: state.upstream_websocket_connection,
      transport_failure: state.transport_failure
    }
  end

  defp empty_attempt_metadata do
    %{upstream_websocket_connection: nil, transport_failure: nil}
  end

  defp safe_connection(connection) when is_map(connection) do
    atom_keys = [:lifecycle_id, :generation, :reused, :reconnected]
    string_keys = Enum.map(atom_keys, &Atom.to_string/1)
    atom_fields = Map.take(connection, atom_keys)
    string_fields = Map.take(connection, string_keys)

    cond do
      valid_connection?(atom_fields, atom_keys) and map_size(string_fields) == 0 ->
        atom_fields

      valid_connection?(string_fields, string_keys) and map_size(atom_fields) == 0 ->
        string_fields

      true ->
        nil
    end
  end

  defp safe_connection(_connection), do: nil

  defp valid_connection?(connection, [lifecycle_key, generation_key, reused_key, reconnected_key]) do
    map_size(connection) == 4 and
      match?({:ok, _uuid}, Ecto.UUID.cast(Map.get(connection, lifecycle_key))) and
      is_integer(Map.get(connection, generation_key)) and Map.get(connection, generation_key) > 0 and
      is_boolean(Map.get(connection, reused_key)) and
      is_boolean(Map.get(connection, reconnected_key))
  end

  defp committed_transport_failure(metadata, true) when map_size(metadata) > 0,
    do: Map.put(metadata, "upstream_committed", true)

  defp committed_transport_failure(metadata, _upstream_committed), do: metadata

  defp nonempty_map(metadata) when map_size(metadata) > 0, do: metadata
  defp nonempty_map(_metadata), do: nil

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :relay_task_down
end
