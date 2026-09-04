defmodule CodexPooler.Gateway.Runtime.Streaming.OpenAIStreamCollector do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Images, Responses}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamRelay

  @spec collect_response(Req.Response.t(), SelectedCandidateContext.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def collect_response(response, %SelectedCandidateContext{} = context, finalization_callbacks) do
    collect_stream(response, context, finalization_callbacks, fn body ->
      with {:ok, response_body} <- Responses.response_from_sse(body, context.request_options) do
        {:ok, %{status: 200, headers: json_headers(), raw_body: Jason.encode!(response_body)}}
      end
    end)
  end

  @spec collect_image(Req.Response.t(), SelectedCandidateContext.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def collect_image(response, %SelectedCandidateContext{} = context, finalization_callbacks) do
    collect_stream(response, context, finalization_callbacks, fn body ->
      with {:ok, image_body} <- Images.image_response_from_sse(body) do
        {:ok, %{status: 200, headers: json_headers(), body: image_body}}
      end
    end)
  end

  @spec collect_image?(RequestOptions.t()) :: boolean()
  def collect_image?(%RequestOptions{
        openai_compatibility: %{collect_openai_image_stream: true}
      }),
      do: true

  def collect_image?(_request_options), do: false

  @spec collect_response?(RequestOptions.t()) :: boolean()
  def collect_response?(%RequestOptions{
        openai_compatibility: %{collect_openai_response_stream: true}
      }),
      do: true

  def collect_response?(_request_options), do: false

  defp collect_stream(
         response,
         %SelectedCandidateContext{} = context,
         finalization_callbacks,
         parser
       ) do
    state = %{chunks: [], rate_limit: RateLimitObserver.event_state()}
    response_context = %ResponseContext{context: context, response: response}

    case StreamRelay.run(state, response, %{
           finalize_success: fn body, state ->
             Finalization.finalize_stream_success(
               body,
               response_context,
               finalization_callbacks,
               state
             )
           end,
           finalize_failure: fn body, reason, state ->
             Finalization.finalize_stream_failure(body, reason, response_context, state)
           end,
           first_event_retry: first_event_retry_handler(response_context),
           write_chunk: fn state, data ->
             {:ok, rate_limit_state} =
               RateLimitObserver.collect_events(data, rate_limit_state(state))

             state =
               maybe_mark_visible_stream_output(
                 state,
                 context.reserved.request,
                 context.attempt,
                 data
               )

             {:ok, %{state | chunks: [data | state.chunks], rate_limit: rate_limit_state}}
           end,
           write_keepalive: fn state -> {:ok, state} end,
           keepalive_interval_ms: 0
         }) do
      {:ok, %{chunks: chunks}} ->
        chunks
        |> Enum.reverse()
        |> IO.iodata_to_binary()
        |> parser.()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec first_event_retry_handler(ResponseContext.t()) ::
          (term(), binary(), StreamProtocol.terminal_failure() ->
             {:ok, term()} | {:error, term()})
  def first_event_retry_handler(%ResponseContext{} = response_context) do
    fn state, body, failure ->
      case Finalization.finalize_first_event_stream_failure(body, failure, response_context) do
        {:ok, _finalized} -> {:ok, state}
        {:error, _gateway_error} = error -> error
      end
    end
  end

  defp maybe_mark_visible_stream_output(
         %{visible_output_marked?: true} = state,
         _request,
         _attempt,
         _data
       ),
       do: state

  defp maybe_mark_visible_stream_output(state, request, attempt, data) do
    if StreamProtocol.stream_data_visible?(data) do
      case SessionContinuity.mark_codex_turn_visible(request, attempt) do
        :ok -> Map.put(state, :visible_output_marked?, true)
        {:error, :stale_generation} -> state
      end
    else
      state
    end
  end

  defp rate_limit_state(%{rate_limit: %{buffer: buffer} = state}) when is_binary(buffer),
    do: state

  defp rate_limit_state(_state), do: RateLimitObserver.event_state()

  defp json_headers, do: [{"content-type", "application/json"}]
end
