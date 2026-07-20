defmodule CodexPooler.Gateway.Payloads.RequestOptions do
  @moduledoc """
  Normalized request metadata, transport, continuity, routing, and timeout options.
  """

  alias __MODULE__.Continuity
  alias __MODULE__.FileBridgeContext
  alias __MODULE__.Normalization
  alias __MODULE__.OpenAICompatibility
  alias __MODULE__.PayloadContext
  alias __MODULE__.RequestMetadata
  alias __MODULE__.Routing
  alias __MODULE__.RuntimeContext
  alias __MODULE__.TimeoutConfig
  alias __MODULE__.Transport
  alias __MODULE__.UsageAuthentication
  alias CodexPooler.Gateway.RequestCompression.Metadata, as: RequestCompressionMetadata

  @enforce_keys [
    :request_metadata,
    :transport,
    :continuity,
    :routing,
    :timeout_config,
    :payload_context,
    :runtime,
    :openai_compatibility,
    :usage_authentication,
    :file_bridge
  ]
  defstruct request_metadata: nil,
            transport: nil,
            continuity: nil,
            routing: nil,
            timeout_config: nil,
            payload_context: nil,
            runtime: nil,
            openai_compatibility: nil,
            usage_authentication: nil,
            file_bridge: nil,
            extra: %{}

  @type t :: %__MODULE__{
          request_metadata: RequestMetadata.t(),
          transport: Transport.t(),
          continuity: Continuity.t(),
          routing: Routing.t(),
          timeout_config: TimeoutConfig.t(),
          payload_context: PayloadContext.t(),
          runtime: RuntimeContext.t(),
          openai_compatibility: OpenAICompatibility.t(),
          usage_authentication: UsageAuthentication.t(),
          file_bridge: FileBridgeContext.t(),
          extra: map()
        }

  @websocket_responses_endpoint "/backend-api/codex/responses"

  @prompt_cache_key_routes [
    "/v1/responses",
    "/v1/chat/completions",
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses",
    "/backend-api/codex/v1/chat/completions"
  ]

  @prompt_cache_key_max_bytes 256

  @known_opt_keys [
    :accepted_turn_state,
    :authenticated_owner_attach,
    :api_key_policy,
    :authorization_header,
    :client_ip,
    :codex_session,
    :codex_turn_id,
    :collect_openai_image_stream,
    :collect_openai_response_stream,
    :chatgpt_account_id,
    :conversation_key,
    :connect_timeout,
    :connect_timeout_ms,
    :bridge_owner_lease_ttl_seconds,
    :defer_file_create_request,
    :effective_model,
    :endpoint,
    :file_affinity_assignment_id,
    :file_bridge_endpoint,
    :file_bridge_operation,
    :file_bridge_route_metadata,
    :finalize_retry_interval_ms,
    :finalize_retry_timeout_ms,
    :forced_transcription_model,
    :forwarded_headers,
    :gateway_debug_payload,
    :idempotency_key,
    :interrupt_reason,
    :media_upload,
    :model_serving_mode,
    :model_serving_mode_configured,
    :model_serving_mode_source,
    :native_image_request?,
    :now,
    :openai_source_endpoint,
    :openai_translated_endpoint,
    :openai_chat_payload,
    :owner_instance_id,
    :payload_compression,
    :pool_timeout,
    :pool_timeout_ms,
    :reasoning_effort_snapshot,
    :pool_upstream_assignment_id,
    :previous_response_id,
    :prompt_cache_key,
    :public_openai_chat_stream,
    :public_openai_responses_stream,
    :quota_decision,
    :reasoning_effort_decision,
    :supports_reasoning_summary_parameter?,
    :receive_timeout,
    :receive_timeout_ms,
    :reconnect_window_seconds,
    :reason,
    :request_bytes,
    :client_request_id,
    :request_content_type,
    :request_id,
    :request_method,
    :requested_model,
    :response_id,
    :routing_attempt_metadata,
    :routing_circuit_state,
    :use_responses_lite?,
    :session_header,
    :session_header_source,
    :session_key,
    :timeout,
    :transport,
    :upload_bytes,
    :upstream_endpoint,
    :upstream_identity_id,
    :upstream_websocket_session,
    :websocket_owner,
    :websocket_owner_downstream_epoch,
    :websocket_owner_downstream,
    :websocket_owner_forwarding_enabled?,
    :websocket_owner_forwarder_opts,
    :websocket_owner_instance_id,
    :websocket_owner_lease_token,
    :websocket_owner_proxy_instance_id,
    :websocket_owner_session,
    :user_agent,
    :websocket_writer,
    "authorization_header",
    "chatgpt_account_id",
    "prompt_cache_key",
    "request_method",
    "transport"
  ]

  @spec build(t() | map() | keyword(), String.t(), map()) :: t()
  def build(%__MODULE__{} = options, endpoint, payload) when is_map(payload) do
    for_payload(options, endpoint, payload)
  end

  def build(opts, endpoint, payload) when is_map(payload) do
    opts = Map.new(opts)

    %__MODULE__{
      request_metadata: request_metadata(opts, endpoint, payload),
      transport: Transport.build(opts, endpoint, payload),
      continuity: Continuity.build(opts),
      routing: routing(opts, endpoint, payload),
      timeout_config: TimeoutConfig.build(opts),
      payload_context: payload_context(opts),
      runtime: RuntimeContext.build(opts),
      openai_compatibility: OpenAICompatibility.build(opts),
      usage_authentication: usage_authentication(opts),
      file_bridge: FileBridgeContext.build(opts),
      extra: extra(opts)
    }
  end

  @spec from_conn_metadata(t() | map() | keyword(), String.t(), map()) :: t()
  def from_conn_metadata(opts, endpoint, payload) when is_map(payload) do
    build(opts, endpoint, payload)
  end

  @spec for_websocket(t() | map() | keyword(), map()) :: t()
  def for_websocket(opts, payload \\ %{})

  def for_websocket(%__MODULE__{} = options, payload) when is_map(payload) do
    options
    |> put_transport(transport: "websocket")
    |> retarget(@websocket_responses_endpoint, payload)
    |> put_routing(prompt_cache_key: nil)
  end

  def for_websocket(opts, payload) when is_map(payload) do
    opts
    |> Map.new()
    |> Map.put(:transport, "websocket")
    |> build(@websocket_responses_endpoint, payload)
  end

  @spec for_file_bridge(t() | map() | keyword(), String.t(), map(), keyword()) :: t()
  def for_file_bridge(opts, endpoint, payload, updates \\ [])

  def for_file_bridge(%__MODULE__{} = options, endpoint, payload, updates)
      when is_map(payload) and is_list(updates) do
    options
    |> retarget(endpoint, payload)
    |> apply_file_bridge_updates(updates)
  end

  def for_file_bridge(opts, endpoint, payload, updates)
      when is_map(payload) and is_list(updates) do
    opts
    |> build(endpoint, payload)
    |> apply_file_bridge_updates(updates)
  end

  @spec for_payload(t(), String.t(), map()) :: t()
  def for_payload(%__MODULE__{} = options, endpoint, payload) when is_map(payload) do
    %{options | request_metadata: request_metadata(options, endpoint, payload)}
  end

  @spec retarget(t(), String.t(), map()) :: t()
  def retarget(%__MODULE__{} = options, endpoint, payload) when is_map(payload) do
    %{
      options
      | request_metadata: request_metadata(options, endpoint, payload),
        transport: retargeted_transport(options.transport, endpoint, payload),
        routing: Routing.update(options.routing, prompt_cache_key: nil)
    }
  end

  @spec put_request_metadata(t(), keyword()) :: t()
  def put_request_metadata(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | request_metadata: struct!(options.request_metadata, updates)}
  end

  @spec server_correlation_id(t()) :: Ecto.UUID.t()
  def server_correlation_id(%__MODULE__{
        transport: %{transport: "websocket"},
        continuity: %{codex_turn_id: turn_id}
      }) do
    turn_id || Ecto.UUID.generate()
  end

  def server_correlation_id(%__MODULE__{}), do: Ecto.UUID.generate()

  @spec websocket_request_correlation_id(t()) :: Ecto.UUID.t() | String.t()
  def websocket_request_correlation_id(%__MODULE__{
        request_metadata: %{request_id: request_id},
        transport: %{transport: "websocket"},
        continuity: %{codex_turn_id: turn_id}
      }) do
    turn_id || request_id || Ecto.UUID.generate()
  end

  def websocket_request_correlation_id(%__MODULE__{} = options),
    do: server_correlation_id(options)

  @spec client_request_metadata(t()) :: map()
  def client_request_metadata(%__MODULE__{} = options) do
    case safe_client_request_id(options.request_metadata.client_request_id) do
      nil -> %{}
      client_request_id -> %{"client_request_id" => client_request_id}
    end
  end

  @spec put_routing(t(), keyword()) :: t()
  def put_routing(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | routing: Routing.update(options.routing, updates)}
  end

  @spec put_model_serving_mode(t(), Routing.model_serving_mode_snapshot() | keyword()) :: t()
  def put_model_serving_mode(%__MODULE__{} = options, snapshot)
      when is_map(snapshot) or is_list(snapshot) do
    %{options | routing: Routing.put_model_serving_mode(options.routing, snapshot)}
  end

  @spec model_serving_mode_snapshot(t()) :: Routing.model_serving_mode_snapshot() | nil
  def model_serving_mode_snapshot(%__MODULE__{routing: routing}) do
    Routing.model_serving_mode_snapshot(routing)
  end

  @spec model_serving_mode_configured(t()) :: Routing.configured_model_serving_mode() | nil
  def model_serving_mode_configured(%__MODULE__{routing: routing}),
    do: routing.model_serving_mode_configured

  @spec model_serving_mode(t()) :: Routing.effective_model_serving_mode()
  def model_serving_mode(%__MODULE__{routing: %{model_serving_mode: nil}}), do: "full"
  def model_serving_mode(%__MODULE__{routing: routing}), do: routing.model_serving_mode

  @spec model_serving_mode_source(t()) :: Routing.model_serving_mode_source() | nil
  def model_serving_mode_source(%__MODULE__{routing: routing}),
    do: routing.model_serving_mode_source

  @spec use_responses_lite?(t()) :: boolean()
  def use_responses_lite?(%__MODULE__{routing: routing} = options) do
    case Routing.model_serving_mode_snapshot(routing) do
      nil -> routing.use_responses_lite? == true
      _snapshot -> model_serving_mode(options) == "lite"
    end
  end

  @spec put_transport(t(), keyword()) :: t()
  def put_transport(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | transport: Transport.update(options.transport, updates)}
  end

  @spec put_continuity(t(), keyword()) :: t()
  def put_continuity(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | continuity: Continuity.update(options.continuity, updates)}
  end

  @spec put_file_bridge(t(), keyword()) :: t()
  def put_file_bridge(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | file_bridge: FileBridgeContext.update(options.file_bridge, updates)}
  end

  @spec put_runtime_context(t(), keyword()) :: t()
  def put_runtime_context(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | runtime: RuntimeContext.update(options.runtime, updates)}
  end

  @spec put_payload_context(t(), keyword()) :: t()
  def put_payload_context(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | payload_context: struct!(options.payload_context, updates)}
  end

  @spec put_openai_compatibility(t(), keyword()) :: t()
  def put_openai_compatibility(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | openai_compatibility: struct!(options.openai_compatibility, updates)}
  end

  @spec mark_openai_compatibility_origin(t(), String.t(), String.t()) :: t()
  def mark_openai_compatibility_origin(
        %__MODULE__{} = options,
        source_endpoint,
        translated_endpoint
      )
      when is_binary(source_endpoint) and is_binary(translated_endpoint) do
    %{
      options
      | openai_compatibility:
          OpenAICompatibility.mark_origin(
            options.openai_compatibility,
            source_endpoint,
            translated_endpoint
          )
    }
  end

  @spec openai_compatibility_metadata(t()) :: map()
  def openai_compatibility_metadata(%__MODULE__{openai_compatibility: compatibility}) do
    OpenAICompatibility.metadata(compatibility)
  end

  @spec payload_compression_attempt_metadata(t() | map() | term()) :: map()
  def payload_compression_attempt_metadata(%__MODULE__{
        runtime: %{payload_compression: metadata}
      }),
      do: payload_compression_metadata_envelope(metadata)

  def payload_compression_attempt_metadata(%{runtime: %{payload_compression: metadata}}),
    do: payload_compression_metadata_envelope(metadata)

  def payload_compression_attempt_metadata(%{payload_compression: metadata}),
    do: payload_compression_metadata_envelope(metadata)

  def payload_compression_attempt_metadata(_opts), do: %{}

  @spec reasoning_effort_attempt_metadata(t() | map() | term()) :: map()
  def reasoning_effort_attempt_metadata(%__MODULE__{
        runtime: %{reasoning_effort_snapshot: snapshot}
      }),
      do: reasoning_effort_metadata_envelope(snapshot)

  def reasoning_effort_attempt_metadata(%{runtime: %{reasoning_effort_snapshot: snapshot}}),
    do: reasoning_effort_metadata_envelope(snapshot)

  def reasoning_effort_attempt_metadata(%{reasoning_effort_snapshot: snapshot}),
    do: reasoning_effort_metadata_envelope(snapshot)

  def reasoning_effort_attempt_metadata(_opts), do: %{}

  @spec payload_compression_request_metadata(t() | map() | term()) :: map()
  def payload_compression_request_metadata(opts), do: payload_compression_attempt_metadata(opts)

  @spec route_class(t()) :: String.t() | nil
  def route_class(%__MODULE__{transport: %{route_class: route_class}})
      when is_binary(route_class),
      do: route_class

  def route_class(%__MODULE__{transport: %{route_class: nil}}), do: nil

  @spec default_transport(String.t(), map()) :: String.t()
  def default_transport(endpoint, payload), do: Transport.default(endpoint, payload)

  @spec timeout_config(map() | keyword()) :: TimeoutConfig.t()
  def timeout_config(opts), do: TimeoutConfig.build(opts)

  @spec json_request_bytes(term()) :: non_neg_integer() | nil
  def json_request_bytes(payload) when is_map(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> nil
    end
  end

  def json_request_bytes(_payload), do: nil

  defp request_metadata(
         %__MODULE__{request_metadata: %RequestMetadata{} = metadata},
         _endpoint,
         payload
       ) do
    %RequestMetadata{metadata | request_bytes: json_request_bytes(payload)}
  end

  defp request_metadata(opts, _endpoint, payload) do
    %RequestMetadata{
      request_id: Map.get(opts, :request_id),
      client_request_id: Map.get(opts, :client_request_id),
      idempotency_key: Map.get(opts, :idempotency_key),
      client_ip: Map.get(opts, :client_ip),
      user_agent: Map.get(opts, :user_agent),
      request_bytes: Map.get(opts, :request_bytes) || json_request_bytes(payload),
      upload_bytes: Map.get(opts, :upload_bytes),
      request_content_type: Map.get(opts, :request_content_type)
    }
  end

  defp retargeted_transport(%Transport{} = transport, endpoint, payload) do
    Transport.retarget(transport, endpoint, payload)
  end

  defp routing(opts, endpoint, payload) do
    %Routing{
      requested_model: Map.get(opts, :requested_model),
      effective_model: Map.get(opts, :effective_model),
      api_key_policy: Map.get(opts, :api_key_policy),
      file_affinity_assignment_id: Map.get(opts, :file_affinity_assignment_id),
      prompt_cache_key: prompt_cache_key(opts, endpoint, payload),
      quota_decision: Map.get(opts, :quota_decision),
      reasoning_effort_decision: Map.get(opts, :reasoning_effort_decision),
      supports_reasoning_summary_parameter?:
        Map.get(opts, :supports_reasoning_summary_parameter?, true) != false,
      routing_attempt_metadata: Map.get(opts, :routing_attempt_metadata),
      routing_circuit_state: Map.get(opts, :routing_circuit_state),
      model_serving_mode_configured: Map.get(opts, :model_serving_mode_configured),
      model_serving_mode: Map.get(opts, :model_serving_mode),
      model_serving_mode_source: Map.get(opts, :model_serving_mode_source),
      use_responses_lite?: Map.get(opts, :use_responses_lite?, false) == true
    }
    |> validate_routing_model_serving_mode!()
  end

  defp validate_routing_model_serving_mode!(%Routing{} = routing) do
    case Routing.model_serving_mode_snapshot(routing) do
      nil ->
        routing

      snapshot ->
        routing
        |> Map.put(:model_serving_mode_configured, nil)
        |> Map.put(:model_serving_mode, nil)
        |> Map.put(:model_serving_mode_source, nil)
        |> Map.put(:use_responses_lite?, false)
        |> Routing.put_model_serving_mode(snapshot)
    end
  end

  defp payload_context(opts) do
    PayloadContext.build(opts)
  end

  defp usage_authentication(opts) do
    %UsageAuthentication{
      authorization_header:
        Map.get(opts, :authorization_header) || Map.get(opts, "authorization_header"),
      chatgpt_account_id:
        Map.get(opts, :chatgpt_account_id) || Map.get(opts, "chatgpt_account_id")
    }
  end

  defp extra(opts) do
    Map.drop(opts, @known_opt_keys)
  end

  defp apply_file_bridge_updates(%__MODULE__{} = options, updates) do
    {transport_updates, file_bridge_updates} = Keyword.split(updates, [:route_class])

    options
    |> maybe_put_transport(transport_updates)
    |> maybe_put_file_bridge(file_bridge_updates)
  end

  defp maybe_put_transport(%__MODULE__{} = options, []), do: options
  defp maybe_put_transport(%__MODULE__{} = options, updates), do: put_transport(options, updates)

  defp maybe_put_file_bridge(%__MODULE__{} = options, []), do: options

  defp maybe_put_file_bridge(%__MODULE__{} = options, updates),
    do: put_file_bridge(options, updates)

  defp safe_client_request_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 160)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp safe_client_request_id(_value), do: nil

  defp prompt_cache_key(opts, endpoint, payload) do
    if prompt_cache_key_route?(opts, endpoint, payload) do
      payload
      |> Map.get("prompt_cache_key")
      |> normalized_prompt_cache_key()
    end
  end

  defp prompt_cache_key_route?(opts, endpoint, payload) do
    route_endpoint =
      Normalization.safe_endpoint(Map.get(opts, :openai_source_endpoint)) || endpoint

    route_endpoint in @prompt_cache_key_routes and
      post_request?(Map.get(opts, :request_method) || Map.get(opts, "request_method")) and
      Transport.route_class(opts, endpoint, payload) != "proxy_websocket"
  end

  defp post_request?(nil), do: true

  defp post_request?(method) when is_atom(method),
    do: method |> Atom.to_string() |> post_request?()

  defp post_request?(method) when is_binary(method), do: String.upcase(method) == "POST"
  defp post_request?(_method), do: false

  defp normalized_prompt_cache_key(value) when is_binary(value) do
    canonical = String.trim(value)

    cond do
      canonical == "" ->
        nil

      byte_size(canonical) > @prompt_cache_key_max_bytes ->
        nil

      true ->
        :crypto.hash(:sha256, canonical)
        |> Base.encode16(case: :lower)
    end
  end

  defp normalized_prompt_cache_key(_value), do: nil

  defp reasoning_effort_metadata_envelope(snapshot) when is_map(snapshot) do
    snapshot =
      snapshot
      |> Map.take(
        ~w(policy_mode configured_effort requested_effort applied_effort effective_effort source rewrite)
      )
      |> Enum.reject(fn {_key, value} ->
        is_nil(value) or (is_binary(value) and String.trim(value) == "")
      end)
      |> Map.new()

    if snapshot == %{}, do: %{}, else: %{"reasoning" => snapshot}
  end

  defp reasoning_effort_metadata_envelope(_snapshot), do: %{}

  defp payload_compression_metadata_envelope(metadata),
    do: RequestCompressionMetadata.request_envelope(metadata)
end
