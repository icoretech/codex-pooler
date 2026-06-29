defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamStream do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses

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
  def terminal_outcome(%{public_openai_responses: stream_state}) do
    case PublicResponses.terminal_kind(stream_state) do
      :failed ->
        failure = PublicResponses.terminal_failure(stream_state)

        {:failed, failure}

      kind when kind in [:completed, :incomplete] ->
        kind

      _kind ->
        nil
    end
  end

  def terminal_outcome(_state), do: nil

  @spec synthetic_terminal_failure(state(), term()) :: {binary() | nil, state()}
  def synthetic_terminal_failure(
        %{public_openai_responses: stream_state} = state,
        reason
      ) do
    if PublicResponses.visible_seen?(stream_state) and
         is_nil(PublicResponses.terminal_kind(stream_state)) do
      data =
        StreamProtocol.synthetic_public_openai_responses_failure_sse(
          PublicResponses.response_id(stream_state),
          reason
        )

      stream_state = PublicResponses.mark_synthetic_terminal_failure(stream_state)

      {data, %{state | public_openai_responses: stream_state}}
    else
      {nil, state}
    end
  end

  def synthetic_terminal_failure(state, _reason), do: {nil, state}

  @spec terminal_missing_interruption_reason(state(), term()) :: term()
  def terminal_missing_interruption_reason(_state, {:upstream_idle_timeout, _reason} = reason),
    do: reason

  def terminal_missing_interruption_reason(
        %{public_openai_responses: stream_state},
        original_reason
      ) do
    if PublicResponses.visible_seen?(stream_state) and
         is_nil(PublicResponses.terminal_kind(stream_state)) do
      {:upstream_stream_interrupted, original_reason}
    else
      original_reason
    end
  end

  def terminal_missing_interruption_reason(_state, original_reason), do: original_reason

  @spec public_openai_responses_stream_metadata(state()) :: map()
  def public_openai_responses_stream_metadata(%{public_openai_responses: stream_state}) do
    %{
      "public_openai_responses_stream" => PublicResponses.summary_metadata(stream_state)
    }
  end

  def public_openai_responses_stream_metadata(_state), do: %{}

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

    {data, state}
  end

  defp normalize_public_openai_responses_stream_data(data, state), do: {data, state}

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
end
