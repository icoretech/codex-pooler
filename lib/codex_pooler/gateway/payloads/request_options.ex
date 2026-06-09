defmodule CodexPooler.Gateway.Payloads.RequestOptions do
  @moduledoc """
  Normalized request metadata, transport, continuity, routing, and timeout options.
  """

  alias __MODULE__.Continuity
  alias __MODULE__.FileBridgeContext
  alias __MODULE__.OpenAICompatibility
  alias __MODULE__.PayloadContext
  alias __MODULE__.RequestMetadata
  alias __MODULE__.Routing
  alias __MODULE__.RuntimeContext
  alias __MODULE__.TimeoutConfig
  alias __MODULE__.Transport
  alias __MODULE__.UsageAuthentication
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.RouteClass

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

  @session_header_sources ~w(x-codex-window-id x-codex-session-id session-id x-session-affinity session_id x-codex-conversation-id)

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
    :now,
    :openai_source_endpoint,
    :openai_translated_endpoint,
    :openai_chat_payload,
    :owner_instance_id,
    :pool_timeout,
    :pool_timeout_ms,
    :pool_upstream_assignment_id,
    :previous_response_id,
    :prompt_cache_key,
    :public_openai_chat_stream,
    :public_openai_responses_stream,
    :quota_decision,
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
      transport: transport(opts, endpoint, payload),
      continuity: continuity(opts),
      routing: routing(opts, endpoint, payload),
      timeout_config: timeout_config(opts),
      payload_context: payload_context(opts),
      runtime: runtime_context(opts),
      openai_compatibility: openai_compatibility(opts),
      usage_authentication: usage_authentication(opts),
      file_bridge: file_bridge(opts),
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
        routing: struct!(options.routing, prompt_cache_key: nil)
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
    %{options | routing: struct!(options.routing, updates)}
  end

  @spec put_transport(t(), keyword()) :: t()
  def put_transport(%__MODULE__{} = options, updates) when is_list(updates) do
    updates = updates |> Map.new() |> normalize_transport_updates()
    %{options | transport: struct!(options.transport, updates)}
  end

  @spec put_continuity(t(), keyword()) :: t()
  def put_continuity(%__MODULE__{} = options, updates) when is_list(updates) do
    updates = updates |> Map.new() |> normalize_continuity_updates()
    %{options | continuity: struct!(options.continuity, updates)}
  end

  @spec put_file_bridge(t(), keyword()) :: t()
  def put_file_bridge(%__MODULE__{} = options, updates) when is_list(updates) do
    updates = updates |> Map.new() |> normalize_file_bridge_updates()
    %{options | file_bridge: struct!(options.file_bridge, updates)}
  end

  @spec put_runtime_context(t(), keyword()) :: t()
  def put_runtime_context(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | runtime: struct!(options.runtime, updates)}
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
    put_openai_compatibility(options,
      source_endpoint: safe_endpoint(source_endpoint),
      translated_endpoint: safe_endpoint(translated_endpoint)
    )
  end

  @spec openai_compatibility_metadata(t()) :: map()
  def openai_compatibility_metadata(%__MODULE__{openai_compatibility: compatibility}) do
    metadata =
      %{
        "surface" => openai_surface(compatibility),
        "source_endpoint" => compatibility.source_endpoint,
        "translated_endpoint" => compatibility.translated_endpoint
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(metadata) == 0 do
      %{}
    else
      %{"openai_compatibility" => metadata}
    end
  end

  @spec route_class(t()) :: String.t() | nil
  def route_class(%__MODULE__{transport: %{route_class: route_class}})
      when is_binary(route_class),
      do: route_class

  def route_class(%__MODULE__{transport: %{route_class: nil}}), do: nil

  @spec default_transport(String.t(), map()) :: String.t()
  def default_transport("/backend-api/transcribe", _payload), do: "http_multipart"

  def default_transport(endpoint, payload) do
    if RouteClass.streaming?(payload), do: "http_sse", else: compact_transport(endpoint)
  end

  @spec timeout_config(map() | keyword()) :: TimeoutConfig.t()
  def timeout_config(opts) do
    opts = Map.new(opts)
    settings = OperationalSettings.current()
    shared_timeout = Map.get(opts, :timeout)

    %TimeoutConfig{
      connect_timeout_ms:
        configured_timeout(
          opts,
          :connect_timeout,
          :connect_timeout_ms,
          shared_timeout,
          settings.upstream_connect_timeout_ms
        ),
      pool_timeout_ms:
        configured_timeout(
          opts,
          :pool_timeout,
          :pool_timeout_ms,
          shared_timeout,
          settings.upstream_pool_timeout_ms
        ),
      receive_timeout_ms:
        configured_timeout(
          opts,
          :receive_timeout,
          :receive_timeout_ms,
          shared_timeout,
          settings.upstream_receive_timeout_ms
        )
    }
  end

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

  defp transport(opts, endpoint, payload) do
    %Transport{
      transport: Map.get(opts, :transport) || default_transport(endpoint, payload),
      upstream_endpoint: Map.get(opts, :upstream_endpoint) || endpoint,
      websocket_writer: Map.get(opts, :websocket_writer),
      forwarded_metadata_headers: forwarded_headers(Map.get(opts, :forwarded_headers, [])),
      upstream_websocket_session: Map.get(opts, :upstream_websocket_session),
      websocket_owner_forwarding_enabled?:
        Map.get(opts, :websocket_owner_forwarding_enabled?, false) == true,
      websocket_owner_session: Map.get(opts, :websocket_owner_session),
      websocket_owner_lease_token: Map.get(opts, :websocket_owner_lease_token),
      websocket_owner_downstream: Map.get(opts, :websocket_owner_downstream),
      websocket_owner_downstream_epoch:
        optional_positive_integer(Map.get(opts, :websocket_owner_downstream_epoch)),
      websocket_owner_proxy_instance_id: Map.get(opts, :websocket_owner_proxy_instance_id),
      websocket_owner_instance_id: Map.get(opts, :websocket_owner_instance_id),
      websocket_owner_forwarder_opts: websocket_owner_forwarder_opts(opts),
      route_class: classify_route_class(opts, endpoint, payload)
    }
  end

  defp retargeted_transport(%Transport{} = transport, endpoint, payload) do
    transport_name = transport.transport || default_transport(endpoint, payload)

    %Transport{
      transport
      | transport: transport_name,
        upstream_endpoint: endpoint,
        route_class: classify_route_class(%{transport: transport_name}, endpoint, payload)
    }
  end

  defp classify_route_class(opts, endpoint, payload) do
    transport = Map.get(opts, :transport) || Map.get(opts, "transport")
    RouteClass.classify(endpoint, payload, transport)
  end

  defp continuity(opts) do
    %Continuity{
      accepted_turn_state: Map.get(opts, :accepted_turn_state),
      previous_response_id: Map.get(opts, :previous_response_id),
      response_id: Map.get(opts, :response_id),
      session_header: Map.get(opts, :session_header),
      session_header_source:
        normalized_session_header_source(Map.get(opts, :session_header_source)),
      session_key: Map.get(opts, :session_key),
      conversation_key: Map.get(opts, :conversation_key),
      owner_instance_id: Map.get(opts, :owner_instance_id),
      bridge_owner_lease_ttl_seconds:
        optional_positive_integer(Map.get(opts, :bridge_owner_lease_ttl_seconds)),
      reconnect_window_seconds:
        optional_non_negative_integer(Map.get(opts, :reconnect_window_seconds)),
      codex_session: Map.get(opts, :codex_session),
      codex_turn_id: Map.get(opts, :codex_turn_id),
      authenticated_owner_attach: Map.get(opts, :authenticated_owner_attach, false) == true
    }
  end

  defp routing(opts, endpoint, payload) do
    %Routing{
      requested_model: Map.get(opts, :requested_model),
      effective_model: Map.get(opts, :effective_model),
      api_key_policy: Map.get(opts, :api_key_policy),
      file_affinity_assignment_id: Map.get(opts, :file_affinity_assignment_id),
      prompt_cache_key: prompt_cache_key(opts, endpoint, payload),
      quota_decision: Map.get(opts, :quota_decision),
      routing_attempt_metadata: Map.get(opts, :routing_attempt_metadata),
      routing_circuit_state: Map.get(opts, :routing_circuit_state),
      use_responses_lite?: Map.get(opts, :use_responses_lite?, false) == true
    }
  end

  defp payload_context(opts) do
    %PayloadContext{
      media_upload: Map.get(opts, :media_upload),
      forced_transcription_model: Map.get(opts, :forced_transcription_model)
    }
  end

  defp runtime_context(opts) do
    %RuntimeContext{
      now: Map.get(opts, :now),
      interrupt_reason: Map.get(opts, :interrupt_reason) || Map.get(opts, :reason),
      gateway_debug_payload: Map.get(opts, :gateway_debug_payload)
    }
  end

  defp openai_compatibility(opts) do
    %OpenAICompatibility{
      public_openai_responses_stream: Map.get(opts, :public_openai_responses_stream, false),
      public_openai_chat_stream: Map.get(opts, :public_openai_chat_stream, false),
      collect_openai_response_stream: Map.get(opts, :collect_openai_response_stream, false),
      collect_openai_image_stream: Map.get(opts, :collect_openai_image_stream, false),
      openai_chat_payload: Map.get(opts, :openai_chat_payload),
      source_endpoint: safe_endpoint(Map.get(opts, :openai_source_endpoint)),
      translated_endpoint: safe_endpoint(Map.get(opts, :openai_translated_endpoint))
    }
  end

  defp usage_authentication(opts) do
    %UsageAuthentication{
      authorization_header:
        Map.get(opts, :authorization_header) || Map.get(opts, "authorization_header"),
      chatgpt_account_id:
        Map.get(opts, :chatgpt_account_id) || Map.get(opts, "chatgpt_account_id")
    }
  end

  defp file_bridge(opts) do
    %FileBridgeContext{
      operation: Map.get(opts, :file_bridge_operation),
      endpoint: Map.get(opts, :file_bridge_endpoint),
      route_metadata: Map.get(opts, :file_bridge_route_metadata),
      forwarded_headers: forwarded_headers(Map.get(opts, :forwarded_headers, [])),
      pool_upstream_assignment_id: Map.get(opts, :pool_upstream_assignment_id),
      upstream_identity_id: Map.get(opts, :upstream_identity_id),
      defer_create_request: Map.get(opts, :defer_file_create_request),
      finalize_retry_timeout_ms:
        optional_non_negative_integer(Map.get(opts, :finalize_retry_timeout_ms)),
      finalize_retry_interval_ms:
        optional_non_negative_integer(Map.get(opts, :finalize_retry_interval_ms))
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

  defp configured_timeout(opts, opts_key, opts_ms_key, shared_timeout, default) do
    [Map.get(opts, opts_key), Map.get(opts, opts_ms_key), shared_timeout]
    |> Enum.find(&non_negative_integer?/1)
    |> case do
      nil -> default
      timeout -> timeout
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp optional_positive_integer(value) do
    if positive_integer?(value), do: value, else: nil
  end

  defp optional_non_negative_integer(value) do
    if non_negative_integer?(value), do: value, else: nil
  end

  defp forwarded_headers(headers) when is_list(headers) do
    Enum.filter(headers, fn
      {name, value} -> is_binary(name) and is_binary(value)
      _other -> false
    end)
  end

  defp forwarded_headers(_headers), do: []

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

  defp safe_endpoint(value) when is_binary(value) do
    value = value |> String.trim() |> String.slice(0, 160)

    if String.starts_with?(value, "/") and value != "/" do
      value
    else
      nil
    end
  end

  defp safe_endpoint(_value), do: nil

  defp prompt_cache_key(opts, endpoint, payload) do
    if prompt_cache_key_route?(opts, endpoint, payload) do
      payload
      |> Map.get("prompt_cache_key")
      |> normalized_prompt_cache_key()
    end
  end

  defp prompt_cache_key_route?(opts, endpoint, payload) do
    route_endpoint = safe_endpoint(Map.get(opts, :openai_source_endpoint)) || endpoint

    route_endpoint in @prompt_cache_key_routes and
      post_request?(Map.get(opts, :request_method) || Map.get(opts, "request_method")) and
      classify_route_class(opts, endpoint, payload) != "proxy_websocket"
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

  defp normalized_session_header_source(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalized_session_header_source()
  end

  defp normalized_session_header_source(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if value in @session_header_sources do
      value
    end
  end

  defp normalized_session_header_source(_value), do: nil

  defp openai_surface(%OpenAICompatibility{source_endpoint: endpoint}) when is_binary(endpoint),
    do: "openai_v1"

  defp openai_surface(_compatibility), do: nil

  defp websocket_owner_forwarder_opts(opts) do
    case Map.get(opts, :websocket_owner_forwarder_opts) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp normalize_continuity_updates(updates) do
    updates
    |> normalize_update(:bridge_owner_lease_ttl_seconds, &optional_positive_integer/1)
    |> normalize_update(:reconnect_window_seconds, &optional_non_negative_integer/1)
    |> normalize_update(:session_header_source, &normalized_session_header_source/1)
  end

  defp normalize_transport_updates(updates) do
    normalize_update(updates, :forwarded_metadata_headers, &forwarded_headers/1)
  end

  defp normalize_file_bridge_updates(updates) do
    updates
    |> normalize_update(:forwarded_headers, &forwarded_headers/1)
    |> normalize_update(:finalize_retry_timeout_ms, &optional_non_negative_integer/1)
    |> normalize_update(:finalize_retry_interval_ms, &optional_non_negative_integer/1)
  end

  defp normalize_update(updates, key, normalizer) do
    if Map.has_key?(updates, key) do
      Map.update!(updates, key, normalizer)
    else
      updates
    end
  end

  defp compact_transport(endpoint)
       when endpoint in [
              "/backend-api/codex/responses/compact",
              "/backend-api/codex/v1/responses/compact"
            ],
       do: "http_compact_json"

  defp compact_transport(_endpoint), do: "http_json"
end
