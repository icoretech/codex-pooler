defmodule CodexPooler.Gateway.Websocket.DeliveryReceipt do
  @moduledoc false

  # Bounded, metadata-only evidence that a downstream transport pushed (or
  # decided not to push) a turn's terminal to the client: the WebSock for
  # native websocket turns, the HTTP SSE relay for streaming responses. The
  # receipt is merged into `attempts.response_metadata["downstream_delivery"]`
  # after the gateway finalized the attempt, so a completed request whose client
  # never saw `response.completed` can be told apart from a push that never
  # happened. The receipt's transport is the log-line prefix.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.InterruptionOutcome
  alias CodexPooler.Gateway.Runtime.Finalization.SettlementRetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Repo

  @metadata_key "downstream_delivery"
  @outcomes ~w(delivered completed aborted skipped)
  @terminal_classes ~w(response.completed response.failed response.incomplete error)
  @transports ~w(websocket http_sse)
  @default_transport "websocket"
  @unknown "unknown"
  @none "none"
  @persist_timeout_ms 5_000
  # The highest class of frame a socket pushed for a turn, ranked by what the
  # released Codex client does with it (findings#232 row 232-203, measured with
  # Codex 0.156.1; `codex-api/src/sse/responses.rs` and `core/src/session/turn.rs`
  # at rust-v0.156.1): lifecycle frames, an output item or content/summary part
  # being opened, and deltas only stream into the client's view and record
  # nothing in its history, so after a cut it discards them and resends the
  # identical request; `response.output_item.done` records an item and changes
  # what it sends next; a terminal ends the turn. `other` is every frame this
  # ranking does not know, and ranks above the resendable classes so it keeps
  # the fence.
  @frame_classes ~w(none lifecycle item_added part_added delta other item_done terminal)
  @resendable_frame_classes ~w(lifecycle item_added part_added delta)
  @lifecycle_frame_types ~w(response.created response.in_progress response.queued response.metadata)
  @part_added_frame_types ~w(response.content_part.added response.reasoning_summary_part.added)
  @terminal_frame_types ~w(response.completed response.done response.failed response.incomplete error)
  # How many completed items a receipt names (findings#232 row 232-232): the
  # released client resends a turn cut after completed items with those items
  # appended, and a resend is admitted only when every pushed item is named.
  # `completed_items` keeps the exact count, so a longer run is visibly
  # truncated and keeps the fence.
  @completed_item_digest_limit 8
  # Why a receipt is not `delivered` although the socket pushed more: the class
  # of the first failed write of the connection (`timeout` for a client that
  # stopped reading, `closed` for a connection already gone, `other`), written
  # by the native and `/v1` websockets (findings#232 row 232-256). Everything
  # the receipt counts was written before it. `write_failed_at` (millisecond
  # ISO 8601, like `pushed_at`) is when that failure was reported, and the
  # client-retry window of the cut turn starts there instead of at the
  # provider's completion (row 232-261, `ClientRetry.retry_window_start/3`).
  @write_failures ~w(timeout closed other)
  # Why a pushed `response.incomplete` ended its response, for the reasons the
  # provider names in `incomplete_details.reason`: `interrupted` is a response
  # the client stopped with `response.interrupt` (findings#270 row 270-272), a
  # served request billed for what it generated. `steered` ends the original
  # response before the provider opens a separately accounted successor.
  # Any other reason reads `other`; another terminal has no field.
  @incomplete_reasons ~w(interrupted steered max_output_tokens content_filter)
  # Whether the provider's `response.completed` said it affirmatively ended the turn (`response.end_turn`): `true`,
  # `false`, or `absent` for a missing, null or non-boolean field. A client that reads `false` re-samples the turn
  # (findings#311), so a pushed completion names the class and the exposure is read from attempt rows. Only the
  # receipt of a pushed `response.completed` carries it, and only from a transport that classified what it pushed.
  @end_turn_classes ~w(true false absent)

  @type outcome :: String.t()
  @type terminal_class :: String.t() | nil
  @type receipt :: %{
          required(String.t()) => String.t() | non_neg_integer() | [String.t()] | nil
        }
  @type context :: %{
          required(:request_id) => term(),
          optional(:attempt_id) => Ecto.UUID.t() | nil,
          optional(:codex_session_id) => term(),
          optional(:replay_generation) => non_neg_integer() | nil,
          optional(:delivery_failure) => CodexPooler.Gateway.Runtime.Finalization.RetainedUsage.failure() | nil
        }
  @type persistence_option :: {:retry_timeout_ms, pos_integer()}

  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes ++ [@unknown]

  @doc """
  Every value `build/1` can persist under `terminal_class`: the provider
  terminal classes plus the `none`/`unknown` placeholders.
  """
  @spec terminal_class_values() :: [String.t()]
  def terminal_class_values, do: @terminal_classes ++ [@none, @unknown]

  @spec transports() :: [String.t()]
  def transports, do: @transports

  @doc "Every value `build/1` can persist under `highest_frame_class`, lowest first."
  @spec frame_classes() :: [String.t()]
  def frame_classes, do: @frame_classes

  @doc """
  The frame classes after which the released Codex client resends the identical
  request when its connection is cut: nothing it was pushed completed an item
  or ended the turn.
  """
  @spec resendable_frame_classes() :: [String.t()]
  def resendable_frame_classes, do: @resendable_frame_classes

  @doc """
  Classifies one downstream frame (a websocket JSON text, or complete SSE
  blocks, whose highest class wins) onto `frame_classes/0`. Only the event type
  is read; anything that does not decode is `other`.
  """
  @spec frame_class(binary() | term()) :: String.t()
  def frame_class(data) when is_binary(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} -> type_frame_class(Map.get(decoded, "type"))
      _not_json -> sse_frame_class(data)
    end
  end

  def frame_class(_data), do: "other"

  @doc "Every value `build/1` can persist under `write_failure`."
  @spec write_failures() :: [String.t()]
  def write_failures, do: @write_failures

  @doc "How many completed-item digests a receipt carries at most."
  @spec completed_item_digest_limit() :: pos_integer()
  def completed_item_digest_limit, do: @completed_item_digest_limit

  @doc """
  The bounded identity (`WebsocketTurnIdentity.completed_item_digest/1`) of the
  item a pushed `response.output_item.done` frame completed, or `nil` for any
  other frame and for a frame whose item cannot be named. Only a websocket JSON
  text is read; the digest is keyed and never carries content.
  """
  @spec completed_item_digest(binary() | term()) :: String.t() | nil
  def completed_item_digest(data) when is_binary(data) do
    with {:ok, %{"type" => "response.output_item.done", "item" => %{} = item}} <- CodexPooler.JSON.decode(data),
         {:ok, digest} <- WebsocketTurnIdentity.completed_item_digest(item) do
      digest
    else
      _other -> nil
    end
  end

  def completed_item_digest(_data), do: nil

  @doc "The higher of two frame classes; `nil` is no frame pushed yet."
  @spec higher_frame_class(String.t() | nil, String.t()) :: String.t()
  def higher_frame_class(nil, class) when class in @frame_classes, do: class

  def higher_frame_class(current, class) when current in @frame_classes and class in @frame_classes do
    if frame_class_rank(class) > frame_class_rank(current), do: class, else: current
  end

  def higher_frame_class(_current, _class), do: "other"

  @doc """
  Builds the persisted receipt from socket-side evidence.

  Every value is coerced onto a fixed vocabulary; nothing from the wire is
  copied through.
  """
  @spec build(map()) :: receipt()
  def build(fields) when is_map(fields) do
    %{
      "outcome" => vocabulary(Map.get(fields, :outcome), @outcomes, @unknown),
      "terminal_class" => terminal_class_value(Map.get(fields, :terminal_class)),
      "pushed_at" => iso8601(Map.get(fields, :pushed_at)),
      "frames_after_visible" => frame_count(Map.get(fields, :frames_after_visible)),
      "transport" => vocabulary(Map.get(fields, :transport), @transports, @default_transport)
    }
    |> maybe_put_highest_frame_class(fields)
    |> maybe_put_completed_items(fields)
    |> maybe_put_write_failure(fields)
    |> maybe_put_incomplete_reason(fields)
    |> maybe_put_end_turn(fields)
  end

  @doc "Every value `build/1` can persist under `end_turn`."
  @spec end_turn_class_values() :: [String.t()]
  def end_turn_class_values, do: @end_turn_classes

  @doc """
  The `end_turn` class of a completed terminal outcome (`StreamProtocol.terminal_outcome/1`), or `nil` for every other
  outcome and for a completed outcome that did not read the field.
  """
  @spec end_turn_class_from_outcome(term()) :: String.t() | nil
  def end_turn_class_from_outcome(%{kind: :completed, end_turn: class}) when class in @end_turn_classes, do: class
  def end_turn_class_from_outcome(_outcome), do: nil

  @doc "Every value `build/1` can persist under `incomplete_reason`."
  @spec incomplete_reason_values() :: [String.t()]
  def incomplete_reason_values, do: @incomplete_reasons ++ ["other"]

  defp maybe_put_incomplete_reason(%{"terminal_class" => "response.incomplete"} = receipt, %{incomplete_reason: reason}) when is_binary(reason),
    do: Map.put(receipt, "incomplete_reason", vocabulary(reason, @incomplete_reasons, "other"))

  defp maybe_put_incomplete_reason(receipt, _fields), do: receipt

  # A class belongs to the receipt of a pushed completion only; anything the transport hands over outside the
  # vocabulary reads `absent` rather than reaching the row.
  defp maybe_put_end_turn(%{"terminal_class" => "response.completed"} = receipt, %{end_turn: class}) when not is_nil(class),
    do: Map.put(receipt, "end_turn", vocabulary(class, @end_turn_classes, "absent"))

  defp maybe_put_end_turn(receipt, _fields), do: receipt

  # Only a receipt whose connection failed a write before the turn's terminal
  # was written carries the fields; the time only with the class.
  defp maybe_put_write_failure(receipt, %{write_failure: failure} = fields) when not is_nil(failure) do
    receipt
    |> Map.put("write_failure", vocabulary(failure, @write_failures, "other"))
    |> maybe_put_write_failed_at(Map.get(fields, :write_failed_at))
  end

  defp maybe_put_write_failure(receipt, _fields), do: receipt

  defp maybe_put_write_failed_at(receipt, %DateTime{} = failed_at), do: Map.put(receipt, "write_failed_at", iso8601(failed_at))
  defp maybe_put_write_failed_at(receipt, _failed_at), do: receipt

  # Written with the class by the transport that classifies what it pushed:
  # the digests of the completed items in push order, at most
  # `@completed_item_digest_limit`, and their exact count.
  defp maybe_put_completed_items(receipt, %{completed_item_digests: digests, completed_items: count})
       when is_list(digests) and is_integer(count) and count >= 0 do
    digests = digests |> Enum.filter(&completed_item_digest_value?/1) |> Enum.take(@completed_item_digest_limit)

    receipt
    |> Map.put("completed_item_digests", digests)
    |> Map.put("completed_items", count)
  end

  defp maybe_put_completed_items(receipt, _fields), do: receipt

  defp completed_item_digest_value?(digest), do: is_binary(digest) and byte_size(digest) == 12 and digest =~ ~r/\A[0-9a-f]{12}\z/

  # Only a transport that classifies what it pushed writes the field (the
  # native websocket); a receipt without it keeps meaning "not classified".
  defp maybe_put_highest_frame_class(receipt, %{highest_frame_class: class}),
    do: Map.put(receipt, "highest_frame_class", highest_frame_class_value(class))

  defp maybe_put_highest_frame_class(receipt, _fields), do: receipt

  defp highest_frame_class_value(nil), do: @none
  defp highest_frame_class_value(class), do: vocabulary(class, @frame_classes, "other")

  defp sse_frame_class(data) do
    case SSEParser.complete_sse_blocks(data, bounded?: false) do
      {[_block | _rest] = blocks, ""} ->
        Enum.reduce(blocks, nil, fn block, highest ->
          higher_frame_class(highest, sse_block_frame_class(block))
        end)

      _incomplete ->
        "other"
    end
  end

  defp sse_block_frame_class(block) do
    decoded = block |> SSEParser.sse_field("data") |> SSEParser.decode_sse_data()

    type =
      case decoded do
        %{"type" => type} when is_binary(type) -> type
        _other -> SSEParser.sse_field(block, "event")
      end

    type_frame_class(type)
  end

  defp type_frame_class(type) when type in @lifecycle_frame_types, do: "lifecycle"
  defp type_frame_class("codex." <> _rest), do: "lifecycle"
  defp type_frame_class("response.output_item.added"), do: "item_added"
  defp type_frame_class(type) when type in @part_added_frame_types, do: "part_added"
  defp type_frame_class("response.output_item.done"), do: "item_done"
  defp type_frame_class(type) when type in @terminal_frame_types, do: "terminal"

  defp type_frame_class("response." <> _rest = type) do
    if String.ends_with?(type, ".delta"), do: "delta", else: "other"
  end

  defp type_frame_class(_type), do: "other"

  defp frame_class_rank(class), do: Enum.find_index(@frame_classes, &(&1 == class))

  @doc """
  Classifies a downstream frame as a terminal of the fixed vocabulary, or `nil`
  when the frame is not a provider terminal.
  """
  @spec terminal_class(binary() | term()) :: terminal_class()
  def terminal_class(data) when is_binary(data) do
    case StreamProtocol.terminal_outcome(data) do
      {:ok, outcome} -> terminal_class_from_outcome(outcome)
      _other -> nil
    end
  end

  def terminal_class(_data), do: nil

  @spec terminal_class_from_outcome(map()) :: terminal_class()
  def terminal_class_from_outcome(%{kind: :completed}), do: "response.completed"
  def terminal_class_from_outcome(%{kind: :incomplete}), do: "response.incomplete"

  def terminal_class_from_outcome(%{kind: :failed} = outcome) do
    case Map.get(outcome, :event_type) do
      event_type when event_type in @terminal_classes -> event_type
      _other -> "response.failed"
    end
  end

  def terminal_class_from_outcome(_outcome), do: nil

  @doc """
  Logs the single info receipt line and merges the receipt into the attempt
  row when an attempt id is known. Never raises: a persistence failure is
  reported as one bounded warning so the socket lifecycle stays unaffected.
  """
  @spec record(context(), receipt()) :: :ok
  def record(context, receipt) when is_map(context) and is_map(receipt) do
    _result = record_result(context, receipt)
    :ok
  end

  @doc false
  @spec persistence_timeout_ms(context()) :: pos_integer()
  def persistence_timeout_ms(%{request_id: request, replay_generation: generation}) when is_binary(request) and is_integer(generation) do
    # Ecto SQL and DBConnection use this timeout when the Repo has no override.
    case Keyword.get(Repo.config(), :timeout, 15_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _unbounded_or_invalid -> @persist_timeout_ms
    end
  end

  def persistence_timeout_ms(_context), do: @persist_timeout_ms

  @doc false
  @spec record_result(context(), receipt(), [persistence_option()]) :: :ok | {:error, term()}
  def record_result(context, receipt, opts \\ []) when is_map(context) and is_map(receipt) and is_list(opts) do
    request_id = DiagnosticTaxonomy.safe_correlator(Map.get(context, :request_id))
    session_id = DiagnosticTaxonomy.safe_correlator(Map.get(context, :codex_session_id))
    transport = vocabulary(receipt["transport"], @transports, @default_transport)

    Logger.info(
      "#{transport} downstream terminal pushed " <>
        "request_id=#{request_id} " <>
        "codex_session_id=#{session_id} " <>
        "outcome=#{receipt["outcome"]} " <>
        "terminal_class=#{receipt["terminal_class"]} " <>
        "frames_after_visible=#{receipt["frames_after_visible"]}" <>
        write_failure_field(receipt) <>
        incomplete_reason_field(receipt) <>
        end_turn_field(receipt)
    )

    case Map.get(context, :attempt_id) do
      attempt_id when is_binary(attempt_id) ->
        result = persist_result(attempt_id, receipt, context, Keyword.get(opts, :retry_timeout_ms))
        log_persist_failure(result, transport, request_id, session_id)
        result

      _missing ->
        :ok
    end
  end

  # Only the registry-owned handoff opts into retry. Its immutable deadline
  # bounds every actor and checkout, and each retry rechecks the same durable
  # request/attempt/generation authority. Log the transport receipt once,
  # independently of how many persistence transactions the database needs.
  defp persist_result(attempt_id, receipt, %{request_id: request_id, replay_generation: generation} = context, timeout_ms)
       when is_binary(request_id) and is_integer(generation) and generation >= 0 and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    SettlementRetry.run(
      :delivery_receipt,
      %{id: request_id},
      %{id: attempt_id},
      fn -> persist_retry_attempt(attempt_id, receipt, context, deadline) end,
      subject: "delivery receipt",
      fallback: "receipt_not_persisted",
      exhaustion: :return
    )
  rescue
    exception -> {:error, exception}
  end

  defp persist_result(attempt_id, receipt, context, _timeout), do: persist(attempt_id, receipt, context)

  defp persist_retry_attempt(attempt_id, receipt, context, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      # A cancelled COMMIT can disconnect its checked-out connection. Retry
      # the entire checkout as well as the transaction, never that dead lease.
      Repo.checkout(
        fn -> persist(attempt_id, receipt, context) |> raise_database_failure() end,
        timeout: min(remaining_ms, persistence_timeout_ms(context))
      )
    else
      {:error, :receipt_deadline_expired}
    end
  end

  defp raise_database_failure({:error, %DBConnection.ConnectionError{} = error}), do: raise(error)
  defp raise_database_failure({:error, %Postgrex.Error{} = error}), do: raise(error)
  defp raise_database_failure(result), do: result

  @doc """
  Merges the receipt under `#{@metadata_key}` with one bounded jsonb update,
  leaving every other attempt metadata key untouched.
  """
  @spec persist(Ecto.UUID.t(), receipt()) :: :ok | {:error, :attempt_not_found | term()}
  def persist(attempt_id, receipt) when is_binary(attempt_id) and is_map(receipt) do
    case Ecto.UUID.cast(attempt_id) do
      {:ok, _uuid} -> persist_receipt(attempt_id, receipt)
      :error -> {:error, :attempt_not_found}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc false
  @spec persist(Ecto.UUID.t(), receipt(), map()) :: :ok | {:error, term()}
  def persist(attempt_id, receipt, %{request_id: request_id, replay_generation: generation} = context)
      when is_binary(request_id) and is_integer(generation) and generation >= 0 do
    attrs = %{
      before_commit: fn result ->
        request = result.request

        status =
          cond do
            request.status == "succeeded" -> "succeeded"
            InterruptionOutcome.interrupted_error_code?(request.last_error_code) -> "interrupted"
            true -> "failed"
          end

        SessionContinuity.complete_codex_turn({:ok, result}, status, request.last_error_code)
        :ok
      end
    }

    case Accounting.record_delivery_receipt(Map.put(context, :attempt_id, attempt_id), receipt, attrs) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  def persist(attempt_id, receipt, _context), do: persist(attempt_id, receipt)

  defp persist_receipt(attempt_id, receipt) do
    patch = %{@metadata_key => receipt}

    query =
      from a in Attempt,
        where: a.id == ^attempt_id,
        update: [
          set: [
            response_metadata: fragment("COALESCE(?, '{}'::jsonb) || ?", a.response_metadata, type(^patch, :map))
          ]
        ]

    case Repo.update_all(query, [], timeout: @persist_timeout_ms) do
      {1, _returned} -> :ok
      {0, _returned} -> {:error, :attempt_not_found}
    end
  end

  defp write_failure_field(%{"write_failure" => failure}) when is_binary(failure), do: " write_failure=#{failure}"
  defp write_failure_field(_receipt), do: ""

  defp incomplete_reason_field(%{"incomplete_reason" => reason}) when is_binary(reason), do: " incomplete_reason=#{reason}"
  defp incomplete_reason_field(_receipt), do: ""

  defp end_turn_field(%{"end_turn" => class}) when is_binary(class), do: " end_turn=#{class}"
  defp end_turn_field(_receipt), do: ""

  defp log_persist_failure(:ok, _transport, _request_id, _session_id), do: :ok

  defp log_persist_failure({:error, reason}, transport, request_id, session_id) do
    Logger.warning(
      "#{transport} downstream delivery receipt not persisted " <>
        "request_id=#{request_id} " <>
        "codex_session_id=#{session_id} " <>
        "reason=#{failure_reason(reason)}"
    )

    :ok
  end

  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason({:exit, _reason}), do: "exit"
  defp failure_reason(%module{}), do: inspect(module)

  defp terminal_class_value(nil), do: @none
  defp terminal_class_value(value), do: vocabulary(value, @terminal_classes, @unknown)

  defp vocabulary(value, allowed, fallback) when is_atom(value) and not is_nil(value),
    do: vocabulary(Atom.to_string(value), allowed, fallback)

  defp vocabulary(value, allowed, fallback) when is_binary(value) do
    if value in allowed, do: value, else: fallback
  end

  defp vocabulary(_value, _allowed, fallback), do: fallback

  defp iso8601(%DateTime{} = pushed_at) do
    pushed_at
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_pushed_at), do: nil

  defp frame_count(count) when is_integer(count) and count >= 0, do: count
  defp frame_count(_count), do: 0
end
