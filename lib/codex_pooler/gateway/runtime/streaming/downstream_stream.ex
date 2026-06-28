defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamStream do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type state :: map()

  @spec initial_state(term(), RequestOptions.t()) :: state()
  def initial_state(target, %RequestOptions{} = opts) do
    state = %{target: target}

    cond do
      public_openai_chat_stream?(opts) ->
        Map.put(
          state,
          :public_openai_chat,
          ChatCompletions.stream_state(openai_chat_payload(opts))
        )

      public_openai_responses_stream?(opts) ->
        state
        |> Map.put(
          :public_openai_responses,
          StreamProtocol.public_openai_responses_stream_state()
        )
        |> Map.put(:public_openai_responses_data_seen?, false)
        |> Map.put(:public_openai_responses_terminal_seen?, false)
        |> Map.put(:public_openai_responses_response_id, nil)
        |> Map.put(:public_openai_responses_terminal_kind, nil)
        |> Map.put(:public_openai_responses_terminal_failure, nil)

      true ->
        state
    end
  end

  @spec endpoint(map(), RequestOptions.t()) :: String.t() | nil
  def endpoint(_payload, %RequestOptions{
        transport: %{upstream_endpoint: endpoint}
      })
      when is_binary(endpoint),
      do: endpoint

  def endpoint(_payload, _opts), do: nil

  @spec normalize_data(iodata(), String.t() | nil, RequestOptions.t(), state()) ::
          {iodata(), state()}
  def normalize_data(data, endpoint, %RequestOptions{} = opts, state) do
    cond do
      public_openai_chat_stream?(opts) ->
        normalize_public_openai_chat_stream_data(data, state)

      public_openai_responses_stream?(opts) ->
        normalize_public_openai_responses_stream_data(data, state)

      codex_responses_stream_endpoint?(endpoint) ->
        normalize_codex_responses_stream_data(data, endpoint, opts, state)

      true ->
        {normalize_endpoint_data(endpoint, data), state}
    end
  end

  @spec keepalive_allowed?(state()) :: boolean()
  def keepalive_allowed?(%{
        public_openai_responses: %{buffer: buffer, passthrough?: passthrough?}
      })
      when is_binary(buffer) and is_boolean(passthrough?) do
    buffer == "" and not passthrough?
  end

  def keepalive_allowed?(%{
        public_openai_chat: %{buffer: buffer, discarding_oversized?: discarding_oversized?}
      })
      when is_binary(buffer) and is_boolean(discarding_oversized?) do
    buffer == "" and not discarding_oversized?
  end

  def keepalive_allowed?(_state), do: true

  @spec terminal_outcome(state()) ::
          :completed | :incomplete | {:failed, StreamProtocol.terminal_failure() | nil} | nil
  def terminal_outcome(%{
        public_openai_responses_terminal_kind: :failed,
        public_openai_responses_terminal_failure: failure
      }) do
    {:failed, failure}
  end

  def terminal_outcome(%{public_openai_responses_terminal_kind: kind})
      when kind in [:completed, :incomplete],
      do: kind

  def terminal_outcome(_state), do: nil

  @spec synthetic_terminal_failure(state(), term()) :: {binary() | nil, state()}
  def synthetic_terminal_failure(
        %{
          public_openai_responses_data_seen?: true,
          public_openai_responses_terminal_seen?: false
        } = state,
        reason
      ) do
    data =
      StreamProtocol.synthetic_public_openai_responses_failure_sse(
        Map.get(state, :public_openai_responses_response_id),
        reason
      )

    {data, %{state | public_openai_responses_terminal_seen?: true}}
  end

  def synthetic_terminal_failure(state, _reason), do: {nil, state}

  @spec terminal_missing_interruption_reason(state(), term()) :: term()
  def terminal_missing_interruption_reason(_state, {:upstream_idle_timeout, _reason} = reason),
    do: reason

  def terminal_missing_interruption_reason(
        %{
          public_openai_responses_data_seen?: true,
          public_openai_responses_terminal_seen?: false
        },
        original_reason
      ) do
    {:upstream_stream_interrupted, original_reason}
  end

  def terminal_missing_interruption_reason(_state, original_reason), do: original_reason

  defp normalize_public_openai_chat_stream_data(
         data,
         %{public_openai_chat: stream_state} = state
       ) do
    {data, stream_state} = ChatCompletions.normalize_stream_data(data, stream_state)
    {data, %{state | public_openai_chat: stream_state}}
  end

  defp normalize_public_openai_chat_stream_data(data, state), do: {data, state}

  defp normalize_public_openai_responses_stream_data(
         data,
         %{public_openai_responses: stream_state} = state
       ) do
    {data, stream_state} =
      StreamProtocol.normalize_public_openai_responses_sse_data(data, stream_state)

    state =
      state
      |> Map.put(:public_openai_responses, stream_state)
      |> maybe_mark_passthrough_terminal(stream_state)
      |> track_public_openai_responses_output(data)

    {data, state}
  end

  defp normalize_public_openai_responses_stream_data(data, state), do: {data, state}

  defp maybe_mark_passthrough_terminal(state, stream_state) do
    case StreamProtocol.public_openai_responses_passthrough_terminal_kind(stream_state) do
      kind when kind in [:completed, :incomplete, :failed] ->
        state
        |> Map.put(:public_openai_responses_terminal_seen?, true)
        |> Map.put(:public_openai_responses_terminal_kind, kind)
        |> Map.put(
          :public_openai_responses_terminal_failure,
          StreamProtocol.public_openai_responses_passthrough_terminal_failure(stream_state)
        )

      _kind ->
        state
    end
  end

  defp track_public_openai_responses_output(state, data) when is_binary(data) do
    {blocks, _buffer} = StreamProtocol.complete_sse_blocks(data, bounded?: false)

    Enum.reduce(blocks, state, fn block, acc ->
      track_public_openai_responses_block(acc, block)
    end)
  end

  defp track_public_openai_responses_block(state, "data: [DONE]") do
    state
    |> Map.put(:public_openai_responses_terminal_seen?, true)
    |> Map.put(:public_openai_responses_terminal_kind, :completed)
  end

  defp track_public_openai_responses_block(state, block) do
    data = StreamProtocol.sse_field(block, "data")
    decoded = StreamProtocol.decode_sse_data(data)
    data_type = decoded_string(decoded, "type")
    event_type = StreamProtocol.sse_field(block, "event") || data_type
    event = %{event_type: event_type, data_type: data_type}

    state
    |> maybe_put_public_openai_responses_response_id(decoded)
    |> maybe_mark_public_openai_responses_data_seen(event)
    |> maybe_mark_public_openai_responses_terminal_seen(event_type, decoded)
  end

  defp normalize_codex_responses_stream_data(data, endpoint, opts, state) when is_binary(data) do
    buffer = Map.get(state, :codex_responses_sse_buffer, "")

    if buffer == "" and not codex_responses_sse_chunk?(data) do
      {data, state}
    else
      buffered_data = buffer <> data
      {blocks, buffer} = StreamProtocol.complete_sse_blocks(buffered_data, bounded?: true)

      data =
        if oversized_incomplete_sse_prefix?(blocks, buffer, buffered_data) do
          BufferTelemetry.record_oversized_incomplete(
            "codex_responses_sse",
            byte_size(buffered_data),
            StreamProtocol.max_incomplete_sse_block_bytes(),
            request_options: opts,
            endpoint: endpoint
          )

          buffered_data
        else
          blocks
          |> Enum.map(&StreamProtocol.normalize_codex_responses_sse_block/1)
          |> IO.iodata_to_binary()
        end

      {data, Map.put(state, :codex_responses_sse_buffer, buffer)}
    end
  end

  defp normalize_codex_responses_stream_data(data, _endpoint, _opts, state), do: {data, state}

  defp normalize_endpoint_data("/backend-api/codex/responses", data) when is_binary(data) do
    StreamProtocol.normalize_codex_responses_sse_data(data)
  end

  defp normalize_endpoint_data("/backend-api/codex/responses/compact", data)
       when is_binary(data) do
    StreamProtocol.normalize_codex_responses_sse_data(data)
  end

  defp normalize_endpoint_data(_endpoint, data), do: data

  defp codex_responses_stream_endpoint?("/backend-api/codex/responses"), do: true
  defp codex_responses_stream_endpoint?("/backend-api/codex/responses/compact"), do: true
  defp codex_responses_stream_endpoint?(_endpoint), do: false

  defp public_openai_responses_stream?(%RequestOptions{
         openai_compatibility: %{public_openai_responses_stream: true}
       }),
       do: true

  defp public_openai_responses_stream?(_opts), do: false

  defp codex_responses_sse_chunk?(data) when is_binary(data) do
    String.starts_with?(data, "event: ") or String.starts_with?(data, "data: ") or
      String.contains?(data, "\nevent: ") or String.contains?(data, "\ndata: ") or
      String.contains?(data, "\n\n")
  end

  defp oversized_incomplete_sse_prefix?([], "", data),
    do: StreamProtocol.oversized_incomplete_sse_block?(data)

  defp oversized_incomplete_sse_prefix?(_blocks, _buffer, _data), do: false

  defp public_openai_chat_stream?(%RequestOptions{
         openai_compatibility: %{public_openai_chat_stream: true}
       }),
       do: true

  defp public_openai_chat_stream?(_opts), do: false

  defp openai_chat_payload(%RequestOptions{
         openai_compatibility: %{openai_chat_payload: %{} = payload}
       }),
       do: payload

  defp openai_chat_payload(_opts), do: %{}

  defp maybe_put_public_openai_responses_response_id(state, decoded) do
    case response_id(decoded) do
      response_id when is_binary(response_id) ->
        %{state | public_openai_responses_response_id: response_id}

      nil ->
        state
    end
  end

  defp maybe_mark_public_openai_responses_data_seen(state, event) do
    if StreamProtocol.downstream_visible_event?(event) and
         is_nil(StreamProtocol.terminal_outcome_event(event)) do
      %{state | public_openai_responses_data_seen?: true}
    else
      state
    end
  end

  defp maybe_mark_public_openai_responses_terminal_seen(state, event_type, decoded) do
    case StreamProtocol.terminal_outcome(event_type, decoded) do
      {:ok, %{kind: :failed, failure: failure}} ->
        state
        |> Map.put(:public_openai_responses_terminal_seen?, true)
        |> Map.put(:public_openai_responses_terminal_kind, :failed)
        |> Map.put(:public_openai_responses_terminal_failure, failure)

      {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
        state
        |> Map.put(:public_openai_responses_terminal_seen?, true)
        |> Map.put(:public_openai_responses_terminal_kind, kind)

      _outcome ->
        state
    end
  end

  defp response_id(decoded) when is_map(decoded) do
    nested_string(decoded, ["response", "id"]) || decoded_string(decoded, "id")
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp nested_string(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:cont, value}
        _other -> {:halt, nil}
      end
    end)
    |> case do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end
end
