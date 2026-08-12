defmodule CodexPooler.Gateway.Facade.Anthropic.TokenCount do
  @moduledoc """
  Bounded local token estimate for Anthropic Messages requests.

  The public result intentionally exposes only the aggregate input count. The
  tokenizer/model choice and framing details remain implementation data.
  """

  alias CodexPooler.Gateway.Facade.Anthropic.Messages
  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @target_model "gpt-5.6-sol"
  @max_segments 50_000
  @max_total_segment_bytes 8 * 1_024 * 1_024
  @fixed_final_overhead 3

  @type count_result ::
          {:ok, %{required(String.t()) => non_neg_integer()}} | {:error, Error.reason()}

  @spec count(term()) :: count_result()
  def count(payload) do
    with {:ok, %{canonical: canonical}} <- Messages.normalize_for_count(payload),
         {:ok, segments} <- segments(canonical),
         {:ok, count} <- count_segments(segments) do
      {:ok, %{"input_tokens" => count + @fixed_final_overhead}}
    end
  end

  defp segments(canonical) do
    with {:ok, input_segments} <- input_segments(Map.get(canonical, "input", [])),
         {:ok, tool_segments} <- tool_segments(Map.get(canonical, "tools")),
         segments <-
           ["<anthropic_messages>"] ++
             input_segments ++
             tool_segments ++
             optional_control_segments(canonical) ++ ["</anthropic_messages>"],
         :ok <- validate_segment_bounds(segments) do
      {:ok, segments}
    end
  end

  defp input_segments(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, segments} ->
      case item_segments(item, index) do
        {:ok, item_segments} -> {:cont, {:ok, Enum.reverse(item_segments, segments)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp input_segments(_items), do: unrepresentable("messages")

  defp item_segments(%{"type" => "message", "role" => role, "content" => content}, index)
       when is_binary(role) and is_list(content) do
    with {:ok, content_segments} <- content_segments(content, "messages") do
      {:ok,
       ["<message role=#{role} index=#{index}>"] ++
         content_segments ++ ["</message>"]}
    end
  end

  defp item_segments(
         %{
           "type" => "function_call",
           "call_id" => call_id,
           "name" => name,
           "arguments" => arguments
         },
         _index
       )
       when is_binary(call_id) and is_binary(name) and is_binary(arguments) do
    {:ok,
     [
       "<tool_use id=#{call_id} name=#{name}>",
       arguments,
       "</tool_use>"
     ]}
  end

  defp item_segments(
         %{"type" => "function_call_output", "call_id" => call_id, "output" => output},
         _index
       )
       when is_binary(call_id) do
    with {:ok, output_segments} <- tool_output_segments(output) do
      {:ok,
       ["<tool_result tool_use_id=#{call_id}>"] ++
         output_segments ++ ["</tool_result>"]}
    end
  end

  defp item_segments(_item, _index), do: unrepresentable("messages")

  defp content_segments(content, param) do
    content
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {part, index}, {:ok, segments} ->
      case content_part_segment(part, index, param) do
        {:ok, segment} -> {:cont, {:ok, [segment | segments]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_part_segment(%{"type" => type, "text" => text}, index, _param)
       when type in ["input_text", "output_text"] and is_binary(text) do
    {:ok, "<block type=#{type} index=#{index}>#{text}</block>"}
  end

  defp content_part_segment(%{"type" => "input_image", "image_url" => image_url}, index, _param)
       when is_binary(image_url) do
    with {:ok, media_type} <- image_media_type(image_url) do
      {:ok, "<block type=input_image index=#{index}>[image:#{media_type}]</block>"}
    end
  end

  defp content_part_segment(_part, _index, param), do: unrepresentable(param)

  defp image_media_type("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [media_type, _encoded] when media_type in ~w(image/gif image/jpeg image/png image/webp) ->
        {:ok, media_type}

      _parts ->
        unrepresentable("messages")
    end
  end

  defp image_media_type(_image_url), do: unrepresentable("messages")

  defp tool_output_segments(output) when is_binary(output), do: {:ok, [output]}

  defp tool_output_segments(output) when is_list(output),
    do: content_segments(output, "messages")

  defp tool_output_segments(output) do
    case stable_json(output) do
      {:ok, encoded} -> {:ok, [encoded]}
      {:error, _reason} -> unrepresentable("messages")
    end
  end

  defp tool_segments(nil), do: {:ok, []}

  defp tool_segments(tools) when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool, index}, {:ok, segments} ->
      case stable_json(tool) do
        {:ok, encoded} ->
          {:cont,
           {:ok, ["</tool_definition>", encoded, "<tool_definition index=#{index}>" | segments]}}

        {:error, _reason} ->
          {:halt, unrepresentable("tools")}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_segments(_tools), do: unrepresentable("tools")

  defp optional_control_segments(canonical) do
    []
    |> maybe_append_control("tool_choice", Map.get(canonical, "tool_choice"))
    |> maybe_append_control("parallel_tool_calls", Map.get(canonical, "parallel_tool_calls"))
    |> maybe_append_control("thinking", Map.has_key?(canonical, "reasoning"))
  end

  defp maybe_append_control(segments, _name, nil), do: segments

  defp maybe_append_control(segments, name, value) do
    case stable_json(value) do
      {:ok, encoded} -> segments ++ ["<control name=#{name}>#{encoded}</control>"]
      {:error, _reason} -> segments
    end
  end

  defp validate_segment_bounds(segments) do
    cond do
      length(segments) > @max_segments ->
        unrepresentable("messages")

      Enum.any?(segments, &(not is_binary(&1))) ->
        unrepresentable("messages")

      Enum.reduce_while(segments, 0, fn segment, total ->
        total = total + byte_size(segment)
        if total > @max_total_segment_bytes, do: {:halt, :too_large}, else: {:cont, total}
      end) == :too_large ->
        unrepresentable("messages")

      true ->
        :ok
    end
  end

  defp count_segments(segments) do
    Enum.reduce_while(segments, {:ok, 0}, fn segment, {:ok, total} ->
      case TokenCounter.count(@target_model, segment) do
        {:ok, count, _private_metadata} -> {:cont, {:ok, total + count}}
        {:error, _reason} -> {:halt, unrepresentable(segment_param(segment))}
      end
    end)
  end

  defp segment_param("<tool_definition" <> _rest), do: "tools"
  defp segment_param(_segment), do: "messages"

  defp stable_json(value), do: Jason.encode(value)

  defp unrepresentable(param) do
    {:error,
     Error.invalid_request(
       "request cannot be represented by the bounded local token counter",
       param
     )}
  end
end
