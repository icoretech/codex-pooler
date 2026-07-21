defmodule CodexPooler.Gateway.Payloads.CompactionTrigger do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts

  @backend_response_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses"
  ]

  @compact_payload_keys ~w(
    model
    instructions
    input
    reasoning
    service_tier
    prompt_cache_key
    previous_response_id
    conversation
  )

  @stream_headers [{"content-type", "text/event-stream"}]

  @type payload :: %{optional(String.t()) => term()}
  @type bridge_decision :: :passthrough | {:ok, payload()} | {:error, Contracts.gateway_error()}

  @spec prepare_bridge(String.t(), payload()) :: bridge_decision()
  def prepare_bridge(local_endpoint, payload)
      when is_binary(local_endpoint) and is_map(payload) do
    cond do
      local_endpoint not in @backend_response_endpoints ->
        :passthrough

      Map.get(payload, "stream") != true ->
        :passthrough

      not is_list(Map.get(payload, "input")) ->
        :passthrough

      true ->
        prepare_input_bridge(payload)
    end
  end

  @spec adapt_gateway_result(
          {:ok, Contracts.gateway_result()}
          | {:error, Contracts.gateway_error()}
        ) ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  def adapt_gateway_result({:ok, %{status: status} = result})
      when is_integer(status) and status >= 200 and status < 300 do
    with {:ok, decoded} <- decode_result(result),
         {:ok, encrypted_content} <- encrypted_content(decoded) do
      {:ok,
       %{
         status: 200,
         headers: stream_headers(result),
         raw_body: sse_body(decoded, encrypted_content)
       }}
    else
      {:error, :invalid_json} ->
        {:error,
         %{
           status: 502,
           code: "invalid_compaction_response",
           message: "upstream compact response was not valid JSON"
         }}

      {:error, :missing_encrypted_content} ->
        {:error,
         %{
           status: 502,
           code: "invalid_compaction_response",
           message: "upstream compact response did not include encrypted compaction content"
         }}
    end
  end

  def adapt_gateway_result(result), do: result

  defp prepare_input_bridge(%{"input" => input} = payload) do
    trigger_indexes = trigger_indexes(input)

    cond do
      trigger_indexes == [] ->
        :passthrough

      trigger_indexes != [length(input) - 1] ->
        {:error, invalid_trigger_error()}

      length(input) < 2 ->
        {:error, invalid_trigger_error()}

      not visible_input_before_trigger?(input) ->
        {:error, invalid_trigger_error()}

      true ->
        {:ok, compact_payload(payload)}
    end
  end

  defp visible_input_before_trigger?(input) do
    input
    |> Enum.drop(-1)
    |> Enum.any?(&visible_input_item?/1)
  end

  defp trigger_indexes(input) do
    input
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"type" => "compaction_trigger"}, index} -> [index]
      {_item, _index} -> []
    end)
  end

  defp invalid_trigger_error do
    %{
      status: 400,
      code: "invalid_request",
      message: "compaction_trigger must be the final input item and must follow visible input",
      param: "input"
    }
  end

  defp visible_input_item?(value) when is_binary(value), do: visible_text?(value)

  defp visible_input_item?(%{"type" => "compaction_trigger"}), do: false
  defp visible_input_item?(%{"type" => "reasoning"}), do: false

  defp visible_input_item?(%{"content" => content}), do: visible_content?(content)
  defp visible_input_item?(%{"output" => output}), do: visible_content?(output)
  defp visible_input_item?(%{"text" => text}), do: visible_text?(text)
  defp visible_input_item?(_item), do: false

  defp visible_content?(content) when is_binary(content), do: visible_text?(content)
  defp visible_content?(content) when is_list(content), do: Enum.any?(content, &visible_part?/1)
  defp visible_content?(_content), do: false

  defp visible_part?(part) when is_binary(part), do: visible_text?(part)

  defp visible_part?(%{"type" => type, "text" => text})
       when type in ["input_text", "text", "output_text"] do
    visible_text?(text)
  end

  defp visible_part?(%{"type" => "input_image"} = part) do
    visible_text?(Map.get(part, "image_url")) or visible_text?(Map.get(part, "file_id"))
  end

  defp visible_part?(%{"type" => "input_audio"} = part) do
    visible_text?(Map.get(part, "audio_url"))
  end

  defp visible_part?(%{"type" => "input_file"} = part) do
    visible_text?(Map.get(part, "file_id"))
  end

  defp visible_part?(_part), do: false

  defp visible_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp visible_text?(_value), do: false

  defp compact_payload(payload) do
    payload
    |> Map.take(@compact_payload_keys)
    |> Map.put("input", payload["input"] |> Enum.drop(-1))
    |> maybe_put_prompt_cache_key(payload)
  end

  defp maybe_put_prompt_cache_key(compact_payload, %{"prompt_cache_key" => value}) do
    Map.put(compact_payload, "prompt_cache_key", value)
  end

  defp maybe_put_prompt_cache_key(compact_payload, %{"promptCacheKey" => value}) do
    Map.put(compact_payload, "prompt_cache_key", value)
  end

  defp maybe_put_prompt_cache_key(compact_payload, _payload), do: compact_payload

  defp decode_result(%{raw_body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _result -> {:error, :invalid_json}
    end
  end

  defp decode_result(%{body: body}) when is_map(body), do: {:ok, body}
  defp decode_result(_result), do: {:error, :invalid_json}

  defp encrypted_content(%{"output" => output} = decoded) when is_list(output) do
    output
    |> Enum.find_value(fn
      %{"type" => type, "encrypted_content" => content}
      when type in ["compaction", "compaction_summary"] and is_binary(content) ->
        content

      _item ->
        nil
    end)
    |> case do
      nil -> encrypted_content_from_summary(decoded)
      content -> {:ok, content}
    end
  end

  defp encrypted_content(decoded), do: encrypted_content_from_summary(decoded)

  defp encrypted_content_from_summary(%{
         "compaction_summary" => %{"encrypted_content" => content}
       })
       when is_binary(content),
       do: {:ok, content}

  defp encrypted_content_from_summary(_decoded), do: {:error, :missing_encrypted_content}

  defp sse_body(decoded, encrypted_content) do
    item = %{"type" => "compaction", "encrypted_content" => encrypted_content}

    response =
      %{
        "id" => response_id(decoded),
        "status" => "completed",
        "output" => [item]
      }
      |> maybe_put_usage(decoded)

    [
      sse_block("response.output_item.done", %{
        "type" => "response.output_item.done",
        "item" => item
      }),
      sse_block("response.completed", %{
        "type" => "response.completed",
        "response" => response
      }),
      "data: [DONE]\n\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp response_id(%{"id" => id}) when is_binary(id), do: id
  defp response_id(_decoded), do: "resp_compaction"

  defp maybe_put_usage(response, %{"usage" => usage}) when is_map(usage),
    do: Map.put(response, "usage", usage)

  defp maybe_put_usage(response, _decoded), do: response

  defp sse_block(event, data) do
    ["event: ", event, "\n", "data: ", Jason.encode!(data), "\n\n"]
  end

  defp stream_headers(result) do
    result
    |> Map.get(:headers, [])
    |> Enum.reject(fn {key, _value} ->
      normalized = String.downcase(key)
      normalized in ["content-type", "content-length"]
    end)
    |> Kernel.++(@stream_headers)
  end
end
