defmodule CodexPooler.Gateway.OpenAICompatibility.Chat.TextParts do
  @moduledoc false

  import Bitwise, only: [band: 2]

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @maximum_text_bytes 10_485_760
  @chunk_bytes 262_144
  @type result :: {:ok, map()} | {:error, Error.reason()}

  @spec normalize(map(), map()) :: result()
  def normalize(payload, %{"messages" => [_message | _rest]}) do
    with {:ok, input} <- normalize_items(Map.get(payload, "input", [])) do
      normalize_instructions(Map.put(payload, "input", input))
    end
  end

  def normalize(payload, _chat_payload), do: {:ok, payload}

  defp normalize_items(items) when is_list(items) do
    map_result(items, &normalize_item/1)
  end

  defp normalize_items(items), do: {:ok, items}

  defp normalize_item(%{"type" => "message", "content" => parts} = item) when is_list(parts) do
    with {:ok, parts} <- normalize_parts(parts), do: {:ok, Map.put(item, "content", parts)}
  end

  defp normalize_item(%{"type" => type, "output" => output} = item) when type in ["function_call_output", "custom_tool_call_output"] do
    with {:ok, output} <- normalize_tool_output(output), do: {:ok, Map.put(item, "output", output)}
  end

  defp normalize_item(item), do: {:ok, item}

  defp normalize_tool_output(output) when is_list(output), do: normalize_parts(output)

  defp normalize_tool_output(output) when is_binary(output) and byte_size(output) > @maximum_text_bytes,
    do: split_part(%{"type" => "input_text", "text" => output})

  defp normalize_tool_output(output), do: {:ok, output}

  defp normalize_parts(parts) do
    with {:ok, groups} <- map_result(parts, &split_part/1), do: {:ok, Enum.concat(groups)}
  end

  defp split_part(%{"type" => type, "text" => text} = part)
       when type in ["input_text", "output_text"] and is_binary(text) and byte_size(text) > @maximum_text_bytes do
    cond do
      not String.valid?(text) ->
        {:error, Error.invalid_request("oversized text must be valid UTF-8", "messages")}

      Enum.any?(~w(annotations logprobs), &(Map.get(part, &1) not in [nil, []])) ->
        {:error, Error.invalid_request("oversized annotated text cannot be split losslessly", "messages")}

      true ->
        {:ok, replace_text_parts(part, split_utf8(text, []))}
    end
  end

  defp split_part(part), do: {:ok, [part]}

  defp replace_text_parts(part, chunks) do
    last = length(chunks) - 1

    Enum.with_index(chunks, fn chunk, index ->
      replacement = Map.put(part, "text", chunk)
      if index == last, do: replacement, else: Map.delete(replacement, "prompt_cache_breakpoint")
    end)
  end

  defp normalize_instructions(%{"instructions" => text} = payload)
       when is_binary(text) and byte_size(text) > @maximum_text_bytes do
    with {:ok, parts} <- split_part(%{"type" => "input_text", "text" => text}) do
      instruction = %{"type" => "message", "role" => "developer", "content" => parts}
      {:ok, payload |> Map.put("instructions", "") |> Map.update!("input", &[instruction | &1])}
    end
  end

  defp normalize_instructions(payload), do: {:ok, payload}

  defp split_utf8(text, chunks) when byte_size(text) <= @chunk_bytes, do: Enum.reverse([text | chunks])

  defp split_utf8(text, chunks) do
    boundary = utf8_boundary(text, @chunk_bytes)
    <<chunk::binary-size(^boundary), rest::binary>> = text
    split_utf8(rest, [chunk | chunks])
  end

  defp utf8_boundary(text, boundary) do
    if band(:binary.at(text, boundary), 0xC0) == 0x80,
      do: utf8_boundary(text, boundary - 1),
      else: boundary
  end

  defp map_result(items, mapper) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, result} ->
      case mapper.(item) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | result]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end
  end
end
