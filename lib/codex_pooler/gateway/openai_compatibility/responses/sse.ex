defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.SSE do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @spec response_from_sse(binary()) :: {:ok, map()} | {:error, Error.reason()}
  def response_from_sse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        response = Map.put_new(decoded, "object", "response")

        case response_terminal_type(response) do
          nil ->
            {:ok, response}

          type ->
            terminal_error(%{"type" => type, "response" => response}, response) || {:ok, response}
        end

      _error ->
        body |> decoded_sse_events() |> response_from_sse_events()
    end
  end

  defp response_from_sse_events(events) do
    with {:ok, response, event} <- terminal_response(events) do
      response =
        response
        |> Map.put_new("object", "response")
        |> maybe_backfill_output(events)

      terminal_error(event, response) || {:ok, response}
    end
  end

  defp decoded_sse_events(body) do
    body
    |> StreamProtocol.complete_sse_blocks(bounded?: false)
    |> elem(0)
    |> Enum.map(fn block ->
      block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp terminal_response(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"response" => %{} = response} = event -> {:ok, response, event}
      _event -> nil
    end)
    |> Kernel.||(
      {:error, Error.reason(502, "upstream_response_missing", "upstream response was incomplete")}
    )
  end

  defp terminal_error(event, response) do
    event_type = event["type"] || response_terminal_type(response)

    case StreamProtocol.terminal_outcome(event_type, event) do
      {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
        nil

      {:ok, %{kind: :failed, failure: failure}} ->
        terminal_failure_error(event, response, failure)

      _outcome ->
        terminal_failure_error(event, response, nil)
    end
  end

  defp terminal_failure_error(event, response, failure) do
    error = response["error"] || event["error"]

    case error do
      %{} = error ->
        status = PublicResponse.terminal_error_status(error)
        normalized = PublicResponse.normalize_error(error, status: status)

        {:error,
         Error.reason(
           status,
           normalized["code"] || "upstream_error",
           normalized["message"] || "upstream request failed",
           normalized["param"]
         )}

      _other ->
        {:error, Error.reason(502, failure_code(failure), "upstream request failed")}
    end
  end

  defp failure_code(%{code: code}) when is_binary(code), do: code
  defp failure_code(_failure), do: "upstream_error"

  defp response_terminal_type(%{"status" => "completed"}), do: "response.completed"
  defp response_terminal_type(%{"status" => "failed"}), do: "response.failed"
  defp response_terminal_type(%{"status" => "incomplete"}), do: "response.incomplete"
  defp response_terminal_type(_response), do: nil

  defp maybe_backfill_output(%{"output" => output} = response, _events)
       when is_list(output) and output != [],
       do: response

  defp maybe_backfill_output(response, events) do
    output_items =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_item.done", "item" => %{} = item} -> [item]
        _event -> []
      end)

    cond do
      output_items != [] ->
        Map.put(response, "output", output_items)

      output_text = output_text_from_events(events) ->
        Map.put(response, "output", [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => output_text}]}
        ])

      true ->
        response
    end
  end

  defp output_text_from_events(events) do
    deltas =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_text.delta", "delta" => delta} when is_binary(delta) ->
          [delta]

        _event ->
          []
      end)

    done_texts =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_text.done", "text" => text} when is_binary(text) -> [text]
        _event -> []
      end)

    [deltas, done_texts]
    |> Enum.find(&(&1 != []))
    |> case do
      nil -> nil
      parts -> Enum.join(parts)
    end
  end
end
