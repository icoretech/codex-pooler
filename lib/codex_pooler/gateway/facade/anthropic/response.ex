defmodule CodexPooler.Gateway.Facade.Anthropic.Response do
  @moduledoc """
  Projects a collected canonical Responses result into an Anthropic Message.

  Every identifier and thinking signature is minted locally. Only documented
  Anthropic content, stop, and usage fields cross the public boundary.
  """

  alias CodexPooler.Gateway.Facade

  @zero_usage %{
    "input_tokens" => 0,
    "cache_creation_input_tokens" => 0,
    "cache_read_input_tokens" => 0,
    "output_tokens" => 0
  }

  @spec message(map(), map()) :: map()
  def message(decoded, formatting) when is_map(decoded) and is_map(formatting) do
    {text_limit, stop_sequence} = visible_text_limit(decoded, formatting)
    {content, tool_used?} = content_blocks(decoded, formatting, text_limit)

    %{
      "id" => local_id("msg_"),
      "type" => "message",
      "role" => "assistant",
      "model" => Facade.public_model(),
      "content" => content,
      "stop_reason" => stop_reason(decoded, stop_sequence, tool_used?),
      "stop_sequence" => stop_sequence,
      "usage" => safe_usage(decoded)
    }
  end

  @doc false
  @spec zero_usage() :: map()
  def zero_usage, do: @zero_usage

  @doc false
  @spec safe_usage(map()) :: map()
  def safe_usage(decoded) when is_map(decoded) do
    usage = usage_map(decoded)
    total_input = nonnegative_integer(Map.get(usage, "input_tokens"))

    cached =
      usage
      |> cached_input_tokens()
      |> min(total_input)

    created =
      usage
      |> Map.get("cache_creation_input_tokens")
      |> nonnegative_integer()
      |> min(max(total_input - cached, 0))

    %{
      "input_tokens" => max(total_input - cached - created, 0),
      "cache_creation_input_tokens" => created,
      "cache_read_input_tokens" => cached,
      "output_tokens" => nonnegative_integer(Map.get(usage, "output_tokens"))
    }
  end

  def safe_usage(_decoded), do: @zero_usage

  defp content_blocks(decoded, formatting, text_limit) do
    decoded
    |> output_items()
    |> Enum.reduce({[], 0, false}, fn item, {blocks, consumed_text, tool_used?} ->
      case item do
        %{"type" => "reasoning", "summary" => summary} when is_list(summary) ->
          case thinking_block(summary, formatting) do
            nil -> {blocks, consumed_text, tool_used?}
            block -> {[block | blocks], consumed_text, tool_used?}
          end

        %{"type" => "message", "content" => content} when is_list(content) ->
          {text_blocks, consumed_text} =
            visible_message_blocks(content, consumed_text, text_limit)

          {text_blocks ++ blocks, consumed_text, tool_used?}

        %{"type" => "function_call", "name" => name, "arguments" => arguments}
        when is_binary(name) and is_binary(arguments) ->
          block = %{
            "type" => "tool_use",
            "id" => local_id("toolu_"),
            "name" => safe_tool_name(name),
            "input" => safe_arguments(arguments)
          }

          {[block | blocks], consumed_text, true}

        _item ->
          {blocks, consumed_text, tool_used?}
      end
    end)
    |> then(fn {blocks, _consumed_text, tool_used?} -> {Enum.reverse(blocks), tool_used?} end)
  end

  defp thinking_block(_summary, %{think?: false}), do: nil

  defp thinking_block(summary, _formatting) do
    text =
      summary
      |> Enum.flat_map(fn
        %{"type" => "summary_text", "text" => text} when is_binary(text) -> [text]
        _part -> []
      end)
      |> Enum.join("\n")

    if String.trim(text) == "" do
      nil
    else
      %{
        "type" => "thinking",
        "thinking" => text,
        "signature" => local_id("sig_")
      }
    end
  end

  defp visible_message_blocks(content, consumed_text, text_limit) do
    Enum.reduce(content, {[], consumed_text}, fn
      %{"type" => "output_text", "text" => text}, {blocks, consumed}
      when is_binary(text) ->
        remaining = max(text_limit - consumed, 0)
        visible_bytes = min(byte_size(text), remaining)
        visible = binary_part(text, 0, visible_bytes)

        blocks =
          if visible == "", do: blocks, else: [%{"type" => "text", "text" => visible} | blocks]

        {blocks, consumed + byte_size(text)}

      _part, state ->
        state
    end)
  end

  defp visible_text_limit(decoded, formatting) do
    text =
      decoded
      |> output_items()
      |> Enum.flat_map(fn
        %{"type" => "message", "content" => content} when is_list(content) ->
          Enum.flat_map(content, fn
            %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
            _part -> []
          end)

        _item ->
          []
      end)
      |> IO.iodata_to_binary()

    case earliest_stop(text, Map.get(formatting, :stops, [])) do
      {index, stop} -> {index, stop}
      nil -> {byte_size(text), nil}
    end
  end

  defp stop_reason(_decoded, stop_sequence, _tool_used?) when is_binary(stop_sequence),
    do: "stop_sequence"

  defp stop_reason(_decoded, _stop_sequence, true), do: "tool_use"

  defp stop_reason(decoded, _stop_sequence, false) do
    case decoded do
      %{"incomplete_details" => %{"reason" => reason}}
      when reason in ["max_output_tokens", "max_tokens"] ->
        "max_tokens"

      %{"status" => "incomplete"} ->
        "max_tokens"

      _decoded ->
        "end_turn"
    end
  end

  defp earliest_stop(text, stops) when is_binary(text) and is_list(stops) do
    stops
    |> Enum.flat_map(fn
      stop when is_binary(stop) and stop != "" ->
        case :binary.match(text, stop) do
          {index, _length} -> [{index, stop}]
          :nomatch -> []
        end

      _stop ->
        []
    end)
    |> Enum.min_by(fn {index, stop} -> {index, -byte_size(stop)} end, fn -> nil end)
  end

  defp output_items(%{"output" => output}) when is_list(output), do: output
  defp output_items(_decoded), do: []

  defp usage_map(%{"usage" => %{} = usage}), do: usage
  defp usage_map(%{"response" => %{} = response}), do: usage_map(response)
  defp usage_map(_decoded), do: %{}

  defp cached_input_tokens(%{"input_tokens_details" => %{} = details} = usage) do
    details
    |> Map.get("cached_tokens", Map.get(usage, "cache_read_input_tokens"))
    |> nonnegative_integer()
  end

  defp cached_input_tokens(usage),
    do: usage |> Map.get("cache_read_input_tokens") |> nonnegative_integer()

  defp safe_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{}
    end
  end

  defp safe_tool_name(name) when is_binary(name) do
    name = String.trim(name)

    if name != "" and byte_size(name) <= 256 and String.printable?(name),
      do: name,
      else: "tool"
  end

  defp local_id(prefix),
    do: prefix <> (Ecto.UUID.generate() |> String.replace("-", ""))

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: 0
end
