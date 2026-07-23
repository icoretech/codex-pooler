defmodule CodexPooler.Gateway.OpenAICompatibility.ChatCompletions do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @spec normalize_response(map(), map()) :: map()
  def normalize_response(decoded, chat_payload) when is_map(decoded) do
    message = %{"role" => "assistant", "content" => output_text(decoded)}
    message = put_if_present(message, "tool_calls", output_tool_calls(decoded))

    %{
      "id" => response_id(decoded),
      "object" => "chat.completion",
      "created" => created(decoded),
      "model" => model(decoded, chat_payload),
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => finish_reason(decoded)
        }
      ]
    }
    |> put_if_present("usage", usage(decoded))
  end

  @type stream_state :: %{
          required(:buffer) => binary(),
          required(:id) => String.t(),
          required(:created) => integer(),
          required(:model) => String.t() | nil,
          required(:role_sent?) => boolean(),
          required(:visible_seen?) => boolean(),
          required(:terminal_seen?) => boolean(),
          required(:include_usage?) => boolean(),
          required(:discarding_oversized?) => boolean()
        }

  @max_incomplete_chat_sse_block_bytes 1_048_576

  @spec stream_state(map()) :: stream_state()
  def stream_state(chat_payload), do: initial_state(chat_payload)

  @spec visible_seen?(stream_state()) :: boolean()
  def visible_seen?(%{visible_seen?: visible_seen?}) when is_boolean(visible_seen?),
    do: visible_seen?

  def visible_seen?(_state), do: false

  @spec terminal_seen?(stream_state()) :: boolean()
  def terminal_seen?(%{terminal_seen?: terminal_seen?}) when is_boolean(terminal_seen?),
    do: terminal_seen?

  def terminal_seen?(_state), do: false

  @spec normalize_stream_data(binary(), stream_state()) :: {binary(), stream_state()}
  def normalize_stream_data(data, %{discarding_oversized?: true} = state) when is_binary(data) do
    discard_oversized_data(data, state)
  end

  def normalize_stream_data(data, state) when is_binary(data) and is_map(state) do
    buffered_data = state.buffer <> data
    {blocks, buffer} = StreamProtocol.complete_sse_blocks(buffered_data, bounded?: false)

    if oversized_incomplete_sse_block?(buffer) do
      BufferTelemetry.record_oversized_incomplete(
        "public_openai_chat_sse",
        byte_size(buffered_data),
        @max_incomplete_chat_sse_block_bytes
      )

      {iodata, state} = normalize_complete_blocks(blocks, %{state | buffer: ""})
      {oversized_iodata, state} = oversized_incomplete_prefix_chunk(buffer, state)

      {
        [iodata, oversized_iodata] |> IO.iodata_to_binary(),
        %{state | buffer: "", discarding_oversized?: true}
      }
    else
      normalize_stream_blocks(blocks, buffer, state)
    end
  end

  def normalize_stream_data(data, state), do: {data, state}

  defp discard_oversized_data(data, state) do
    case sse_block_separator(data) do
      {index, separator_size} ->
        discard_size = index + separator_size
        rest = binary_part(data, discard_size, byte_size(data) - discard_size)

        state = %{state | discarding_oversized?: false, buffer: ""}
        {normalized_rest, state} = normalize_stream_data(rest, state)

        {normalized_rest, state}

      nil ->
        {"", state}
    end
  end

  defp normalize_stream_blocks(blocks, buffer, state) do
    {iodata, state} = normalize_complete_blocks(blocks, %{state | buffer: buffer})

    state = if terminal_blocks?(blocks), do: %{state | buffer: ""}, else: state

    {IO.iodata_to_binary(iodata), state}
  end

  defp normalize_complete_blocks(blocks, state) do
    Enum.map_reduce(blocks, state, fn block, stream_state ->
      normalize_stream_block(block, stream_state)
    end)
  end

  defp normalize_stream_block("data: [DONE]", state), do: {[], state}

  defp normalize_stream_block(block, state) do
    event_type = StreamProtocol.sse_field(block, "event")
    decoded = block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
    type = event_type || decoded_string(decoded, "type")

    normalize_stream_event(type, decoded, state)
  end

  defp normalize_stream_event("response.created", decoded, state) do
    state
    |> sync_response_state(decoded)
    |> maybe_role_chunk()
  end

  defp normalize_stream_event("response.output_text.delta", decoded, state) do
    state = sync_response_state(state, decoded)
    text_delta_chunk(decoded_string(decoded, "delta") || "", state)
  end

  defp normalize_stream_event("response.output_item.added", decoded, state) do
    state = sync_response_state(state, decoded)
    tool_call_item_chunk(decoded["item"], decoded, state)
  end

  defp normalize_stream_event("response.output_item.done", decoded, state) do
    {[], sync_response_state(state, decoded)}
  end

  defp normalize_stream_event("response.function_call_arguments.delta", decoded, state) do
    state = sync_response_state(state, decoded)
    tool_call_arguments_chunk(decoded, state)
  end

  defp normalize_stream_event(type, decoded, state) when is_binary(type) do
    cond do
      codex_event?(type) ->
        {[], state}

      terminal_event?(type) ->
        {data, state} = terminal_stream_chunk(type, decoded, state)
        {data, %{state | terminal_seen?: true}}

      moderation = moderation_metadata(decoded) ->
        moderation_stream_chunk(moderation, sync_response_state(state, decoded))

      true ->
        {[], state}
    end
  end

  defp normalize_stream_event(_type, _decoded, state), do: {[], state}

  defp oversized_incomplete_sse_block?(buffer),
    do: byte_size(buffer) > @max_incomplete_chat_sse_block_bytes

  defp oversized_incomplete_prefix_chunk(buffer, state) do
    if response_created_prefix?(buffer) do
      maybe_role_chunk(state)
    else
      {[], state}
    end
  end

  defp response_created_prefix?(buffer) do
    String.starts_with?(buffer, "event: response.created\n") or
      String.starts_with?(buffer, "event: response.created\r\n") or
      String.contains?(buffer, "\"type\":\"response.created\"") or
      String.contains?(buffer, "\"type\": \"response.created\"")
  end

  defp maybe_role_chunk(%{role_sent?: true} = state), do: {[], state}

  defp maybe_role_chunk(state) do
    state = %{state | role_sent?: true}
    {chat_sse_chunk(%{"role" => "assistant"}, nil, state), mark_visible(state)}
  end

  defp text_delta_chunk("", state), do: {[], state}

  defp text_delta_chunk(delta, %{role_sent?: false} = state) do
    {prefix, state} = maybe_role_chunk(state)
    {[prefix, chat_sse_chunk(%{"content" => delta}, nil, state)], mark_visible(state)}
  end

  defp text_delta_chunk(delta, state),
    do: {chat_sse_chunk(%{"content" => delta}, nil, state), mark_visible(state)}

  defp tool_call_item_chunk(%{"type" => "function_call"} = item, context, state) do
    index = tool_call_index(item, context)

    delta = %{
      "tool_calls" => [
        %{
          "index" => index,
          "id" => tool_call_id(item, context, index),
          "type" => "function",
          "function" => %{
            "name" => decoded_string(item, "name") || "tool",
            "arguments" => decoded_string(item, "arguments") || ""
          }
        }
      ]
    }

    {chat_sse_chunk(delta, nil, state), mark_visible(state)}
  end

  defp tool_call_item_chunk(_item, _context, state), do: {[], state}

  defp tool_call_arguments_chunk(decoded, state) do
    index = Map.get(decoded, "output_index") || 0

    delta = %{
      "tool_calls" => [
        %{
          "index" => index,
          "function" => %{"arguments" => decoded_string(decoded, "delta") || ""}
        }
      ]
    }

    {chat_sse_chunk(delta, nil, state), mark_visible(state)}
  end

  defp terminal_stream_chunk(type, decoded, %{role_sent?: false} = state)
       when type in ["response.failed", "error"] do
    state = sync_response_state(state, decoded)
    {["data: ", Jason.encode!(%{"error" => public_error(decoded)}), "\n\n"], state}
  end

  defp terminal_stream_chunk(_type, decoded, state), do: terminal_stream_chunk(decoded, state)

  defp terminal_stream_chunk(decoded, %{role_sent?: false} = state) do
    {prefix, state} = maybe_role_chunk(state)
    {[prefix, terminal_stream_chunk(decoded, state) |> elem(0)], state}
  end

  defp terminal_stream_chunk(decoded, state) do
    response = response_map(decoded)
    finish_reason = finish_reason(response)

    {[
       chat_sse_chunk(%{}, finish_reason, state),
       usage_stream_chunk(response, state),
       "data: [DONE]\n\n"
     ], state}
  end

  defp moderation_stream_chunk(moderation, state) do
    payload = %{
      "id" => state.id,
      "object" => "chat.completion.chunk",
      "created" => state.created,
      "model" => state.model,
      "choices" => [],
      "moderation" => moderation
    }

    {["data: ", Jason.encode!(payload), "\n\n"], mark_visible(state)}
  end

  defp chat_sse_chunk(delta, finish_reason, state) do
    payload = %{
      "id" => state.id,
      "object" => "chat.completion.chunk",
      "created" => state.created,
      "model" => state.model,
      "choices" => [
        %{
          "index" => 0,
          "delta" => delta,
          "finish_reason" => finish_reason
        }
      ]
    }

    ["data: ", Jason.encode!(payload), "\n\n"]
  end

  defp initial_state(chat_payload) do
    %{
      buffer: "",
      id: "chatcmpl_" <> Ecto.UUID.generate(),
      created: System.system_time(:second),
      model: Map.get(chat_payload, "model"),
      role_sent?: false,
      visible_seen?: false,
      terminal_seen?: false,
      include_usage?: get_in(chat_payload, ["stream_options", "include_usage"]) == true,
      discarding_oversized?: false
    }
  end

  defp usage_stream_chunk(decoded, %{include_usage?: true} = state) do
    case usage(decoded) do
      usage when is_map(usage) and usage != %{} ->
        payload = %{
          "id" => state.id,
          "object" => "chat.completion.chunk",
          "created" => state.created,
          "model" => state.model,
          "choices" => [],
          "usage" => usage
        }

        ["data: ", Jason.encode!(payload), "\n\n"]

      _usage ->
        []
    end
  end

  defp usage_stream_chunk(_decoded, _state), do: []

  defp mark_visible(state), do: %{state | visible_seen?: true}

  defp sync_response_state(state, decoded) do
    response = response_map(decoded)

    %{
      state
      | id: decoded_string(response, "id") || state.id,
        created: created(response, state.created),
        model: model(response, state)
    }
  end

  defp response_id(decoded),
    do: decoded_string(decoded, "id") || "chatcmpl_" <> Ecto.UUID.generate()

  defp created(decoded, fallback) do
    case decoded do
      %{"created" => created} when is_integer(created) -> created
      %{"created_at" => created} when is_integer(created) -> created
      _decoded -> fallback
    end
  end

  defp created(%{"created" => created}) when is_integer(created), do: created
  defp created(%{"created_at" => created}) when is_integer(created), do: created
  defp created(_decoded), do: System.system_time(:second)

  defp model(decoded, %{"model" => model}) when is_binary(model),
    do: decoded_string(decoded, "model") || model

  defp model(decoded, %{model: model}) when is_binary(model),
    do: decoded_string(decoded, "model") || model

  defp model(decoded, _fallback), do: decoded_string(decoded, "model") || "unknown"

  defp output_text(decoded) do
    decoded
    |> output_items()
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

  defp output_tool_calls(decoded) do
    decoded
    |> output_items()
    |> Enum.filter(&(Map.get(&1, "type") == "function_call"))
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      %{
        "id" => tool_call_id(item),
        "type" => "function",
        "function" => %{
          "name" => decoded_string(item, "name") || "tool",
          "arguments" => decoded_string(item, "arguments") || ""
        },
        "index" => index
      }
    end)
    |> case do
      [] -> nil
      tool_calls -> tool_calls
    end
  end

  defp output_items(decoded) do
    decoded
    |> response_map()
    |> case do
      %{"output" => output} -> List.wrap(output)
      _response -> []
    end
  end

  defp usage(decoded) do
    usage = Map.get(decoded, "usage") || get_in(decoded, ["response", "usage"])

    case usage do
      %{} ->
        prompt_tokens = Map.get(usage, "prompt_tokens") || Map.get(usage, "input_tokens")
        completion_tokens = Map.get(usage, "completion_tokens") || Map.get(usage, "output_tokens")

        %{
          "prompt_tokens" => prompt_tokens,
          "prompt_tokens_details" => Map.get(usage, "prompt_tokens_details"),
          "completion_tokens" => completion_tokens,
          "total_tokens" =>
            Map.get(usage, "total_tokens") || total_tokens(prompt_tokens, completion_tokens)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _usage ->
        nil
    end
  end

  defp total_tokens(prompt_tokens, completion_tokens)
       when is_integer(prompt_tokens) and is_integer(completion_tokens),
       do: prompt_tokens + completion_tokens

  defp total_tokens(_prompt_tokens, _completion_tokens), do: nil

  defp finish_reason(decoded) do
    status = decoded_string(decoded, "status")

    cond do
      status in [nil, "completed", "in_progress"] -> "stop"
      status == "incomplete" -> incomplete_finish_reason(decoded)
      status == "failed" -> "stop"
      true -> "stop"
    end
  end

  defp incomplete_finish_reason(decoded) do
    case incomplete_reason(decoded) do
      reason when reason in ["content_filter", "content-filter"] -> "content_filter"
      _reason -> "length"
    end
  end

  defp incomplete_reason(%{"incomplete_details" => %{} = details}),
    do: decoded_string(details, "reason")

  defp incomplete_reason(_decoded), do: nil

  defp moderation_metadata(%{"moderation" => %{} = moderation}), do: moderation
  defp moderation_metadata(_decoded), do: nil

  defp response_map(%{"response" => %{} = response}), do: response
  defp response_map(%{} = decoded), do: decoded

  defp public_error(decoded) do
    error = response_map(decoded)["error"] || Map.get(decoded, "error") || %{}
    status = PublicResponse.terminal_error_status(error)

    PublicResponse.normalize_error(error, status: status)
  end

  defp tool_call_id(item, context, index) do
    decoded_string(item, "call_id") || decoded_string(item, "id") ||
      decoded_string(context, "item_id") || "call_#{index}"
  end

  defp tool_call_id(item), do: decoded_string(item, "call_id") || decoded_string(item, "id")

  defp tool_call_index(%{"output_index" => index}, _context) when is_integer(index), do: index
  defp tool_call_index(_item, %{"output_index" => index}) when is_integer(index), do: index
  defp tool_call_index(_item, _context), do: 0

  defp terminal_blocks?(blocks) do
    Enum.any?(blocks, fn
      "data: [DONE]" ->
        true

      block ->
        event_type = StreamProtocol.sse_field(block, "event")
        decoded = block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
        terminal_event?(event_type || decoded_string(decoded, "type"))
    end)
  end

  defp terminal_event?(type),
    do: type in ["response.completed", "response.failed", "response.incomplete", "error"]

  defp codex_event?(type) when is_binary(type), do: String.starts_with?(type, "codex.")

  defp sse_block_separator(data) do
    ["\n\n", "\r\n\r\n"]
    |> Enum.map(fn separator -> {separator, :binary.match(data, separator)} end)
    |> Enum.flat_map(fn
      {separator, {index, _size}} -> [{index, byte_size(separator)}]
      {_separator, :nomatch} -> []
    end)
    |> Enum.min_by(fn {index, _size} -> index end, fn -> nil end)
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp decoded_string(_decoded, _key), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
