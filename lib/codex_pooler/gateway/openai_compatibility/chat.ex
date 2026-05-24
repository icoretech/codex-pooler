defmodule CodexPooler.Gateway.OpenAICompatibility.Chat do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions

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
         {:ok, messages} <- messages(payload),
         {:ok, response_payload} <- response_payload(payload, messages) do
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

  defp valid_message?(%{"role" => role, "content" => content})
       when role in ["system", "user", "assistant", "developer", "tool"] do
    valid_content?(content)
  end

  defp valid_message?(_message), do: false

  defp response_payload(payload, messages) do
    base = %{
      "model" => payload["model"],
      "input" => Enum.map(messages, &message_to_input_item/1)
    }

    with {:ok, base} <- maybe_put_tools(base, payload) do
      base
      |> maybe_put_tool_choice(payload)
      |> maybe_put(payload, "parallel_tool_calls")
      |> maybe_put(payload, "stream")
      |> put_text_format(payload)
    end
  end

  defp message_to_input_item(%{"role" => role, "content" => content} = message) do
    %{"type" => "message", "role" => role, "content" => normalize_content(content)}
    |> maybe_put(message, "name")
    |> maybe_put(message, "tool_call_id")
  end

  defp normalize_content(content) when is_binary(content) do
    [%{"type" => "input_text", "text" => content}]
  end

  defp normalize_content(content) when is_list(content),
    do: Enum.map(content, &normalize_content_part/1)

  defp normalize_content(%{} = content), do: [normalize_content_part(content)]

  defp normalize_content(content), do: content

  defp normalize_content_part(%{"type" => "text", "text" => text}),
    do: %{"type" => "input_text", "text" => text}

  defp normalize_content_part(%{"type" => "image_url", "image_url" => image_url})
       when is_binary(image_url),
       do: %{"type" => "input_image", "image_url" => image_url}

  defp normalize_content_part(%{"type" => "image_url", "image_url" => %{"url" => image_url}})
       when is_binary(image_url),
       do: %{"type" => "input_image", "image_url" => image_url}

  defp normalize_content_part(%{"type" => "input_audio"} = part), do: part

  defp normalize_content_part(%{} = part), do: part

  defp valid_content?(content) when is_binary(content), do: true

  defp valid_content?(content) when is_list(content),
    do: content != [] and Enum.all?(content, &valid_content_part?/1)

  defp valid_content?(%{} = content), do: valid_content_part?(content)
  defp valid_content?(_content), do: false

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

  defp valid_content_part?(_part), do: false

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

  defp maybe_put(acc, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end
end
