defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.ToolResultShape

  @input_audio_formats ~w(mp3 wav)

  def normalize_input(%{"input" => input} = payload) when is_binary(input) do
    {:ok, Map.put(payload, "input", [input_text_message(input)])}
  end

  def normalize_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_input_items(input) do
      {:ok, payload |> Map.put("input", input) |> lift_instruction_messages()}
    end
  end

  def normalize_input(payload), do: {:ok, payload}

  def normalize_list_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_input_items(input) do
      {:ok, Map.put(payload, "input", input)}
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

  defp normalize_input_item(%{"role" => "assistant", "tool_calls" => tool_calls})
       when is_list(tool_calls) do
    normalize_assistant_tool_calls(tool_calls)
  end

  defp normalize_input_item(%{"role" => "tool"} = item) do
    with {:ok, call_id} <- tool_call_id(item),
         {:ok, output} <- tool_output(item) do
      {:ok, %{"type" => "function_call_output", "call_id" => call_id, "output" => output}}
    end
  end

  defp normalize_input_item(%{"type" => "reasoning"} = item) do
    {:ok, Map.drop(item, ["content"])}
  end

  defp normalize_input_item(%{"type" => "function_call", "status" => "completed"} = item),
    do: {:ok, Map.delete(item, "status")}

  defp normalize_input_item(%{"type" => "function_call"} = item), do: {:ok, item}

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

  defp normalize_assistant_tool_calls(tool_calls) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case normalize_assistant_tool_call(tool_call) do
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
         %{"function" => %{"name" => name, "arguments" => arguments}} = item
       )
       when is_binary(name) and is_binary(arguments) do
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
         |> put_optional_id(Map.get(item, "response_item_id"))}
    end
  end

  defp normalize_assistant_tool_call(_item),
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

  defp input_text_message(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp lift_instruction_messages(%{"input" => input} = payload) when is_list(input) do
    {input, instruction_texts} =
      Enum.reduce(input, {[], []}, fn item, {items, instruction_texts} ->
        case lift_instruction_item(item) do
          {:ok, texts, nil} ->
            {items, instruction_texts ++ texts}

          {:ok, texts, residual_item} ->
            {[residual_item | items], instruction_texts ++ texts}

          :ignore ->
            {[item | items], instruction_texts}
        end
      end)

    payload
    |> Map.put("input", Enum.reverse(input))
    |> put_lifted_instruction_text(instruction_texts)
  end

  defp lift_instruction_messages(payload), do: payload

  defp lift_instruction_item(%{"type" => "message", "role" => role, "content" => content} = item)
       when role in ["system", "developer"] do
    {texts, preserved_content} = lift_instruction_content(content)

    residual_item =
      case preserved_content do
        [] -> nil
        content -> item |> Map.put("role", "user") |> Map.put("content", content)
      end

    {:ok, texts, residual_item}
  end

  defp lift_instruction_item(_item), do: :ignore

  defp lift_instruction_content(content) when is_binary(content) do
    case clean_string(content) do
      nil -> {[], []}
      text -> {[text], []}
    end
  end

  defp lift_instruction_content(content) when is_list(content) do
    content
    |> Enum.reduce({[], []}, fn part, {texts, preserved_content} ->
      case instruction_content_text(part) do
        {:ok, nil} -> {texts, preserved_content}
        {:ok, text} -> {texts ++ [text], preserved_content}
        :error -> {texts, preserved_content ++ [part]}
      end
    end)
  end

  defp lift_instruction_content(content), do: {[], [content]}

  defp instruction_content_text(%{"type" => type, "text" => text})
       when type in ["input_text", "text"] and is_binary(text) do
    {:ok, clean_string(text)}
  end

  defp instruction_content_text(text) when is_binary(text), do: {:ok, clean_string(text)}
  defp instruction_content_text(_part), do: :error

  defp put_lifted_instruction_text(payload, []), do: payload

  defp put_lifted_instruction_text(payload, instruction_texts) do
    existing_text =
      payload
      |> Map.get("instructions")
      |> clean_string()

    instructions =
      [existing_text | instruction_texts]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if instructions == "" do
      payload
    else
      Map.put(payload, "instructions", instructions)
    end
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

  def validate_input(%{"input" => input}) when is_binary(input), do: :ok

  def validate_input(%{"input" => input} = payload) when is_list(input) and input != [] do
    validate_each(input, &validate_input_item(&1, payload))
  end

  def validate_input(%{"input" => input}) when is_list(input),
    do: {:error, Error.invalid_request("input must be a non-empty string or array", "input")}

  def validate_input(%{"input" => _input}),
    do: {:error, Error.invalid_request("input must be a string or array", "input")}

  def validate_input(_payload), do: :ok

  defp validate_input_item(%{"type" => "additional_tools"} = item, _payload),
    do: validate_additional_tools_item(item)

  defp validate_input_item(%{"role" => "assistant"} = item, _payload),
    do: validate_assistant_replay_item(item)

  defp validate_input_item(%{"type" => "message", "role" => "assistant"} = item, _payload),
    do: validate_assistant_replay_item(item)

  defp validate_input_item(%{"phase" => _phase}, _payload),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_input_item(%{"type" => "reasoning"} = item, _payload),
    do: validate_reasoning_replay_item(item)

  defp validate_input_item(%{"type" => "function_call"} = item, _payload),
    do: validate_function_call_replay_item(item)

  defp validate_input_item(%{"type" => "message"} = item, _payload),
    do: validate_message_item(item)

  defp validate_input_item(%{"role" => _role} = item, _payload), do: validate_message_item(item)

  defp validate_input_item(%{"content" => _content} = item, _payload),
    do: validate_message_item(item)

  defp validate_input_item(%{"type" => "input_file", "file_id" => file_id}, _payload)
       when is_binary(file_id) and file_id != "",
       do: :ok

  defp validate_input_item(%{"type" => "input_file", "file_data" => file_data}, _payload)
       when is_binary(file_data),
       do: :ok

  defp validate_input_item(
         %{"type" => "function_call_output", "call_id" => call_id} = item,
         _payload
       )
       when is_binary(call_id) and call_id != "" do
    validate_function_call_output_item(item)
  end

  defp validate_input_item(%{"type" => "item_reference"} = item, payload),
    do: validate_item_reference(item, payload)

  defp validate_input_item(%{"type" => _type}, _payload),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_input_item(%{} = item, _payload) do
    if ToolResultShape.tool_result?(item),
      do: :ok,
      else: {:error, Error.invalid_request("input item shape is not translatable", "input")}
  end

  defp validate_input_item(_item, _payload),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_additional_tools_item(item) do
    with :ok <- validate_exact_item_keys(item, ["type", "role", "tools", "id"]),
         :ok <- validate_additional_tools_role(Map.get(item, "role")),
         :ok <- validate_additional_tools_tools(Map.get(item, "tools")) do
      validate_optional_id(item)
    end
  end

  defp validate_additional_tools_role("developer"), do: :ok

  defp validate_additional_tools_role(_role),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_additional_tools_tools(tools) when is_list(tools), do: :ok

  defp validate_additional_tools_tools(_tools),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_item_reference(%{"id" => id} = item, payload) when is_binary(id) do
    cond do
      !bare_item_reference?(item) ->
        {:error, Error.invalid_request("input item shape is not translatable", "input")}

      String.trim(id) == "" ->
        {:error, Error.invalid_request("input item shape is not translatable", "input")}

      !previous_response_id?(payload) ->
        {:error, Error.invalid_request("input item shape is not translatable", "input")}

      ToolResultShape.items(Map.get(payload, "input")) == [] ->
        {:error, Error.invalid_request("input item shape is not translatable", "input")}

      true ->
        :ok
    end
  end

  defp validate_item_reference(_item, _payload),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  def validate_previous_response_continuation(%{"previous_response_id" => response_id} = payload)
      when is_binary(response_id) do
    cond do
      String.trim(response_id) == "" ->
        {:error,
         Error.invalid_request(
           "previous_response_id requires a tool-output continuation",
           "previous_response_id"
         )}

      payload |> Map.get("input") |> ToolResultShape.items() |> Enum.empty?() ->
        {:error,
         Error.invalid_request(
           "previous_response_id requires a tool-output continuation",
           "previous_response_id"
         )}

      true ->
        :ok
    end
  end

  def validate_previous_response_continuation(%{"previous_response_id" => _response_id}),
    do:
      {:error,
       Error.invalid_request(
         "previous_response_id requires a tool-output continuation",
         "previous_response_id"
       )}

  def validate_previous_response_continuation(_payload), do: :ok

  defp bare_item_reference?(item),
    do: map_size(item) == 2 and Map.has_key?(item, "id") and Map.has_key?(item, "type")

  defp previous_response_id?(%{"previous_response_id" => value}) when is_binary(value),
    do: String.trim(value) != ""

  defp previous_response_id?(_payload), do: false

  defp validate_assistant_replay_item(%{"role" => "assistant", "content" => content} = item) do
    with :ok <-
           validate_exact_item_keys(item, ["type", "role", "content", "id", "phase", "status"]),
         :ok <- validate_optional_id(item),
         :ok <- validate_optional_assistant_phase(item),
         :ok <- validate_optional_assistant_status(item) do
      validate_assistant_replay_content(content)
    end
  end

  defp validate_assistant_replay_item(_item),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_assistant_replay_content(content) when is_list(content) and content != [] do
    validate_each(content, &validate_assistant_replay_content_part/1)
  end

  defp validate_assistant_replay_content(_content),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_assistant_replay_content_part(%{"type" => "output_text", "text" => text} = part)
       when is_binary(text) do
    validate_exact_item_keys(part, ["type", "text"])
  end

  defp validate_assistant_replay_content_part(_part),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_assistant_phase(%{"phase" => phase})
       when phase in ["commentary", "final_answer"],
       do: :ok

  defp validate_optional_assistant_phase(%{"phase" => nil}), do: :ok

  defp validate_optional_assistant_phase(%{"phase" => _phase}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_assistant_phase(_item), do: :ok

  defp validate_optional_assistant_status(%{"status" => status})
       when status in ["completed", "incomplete", "in_progress"],
       do: :ok

  defp validate_optional_assistant_status(%{"status" => nil}), do: :ok

  defp validate_optional_assistant_status(%{"status" => _status}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_assistant_status(_item), do: :ok

  defp validate_reasoning_replay_item(%{"id" => id, "summary" => summary} = item)
       when is_binary(id) do
    with :ok <- validate_exact_item_keys(item, ["type", "id", "summary", "encrypted_content"]),
         :ok <- validate_nonblank(id),
         :ok <- validate_reasoning_replay_encrypted_content(Map.get(item, "encrypted_content")) do
      validate_reasoning_replay_summary(summary)
    end
  end

  defp validate_reasoning_replay_item(
         %{"summary" => summary, "encrypted_content" => encrypted_content} = item
       )
       when is_binary(encrypted_content) do
    with :ok <- validate_exact_item_keys(item, ["type", "summary", "encrypted_content"]),
         :ok <- validate_nonblank(encrypted_content) do
      validate_reasoning_replay_summary(summary)
    end
  end

  defp validate_reasoning_replay_item(_item),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_reasoning_replay_encrypted_content(nil), do: :ok
  defp validate_reasoning_replay_encrypted_content(value) when is_binary(value), do: :ok

  defp validate_reasoning_replay_encrypted_content(_value),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_reasoning_replay_summary(summary) when is_list(summary) do
    validate_each(summary, &validate_reasoning_replay_summary_part/1)
  end

  defp validate_reasoning_replay_summary(_summary),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_reasoning_replay_summary_part(%{"type" => "summary_text", "text" => text} = part)
       when is_binary(text) do
    validate_exact_item_keys(part, ["type", "text"])
  end

  defp validate_reasoning_replay_summary_part(_part),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_function_call_replay_item(
         %{"call_id" => call_id, "name" => name, "arguments" => arguments} = item
       )
       when is_binary(call_id) and is_binary(name) and is_binary(arguments) do
    with :ok <-
           validate_exact_item_keys(item, [
             "type",
             "call_id",
             "name",
             "arguments",
             "id",
             "namespace"
           ]),
         :ok <- validate_nonblank(call_id),
         :ok <- validate_nonblank(name),
         :ok <- validate_optional_namespace(item) do
      validate_optional_id(item)
    end
  end

  defp validate_function_call_replay_item(_item),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_function_call_output_item(item) do
    cond do
      Map.has_key?(item, "output") ->
        with :ok <- validate_exact_item_keys(item, ["type", "call_id", "output", "id"]),
             :ok <- validate_nonblank(Map.get(item, "call_id")),
             :ok <- validate_optional_id(item) do
          validate_function_call_output(Map.get(item, "output"))
        end

      Map.has_key?(item, "result") ->
        with :ok <- validate_exact_item_keys(item, ["type", "call_id", "result", "id"]),
             :ok <- validate_nonblank(Map.get(item, "call_id")) do
          validate_optional_id(item)
        end

      true ->
        {:error, Error.invalid_request("function_call_output requires output", "input")}
    end
  end

  defp validate_function_call_output(output), do: validate_json_value(output)

  defp validate_json_value(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: :ok

  defp validate_json_value(value) when is_list(value),
    do: validate_each(value, &validate_json_value/1)

  defp validate_json_value(%{} = value) do
    if Enum.all?(Map.keys(value), &is_binary/1) do
      value |> Map.values() |> validate_each(&validate_json_value/1)
    else
      {:error, Error.invalid_request("input item shape is not translatable", "input")}
    end
  end

  defp validate_json_value(_value),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_id(%{"id" => id}) when is_binary(id), do: validate_nonblank(id)

  defp validate_optional_id(%{"id" => _id}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_id(_item), do: :ok

  defp validate_optional_namespace(%{"namespace" => namespace}) when is_binary(namespace),
    do: validate_nonblank(namespace)

  defp validate_optional_namespace(%{"namespace" => _namespace}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_namespace(_item), do: :ok

  defp validate_nonblank(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, Error.invalid_request("input item shape is not translatable", "input")}
    else
      :ok
    end
  end

  defp validate_nonblank(_value),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_exact_item_keys(item, allowed_keys) do
    case item |> Map.keys() |> Enum.reject(&(&1 in allowed_keys)) do
      [] ->
        :ok

      [_key | _rest] ->
        {:error, Error.invalid_request("input item shape is not translatable", "input")}
    end
  end

  defp validate_message_item(%{"role" => role, "content" => content})
       when role in ["system", "user", "assistant", "developer", "tool"] do
    validate_message_content(content)
  end

  defp validate_message_item(%{"content" => content}), do: validate_message_content(content)

  defp validate_message_item(_item),
    do: {:error, Error.invalid_request("message input items require role and content", "input")}

  defp validate_message_content(content) when is_binary(content), do: :ok

  defp validate_message_content(content) when is_list(content) and content != [] do
    validate_each(content, &validate_message_content_part/1)
  end

  defp validate_message_content(content) when is_list(content),
    do: {:error, Error.invalid_request("message content must not be empty", "input")}

  defp validate_message_content(_content),
    do: {:error, Error.invalid_request("message content shape is not translatable", "input")}

  defp validate_message_content_part(%{"type" => type, "text" => text})
       when type in ["text", "input_text"] and is_binary(text),
       do: :ok

  defp validate_message_content_part(%{"type" => "input_image", "image_url" => image_url})
       when is_binary(image_url),
       do: :ok

  defp validate_message_content_part(%{"type" => "input_image", "file_id" => file_id})
       when is_binary(file_id),
       do: :ok

  defp validate_message_content_part(%{"type" => "input_file", "file_id" => file_id})
       when is_binary(file_id) and file_id != "",
       do: :ok

  defp validate_message_content_part(%{"type" => "input_file", "file_data" => file_data})
       when is_binary(file_data),
       do: :ok

  defp validate_message_content_part(%{
         "type" => "input_audio",
         "input_audio" => %{"data" => data, "format" => format}
       })
       when is_binary(data) and format in @input_audio_formats,
       do: validate_base64_audio(data)

  defp validate_message_content_part(_part),
    do: {:error, Error.invalid_request("message content part is not translatable", "input")}

  defp validate_base64_audio(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, bytes} when byte_size(bytes) > 0 ->
        :ok

      _value ->
        {:error, Error.invalid_request("input_audio data must be base64", "input")}
    end
  end

  defp validate_each(items, validator) when is_list(items) and is_function(validator, 1) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validator.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
