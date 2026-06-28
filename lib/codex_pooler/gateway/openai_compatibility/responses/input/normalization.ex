defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.Normalization do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.OpenAICompatibility.Responses.Input.InstructionLifter
  alias CodexPooler.Gateway.Payloads.ToolResultShape

  @metadata_passthrough_key "internal_chat_message_metadata_passthrough"

  def normalize_input(%{"input" => input} = payload) when is_binary(input) do
    {:ok, Map.put(payload, "input", [input_text_message(input)])}
  end

  def normalize_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_input_items(input) do
      {:ok,
       payload
       |> Map.put("input", input)
       |> drop_stateless_reasoning_replay()
       |> InstructionLifter.lift()}
    end
  end

  def normalize_input(payload), do: {:ok, payload}

  def normalize_list_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_input_items(input) do
      {:ok, payload |> Map.put("input", input) |> drop_stateless_reasoning_replay()}
    end
  end

  def normalize_list_input(payload), do: {:ok, payload}

  def normalize_recoverable_opencode_replay_call_ids(%{"input" => input} = payload)
      when is_list(input) do
    {:ok, Map.put(payload, "input", normalize_recoverable_opencode_replay_items(input))}
  end

  def normalize_recoverable_opencode_replay_call_ids(payload), do: {:ok, payload}

  defp normalize_recoverable_opencode_replay_items(input) do
    input
    |> do_normalize_recoverable_opencode_replay_items(0, [])
    |> Enum.reverse()
  end

  defp do_normalize_recoverable_opencode_replay_items([call, output | rest], index, acc)
       when is_map(call) and is_map(output) do
    if recoverable_opencode_tool_replay_pair?(call, output) do
      call_id = opencode_replay_call_id(call, index)

      do_normalize_recoverable_opencode_replay_items(
        rest,
        index + 2,
        [Map.put(output, "call_id", call_id), Map.put(call, "call_id", call_id) | acc]
      )
    else
      do_normalize_recoverable_opencode_replay_items([output | rest], index + 1, [call | acc])
    end
  end

  defp do_normalize_recoverable_opencode_replay_items([item | rest], index, acc),
    do: do_normalize_recoverable_opencode_replay_items(rest, index + 1, [item | acc])

  defp do_normalize_recoverable_opencode_replay_items([], _index, acc), do: acc

  defp recoverable_opencode_tool_replay_pair?(call, output) do
    function_call_replay_shape?(call) and function_call_output_replay_shape?(output) and
      blank_call_id?(output) and recoverable_opencode_call_id?(call)
  end

  defp function_call_replay_shape?(%{
         "type" => "function_call",
         "name" => name,
         "arguments" => arguments
       })
       when is_binary(name) and name != "" and is_binary(arguments),
       do: true

  defp function_call_replay_shape?(_item), do: false

  defp function_call_output_replay_shape?(%{"type" => "function_call_output"} = item),
    do: Map.has_key?(item, "output") or Map.has_key?(item, "result")

  defp function_call_output_replay_shape?(_item), do: false

  defp opencode_replay_call_id(call, _index) do
    clean_string(Map.get(call, "call_id")) || clean_string(Map.get(call, "id"))
  end

  defp blank_call_id?(item), do: is_nil(clean_string(Map.get(item, "call_id")))

  defp recoverable_opencode_call_id?(call), do: is_binary(opencode_replay_call_id(call, 0))

  defp drop_stateless_reasoning_replay(%{"input" => input} = payload) when is_list(input) do
    if previous_response_id?(payload) do
      payload
    else
      Map.put(payload, "input", Enum.reject(input, &reasoning_replay_item?/1))
    end
  end

  defp drop_stateless_reasoning_replay(payload), do: payload

  defp previous_response_id?(%{"previous_response_id" => value}) when is_binary(value),
    do: String.trim(value) != ""

  defp previous_response_id?(_payload), do: false

  defp reasoning_replay_item?(%{"type" => "reasoning"}), do: true
  defp reasoning_replay_item?(_item), do: false

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp normalize_input_items(input) do
    Enum.reduce_while(input, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_input_item(item) do
        {:ok, items} when is_list(items) -> {:cont, {:ok, Enum.reverse(items) ++ acc}}
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, input} -> {:ok, Enum.reverse(input)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_input_item(%{"type" => "additional_tools"} = item), do: {:ok, item}

  defp normalize_input_item(%{"role" => "assistant", "tool_calls" => tool_calls} = item)
       when is_list(tool_calls) do
    with {:ok, parent_metadata_passthrough} <- optional_metadata_passthrough(item) do
      normalize_assistant_tool_calls(
        tool_calls,
        Map.get(item, "metadata"),
        parent_metadata_passthrough
      )
    end
  end

  defp normalize_input_item(%{"role" => "tool"} = item) do
    with {:ok, call_id} <- tool_call_id(item),
         {:ok, output} <- tool_output(item),
         {:ok, metadata_passthrough} <- optional_metadata_passthrough(item) do
      {:ok,
       %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
       |> put_optional_metadata(Map.get(item, "metadata"))
       |> put_optional_metadata_passthrough(metadata_passthrough)}
    end
  end

  defp normalize_input_item(%{"type" => "reasoning"} = item) do
    {:ok, Map.drop(item, ["content"])}
  end

  defp normalize_input_item(%{"type" => "function_call", "status" => status} = item)
       when status in ["completed", "incomplete"],
       do: {:ok, Map.delete(item, "status")}

  defp normalize_input_item(%{"type" => "function_call"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "custom_tool_call", "status" => status} = item)
       when status in ["completed", "incomplete"],
       do: {:ok, Map.delete(item, "status")}

  defp normalize_input_item(%{"type" => "custom_tool_call"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "custom_tool_call_output"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "function_call_output"} = item), do: {:ok, item}

  defp normalize_input_item(%{"role" => "assistant", "content" => content} = item)
       when is_binary(content) do
    {:ok,
     item
     |> Map.put("type", "message")
     |> Map.put("content", [%{"type" => "output_text", "text" => content}])}
  end

  defp normalize_input_item(%{"role" => "assistant", "content" => content} = item)
       when is_list(content) do
    with {:ok, content} <- normalize_assistant_replay_content(content) do
      {:ok,
       item
       |> Map.put("type", "message")
       |> Map.put("content", content)}
    end
  end

  defp normalize_input_item(%{"content" => content} = item) when is_binary(content) do
    item =
      item
      |> Map.put("type", "message")
      |> Map.put_new("role", "user")
      |> Map.put("content", [%{"type" => "input_text", "text" => content}])
      |> normalize_message_role()

    {:ok, item}
  end

  defp normalize_input_item(%{"content" => content} = item) when is_list(content) do
    {:ok,
     item |> Map.put("type", "message") |> Map.put_new("role", "user") |> normalize_message_role()}
  end

  defp normalize_input_item(%{"role" => _role} = item),
    do: {:ok, item |> Map.put_new("type", "message") |> normalize_message_role()}

  defp normalize_input_item(%{"type" => "input_file"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "item_reference"} = item), do: {:ok, item}

  defp normalize_input_item(%{} = item) do
    if ToolResultShape.tool_result?(item) do
      {:ok, item}
    else
      {:error, Error.invalid_request("input item shape is not translatable", "input")}
    end
  end

  defp normalize_assistant_tool_calls(tool_calls, parent_metadata, parent_metadata_passthrough) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case normalize_assistant_tool_call(tool_call, parent_metadata, parent_metadata_passthrough) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_assistant_tool_call(
         %{"function" => %{"name" => name, "arguments" => arguments}} = item,
         parent_metadata,
         parent_metadata_passthrough
       )
       when is_binary(name) and is_binary(arguments) do
    with {:ok, metadata_passthrough} <- optional_metadata_passthrough(item) do
      case clean_string(Map.get(item, "call_id")) || clean_string(Map.get(item, "id")) do
        nil ->
          {:error, Error.invalid_request("input item shape is not translatable", "input")}

        call_id ->
          {:ok,
           %{
             "type" => "function_call",
             "call_id" => call_id,
             "name" => name,
             "arguments" => arguments
           }
           |> put_optional_id(Map.get(item, "response_item_id"))
           |> put_optional_metadata(Map.get(item, "metadata") || parent_metadata)
           |> put_optional_metadata_passthrough(
             metadata_passthrough || parent_metadata_passthrough
           )}
      end
    end
  end

  defp normalize_assistant_tool_call(_item, _parent_metadata, _parent_metadata_passthrough),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp normalize_assistant_replay_content(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case normalize_assistant_replay_content_part(part) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, [%{"type" => "output_text", "text" => ""}]}
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_assistant_replay_content_part(%{"type" => "output_text", "text" => text})
       when is_binary(text) do
    {:ok, %{"type" => "output_text", "text" => text}}
  end

  defp normalize_assistant_replay_content_part(%{"type" => "text", "text" => text})
       when is_binary(text) do
    {:ok, %{"type" => "output_text", "text" => text}}
  end

  defp normalize_assistant_replay_content_part(%{"type" => "thinking", "thinking" => thinking})
       when is_binary(thinking) do
    {:ok, nil}
  end

  defp normalize_assistant_replay_content_part(_part),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp put_optional_id(item, value) do
    case clean_string(value) do
      nil -> item
      id -> Map.put(item, "id", id)
    end
  end

  defp put_optional_metadata(item, metadata) when is_map(metadata),
    do: Map.put(item, "metadata", metadata)

  defp put_optional_metadata(item, _metadata), do: item

  defp optional_metadata_passthrough(%{@metadata_passthrough_key => nil}), do: {:ok, nil}

  defp optional_metadata_passthrough(%{@metadata_passthrough_key => metadata})
       when is_map(metadata),
       do: {:ok, metadata}

  defp optional_metadata_passthrough(%{@metadata_passthrough_key => _metadata}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp optional_metadata_passthrough(_item), do: {:ok, nil}

  defp put_optional_metadata_passthrough(item, metadata) when is_map(metadata),
    do: Map.put(item, @metadata_passthrough_key, metadata)

  defp put_optional_metadata_passthrough(item, _metadata), do: item

  defp input_text_message(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp tool_call_id(item) do
    case clean_string(Map.get(item, "tool_call_id")) || clean_string(Map.get(item, "call_id")) do
      nil -> {:error, Error.invalid_request("input item shape is not translatable", "input")}
      call_id -> {:ok, call_id}
    end
  end

  defp tool_output(%{"content" => content}) when is_binary(content), do: {:ok, content}

  defp tool_output(%{"content" => content}) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case normalize_tool_output_part(part) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_output(%{"content" => nil}), do: {:ok, ""}

  defp tool_output(%{"content" => %{"output" => output}}) when is_binary(output),
    do: {:ok, output}

  defp tool_output(%{"content" => _content}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp tool_output(_item), do: {:ok, ""}

  defp normalize_tool_output_part(part) when is_binary(part) do
    {:ok, %{"type" => "input_text", "text" => part}}
  end

  defp normalize_tool_output_part(%{"type" => type, "text" => text})
       when type in ["text", "input_text"] and is_binary(text) do
    {:ok, %{"type" => "input_text", "text" => text}}
  end

  defp normalize_tool_output_part(%{"type" => "input_image", "image_url" => image_url})
       when is_binary(image_url) do
    {:ok, %{"type" => "input_image", "image_url" => image_url}}
  end

  defp normalize_tool_output_part(%{"type" => "image_url"} = part) do
    case Map.get(part, "image_url") do
      %{"url" => image_url} when is_binary(image_url) ->
        {:ok, %{"type" => "input_image", "image_url" => image_url}}

      image_url when is_binary(image_url) ->
        {:ok, %{"type" => "input_image", "image_url" => image_url}}

      _value ->
        {:error, Error.invalid_request("input item shape is not translatable", "input")}
    end
  end

  defp normalize_tool_output_part(_part),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp normalize_message_role(%{"type" => "message", "role" => "system"} = item),
    do: Map.put(item, "role", "developer")

  defp normalize_message_role(item), do: item
end
