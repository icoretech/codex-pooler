defmodule CodexPooler.Gateway.Payloads.CompactionTrigger do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @public_response_endpoint "/v1/responses"

  @backend_response_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses"
  ]

  @compact_endpoints [
    "/backend-api/codex/responses/compact",
    "/backend-api/codex/v1/responses/compact"
  ]

  @compact_payload_keys ~w(
    model
    instructions
    input
    tools
    parallel_tool_calls
    reasoning
    service_tier
    prompt_cache_key
    prompt_cache_options
    text
  )

  @stream_headers [{"content-type", "text/event-stream"}]

  @type payload :: %{optional(String.t()) => term()}
  @type bridge_decision :: :passthrough | {:ok, payload()} | {:error, Contracts.gateway_error()}
  @type compaction_result_transport :: :buffered | :sse

  @spec compaction_result_transport(payload()) :: compaction_result_transport()
  def compaction_result_transport(%{"client_metadata" => %{} = metadata}) do
    case metadata["x-codex-turn-metadata"] do
      turn_metadata when is_binary(turn_metadata) ->
        case Jason.decode(turn_metadata) do
          {:ok, %{"compaction" => %{"implementation" => "responses_compaction_v2"}}} -> :sse
          _result -> :buffered
        end

      _value ->
        :buffered
    end
  end

  def compaction_result_transport(%{}), do: :buffered

  @spec v2_streaming?(payload()) :: boolean()
  def v2_streaming?(payload), do: compaction_result_transport(payload) == :sse

  @type result_mode :: :sse | :public_sse | :response | :websocket | :native_websocket

  @spec prepare_bridge(String.t(), payload()) :: bridge_decision()
  def prepare_bridge(@public_response_endpoint, %{"input" => input} = payload)
      when is_list(input) do
    prepare_input_bridge(payload, require_visible?: true)
  end

  def prepare_bridge(@public_response_endpoint, payload) when is_map(payload), do: :passthrough

  def prepare_bridge(local_endpoint, payload)
      when is_binary(local_endpoint) and is_map(payload) do
    cond do
      local_endpoint in @compact_endpoints ->
        validate_direct_compact_payload(payload)

      local_endpoint not in @backend_response_endpoints ->
        :passthrough

      Map.get(payload, "stream") != true ->
        :passthrough

      not is_list(Map.get(payload, "input")) ->
        :passthrough

      true ->
        prepare_input_bridge(payload, require_visible?: false)
    end
  end

  @spec validate_projection(payload()) :: :ok | {:error, Contracts.gateway_error()}
  def validate_projection(payload) when is_map(payload) do
    cond do
      Map.has_key?(payload, "tools") and not is_list(payload["tools"]) ->
        {:error, Error.invalid_request("tools must be an array", "tools")}

      Map.has_key?(payload, "parallel_tool_calls") and
          not is_boolean(payload["parallel_tool_calls"]) ->
        {:error,
         Error.invalid_request("parallel_tool_calls must be a boolean", "parallel_tool_calls")}

      Map.has_key?(payload, "text") and not is_map(payload["text"]) ->
        {:error, Error.invalid_request("text must be an object", "text")}

      true ->
        :ok
    end
  end

  @spec project_native_payload(payload()) :: payload()
  def project_native_payload(payload) when is_map(payload) do
    payload
    |> Map.take(@compact_payload_keys)
    |> maybe_put_prompt_cache_key(payload)
    |> remove_compaction_triggers()
  end

  @spec project_responses_payload(payload(), :buffered | :sse) :: payload()
  def project_responses_payload(payload, result_transport \\ :buffered)

  def project_responses_payload(payload, result_transport)
      when is_map(payload) and result_transport in [:buffered, :sse] do
    payload
    |> Map.take(["store" | @compact_payload_keys])
    |> maybe_put_prompt_cache_key(payload)
    |> Map.put("store", false)
    |> maybe_put_stream(result_transport)
    |> maybe_put_previous_response_id(payload)
  end

  @spec streaming_result?(RequestOptions.t()) :: boolean()
  def streaming_result?(%RequestOptions{
        payload_context: %{
          compaction_trigger_bridge?: true,
          compaction_result_transport: :sse
        }
      }),
      do: true

  def streaming_result?(%RequestOptions{}), do: false

  @spec adapt_gateway_result(
          {:ok, Contracts.gateway_result()}
          | {:error, Contracts.gateway_error()}
        ) ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  def adapt_gateway_result(result), do: adapt_gateway_result(result, :sse)

  @spec adapt_gateway_result(
          {:ok, Contracts.gateway_result()}
          | {:error, Contracts.gateway_error()},
          result_mode()
        ) ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  def adapt_gateway_result({:ok, %{status: status} = result}, mode)
      when mode in [:sse, :public_sse, :response, :websocket, :native_websocket] and
             is_integer(status) and
             status >= 200 and status < 300 do
    with {:ok, decoded} <- decode_result(result),
         {:ok, item} <- compaction_item(decoded, mode) do
      {:ok, adapted_result(result, decoded, item, mode)}
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

  def adapt_gateway_result(result, _mode), do: result

  defp prepare_input_bridge(
         %{"input" => [%{"type" => "compaction_trigger"}]} = payload,
         require_visible?: false
       ) do
    payload
    |> compact_payload()
    |> validate_compact_payload()
  end

  defp prepare_input_bridge(%{"input" => input} = payload, require_visible?: _require_visible?) do
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
        compact_payload(payload)
        |> validate_compact_payload()
    end
  end

  defp validate_direct_compact_payload(payload) do
    case validate_projection(payload) do
      :ok -> :passthrough
      {:error, _reason} = error -> error
    end
  end

  defp validate_compact_payload(payload) do
    case validate_projection(payload) do
      :ok -> {:ok, payload}
      {:error, _reason} = error -> error
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

  defp compact_payload(payload), do: project_responses_payload(payload)

  defp remove_compaction_triggers(%{"input" => input} = payload) when is_list(input) do
    Map.put(payload, "input", Enum.reject(input, &match?(%{"type" => "compaction_trigger"}, &1)))
  end

  defp remove_compaction_triggers(payload), do: payload

  defp maybe_put_prompt_cache_key(compact_payload, %{"prompt_cache_key" => value}) do
    Map.put(compact_payload, "prompt_cache_key", value)
  end

  defp maybe_put_prompt_cache_key(compact_payload, %{"promptCacheKey" => value}) do
    Map.put(compact_payload, "prompt_cache_key", value)
  end

  defp maybe_put_prompt_cache_key(compact_payload, _payload), do: compact_payload

  defp maybe_put_previous_response_id(compact_payload, %{"previous_response_id" => response_id})
       when is_binary(response_id) do
    if String.trim(response_id) == "" do
      compact_payload
    else
      Map.put(compact_payload, "previous_response_id", response_id)
    end
  end

  defp maybe_put_previous_response_id(compact_payload, _payload), do: compact_payload

  defp maybe_put_stream(payload, :sse), do: Map.put(payload, "stream", true)
  defp maybe_put_stream(payload, :buffered), do: Map.delete(payload, "stream")

  defp decode_result(%{raw_body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _result -> {:error, :invalid_json}
    end
  end

  defp decode_result(%{body: body}) when is_map(body), do: {:ok, body}
  defp decode_result(_result), do: {:error, :invalid_json}

  defp compaction_item(%{"output" => output} = decoded) when is_list(output) do
    output
    |> Enum.find_value(fn
      %{"type" => type, "encrypted_content" => content} = item
      when type in ["compaction", "compaction_summary"] and is_binary(content) ->
        validate_native_compaction_item(item)

      _item ->
        nil
    end)
    |> case do
      nil -> compaction_item_from_summary(decoded)
      result -> result
    end
  end

  defp compaction_item(decoded), do: compaction_item_from_summary(decoded)

  defp compaction_item(decoded, :sse), do: compaction_item(decoded)

  defp compaction_item(decoded, :native_websocket), do: compaction_item(decoded)

  defp compaction_item(decoded, mode) when mode in [:public_sse, :response, :websocket],
    do: public_compaction_item(decoded)

  defp compaction_item_from_summary(%{"compaction_summary" => item}) when is_map(item),
    do: validate_native_compaction_item(item)

  defp compaction_item_from_summary(_decoded), do: {:error, :missing_encrypted_content}

  defp validate_native_compaction_item(%{"encrypted_content" => content} = source_item)
       when is_binary(content) do
    if nonblank_compaction_content?(content) do
      {:ok, normalize_native_item(source_item)}
    else
      {:error, :missing_encrypted_content}
    end
  end

  defp validate_native_compaction_item(_source_item),
    do: {:error, :missing_encrypted_content}

  defp public_compaction_item(%{"output" => output} = decoded) when is_list(output) do
    case Enum.find(output, &public_compaction_candidate?/1) do
      nil -> public_compaction_item_from_summary(decoded)
      candidate -> validate_public_compaction_item(candidate)
    end
  end

  defp public_compaction_item(decoded), do: public_compaction_item_from_summary(decoded)

  defp public_compaction_candidate?(%{"type" => type})
       when type in ["compaction", "compaction_summary"],
       do: true

  defp public_compaction_candidate?(_item), do: false

  defp public_compaction_item_from_summary(%{"compaction_summary" => item}) when is_map(item),
    do: validate_public_compaction_item(item)

  defp public_compaction_item_from_summary(_decoded), do: {:error, :missing_encrypted_content}

  defp validate_public_compaction_item(%{"encrypted_content" => content} = source_item)
       when is_binary(content) do
    if nonblank_compaction_content?(content) do
      {:ok, normalize_public_compaction_item(source_item)}
    else
      {:error, :missing_encrypted_content}
    end
  end

  defp validate_public_compaction_item(_source_item),
    do: {:error, :missing_encrypted_content}

  defp nonblank_compaction_content?(content), do: String.trim(content) != ""

  defp normalize_public_compaction_item(source_item) do
    item = %{
      "type" => "compaction",
      "encrypted_content" => source_item["encrypted_content"]
    }

    case Map.fetch(source_item, "id") do
      {:ok, id} when is_nil(id) or is_binary(id) -> Map.put(item, "id", id)
      _result -> item
    end
  end

  @doc false
  @spec normalize_native_item(payload()) :: payload()
  def normalize_native_item(source_item) when is_map(source_item) do
    %{
      "type" => "compaction",
      "encrypted_content" => source_item["encrypted_content"]
    }
    |> maybe_put_item_id(source_item)
    |> maybe_put_turn_id(source_item)
  end

  defp maybe_put_item_id(item, %{"id" => id}) when is_binary(id), do: Map.put(item, "id", id)
  defp maybe_put_item_id(item, _source_item), do: item

  defp maybe_put_turn_id(
         item,
         %{"internal_chat_message_metadata_passthrough" => %{"turn_id" => turn_id}}
       )
       when is_binary(turn_id) do
    Map.put(item, "internal_chat_message_metadata_passthrough", %{"turn_id" => turn_id})
  end

  defp maybe_put_turn_id(item, _source_item), do: item

  defp sse_body(decoded, item, response_builder \\ &response/2) do
    response = response_builder.(decoded, item)

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

  defp adapted_result(result, decoded, item, :sse) do
    %{
      status: 200,
      headers: stream_headers(result),
      raw_body: sse_body(decoded, item)
    }
  end

  defp adapted_result(result, decoded, item, :public_sse) do
    %{
      status: 200,
      headers: stream_headers(result),
      raw_body: sse_body(decoded, item, &public_response/2)
    }
  end

  defp adapted_result(result, decoded, item, :response) do
    response = public_response(decoded, item)

    %{
      status: 200,
      headers: json_headers(result),
      raw_body: Jason.encode!(response)
    }
  end

  defp adapted_result(result, decoded, item, :websocket) do
    %{
      status: 200,
      headers: json_headers(result),
      websocket_messages: [
        %{"type" => "response.output_item.done", "item" => item},
        %{"type" => "response.completed", "response" => public_response(decoded, item)}
      ]
    }
  end

  defp adapted_result(result, decoded, item, :native_websocket) do
    %{
      status: 200,
      headers: json_headers(result),
      websocket_messages: [
        %{"type" => "response.output_item.done", "item" => item},
        %{"type" => "response.completed", "response" => response(decoded, item)}
      ]
    }
  end

  defp public_response(decoded, item), do: Map.put(response(decoded, item), "object", "response")

  defp response(decoded, item) do
    %{
      "id" => response_id(decoded),
      "status" => "completed",
      "output" => [item]
    }
    |> maybe_put_usage(decoded)
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

  defp json_headers(result) do
    result
    |> Map.get(:headers, [])
    |> Enum.reject(fn {key, _value} ->
      normalized = String.downcase(key)
      normalized in ["content-type", "content-length"]
    end)
    |> Kernel.++([{"content-type", "application/json"}])
  end
end
