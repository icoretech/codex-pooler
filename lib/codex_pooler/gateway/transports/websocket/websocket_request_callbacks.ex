defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type writer :: Request.writer() | nil
  @type materialize_error ::
          :upstream_identity_not_found
          | :invalid_writer
          | {:invalid_owner_request,
             WebsocketOwnerRequest.validation_error()
             | WebsocketOwnerRequestV2.validation_error()
             | WebsocketOwnerRequestV3.validation_error()}

  @spec mapper(WebsocketOwnerRequest.mapper() | term()) ::
          {:ok, (binary() -> binary())} | {:error, :invalid_mapper}
  def mapper(:public_openai_responses),
    do: {:ok, &StreamProtocol.normalize_public_openai_responses_json_message/1}

  def mapper(:native_codex_responses),
    do: {:ok, &StreamProtocol.canonicalize_native_codex_responses_json_message/1}

  def mapper(:codex_responses),
    do: {:ok, &StreamProtocol.canonicalize_codex_responses_json_message/1}

  def mapper(_mapper), do: {:error, :invalid_mapper}

  @spec materialize(
          WebsocketOwnerRequest.t()
          | WebsocketOwnerRequestV2.t()
          | WebsocketOwnerRequestV3.t()
          | map(),
          writer()
        ) ::
          {:ok, Request.t()} | {:error, materialize_error()}
  def materialize(%WebsocketOwnerRequestV3{} = owner_request, nil) do
    with :ok <- validate_v3(owner_request),
         %UpstreamIdentity{} = identity <-
           Upstreams.get_upstream_identity(owner_request.upstream_identity_id),
         {:ok, message_mapper} <- mapper(owner_request.mapper) do
      capability = owner_request.owner_admission_capability
      first_compact_collection = owner_request.first_compact_collection
      binding = if capability, do: capability.binding, else: first_compact_collection.binding

      {:ok,
       %Request{
         url: owner_request.url,
         headers: owner_request.headers,
         payload: owner_request.payload,
         timeouts: owner_request.timeouts,
         writer: nil,
         message_mapper: message_mapper,
         frame_observer: frame_observer(identity, owner_request.observation),
         submission_observer: nil,
         reset_probe: owner_request.reset_probe,
         native_codex_response_control: owner_request.native_codex_response_control,
         native_compaction_capability: capability,
         first_compact_collection: first_compact_collection,
         expected_connection_lifecycle: %{
           lifecycle_id: binding.lifecycle_id,
           generation: binding.generation
         },
         assignment_advertised?: owner_request.assignment_advertised?,
         connection_bound_continuation?: owner_request.connection_bound_continuation?,
         websocket_delivery_mode: owner_request.websocket_delivery_mode,
         effective_serving_mode: Atom.to_string(owner_request.effective_serving_mode),
         forward_error_body?: owner_request.forward_error_body?
       }}
    else
      nil -> {:error, :upstream_identity_not_found}
      {:error, :invalid_mapper} -> {:error, {:invalid_owner_request, {:invalid_field, :mapper}}}
      {:error, _reason} = error -> error
    end
  end

  def materialize(%WebsocketOwnerRequestV3{}, _writer), do: {:error, :invalid_writer}

  def materialize(%WebsocketOwnerRequestV2{} = owner_request, nil) do
    with :ok <- validate_v2(owner_request),
         %UpstreamIdentity{} = identity <-
           Upstreams.get_upstream_identity(owner_request.upstream_identity_id),
         {:ok, message_mapper} <- mapper(owner_request.mapper) do
      {:ok,
       %Request{
         url: owner_request.url,
         headers: owner_request.headers,
         payload: owner_request.payload,
         timeouts: owner_request.timeouts,
         writer: nil,
         message_mapper: message_mapper,
         frame_observer: frame_observer(identity, owner_request.observation),
         submission_observer: nil,
         reset_probe: owner_request.reset_probe,
         native_codex_response_control: owner_request.native_codex_response_control,
         assignment_advertised?: owner_request.assignment_advertised?,
         connection_bound_continuation?: owner_request.connection_bound_continuation?,
         websocket_delivery_mode: :collect_compaction,
         effective_serving_mode: Atom.to_string(owner_request.effective_serving_mode),
         forward_error_body?: owner_request.forward_error_body?
       }}
    else
      nil -> {:error, :upstream_identity_not_found}
      {:error, :invalid_mapper} -> {:error, {:invalid_owner_request, {:invalid_field, :mapper}}}
      {:error, _reason} = error -> error
    end
  end

  def materialize(%WebsocketOwnerRequestV2{}, _writer), do: {:error, :invalid_writer}

  def materialize(owner_request, writer) do
    with {:ok, owner_request} <- validated_request(owner_request),
         :ok <- validate_writer(writer),
         %UpstreamIdentity{} = identity <-
           Upstreams.get_upstream_identity(owner_request.upstream_identity_id),
         {:ok, message_mapper} <- mapper(owner_request.mapper) do
      {:ok,
       %Request{
         url: owner_request.url,
         headers: owner_request.headers,
         payload: owner_request.payload,
         timeouts: owner_request.timeouts,
         writer: observing_writer(writer, owner_request.observation),
         message_mapper: message_mapper,
         frame_observer: frame_observer(identity, owner_request.observation),
         submission_observer: nil,
         reset_probe: owner_request.reset_probe,
         native_codex_response_control: owner_request.native_codex_response_control,
         effective_serving_mode: owner_request.observation.mode,
         assignment_advertised?: owner_request.assignment_advertised?,
         connection_bound_continuation?: owner_request.connection_bound_continuation?,
         forward_error_body?: owner_request.forward_error_body?
       }}
    else
      nil -> {:error, :upstream_identity_not_found}
      {:error, :invalid_mapper} -> {:error, {:invalid_owner_request, {:invalid_field, :mapper}}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_v2(request) do
    case WebsocketOwnerRequestV2.validate(request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_v3(request) do
    case WebsocketOwnerRequestV3.validate(request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  @spec frame_observer(UpstreamIdentity.t(), WebsocketOwnerRequest.observation()) ::
          (binary(), map() | nil -> :ok)
  def frame_observer(%UpstreamIdentity{} = identity, observation) do
    fn
      _frame, %{} = decoded ->
        RateLimitObserver.record_complete_event(identity, decoded)
        emit_product_observation(observation, :provider_to_pooler, decoded)

      frame, _decoded ->
        RateLimitObserver.record_complete_events(identity, frame)
    end
  end

  @spec observing_writer(writer(), WebsocketOwnerRequest.observation()) :: writer()
  def observing_writer(nil, _observation), do: nil

  def observing_writer(writer, observation) when is_function(writer, 2) do
    fn text, terminal_discriminator ->
      result = writer.(text, terminal_discriminator)
      emit_downstream_observation(observation, text)
      result
    end
  end

  def observing_writer(writer, observation) when is_function(writer, 1) do
    fn text ->
      result = writer.(text)
      emit_downstream_observation(observation, text)
      result
    end
  end

  defp validated_request(%WebsocketOwnerRequest{} = request) do
    case WebsocketOwnerRequest.validate(request) do
      :ok -> {:ok, request}
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validated_request(attrs) do
    case WebsocketOwnerRequest.new(attrs) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_writer(nil), do: :ok
  defp validate_writer(writer) when is_function(writer, 1) or is_function(writer, 2), do: :ok
  defp validate_writer(_writer), do: {:error, :invalid_writer}

  defp emit_downstream_observation(observation, text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} -> emit_product_observation(observation, :pooler_to_codex, decoded)
      _not_json -> :ok
    end
  end

  defp emit_product_observation(observation, direction, decoded) do
    if Application.get_env(:codex_pooler, :multi_agent_round_product_observation_enabled, false) do
      case Map.get(decoded, "type") do
        event_type when event_type in ["response.output_text.delta", "response.completed"] ->
          metadata =
            observation
            |> Map.put(:route, "backend_websocket")
            |> Map.put(:direction, direction)
            |> Map.put(:event_type, event_type)
            |> Map.put(:response_fingerprint, response_fingerprint(decoded))

          :telemetry.execute(
            [:codex_pooler, :gateway, :multi_agent_round, :product_stage],
            %{count: 1},
            metadata
          )

        _other ->
          :ok
      end
    end
  end

  defp response_fingerprint(decoded) do
    response_id =
      case decoded do
        %{"response" => %{"id" => id}} when is_binary(id) -> id
        %{"response_id" => id} when is_binary(id) -> id
        %{"id" => id} when is_binary(id) -> id
        _other -> nil
      end

    if is_binary(response_id) do
      :sha256
      |> :crypto.hash(response_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)
    end
  end
end
