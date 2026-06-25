defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.Validation do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.ToolResultShape

  @input_audio_formats ~w(mp3 wav)
  @metadata_passthrough_key "internal_chat_message_metadata_passthrough"

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

  defp validate_additional_tools_tools(tools) when is_list(tools),
    do: validate_each(tools, &validate_additional_tool/1)

  defp validate_additional_tools_tools(_tools),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_additional_tool(%{"type" => "mcp"}),
    do: {:error, Error.invalid_request("remote MCP tools are not supported", "input")}

  defp validate_additional_tool(_tool), do: :ok

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
           validate_exact_item_keys(item, [
             "type",
             "role",
             "content",
             "id",
             "phase",
             "status",
             "metadata",
             @metadata_passthrough_key
           ]),
         :ok <- validate_optional_id(item),
         :ok <- validate_optional_item_metadata(item),
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
    with :ok <-
           validate_exact_item_keys(item, [
             "type",
             "id",
             "summary",
             "encrypted_content",
             "metadata",
             @metadata_passthrough_key
           ]),
         :ok <- validate_nonblank(id),
         :ok <- validate_optional_item_metadata(item),
         :ok <- validate_reasoning_replay_encrypted_content(Map.get(item, "encrypted_content")) do
      validate_reasoning_replay_summary(summary)
    end
  end

  defp validate_reasoning_replay_item(
         %{"summary" => summary, "encrypted_content" => encrypted_content} = item
       )
       when is_binary(encrypted_content) do
    with :ok <-
           validate_exact_item_keys(item, [
             "type",
             "summary",
             "encrypted_content",
             "metadata",
             @metadata_passthrough_key
           ]),
         :ok <- validate_optional_item_metadata(item),
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
             "namespace",
             "metadata",
             @metadata_passthrough_key
           ]),
         :ok <- validate_nonblank(call_id),
         :ok <- validate_nonblank(name),
         :ok <- validate_optional_item_metadata(item),
         :ok <- validate_optional_namespace(item) do
      validate_optional_id(item)
    end
  end

  defp validate_function_call_replay_item(_item),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_function_call_output_item(item) do
    cond do
      Map.has_key?(item, "output") ->
        with :ok <-
               validate_exact_item_keys(item, [
                 "type",
                 "call_id",
                 "output",
                 "id",
                 "metadata",
                 @metadata_passthrough_key
               ]),
             :ok <- validate_nonblank(Map.get(item, "call_id")),
             :ok <- validate_optional_item_metadata(item),
             :ok <- validate_optional_id(item) do
          validate_function_call_output(Map.get(item, "output"))
        end

      Map.has_key?(item, "result") ->
        with :ok <-
               validate_exact_item_keys(item, [
                 "type",
                 "call_id",
                 "result",
                 "id",
                 "metadata",
                 @metadata_passthrough_key
               ]),
             :ok <- validate_optional_item_metadata(item),
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

  defp validate_optional_item_metadata(item) do
    with :ok <- validate_optional_metadata(item) do
      validate_optional_metadata_passthrough(item)
    end
  end

  defp validate_optional_metadata(%{"metadata" => nil}), do: :ok

  defp validate_optional_metadata(%{"metadata" => metadata}) when is_map(metadata),
    do: validate_json_value(metadata)

  defp validate_optional_metadata(%{"metadata" => _metadata}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_metadata(_item), do: :ok

  defp validate_optional_metadata_passthrough(%{@metadata_passthrough_key => nil}), do: :ok

  defp validate_optional_metadata_passthrough(%{@metadata_passthrough_key => metadata})
       when is_map(metadata),
       do: validate_json_value(metadata)

  defp validate_optional_metadata_passthrough(%{@metadata_passthrough_key => _metadata}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_metadata_passthrough(_item), do: :ok

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
