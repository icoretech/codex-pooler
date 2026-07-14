defmodule CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle do
  @moduledoc """
  Runtime lifecycle callbacks for streaming dispatch.
  """

  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.CandidateDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Transports.ModelUnavailability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type finalization_callbacks :: Finalization.callbacks()
  @type dispatch_candidate_result :: Dispatch.dispatch_result()
  @type dispatch_candidate :: (PreparedContext.t() -> dispatch_candidate_result())
  @type stream_candidate_result :: {:ok, term()} | {:error, term()}
  @type stream_candidate :: (dispatch_candidate_result(), term() -> stream_candidate_result())
  @type reset_state :: (term() -> term())
  @type write_final_event :: (term(), binary() -> {:ok, term()} | {:error, term()})
  @type first_event_retry_result ::
          stream_candidate_result() | Finalization.stream_finalization_result()
  @type first_event_retry ::
          (term(), binary(), StreamProtocol.terminal_failure() -> first_event_retry_result())
  @type http_first_event_retry :: (ResponseContext.t(), keyword() -> first_event_retry())
  @type first_event_retry_context :: %{
          context: SelectedCandidateContext.t(),
          dispatch_candidate: dispatch_candidate(),
          next_index: non_neg_integer(),
          reset_state: reset_state(),
          stream_candidate: stream_candidate(),
          write_final_event: write_final_event()
        }
  @type callbacks :: %{
          required(:finalization_callbacks) => finalization_callbacks(),
          optional(:http_first_event_retry) => http_first_event_retry()
        }

  @spec lifecycle_handlers(ResponseContext.t(), callbacks(), keyword()) :: map()
  def lifecycle_handlers(%ResponseContext{} = response_context, callbacks, opts \\ []) do
    finalization_callbacks = Map.fetch!(callbacks, :finalization_callbacks)

    %{
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
      first_event_retry:
        Keyword.get_lazy(opts, :first_event_retry, fn ->
          fail_first_event_handler(response_context)
        end)
    }
  end

  @spec fail_first_event_handler(ResponseContext.t()) :: first_event_retry()
  def fail_first_event_handler(%ResponseContext{} = response_context) do
    fn _state, body, failure ->
      Finalization.finalize_first_event_stream_failure(body, failure, response_context)
    end
  end

  @spec http_first_event_retry(dispatch_candidate()) :: http_first_event_retry()
  def http_first_event_retry(dispatch_candidate) when is_function(dispatch_candidate, 1) do
    fn %ResponseContext{} = response_context, opts ->
      first_event_retry_handler(response_context, dispatch_candidate, opts)
    end
  end

  @spec first_event_retry_handler(ResponseContext.t(), dispatch_candidate(), keyword()) ::
          first_event_retry()
  def first_event_retry_handler(
        %ResponseContext{context: %SelectedCandidateContext{} = context} = response_context,
        dispatch_candidate,
        opts
      )
      when is_function(dispatch_candidate, 1) do
    reset_state = Keyword.fetch!(opts, :reset_state)
    write_final_event = Keyword.get(opts, :write_final_event, fn state, _body -> {:ok, state} end)
    stream_candidate = Keyword.fetch!(opts, :stream_candidate)

    fn state, body, failure ->
      next_index = context.retry_count + 1

      if compact_assignment_model_miss?(failure, context) do
        finalize_last_first_event_failure(
          state,
          body,
          failure,
          response_context,
          write_final_event
        )
      else
        retry_or_finalize_first_event_failure(
          state,
          body,
          failure,
          response_context,
          %{
            context: context,
            dispatch_candidate: dispatch_candidate,
            next_index: next_index,
            reset_state: reset_state,
            stream_candidate: stream_candidate,
            write_final_event: write_final_event
          }
        )
      end
    end
  end

  defp retry_or_finalize_first_event_failure(
         state,
         body,
         failure,
         response_context,
         %{
           context: context,
           dispatch_candidate: dispatch_candidate,
           next_index: next_index,
           reset_state: reset_state,
           stream_candidate: stream_candidate,
           write_final_event: write_final_event
         }
       ) do
    if Dispatch.candidate_available?(context, next_index) do
      body
      |> Finalization.record_retryable_first_event_stream_failure(failure, response_context)
      |> continue_after_retryable_first_event_record(
        context,
        next_index,
        dispatch_candidate,
        stream_candidate,
        reset_state,
        state
      )
    else
      finalize_last_first_event_failure(
        state,
        body,
        failure,
        response_context,
        write_final_event
      )
    end
  end

  defp finalize_last_first_event_failure(
         state,
         body,
         failure,
         response_context,
         write_final_event
       ) do
    case write_final_event.(state, body) do
      {:ok, state} ->
        case Finalization.finalize_first_event_stream_failure(body, failure, response_context) do
          {:ok, _finalized} -> {:ok, state}
          {:error, _gateway_error} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp continue_after_retryable_first_event_record(
         {:ok, _recorded_failure},
         context,
         next_index,
         dispatch_candidate,
         stream_candidate,
         reset_state,
         state
       ) do
    context
    |> CandidateDispatch.dispatch_from(next_index, dispatch_candidate)
    |> stream_candidate.(reset_state.(state))
  end

  defp continue_after_retryable_first_event_record(
         {:error, _gateway_error} = error,
         _context,
         _next_index,
         _dispatch_candidate,
         _stream_candidate,
         _reset_state,
         _state
       ) do
    error
  end

  defp compact_assignment_model_miss?(failure, %SelectedCandidateContext{} = context) do
    context.endpoint == "/backend-api/codex/responses/compact" and
      ModelUnavailability.terminal_failure?(
        failure,
        ModelMetadata.assignment_source?(context.model, context.assignment.id)
      )
  end
end
