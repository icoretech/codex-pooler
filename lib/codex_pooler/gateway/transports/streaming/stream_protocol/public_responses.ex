defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{PublicResponse, Responses}
  alias CodexPooler.Gateway.Runtime.Finalization.ProviderUsageLimit
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence

  @type summary_state :: %{
          required(:schema_version) => pos_integer(),
          required(:mode) => String.t(),
          required(:created_seen) => boolean(),
          required(:visible_seen) => boolean(),
          required(:delta_count) => non_neg_integer(),
          required(:delta_bytes) => non_neg_integer(),
          required(:text_done_count) => non_neg_integer(),
          required(:text_done_bytes) => non_neg_integer(),
          required(:item_done_count) => non_neg_integer(),
          required(:terminal_seen) => boolean(),
          required(:terminal_kind) => String.t() | nil,
          required(:terminal_status) => String.t() | nil,
          required(:finish_class) => String.t() | nil,
          required(:synthetic_terminal_sent) => boolean(),
          required(:source_chunk_count) => non_neg_integer(),
          required(:stream_bytes) => non_neg_integer(),
          required(:relay_bytes) => non_neg_integer(),
          required(:passthrough_seen) => boolean()
        }
  @type state :: %{
          required(:buffer) => binary(),
          required(:sse_block_state) => StreamProtocol.sse_block_state(),
          required(:buffer_candidate?) => boolean(),
          required(:created?) => boolean(),
          required(:text_delta?) => boolean(),
          required(:items_relayed?) => boolean(),
          required(:terminal_kind) => atom() | nil,
          required(:terminal_failure) => StreamProtocol.terminal_failure() | nil,
          required(:custom_tool_namespaces) => map(),
          required(:sequence) => PublicResponsesSequence.state(),
          required(:summary) => summary_state(),
          required(:passthrough?) => boolean(),
          required(:passthrough_terminal) => nil,
          required(:passthrough_terminal_kind) => atom() | nil,
          required(:passthrough_terminal_failure) => StreamProtocol.terminal_failure() | nil,
          required(:passthrough_terminal_seen?) => boolean()
        }

  @websocket_retry_error_codes ~w(websocket_connection_limit_reached previous_response_not_found)

  @spec new_state(map()) :: state()
  def new_state(custom_tool_namespaces \\ %{}) when is_map(custom_tool_namespaces) do
    %{
      buffer: "",
      sse_block_state: StreamProtocol.new_sse_block_state(),
      buffer_candidate?: false,
      created?: false,
      text_delta?: false,
      items_relayed?: false,
      terminal_kind: nil,
      terminal_failure: nil,
      custom_tool_namespaces: custom_tool_namespaces,
      sequence: PublicResponsesSequence.new_state(),
      summary: new_summary(),
      passthrough?: false,
      passthrough_terminal: nil,
      passthrough_terminal_kind: nil,
      passthrough_terminal_failure: nil,
      passthrough_terminal_seen?: false
    }
  end

  @terminal_buffer_markers [
    "data: [DONE]",
    "response.completed",
    "response.done",
    "response.failed",
    "response.incomplete",
    "event: error",
    ~s("type":"error"),
    ~s("type": "error")
  ]
  @max_safe_integer 9_007_199_254_740_991
  @failed_response_id_pattern ~r/^resp_[A-Za-z0-9_-]+$/

  @spec normalize_data(binary(), state()) :: {binary(), state()}
  def normalize_data(data, state) when is_binary(data) do
    state = record_source_chunk(state, data)
    {data, state} = normalize_data_chunk(data, state)
    {data, record_relay_chunk(state, data)}
  end

  def normalize_data(data, state), do: {data, state}

  @spec normalize_json_message(binary()) :: binary()
  def normalize_json_message(data) when is_binary(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} ->
        {normalized, _decoded} = normalize_json_message(data, decoded)
        normalized

      _invalid ->
        data
    end
  end

  @doc """
  Owner-side mapper for public turns carried over the upstream websocket.

  It normalizes like `normalize_json_message/2` except for a provider
  refusal sent as the websocket transport's wrapped error frame
  (`provider_rejection_frame?/1`), which it passes through unchanged: the
  websocket bridge turns that frame into the HTTP response the provider
  returns for the same request over HTTP (findings#225), and the public
  websocket surface normalizes every owner frame again with
  `normalize_json_message/2` before it reaches its client.
  """
  @spec normalize_owner_json_message(binary()) :: binary()
  def normalize_owner_json_message(data) when is_binary(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} ->
        {normalized, _decoded} = normalize_owner_json_message(data, decoded)
        normalized

      _invalid ->
        data
    end
  end

  @spec normalize_owner_json_message(binary(), map()) :: {binary(), map()}
  def normalize_owner_json_message(data, %{} = decoded) when is_binary(data) do
    if provider_rejection_frame?(decoded) or provider_usage_limit_frame?(decoded),
      do: {data, decoded},
      else: normalize_json_message(data, decoded)
  end

  @doc """
  True for a provider usage limit with a known reset sent as the websocket
  transport's wrapped `429` frame, or as the canonical `response.failed` the
  session makes of it, which keeps the wrapped `status` and the provider's
  error object (`ProviderUsageLimit.frame_error/2`). The owner passes it
  through unmasked like a refusal frame, and the public websocket, which
  normalizes every owner frame again, answers it with the wrapped terminal
  event (findings#206 row 206-546).
  """
  @spec provider_usage_limit_frame?(term()) :: boolean()
  def provider_usage_limit_frame?(%{"type" => type} = decoded) when type in ["error", "response.failed"],
    do: match?({:ok, _error}, ProviderUsageLimit.frame_error(decoded))

  def provider_usage_limit_frame?(_decoded), do: false

  @doc """
  True for the websocket transport's wrapped error frame
  (`{"type": "error", "status": 4xx, "error": {...}}`, `status_code` is the
  Codex client's alias) in the 4xx window whose rejection fields the HTTP
  path records (429 excluded), unless it carries one of the two codes the
  Codex client itself retries on its websocket.
  """
  @spec provider_rejection_frame?(term()) :: boolean()
  def provider_rejection_frame?(%{"type" => "error", "error" => %{} = error} = decoded) do
    status = Map.get(decoded, "status", Map.get(decoded, "status_code"))

    is_integer(status) and status in 400..499 and status != 429 and
      Map.get(error, "code") not in @websocket_retry_error_codes
  end

  def provider_rejection_frame?(_decoded), do: false

  @spec normalize_json_message(binary(), map()) :: {binary(), map()}
  def normalize_json_message(_data, %{"type" => "response.failed"} = decoded) do
    normalized = normalize_terminal_errors("response.failed", decoded)
    {CodexPooler.JSON.encode!(normalized), normalized}
  end

  def normalize_json_message(data, %{} = decoded) when is_binary(data) do
    {canonical_data, canonical} = canonicalize_public_json_message(decoded, data)
    normalize_public_json_message(canonical, canonical_data)
  end

  defp normalize_data_chunk(_data, %{sequence: %{terminal_latched?: true}} = state) do
    {"",
     %{
       state
       | buffer: "",
         sse_block_state: StreamProtocol.new_sse_block_state(),
         buffer_candidate?: false,
         passthrough?: false
     }}
  end

  defp normalize_data_chunk(data, state) do
    previous_buffer = state.buffer

    {blocks, sse_block_state} =
      StreamProtocol.complete_sse_blocks(state.sse_block_state, data, bounded?: false)

    buffer = sse_block_state.buffer
    candidate? = incremental_buffer_candidate?(state, previous_buffer, data, blocks, buffer)

    state = %{
      state
      | buffer: buffer,
        sse_block_state: sse_block_state,
        buffer_candidate?: candidate?
    }

    cond do
      structurally_complete_terminal_buffer?(buffer, candidate?) ->
        state = %{state | sse_block_state: StreamProtocol.new_sse_block_state()}
        normalize_blocks(blocks ++ [buffer], "", state)

      candidate? and StreamProtocol.oversized_incomplete_terminal_sse_block?(buffer) ->
        record_oversized_incomplete(
          byte_size(buffer),
          StreamProtocol.max_incomplete_terminal_sse_block_bytes()
        )

        fail_oversized_incomplete(blocks, state)

      candidate? ->
        normalize_blocks(blocks, buffer, state)

      StreamProtocol.oversized_incomplete_sse_block?(buffer) ->
        record_oversized_incomplete(
          byte_size(buffer),
          StreamProtocol.max_incomplete_sse_block_bytes()
        )

        fail_oversized_incomplete(blocks, state)

      true ->
        normalize_blocks(blocks, buffer, state)
    end
  end

  # Invariant: state.buffer_candidate? always equals
  # terminal_buffer_candidate?(state.buffer). When the parse provably appended
  # (`buffer == previous_buffer <> data`, guaranteed by the size match because
  # neither CRLF collapse nor splitting nor bounding preserves the size), the
  # flag advances with one scan of the junction window plus the new data
  # instead of rescanning the whole retained buffer; any restructured result
  # recomputes from scratch.
  defp incremental_buffer_candidate?(state, previous_buffer, data, blocks, buffer) do
    cond do
      buffer == "" ->
        false

      blocks == [] and previous_buffer != "" and
          byte_size(buffer) == byte_size(previous_buffer) + byte_size(data) ->
        state.buffer_candidate? or junction_window_candidate?(previous_buffer, data)

      true ->
        terminal_buffer_candidate?(buffer)
    end
  end

  # Longest marker is "response.incomplete" (19 bytes), so a marker not fully
  # inside the previous buffer must start within its last 18 bytes.
  @terminal_marker_overlap 18
  defp junction_window_candidate?(previous_buffer, data) do
    overlap = min(byte_size(previous_buffer), @terminal_marker_overlap)

    window =
      binary_part(previous_buffer, byte_size(previous_buffer) - overlap, overlap) <> data

    terminal_buffer_candidate?(window)
  end

  defp fail_oversized_incomplete(blocks, state) do
    {iodata, state, _terminal_in_batch?} =
      normalize_complete_blocks(
        blocks,
        %{
          state
          | buffer: "",
            sse_block_state: StreamProtocol.new_sse_block_state(),
            buffer_candidate?: false,
            passthrough?: false
        }
      )

    if state.sequence.terminal_latched? do
      {IO.iodata_to_binary(iodata), state}
    else
      {sequence_number, state} = track_synthetic_terminal_failure(state)

      terminal =
        StreamProtocol.synthetic_public_openai_responses_error_sse(
          :upstream_stream_error,
          sequence_number
        )

      {[iodata, terminal] |> IO.iodata_to_binary(), state}
    end
  end

  @spec passthrough_terminal_kind(state()) :: atom() | nil
  def passthrough_terminal_kind(%{passthrough_terminal_kind: kind}) when is_atom(kind), do: kind
  def passthrough_terminal_kind(_state), do: nil

  @spec passthrough_terminal_failure(state()) :: StreamProtocol.terminal_failure() | nil
  def passthrough_terminal_failure(%{passthrough_terminal_failure: %{} = failure}), do: failure
  def passthrough_terminal_failure(_state), do: nil

  @spec terminal_kind(state()) :: atom() | nil
  def terminal_kind(%{terminal_kind: kind}) when is_atom(kind), do: kind
  def terminal_kind(_state), do: nil

  @spec terminal_failure(state()) :: StreamProtocol.terminal_failure() | nil
  def terminal_failure(%{terminal_failure: %{} = failure}), do: failure
  def terminal_failure(_state), do: nil

  @spec visible_seen?(state()) :: boolean()
  def visible_seen?(%{summary: %{visible_seen: visible_seen?}}), do: visible_seen?
  def visible_seen?(_state), do: false

  @spec summary_metadata(state()) :: map()
  def summary_metadata(%{summary: %{} = summary}) do
    %{
      "schema_version" => summary.schema_version,
      "mode" => summary.mode,
      "created_seen" => summary.created_seen,
      "visible_seen" => summary.visible_seen,
      "delta_count" => summary.delta_count,
      "delta_bytes" => summary.delta_bytes,
      "text_done_count" => summary.text_done_count,
      "text_done_bytes" => summary.text_done_bytes,
      "item_done_count" => summary.item_done_count,
      "terminal_seen" => summary.terminal_seen,
      "terminal_kind" => summary.terminal_kind,
      "terminal_status" => summary.terminal_status,
      "finish_class" => summary.finish_class,
      "synthetic_terminal_sent" => summary.synthetic_terminal_sent,
      "source_chunk_count" => summary.source_chunk_count,
      "stream_bytes" => summary.stream_bytes,
      "relay_bytes" => summary.relay_bytes,
      "passthrough_seen" => summary.passthrough_seen
    }
  end

  def summary_metadata(_state), do: %{}

  @spec mark_synthetic_terminal_failure(state()) :: state()
  def mark_synthetic_terminal_failure(state) do
    state
    |> Map.put(:terminal_kind, :failed)
    |> put_summary(:synthetic_terminal_sent, true)
    |> put_summary_terminal(:failed, "failed")
  end

  @spec track_synthetic_terminal_failure(state()) :: {non_neg_integer(), state()}
  def track_synthetic_terminal_failure(state) do
    synthetic_terminal = %{
      "type" => "response.failed",
      "response" => %{"status" => "failed"}
    }

    {:emit, "response.failed", %{"sequence_number" => sequence_number}, sequence_state} =
      PublicResponsesSequence.assign(
        "response.failed",
        synthetic_terminal,
        state.sequence,
        :sse
      )

    state =
      state
      |> Map.put(:sequence, sequence_state)
      |> mark_synthetic_terminal_failure()

    {sequence_number, state}
  end

  defp record_oversized_incomplete(bytes, max_bytes) do
    BufferTelemetry.record_oversized_incomplete(
      "public_openai_responses_sse",
      bytes,
      max_bytes
    )
  end

  defp normalize_complete_blocks(blocks, state) do
    Enum.reduce(blocks, {[], state, false}, fn block, {iodata, stream_state, terminal?} ->
      {normalized, stream_state, terminal_in_block?} = normalize_block(block, stream_state)
      {[iodata, normalized], stream_state, terminal? or terminal_in_block?}
    end)
  end

  defp normalize_blocks(blocks, buffer, state) do
    {iodata, state, terminal_in_batch?} =
      normalize_complete_blocks(
        blocks,
        %{state | buffer: buffer, buffer_candidate?: buffer != "" and state.buffer_candidate?}
      )

    state = if terminal_in_batch?, do: reset_parser_after_terminal(state), else: state

    {IO.iodata_to_binary(iodata), state}
  end

  defp normalize_block("data: [DONE]", state) do
    state =
      state
      |> Map.update!(:sequence, &%{&1 | terminal_latched?: true})
      |> Map.put(:terminal_kind, :completed)
      |> Map.put(:terminal_failure, nil)
      |> put_summary_terminal(:completed, "completed")

    {[], state, true}
  end

  defp normalize_block(block, state) do
    {event_type, decoded} = stream_block_event(block)

    decoded =
      decoded
      |> drop_provider_event_headers()
      |> Responses.restore_custom_tool_call_namespaces(state.custom_tool_namespaces)

    source_type = effective_source_public_type(event_type, decoded)
    source_terminal_outcome = source_terminal_outcome(source_type, decoded)
    decoded = normalize_matching_terminal_errors(event_type, decoded)

    case PublicResponsesSequence.public_shape(event_type, decoded) do
      {:ok, type, decoded} ->
        decoded = normalize_public_event(type, decoded)

        terminal_in_block? =
          type in ["response.completed", "response.failed", "response.incomplete", "error"]

        {normalized, state} =
          if terminal_in_block? do
            normalize_public_terminal_block(type, decoded, source_terminal_outcome, state)
          else
            normalize_public_block(type, decoded, state)
          end

        {normalized, state, terminal_in_block?}

      :drop ->
        {[], state, false}
    end
  end

  defp effective_source_public_type(event_type, %{} = decoded) do
    event_type = StreamProtocol.normalize_sse_event_label(event_type)
    data_type = clean_string(Map.get(decoded, "type"))

    if public_types_agree?(event_type, data_type) do
      event_type || data_type
    end
  end

  defp normalize_public_block("response.created", decoded, state) do
    {block, state, emitted?} = emit_public_sse("response.created", decoded, state)
    {block, if(emitted?, do: record_created(state), else: state)}
  end

  defp normalize_public_block("response.output_text.delta", decoded, state) do
    {block, state, emitted?} = emit_public_sse("response.output_text.delta", decoded, state)
    {block, if(emitted?, do: record_delta(state, decoded), else: state)}
  end

  defp normalize_public_block("response.output_text.done", decoded, state) do
    {block, state, emitted?} = emit_public_sse("response.output_text.done", decoded, state)
    {block, if(emitted?, do: record_text_done(state, decoded), else: state)}
  end

  defp normalize_public_block("response.output_item.added", decoded, state) do
    {block, state, emitted?} = emit_public_sse("response.output_item.added", decoded, state)
    {block, if(emitted?, do: state |> record_visible("response.output_item.added", decoded) |> record_item_relayed(), else: state)}
  end

  defp normalize_public_block("response.output_item.done", decoded, state) do
    {block, state, emitted?} = emit_public_sse("response.output_item.done", decoded, state)
    {block, if(emitted?, do: state |> record_item_done() |> record_item_relayed(), else: state)}
  end

  defp normalize_public_block(type, decoded, state) when is_binary(type) do
    if public_stream_event?(type) do
      {block, state, emitted?} = emit_public_sse(type, decoded, state)

      state =
        if emitted?,
          do: state |> record_visible(type, decoded) |> record_hosted_shell_event(type),
          else: state

      {block, state}
    else
      {[], state}
    end
  end

  defp normalize_public_block(_type, _decoded, state), do: {[], state}

  defp normalize_public_terminal_block(type, decoded, source_terminal_outcome, state) do
    {prefix, state} = terminal_prefix(type, decoded, state)
    {terminal, state, emitted?} = emit_public_sse(type, decoded, state)

    state =
      if emitted?,
        do: record_terminal(state, type, decoded, source_terminal_outcome),
        else: state

    {[prefix, terminal], state}
  end

  defp terminal_prefix(type, _decoded, %{created?: false, text_delta?: false} = state)
       when type in ["response.failed", "response.incomplete", "error"],
       do: {[], state}

  # A terminal that closes a response the upstream never opened is preceded by
  # the grammar the Responses stream contract requires, so SDK stream helpers
  # (openai-python `responses.stream()`, openai-node `responses.stream()`,
  # `@ai-sdk/openai`) can follow it: a `response.created` snapshot, then every
  # terminal output item announced in order with its content parts and text
  # (findings#254). Only what the terminal carries is replayed; items the
  # upstream already relayed, or text it already streamed, are never repeated.
  defp terminal_prefix(_type, decoded, state) do
    {created_prefix, state} = created_prefix(decoded, state)
    {output_prefix, state} = output_prefix(decoded, state)
    {[created_prefix, output_prefix], state}
  end

  defp created_prefix(_decoded, %{created?: true} = state), do: {[], state}

  defp created_prefix(decoded, state) do
    created = %{"type" => "response.created", "response" => created_snapshot(decoded)}
    {block, state, emitted?} = emit_public_sse("response.created", created, state)
    {block, if(emitted?, do: record_created(state), else: state)}
  end

  # The opening snapshot carries the identity the terminal response states
  # (id, creation time, model) with no output yet; a field the terminal does
  # not carry stays absent rather than being invented.
  defp created_snapshot(decoded) do
    response = terminal_response(decoded)

    %{"object" => "response", "status" => "in_progress", "output" => []}
    |> maybe_put_created_field("id", nested_string(decoded, ["response", "id"]) || decoded_string(decoded, "id"))
    |> maybe_put_created_field("created_at", Map.get(response, "created_at"))
    |> maybe_put_created_field("model", Map.get(response, "model"))
  end

  defp maybe_put_created_field(snapshot, key, value) when key in ["id", "model"] and is_binary(value) and value != "",
    do: Map.put(snapshot, key, value)

  defp maybe_put_created_field(snapshot, "created_at", value) when is_integer(value) and value >= 0,
    do: Map.put(snapshot, "created_at", value)

  defp maybe_put_created_field(snapshot, _key, _value), do: snapshot

  defp output_prefix(_decoded, %{text_delta?: true} = state), do: {[], state}
  defp output_prefix(_decoded, %{items_relayed?: true} = state), do: {[], state}

  defp output_prefix(decoded, state) do
    decoded
    |> terminal_response()
    |> Map.get("output")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, output_index} -> output_item_events(item, output_index) end)
    |> Enum.reduce({[], state}, fn {type, event}, {blocks, state} ->
      {block, state, emitted?} = emit_public_sse(type, event, state)
      {[blocks, block], if(emitted?, do: record_synthesized(state, type, event), else: state)}
    end)
  end

  defp terminal_response(%{"response" => %{} = response}), do: response
  defp terminal_response(%{} = decoded), do: decoded

  # A message is announced empty and filled part by part, because the SDK
  # accumulators append each content part and each delta onto the announced
  # item; any other item is announced and closed as the terminal states it.
  defp output_item_events(%{"type" => "message"} = item, output_index) do
    item_id = Map.get(item, "id")

    parts =
      item
      |> Map.get("content")
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.with_index()
      |> Enum.flat_map(fn {part, content_index} ->
        content_part_events(part, %{"item_id" => item_id, "output_index" => output_index, "content_index" => content_index})
      end)

    [
      {"response.output_item.added",
       %{
         "type" => "response.output_item.added",
         "output_index" => output_index,
         "item" => item |> Map.put("status", "in_progress") |> Map.put("content", [])
       }}
    ] ++ parts ++ [output_item_done(item, output_index)]
  end

  defp output_item_events(item, output_index) do
    [
      {"response.output_item.added", %{"type" => "response.output_item.added", "output_index" => output_index, "item" => item}},
      output_item_done(item, output_index)
    ]
  end

  defp output_item_done(item, output_index) do
    {"response.output_item.done", %{"type" => "response.output_item.done", "output_index" => output_index, "item" => item}}
  end

  defp content_part_events(%{"type" => "output_text", "text" => text} = part, position) when is_binary(text) do
    opening = part |> Map.put("text", "") |> reset_annotations()

    [{"response.content_part.added", Map.merge(position, %{"type" => "response.content_part.added", "part" => opening})}] ++
      text_events(text, position) ++
      [{"response.content_part.done", Map.merge(position, %{"type" => "response.content_part.done", "part" => part})}]
  end

  defp content_part_events(part, position) do
    [
      {"response.content_part.added", Map.merge(position, %{"type" => "response.content_part.added", "part" => part})},
      {"response.content_part.done", Map.merge(position, %{"type" => "response.content_part.done", "part" => part})}
    ]
  end

  defp text_events("", position) do
    [{"response.output_text.done", Map.merge(position, %{"type" => "response.output_text.done", "text" => ""})}]
  end

  defp text_events(text, position) do
    [
      {"response.output_text.delta", Map.merge(position, %{"type" => "response.output_text.delta", "delta" => text})},
      {"response.output_text.done", Map.merge(position, %{"type" => "response.output_text.done", "text" => text})}
    ]
  end

  defp reset_annotations(%{"annotations" => _annotations} = part), do: Map.put(part, "annotations", [])
  defp reset_annotations(part), do: part

  defp record_synthesized(state, "response.output_text.delta", event), do: record_delta(state, event)
  defp record_synthesized(state, "response.output_text.done", event), do: record_text_done(state, event)
  defp record_synthesized(state, "response.output_item.done", _event), do: state |> record_item_done() |> record_item_relayed()
  defp record_synthesized(state, "response.output_item.added", _event), do: state |> put_summary(:visible_seen, true) |> record_item_relayed()
  defp record_synthesized(state, _type, _event), do: state

  defp public_sse_block(event_type, decoded) when is_binary(event_type) and is_map(decoded) do
    [
      "event: ",
      event_type,
      "\n",
      "data: ",
      CodexPooler.JSON.encode!(Map.put_new(decoded, "type", event_type)),
      "\n\n"
    ]
  end

  defp emit_public_sse(type, decoded, state) do
    case PublicResponsesSequence.assign(type, decoded, state.sequence, :sse) do
      {:emit, event_type, decoded, sequence} ->
        {[public_sse_block(event_type, decoded)], %{state | sequence: sequence}, true}

      {:drop, sequence} ->
        {[], %{state | sequence: sequence}, false}

      {:overflow, failed, sequence} ->
        failed = normalize_public_event("response.failed", failed)

        state =
          state
          |> Map.put(:sequence, sequence)
          |> record_terminal("response.failed", failed)

        {[public_sse_block("response.failed", failed)], state, false}
    end
  end

  defp normalize_public_event(type, %{} = decoded)
       when type in ["response.output_item.added", "response.output_item.done"] do
    case decoded do
      %{"item" => %{} = item} -> Map.put(decoded, "item", ensure_output_item_id(item, decoded))
      _event -> decoded
    end
  end

  defp normalize_public_event(type, %{} = decoded) do
    if terminal_event?(type) do
      normalize_terminal_output_items(decoded)
      |> then(&normalize_terminal_errors(type, &1))
    else
      decoded
    end
  end

  # Public /v1 events carry no provider header objects: `headers` and the
  # nested `response.headers` are dropped from every decoded event before it
  # is shaped and re-encoded, on SSE and on the public websocket alike
  # (findings#239). The one exemption is `codex.response.metadata`, whose
  # header object is the event's payload (the owner-forwarded Pooler ETag
  # event on a public turn); the session already strips an untrusted
  # provider ETag from it. An event without header objects is returned as is.
  @spec drop_provider_event_headers(map()) :: map()
  def drop_provider_event_headers(%{"type" => "codex.response.metadata"} = decoded), do: decoded

  def drop_provider_event_headers(%{} = decoded) do
    case NativeCodexResponseControl.drop_event_headers(decoded) do
      {:changed, dropped} -> dropped
      _unchanged -> decoded
    end
  end

  @spec normalize_terminal_errors(String.t() | nil, map()) :: map()
  def normalize_terminal_errors("response.failed", %{} = decoded) do
    response =
      case Map.get(decoded, "response") do
        %{} = response -> response
        _value -> %{}
      end

    status = wrapped_throttle_status(decoded)

    event = %{
      "type" => "response.failed",
      "response" => project_failed_response(response, status)
    }

    event =
      case Map.fetch(decoded, "sequence_number") do
        {:ok, sequence_number} -> Map.put(event, "sequence_number", sequence_number)
        :error -> event
      end

    maybe_put_failed_top_level_error(event, decoded, status)
  end

  def normalize_terminal_errors(type, %{} = decoded)
      when type in ["response.completed", "response.incomplete", "error"] do
    decoded
    |> normalize_top_level_error()
    |> normalize_response_error()
  end

  def normalize_terminal_errors(_type, %{} = decoded), do: decoded

  defp canonicalize_public_json_message(decoded, data) do
    case suppress_incomplete_provider_error_types(decoded) do
      {:unchanged, prepared} ->
        StreamProtocol.canonicalize_codex_responses_json_message(data, prepared)

      {:changed, prepared} ->
        canonical_input = CodexPooler.JSON.encode!(prepared)
        StreamProtocol.canonicalize_codex_responses_json_message(canonical_input, prepared)
    end
  end

  defp normalize_public_json_message(%{} = decoded, canonical_data) do
    type = clean_string(Map.get(decoded, "type"))

    case normalize_terminal_errors_with_change(type, decoded) do
      {:unchanged, normalized} -> {canonical_data, normalized}
      {:changed, normalized} -> {CodexPooler.JSON.encode!(normalized), normalized}
    end
  end

  defp suppress_incomplete_provider_error_types(%{"type" => "response.incomplete"} = decoded) do
    {top_level_change, decoded} = drop_type_without_code(decoded, ["error"])
    {nested_change, decoded} = drop_type_without_code(decoded, ["response", "error"])

    if top_level_change == :changed or nested_change == :changed,
      do: {:changed, decoded},
      else: {:unchanged, decoded}
  end

  defp suppress_incomplete_provider_error_types(decoded), do: {:unchanged, decoded}

  defp drop_type_without_code(decoded, path) do
    case get_in(decoded, path) do
      %{"type" => _type, "code" => code} when is_binary(code) ->
        {:unchanged, decoded}

      %{"type" => _type} = error ->
        {:changed, put_in(decoded, path, Map.delete(error, "type"))}

      _error ->
        {:unchanged, decoded}
    end
  end

  defp normalize_matching_terminal_errors(event_type, decoded) do
    event_type = StreamProtocol.normalize_sse_event_label(event_type)

    if public_types_agree?(event_type, clean_string(Map.get(decoded, "type"))) do
      {_change, decoded} = suppress_incomplete_provider_error_types(decoded)
      normalize_terminal_errors(event_type || clean_string(Map.get(decoded, "type")), decoded)
    else
      decoded
    end
  end

  defp source_terminal_outcome("response.failed", %{} = decoded) do
    nested_error =
      case Map.get(decoded, "response") do
        %{} = response -> Map.get(response, "error")
        _response -> nil
      end

    classification =
      %{"type" => "response.failed", "response" => %{}}
      |> maybe_put_source_top_level_error(Map.get(decoded, "error"))
      |> maybe_put_source_nested_error(nested_error)

    StreamProtocol.terminal_outcome("response.failed", classification)
  end

  defp source_terminal_outcome(_event_type, _decoded), do: nil

  defp maybe_put_source_top_level_error(classification, %{} = error) do
    Map.put(classification, "error", normalize_terminal_error(error))
  end

  defp maybe_put_source_top_level_error(classification, _error), do: classification

  defp maybe_put_source_nested_error(classification, %{} = error) do
    put_in(classification, ["response", "error"], normalize_terminal_error(error))
  end

  defp maybe_put_source_nested_error(classification, _error), do: classification

  # The upstream includes `"error": null` on every successful terminal event.
  # A key-presence match treated that null as an error to normalize, and the
  # non-map fallback below fabricated a redacted `upstream_error`/`server_error`
  # object onto every successful streamed terminal. Null means success: preserve
  # it, and only rewrite genuinely present error objects.
  defp normalize_top_level_error(%{"error" => nil} = decoded), do: decoded

  defp normalize_top_level_error(%{"error" => error} = decoded),
    do: Map.put(decoded, "error", normalize_terminal_error(error))

  defp normalize_top_level_error(decoded), do: decoded

  # A real top-level error alongside a null nested error keeps the existing
  # copy-into-response behavior instead of fabricating from the null.
  defp normalize_response_error(%{"error" => %{} = public_error, "response" => %{"error" => nil} = response} = decoded) do
    Map.put(decoded, "response", Map.put(response, "error", public_error))
  end

  defp normalize_response_error(%{"response" => %{"error" => nil}} = decoded), do: decoded

  defp normalize_response_error(%{"response" => %{"error" => error} = response} = decoded) do
    Map.put(
      decoded,
      "response",
      Map.put(response, "error", normalize_terminal_error(error))
    )
  end

  defp normalize_response_error(%{"error" => %{} = public_error, "response" => %{} = response} = decoded) do
    Map.put(decoded, "response", Map.put(response, "error", public_error))
  end

  defp normalize_response_error(decoded), do: decoded

  # A provider 429 the upstream websocket sent as its wrapped error frame is
  # canonicalized to a `response.failed` that keeps the integer `status`; its
  # masked error is typed from that status like the `/v1` HTTP answer of the
  # same throttle, `rate_limit_error`, instead of `server_error` (findings#254
  # row 254-82; HTTP since row 254-72). The masked frame drops the status, and
  # the public websocket normalizes the owner's frame a second time, so a
  # redacted throttle error keeps its type there (`PublicResponse.redacted_throttle_error?/1`).
  defp wrapped_throttle_status(decoded) do
    if Map.get(decoded, "status", Map.get(decoded, "status_code")) == 429, do: 429
  end

  defp normalize_terminal_error(error, 429) when is_map(error), do: PublicResponse.normalize_error(error, status: 429)
  defp normalize_terminal_error(error, _status), do: normalize_terminal_error(error)

  defp normalize_terminal_error(%{} = error) do
    if PublicResponse.redacted_throttle_error?(error),
      do: PublicResponse.normalize_error(error, status: 429),
      else: PublicResponse.normalize_error(error, status: PublicResponse.terminal_error_status(error))
  end

  defp normalize_terminal_error(error), do: PublicResponse.normalize_error(error, status: 502)

  defp normalize_terminal_errors_with_change(type, decoded) do
    normalized = normalize_terminal_errors(type, decoded)
    change = if normalized === decoded, do: :unchanged, else: :changed
    {change, normalized}
  end

  defp project_failed_response(response, status) do
    %{
      "id" => safe_failed_response_id(Map.get(response, "id")),
      "created_at" => 0,
      "status" => "failed",
      "error" => normalize_terminal_error(Map.get(response, "error"), status),
      "incomplete_details" => project_failed_incomplete_details(Map.get(response, "incomplete_details")),
      "model" => "unknown",
      "object" => "response",
      "output" => [],
      "output_text" => "",
      "instructions" => nil,
      "metadata" => nil,
      "parallel_tool_calls" => false,
      "tool_choice" => "auto",
      "tools" => [],
      "usage" => project_failed_usage(Map.get(response, "usage")),
      "temperature" => nil,
      "top_p" => nil
    }
  end

  defp project_failed_incomplete_details(%{"reason" => reason})
       when reason in ["max_output_tokens", "content_filter"],
       do: %{"reason" => reason}

  defp project_failed_incomplete_details(_details), do: nil

  defp project_failed_usage(%{} = usage) do
    input_details =
      case Map.get(usage, "input_tokens_details") do
        %{} = details -> details
        _details -> %{}
      end

    output_details =
      case Map.get(usage, "output_tokens_details") do
        %{} = details -> details
        _details -> %{}
      end

    input_tokens = bounded_usage_integer(Map.get(usage, "input_tokens"))
    output_tokens = bounded_usage_integer(Map.get(usage, "output_tokens"))

    total_tokens =
      case Map.get(usage, "total_tokens") do
        value when is_integer(value) and value >= 0 and value <= @max_safe_integer ->
          value

        _value ->
          min(input_tokens + output_tokens, @max_safe_integer)
      end

    %{
      "input_tokens" => input_tokens,
      "input_tokens_details" => %{
        "cache_write_tokens" => bounded_usage_integer(Map.get(input_details, "cache_write_tokens")),
        "cached_tokens" => bounded_usage_integer(Map.get(input_details, "cached_tokens"))
      },
      "output_tokens" => output_tokens,
      "output_tokens_details" => %{
        "reasoning_tokens" => bounded_usage_integer(Map.get(output_details, "reasoning_tokens"))
      },
      "total_tokens" => total_tokens
    }
  end

  defp project_failed_usage(_usage), do: nil

  defp safe_failed_response_id(value)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= 255 do
    if Regex.match?(@failed_response_id_pattern, value), do: value, else: "resp_failed"
  end

  defp safe_failed_response_id(_value), do: "resp_failed"

  defp bounded_usage_integer(value)
       when is_integer(value) and value >= 0 and value <= @max_safe_integer,
       do: value

  defp bounded_usage_integer(_value), do: 0

  defp maybe_put_failed_top_level_error(event, source, status) do
    case Map.fetch(source, "error") do
      {:ok, error} -> Map.put(event, "error", normalize_terminal_error(error, status))
      :error -> event
    end
  end

  defp normalize_terminal_output_items(%{"response" => %{} = response} = decoded) do
    Map.put(decoded, "response", normalize_response_output_items(response))
  end

  defp normalize_terminal_output_items(%{} = decoded),
    do: normalize_response_output_items(decoded)

  defp normalize_response_output_items(%{"output" => output} = response) when is_list(output) do
    output =
      output
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> ensure_output_item_id(item, %{"output_index" => index}) end)

    Map.put(response, "output", output)
  end

  defp normalize_response_output_items(response), do: response

  defp ensure_output_item_id(%{} = item, context) do
    case clean_string(Map.get(item, "id")) || clean_string(Map.get(item, "call_id")) ||
           clean_string(Map.get(context, "item_id")) do
      nil -> Map.put(item, "id", fallback_output_item_id(item, context))
      id -> Map.put(item, "id", id)
    end
  end

  defp ensure_output_item_id(item, _context), do: item

  defp fallback_output_item_id(item, context) do
    item_type = clean_string(Map.get(item, "type")) || "item"

    case Map.get(context, "output_index") do
      index when is_integer(index) and index >= 0 -> "#{item_type}_#{index}"
      index when is_binary(index) and index != "" -> "#{item_type}_#{index}"
      _index -> item_type
    end
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp new_summary do
    %{
      schema_version: 1,
      mode: "normalized",
      created_seen: false,
      visible_seen: false,
      delta_count: 0,
      delta_bytes: 0,
      text_done_count: 0,
      text_done_bytes: 0,
      item_done_count: 0,
      terminal_seen: false,
      terminal_kind: nil,
      terminal_status: nil,
      finish_class: nil,
      synthetic_terminal_sent: false,
      source_chunk_count: 0,
      stream_bytes: 0,
      relay_bytes: 0,
      passthrough_seen: false
    }
  end

  defp record_source_chunk(state, data) when is_binary(data) do
    state
    |> update_summary(:source_chunk_count, &(&1 + 1))
    |> update_summary(:stream_bytes, &(&1 + byte_size(data)))
  end

  defp record_relay_chunk(state, data) when is_binary(data) do
    update_summary(state, :relay_bytes, &(&1 + byte_size(data)))
  end

  defp reset_parser_after_terminal(state) do
    %{
      state
      | buffer: "",
        sse_block_state: StreamProtocol.new_sse_block_state(),
        buffer_candidate?: false,
        created?: false,
        text_delta?: false,
        items_relayed?: false,
        passthrough?: false,
        passthrough_terminal: nil
    }
  end

  defp record_created(state) do
    state
    |> Map.put(:created?, true)
    |> put_summary(:created_seen, true)
    |> put_summary(:visible_seen, true)
  end

  defp record_delta(state, decoded) do
    case decoded_string(decoded, "delta") do
      delta when is_binary(delta) ->
        state
        |> Map.put(:text_delta?, true)
        |> put_summary(:visible_seen, true)
        |> update_summary(:delta_count, &(&1 + 1))
        |> update_summary(:delta_bytes, &(&1 + byte_size(delta)))

      nil ->
        state
    end
  end

  defp record_item_relayed(state), do: %{state | items_relayed?: true}

  defp record_text_done(state, decoded) do
    text_bytes = decoded |> decoded_string("text") |> safe_byte_size()

    state
    |> put_summary(:visible_seen, true)
    |> update_summary(:text_done_count, &(&1 + 1))
    |> update_summary(:text_done_bytes, &(&1 + text_bytes))
  end

  defp record_item_done(state) do
    state
    |> put_summary(:visible_seen, true)
    |> update_summary(:item_done_count, &(&1 + 1))
  end

  defp record_visible(state, type, _decoded) when is_binary(type) do
    if visible_type?(type), do: put_summary(state, :visible_seen, true), else: state
  end

  defp record_hosted_shell_event(state, "response.shell_call_" <> _suffix),
    do: %{state | created?: true}

  defp record_hosted_shell_event(state, _type), do: state

  defp record_terminal(state, type, decoded) do
    record_terminal(state, type, decoded, nil)
  end

  defp record_terminal(state, type, decoded, source_terminal_outcome) do
    case source_terminal_outcome || StreamProtocol.terminal_outcome(type, decoded) do
      {:ok, %{kind: kind} = outcome} ->
        state
        |> Map.put(:terminal_kind, kind)
        |> maybe_put_terminal_failure(outcome)
        |> put_summary_terminal(kind, terminal_status_for_kind(kind))

      _outcome ->
        state
    end
  end

  defp maybe_put_terminal_failure(state, %{kind: :failed, failure: %{} = failure}) do
    Map.put(state, :terminal_failure, failure)
  end

  defp maybe_put_terminal_failure(state, _outcome), do: state

  defp put_summary_terminal(state, kind, status) when is_atom(kind) do
    state
    |> put_summary(:terminal_seen, true)
    |> put_summary(:terminal_kind, Atom.to_string(kind))
    |> put_summary(:terminal_status, status)
    |> put_summary(:finish_class, Atom.to_string(kind))
  end

  defp terminal_status_for_kind(:completed), do: "completed"
  defp terminal_status_for_kind(:incomplete), do: "incomplete"
  defp terminal_status_for_kind(:failed), do: "failed"

  defp visible_type?(type) do
    String.contains?(type, ".delta") or String.contains?(type, "output") or
      String.contains?(type, "message") or String.contains?(type, "tool")
  end

  defp safe_byte_size(value) when is_binary(value), do: byte_size(value)
  defp safe_byte_size(_value), do: 0

  defp put_summary(%{summary: summary} = state, key, value) do
    %{state | summary: Map.put(summary, key, value)}
  end

  defp update_summary(%{summary: summary} = state, key, fun) when is_function(fun, 1) do
    %{state | summary: Map.update!(summary, key, fun)}
  end

  @spec structurally_complete_terminal_buffer?(binary(), boolean()) :: boolean()
  defp structurally_complete_terminal_buffer?("", _candidate?), do: false

  defp structurally_complete_terminal_buffer?(buffer, candidate?) when is_binary(buffer) do
    candidate? and (done_marker?(buffer) or decoded_sse_buffer?(buffer))
  end

  @spec terminal_buffer_candidate?(binary()) :: boolean()
  defp terminal_buffer_candidate?(buffer) do
    String.contains?(buffer, @terminal_buffer_markers)
  end

  @spec done_marker?(binary()) :: boolean()
  defp done_marker?(block), do: String.trim(block) == "data: [DONE]"

  @spec decoded_sse_buffer?(binary()) :: boolean()
  defp decoded_sse_buffer?(buffer) do
    if maybe_decodable_tail?(buffer) do
      data = StreamProtocol.sse_field(buffer, "data") || buffer

      match?({:ok, %{}}, CodexPooler.JSON.decode(data))
    else
      false
    end
  end

  # A structurally complete buffer must assemble into a JSON object, and an
  # object closes with "}". While the buffer's trailing line is a data or
  # payload line still mid-object, the O(buffer) field assembly and JSON
  # decode cannot succeed, so both are skipped. The backward scan is bounded:
  # a trailing line longer than the window can only be a payload line (labels
  # and comments are short), so requiring the "}" tail there stays exact for
  # object decoding. A short trailing non-data line always attempts the
  # decode, because earlier data lines may already assemble a complete object.
  @decode_gate_window 1_024
  defp maybe_decodable_tail?(buffer) do
    window_start = max(byte_size(buffer) - @decode_gate_window, 0)
    window = binary_part(buffer, window_start, byte_size(buffer) - window_start)

    case window |> String.split("\n") |> List.last() do
      ^window when window_start > 0 ->
        String.ends_with?(String.trim_trailing(window), "}")

      line ->
        not String.starts_with?(line, "data:") or
          String.ends_with?(String.trim_trailing(line), "}")
    end
  end

  defp public_types_agree?(event_type, data_type)
       when is_binary(event_type) and event_type != "" and is_binary(data_type) and
              data_type != "",
       do: event_type == data_type

  defp public_types_agree?(_event_type, _data_type), do: true

  defp terminal_event?(type)
       when type in [
              "response.completed",
              "response.done",
              "response.failed",
              "response.incomplete",
              "error"
            ],
       do: true

  defp terminal_event?(_type), do: false

  # The public Responses stream vocabulary is `response.*` plus the `error`
  # terminal (handled with the terminals) and `keepalive`. Every other type is
  # backend-internal (`codex.*` controls, the websocket transport's
  # `responsesapi.websocket_timing`) and is dropped before it takes a sequence
  # number: openai-node's `responses.stream()` throws `Unhandled response
  # stream event` on any type outside its vocabulary (findings#225). Unknown
  # `response.*` types stay relayed so new public events keep flowing.
  # The public websocket relay shares it (findings#254 row 254-14).
  @doc false
  @spec public_stream_event?(term()) :: boolean()
  def public_stream_event?("response." <> _rest), do: true
  def public_stream_event?("keepalive"), do: true
  def public_stream_event?(_type), do: false

  defp stream_block_event(block) do
    data = StreamProtocol.sse_field(block, "data")

    decoded =
      if is_binary(data),
        do: StreamProtocol.decode_sse_data(data),
        else: StreamProtocol.decode_sse_data(block)

    event_type =
      block
      |> StreamProtocol.sse_field("event")
      |> StreamProtocol.normalize_sse_event_label()

    {event_type, decoded}
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp nested_string(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:cont, value}
        _other -> {:halt, nil}
      end
    end)
    |> case do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
