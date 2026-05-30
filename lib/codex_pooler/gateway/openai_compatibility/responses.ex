defmodule CodexPooler.Gateway.OpenAICompatibility.Responses do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Matrix, Validation}
  alias CodexPooler.Gateway.Payloads.{InputShape, RequestOptions, StrictSchema, ToolResultShape}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @reasoning_efforts ~w(none minimal low medium high xhigh)
  @reasoning_summaries ~w(auto concise detailed)
  @service_tiers ~w(auto default flex priority scale ultrafast)
  @locally_unsupported_fields ~w(background context_management conversation max_tool_calls prompt top_logprobs truncation user)
  @input_audio_formats ~w(mp3 wav)

  @endpoint "/backend-api/codex/responses"

  @spec validate(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :responses),
         :ok <- Validation.require_model(payload),
         :ok <- reject_locally_unsupported_fields(payload),
         {:ok, payload} <- normalize_recoverable_opencode_replay_call_ids(payload),
         :ok <- validate_input(payload),
         :ok <- validate_previous_response_continuation(payload),
         :ok <- validate_tools(payload),
         :ok <- validate_tool_choice(payload),
         :ok <- validate_max_output_tokens(payload),
         :ok <- validate_reasoning(payload),
         :ok <- validate_service_tier(payload),
         :ok <- validate_stream_options(payload),
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
           |> Map.take(Matrix.forwarded_fields(:responses))
           |> normalize_forwarded_enums()
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

  defp normalize_recoverable_opencode_replay_call_ids(%{"input" => input} = payload)
       when is_list(input) do
    {:ok, Map.put(payload, "input", normalize_recoverable_opencode_replay_items(input))}
  end

  defp normalize_recoverable_opencode_replay_call_ids(payload), do: {:ok, payload}

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
  defp normalize_input_item(%{"type" => "reasoning"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "function_call"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "function_call_output"} = item), do: {:ok, item}

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

  defp backend_streaming_required?(%RequestOptions{openai_compatibility: compatibility}) do
    compatibility.collect_openai_response_stream or compatibility.public_openai_responses_stream or
      compatibility.public_openai_chat_stream
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

    cond do
      output_items != [] ->
        Map.put(response, "output", output_items)

      output_text = output_text_from_events(events) ->
        Map.put(response, "output", [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => output_text}]}
        ])

      true ->
        response
    end
  end

  defp output_text_from_events(events) do
    deltas =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_text.delta", "delta" => delta} when is_binary(delta) ->
          [delta]

        _event ->
          []
      end)

    done_texts =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_text.done", "text" => text} when is_binary(text) -> [text]
        _event -> []
      end)

    [deltas, done_texts]
    |> Enum.find(&(&1 != []))
    |> case do
      nil -> nil
      parts -> Enum.join(parts)
    end
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

  defp reject_locally_unsupported_fields(payload) do
    payload
    |> Map.keys()
    |> Enum.find(&(&1 in @locally_unsupported_fields))
    |> case do
      nil -> :ok
      field -> {:error, Error.unsupported_parameter(field)}
    end
  end

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

  defp validate_previous_response_continuation(%{"previous_response_id" => response_id} = payload)
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

  defp validate_previous_response_continuation(%{"previous_response_id" => _response_id}),
    do:
      {:error,
       Error.invalid_request(
         "previous_response_id requires a tool-output continuation",
         "previous_response_id"
       )}

  defp validate_previous_response_continuation(_payload), do: :ok

  defp validate_reasoning(%{"reasoning" => reasoning}) when is_map(reasoning) do
    reasoning
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> validate_reasoning_map()
  end

  defp validate_reasoning(%{"reasoning" => _reasoning}),
    do: {:error, Error.invalid_request("reasoning must be an object", "reasoning")}

  defp validate_reasoning(_payload), do: :ok

  defp validate_max_output_tokens(%{"max_output_tokens" => value})
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_max_output_tokens(%{"max_output_tokens" => _value}),
    do:
      {:error,
       Error.invalid_request("max_output_tokens must be a positive integer", "max_output_tokens")}

  defp validate_max_output_tokens(_payload), do: :ok

  defp validate_reasoning_map(reasoning) do
    with :ok <- validate_reasoning_keys(reasoning),
         :ok <- validate_reasoning_effort(Map.get(reasoning, "effort")) do
      validate_reasoning_summary(Map.get(reasoning, "summary"))
    end
  end

  defp validate_reasoning_keys(reasoning) do
    case reasoning |> Map.keys() |> Enum.reject(&(&1 in ["effort", "summary"])) do
      [] ->
        :ok

      [key | _rest] ->
        {:error, Error.invalid_request("reasoning field is not supported", "reasoning." <> key)}
    end
  end

  defp validate_reasoning_effort(nil), do: :ok

  defp validate_reasoning_effort(effort) when is_binary(effort) do
    normalized = effort |> String.trim() |> String.downcase()

    if normalized in @reasoning_efforts do
      :ok
    else
      {:error, Error.invalid_request("reasoning effort is not supported", "reasoning.effort")}
    end
  end

  defp validate_reasoning_effort(_effort),
    do: {:error, Error.invalid_request("reasoning effort is not supported", "reasoning.effort")}

  defp validate_reasoning_summary(nil), do: :ok

  defp validate_reasoning_summary(summary) when is_binary(summary) do
    normalized = summary |> String.trim() |> String.downcase()

    if normalized in @reasoning_summaries do
      :ok
    else
      {:error, Error.invalid_request("reasoning summary is not supported", "reasoning.summary")}
    end
  end

  defp validate_reasoning_summary(_summary),
    do: {:error, Error.invalid_request("reasoning summary is not supported", "reasoning.summary")}

  defp validate_service_tier(%{"service_tier" => tier}) when is_binary(tier) do
    normalized = tier |> String.trim() |> String.downcase()

    if normalized in @service_tiers do
      :ok
    else
      {:error, Error.invalid_request("service_tier is not supported", "service_tier")}
    end
  end

  defp validate_service_tier(%{"service_tier" => _tier}),
    do: {:error, Error.invalid_request("service_tier is not supported", "service_tier")}

  defp validate_service_tier(_payload), do: :ok

  defp validate_stream_options(%{"stream_options" => options}) when is_map(options) do
    with :ok <- validate_stream_option_keys(options, ["include_obfuscation"]) do
      case Map.get(options, "include_obfuscation") do
        nil ->
          :ok

        value when is_boolean(value) ->
          :ok

        _value ->
          {:error,
           Error.invalid_request(
             "stream_options.include_obfuscation must be a boolean",
             "stream_options.include_obfuscation"
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

  defp normalize_forwarded_enums(payload) do
    payload
    |> normalize_string_field("service_tier")
    |> normalize_reasoning_fields()
  end

  defp normalize_string_field(payload, field) do
    case Map.fetch(payload, field) do
      {:ok, value} when is_binary(value) -> Map.put(payload, field, normalize_enum(value))
      _other -> payload
    end
  end

  defp normalize_reasoning_fields(%{"reasoning" => reasoning} = payload) when is_map(reasoning) do
    reasoning =
      reasoning
      |> normalize_string_field("effort")
      |> normalize_string_field("summary")

    Map.put(payload, "reasoning", reasoning)
  end

  defp normalize_reasoning_fields(payload), do: payload

  defp normalize_enum(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp bare_item_reference?(item),
    do: map_size(item) == 2 and Map.has_key?(item, "id") and Map.has_key?(item, "type")

  defp previous_response_id?(%{"previous_response_id" => value}) when is_binary(value),
    do: String.trim(value) != ""

  defp previous_response_id?(_payload), do: false

  defp validate_assistant_replay_item(%{"role" => "assistant", "content" => content} = item) do
    with :ok <- validate_exact_item_keys(item, ["type", "role", "content", "id", "phase"]),
         :ok <- validate_optional_id(item),
         :ok <- validate_optional_assistant_phase(item) do
      validate_assistant_replay_content(content)
    end
  end

  defp validate_assistant_replay_item(_item),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_assistant_replay_content(content) when is_list(content) and content != [] do
    Enum.reduce_while(content, :ok, fn part, _acc ->
      case validate_assistant_replay_content_part(part) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
    Enum.reduce_while(summary, :ok, fn part, _acc ->
      case validate_reasoning_replay_summary_part(part) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
    with :ok <- validate_exact_item_keys(item, ["type", "call_id", "name", "arguments", "id"]),
         :ok <- validate_nonblank(call_id),
         :ok <- validate_nonblank(name) do
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

  defp validate_function_call_output(output) when is_binary(output), do: :ok

  defp validate_function_call_output(output) when is_list(output) do
    Enum.reduce_while(output, :ok, fn part, _acc ->
      case validate_function_call_output_part(part) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_function_call_output(_output),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_function_call_output_part(%{"type" => "input_text", "text" => text} = part)
       when is_binary(text) do
    validate_exact_item_keys(part, ["type", "text"])
  end

  defp validate_function_call_output_part(
         %{"type" => "input_image", "image_url" => image_url} = part
       )
       when is_binary(image_url) do
    validate_exact_item_keys(part, ["type", "image_url"])
  end

  defp validate_function_call_output_part(_part),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_id(%{"id" => id}) when is_binary(id), do: validate_nonblank(id)

  defp validate_optional_id(%{"id" => _id}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp validate_optional_id(_item), do: :ok

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

  defp validate_tool(%{"namespace" => _namespace}),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp validate_tool(%{"deferred" => _deferred}),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp validate_tool(%{"type" => "function", "name" => name, "parameters" => parameters})
       when is_binary(name) and is_map(parameters) do
    if String.trim(name) == "",
      do: {:error, Error.invalid_request("function tool requires a non-empty name", "tools")},
      else: :ok
  end

  defp validate_tool(%{"type" => "function"}),
    do:
      {:error, Error.invalid_request("function tool requires flat name and parameters", "tools")}

  defp validate_tool(%{"type" => "web_search_preview"} = tool),
    do: validate_exact_builtin_tool(tool, ["type"])

  defp validate_tool(
         %{"type" => "image_generation", "model" => model, "size" => size, "quality" => quality} =
           tool
       )
       when is_binary(model) and is_binary(size) and is_binary(quality),
       do:
         validate_exact_builtin_tool(tool, [
           "type",
           "model",
           "size",
           "quality",
           "background",
           "input_fidelity"
         ])

  defp validate_tool(%{"type" => "image_generation"} = tool),
    do: validate_exact_builtin_tool(tool, ["type"])

  defp validate_tool(_tool),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp validate_exact_builtin_tool(tool, allowed_keys) do
    case tool |> Map.keys() |> Enum.reject(&(&1 in allowed_keys)) do
      [] -> :ok
      [_key | _rest] -> {:error, Error.invalid_request("tool shape is not translatable", "tools")}
    end
  end

  defp validate_tool_choice(%{"tool_choice" => choice})
       when choice in ["auto", "none", "required"],
       do: :ok

  defp validate_tool_choice(%{"tool_choice" => %{"type" => "function", "name" => name}} = payload)
       when is_binary(name) do
    validate_named_tool_choice(payload, name)
  end

  defp validate_tool_choice(%{"tool_choice" => %{"type" => "image_generation"}}), do: :ok

  defp validate_tool_choice(%{"tool_choice" => %{"type" => "function"}}),
    do:
      {:error,
       Error.invalid_request("tool_choice function requires a non-empty name", "tool_choice")}

  defp validate_tool_choice(%{"tool_choice" => _choice}),
    do: {:error, Error.invalid_request("tool_choice shape is not translatable", "tool_choice")}

  defp validate_tool_choice(_payload), do: :ok

  defp validate_named_tool_choice(payload, name) do
    cond do
      String.trim(name) == "" ->
        {:error,
         Error.invalid_request("tool_choice function requires a non-empty name", "tool_choice")}

      name in function_tool_names(payload) ->
        :ok

      true ->
        {:error,
         Error.invalid_request("tool_choice references unknown function tool", "tool_choice")}
    end
  end

  defp function_tool_names(%{"tools" => tools}) when is_list(tools) do
    Enum.flat_map(tools, fn
      %{"type" => "function", "name" => name} when is_binary(name) -> [name]
      _tool -> []
    end)
  end

  defp function_tool_names(_payload), do: []
end
