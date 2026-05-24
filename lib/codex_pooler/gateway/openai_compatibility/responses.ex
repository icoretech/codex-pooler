defmodule CodexPooler.Gateway.OpenAICompatibility.Responses do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Matrix, Validation}
  alias CodexPooler.Gateway.Payloads.{InputShape, RequestOptions, StrictSchema, ToolResultShape}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @endpoint "/backend-api/codex/responses"

  @spec validate(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :responses),
         :ok <- Validation.require_model(payload),
         :ok <- validate_input(payload),
         :ok <- validate_tools(payload),
         :ok <- validate_tool_choice(payload),
         :ok <- StrictSchema.validate(payload),
         :ok <- InputShape.validate(payload) do
      {:ok, payload}
    end
  end

  @spec coerce(term(), map() | keyword()) ::
          {:ok, %{endpoint: String.t(), payload: map(), request_options: RequestOptions.t()}}
          | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, payload} <- validate(payload),
         {:ok, payload} <-
           payload
           |> Map.take(Matrix.supported_fields(:responses))
           |> normalize_input() do
      payload =
        maybe_force_backend_streaming(payload, opts)

      request_options = RequestOptions.build(opts, @endpoint, payload)
      {:ok, %{endpoint: @endpoint, payload: payload, request_options: request_options}}
    end
  end

  @spec response_from_sse(binary()) :: {:ok, map()} | {:error, Error.reason()}
  def response_from_sse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        {:ok, Map.put_new(decoded, "object", "response")}

      _error ->
        body |> decoded_sse_events() |> response_from_sse_events()
    end
  end

  defp response_from_sse_events(events) do
    with {:ok, response, event} <- terminal_response(events) do
      response =
        response
        |> Map.put_new("object", "response")
        |> maybe_backfill_output(events)

      terminal_error(event, response) || {:ok, response}
    end
  end

  defp normalize_input(%{"input" => input} = payload) when is_binary(input) do
    {:ok, Map.put(payload, "input", [input_text_message(input)])}
  end

  defp normalize_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_input_items(input) do
      {:ok, Map.put(payload, "input", input)}
    end
  end

  defp normalize_input(payload), do: {:ok, payload}

  defp normalize_input_items(input) do
    Enum.reduce_while(input, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_input_item(item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, input} -> {:ok, Enum.reverse(input)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_input_item(%{"content" => content} = item) when is_binary(content) do
    item =
      item
      |> Map.put("type", "message")
      |> Map.put_new("role", "user")
      |> Map.put("content", [%{"type" => "input_text", "text" => content}])

    {:ok, item}
  end

  defp normalize_input_item(%{"content" => content} = item) when is_list(content) do
    {:ok, item |> Map.put("type", "message") |> Map.put_new("role", "user")}
  end

  defp normalize_input_item(%{"role" => _role} = item),
    do: {:ok, Map.put_new(item, "type", "message")}

  defp normalize_input_item(%{"type" => "input_file"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "item_reference"} = item), do: {:ok, item}

  defp normalize_input_item(%{} = item) do
    if ToolResultShape.tool_result?(item) do
      {:ok, item}
    else
      {:error, Error.invalid_request("input item shape is not translatable", "input")}
    end
  end

  defp input_text_message(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp maybe_force_backend_streaming(payload, opts) do
    if backend_streaming_required?(opts) do
      payload
      |> Map.put("stream", true)
      |> Map.put("store", false)
    else
      payload
    end
  end

  defp backend_streaming_required?(opts) when is_map(opts) do
    Enum.any?(
      [
        :collect_openai_response_stream,
        :public_openai_responses_stream,
        :public_openai_chat_stream
      ],
      &Map.get(opts, &1)
    )
  end

  defp backend_streaming_required?(opts) when is_list(opts),
    do: backend_streaming_required?(Map.new(opts))

  defp backend_streaming_required?(_opts), do: false

  defp decoded_sse_events(body) do
    body
    |> StreamProtocol.complete_sse_blocks(bounded?: false)
    |> elem(0)
    |> Enum.map(fn block ->
      block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp terminal_response(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"response" => %{} = response} = event -> {:ok, response, event}
      _event -> nil
    end)
    |> Kernel.||(
      {:error, Error.reason(502, "upstream_response_missing", "upstream response was incomplete")}
    )
  end

  defp terminal_error(_event, %{"status" => status}) when status in ["completed", "in_progress"],
    do: nil

  defp terminal_error(event, response) do
    error = response["error"] || event["error"]

    case error do
      %{} = error ->
        status = if Map.get(error, "type") == "invalid_request_error", do: 400, else: 502

        {:error,
         Error.reason(
           status,
           Map.get(error, "code") || "upstream_error",
           Map.get(error, "message") || "upstream response failed",
           Map.get(error, "param")
         )}

      _other ->
        {:error, Error.reason(502, "upstream_error", "upstream response failed")}
    end
  end

  defp maybe_backfill_output(%{"output" => output} = response, _events) when is_list(output),
    do: response

  defp maybe_backfill_output(response, events) do
    output_items =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_item.done", "item" => %{} = item} -> [item]
        _event -> []
      end)

    if output_items == [], do: response, else: Map.put(response, "output", output_items)
  end

  defp validate_input(%{"input" => input}) when is_binary(input), do: :ok

  defp validate_input(%{"input" => input} = payload) when is_list(input) and input != [] do
    Enum.reduce_while(input, :ok, fn item, _acc ->
      case validate_input_item(item, payload) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_input(%{"input" => input}) when is_list(input),
    do: {:error, Error.invalid_request("input must be a non-empty string or array", "input")}

  defp validate_input(%{"input" => _input}),
    do: {:error, Error.invalid_request("input must be a string or array", "input")}

  defp validate_input(_payload), do: :ok

  defp validate_input_item(%{"type" => "message"} = item, _payload),
    do: validate_message_item(item)

  defp validate_input_item(%{"role" => _role} = item, _payload), do: validate_message_item(item)

  defp validate_input_item(%{"content" => _content} = item, _payload),
    do: validate_message_item(item)

  defp validate_input_item(%{"type" => "input_file", "file_id" => file_id}, _payload)
       when is_binary(file_id) and file_id != "",
       do: :ok

  defp validate_input_item(
         %{"type" => "function_call_output", "call_id" => call_id} = item,
         _payload
       )
       when is_binary(call_id) and call_id != "" do
    if Map.has_key?(item, "output") or Map.has_key?(item, "result"),
      do: :ok,
      else: {:error, Error.invalid_request("function_call_output requires output", "input")}
  end

  defp validate_input_item(%{"type" => "item_reference"} = item, payload),
    do: validate_item_reference(item, payload)

  defp validate_input_item(%{} = item, _payload) do
    if ToolResultShape.tool_result?(item),
      do: :ok,
      else: {:error, Error.invalid_request("input item shape is not translatable", "input")}
  end

  defp validate_input_item(_item, _payload),
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

  defp bare_item_reference?(item),
    do: map_size(item) == 2 and Map.has_key?(item, "id") and Map.has_key?(item, "type")

  defp previous_response_id?(%{"previous_response_id" => value}) when is_binary(value),
    do: String.trim(value) != ""

  defp previous_response_id?(_payload), do: false

  defp validate_message_item(%{"role" => role, "content" => content})
       when role in ["system", "user", "assistant", "developer", "tool"] do
    validate_message_content(content)
  end

  defp validate_message_item(%{"content" => content}), do: validate_message_content(content)

  defp validate_message_item(_item),
    do: {:error, Error.invalid_request("message input items require role and content", "input")}

  defp validate_message_content(content) when is_binary(content), do: :ok

  defp validate_message_content(content) when is_list(content) and content != [] do
    Enum.reduce_while(content, :ok, fn part, _acc ->
      case validate_message_content_part(part) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp validate_message_content_part(_part),
    do: {:error, Error.invalid_request("message content part is not translatable", "input")}

  defp validate_tools(%{"tools" => tools}) when is_list(tools) do
    Enum.reduce_while(tools, :ok, fn tool, _acc ->
      case validate_tool(tool) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_tools(%{"tools" => _tools}),
    do: {:error, Error.invalid_request("tools must be an array", "tools")}

  defp validate_tools(_payload), do: :ok

  defp validate_tool(%{
         "type" => "function",
         "function" => %{"name" => name, "parameters" => parameters}
       })
       when is_binary(name) and name != "" and is_map(parameters),
       do: :ok

  defp validate_tool(%{"type" => "function", "name" => name, "parameters" => parameters})
       when is_binary(name) and name != "" and is_map(parameters),
       do: :ok

  defp validate_tool(%{"type" => type}) when type in ["web_search_preview", "image_generation"],
    do: :ok

  defp validate_tool(_tool),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp validate_tool_choice(%{"tool_choice" => choice})
       when choice in ["auto", "none", "required"],
       do: :ok

  defp validate_tool_choice(%{
         "tool_choice" => %{"type" => "function", "function" => %{"name" => name}}
       })
       when is_binary(name) and name != "",
       do: :ok

  defp validate_tool_choice(%{"tool_choice" => %{"type" => "image_generation"}}), do: :ok

  defp validate_tool_choice(%{"tool_choice" => _choice}),
    do: {:error, Error.invalid_request("tool_choice shape is not translatable", "tool_choice")}

  defp validate_tool_choice(_payload), do: :ok
end
