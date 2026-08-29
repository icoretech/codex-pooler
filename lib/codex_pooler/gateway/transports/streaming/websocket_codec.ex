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
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability
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
  @type prepared_result :: {:ok, PreparedWebsocketFrame.t()} | {:error, gateway_error()}

  @stream_id_pattern ~r/\A[A-Za-z0-9_.-]+\z/
  @prepared_frame_salt "gateway websocket prepared frame v1"
  @prepared_validation_salt "gateway websocket payload validation v1"

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

  @spec prepare_frame(binary(), RequestOptions.t(), (binary() -> any())) :: prepared_result()
  def prepare_frame(raw_payload, %RequestOptions{} = opts, push_frame)
      when is_binary(raw_payload) and is_function(push_frame, 1) do
    with {:ok, payload} <- decode_prepared_payload(raw_payload),
         {:ok, prepared} <- prepare_decoded_frame(payload, opts, push_frame) do
      prepared = seal_prepared_frame(prepared)
      notify_preparation_observer(prepared.request_options)
      {:ok, prepared}
    end
  end

  def prepare_frame(_raw_payload, _opts, _push_frame) do
    {:error, Error.invalid_request("websocket message must be a text JSON frame")}
  end

  defp prepare_decoded_frame(%{"type" => "response.processed"} = payload, opts, _push_frame) do
    with :ok <- validate_response_processed(payload) do
      {:ok,
       %PreparedWebsocketFrame{
         variant: :response_processed,
         endpoint: "/backend-api/codex/responses",
         payload: payload,
         request_options: websocket_request_options(opts, payload)
       }}
    end
  end

  defp prepare_decoded_frame(%{"generate" => false} = payload, opts, _push_frame) do
    with :ok <- validate_optional_model(payload) do
      {:ok,
       %PreparedWebsocketFrame{
         variant: :prewarm,
         endpoint: "/backend-api/codex/responses",
         payload: payload,
         request_options: websocket_request_options(opts, payload)
       }}
    end
  end

  defp prepare_decoded_frame(%{"type" => "response.create"} = payload, opts, push_frame) do
    with :ok <- validate_native_response_model(payload, opts),
         :ok <- validate_native_compaction_placement(payload, opts),
         {:ok, coerced} <- coerce_request(payload, opts, push_frame) do
      request_options = coerced.request_options

      {:ok,
       %PreparedWebsocketFrame{
         variant: response_create_variant(opts),
         endpoint: coerced.endpoint,
         payload: prepared_payload(coerced.payload, opts),
         request_options: request_options,
         semantic_turn_key: request_options.continuity.semantic_turn_key,
         turn_claim_key: request_options.continuity.turn_claim_key,
         result_adapter: Map.get(coerced, :result_adapter)
       }}
    end
  end

  defp prepare_decoded_frame(
         payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: false}} = opts,
         push_frame
       ) do
    prepare_decoded_frame(Map.put_new(payload, "type", "response.create"), opts, push_frame)
  end

  defp prepare_decoded_frame(_payload, _opts, _push_frame) do
    {:error, Error.invalid_request("websocket message type is not supported", "type")}
  end

  defp decode_prepared_payload(raw_payload) do
    case decode_payload(raw_payload) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, :not_object} ->
        {:error, Error.invalid_request("websocket message must be a JSON object")}

      {:error, :invalid_json} ->
        {:error, Error.invalid_request("websocket message must be valid JSON")}
    end
  end

  defp validate_response_processed(%{"response_id" => response_id})
       when is_binary(response_id) do
    if String.trim(response_id) == "" do
      {:error, Error.invalid_request("response.processed requires response_id")}
    else
      :ok
    end
  end

  defp validate_response_processed(_payload),
    do: {:error, Error.invalid_request("response.processed requires response_id")}

  defp validate_native_response_model(
         _payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}}
       ),
       do: :ok

  defp validate_native_response_model(%{"model" => model}, %RequestOptions{})
       when is_binary(model) do
    if String.trim(model) == "" do
      {:error, Error.invalid_request("model is required", "model")}
    else
      :ok
    end
  end

  defp validate_native_response_model(_payload, %RequestOptions{}),
    do: {:error, Error.invalid_request("model is required", "model")}

  defp validate_optional_model(payload) do
    case Map.fetch(payload, "model") do
      :error ->
        :ok

      {:ok, model} when is_binary(model) ->
        if String.trim(model) == "",
          do: {:error, Error.invalid_request("model is required", "model")},
          else: :ok

      {:ok, _invalid} ->
        {:error, Error.invalid_request("model is required", "model")}
    end
  end

  defp validate_native_compaction_placement(
         _payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}}
       ),
       do: :ok

  defp validate_native_compaction_placement(%{"input" => input} = payload, %RequestOptions{})
       when is_list(input) do
    if Enum.any?(input, &match?(%{"type" => "compaction_trigger"}, &1)) do
      case CompactionTrigger.prepare_bridge(
             "/backend-api/codex/responses",
             Map.put(payload, "stream", true)
           ) do
        {:error, reason} -> {:error, reason}
        _valid -> :ok
      end
    else
      :ok
    end
  end

  defp validate_native_compaction_placement(_payload, %RequestOptions{}), do: :ok

  @spec valid_prepared_frame?(PreparedWebsocketFrame.t()) :: boolean()
  def valid_prepared_frame?(
        %PreparedWebsocketFrame{
          provenance: %{
            frame: token,
            validation: validation_token,
            capability: capability
          }
        } = prepared
      )
      when is_binary(token) and is_binary(validation_token) do
    valid_signed_digest?(
      @prepared_frame_salt,
      token,
      prepared_frame_digest(prepared, validation_token, capability)
    )
  end

  def valid_prepared_frame?(_prepared), do: false

  @spec consume_prepared_frame(PreparedWebsocketFrame.t()) ::
          :ok | {:error, :consumed | :invalid}
  def consume_prepared_frame(
        %PreparedWebsocketFrame{
          provenance: %{frame: frame_token, capability: capability}
        } = prepared
      ) do
    if valid_prepared_frame?(prepared) do
      Capability.consume(capability, frame_token)
    else
      {:error, :invalid}
    end
  end

  def consume_prepared_frame(_prepared), do: {:error, :invalid}

  @spec prevalidated_request?(map(), RequestOptions.t(), binary()) :: boolean()
  def prevalidated_request?(
        payload,
        %RequestOptions{} = request_options,
        token
      )
      when is_map(payload) and is_binary(token) do
    valid_signed_digest?(
      @prepared_validation_salt,
      token,
      validation_digest(payload, request_options)
    )
  end

  def prevalidated_request?(_payload, %RequestOptions{}, _token), do: false

  defp seal_prepared_frame(%PreparedWebsocketFrame{} = prepared) do
    validation_token =
      sign_digest(
        @prepared_validation_salt,
        validation_digest(prepared.payload, prepared.request_options)
      )

    capability = Capability.issue()

    frame_token =
      sign_digest(
        @prepared_frame_salt,
        prepared_frame_digest(prepared, validation_token, capability)
      )

    :ok = Capability.seal(capability, frame_token)

    %{
      prepared
      | provenance: %{frame: frame_token, validation: validation_token, capability: capability}
    }
  end

  defp prepared_frame_digest(
         %PreparedWebsocketFrame{} = prepared,
         validation_token,
         capability
       ) do
    {capability_server, capability_reference} = Capability.digest_identity(capability)

    digest_term({
      prepared.variant,
      prepared.endpoint,
      prepared.payload,
      prepared.semantic_turn_key,
      prepared.turn_claim_key,
      validation_token,
      capability_server,
      capability_reference,
      is_function(prepared.result_adapter, 1)
    })
  end

  defp validation_digest(payload, %RequestOptions{} = request_options) do
    digest_term({
      payload,
      request_options.transport.transport,
      request_options.transport.upstream_endpoint,
      request_options.payload_context,
      RequestOptions.use_responses_lite?(request_options),
      RequestOptions.OpenAICompatibility.translated_responses_surface?(
        request_options.openai_compatibility
      )
    })
  end

  defp digest_term(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
  end

  defp sign_digest(salt, digest) do
    :crypto.mac(:hmac, :sha256, provenance_key(salt), digest)
  end

  defp valid_signed_digest?(salt, token, expected_digest) do
    expected_token = sign_digest(salt, expected_digest)

    byte_size(token) == byte_size(expected_token) and
      Plug.Crypto.secure_compare(token, expected_token)
  end

  defp provenance_key(salt) do
    :crypto.hash(:sha256, secret_key_base() <> <<0>> <> salt)
  end

  defp secret_key_base do
    :codex_pooler
    |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  defp response_create_variant(%RequestOptions{
         openai_compatibility: %{public_openai_responses_stream: true}
       }),
       do: :public_response_create

  defp response_create_variant(%RequestOptions{}), do: :native_response_create

  defp prepared_payload(
         payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}}
       ),
       do: payload

  defp prepared_payload(payload, %RequestOptions{}) do
    payload
    |> Map.drop(["turn_id", "request_id"])
    |> scrub_client_metadata_turn_id()
  end

  defp scrub_client_metadata_turn_id(%{"client_metadata" => client_metadata} = payload)
       when is_map(client_metadata) do
    client_metadata =
      client_metadata
      |> Map.delete("turn_id")
      |> scrub_canonical_metadata_turn_id()

    Map.put(payload, "client_metadata", client_metadata)
  end

  defp scrub_client_metadata_turn_id(payload), do: payload

  defp scrub_canonical_metadata_turn_id(%{"x-codex-turn-metadata" => metadata} = client_metadata)
       when is_map(metadata) do
    Map.put(client_metadata, "x-codex-turn-metadata", Map.delete(metadata, "turn_id"))
  end

  defp scrub_canonical_metadata_turn_id(%{"x-codex-turn-metadata" => encoded} = client_metadata)
       when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, metadata} when is_map(metadata) ->
        Map.put(
          client_metadata,
          "x-codex-turn-metadata",
          metadata |> Map.delete("turn_id") |> Jason.encode!()
        )

      _validated_earlier ->
        client_metadata
    end
  end

  defp scrub_canonical_metadata_turn_id(client_metadata), do: client_metadata

  defp websocket_request_options(%RequestOptions{} = opts, payload) do
    opts
    |> RequestOptions.for_payload("/backend-api/codex/responses", payload)
    |> RequestOptions.put_transport(
      transport: "websocket",
      upstream_endpoint: "/backend-api/codex/responses",
      route_class: RouteClass.proxy_websocket()
    )
  end

  defp notify_preparation_observer(%RequestOptions{
         extra: %{websocket_preparation_observer: observer}
       })
       when is_function(observer, 0),
       do: observer.()

  defp notify_preparation_observer(%RequestOptions{}), do: :ok

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

  @spec response_writer(RequestOptions.t(), (binary() -> any())) ::
          nil | (binary() -> any())
  def response_writer(
        %RequestOptions{transport: %{websocket_writer: nil}},
        _push_frame
      ),
      do: nil

  def response_writer(%RequestOptions{} = request_options, push_frame)
      when is_function(push_frame, 1),
      do: namespace_restoring_writer(push_frame, request_options)

  @spec coerce_request(map(), RequestOptions.t(), (binary() -> any())) ::
          {:ok, coerced_request()} | {:error, gateway_error()}
  def coerce_request(payload, %RequestOptions{} = opts, push_frame)
      when is_map(payload) and is_function(push_frame, 1) do
    with {:ok, coerced} <- coerce_response_payload(payload, opts),
         {:ok, turn_identity} <- native_turn_identity(payload, opts) do
      request_options =
        coerced
        |> request_options(push_frame)
        |> maybe_put_backend_turn_state(coerced.endpoint, coerced.payload)
        |> put_native_turn_identity(turn_identity)

      {:ok, %{coerced | request_options: request_options}}
    end
  end

  defp native_turn_identity(
         _payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}}
       ),
       do: {:ok, :missing}

  defp native_turn_identity(%{"type" => "response.create"} = payload, %RequestOptions{} = opts) do
    case WebsocketTurnIdentity.resolve(payload, codex_session_id(opts)) do
      {:ok, identity} -> {:ok, identity}
      :missing -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp native_turn_identity(_payload, %RequestOptions{}), do: {:ok, :missing}

  defp codex_session_id(%RequestOptions{continuity: %{codex_session: %{id: id}}})
       when is_binary(id),
       do: id

  defp codex_session_id(%RequestOptions{}), do: nil

  defp put_native_turn_identity(%RequestOptions{} = request_options, :missing),
    do: request_options

  defp put_native_turn_identity(%RequestOptions{} = request_options, identity) do
    RequestOptions.put_continuity(request_options,
      semantic_turn_key: identity.semantic_turn_key,
      turn_claim_key: identity.turn_claim_key
    )
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
