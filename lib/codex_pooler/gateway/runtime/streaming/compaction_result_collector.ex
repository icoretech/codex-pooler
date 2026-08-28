defmodule CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.CompactionTrigger
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam
  alias CodexPooler.Gateway.Transports.Streaming.StreamRelay
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy

  @type collection_error ::
          :duplicate_compaction
          | :invalid_compaction
          | :missing_compaction
          | :missing_terminal
          | {:provider_failure, StreamProtocol.terminal_failure(),
             StreamProtocol.terminal_failure()}

  @type websocket_collection_result ::
          {:ok, map()}
          | {:provider_failure, StreamProtocol.terminal_failure()}
          | {:error, map()}

  @spec collect(Req.Response.t(), SelectedCandidateContext.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def collect(response, %SelectedCandidateContext{} = context, finalization_callbacks) do
    response_context = %ResponseContext{context: context, response: response}
    state = new_state()

    case StreamRelay.run(state, response, handlers(response_context, finalization_callbacks)) do
      {:ok, state} -> state |> finalize_sse_state() |> compact_result()
      {:error, error} -> {:error, error}
    end
  end

  @spec collect_websocket_body(binary(), :native | :public) :: websocket_collection_result()
  def collect_websocket_body(body, item_mode \\ :native)

  def collect_websocket_body(body, item_mode)
      when is_binary(body) and item_mode in [:native, :public] do
    {:ok, state} = collect_sse_data(new_state(item_mode), body)
    state |> finalize_sse_state() |> websocket_compact_result()
  end

  defp new_state(item_mode \\ :native) do
    %{
      collection: %{
        invalid_reason: nil,
        item_mode: item_mode,
        item: nil,
        provider_failure: nil,
        response: nil,
        terminal_failure: nil,
        terminal?: false
      },
      rate_limit: RateLimitObserver.event_state(),
      sse: StreamProtocol.new_sse_block_state(),
      usage_observer: StreamUsageObserver.new()
    }
  end

  defp compact_result(%{collection: %{invalid_reason: nil} = collection}) do
    case compact_response(collection) do
      {:ok, response} ->
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           raw_body: Jason.encode!(response)
         }}

      {:error, _reason} ->
        invalid_compaction_error()
    end
  end

  defp compact_result(_state), do: invalid_compaction_error()

  defp websocket_compact_result(%{collection: %{provider_failure: %{} = failure}}),
    do: {:provider_failure, failure}

  defp websocket_compact_result(state), do: compact_result(state)

  defp compact_response(%{item: item, response: response, terminal?: true})
       when is_map(item) and is_map(response) do
    {:ok,
     response
     |> Map.take(["id", "usage"])
     |> Map.put("status", "completed")
     |> Map.put("output", [item])}
  end

  defp compact_response(_collection), do: {:error, :missing_terminal}

  defp handlers(response_context, finalization_callbacks) do
    %{
      finalize_success: fn _body, state ->
        state = finalize_sse_state(state)

        case compact_result(state) do
          {:ok, %{raw_body: compact_body}} ->
            Finalization.finalize_stream_success(
              compact_body,
              response_context,
              finalization_callbacks,
              state
            )

          {:error, _reason} ->
            case Finalization.finalize_stream_failure(
                   "",
                   {:terminal_stream_failure, saved_terminal_failure(state)},
                   response_context,
                   state
                 ) do
              {:ok, _finalized} -> invalid_compaction_error()
              {:error, gateway_error} -> {:error, gateway_error}
            end
        end
      end,
      finalize_failure: fn _body, reason, state ->
        Finalization.finalize_stream_failure(
          "",
          compaction_failure_reason(reason),
          response_context,
          state
        )
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

        with {:ok, state} <- collect_sse_data(state, data) do
          {:ok, %{state | rate_limit: rate_limit}}
        end
      end,
      write_keepalive: fn state -> {:ok, state} end,
      keepalive_interval_ms: 0
    }
  end

  defp collect_sse_data(%{sse: sse, collection: collection} = state, data) do
    {blocks, sse} = StreamProtocol.complete_sse_blocks(sse, data, bounded?: true)

    case collect_events(blocks, collection) do
      {:ok, collection} ->
        {:ok,
         %{
           state
           | collection: collection,
             sse: sse,
             usage_observer: StreamUsageObserver.observe(state.usage_observer, data)
         }}

      {:error, reason} ->
        {:ok,
         state
         |> Map.put(:sse, sse)
         |> put_collection_error(reason)}
    end
  end

  defp finalize_sse_state(%{sse: %{buffer: buffer}, collection: collection} = state) do
    if buffer != "" and is_map(collection.provider_failure) do
      %{
        state
        | collection: %{collection | invalid_reason: :invalid_compaction, provider_failure: nil}
      }
    else
      case collect_terminal_buffer(buffer, collection) do
        {:ok, collection} -> %{state | collection: collection}
        {:error, reason} -> put_collection_error(state, reason)
      end
    end
  end

  defp finalize_sse_state(state), do: state

  defp put_collection_error(%{collection: %{invalid_reason: nil} = collection} = state, reason) do
    collection =
      case reason do
        {:provider_failure, terminal_failure, provider_failure} ->
          %{
            collection
            | terminal_failure: terminal_failure,
              provider_failure: provider_failure
          }

        _reason ->
          collection
      end

    %{state | collection: %{collection | invalid_reason: reason}}
  end

  defp put_collection_error(state, _reason), do: state

  defp saved_terminal_failure(%{collection: %{terminal_failure: %{} = failure}}), do: failure
  defp saved_terminal_failure(_state), do: failure(:invalid_compaction)

  defp collect_terminal_buffer("", collection), do: {:ok, collection}

  defp collect_terminal_buffer(_buffer, %{terminal?: true}), do: {:error, :invalid_compaction}

  defp collect_terminal_buffer(buffer, collection) do
    with {:ok, event_type, decoded} <- terminal_event(buffer) do
      collect_event(event_type, decoded, collection)
    end
  end

  defp terminal_event(buffer) do
    event_type =
      buffer
      |> StreamProtocol.sse_field("event")
      |> StreamProtocol.normalize_sse_event_label()

    with data when is_binary(data) <- StreamProtocol.sse_field(buffer, "data"),
         {:ok, %{} = decoded} <- Jason.decode(data),
         data_type when is_binary(data_type) <- Map.get(decoded, "type"),
         true <- event_type in [nil, data_type] do
      {:ok, event_type, decoded}
    else
      false -> {:error, :invalid_compaction}
      _result -> {:error, :missing_terminal}
    end
  end

  defp collect_events([], state), do: {:ok, state}

  defp collect_events([block | blocks], state) do
    case collect_block(block, state) do
      {:ok, state} ->
        collect_events(blocks, state)

      {:error, {:provider_failure, _terminal_failure, _provider_failure}} when blocks != [] ->
        {:error, :invalid_compaction}

      {:error, _reason} = error ->
        error
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
          collect_event(event_type, event, state)
        else
          {:error, :invalid_compaction}
        end

      nil ->
        {:ok, state}
    end
  end

  defp collect_event(_event_type, _decoded, %{terminal?: true}), do: {:error, :invalid_compaction}

  defp collect_event(event_type, decoded, state) do
    event_summary = StreamProtocol.event_summary(event_type || Map.get(decoded, "type"), decoded)
    collect_summarized_event(event_summary, decoded, state)
  end

  defp collect_summarized_event(
         %{data_type: "response.output_item.done"},
         %{"item" => %{"type" => type} = item},
         %{item: nil, item_mode: item_mode} = state
       )
       when type in ["compaction", "compaction_summary"] do
    case compact_item(item, item_mode) do
      {:ok, item} -> {:ok, %{state | item: item}}
      {:error, _reason} = error -> error
    end
  end

  defp collect_summarized_event(
         %{data_type: "response.output_item.done"},
         %{"item" => %{"type" => type}},
         _state
       )
       when type in ["compaction", "compaction_summary"],
       do: {:error, :duplicate_compaction}

  defp collect_summarized_event(
         %{data_type: "response.output_item.done"},
         %{"item" => item},
         state
       )
       when is_map(item),
       do: {:ok, state}

  defp collect_summarized_event(%{data_type: "response.output_item.done"}, _event, _state),
    do: {:error, :invalid_compaction}

  defp collect_summarized_event(
         %{data_type: type},
         %{"response" => %{"status" => "completed"} = response},
         %{item: item, terminal?: false} = state
       )
       when type in ["response.completed", "response.done"] and is_map(item),
       do: {:ok, %{state | response: response, terminal?: true}}

  defp collect_summarized_event(%{data_type: type}, _event, _state)
       when type in ["response.completed", "response.done"],
       do: {:error, :missing_terminal}

  defp collect_summarized_event(%{event_type: type} = event_summary, _event, _state)
       when type in ["error", "response.failed", "response.incomplete"] do
    case StreamProtocol.terminal_outcome_event(event_summary) do
      {:ok, %{kind: :failed} = outcome} ->
        {:error,
         {:provider_failure, terminal_failure(outcome), provider_terminal_failure(outcome)}}

      {:ok, %{kind: :incomplete, incomplete_reason: reason} = outcome} when is_binary(reason) ->
        if String.trim(reason) == "" do
          {:error, :invalid_compaction}
        else
          {:error,
           {:provider_failure, terminal_failure(outcome), provider_terminal_failure(outcome)}}
        end

      _outcome ->
        {:error, :invalid_compaction}
    end
  end

  defp collect_summarized_event(_event_summary, _event, state), do: {:ok, state}

  defp compact_item(%{"type" => type, "encrypted_content" => content} = item, item_mode)
       when type in ["compaction", "compaction_summary"] and is_binary(content) do
    if String.trim(content) == "" do
      {:error, :invalid_compaction}
    else
      {:ok, normalize_compaction_item(item, item_mode)}
    end
  end

  defp compact_item(_item, _item_mode), do: {:error, :invalid_compaction}

  defp normalize_compaction_item(item, :native),
    do: CompactionTrigger.normalize_native_item(item)

  defp normalize_compaction_item(item, :public) do
    normalized = %{
      "type" => "compaction",
      "encrypted_content" => item["encrypted_content"]
    }

    case Map.fetch(item, "id") do
      {:ok, id} when is_nil(id) or is_binary(id) -> Map.put(normalized, "id", id)
      _result -> normalized
    end
  end

  defp compaction_failure_reason({:upstream_idle_timeout, _reason} = reason), do: reason
  defp compaction_failure_reason(reason), do: {:upstream_stream_interrupted, reason}

  @spec terminal_failure(String.t() | nil, map()) :: StreamProtocol.terminal_failure()
  def terminal_failure(event_type, decoded) when is_map(decoded) do
    event_summary = StreamProtocol.event_summary(event_type || Map.get(decoded, "type"), decoded)

    case StreamProtocol.terminal_outcome_event(event_summary) do
      {:ok, %{kind: kind} = outcome} when kind in [:failed, :incomplete] ->
        terminal_failure(outcome)

      _outcome ->
        terminal_failure_from_summary(event_summary)
    end
  end

  defp terminal_failure(%{kind: :failed, failure: failure} = outcome) do
    terminal_failure(
      outcome.event_type,
      failure.upstream_code,
      failure.upstream_error_param
    )
  end

  defp terminal_failure(%{kind: :incomplete} = outcome) do
    terminal_failure(outcome.event_type, outcome.incomplete_reason, nil)
  end

  defp provider_terminal_failure(%{kind: :failed, failure: failure}) do
    sanitize_provider_terminal_failure(failure)
  end

  defp provider_terminal_failure(%{kind: :incomplete} = outcome) do
    sanitize_provider_terminal_failure(%{
      code: outcome.incomplete_reason || outcome.event_type,
      upstream_code: outcome.incomplete_reason,
      upstream_error_param: nil,
      event_type: outcome.event_type,
      data_type: outcome.data_type
    })
  end

  defp sanitize_provider_terminal_failure(failure) do
    %{
      code: DiagnosticTaxonomy.identifier(failure.code),
      upstream_code: optional_identifier(failure.upstream_code),
      upstream_error_param: UpstreamErrorParam.sanitize(failure.upstream_error_param),
      event_type: optional_identifier(failure.event_type),
      data_type: optional_identifier(failure.data_type)
    }
  end

  defp optional_identifier(value) when is_binary(value), do: DiagnosticTaxonomy.identifier(value)
  defp optional_identifier(_value), do: nil

  defp terminal_failure_from_summary(event_summary) do
    terminal_failure(
      event_summary.event_type,
      event_summary.upstream_error_code || event_summary.incomplete_reason,
      event_summary.upstream_error_param
    )
  end

  defp terminal_failure(event_type, diagnostic_upstream_code, upstream_error_param) do
    failure = %{
      code: "invalid_compaction_response",
      upstream_code: nil,
      upstream_error_param: UpstreamErrorParam.sanitize(upstream_error_param),
      event_type: DiagnosticTaxonomy.identifier(event_type),
      data_type: nil
    }

    case diagnostic_upstream_code do
      diagnostic_upstream_code when is_binary(diagnostic_upstream_code) ->
        Map.put(
          failure,
          :diagnostic_upstream_code,
          DiagnosticTaxonomy.identifier(diagnostic_upstream_code)
        )

      nil ->
        failure
    end
  end

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
