defmodule CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamRelay

  @type collection_error ::
          :duplicate_compaction
          | :invalid_compaction
          | :missing_compaction
          | :missing_terminal
          | :provider_failure

  @spec collect(Req.Response.t(), SelectedCandidateContext.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def collect(response, %SelectedCandidateContext{} = context, finalization_callbacks) do
    response_context = %ResponseContext{context: context, response: response}
    state = %{chunks: [], rate_limit: RateLimitObserver.event_state()}

    case StreamRelay.run(state, response, handlers(response_context, finalization_callbacks)) do
      {:ok, %{chunks: chunks}} ->
        chunks
        |> Enum.reverse()
        |> IO.iodata_to_binary()
        |> compact_result()

      {:error, error} ->
        {:error, error}
    end
  end

  defp compact_result(body) do
    case compact_response(body) do
      {:ok, compact_response} ->
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           raw_body: Jason.encode!(compact_response)
         }}

      {:error, _reason} ->
        invalid_compaction_error()
    end
  end

  defp handlers(response_context, finalization_callbacks) do
    %{
      finalize_success: fn body ->
        case compact_response(body) do
          {:ok, _compact_response} ->
            Finalization.finalize_stream_success(body, response_context, finalization_callbacks)

          {:error, reason} ->
            case Finalization.finalize_stream_failure(
                   body,
                   {:terminal_stream_failure, failure(reason)},
                   response_context
                 ) do
              {:ok, _finalized} -> invalid_compaction_error()
              {:error, gateway_error} -> {:error, gateway_error}
            end
        end
      end,
      finalize_failure: fn body, reason ->
        Finalization.finalize_stream_failure(body, reason, response_context)
      end,
      first_event_retry: fn _state, body, failure ->
        Finalization.finalize_first_event_stream_failure(body, failure, response_context)
      end,
      write_chunk: fn state, data ->
        {:ok, rate_limit} =
          RateLimitObserver.record_events(
            response_context.context.identity,
            data,
            rate_limit_state(state)
          )

        {:ok, %{state | chunks: [data | state.chunks], rate_limit: rate_limit}}
      end,
      write_keepalive: fn state -> {:ok, state} end,
      keepalive_interval_ms: 0
    }
  end

  defp compact_response(body) when is_binary(body) do
    state = StreamProtocol.new_sse_block_state()
    {blocks, %{buffer: buffer}} = StreamProtocol.complete_sse_blocks(state, body, bounded?: true)

    with true <- buffer == "",
         {:ok, collection} <-
           collect_events(blocks, %{item: nil, response: nil, terminal?: false}),
         %{item: item, response: response, terminal?: true} <- collection do
      {:ok,
       response
       |> Map.take(["id", "usage"])
       |> Map.put("status", "completed")
       |> Map.put("output", [item])}
    else
      false -> {:error, :missing_terminal}
      %{terminal?: false} -> {:error, :missing_terminal}
      _other -> {:error, :invalid_compaction}
    end
  end

  defp collect_events([], state), do: {:ok, state}

  defp collect_events([block | blocks], state) do
    case collect_block(block, state) do
      {:ok, state} -> collect_events(blocks, state)
      {:error, _reason} = error -> error
    end
  end

  defp collect_block(block, state) do
    event_type =
      block
      |> StreamProtocol.sse_field("event")
      |> StreamProtocol.normalize_sse_event_label()

    case StreamProtocol.sse_field(block, "data") do
      "[DONE]" ->
        {:ok, state}

      data when is_binary(data) ->
        event = StreamProtocol.decode_sse_data(data)
        data_type = Map.get(event, "type")

        if is_binary(data_type) and event_type in [nil, data_type] do
          collect_event(data_type, event, state)
        else
          {:error, :invalid_compaction}
        end

      nil ->
        {:ok, state}
    end
  end

  defp collect_event(
         "response.output_item.done",
         %{"item" => %{"type" => "compaction"} = item},
         %{item: nil} = state
       ) do
    case compact_item(item) do
      {:ok, item} -> {:ok, %{state | item: item}}
      {:error, _reason} = error -> error
    end
  end

  defp collect_event(
         "response.output_item.done",
         %{"item" => %{"type" => "compaction"}},
         _state
       ),
       do: {:error, :duplicate_compaction}

  defp collect_event("response.output_item.done", %{"item" => item}, state)
       when is_map(item),
       do: {:ok, state}

  defp collect_event("response.output_item.done", _event, _state),
    do: {:error, :invalid_compaction}

  defp collect_event(
         type,
         %{"response" => %{"status" => "completed"} = response},
         %{item: item, terminal?: false} = state
       )
       when type in ["response.completed", "response.done"] and is_map(item),
       do: {:ok, %{state | response: response, terminal?: true}}

  defp collect_event(type, _event, _state)
       when type in ["response.completed", "response.done"],
       do: {:error, :missing_terminal}

  defp collect_event(type, _event, _state)
       when type in ["error", "response.failed", "response.incomplete"],
       do: {:error, :provider_failure}

  defp collect_event(_type, _event, state), do: {:ok, state}

  defp compact_item(%{"type" => "compaction", "encrypted_content" => content} = item)
       when is_binary(content) do
    if String.trim(content) == "" do
      {:error, :invalid_compaction}
    else
      {:ok, Map.take(item, ["type", "encrypted_content", "id"])}
    end
  end

  defp compact_item(_item), do: {:error, :invalid_compaction}

  defp failure(reason) do
    %{
      code: "invalid_compaction_response",
      upstream_code: nil,
      upstream_error_param: nil,
      event_type: nil,
      data_type: Atom.to_string(reason)
    }
  end

  defp invalid_compaction_error do
    {:error,
     %{
       status: 502,
       code: "invalid_compaction_response",
       message: "upstream compact stream was invalid"
     }}
  end

  defp rate_limit_state(%{rate_limit: %{buffer: buffer}}) when is_binary(buffer),
    do: %{buffer: buffer}

  defp rate_limit_state(_state), do: RateLimitObserver.event_state()
end
