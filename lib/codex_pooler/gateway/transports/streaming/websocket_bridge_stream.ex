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
  upstream event the public Responses normalization forwards downstream:
  internal `codex.*` frames are buffered and flushed after the commit, and a
  completion, failure event, owner error, or timeout before the first visible
  event reports a fallback instead.
  """

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
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

  @default_settle_timeout_ms 5_000

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
          upstream_websocket_connection: nil
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

  @doc "Returns and releases connection metadata retained by a committed bridge stream."
  @spec take_upstream_websocket_connection(t()) :: map() | nil
  def take_upstream_websocket_connection(%__MODULE__{
        relay: relay,
        settle_timeout_ms: settle_timeout_ms
      }) do
    query_ref = make_ref()
    monitor_ref = Process.monitor(relay)
    send(relay, {:take_upstream_websocket_connection, self(), query_ref})

    receive do
      {^query_ref, connection} ->
        Process.demonitor(monitor_ref, [:flush])
        connection

      {:DOWN, ^monitor_ref, :process, ^relay, _reason} ->
        nil
    after
      settle_timeout_ms + 1_000 ->
        Process.demonitor(monitor_ref, [:flush])
        send(relay, :cancel)
        nil
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
  # real stream part until it has told the dispatcher to commit. Only an event
  # the public Responses normalization forwards downstream commits the stream;
  # internal `codex.*` frames are buffered so their rate-limit snapshots still
  # reach the relay pipeline after the commit. A completion, failure event,
  # owner error, or task settlement before the first visible event reports a
  # fallback instead.
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
          :visible -> commit_stream(state, text)
          :internal -> preflight_loop(%{state | pending: [text | state.pending]})
          :failure -> fall_back(state, :bridge_failed_before_visible)
        end

      {:websocket_owner_frame, ^correlation_id, ^epoch, :complete} ->
        fall_back(state, :bridge_no_first_event)

      {:websocket_owner_frame, ^correlation_id, ^epoch, {:error, error, _payload}} ->
        fall_back(state, owner_error_reason(error))

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} ->
        preflight_loop(state)

      {^task_ref, {:error, reason}} ->
        report_fallback(parent, ref, error_reason(reason))

      {^task_ref, result} ->
        state
        |> put_submit_result_connection(result)
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
          :visible ->
            report_stream(parent, ref, state.pending, text)
            relay_after_result(%{state | pending: []}, :ok)

          :internal ->
            preflight_after_result(%{state | pending: [text | state.pending]})

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

  defp commit_stream(state, text) do
    report_stream(state.parent, state.ref, state.pending, text)
    relay_loop(%{state | pending: []})
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

  defp report_fallback(parent, ref, reason) do
    send(parent, {ref, {:preflight, {:fallback, reason}}})
  end

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
        send(parent, {ref, {:data, sse_block(text)}})
        relay_loop(state)

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
        |> put_submit_result_connection(result)
        |> relay_after_result({:failed, error_reason(reason)})

      {^task_ref, result} ->
        state
        |> put_submit_result_connection(result)
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
        send(parent, {ref, {:data, sse_block(text)}})
        relay_after_result(state, settle)

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

  defp metadata_loop(state) do
    receive do
      {:take_upstream_websocket_connection, caller, query_ref}
      when is_pid(caller) and is_reference(query_ref) ->
        send(caller, {query_ref, state.upstream_websocket_connection})

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
    case Map.get(result, :upstream_websocket_connection) do
      connection when is_map(connection) ->
        %{state | upstream_websocket_connection: connection}

      _connection ->
        state
    end
  end

  defp put_submit_result_connection(state, _result), do: state

  # Mirrors PublicResponses.normalize_public_block/3: `codex.*` events and
  # typeless payloads produce no downstream output, so they must not commit
  # the bridge — a later failure would otherwise strand the turn past its
  # pre-visible HTTP fallback. Upstream failure terminals fall back outright.
  defp preflight_class(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = decoded} when is_binary(type) and type != "" ->
        cond do
          failed_terminal?(type, decoded) -> :failure
          String.starts_with?(type, "codex.") -> :internal
          true -> :visible
        end

      _other ->
        :internal
    end
  end

  defp failed_terminal?(type, decoded) do
    match?({:ok, %{kind: :failed}}, StreamProtocol.terminal_outcome(type, decoded))
  end

  defp owner_error_reason(error) when is_atom(error), do: error

  defp owner_error_reason(error) do
    if WebsocketOwnerContract.owner_error?(error), do: error, else: :upstream_websocket_error
  end

  defp error_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp error_reason(reason) when is_atom(reason), do: reason
  defp error_reason(_reason), do: :upstream_websocket_error

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :relay_task_down
end
