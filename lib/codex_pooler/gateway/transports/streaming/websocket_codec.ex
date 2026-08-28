defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketCodec do
  @moduledoc """
  Conversion helpers for Codex public websocket frames and upstream stream data.
  """

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.CompactionTrigger
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext
  alias CodexPooler.Gateway.Payloads.ToolResultShape
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.RouteClass

  @type decode_error :: :invalid_json | :not_object
  @type gateway_error :: Contracts.gateway_error()
  @type gateway_call_result :: {:ok, Contracts.gateway_result()} | {:error, gateway_error()}
  @type deliver_result :: :ok | {:error, gateway_error()}
  @type stream_id_result :: :omitted | {:ok, String.t()} | {:error, gateway_error()}
  @type coerced_request :: %{
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          required(:request_options) => RequestOptions.t(),
          optional(:result_adapter) => (gateway_call_result() -> gateway_call_result())
        }

  @stream_id_pattern ~r/\A[A-Za-z0-9_.-]+\z/

  @spec decode_payload(binary()) :: {:ok, map()} | {:error, decode_error()}
  def decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error, :not_object}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  @spec stream_id(term()) :: stream_id_result()
  def stream_id(payload) when is_binary(payload) do
    case decode_payload(payload) do
      {:ok, decoded} -> stream_id(decoded)
      {:error, _reason} -> :omitted
    end
  end

  def stream_id(%{} = payload) do
    case Map.fetch(payload, "stream_id") do
      :error -> :omitted
      {:ok, value} -> validate_stream_id(value)
    end
  end

  def stream_id(_payload), do: :omitted

  @spec deliver_result(map(), (binary() -> any())) :: deliver_result()
  def deliver_result(%{websocket_stream: stream}, _push_frame) do
    stream.()
    |> normalize_websocket_stream_result()
  end

  def deliver_result(%{websocket_messages: messages}, push_frame) do
    Enum.each(messages, fn message -> push_frame.(Jason.encode!(message)) end)
    :ok
  end

  def deliver_result(%{raw_body: body}, push_frame) do
    push_frame.(body)
    :ok
  end

  def deliver_result(%{body: body}, push_frame) do
    push_frame.(Jason.encode!(body))
    :ok
  end

  defp normalize_websocket_stream_result(:ok), do: :ok
  defp normalize_websocket_stream_result({:ok, _result}), do: :ok

  defp normalize_websocket_stream_result(
         {:error, %{status: status, code: code, message: message}} = error
       )
       when is_integer(status) and status > 0 and (is_binary(code) or is_atom(code)) and
              is_binary(message),
       do: error

  defp normalize_websocket_stream_result(_result) do
    {:error,
     %{
       status: 502,
       code: "websocket_stream_error",
       message: "websocket stream failed"
     }}
  end

  @spec warmup_result() :: map()
  def warmup_result do
    response = %{"id" => "", "usage" => nil, "end_turn" => true}

    %{
      websocket_messages: [
        %{"type" => "response.created", "response" => response},
        %{"type" => "response.completed", "response" => response}
      ]
    }
  end

  @spec ack_result() :: map()
  def ack_result, do: %{websocket_messages: []}

  @spec coerce_request(map(), RequestOptions.t(), (binary() -> any())) ::
          {:ok, coerced_request()} | {:error, gateway_error()}
  def coerce_request(payload, %RequestOptions{} = opts, push_frame)
      when is_map(payload) and is_function(push_frame, 1) do
    with {:ok, coerced} <- coerce_response_payload(payload, opts) do
      request_options =
        coerced
        |> request_options(push_frame)
        |> maybe_put_backend_turn_state(coerced.endpoint, coerced.payload)
        |> RequestOptions.put_continuity(
          codex_turn_id: SessionContinuity.websocket_turn_id(coerced.payload)
        )

      {:ok, %{coerced | request_options: request_options}}
    end
  end

  defp namespace_restoring_writer(
         push_frame,
         %RequestOptions{openai_compatibility: %{custom_tool_namespaces: namespaces}}
       )
       when is_function(push_frame, 1) and map_size(namespaces) > 0 do
    fn data -> push_frame.(restore_custom_tool_call_namespaces(data, namespaces)) end
  end

  defp namespace_restoring_writer(push_frame, %RequestOptions{}), do: push_frame

  defp request_options(%{result_adapter: result_adapter} = coerced, _push_frame)
       when is_function(result_adapter, 1) do
    RequestOptions.for_payload(coerced.request_options, coerced.endpoint, coerced.payload)
  end

  defp request_options(coerced, push_frame) do
    push_frame = namespace_restoring_writer(push_frame, coerced.request_options)

    coerced.request_options
    |> RequestOptions.for_payload(coerced.endpoint, coerced.payload)
    |> RequestOptions.put_transport(
      transport: "websocket",
      upstream_endpoint: coerced.endpoint,
      route_class: RouteClass.proxy_websocket(),
      websocket_writer: push_frame
    )
  end

  defp restore_custom_tool_call_namespaces(data, namespaces) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        restored = Responses.restore_custom_tool_call_namespaces(decoded, namespaces)
        if restored === decoded, do: data, else: Jason.encode!(restored)

      _invalid ->
        data
    end
  end

  @spec response_processed_payload?(map()) :: boolean()
  def response_processed_payload?(%{"type" => "response.processed"}), do: true
  def response_processed_payload?(_payload), do: false

  @spec warmup_payload?(map()) :: boolean()
  def warmup_payload?(%{"generate" => false}), do: true
  def warmup_payload?(_payload), do: false

  @spec request_row_producing_response_payload?(term()) :: boolean()
  def request_row_producing_response_payload?(payload) when is_binary(payload) do
    case decode_payload(payload) do
      {:ok, decoded} -> request_row_producing_response_payload(decoded)
      {:error, _reason} -> false
    end
  end

  def request_row_producing_response_payload?(_payload), do: false

  @spec continuity_ordered_payload?(term()) :: boolean()
  def continuity_ordered_payload?(payload) when is_binary(payload) do
    case decode_payload(payload) do
      {:ok, decoded} -> continuity_ordered_payload(decoded)
      {:error, _reason} -> false
    end
  end

  def continuity_ordered_payload?(_payload), do: false

  @spec stream_messages(Ecto.UUID.t() | %{optional(:id) => Ecto.UUID.t()}, term()) :: [binary()]
  def stream_messages(request, data) do
    {messages, _state} =
      stream_messages(request, data, StreamProtocol.new_sse_block_state())

    messages
  end

  @spec stream_messages(
          Ecto.UUID.t() | %{optional(:id) => Ecto.UUID.t()},
          term(),
          StreamProtocol.sse_block_state()
        ) :: {[binary()], StreamProtocol.sse_block_state()}
  def stream_messages(%{id: request_id}, data, state),
    do: stream_messages(request_id, data, state)

  def stream_messages(request_id, data, %{buffer: buffer} = state)
      when is_binary(request_id) and is_binary(data) and is_binary(buffer) do
    buffered_size = byte_size(buffer) + byte_size(data)
    {blocks, state} = StreamProtocol.complete_sse_blocks(state, data, bounded?: true)

    if oversized_incomplete_sse_prefix?(blocks, state.buffer, buffered_size) do
      BufferTelemetry.record_oversized_incomplete(
        "websocket_sse",
        buffered_size,
        StreamProtocol.max_incomplete_sse_block_bytes()
      )
    end

    messages =
      case messages_from_sse_blocks(blocks) do
        [] -> direct_json_message(data)
        messages -> messages
      end

    {messages, state}
  end

  def stream_messages(_request_id, _data, _state),
    do: {[], StreamProtocol.new_sse_block_state()}

  defp oversized_incomplete_sse_prefix?([], "", buffered_size),
    do: buffered_size > StreamProtocol.max_incomplete_sse_block_bytes()

  defp oversized_incomplete_sse_prefix?(_blocks, _buffer, _buffered_size), do: false

  defp messages_from_sse_blocks(blocks) do
    blocks
    |> Enum.map(&StreamProtocol.sse_field(&1, "data"))
    |> Enum.reject(&(&1 in [nil, "[DONE]"]))
    |> Enum.flat_map(&canonical_sse_data_message/1)
  end

  defp canonical_sse_data_message(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        {canonical, _decoded} =
          StreamProtocol.canonicalize_codex_responses_json_message(data, decoded)

        [canonical]

      {:ok, _decoded} ->
        [data]

      {:error, _reason} ->
        []
    end
  end

  defp direct_json_message(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        {canonical, _decoded} =
          StreamProtocol.canonicalize_codex_responses_json_message(data, decoded)

        [canonical]

      {:ok, _decoded} ->
        [data]

      {:error, _reason} ->
        []
    end
  end

  defp coerce_response_payload(
         %{"type" => "response.create"} = payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}} = opts
       ) do
    with {:ok, payload} <- without_stream_id(payload) do
      payload
      |> Map.drop(["type", "generate"])
      |> Responses.coerce(opts)
      |> case do
        {:ok, coerced} ->
          coerced
          |> Map.update!(:payload, &Map.put(&1, "generate", true))
          |> prepare_public_compaction_bridge()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp coerce_response_payload(%{"type" => "response.create"} = payload, opts) do
    prepare_native_compaction_bridge(%{
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: opts
    })
  end

  defp coerce_response_payload(payload, opts) do
    {:ok, %{endpoint: "/backend-api/codex/responses", payload: payload, request_options: opts}}
  end

  defp prepare_native_compaction_bridge(%{payload: payload} = coerced) do
    result_transport = CompactionTrigger.compaction_result_transport(payload)
    coerced = put_native_compaction_input_mode(coerced)

    with {:ok, turn_state} <- validated_native_compaction_turn_state(payload) do
      prepare_native_compaction_bridge(coerced, result_transport, turn_state)
    end
  end

  defp put_native_compaction_input_mode(
         %{
           payload: payload,
           request_options: %RequestOptions{payload_context: payload_context} = request_options
         } = coerced
       ) do
    request_options = %{
      request_options
      | payload_context: %{
          payload_context
          | compaction_input_mode: CompactionTrigger.compaction_input_mode(payload)
        }
    }

    %{coerced | request_options: request_options}
  end

  defp prepare_native_compaction_bridge(coerced, result_transport, turn_state) do
    case CompactionTrigger.prepare_bridge("/backend-api/codex/responses", coerced.payload) do
      :passthrough ->
        {:ok, coerced}

      {:ok, compact_payload} ->
        downstream_payload = coerced.payload

        compact_payload =
          CompactionTrigger.project_responses_payload(compact_payload, result_transport)

        request_options =
          coerced.request_options
          |> RequestOptions.retarget("/backend-api/codex/responses/compact", compact_payload)
          |> put_native_compaction_transport()
          |> RequestOptions.put_payload_context(
            compaction_trigger_bridge?: true,
            compaction_result_transport: result_transport,
            compaction_result_mode: :native_websocket,
            compaction_projection_context:
              CompactionProjectionContext.new(downstream_payload, compact_payload)
          )
          |> put_validated_native_compaction_turn_state(turn_state)

        {:ok,
         %{
           coerced
           | endpoint: "/backend-api/codex/responses/compact",
             payload: compact_payload,
             request_options: request_options
         }
         |> Map.put(
           :result_adapter,
           &CompactionTrigger.adapt_gateway_result(&1, :native_websocket)
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_native_compaction_transport(
         %RequestOptions{
           payload_context: %{compaction_input_mode: :incremental}
         } = request_options
       ) do
    RequestOptions.put_transport(request_options,
      transport: "websocket",
      upstream_endpoint: "/backend-api/codex/responses",
      route_class: RouteClass.proxy_compact(),
      websocket_writer: nil,
      websocket_delivery_mode: :collect_compaction
    )
  end

  defp put_native_compaction_transport(%RequestOptions{} = request_options) do
    RequestOptions.put_transport(request_options,
      transport: "http_compact_json",
      upstream_endpoint: "/backend-api/codex/responses",
      route_class: RouteClass.proxy_compact(),
      websocket_writer: nil
    )
  end

  defp validated_native_compaction_turn_state(payload) do
    case PayloadNormalizer.validate_backend_compaction_turn_state(payload) do
      :passthrough -> {:ok, nil}
      {:ok, turn_state} -> {:ok, turn_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_validated_native_compaction_turn_state(request_options, nil), do: request_options

  defp put_validated_native_compaction_turn_state(request_options, turn_state) do
    forwarded_headers =
      request_options.transport.forwarded_metadata_headers
      |> Enum.reject(fn {name, _value} -> String.downcase(name) == "x-codex-turn-state" end)
      |> then(&[{"x-codex-turn-state", turn_state} | &1])

    request_options
    |> RequestOptions.put_continuity(accepted_turn_state: turn_state)
    |> RequestOptions.put_transport(forwarded_metadata_headers: forwarded_headers)
  end

  defp prepare_public_compaction_bridge(%{payload: payload} = coerced) do
    coerced = put_public_compaction_input_mode(coerced)

    case CompactionTrigger.prepare_bridge("/v1/responses", payload) do
      :passthrough ->
        {:ok, coerced}

      {:ok, compact_payload} ->
        downstream_payload = coerced.payload
        compact_payload = project_public_compaction_payload(coerced, compact_payload)

        request_options =
          coerced.request_options
          |> RequestOptions.retarget("/backend-api/codex/responses/compact", compact_payload)
          |> put_public_compaction_transport()
          |> RequestOptions.put_payload_context(
            compaction_trigger_bridge?: true,
            compaction_result_transport: public_compaction_result_transport(coerced),
            compaction_result_mode: :public_websocket,
            compaction_projection_context:
              CompactionProjectionContext.new(downstream_payload, compact_payload)
          )

        {:ok,
         %{
           coerced
           | endpoint: "/backend-api/codex/responses/compact",
             payload: compact_payload,
             request_options: request_options
         }
         |> Map.put(:result_adapter, &CompactionTrigger.adapt_gateway_result(&1, :websocket))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_public_compaction_input_mode(
         %{
           payload: payload,
           request_options: %RequestOptions{payload_context: payload_context} = request_options
         } = coerced
       ) do
    request_options = %{
      request_options
      | payload_context: %{
          payload_context
          | compaction_input_mode: CompactionTrigger.compaction_input_mode(payload)
        }
    }

    %{coerced | request_options: request_options}
  end

  defp project_public_compaction_payload(
         %{
           request_options: %RequestOptions{
             payload_context: %{compaction_input_mode: :incremental}
           }
         },
         compact_payload
       ) do
    CompactionTrigger.project_responses_payload(compact_payload, :sse)
  end

  defp project_public_compaction_payload(_coerced, compact_payload), do: compact_payload

  defp public_compaction_result_transport(%{
         request_options: %RequestOptions{payload_context: %{compaction_input_mode: :incremental}}
       }),
       do: :sse

  defp public_compaction_result_transport(_coerced), do: :buffered

  defp put_public_compaction_transport(
         %RequestOptions{payload_context: %{compaction_input_mode: :incremental}} =
           request_options
       ) do
    RequestOptions.put_transport(request_options,
      transport: "websocket",
      upstream_endpoint: "/backend-api/codex/responses",
      route_class: RouteClass.proxy_compact(),
      websocket_writer: nil,
      websocket_delivery_mode: :collect_compaction
    )
  end

  defp put_public_compaction_transport(%RequestOptions{} = request_options) do
    RequestOptions.put_transport(request_options,
      transport: "http_compact_json",
      upstream_endpoint: "/backend-api/codex/responses",
      route_class: RouteClass.proxy_compact(),
      websocket_writer: nil
    )
  end

  defp maybe_put_backend_turn_state(
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}} =
           request_options,
         _endpoint,
         _payload
       ) do
    request_options
  end

  defp maybe_put_backend_turn_state(
         %RequestOptions{} = request_options,
         "/backend-api/codex/responses",
         payload
       ) do
    case PayloadNormalizer.backend_client_metadata_turn_state(payload) do
      nil ->
        request_options

      turn_state ->
        RequestOptions.put_continuity(request_options, accepted_turn_state: turn_state)
    end
  end

  defp maybe_put_backend_turn_state(%RequestOptions{} = request_options, _endpoint, _payload),
    do: request_options

  defp request_row_producing_response_payload(%{"type" => "response.processed"}), do: true
  defp request_row_producing_response_payload(%{"generate" => false}), do: false
  defp request_row_producing_response_payload(%{"type" => "response.create"}), do: true

  defp request_row_producing_response_payload(%{"model" => model}) when is_binary(model),
    do: String.trim(model) != ""

  defp request_row_producing_response_payload(_payload), do: false

  defp continuity_ordered_payload(%{"type" => "response.processed"}), do: true

  defp continuity_ordered_payload(
         %{"type" => "response.create", "previous_response_id" => previous_response_id} =
           payload
       )
       when is_binary(previous_response_id) do
    if String.trim(previous_response_id) == "" do
      false
    else
      case CompactionTrigger.prepare_bridge("/backend-api/codex/responses", payload) do
        {:ok, _compact_payload} ->
          true

        :passthrough ->
          payload
          |> Map.get("input")
          |> ToolResultShape.items()
          |> Enum.any?()

        {:error, _reason} ->
          false
      end
    end
  end

  defp continuity_ordered_payload(_payload), do: false

  defp without_stream_id(payload) do
    case stream_id(payload) do
      :omitted -> {:ok, payload}
      {:ok, _stream_id} -> {:ok, Map.delete(payload, "stream_id")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_stream_id(stream_id) when is_binary(stream_id) do
    if byte_size(stream_id) in 1..256 and Regex.match?(@stream_id_pattern, stream_id) do
      {:ok, stream_id}
    else
      {:error, invalid_stream_id_error()}
    end
  end

  defp validate_stream_id(_stream_id), do: {:error, invalid_stream_id_error()}

  defp invalid_stream_id_error do
    Error.invalid_request(
      "stream_id must be 1-256 ASCII characters matching [A-Za-z0-9_.-]+",
      "stream_id"
    )
  end
end
