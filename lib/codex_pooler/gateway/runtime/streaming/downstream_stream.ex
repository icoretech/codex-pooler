defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamStream do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{ChatCompletions, Completions}
  alias CodexPooler.Gateway.Facade.Anthropic.Stream, as: AnthropicStream
  alias CodexPooler.Gateway.Facade.PublicProjection
  alias CodexPooler.Gateway.Facade.Ollama.Stream, as: OllamaStream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @max_codex_iodata_bytes 64 * 1024 * 1024
  @max_codex_iodata_depth 128
  @max_codex_iodata_nodes 1_000_000
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses

  @type state :: map()
  @type source :: :http | :websocket_bridge

  @spec initial_state(term(), RequestOptions.t()) :: state()
  def initial_state(target, %RequestOptions{} = opts), do: initial_state(target, opts, :http)

  @spec initial_state(term(), RequestOptions.t(), source()) :: state()
  def initial_state(target, %RequestOptions{} = opts, source)
      when source in [:http, :websocket_bridge] do
    state = %{target: target}

    state =
      if source == :websocket_bridge, do: Map.put(state, :bridge_committed?, true), else: state

    cond do
      public_anthropic_stream?(opts) ->
        Map.put(
          state,
          :public_anthropic,
          AnthropicStream.new(opts.openai_compatibility.anthropic_formatting)
        )

      public_ollama_stream?(opts) ->
        Map.put(
          state,
          :public_ollama,
          OllamaStream.new(opts.openai_compatibility.ollama_formatting)
        )

      public_openai_completions_stream?(opts) ->
        Map.put(
          state,
          :public_openai_completions,
          Completions.stream_state(openai_completion_payload(opts))
        )

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
          StreamProtocol.public_openai_responses_stream_state(
            opts.openai_compatibility.custom_tool_namespaces
          )
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
      public_anthropic_stream?(opts) ->
        normalize_public_anthropic_stream_data(data, state)

      public_ollama_stream?(opts) ->
        normalize_public_ollama_stream_data(data, state)

      public_openai_completions_stream?(opts) ->
        normalize_public_openai_completions_stream_data(data, state)

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
  def keepalive_allowed?(%{public_anthropic: %{buffer: buffer}}) when is_binary(buffer),
    do: buffer == ""

  def keepalive_allowed?(%{public_ollama: %{buffer: buffer}}) when is_binary(buffer),
    do: buffer == ""

  def keepalive_allowed?(%{
        public_openai_completions: %{
          chat_state: %{buffer: buffer, discarding_oversized?: discarding_oversized?}
        }
      })
      when is_binary(buffer) and is_boolean(discarding_oversized?) do
    buffer == "" and not discarding_oversized?
  end

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
  def terminal_outcome(%{public_anthropic: stream_state}),
    do: AnthropicStream.terminal_outcome(stream_state)

  def terminal_outcome(%{public_ollama: stream_state}),
    do: OllamaStream.terminal_outcome(stream_state)

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

  def terminal_outcome(%{codex_responses_failure: %{} = failure}),
    do: {:failed, failure}

  def terminal_outcome(_state), do: nil

  @spec finalize_eof(state()) :: state()
  def finalize_eof(%{codex_responses_failure: %{} = _failure} = state), do: state

  def finalize_eof(%{codex_responses_sse_buffer: buffer} = state)
      when is_binary(buffer) and buffer != "" do
    {_data, state} = fail_codex_stream(state, "upstream_stream_invalid")
    state
  end

  def finalize_eof(state), do: state

  @spec synthetic_terminal_failure(state(), term()) :: {binary() | nil, state()}
  def synthetic_terminal_failure(%{public_anthropic: stream_state} = state, _reason) do
    {data, stream_state} = AnthropicStream.synthetic_terminal_failure(stream_state)
    {data, %{state | public_anthropic: stream_state}}
  end

  def synthetic_terminal_failure(%{public_ollama: stream_state} = state, _reason) do
    {data, stream_state} = OllamaStream.synthetic_terminal_failure(stream_state)
    {data, %{state | public_ollama: stream_state}}
  end

  def synthetic_terminal_failure(
        %{public_openai_responses: stream_state} = state,
        reason
      ) do
    if (PublicResponses.visible_seen?(stream_state) or bridge_committed?(state)) and
         is_nil(PublicResponses.terminal_kind(stream_state)) do
      {sequence_number, stream_state} =
        PublicResponses.track_synthetic_terminal_failure(stream_state)

      data =
        StreamProtocol.synthetic_public_openai_responses_error_sse(reason, sequence_number)

      {data, %{state | public_openai_responses: stream_state}}
    else
      {nil, state}
    end
  end

  def synthetic_terminal_failure(
        %{codex_responses_failure: %{} = _failure, codex_failure_emitted?: true} = state,
        _reason
      ),
      do: {nil, state}

  def synthetic_terminal_failure(%{codex_responses_failure: %{} = _failure} = state, reason) do
    data = StreamProtocol.synthetic_public_openai_responses_error_sse(reason, 0)
    {data, Map.put(state, :codex_failure_emitted?, true)}
  end

  def synthetic_terminal_failure(%{public_openai_completions: stream_state} = state, _reason) do
    if Completions.visible_seen?(stream_state) and not Completions.terminal_seen?(stream_state) do
      message = StreamProtocol.synthetic_public_openai_responses_failure_message()

      {data, stream_state} =
        Completions.synthetic_terminal_failure_chunk(stream_state, message)

      {data, %{state | public_openai_completions: stream_state}}
    else
      {nil, state}
    end
  end

  def synthetic_terminal_failure(%{public_openai_chat: stream_state} = state, _reason) do
    # Chat streams cannot use the websocket bridge. Keep this gate byte-identical
    # to terminal_missing_interruption_reason/2 so emission and settlement agree.
    if ChatCompletions.visible_seen?(stream_state) and
         not ChatCompletions.terminal_seen?(stream_state) do
      message = StreamProtocol.synthetic_public_openai_responses_failure_message()

      {data, stream_state} =
        ChatCompletions.synthetic_terminal_failure_chunk(stream_state, message)

      {data, %{state | public_openai_chat: stream_state}}
    else
      {nil, state}
    end
  end

  def synthetic_terminal_failure(state, _reason), do: {nil, state}

  @spec terminal_missing_interruption_reason(state(), term()) :: term()
  def terminal_missing_interruption_reason(_state, {:upstream_idle_timeout, _reason} = reason),
    do: reason

  def terminal_missing_interruption_reason(%{public_anthropic: stream_state}, original_reason) do
    if is_nil(AnthropicStream.terminal_outcome(stream_state)) do
      {:upstream_stream_interrupted, original_reason}
    else
      original_reason
    end
  end

  def terminal_missing_interruption_reason(%{public_ollama: stream_state}, original_reason) do
    if is_nil(OllamaStream.terminal_outcome(stream_state)) do
      {:upstream_stream_interrupted, original_reason}
    else
      original_reason
    end
  end

  def terminal_missing_interruption_reason(
        %{public_openai_completions: stream_state},
        original_reason
      ) do
    if Completions.visible_seen?(stream_state) and not Completions.terminal_seen?(stream_state) do
      {:upstream_stream_interrupted, original_reason}
    else
      original_reason
    end
  end

  def terminal_missing_interruption_reason(
        %{public_openai_responses: stream_state} = state,
        original_reason
      ) do
    if (PublicResponses.visible_seen?(stream_state) or bridge_committed?(state)) and
         is_nil(PublicResponses.terminal_kind(stream_state)) do
      {:upstream_stream_interrupted, original_reason}
    else
      original_reason
    end
  end

  def terminal_missing_interruption_reason(
        %{public_openai_chat: stream_state},
        original_reason
      ) do
    if ChatCompletions.visible_seen?(stream_state) and
         not ChatCompletions.terminal_seen?(stream_state) do
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

  @spec bridge_commitment_metadata(state()) :: map()
  def bridge_commitment_metadata(%{bridge_committed?: value}) when is_boolean(value),
    do: %{"bridge_committed" => value}

  def bridge_commitment_metadata(_state), do: %{}

  defp bridge_committed?(%{bridge_committed?: true}), do: true
  defp bridge_committed?(_state), do: false

  @spec public_anthropic_stream?(RequestOptions.t()) :: boolean()
  def public_anthropic_stream?(%RequestOptions{
        persona: %Persona{protocol: :anthropic_messages},
        openai_compatibility: %{
          public_anthropic_stream: true,
          anthropic_formatting: %{stream?: true}
        }
      }),
      do: true

  def public_anthropic_stream?(_opts), do: false

  @spec public_anthropic_visible_seen?(state()) :: boolean()
  def public_anthropic_visible_seen?(%{public_anthropic: stream_state}),
    do: AnthropicStream.visible_seen?(stream_state)

  def public_anthropic_visible_seen?(_state), do: false

  defp normalize_public_anthropic_stream_data(
         data,
         %{public_anthropic: stream_state} = state
       ) do
    {data, stream_state} = AnthropicStream.normalize_data(data, stream_state)
    {data, %{state | public_anthropic: stream_state}}
  end

  defp normalize_public_anthropic_stream_data(_data, state), do: {"", state}

  @spec public_ollama_stream?(RequestOptions.t()) :: boolean()
  def public_ollama_stream?(%RequestOptions{
        persona: %Persona{protocol: :ollama_chat},
        openai_compatibility: %{
          public_ollama_stream: true,
          ollama_surface: :chat,
          ollama_formatting: %{surface: :chat}
        }
      }),
      do: true

  def public_ollama_stream?(%RequestOptions{
        persona: %Persona{protocol: :ollama_generate},
        openai_compatibility: %{
          public_ollama_stream: true,
          ollama_surface: :generate,
          ollama_formatting: %{surface: :generate}
        }
      }),
      do: true

  def public_ollama_stream?(_opts), do: false

  @spec public_ollama_visible_seen?(state()) :: boolean()
  def public_ollama_visible_seen?(%{public_ollama: stream_state}),
    do: OllamaStream.visible_seen?(stream_state)

  def public_ollama_visible_seen?(_state), do: false

  defp normalize_public_ollama_stream_data(
         data,
         %{public_ollama: stream_state} = state
       ) do
    {data, stream_state} = OllamaStream.normalize_data(data, stream_state)
    {data, %{state | public_ollama: stream_state}}
  end

  defp normalize_public_ollama_stream_data(_data, state), do: {"", state}

  defp normalize_public_openai_chat_stream_data(
         data,
         %{public_openai_chat: stream_state} = state
       ) do
    {data, stream_state} = ChatCompletions.normalize_stream_data(data, stream_state)
    {data, %{state | public_openai_chat: stream_state}}
  end

  defp normalize_public_openai_chat_stream_data(data, state), do: {data, state}

  defp normalize_public_openai_completions_stream_data(
         data,
         %{public_openai_completions: stream_state} = state
       ) do
    {data, stream_state} = Completions.normalize_stream_data(data, stream_state)
    {data, %{state | public_openai_completions: stream_state}}
  end

  defp normalize_public_openai_completions_stream_data(data, state), do: {data, state}

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
    if Map.has_key?(state, :codex_responses_failure) do
      {"", state}
    else
      buffer = Map.get(state, :codex_responses_sse_buffer, "")
      previous_buffer = buffer
      buffered_size = byte_size(previous_buffer) + byte_size(data)

      cond do
        previous_buffer == "" and not possible_codex_sse_prefix?(data) ->
          fail_codex_stream(state, "upstream_stream_invalid")

        true ->
          {blocks, buffer} =
            StreamProtocol.complete_sse_blocks(previous_buffer, data, bounded?: true)

          if StreamProtocol.overflowed_incomplete_sse_block?(buffer) do
            BufferTelemetry.record_oversized_incomplete(
              "codex_responses_sse",
              buffered_size,
              StreamProtocol.max_incomplete_sse_block_bytes(),
              request_options: opts,
              endpoint: endpoint
            )

            fail_codex_stream(
              Map.put(state, :codex_responses_sse_buffer, ""),
              "upstream_stream_too_large"
            )
          else
            project_codex_sse_blocks(
              blocks,
              Map.put(state, :codex_responses_sse_buffer, buffer)
            )
          end
      end
    end
  end

  defp normalize_codex_responses_stream_data(data, endpoint, opts, state) when is_list(data) do
    case bounded_iodata_to_binary(data) do
      {:ok, binary} -> normalize_codex_responses_stream_data(binary, endpoint, opts, state)
      :error -> fail_codex_stream(state, "upstream_stream_invalid")
    end
  end

  defp normalize_codex_responses_stream_data(_data, _endpoint, _opts, state),
    do: fail_codex_stream(state, "upstream_stream_invalid")

  defp bounded_iodata_to_binary(data) do
    case validate_iodata([{data, 0}], 0, 0) do
      {:ok, _bytes} -> {:ok, IO.iodata_to_binary(data)}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
    SystemLimitError -> :error
  end

  defp validate_iodata([], bytes, _nodes), do: {:ok, bytes}

  defp validate_iodata(_pending, _bytes, nodes) when nodes >= @max_codex_iodata_nodes,
    do: :error

  defp validate_iodata([{binary, _depth} | rest], bytes, nodes) when is_binary(binary) do
    next_bytes = bytes + byte_size(binary)

    if next_bytes <= @max_codex_iodata_bytes,
      do: validate_iodata(rest, next_bytes, nodes + 1),
      else: :error
  end

  defp validate_iodata([{byte, _depth} | rest], bytes, nodes)
       when is_integer(byte) and byte in 0..255 do
    if bytes < @max_codex_iodata_bytes,
      do: validate_iodata(rest, bytes + 1, nodes + 1),
      else: :error
  end

  defp validate_iodata([{[], _depth} | rest], bytes, nodes),
    do: validate_iodata(rest, bytes, nodes + 1)

  defp validate_iodata([{[head | tail], depth} | rest], bytes, nodes)
       when depth < @max_codex_iodata_depth do
    validate_iodata([{head, depth + 1}, {tail, depth} | rest], bytes, nodes + 1)
  end

  defp validate_iodata(_pending, _bytes, _nodes), do: :error

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

  defp project_codex_sse_blocks(blocks, state) do
    Enum.reduce_while(blocks, {[], state}, fn block, {projected, state} ->
      # Validate the source block before normalization. Otherwise a malformed
      # source record can become a valid-looking local error and erase the
      # signal needed to latch a terminal stream failure. Once validated, run
      # the native error canonicalizer and its projector so safe protocol codes
      # such as stream_incomplete and rate_limit_exceeded retain their meaning.
      case PublicProjection.sse_block_result(block) do
        {:ok, _source_projection} ->
          safe =
            block
            |> StreamProtocol.normalize_codex_responses_sse_block()
            |> IO.iodata_to_binary()

          {:cont, {[safe | projected], state}}

        {:error, _safe_failure} ->
          {:halt, fail_codex_stream(state, "upstream_stream_invalid")}
      end
    end)
    |> case do
      {projected, state} when is_list(projected) ->
        {projected |> Enum.reverse() |> IO.iodata_to_binary(), state}

      {"", state} ->
        {"", state}
    end
  end

  defp fail_codex_stream(state, code) do
    failure = %{
      code: code,
      upstream_code: nil,
      upstream_error_param: nil,
      event_type: nil,
      data_type: nil
    }

    {"", Map.put(state, :codex_responses_failure, failure)}
  end

  defp possible_codex_sse_prefix?(data) when is_binary(data) do
    Enum.any?(["event:", "data:", ":"], fn prefix ->
      String.starts_with?(data, prefix) or String.starts_with?(prefix, data)
    end)
  end

  defp public_openai_chat_stream?(%RequestOptions{
         openai_compatibility: %{public_openai_chat_stream: true}
       }),
       do: true

  defp public_openai_chat_stream?(_opts), do: false

  defp public_openai_completions_stream?(%RequestOptions{
         openai_compatibility: %{public_openai_completions_stream: true}
       }),
       do: true

  defp public_openai_completions_stream?(_opts), do: false

  defp openai_chat_payload(%RequestOptions{
         openai_compatibility: %{openai_chat_payload: %{} = payload}
       }),
       do: payload

  defp openai_chat_payload(_opts), do: %{}

  defp openai_completion_payload(%RequestOptions{
         openai_compatibility: %{completion_payload: %{} = payload}
       }),
       do: payload

  defp openai_completion_payload(_opts), do: %{}
end
