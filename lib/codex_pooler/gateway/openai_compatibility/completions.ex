defmodule CodexPooler.Gateway.OpenAICompatibility.Completions do
  @moduledoc """
  Narrow legacy OpenAI Completions compatibility over canonical Responses.

  A prompt string becomes one ordinary gateway request. A non-streamed prompt
  list becomes one request per prompt so routing, retries, quota, accounting,
  and cache behavior remain truthful for every unit of upstream work.
  """

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.OpenAICompatibility.{ChatCompletions, Error, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @supported_fields ~w(model prompt max_tokens temperature top_p stop stream stream_options n)
  @always_unsupported_fields ~w(best_of logprobs echo)
  @max_stop_sequences 4

  @type coerced_request :: %{
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          required(:request_options) => RequestOptions.t(),
          required(:completion_payload) => map()
        }

  @type batch :: %{
          required(:requests) => [coerced_request()],
          required(:completion_payload) => map()
        }

  @type stream_state :: %{
          required(:chat_state) => ChatCompletions.stream_state(),
          required(:id) => String.t(),
          required(:created) => integer(),
          required(:stops) => [String.t()],
          required(:pending_text) => binary(),
          required(:visible_seen?) => boolean(),
          required(:terminal_seen?) => boolean(),
          required(:done_emitted?) => boolean(),
          required(:local_stop?) => boolean()
        }

  @spec coerce(term(), map() | keyword()) :: {:ok, coerced_request()} | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, normalized} <- prepare(payload),
         {:ok, prompt} <- single_prompt(normalized),
         {:ok, coerced} <- coerce_prompt(normalized, prompt, opts) do
      {:ok, coerced}
    end
  end

  @spec coerce_many(term(), map() | keyword()) :: {:ok, batch()} | {:error, Error.reason()}
  def coerce_many(payload, opts \\ %{}) do
    with {:ok, normalized} <- prepare(payload),
         {:ok, prompts} <- prompts(normalized),
         :ok <- reject_streamed_prompt_list(normalized, prompts),
         {:ok, requests} <- map_coerced_prompts(normalized, prompts, opts) do
      {:ok, %{requests: requests, completion_payload: normalized}}
    end
  end

  @spec normalize_response(map(), map()) :: map()
  def normalize_response(decoded, completion_payload)
      when is_map(decoded) and is_map(completion_payload) do
    normalize_responses([decoded], completion_payload)
  end

  @spec normalize_responses([map()], map()) :: map()
  def normalize_responses(decoded_responses, completion_payload)
      when is_list(decoded_responses) and is_map(completion_payload) do
    choices =
      decoded_responses
      |> Enum.with_index()
      |> Enum.map(fn {decoded, index} ->
        completion_choice(decoded, completion_payload, index)
      end)

    %{
      "id" => local_id(),
      "object" => "text_completion",
      "created" => System.system_time(:second),
      "model" => Facade.public_model(),
      "choices" => choices
    }
    |> maybe_put_usage(aggregate_usage(decoded_responses))
  end

  @spec decode_gateway_results([map()]) :: {:ok, [map()]} | {:error, Error.reason()}
  def decode_gateway_results(results) when is_list(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, decoded} ->
      case decode_gateway_result(result) do
        {:ok, body} -> {:cont, {:ok, [body | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stream_state(map()) :: stream_state()
  def stream_state(completion_payload) when is_map(completion_payload) do
    %{
      chat_state: ChatCompletions.stream_state(completion_payload),
      id: local_id(),
      created: System.system_time(:second),
      stops: normalized_stops(Map.get(completion_payload, "stop")),
      pending_text: "",
      visible_seen?: false,
      terminal_seen?: false,
      done_emitted?: false,
      local_stop?: false
    }
  end

  @spec visible_seen?(stream_state()) :: boolean()
  def visible_seen?(%{visible_seen?: value}) when is_boolean(value), do: value
  def visible_seen?(_state), do: false

  @spec terminal_seen?(stream_state()) :: boolean()
  def terminal_seen?(%{terminal_seen?: value}) when is_boolean(value), do: value
  def terminal_seen?(_state), do: false

  @spec synthetic_terminal_failure_chunk(stream_state(), String.t()) ::
          {binary(), stream_state()}
  def synthetic_terminal_failure_chunk(state, message) when is_binary(message) do
    payload = %{
      "error" => %{
        "message" => message,
        "type" => "server_error",
        "code" => "server_error",
        "param" => nil
      }
    }

    {sse(payload), %{state | terminal_seen?: true, done_emitted?: true}}
  end

  @spec normalize_stream_data(binary(), stream_state()) :: {binary(), stream_state()}
  def normalize_stream_data(_data, %{done_emitted?: true} = state), do: {"", state}

  def normalize_stream_data(data, %{chat_state: chat_state} = state) when is_binary(data) do
    {chat_output, chat_state} = ChatCompletions.normalize_stream_data(data, chat_state)

    {output, state} =
      chat_output
      |> complete_sse_blocks()
      |> Enum.reduce({[], %{state | chat_state: chat_state}}, &project_chat_block/2)

    {IO.iodata_to_binary(output), state}
  end

  def normalize_stream_data(data, state), do: {data, state}

  defp prepare(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- reject_unsupported_fields(payload),
         {:ok, _prompts} <- prompts(payload),
         :ok <- validate_stream(payload),
         :ok <- validate_stream_options(payload),
         :ok <- validate_max_tokens(payload),
         :ok <- validate_temperature(payload),
         :ok <- validate_top_p(payload),
         :ok <- validate_stop(payload),
         :ok <- validate_n(payload) do
      {:ok, payload}
    end
  end

  defp reject_unsupported_fields(payload) do
    field =
      Enum.find(@always_unsupported_fields, &Map.has_key?(payload, &1)) ||
        payload |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in @supported_fields))

    if is_binary(field), do: {:error, Error.unsupported_parameter(field)}, else: :ok
  end

  defp prompts(%{"prompt" => prompt}) when is_binary(prompt), do: {:ok, [prompt]}

  defp prompts(%{"prompt" => prompts}) when is_list(prompts) and prompts != [] do
    if Enum.all?(prompts, &is_binary/1),
      do: {:ok, prompts},
      else: {:error, Error.invalid_request("prompt must contain only strings", "prompt")}
  end

  defp prompts(%{"prompt" => _prompt}),
    do:
      {:error,
       Error.invalid_request("prompt must be a string or non-empty string array", "prompt")}

  defp prompts(_payload), do: {:error, Error.invalid_request("prompt is required", "prompt")}

  defp single_prompt(%{"prompt" => prompt}) when is_binary(prompt), do: {:ok, prompt}

  defp single_prompt(_payload),
    do: {:error, Error.invalid_request("prompt list requires batch execution", "prompt")}

  defp reject_streamed_prompt_list(%{"stream" => true, "prompt" => prompts}, _normalized)
       when is_list(prompts),
       do:
         {:error, Error.invalid_request("streaming is not supported for prompt arrays", "prompt")}

  defp reject_streamed_prompt_list(_payload, _prompts), do: :ok

  defp validate_stream(%{"stream" => stream}) when is_boolean(stream), do: :ok

  defp validate_stream(%{"stream" => _stream}),
    do: {:error, Error.invalid_request("stream must be a boolean", "stream")}

  defp validate_stream(_payload), do: :ok

  defp validate_stream_options(%{"stream_options" => options} = payload)
       when is_map(options) do
    case options |> Map.keys() |> Enum.reject(&(&1 == "include_usage")) |> Enum.sort() do
      [] ->
        validate_include_usage(Map.get(options, "include_usage"), payload)

      [field | _rest] ->
        {:error, Error.unsupported_parameter("stream_options." <> field)}
    end
  end

  defp validate_stream_options(%{"stream_options" => _options}),
    do: {:error, Error.invalid_request("stream_options must be an object", "stream_options")}

  defp validate_stream_options(_payload), do: :ok

  defp validate_include_usage(nil, _payload), do: :ok
  defp validate_include_usage(value, %{"stream" => true}) when is_boolean(value), do: :ok

  defp validate_include_usage(value, _payload) when is_boolean(value),
    do:
      {:error,
       Error.invalid_request(
         "stream_options requires stream=true",
         "stream_options"
       )}

  defp validate_include_usage(_value, _payload),
    do:
      {:error,
       Error.invalid_request(
         "stream_options.include_usage must be a boolean",
         "stream_options.include_usage"
       )}

  defp validate_max_tokens(%{"max_tokens" => value}) when is_integer(value) and value > 0,
    do: :ok

  defp validate_max_tokens(%{"max_tokens" => _value}),
    do: {:error, Error.invalid_request("max_tokens must be a positive integer", "max_tokens")}

  defp validate_max_tokens(_payload), do: :ok

  defp validate_temperature(%{"temperature" => value})
       when is_number(value) and value >= 0 and value <= 2,
       do: :ok

  defp validate_temperature(%{"temperature" => _value}),
    do: {:error, Error.invalid_request("temperature must be between 0 and 2", "temperature")}

  defp validate_temperature(_payload), do: :ok

  defp validate_top_p(%{"top_p" => value}) when is_number(value) and value >= 0 and value <= 1,
    do: :ok

  defp validate_top_p(%{"top_p" => _value}),
    do: {:error, Error.invalid_request("top_p must be between 0 and 1", "top_p")}

  defp validate_top_p(_payload), do: :ok

  defp validate_stop(%{"stop" => value}) when is_binary(value) do
    if value == "",
      do: {:error, Error.invalid_request("stop must not be empty", "stop")},
      else: :ok
  end

  defp validate_stop(%{"stop" => stops}) when is_list(stops) do
    if stops != [] and length(stops) <= @max_stop_sequences and
         Enum.all?(stops, &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error, Error.invalid_request("stop must contain one to four non-empty strings", "stop")}
    end
  end

  defp validate_stop(%{"stop" => nil}), do: :ok

  defp validate_stop(%{"stop" => _value}),
    do: {:error, Error.invalid_request("stop must be a string or string array", "stop")}

  defp validate_stop(_payload), do: :ok

  defp validate_n(%{"n" => 1}), do: :ok

  defp validate_n(%{"n" => value}) when is_integer(value) and value > 1,
    do: {:error, Error.unsupported_parameter("n")}

  defp validate_n(%{"n" => _value}),
    do: {:error, Error.invalid_request("n must be 1", "n")}

  defp validate_n(_payload), do: :ok

  defp map_coerced_prompts(payload, prompts, opts) do
    Enum.reduce_while(prompts, {:ok, []}, fn prompt, {:ok, requests} ->
      case coerce_prompt(payload, prompt, opts) do
        {:ok, request} -> {:cont, {:ok, [request | requests]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, requests} -> {:ok, Enum.reverse(requests)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp coerce_prompt(completion_payload, prompt, opts) do
    response_payload =
      %{
        "input" => prompt,
        "stream" => Map.get(completion_payload, "stream", false)
      }
      |> maybe_put(completion_payload, "model")
      |> maybe_rename(completion_payload, "max_tokens", "max_output_tokens")
      |> maybe_put(completion_payload, "temperature")
      |> maybe_put(completion_payload, "top_p")

    with {:ok, coerced} <- Responses.coerce(response_payload, opts) do
      request_options =
        RequestOptions.put_openai_compatibility(coerced.request_options,
          completion_payload: completion_payload
        )

      {:ok,
       coerced
       |> Map.put(:request_options, request_options)
       |> Map.put(:completion_payload, completion_payload)}
    end
  end

  defp maybe_put(target, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(target, key, value)
      :error -> target
    end
  end

  defp maybe_rename(target, source, source_key, target_key) do
    case Map.fetch(source, source_key) do
      {:ok, value} -> Map.put(target, target_key, value)
      :error -> target
    end
  end

  defp completion_choice(decoded, completion_payload, index) do
    normalized = ChatCompletions.normalize_response(decoded, completion_payload)
    source_choice = normalized |> Map.get("choices", []) |> List.first() || %{}
    source_message = Map.get(source_choice, "message", %{})
    text = Map.get(source_message, "content", "")
    {text, stopped?} = truncate_at_stop(text, normalized_stops(completion_payload["stop"]))

    %{
      "text" => text,
      "index" => index,
      "logprobs" => nil,
      "finish_reason" => if(stopped?, do: "stop", else: Map.get(source_choice, "finish_reason"))
    }
  end

  defp aggregate_usage(decoded_responses) do
    usages =
      Enum.flat_map(decoded_responses, fn decoded ->
        normalized = ChatCompletions.normalize_response(decoded, %{})

        case Map.get(normalized, "usage") do
          %{} = usage -> [usage]
          _usage -> []
        end
      end)

    if usages == [] do
      nil
    else
      %{
        "prompt_tokens" => sum_usage(usages, "prompt_tokens"),
        "completion_tokens" => sum_usage(usages, "completion_tokens"),
        "total_tokens" => sum_usage(usages, "total_tokens")
      }
    end
  end

  defp sum_usage(usages, field) do
    Enum.reduce(usages, 0, fn usage, total ->
      case Map.get(usage, field) do
        value when is_integer(value) and value >= 0 -> total + value
        _value -> total
      end
    end)
  end

  defp maybe_put_usage(payload, nil), do: payload
  defp maybe_put_usage(payload, usage), do: Map.put(payload, "usage", usage)

  defp decode_gateway_result(%{status: status, raw_body: body})
       when status in 200..299 and is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _invalid -> {:error, Error.reason(502, "upstream_error", "gemma3 request failed")}
    end
  end

  defp decode_gateway_result(%{status: status, body: %{} = body}) when status in 200..299,
    do: {:ok, body}

  defp decode_gateway_result(_result),
    do: {:error, Error.reason(502, "upstream_error", "gemma3 request failed")}

  defp complete_sse_blocks(""), do: []

  defp complete_sse_blocks(output) do
    String.split(output, ~r/\r?\n\r?\n/, trim: true)
  end

  defp project_chat_block(_block, {output, %{done_emitted?: true} = state}),
    do: {output, state}

  defp project_chat_block("data: [DONE]", {output, state}) do
    {flushed, state} = flush_pending(state)
    {[output, flushed, "data: [DONE]\n\n"], %{state | done_emitted?: true}}
  end

  defp project_chat_block(block, {output, state}) do
    case decode_sse_block(block) do
      {:ok, %{"error" => _error} = payload} ->
        {[output, sse(payload)], %{state | pending_text: "", terminal_seen?: true}}

      {:ok, %{} = payload} ->
        project_chat_payload(payload, output, state)

      :error ->
        {output, state}
    end
  end

  defp project_chat_payload(%{"choices" => []} = payload, output, state) do
    case Map.get(payload, "usage") do
      %{} = usage -> {[output, sse(stream_payload(state, [], usage))], state}
      _usage -> {output, state}
    end
  end

  defp project_chat_payload(%{"choices" => [choice | _rest]}, output, state)
       when is_map(choice) do
    text = get_in(choice, ["delta", "content"])
    finish_reason = Map.get(choice, "finish_reason")

    cond do
      is_binary(text) and text != "" ->
        {projected, state} = project_text_delta(text, state)
        {[output, projected], state}

      is_binary(finish_reason) ->
        {flushed, state} = flush_pending(state)
        finish = sse(stream_payload(state, [stream_choice("", finish_reason)]))
        {[output, flushed, finish], %{state | terminal_seen?: true}}

      true ->
        {output, state}
    end
  end

  defp project_chat_payload(_payload, output, state), do: {output, state}

  defp project_text_delta(text, %{stops: []} = state) do
    payload = sse(stream_payload(state, [stream_choice(text, nil)]))
    {payload, %{state | visible_seen?: true}}
  end

  defp project_text_delta(text, state) do
    pending = state.pending_text <> text

    case earliest_stop(pending, state.stops) do
      {index, _stop} ->
        visible = binary_part(pending, 0, index)

        visible_chunk =
          if visible == "",
            do: [],
            else: sse(stream_payload(state, [stream_choice(visible, nil)]))

        finish = sse(stream_payload(state, [stream_choice("", "stop")]))

        {[visible_chunk, finish, "data: [DONE]\n\n"],
         %{
           state
           | pending_text: "",
             visible_seen?: state.visible_seen? or visible != "",
             terminal_seen?: true,
             done_emitted?: true,
             local_stop?: true
         }}

      nil ->
        {visible, retained} = retain_stop_prefix(pending, state.stops)

        chunk =
          if visible == "",
            do: [],
            else: sse(stream_payload(state, [stream_choice(visible, nil)]))

        {chunk,
         %{
           state
           | pending_text: retained,
             visible_seen?: state.visible_seen? or visible != ""
         }}
    end
  end

  defp flush_pending(%{pending_text: ""} = state), do: {[], state}

  defp flush_pending(state) do
    chunk = sse(stream_payload(state, [stream_choice(state.pending_text, nil)]))
    {chunk, %{state | pending_text: "", visible_seen?: true}}
  end

  defp stream_payload(state, choices, usage \\ nil) do
    %{
      "id" => state.id,
      "object" => "text_completion",
      "created" => state.created,
      "model" => Facade.public_model(),
      "choices" => choices
    }
    |> maybe_put_usage(usage)
  end

  defp stream_choice(text, finish_reason) do
    %{
      "text" => text,
      "index" => 0,
      "logprobs" => nil,
      "finish_reason" => finish_reason
    }
  end

  defp decode_sse_block(block) do
    case String.split(block, "data: ", parts: 2) do
      [_prefix, data] ->
        case Jason.decode(data) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          _invalid -> :error
        end

      _parts ->
        :error
    end
  end

  defp sse(payload), do: ["data: ", Jason.encode!(payload), "\n\n"] |> IO.iodata_to_binary()

  defp normalized_stops(nil), do: []
  defp normalized_stops(stop) when is_binary(stop), do: [stop]
  defp normalized_stops(stops) when is_list(stops), do: stops
  defp normalized_stops(_stops), do: []

  defp truncate_at_stop(text, stops) when is_binary(text) do
    case earliest_stop(text, stops) do
      {index, _stop} -> {binary_part(text, 0, index), true}
      nil -> {text, false}
    end
  end

  defp earliest_stop(_text, []), do: nil

  defp earliest_stop(text, stops) do
    stops
    |> Enum.flat_map(fn stop ->
      case :binary.match(text, stop) do
        {index, _length} -> [{index, stop}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(fn {index, stop} -> {index, -byte_size(stop)} end, fn -> nil end)
  end

  defp retain_stop_prefix(text, stops) do
    retain_bytes = stops |> Enum.map(&byte_size/1) |> Enum.max(fn -> 1 end) |> Kernel.-(1)
    desired_prefix_bytes = max(byte_size(text) - retain_bytes, 0)
    split_valid_utf8_prefix(text, desired_prefix_bytes)
  end

  defp split_valid_utf8_prefix(text, desired) when desired <= 0, do: {"", text}

  defp split_valid_utf8_prefix(text, desired) do
    prefix = binary_part(text, 0, desired)

    if String.valid?(prefix) do
      {prefix, binary_part(text, desired, byte_size(text) - desired)}
    else
      split_valid_utf8_prefix(text, desired - 1)
    end
  end

  defp local_id, do: "cmpl_" <> Ecto.UUID.generate()
end
