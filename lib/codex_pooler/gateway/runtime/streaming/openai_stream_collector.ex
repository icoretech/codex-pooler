defmodule CodexPooler.Gateway.Runtime.Streaming.OpenAIStreamCollector do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.OpenAICompatibility.{ImageObservation, Images, Responses}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.{Metadata, ResponseUsage}
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamRelay

  @spec collect_response(Req.Response.t(), SelectedCandidateContext.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def collect_response(response, %SelectedCandidateContext{} = context, finalization_callbacks) do
    collect_stream(response, context, finalization_callbacks, fn body ->
      with {:ok, response_body} <- Responses.response_from_sse(body, context.request_options) do
        {:ok,
         %{
           status: 200,
           headers: json_headers(),
           raw_body: CodexPooler.JSON.encode!(response_body)
         }}
      end
    end)
  end

  @spec collect_image(Req.Response.t(), SelectedCandidateContext.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def collect_image(response, %SelectedCandidateContext{} = context, finalization_callbacks) do
    collect_stream(response, context, finalization_callbacks, fn body ->
      case Images.image_response_from_sse(body) do
        {:ok, image_body} ->
          {:ok, %{status: 200, headers: json_headers(), body: image_body}}

        {:error, _reason} = error ->
          log_image_failure(body, context, response.status)
          error
      end
    end)
  end

  defp log_image_failure(body, context, status) do
    Logger.info(fn ->
      "image_collection_failure request_id=#{context.reserved.request.id} " <>
        "attempt_id=#{context.attempt.id} observation=#{inspect(ImageObservation.from_http(status, body))}"
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
    state = %{
      chunks: [],
      rate_limit: RateLimitObserver.event_state(),
      usage_observer: StreamUsageObserver.new()
    }

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
             with {:ok, finalized} <-
                    Finalization.finalize_stream_failure(body, reason, response_context, state) do
               case Map.fetch(state, :collection_error) do
                 {:ok, error} -> {:error, error}
                 :error -> {:ok, finalized}
               end
             end
           end,
           before_finalize_success: fn state ->
             prepare_collection_result(state, parser, response)
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

             {:ok,
              %{
                state
                | chunks: [data | state.chunks],
                  rate_limit: rate_limit_state,
                  usage_observer: StreamUsageObserver.observe(state.usage_observer, data)
              }}
           end,
           write_keepalive: fn state -> {:ok, state} end,
           keepalive_interval_ms: 0
         }) do
      {:ok, %{collected_response: response}} ->
        {:ok, response}

      {:ok, %{chunks: chunks}} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary() |> parser.()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_collection_result(state, parser, upstream_response) do
    body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    state = put_json_usage(state, body, upstream_response)
    result = parser.(body)

    case result do
      {:ok, response} ->
        {:ok, Map.put(state, :collected_response, response), ""}

      {:error, error} ->
        {:failure, Map.put(state, :collection_error, error), "",
         {:collected_response_invalid, error.status, error.code}}
    end
  end

  defp put_json_usage(state, body, upstream_response) do
    if Metadata.json_content?(upstream_response) do
      usage =
        case CodexPooler.JSON.decode(body) do
          {:ok, decoded} -> ResponseUsage.from_stream_event(decoded)
          {:error, _reason} -> %{status: "usage_unknown", source: "json_decode_failed"}
        end

      state |> Map.delete(:usage_observer) |> Map.put(:response_usage, usage)
    else
      state
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
