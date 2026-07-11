defmodule CodexPooler.Gateway.OpenAICompatibility.Chat do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Matrix, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @locally_unsupported_fields ~w(audio frequency_penalty logit_bias logprobs modalities n prediction presence_penalty seed stop top_logprobs user web_search_options)
  @service_tiers ~w(auto default flex priority scale)
  @verbosity_values ~w(low medium high)

  @spec validate(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate(payload) do
    with {:ok, %{chat_payload: chat_payload, response_payload: response_payload}} <-
           prepare_response_payload(payload),
         {:ok, _response_payload} <- Responses.validate(response_payload) do
      {:ok, chat_payload}
    end
  end

  @spec coerce(term(), map() | keyword()) ::
          {:ok,
           %{
             endpoint: String.t(),
             payload: map(),
             request_options: RequestOptions.t(),
             chat_payload: map()
           }}
          | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, %{chat_payload: chat_payload, response_payload: response_payload}} <-
           prepare_response_payload(payload),
         {:ok, response} <- Responses.coerce(response_payload, opts) do
      {:ok, Map.put(response, :chat_payload, chat_payload)}
    end
  end

  defp prepare_response_payload(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- reject_legacy_functions(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :chat),
         :ok <- Validation.require_model(payload),
         :ok <- reject_locally_unsupported_fields(payload),
         :ok <- validate_reasoning_effort(payload),
         :ok <- validate_service_tier(payload),
         :ok <- validate_stream_options(payload),
         :ok <- validate_token_limits(payload),
         :ok <- validate_verbosity(payload),
         :ok <- validate_translatable_prompt_cache_breakpoints(payload),
         {:ok, response_payload} <- response_payload(payload) do
      {:ok, %{chat_payload: payload, response_payload: response_payload}}
    end
  end

  defp reject_legacy_functions(payload) do
    cond do
      Map.has_key?(payload, "functions") ->
        {:error, Error.invalid_request("legacy functions are not translatable", "functions")}

      Map.has_key?(payload, "function_call") ->
        {:error,
         Error.invalid_request("legacy function_call is not translatable", "function_call")}

      true ->
        :ok
    end
  end

  defp messages(%{"messages" => messages}) when is_list(messages) and messages != [] do
    if Enum.all?(messages, &valid_message?/1) do
      {:ok, messages}
    else
      {:error, Error.invalid_request("messages must contain role/content objects", "messages")}
    end
  end

  defp messages(%{"messages" => _messages}),
    do: {:error, Error.invalid_request("messages must be a non-empty array", "messages")}

  defp messages(_payload), do: {:error, Error.invalid_request("messages is required", "messages")}

  defp reject_locally_unsupported_fields(payload) do
    payload
    |> Map.keys()
    |> Enum.find(&(&1 in @locally_unsupported_fields))
    |> case do
      nil -> :ok
      field -> {:error, Error.unsupported_parameter(field)}
    end
  end

  defp validate_reasoning_effort(%{"reasoning_effort" => effort}),
    do: Validation.validate_reasoning_effort_token(effort, "reasoning_effort")

  defp validate_reasoning_effort(_payload), do: :ok

  defp validate_service_tier(%{"service_tier" => tier}) when is_binary(tier) do
    tier = normalize_enum(tier)

    if tier in @service_tiers,
      do: :ok,
      else: {:error, Error.invalid_request("service_tier is not supported", "service_tier")}
  end

  defp validate_service_tier(%{"service_tier" => _tier}),
    do: {:error, Error.invalid_request("service_tier is not supported", "service_tier")}

  defp validate_service_tier(_payload), do: :ok

  defp validate_stream_options(%{"stream_options" => options}) when is_map(options) do
    with :ok <- validate_stream_option_keys(options, ["include_usage"]) do
      case Map.get(options, "include_usage") do
        nil ->
          :ok

        value when is_boolean(value) ->
          :ok

        _value ->
          {:error,
           Error.invalid_request(
             "stream_options.include_usage must be a boolean",
             "stream_options.include_usage"
           )}
      end
    end
  end

  defp validate_stream_options(%{"stream_options" => _options}),
    do: {:error, Error.invalid_request("stream_options must be an object", "stream_options")}

  defp validate_stream_options(_payload), do: :ok

  defp validate_stream_option_keys(options, allowed_keys) do
    case options |> Map.keys() |> Enum.reject(&(&1 in allowed_keys)) do
      [] ->
        :ok

      [key | _rest] ->
        {:error,
         Error.invalid_request("stream_options field is not supported", "stream_options." <> key)}
    end
  end

  defp validate_token_limits(payload) do
    ["max_tokens", "max_completion_tokens"]
    |> Enum.find_value(:ok, fn field ->
      case Map.fetch(payload, field) do
        {:ok, value} when is_integer(value) and value > 0 ->
          false

        {:ok, _value} ->
          {:error, Error.invalid_request(field <> " must be a positive integer", field)}

        :error ->
          false
      end
    end)
  end

  defp validate_verbosity(%{"verbosity" => verbosity}) when is_binary(verbosity) do
    verbosity = normalize_enum(verbosity)

    if verbosity in @verbosity_values,
      do: :ok,
      else: {:error, Error.invalid_request("verbosity is not supported", "verbosity")}
  end

  defp validate_verbosity(%{"verbosity" => _verbosity}),
    do: {:error, Error.invalid_request("verbosity is not supported", "verbosity")}

  defp validate_verbosity(_payload), do: :ok

  defp valid_message?(%{"role" => "assistant", "tool_calls" => tool_calls} = message)
       when is_list(tool_calls) do
    valid_assistant_tool_message_content?(Map.get(message, "content")) and
      valid_assistant_tool_calls?(tool_calls)
  end

  defp valid_message?(%{"role" => "tool", "content" => content}),
    do: valid_tool_content?(content)

  defp valid_message?(%{"role" => role, "content" => content})
       when role in ["system", "user", "assistant", "developer", "tool"] do
    valid_content?(content)
  end

  defp valid_message?(_message), do: false

  defp response_payload(%{"messages" => messages} = payload)
       when is_list(messages) and messages != [] do
    with {:ok, messages} <- messages(payload) do
      response_payload_from_messages(payload, messages)
    end
  end

  defp response_payload(%{"messages" => []} = payload) do
    fallback_response_payload(
      payload,
      Error.invalid_request("messages must be a non-empty array", "messages")
    )
  end

  defp response_payload(%{"messages" => _messages} = payload) do
    with {:ok, _messages} <- messages(payload) do
      fallback_response_payload(
        payload,
        Error.invalid_request("messages is required", "messages")
      )
    end
  end

  defp response_payload(payload) do
    fallback_response_payload(payload, Error.invalid_request("messages is required", "messages"))
  end

  defp fallback_response_payload(%{"input" => _input} = payload, _messages_error) do
    payload
    |> Map.take(Matrix.forwarded_fields(:responses))
    |> Map.put_new("instructions", "")
    |> then(&{:ok, &1})
  end

  defp fallback_response_payload(_payload, messages_error), do: {:error, messages_error}

  defp response_payload_from_messages(payload, messages) do
    base = %{
      "model" => payload["model"],
      "input" => Enum.flat_map(messages, &message_to_input_items/1)
    }

    with {:ok, base} <- maybe_put_tools(base, payload) do
      base
      |> maybe_put_tool_choice(payload)
      |> maybe_put(payload, "parallel_tool_calls")
      |> maybe_put(payload, "metadata")
      |> maybe_put(payload, "moderation")
      |> maybe_put(payload, "prompt_cache_key")
      |> maybe_put(payload, "prompt_cache_options")
      |> maybe_put(payload, "prompt_cache_retention")
      |> maybe_put(payload, "safety_identifier")
      |> maybe_put(payload, "service_tier")
      |> maybe_put(payload, "store")
      |> maybe_put(payload, "stream")
      |> maybe_put(payload, "temperature")
      |> maybe_put(payload, "top_p")
      |> maybe_put_max_output_tokens(payload)
      |> maybe_put_reasoning(payload)
      |> put_text_options(payload)
    end
  end

  defp message_to_input_items(%{"role" => "assistant", "tool_calls" => tool_calls} = message)
       when is_list(tool_calls) do
    assistant_tool_message_content_items(message) ++ assistant_tool_call_items(tool_calls)
  end

  defp message_to_input_items(%{"role" => role, "content" => content} = message) do
    content
    |> content_parts()
    |> expand_message_parts(role, message)
  end

  defp assistant_tool_message_content_items(message) do
    case Map.fetch(message, "content") do
      {:ok, nil} -> []
      {:ok, ""} -> []
      {:ok, content} -> content |> content_parts() |> expand_message_parts("assistant", message)
      :error -> []
    end
  end

  defp content_parts(content) when is_binary(content), do: [content]
  defp content_parts(content) when is_list(content), do: content
  defp content_parts(%{} = content), do: [content]
  defp content_parts(content), do: [content]

  defp expand_message_parts(parts, role, message) do
    parts
    |> Enum.reduce({[], []}, fn part, {items, pending_parts} ->
      case special_content_item(part) do
        nil ->
          {items, pending_parts ++ [normalize_content_part(part, role)]}

        item ->
          items = flush_message_item(items, pending_parts, role, message)
          {items ++ [item], []}
      end
    end)
    |> then(fn {items, pending_parts} ->
      flush_message_item(items, pending_parts, role, message)
    end)
  end

  defp flush_message_item(items, [], _role, _message), do: items

  defp flush_message_item(items, pending_parts, role, message) do
    item =
      %{"type" => "message", "role" => role, "content" => pending_parts}
      |> maybe_put(message, "name")
      |> maybe_put(message, "tool_call_id")

    items ++ [item]
  end

  defp normalize_content_part(text, "assistant") when is_binary(text),
    do: %{"type" => "output_text", "text" => text}

  defp normalize_content_part(text, _role) when is_binary(text),
    do: %{"type" => "input_text", "text" => text}

  defp normalize_content_part(%{"type" => "text", "text" => text} = part, "assistant"),
    do:
      %{"type" => "output_text", "text" => text}
      |> maybe_put_prompt_cache_breakpoint(part)

  defp normalize_content_part(%{"type" => "text", "text" => text} = part, _role),
    do:
      %{"type" => "input_text", "text" => text}
      |> maybe_put_prompt_cache_breakpoint(part)

  defp normalize_content_part(%{"type" => "input_text", "text" => text} = part, _role),
    do:
      %{"type" => "input_text", "text" => text}
      |> maybe_put_prompt_cache_breakpoint(part)

  defp normalize_content_part(%{"type" => "image_url", "image_url" => image_url} = part, _role)
       when is_binary(image_url),
       do:
         %{"type" => "input_image", "image_url" => image_url}
         |> maybe_put_prompt_cache_breakpoint(part)

  defp normalize_content_part(
         %{"type" => "image_url", "image_url" => %{"url" => image_url}} = part,
         _role
       )
       when is_binary(image_url),
       do:
         %{"type" => "input_image", "image_url" => image_url}
         |> maybe_put_prompt_cache_breakpoint(part)

  defp normalize_content_part(
         %{"type" => "file", "file" => %{"file_id" => file_id}} = part,
         _role
       )
       when is_binary(file_id) and file_id != "",
       do:
         %{"type" => "input_file", "file_id" => file_id}
         |> maybe_put_prompt_cache_breakpoint(part)

  defp normalize_content_part(
         %{"type" => "file", "file" => %{"filename" => filename, "file_data" => file_data}} = part,
         _role
       )
       when is_binary(filename) and filename != "" and is_binary(file_data),
       do:
         %{"type" => "input_file", "filename" => filename, "file_data" => file_data}
         |> maybe_put_prompt_cache_breakpoint(part)

  defp normalize_content_part(%{"type" => "input_audio"} = part, _role), do: part
  defp normalize_content_part(%{} = part, _role), do: part
  defp normalize_content_part(content, _role), do: content

  defp special_content_item(%{"type" => "tool-call"} = part), do: cline_tool_call_item(part)
  defp special_content_item(%{"type" => "tool-result"} = part), do: cline_tool_result_item(part)
  defp special_content_item(_part), do: nil

  defp cline_tool_call_item(%{"toolCallId" => call_id, "toolName" => name, "input" => input})
       when is_binary(call_id) and call_id != "" and is_binary(name) and name != "" do
    %{
      "type" => "function_call",
      "call_id" => call_id,
      "name" => name,
      "arguments" => Jason.encode!(input)
    }
  end

  defp cline_tool_call_item(part), do: part

  defp cline_tool_result_item(%{"toolCallId" => call_id, "output" => output})
       when is_binary(call_id) and call_id != "" do
    %{
      "type" => "function_call_output",
      "call_id" => call_id,
      "output" => normalize_cline_tool_result_output(output)
    }
  end

  defp cline_tool_result_item(part), do: part

  defp assistant_tool_call_items(tool_calls),
    do: Enum.map(tool_calls, &assistant_tool_call_item/1)

  defp assistant_tool_call_item(
         %{"function" => %{"name" => name, "arguments" => arguments}} = item
       ) do
    %{
      "type" => "function_call",
      "call_id" => assistant_tool_call_id(item),
      "name" => name,
      "arguments" => arguments
    }
  end

  defp assistant_tool_call_id(item) do
    clean_string(Map.get(item, "call_id")) || clean_string(Map.get(item, "id"))
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp normalize_cline_tool_result_output(output) when is_binary(output), do: output

  defp normalize_cline_tool_result_output(output) when is_list(output),
    do: Enum.map(output, &normalize_cline_tool_result_output_part/1)

  defp normalize_cline_tool_result_output(output), do: output

  defp normalize_cline_tool_result_output_part(part) when is_binary(part),
    do: %{"type" => "input_text", "text" => part}

  defp normalize_cline_tool_result_output_part(%{"type" => type, "text" => text})
       when type in ["text", "input_text"] and is_binary(text),
       do: %{"type" => "input_text", "text" => text}

  defp normalize_cline_tool_result_output_part(%{"type" => "image_url", "image_url" => image_url})
       when is_binary(image_url),
       do: %{"type" => "input_image", "image_url" => image_url}

  defp normalize_cline_tool_result_output_part(%{
         "type" => "image_url",
         "image_url" => %{"url" => image_url}
       })
       when is_binary(image_url),
       do: %{"type" => "input_image", "image_url" => image_url}

  defp normalize_cline_tool_result_output_part(%{
         "type" => "input_image",
         "image_url" => image_url
       })
       when is_binary(image_url),
       do: %{"type" => "input_image", "image_url" => image_url}

  defp normalize_cline_tool_result_output_part(%{
         "type" => "image",
         "data" => data,
         "mediaType" => media_type
       })
       when is_binary(data) and is_binary(media_type),
       do: %{"type" => "input_image", "image_url" => "data:#{media_type};base64,#{data}"}

  defp normalize_cline_tool_result_output_part(%{"type" => "json", "value" => value}),
    do: %{"type" => "input_text", "text" => Jason.encode!(value)}

  defp normalize_cline_tool_result_output_part(part), do: part

  defp valid_tool_content?(content) when is_binary(content), do: true

  defp valid_tool_content?(content) when is_list(content) do
    content != [] and Enum.all?(content, &valid_tool_content_part?/1)
  end

  defp valid_tool_content?(_content), do: false

  defp valid_tool_content_part?(%{"type" => type, "text" => text})
       when type in ["text", "input_text"] and is_binary(text),
       do: true

  defp valid_tool_content_part?(_part), do: false

  defp validate_translatable_prompt_cache_breakpoints(%{"messages" => messages})
       when is_list(messages) do
    messages
    |> Enum.find_value(:ok, &prompt_cache_breakpoint_translation_error/1)
  end

  defp validate_translatable_prompt_cache_breakpoints(_payload), do: :ok

  defp prompt_cache_breakpoint_translation_error(%{"role" => "assistant", "content" => content}) do
    if content
       |> content_parts()
       |> Enum.any?(&marked_text_content_part?/1) do
      {:error,
       Error.invalid_request("assistant prompt_cache_breakpoint is not translatable", "input")}
    end
  end

  defp prompt_cache_breakpoint_translation_error(%{"role" => "user", "content" => content}) do
    if content
       |> content_parts()
       |> Enum.any?(&marked_input_audio_content_part?/1) do
      {:error,
       Error.invalid_request("input_audio prompt_cache_breakpoint is not translatable", "input")}
    end
  end

  defp prompt_cache_breakpoint_translation_error(_message), do: false

  defp marked_text_content_part?(%{
         "type" => type,
         "text" => _text,
         "prompt_cache_breakpoint" => _breakpoint
       })
       when type in ["text", "input_text"],
       do: true

  defp marked_text_content_part?(_part), do: false

  defp marked_input_audio_content_part?(%{
         "type" => "input_audio",
         "prompt_cache_breakpoint" => _breakpoint
       }),
       do: true

  defp marked_input_audio_content_part?(_part), do: false

  defp maybe_put_prompt_cache_breakpoint(acc, %{"prompt_cache_breakpoint" => breakpoint}),
    do: Map.put(acc, "prompt_cache_breakpoint", breakpoint)

  defp maybe_put_prompt_cache_breakpoint(acc, _part), do: acc

  defp valid_content?(content) when is_binary(content), do: true

  defp valid_content?(content) when is_list(content),
    do: content != [] and Enum.all?(content, &valid_content_part?/1)

  defp valid_content?(%{} = content), do: valid_content_part?(content)
  defp valid_content?(_content), do: false

  defp valid_assistant_tool_message_content?(nil), do: true
  defp valid_assistant_tool_message_content?(content), do: valid_content?(content)

  defp valid_assistant_tool_calls?(tool_calls),
    do: Enum.all?(tool_calls, &valid_assistant_tool_call?/1)

  defp valid_assistant_tool_call?(
         %{"function" => %{"name" => name, "arguments" => arguments}} = item
       )
       when is_binary(name) and name != "" and is_binary(arguments) do
    assistant_tool_call_id(item) != nil
  end

  defp valid_assistant_tool_call?(_tool_call), do: false

  defp valid_content_part?(%{"type" => type, "text" => text})
       when type in ["text", "input_text"] and is_binary(text),
       do: true

  defp valid_content_part?(%{"type" => "image_url", "image_url" => image_url})
       when is_binary(image_url),
       do: true

  defp valid_content_part?(%{"type" => "image_url", "image_url" => %{"url" => image_url}})
       when is_binary(image_url),
       do: true

  defp valid_content_part?(%{"type" => "input_image", "image_url" => image_url})
       when is_binary(image_url),
       do: true

  defp valid_content_part?(%{
         "type" => "input_audio",
         "input_audio" => %{"data" => data, "format" => format}
       })
       when is_binary(data) and is_binary(format),
       do: true

  defp valid_content_part?(%{"type" => "file", "file" => %{"file_id" => file_id}})
       when is_binary(file_id) and file_id != "",
       do: true

  defp valid_content_part?(%{
         "type" => "file",
         "file" => %{"filename" => filename, "file_data" => file_data}
       })
       when is_binary(filename) and filename != "" and is_binary(file_data),
       do: true

  defp valid_content_part?(%{
         "type" => "tool-call",
         "toolCallId" => call_id,
         "toolName" => name,
         "input" => _input
       })
       when is_binary(call_id) and call_id != "" and is_binary(name) and name != "",
       do: true

  defp valid_content_part?(%{
         "type" => "tool-result",
         "toolCallId" => call_id,
         "output" => output
       })
       when is_binary(call_id) and call_id != "",
       do: valid_cline_tool_result_output?(output)

  defp valid_content_part?(_part), do: false

  defp valid_cline_tool_result_output?(output) when is_binary(output), do: true

  defp valid_cline_tool_result_output?(output) when is_list(output),
    do: output != [] and Enum.all?(output, &valid_cline_tool_result_output_part?/1)

  defp valid_cline_tool_result_output?(output) when is_map(output), do: true
  defp valid_cline_tool_result_output?(_output), do: false

  defp valid_cline_tool_result_output_part?(part) when is_binary(part), do: true

  defp valid_cline_tool_result_output_part?(%{"type" => type, "text" => text})
       when type in ["text", "input_text"] and is_binary(text),
       do: true

  defp valid_cline_tool_result_output_part?(%{"type" => "image_url", "image_url" => image_url})
       when is_binary(image_url),
       do: true

  defp valid_cline_tool_result_output_part?(%{
         "type" => "image_url",
         "image_url" => %{"url" => image_url}
       })
       when is_binary(image_url),
       do: true

  defp valid_cline_tool_result_output_part?(%{
         "type" => "input_image",
         "image_url" => image_url
       })
       when is_binary(image_url),
       do: true

  defp valid_cline_tool_result_output_part?(%{
         "type" => "image",
         "data" => data,
         "mediaType" => media_type
       })
       when is_binary(data) and is_binary(media_type),
       do: true

  defp valid_cline_tool_result_output_part?(%{"type" => "json", "value" => _value}), do: true
  defp valid_cline_tool_result_output_part?(_part), do: false

  defp maybe_put_tools(acc, %{"tools" => tools}) when is_list(tools) do
    with {:ok, tools} <- translate_tools(tools) do
      {:ok, Map.put(acc, "tools", tools)}
    end
  end

  defp maybe_put_tools(_acc, %{"tools" => _tools}),
    do: {:error, Error.invalid_request("tools must be an array", "tools")}

  defp maybe_put_tools(acc, _payload), do: {:ok, acc}

  defp translate_tools(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case translate_tool(tool) do
        {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_tool(%{
         "type" => "function",
         "function" => %{"name" => name, "parameters" => parameters} = function
       })
       when is_binary(name) and is_map(parameters) do
    if String.trim(name) == "" do
      {:error, Error.invalid_request("function tool requires a non-empty name", "tools")}
    else
      tool =
        function
        |> Map.take(["name", "description", "parameters", "strict"])
        |> Map.put("type", "function")

      {:ok, tool}
    end
  end

  defp translate_tool(%{"type" => "function"}),
    do:
      {:error,
       Error.invalid_request(
         "function tool requires nested function name and parameters",
         "tools"
       )}

  defp translate_tool(%{"type" => type} = tool)
       when type in ["web_search_preview", "image_generation"],
       do: {:ok, tool}

  defp translate_tool(_tool),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp maybe_put_tool_choice(acc, %{
         "tool_choice" => %{"type" => "function", "function" => %{"name" => name}}
       })
       when is_binary(name),
       do: Map.put(acc, "tool_choice", %{"type" => "function", "name" => name})

  defp maybe_put_tool_choice(acc, %{"tool_choice" => tool_choice}),
    do: Map.put(acc, "tool_choice", tool_choice)

  defp maybe_put_tool_choice(acc, _payload), do: acc

  defp put_text_options(acc, payload) do
    with {:ok, acc} <- put_text_format(acc, payload) do
      put_text_verbosity(acc, payload)
    end
  end

  defp put_text_format(acc, %{"response_format" => response_format}) do
    case response_format do
      %{"type" => "json_object"} ->
        {:ok, Map.put(acc, "text", %{"format" => %{"type" => "json_object"}})}

      %{"type" => "json_schema", "json_schema" => schema} when is_map(schema) ->
        {:ok, Map.put(acc, "text", %{"format" => Map.put(schema, "type", "json_schema")})}

      %{"type" => "json_schema"} ->
        {:error,
         Error.invalid_request("response_format json_schema must be an object", "response_format")}

      %{"type" => "text"} ->
        {:ok, Map.put(acc, "text", %{"format" => %{"type" => "text"}})}

      _format ->
        {:ok, Map.put(acc, "response_format", response_format)}
    end
  end

  defp put_text_format(acc, _payload), do: {:ok, acc}

  defp put_text_verbosity(acc, %{"verbosity" => verbosity}) do
    text = Map.get(acc, "text", %{})
    {:ok, Map.put(acc, "text", Map.put(text, "verbosity", normalize_enum(verbosity)))}
  end

  defp put_text_verbosity(acc, _payload), do: {:ok, acc}

  defp maybe_put_max_output_tokens(acc, %{"max_completion_tokens" => value}),
    do: Map.put(acc, "max_output_tokens", value)

  defp maybe_put_max_output_tokens(acc, %{"max_tokens" => value}),
    do: Map.put(acc, "max_output_tokens", value)

  defp maybe_put_max_output_tokens(acc, _payload), do: acc

  defp maybe_put_reasoning(acc, %{"reasoning_effort" => effort}),
    do: Map.put(acc, "reasoning", %{"effort" => normalize_enum(effort)})

  defp maybe_put_reasoning(acc, _payload), do: acc

  defp maybe_put(acc, source, "service_tier" = key) do
    case Map.fetch(source, key) do
      {:ok, value} when is_binary(value) -> Map.put(acc, key, normalize_enum(value))
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp maybe_put(acc, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp normalize_enum(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()
end
