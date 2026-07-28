defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
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
          required(:created?) => boolean(),
          required(:text_delta?) => boolean(),
          required(:terminal_kind) => atom() | nil,
          required(:terminal_failure) => StreamProtocol.terminal_failure() | nil,
          required(:sequence) => PublicResponsesSequence.state(),
          required(:summary) => summary_state(),
          required(:passthrough?) => boolean(),
          required(:passthrough_terminal) => nil,
          required(:passthrough_terminal_kind) => atom() | nil,
          required(:passthrough_terminal_failure) => StreamProtocol.terminal_failure() | nil,
          required(:passthrough_terminal_seen?) => boolean()
        }

  @spec new_state() :: state()
  def new_state do
    %{
      buffer: "",
      created?: false,
      text_delta?: false,
      terminal_kind: nil,
      terminal_failure: nil,
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
    case Jason.decode(data) do
      {:ok, %{"type" => "response.failed"} = decoded} ->
        "response.failed"
        |> normalize_terminal_errors(decoded)
        |> Jason.encode!()

      {:ok, %{} = decoded} ->
        canonical_data = canonicalize_public_json_message(decoded, data)

        case Jason.decode(canonical_data) do
          {:ok, %{} = canonical} -> normalize_public_json_message(canonical, canonical_data)
          _invalid -> data
        end

      _invalid ->
        data
    end
  end

  defp normalize_data_chunk(data, %{passthrough?: true} = state) do
    normalize_passthrough_data(data, state)
  end

  defp normalize_data_chunk(data, state) do
    buffered_data = state.buffer <> data
    {blocks, buffer} = StreamProtocol.complete_sse_blocks(buffered_data, bounded?: false)

    cond do
      structurally_complete_terminal_buffer?(buffer) ->
        normalize_blocks(blocks ++ [buffer], "", state)

      terminal_buffer_candidate?(buffer) and
          StreamProtocol.oversized_incomplete_sse_block?(buffer) ->
        record_oversized_incomplete(byte_size(buffered_data))
        {"", %{state | buffer: buffer}}

      blocks == [] and StreamProtocol.oversized_incomplete_sse_block?(buffer) ->
        record_oversized_incomplete(byte_size(buffered_data))
        {buffered_data, enter_passthrough(buffered_data, state)}

      StreamProtocol.oversized_incomplete_sse_block?(buffer) ->
        record_oversized_incomplete(byte_size(buffered_data))
        {iodata, state} = normalize_complete_blocks(blocks, state)
        {[iodata, buffer] |> IO.iodata_to_binary(), enter_passthrough(buffer, state)}

      true ->
        normalize_blocks(blocks, buffer, state)
    end
  end

  defp normalize_passthrough_data(data, state) do
    case sse_block_separator(data) do
      {index, separator_size} ->
        passthrough_size = index + separator_size
        passthrough = binary_part(data, 0, passthrough_size)
        rest = binary_part(data, passthrough_size, byte_size(data) - passthrough_size)

        state =
          %{state | passthrough?: false, buffer: "", passthrough_terminal: nil}

        {normalized_rest, state} = normalize_data_chunk(rest, state)

        {[passthrough, normalized_rest] |> IO.iodata_to_binary(), state}

      nil ->
        {data, state}
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

  defp enter_passthrough(_data, state) do
    state
    |> then(&%{&1 | buffer: "", passthrough?: true, passthrough_terminal: nil})
    |> mark_passthrough_seen()
  end

  defp record_oversized_incomplete(bytes) do
    BufferTelemetry.record_oversized_incomplete(
      "public_openai_responses_sse",
      bytes,
      StreamProtocol.max_incomplete_sse_block_bytes()
    )
  end

  defp normalize_complete_blocks(blocks, state) do
    Enum.map_reduce(blocks, state, fn block, stream_state ->
      normalize_block(block, stream_state)
    end)
  end

  defp normalize_blocks(blocks, buffer, state) do
    {iodata, state} = normalize_complete_blocks(blocks, %{state | buffer: buffer})

    state = if stream_terminal?(blocks), do: reset_parser_after_terminal(state), else: state

    {IO.iodata_to_binary(iodata), state}
  end

  defp normalize_block("data: [DONE]", state) do
    state =
      state
      |> Map.update!(:sequence, &%{&1 | terminal_latched?: true})
      |> Map.put(:terminal_kind, :completed)
      |> Map.put(:terminal_failure, nil)
      |> put_summary_terminal(:completed, "completed")

    {[], state}
  end

  defp normalize_block(block, state) do
    {event_type, decoded} = stream_block_event(block)
    source_type = effective_source_public_type(event_type, decoded)
    source_terminal_outcome = source_terminal_outcome(source_type, decoded)
    decoded = normalize_matching_terminal_errors(event_type, decoded)

    case PublicResponsesSequence.public_shape(event_type, decoded) do
      {:ok, type, decoded} ->
        decoded = normalize_public_event(type, decoded)

        if type in ["response.completed", "response.failed", "response.incomplete", "error"] do
          normalize_public_terminal_block(type, decoded, source_terminal_outcome, state)
        else
          normalize_public_block(type, decoded, state)
        end

      :drop ->
        {[], state}
    end
  end

  defp effective_source_public_type(event_type, %{} = decoded) do
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

  defp normalize_public_block("response.output_item.done", decoded, state) do
    {block, state, emitted?} = emit_public_sse("response.output_item.done", decoded, state)
    {block, if(emitted?, do: record_item_done(state), else: state)}
  end

  defp normalize_public_block(type, decoded, state) when is_binary(type) do
    if codex_public_event?(type) do
      {[], state}
    else
      {block, state, emitted?} = emit_public_sse(type, decoded, state)
      {block, if(emitted?, do: record_visible(state, type, decoded), else: state)}
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

  defp terminal_prefix(_type, decoded, state) do
    {created_prefix, state} =
      if state.created? do
        {[], state}
      else
        response_id =
          nested_string(decoded, ["response", "id"]) || decoded_string(decoded, "id") || ""

        created = %{
          "type" => "response.created",
          "response" => %{"id" => response_id, "object" => "response", "status" => "in_progress"}
        }

        {block, state, emitted?} = emit_public_sse("response.created", created, state)
        {block, if(emitted?, do: record_created(state), else: state)}
      end

    {delta_prefix, state} =
      if state.text_delta? do
        {[], state}
      else
        case terminal_output_text(decoded) do
          "" ->
            {[], state}

          text ->
            delta = %{"type" => "response.output_text.delta", "delta" => text}

            {block, state, emitted?} =
              emit_public_sse("response.output_text.delta", delta, state)

            {block, if(emitted?, do: record_delta(state, delta), else: state)}
        end
      end

    {[created_prefix, delta_prefix], state}
  end

  defp public_sse_block(event_type, decoded) when is_binary(event_type) and is_map(decoded) do
    [
      "event: ",
      event_type,
      "\n",
      "data: ",
      Jason.encode!(Map.put_new(decoded, "type", event_type)),
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

  defp terminal_output_text(decoded) do
    response = if is_map(decoded["response"]), do: decoded["response"], else: decoded

    response
    |> Map.get("output", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"content" => content} -> List.wrap(content)
      %{"text" => text} when is_binary(text) -> [%{"text" => text}]
      _item -> []
    end)
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _content -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
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

  @spec normalize_terminal_errors(String.t() | nil, map()) :: map()
  def normalize_terminal_errors("response.failed", %{} = decoded) do
    response =
      case Map.get(decoded, "response") do
        %{} = response -> response
        _value -> %{}
      end

    event = %{
      "type" => "response.failed",
      "response" => project_failed_response(response)
    }

    event =
      case Map.fetch(decoded, "sequence_number") do
        {:ok, sequence_number} -> Map.put(event, "sequence_number", sequence_number)
        :error -> event
      end

    maybe_put_failed_top_level_error(event, decoded)
  end

  def normalize_terminal_errors(type, %{} = decoded)
      when type in ["response.completed", "response.incomplete", "error"] do
    decoded
    |> normalize_top_level_error()
    |> normalize_response_error()
  end

  def normalize_terminal_errors(_type, %{} = decoded), do: decoded

  defp canonicalize_public_json_message(decoded, data) do
    prepared = suppress_incomplete_provider_error_types(decoded)
    canonical_input = if prepared == decoded, do: data, else: Jason.encode!(prepared)
    StreamProtocol.canonicalize_codex_responses_json_message(canonical_input)
  end

  defp normalize_public_json_message(%{} = decoded, canonical_data) do
    type = clean_string(Map.get(decoded, "type"))
    normalized = normalize_terminal_errors(type, decoded)

    if normalized == decoded, do: canonical_data, else: Jason.encode!(normalized)
  end

  defp suppress_incomplete_provider_error_types(%{"type" => "response.incomplete"} = decoded) do
    decoded
    |> drop_type_without_code(["error"])
    |> drop_type_without_code(["response", "error"])
  end

  defp suppress_incomplete_provider_error_types(decoded), do: decoded

  defp drop_type_without_code(decoded, path) do
    case get_in(decoded, path) do
      %{"type" => _type, "code" => code} when is_binary(code) ->
        decoded

      %{"type" => _type} = error ->
        put_in(decoded, path, Map.delete(error, "type"))

      _error ->
        decoded
    end
  end

  defp normalize_matching_terminal_errors(event_type, decoded) do
    if public_types_agree?(event_type, clean_string(Map.get(decoded, "type"))) do
      decoded = suppress_incomplete_provider_error_types(decoded)
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

  defp normalize_top_level_error(%{"error" => error} = decoded),
    do: Map.put(decoded, "error", normalize_terminal_error(error))

  defp normalize_top_level_error(decoded), do: decoded

  defp normalize_response_error(%{"response" => %{"error" => error} = response} = decoded) do
    Map.put(
      decoded,
      "response",
      Map.put(response, "error", normalize_terminal_error(error))
    )
  end

  defp normalize_response_error(
         %{"error" => %{} = public_error, "response" => %{} = response} = decoded
       ) do
    Map.put(decoded, "response", Map.put(response, "error", public_error))
  end

  defp normalize_response_error(decoded), do: decoded

  defp normalize_terminal_error(%{} = error) do
    PublicResponse.normalize_error(error, status: PublicResponse.terminal_error_status(error))
  end

  defp normalize_terminal_error(error), do: PublicResponse.normalize_error(error, status: 502)

  defp project_failed_response(response) do
    %{
      "id" => safe_failed_response_id(Map.get(response, "id")),
      "created_at" => 0,
      "status" => "failed",
      "error" => normalize_terminal_error(Map.get(response, "error")),
      "incomplete_details" =>
        project_failed_incomplete_details(Map.get(response, "incomplete_details")),
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
        "cache_write_tokens" =>
          bounded_usage_integer(Map.get(input_details, "cache_write_tokens")),
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

  defp maybe_put_failed_top_level_error(event, source) do
    case Map.fetch(source, "error") do
      {:ok, error} -> Map.put(event, "error", normalize_terminal_error(error))
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

  defp mark_passthrough_seen(state) do
    state
    |> put_summary(:mode, "passthrough")
    |> put_summary(:passthrough_seen, true)
  end

  defp reset_parser_after_terminal(state) do
    %{
      state
      | buffer: "",
        created?: false,
        text_delta?: false,
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

  @spec structurally_complete_terminal_buffer?(binary()) :: boolean()
  defp structurally_complete_terminal_buffer?(""), do: false

  defp structurally_complete_terminal_buffer?(buffer) when is_binary(buffer) do
    if terminal_buffer_candidate?(buffer) do
      done_marker?(buffer) or decoded_sse_buffer?(buffer)
    else
      false
    end
  end

  @spec terminal_buffer_candidate?(binary()) :: boolean()
  defp terminal_buffer_candidate?(buffer) do
    Enum.any?(@terminal_buffer_markers, &String.contains?(buffer, &1))
  end

  @spec done_marker?(binary()) :: boolean()
  defp done_marker?(block), do: String.trim(block) == "data: [DONE]"

  @spec decoded_sse_buffer?(binary()) :: boolean()
  defp decoded_sse_buffer?(buffer) do
    data = StreamProtocol.sse_field(buffer, "data") || buffer

    match?({:ok, %{}}, Jason.decode(data))
  end

  defp stream_terminal?(blocks) do
    Enum.any?(blocks, fn block ->
      {event_type, decoded} = stream_block_event(block)
      data_type = clean_string(Map.get(decoded, "type"))

      done_marker?(block) or
        (public_types_agree?(event_type, data_type) and
           match?(
             {:ok, _outcome},
             StreamProtocol.terminal_outcome(
               event_type,
               normalize_terminal_errors(event_type || data_type, decoded)
             )
           ))
    end)
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

  defp codex_public_event?(type) when is_binary(type), do: String.starts_with?(type, "codex.")

  defp sse_block_separator(data) do
    ["\n\n", "\r\n\r\n"]
    |> Enum.map(fn separator -> {separator, :binary.match(data, separator)} end)
    |> Enum.flat_map(fn
      {separator, {index, _size}} -> [{index, byte_size(separator)}]
      {_separator, :nomatch} -> []
    end)
    |> Enum.min_by(fn {index, _size} -> index end, fn -> nil end)
  end

  defp stream_block_event(block) do
    data = StreamProtocol.sse_field(block, "data")

    decoded =
      if is_binary(data),
        do: StreamProtocol.decode_sse_data(data),
        else: StreamProtocol.decode_sse_data(block)

    event_type = StreamProtocol.sse_field(block, "event")

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
