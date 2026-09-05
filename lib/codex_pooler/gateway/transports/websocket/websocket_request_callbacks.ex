defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.{ClientRetry, RequestReplayEntitlement}
  alias CodexPooler.Accounting.Request, as: AccountingRequest
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV4
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV5
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV6
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  # One receive call owns this bounded slot. Only a committed first-visible
  # transition makes replay impossible; pre-visible reads never grant a cache.
  @visibility_key {__MODULE__, :visibility}

  @doc false
  @spec begin_request(term(), term()) :: :ok
  def begin_request(request_id, attempt_id) do
    Process.put(@visibility_key, %{
      request_id: request_id,
      attempt_id: attempt_id,
      attempt: nil,
      committed?: false
    })

    :ok
  end

  @doc false
  @spec end_request() :: :ok
  def end_request do
    Process.delete(@visibility_key)
    :ok
  end

  @type writer :: Request.writer() | nil
  @type materialize_error ::
          :upstream_identity_not_found
          | :invalid_writer
          | {:invalid_owner_request,
             WebsocketOwnerRequest.validation_error()
             | WebsocketOwnerRequestV2.validation_error()
             | WebsocketOwnerRequestV3.validation_error()
             | WebsocketOwnerRequestV4.validation_error()
             | WebsocketOwnerRequestV6.validation_error()
             | WebsocketOwnerRequestV5.validation_error()}

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
          | WebsocketOwnerRequestV4.t()
          | WebsocketOwnerRequestV6.t()
          | WebsocketOwnerRequestV5.t()
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
         request_id: owner_request.observation.request_id,
         attempt_id: owner_request.observation.attempt_id,
         native_client_retry_observation:
           native_client_retry_observation(owner_request.observation),
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

  def materialize(%WebsocketOwnerRequestV5{} = owner_request, nil) do
    with :ok <- validate_v5(owner_request),
         :ok <- validate_client_retry_owner_request(owner_request),
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
         request_id: owner_request.observation.request_id,
         attempt_id: owner_request.observation.attempt_id,
         native_client_retry_observation: nil,
         client_retry_dispatch_authority: owner_request.client_retry_dispatch_authority,
         assignment_advertised?: owner_request.assignment_advertised?,
         connection_bound_continuation?: owner_request.connection_bound_continuation?,
         websocket_delivery_mode: :relay,
         effective_serving_mode: owner_request.observation.mode,
         forward_error_body?: owner_request.forward_error_body?
       }}
    else
      nil -> {:error, :upstream_identity_not_found}
      {:error, :invalid_mapper} -> {:error, {:invalid_owner_request, {:invalid_field, :mapper}}}
      {:error, _reason} = error -> error
    end
  end

  def materialize(%WebsocketOwnerRequestV5{}, _writer), do: {:error, :invalid_writer}

  def materialize(%WebsocketOwnerRequestV4{} = owner_request, nil) do
    with :ok <- validate_v4(owner_request),
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
         request_id: owner_request.observation.request_id,
         attempt_id: owner_request.observation.attempt_id,
         native_client_retry_observation:
           native_client_retry_observation(owner_request.observation),
         native_replay_binding: owner_request.native_replay_binding,
         native_replay_proof: owner_request.native_replay_proof,
         provisional_token: owner_request.provisional_token,
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

  def materialize(%WebsocketOwnerRequestV4{}, _writer), do: {:error, :invalid_writer}

  def materialize(%WebsocketOwnerRequestV3{}, _writer), do: {:error, :invalid_writer}

  def materialize(%WebsocketOwnerRequestV6{} = owner_request, nil) do
    with :ok <- validate_v6(owner_request),
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
         request_id: owner_request.observation.request_id,
         attempt_id: owner_request.observation.attempt_id,
         native_client_retry_observation:
           native_client_retry_observation(owner_request.observation),
         assignment_advertised?: owner_request.assignment_advertised?,
         connection_bound_continuation?: owner_request.connection_bound_continuation?,
         websocket_delivery_mode: :collect_full_history,
         native_compaction_metadata: owner_request.native_compaction_metadata,
         effective_serving_mode: Atom.to_string(owner_request.effective_serving_mode),
         forward_error_body?: owner_request.forward_error_body?
       }}
    else
      nil -> {:error, :upstream_identity_not_found}
      {:error, :invalid_mapper} -> {:error, {:invalid_owner_request, {:invalid_field, :mapper}}}
      {:error, _reason} = error -> error
    end
  end

  def materialize(%WebsocketOwnerRequestV6{}, _writer), do: {:error, :invalid_writer}

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
         request_id: owner_request.observation.request_id,
         attempt_id: owner_request.observation.attempt_id,
         native_client_retry_observation:
           native_client_retry_observation(owner_request.observation),
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
         request_id: owner_request.observation.request_id,
         attempt_id: owner_request.observation.attempt_id,
         native_client_retry_observation:
           native_client_retry_observation(owner_request.observation),
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

  defp validate_v6(request) do
    case WebsocketOwnerRequestV6.validate(request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_v2(request) do
    case WebsocketOwnerRequestV2.validate(request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp native_client_retry_observation(%{request_id: request_id}) when is_binary(request_id) do
    case Repo.get(AccountingRequest, request_id) do
      %AccountingRequest{} = request ->
        if ClientRetry.original_witness_eligible?(request),
          do: ClientRetry.new_observation()

      nil ->
        nil
    end
  end

  defp native_client_retry_observation(_observation), do: nil

  defp validate_v3(request) do
    case WebsocketOwnerRequestV3.validate(request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_v4(request) do
    case WebsocketOwnerRequestV4.validate(request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_v5(request) do
    case WebsocketOwnerRequestV5.validate(request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_client_retry_owner_request(owner_request) do
    with :ok <-
           ClientRetry.validate_dispatch_attempt(
             owner_request.observation.request_id,
             owner_request.observation.attempt_id,
             owner_request.client_retry_dispatch_authority
           ),
         %Attempt{upstream_identity_id: upstream_identity_id} <-
           Repo.get(Attempt, owner_request.observation.attempt_id),
         true <- upstream_identity_id == owner_request.upstream_identity_id do
      :ok
    else
      _failure ->
        {:error, {:invalid_owner_request, {:invalid_field, :client_retry_dispatch_authority}}}
    end
  end

  @spec frame_observer(UpstreamIdentity.t(), WebsocketOwnerRequest.observation()) ::
          (binary(), map() | nil -> :ok)
  def frame_observer(%UpstreamIdentity{} = identity, observation) do
    fn
      _frame, %{} = decoded ->
        with_observation_authority(observation, decoded, fn authority ->
          RateLimitObserver.record_complete_event(identity, decoded, authority)
          emit_product_observation(observation, :provider_to_pooler, decoded)
        end)

      frame, _decoded ->
        with_observation_authority(observation, frame, fn authority ->
          RateLimitObserver.record_complete_events(identity, frame, authority)
        end)
    end
  end

  @spec observing_writer(writer(), WebsocketOwnerRequest.observation()) :: writer()
  def observing_writer(nil, _observation), do: nil

  def observing_writer(writer, observation) when is_function(writer, 2) do
    fn text, terminal_discriminator ->
      with_authorized_observation(observation, text, fn _authority ->
        result = writer.(text, terminal_discriminator)
        emit_downstream_observation(observation, text)
        result
      end)
    end
  end

  def observing_writer(writer, observation) when is_function(writer, 1) do
    fn text ->
      with_authorized_observation(observation, text, fn _authority ->
        result = writer.(text)
        emit_downstream_observation(observation, text)
        result
      end)
    end
  end

  defp with_authorized_observation(
         %{request_id: request_id, attempt_id: attempt_id},
         data,
         callback
       )
       when is_binary(request_id) and is_binary(attempt_id) and is_function(callback, 1) do
    case {Ecto.UUID.cast(request_id), Ecto.UUID.cast(attempt_id)} do
      {{:ok, _request_uuid}, {:ok, _attempt_uuid}} ->
        with_current_attempt_observation(request_id, attempt_id, data, callback)

      _legacy_non_uuid_observation ->
        callback.(nil)
    end
  end

  defp with_authorized_observation(_observation, _data, callback) when is_function(callback, 1),
    do: callback.(nil)

  defp with_observation_authority(
         %{request_id: request_id, attempt_id: attempt_id},
         data,
         callback
       )
       when is_binary(request_id) and is_binary(attempt_id) and is_function(callback, 1) do
    case {Ecto.UUID.cast(request_id), Ecto.UUID.cast(attempt_id)} do
      {{:ok, _request_uuid}, {:ok, _attempt_uuid}} ->
        case observation_attempt(request_id, attempt_id) do
          %Attempt{request_id: ^request_id} = attempt ->
            authorize_observer_callback(request_id, attempt, data, callback)

          _missing_or_mismatched ->
            :ok
        end

      _legacy_non_uuid_observation ->
        callback.(nil)
    end
  end

  defp with_observation_authority(_observation, _data, callback) when is_function(callback, 1),
    do: callback.(nil)

  defp authorize_observer_callback(request_id, attempt, data, callback) do
    authority = generation_authority(attempt)

    cond do
      committed_visibility?(attempt) ->
        callback.(authority)

      StreamProtocol.internal_control_event?(data) ->
        if current_generation_snapshot?(request_id, attempt), do: callback.(authority), else: :ok

      true ->
        with_visible_attempt(request_id, attempt, fn -> callback.(authority) end)
    end
  end

  defp current_generation_snapshot?(request_id, %Attempt{replay_generation: generation}) do
    not Repo.exists?(
      from entitlement in RequestReplayEntitlement,
        where:
          entitlement.request_id == ^request_id and entitlement.replay_generation != ^generation
    )
  end

  defp with_current_attempt_observation(request_id, attempt_id, data, callback) do
    case observation_attempt(request_id, attempt_id) do
      %Attempt{request_id: ^request_id} = attempt ->
        run_current_attempt_observation(request_id, attempt, data, callback)

      _missing_or_mismatched ->
        :ok
    end
  end

  defp run_current_attempt_observation(request_id, attempt, data, callback) do
    authority = generation_authority(attempt)

    cond do
      committed_visibility?(attempt) ->
        callback.(authority)

      StreamProtocol.internal_control_event?(data) ->
        with_current_internal_attempt(request_id, attempt, fn -> callback.(authority) end)

      true ->
        with_visible_attempt(request_id, attempt, fn -> callback.(authority) end)
    end
  rescue
    Ecto.NoResultsError -> :ok
  end

  defp with_current_internal_attempt(request_id, attempt, callback) do
    request = %CodexPooler.Accounting.Request{id: request_id}

    case CodexPooler.Accounting.with_current_replay_generation(request, attempt, callback) do
      {:ok, result} -> result
      {:error, _reason} -> :ok
    end
  end

  defp observation_attempt(request_id, attempt_id) do
    case Process.get(@visibility_key) do
      %{request_id: ^request_id, attempt_id: ^attempt_id, attempt: %Attempt{} = attempt} ->
        attempt

      %{request_id: ^request_id, attempt_id: ^attempt_id} = witness ->
        attempt = Repo.get(Attempt, attempt_id)
        Process.put(@visibility_key, %{witness | attempt: attempt})
        attempt

      _outside_request ->
        Repo.get(Attempt, attempt_id)
    end
  end

  defp committed_visibility?(%Attempt{} = attempt) do
    case Process.get(@visibility_key) do
      %{attempt: %Attempt{} = observed, committed?: true} ->
        generation_authority(observed) == generation_authority(attempt)

      _uncommitted ->
        false
    end
  end

  defp with_visible_attempt(request_id, attempt, callback) do
    case SessionContinuity.authorize_codex_turn_visibility(request_id, attempt) do
      {:ok, :committed} ->
        cache_committed_visibility(attempt)
        callback.()

      {:ok, _not_committed} ->
        callback.()

      {:error, :stale_generation} ->
        :ok
    end
  end

  defp cache_committed_visibility(%Attempt{id: attempt_id, request_id: request_id} = attempt) do
    case Process.get(@visibility_key) do
      %{request_id: ^request_id, attempt_id: ^attempt_id} = witness ->
        Process.put(@visibility_key, %{witness | attempt: attempt, committed?: true})

      _outside_request ->
        :ok
    end
  end

  defp generation_authority(%Attempt{} = attempt) do
    %{
      request_id: attempt.request_id,
      attempt_id: attempt.id,
      replay_generation: attempt.replay_generation
    }
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
