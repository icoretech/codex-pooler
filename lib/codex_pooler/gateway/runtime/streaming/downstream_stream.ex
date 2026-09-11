defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamStream do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses
  alias CodexPooler.Upstreams.ResponsesAPIHistory
  alias CodexPooler.Upstreams.ResponsesAPITools

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
    {data, state} = normalize_api_tools(data, opts.payload_context, state)

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

  defp normalize_api_tools(
         data,
         %{responses_api_tools: bindings, responses_api_history: history},
         state
       )
       when map_size(bindings) > 0 or not is_nil(history) do
    {data, tool_state} =
      ResponsesAPITools.stream(
        IO.iodata_to_binary(data),
        bindings,
        Map.get(state, :responses_api_tools_state)
      )

    ResponsesAPIHistory.remember(history, tool_state.completed_response)
    {data, Map.put(state, :responses_api_tools_state, %{tool_state | completed_response: nil})}
  end

  defp normalize_api_tools(data, _bindings, state), do: {data, state}

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

  def terminal_outcome(%{native_terminal_outcome: :completed}), do: :completed
  def terminal_outcome(_state), do: nil

  @spec synthetic_terminal_failure(state(), term()) :: {binary() | nil, state()}
  def synthetic_terminal_failure(
        %{public_openai_responses: stream_state} = state,
        reason
      ) do
    if emit_public_openai_responses_synthetic_terminal?(state, stream_state, reason) do
      {sequence_number, stream_state} =
        PublicResponses.track_synthetic_terminal_failure(stream_state)

      data =
        StreamProtocol.synthetic_public_openai_responses_error_sse(reason, sequence_number)

      {data, %{state | public_openai_responses: stream_state}}
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

  # The ordinary gate asks whether the client already holds bytes this terminal
  # would have to be consistent with: after visible output, or on a committed
  # bridge, an interruption owes the client an explicit failure. Before any
  # byte it deliberately stays silent, because an upstream that produced
  # nothing may still be retried at a higher layer and a fabricated terminal
  # would foreclose that.
  #
  # A drain is not that case. It is our own lifecycle event, the relay cancels
  # upstream and finalizes once with no retry, and the response is already
  # committed as `200 text/event-stream` by `send_chunked/2` before the
  # deferred closure runs. Staying silent therefore hands the client a
  # zero-byte body that is byte-identical to a successful empty response;
  # findings 159 measured six such turns. Emit for a drain regardless of
  # visibility.
  #
  # The client-visible code stays `server_error`, the same frame the
  # post-visible drain and an ordinary interruption already send:
  #   * It is truthful. The turn failed on our side, not on the caller's input,
  #     and not because the account ran out of anything.
  #   * It is the only honest *retryable* signal available in the public
  #     OpenAI vocabulary, and retryability is the property the caller needs
  #     here: we deliberately do not retry a drained turn ourselves, and a
  #     pre-visible drain is the safest possible retry in the system, because
  #     zero delivered bytes means a client retry cannot duplicate output. The
  #     post-visible drain already uses this code in the strictly weaker case.
  #   * A drain-specific code (`owner_drained`) would be worse on both counts:
  #     it is not in any SDK's vocabulary, so clients would classify it as an
  #     unknown hard failure rather than retry, and it would leak our own
  #     rollout vocabulary onto the public wire. Drain provenance stays where
  #     it belongs, in the request row's `owner_drained` / 499 and the attempt
  #     metadata.
  #
  # This is the one place the emission gate is deliberately wider than
  # `terminal_missing_interruption_reason/2`'s tagging gate. Tagging exists to
  # turn a missing terminal into `{:upstream_stream_interrupted, reason}`, and
  # for a drain that changes nothing: `Finalization.Streaming.error_code/1`
  # maps the tagged and untagged drain to the same `owner_drained`, the same
  # 499, and the same health-neutral completion. Widening the tagging gate as
  # well would only make a pre-visible drain claim the upstream interrupted it.
  defp emit_public_openai_responses_synthetic_terminal?(state, stream_state, reason) do
    (owner_drain_reason?(reason) or PublicResponses.visible_seen?(stream_state) or
       bridge_committed?(state)) and is_nil(PublicResponses.terminal_kind(stream_state))
  end

  defp owner_drain_reason?(:owner_drained), do: true

  defp owner_drain_reason?({:upstream_stream_interrupted, reason}),
    do: owner_drain_reason?(reason)

  defp owner_drain_reason?({:upstream_websocket_bridge, reason}),
    do: owner_drain_reason?(reason)

  defp owner_drain_reason?(_reason), do: false

  @spec terminal_missing_interruption_reason(state(), term()) :: term()
  def terminal_missing_interruption_reason(_state, {:upstream_idle_timeout, _reason} = reason),
    do: reason

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
    sse_block_state =
      Map.get(state, :codex_responses_sse_block_state, StreamProtocol.new_sse_block_state())

    buffer = sse_block_state.buffer

    if buffer == "" and not sse_block_state.skip_leading_lf? and
         not codex_responses_sse_chunk?(data) do
      {data, state}
    else
      previous_buffer = buffer
      buffered_size = byte_size(previous_buffer) + byte_size(data)

      {blocks, sse_block_state} =
        StreamProtocol.complete_sse_blocks(sse_block_state, data, bounded?: true)

      buffer = sse_block_state.buffer

      data =
        if oversized_incomplete_sse_prefix?(blocks, buffer, buffered_size) do
          BufferTelemetry.record_oversized_incomplete(
            "codex_responses_sse",
            buffered_size,
            StreamProtocol.max_incomplete_sse_block_bytes(),
            request_options: opts,
            endpoint: endpoint
          )

          previous_buffer <> data
        else
          blocks
          |> Enum.map(&normalize_codex_responses_sse_block(&1, opts, state))
          |> IO.iodata_to_binary()
        end

      state =
        state
        |> Map.put(:codex_responses_sse_block_state, sse_block_state)
        |> track_native_completion(blocks)

      {data, state}
    end
  end

  defp normalize_codex_responses_stream_data(data, _endpoint, _opts, state), do: {data, state}

  defp track_native_completion(%{target: :websocket} = state, _blocks), do: state

  defp track_native_completion(state, blocks) do
    Enum.reduce(blocks, state, fn block, state ->
      case StreamProtocol.terminal_outcome(block <> "\n\n") do
        {:ok, %{kind: :completed}} -> Map.put(state, :native_terminal_outcome, :completed)
        _outcome -> state
      end
    end)
  end

  defp normalize_codex_responses_sse_block(block, opts, %{target: target})
       when target != :websocket do
    if MisalignmentPolicyViolation.details_allowed?(opts) do
      StreamProtocol.normalize_private_native_misalignment_sse_block(block)
    else
      StreamProtocol.normalize_codex_responses_sse_block(block)
    end
  end

  defp normalize_codex_responses_sse_block(block, _opts, _state),
    do: StreamProtocol.normalize_codex_responses_sse_block(block)

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
      String.contains?(data, ["\nevent: ", "\revent: "]) or
      String.contains?(data, ["\ndata: ", "\rdata: "]) or
      String.contains?(data, ["\n\n", "\n\r", "\r\r"])
  end

  defp oversized_incomplete_sse_prefix?([], "", buffered_size),
    do: buffered_size > StreamProtocol.max_incomplete_sse_block_bytes()

  defp oversized_incomplete_sse_prefix?(_blocks, _buffer, _buffered_size), do: false

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
