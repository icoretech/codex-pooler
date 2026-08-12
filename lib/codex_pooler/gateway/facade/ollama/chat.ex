defmodule CodexPooler.Gateway.Facade.Ollama.Chat do
  @moduledoc """
  Translates native Ollama chat requests into canonical Responses work.
  """

  alias CodexPooler.Gateway.Facade.Ollama.Request
  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @supported_fields ~w(model messages tools format options stream think keep_alive)

  @type formatting :: Request.formatting()

  @spec to_responses(term()) ::
          {:ok, map(), formatting()} | {:error, Error.reason()}
  def to_responses(payload) do
    with {:ok, payload} <- Request.normalize_payload(payload),
         :ok <- Request.reject_unknown_fields(payload, @supported_fields),
         {:ok, input} <- translate_messages(payload),
         {:ok, tools} <- translate_tools(payload),
         canonical = %{"input" => input} |> maybe_put("tools", tools),
         {:ok, canonical, formatting} <- Request.apply_common(payload, canonical, :chat) do
      {:ok, canonical, formatting}
    end
  end

  @spec coerce(term(), map() | keyword()) :: {:ok, map()} | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, payload} <- Request.normalize_payload(payload),
         :ok <- Request.reject_unknown_fields(payload, @supported_fields),
         {:ok, input} <- translate_messages(payload),
         {:ok, tools} <- translate_tools(payload) do
      canonical = %{"input" => input} |> maybe_put("tools", tools)
      Request.coerce(payload, canonical, :chat, opts)
    end
  end

  defp translate_messages(%{"messages" => messages}) when is_list(messages) and messages != [] do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{items: [], pending_calls: []}}, fn {message, index},
                                                                    {:ok, state} ->
      case translate_message(message, index, state) do
        {:ok, translated, state} ->
          {:cont, {:ok, %{state | items: Enum.reverse(translated, state.items)}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, %{items: items}} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_messages(%{"messages" => _messages}) do
    {:error, Error.invalid_request("messages must be a non-empty array", "messages")}
  end

  defp translate_messages(_payload) do
    {:error, Error.invalid_request("messages is required", "messages")}
  end

  defp translate_message(%{"role" => role} = message, index, state) when is_binary(role) do
    case role |> String.trim() |> String.downcase() do
      role when role in ["system", "user"] ->
        translate_input_message(message, role, index, state)

      "assistant" ->
        translate_assistant_message(message, index, state)

      "tool" ->
        translate_tool_result(message, index, state)

      _role ->
        message_error(index, "message role is not supported")
    end
  end

  defp translate_message(_message, index, _state),
    do: message_error(index, "message must contain a role")

  defp translate_input_message(message, role, index, state) do
    with {:ok, content} <- message_content(message, index),
         :ok <- reject_images_for_non_user(message, role, index),
         {:ok, images} <-
           Request.image_parts(Map.get(message, "images"), "messages[#{index}].images"),
         parts = maybe_text_part(content, "input_text") ++ images,
         :ok <- require_content(parts, index) do
      {:ok, [%{"type" => "message", "role" => role, "content" => parts}], state}
    end
  end

  defp reject_images_for_non_user(%{"images" => _images}, role, index) when role != "user" do
    {:error, Error.unsupported_parameter("messages[#{index}].images")}
  end

  defp reject_images_for_non_user(_message, _role, _index), do: :ok

  defp translate_assistant_message(message, index, state) do
    with {:ok, content} <- message_content(message, index),
         :ok <- reject_assistant_images(message, index),
         {:ok, calls, pending_calls} <- assistant_tool_calls(message, index),
         content_items = maybe_assistant_content(content),
         :ok <- require_assistant_content(content_items, calls, index) do
      {:ok, content_items ++ calls,
       %{state | pending_calls: state.pending_calls ++ pending_calls}}
    end
  end

  defp reject_assistant_images(%{"images" => _images}, index),
    do: {:error, Error.unsupported_parameter("messages[#{index}].images")}

  defp reject_assistant_images(_message, _index), do: :ok

  defp maybe_assistant_content(""), do: []

  defp maybe_assistant_content(content) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => content}]
      }
    ]
  end

  defp assistant_tool_calls(%{"tool_calls" => calls}, message_index) when is_list(calls) do
    calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {call, call_index}, {:ok, items, pending} ->
      case assistant_tool_call(call, message_index, call_index) do
        {:ok, item, pending_call} ->
          {:cont, {:ok, [item | items], [pending_call | pending]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items, pending} -> {:ok, Enum.reverse(items), Enum.reverse(pending)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assistant_tool_calls(%{"tool_calls" => _calls}, message_index) do
    {:error,
     Error.invalid_request(
       "tool_calls must be an array",
       "messages[#{message_index}].tool_calls"
     )}
  end

  defp assistant_tool_calls(_message, _message_index), do: {:ok, [], []}

  defp assistant_tool_call(
         %{"function" => %{"name" => name, "arguments" => arguments}} = call,
         message_index,
         call_index
       )
       when is_binary(name) and is_map(arguments) do
    name = String.trim(name)

    if name == "" do
      invalid_tool_call(message_index, call_index)
    else
      call_id =
        clean_string(Map.get(call, "id")) ||
          "ollama_call_#{message_index}_#{call_index}"

      item = %{
        "type" => "function_call",
        "call_id" => call_id,
        "name" => name,
        "arguments" => Jason.encode!(arguments)
      }

      {:ok, item, %{id: call_id, name: name}}
    end
  end

  defp assistant_tool_call(_call, message_index, call_index),
    do: invalid_tool_call(message_index, call_index)

  defp invalid_tool_call(message_index, call_index) do
    {:error,
     Error.invalid_request(
       "tool call requires a function name and object arguments",
       "messages[#{message_index}].tool_calls[#{call_index}]"
     )}
  end

  defp translate_tool_result(message, index, state) do
    with {:ok, content} <- message_content(message, index),
         {:ok, call, pending_calls} <- resolve_tool_result_call(message, state.pending_calls),
         :ok <- validate_tool_result_name(message, call, index) do
      item = %{
        "type" => "function_call_output",
        "call_id" => call.id,
        "output" => content
      }

      {:ok, [item], %{state | pending_calls: pending_calls}}
    else
      {:error, :unmatched} -> message_error(index, "tool result does not match a prior tool call")
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_tool_result_call(message, pending_calls) do
    call_id = clean_string(Map.get(message, "tool_call_id"))
    tool_name = clean_string(Map.get(message, "tool_name"))

    matcher =
      cond do
        call_id -> &(&1.id == call_id)
        tool_name -> &(&1.name == tool_name)
        length(pending_calls) == 1 -> fn _call -> true end
        true -> fn _call -> false end
      end

    case Enum.find_index(pending_calls, matcher) do
      nil ->
        {:error, :unmatched}

      index ->
        {call, pending_calls} = List.pop_at(pending_calls, index)
        {:ok, call, pending_calls}
    end
  end

  defp validate_tool_result_name(message, call, index) do
    case clean_string(Map.get(message, "tool_name")) do
      nil -> :ok
      name when name == call.name -> :ok
      _name -> message_error(index, "tool_name does not match tool_call_id")
    end
  end

  defp message_content(%{"content" => content}, _index) when is_binary(content),
    do: {:ok, content}

  defp message_content(_message, index),
    do: message_error(index, "message content must be a string")

  defp require_content([], index), do: message_error(index, "message content must not be empty")
  defp require_content(_parts, _index), do: :ok

  defp require_assistant_content([], [], index),
    do: message_error(index, "assistant message must contain content or tool_calls")

  defp require_assistant_content(_content, _calls, _index), do: :ok

  defp message_error(index, message),
    do: {:error, Error.invalid_request(message, "messages[#{index}]")}

  defp maybe_text_part("", _type), do: []
  defp maybe_text_part(text, type), do: [%{"type" => type, "text" => text}]

  defp translate_tools(%{"tools" => tools}) when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool, index}, {:ok, translated} ->
      case translate_tool(tool, index) do
        {:ok, tool} -> {:cont, {:ok, [tool | translated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, translated} -> {:ok, Enum.reverse(translated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_tools(%{"tools" => _tools}),
    do: {:error, Error.invalid_request("tools must be an array", "tools")}

  defp translate_tools(_payload), do: {:ok, nil}

  defp translate_tool(
         %{
           "type" => "function",
           "function" => %{"name" => name, "parameters" => parameters} = function
         },
         index
       )
       when is_binary(name) and is_map(parameters) do
    name = String.trim(name)

    if name == "" do
      invalid_tool(index)
    else
      tool = %{"type" => "function", "name" => name, "parameters" => parameters}

      tool =
        case Map.get(function, "description") do
          description when is_binary(description) -> Map.put(tool, "description", description)
          _description -> tool
        end

      {:ok, tool}
    end
  end

  defp translate_tool(_tool, index), do: invalid_tool(index)

  defp invalid_tool(index) do
    {:error,
     Error.invalid_request(
       "function tool requires a name and parameters object",
       "tools[#{index}]"
     )}
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
