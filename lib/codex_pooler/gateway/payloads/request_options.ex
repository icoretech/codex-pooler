defmodule CodexPooler.Gateway.Payloads.RequestOptions do
  @moduledoc """
  Normalized request metadata, transport, continuity, routing, and timeout options.
  """

  alias __MODULE__.Continuity
  alias __MODULE__.FileBridgeContext
  alias __MODULE__.NativeCompactionAdmission, as: NativeCompactionAdmissionContext
  alias __MODULE__.Normalization
  alias __MODULE__.OpenAICompatibility
  alias __MODULE__.PayloadContext
  alias __MODULE__.RequestMetadata
  alias __MODULE__.ResetProbe
  alias __MODULE__.Routing
  alias __MODULE__.RuntimeContext
  alias __MODULE__.TimeoutConfig
  alias __MODULE__.Transport
  alias __MODULE__.UsageAuthentication
  alias CodexPooler.Gateway.Payloads.CompactionTrigger
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.RequestCompression.Metadata, as: RequestCompressionMetadata
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder

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
            native_compaction_admission: nil,
            native_compaction_reservation: nil,
            first_compact_collection: nil,
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
          native_compaction_admission: NativeCompactionAdmissionContext.t() | nil,
          native_compaction_reservation: map() | nil,
          first_compact_collection: NativeCompactionAdmission.FirstCompactCollection.t() | nil,
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
    :api_key_runtime_epoch,
    :authorization_header,
    :client_ip,
    :codex_session,
    :codex_turn_id,
    :semantic_turn_key,
    :turn_claim_key,
    :request_claim_key,
    :replay_claim_digest,
    :collect_openai_image_stream,
    :collect_openai_response_stream,
    :chatgpt_account_id,
    :compaction_trigger_bridge?,
    :compaction_input_mode,
    :compaction_projection_context,
    :compaction_result_mode,
    :compaction_result_transport,
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
    :image_generation_permission_required?,
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
    :replay_authorization_binding,
    :replay_lifecycle_binding,
    :replay_generation,
    :native_replay_binding,
    :replay_provisional_token,
    :pool_upstream_assignment_id,
    :previous_response_id,
    :prompt_cache_controls_downgraded,
    :prompt_cache_key,
    :public_openai_chat_stream,
    :public_openai_responses_stream,
    :quota_decision,
    :reset_probe,
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
    :upstream_previous_response_id?,
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
    :websocket_delivery_mode,
    :user_agent,
    :websocket_writer,
    "authorization_header",
    "chatgpt_account_id",
    "compaction_input_mode",
    "prompt_cache_controls_downgraded",
    "prompt_cache_key",
    "request_method",
    "transport",
    "websocket_delivery_mode"
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
      payload_context: payload_context(opts, payload),
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

  @spec server_correlation_id(t()) :: String.t()
  @spec server_correlation_id(t(), map()) :: String.t()
  def server_correlation_id(%__MODULE__{} = options, payload) when is_map(payload),
    do: server_correlation_id(options)

  def server_correlation_id(%__MODULE__{
        transport: %{transport: "websocket"},
        continuity: %{
          request_claim_key: request_claim_key,
          turn_claim_key: turn_claim_key
        }
      }) do
    request_claim_key || turn_claim_key || Ecto.UUID.generate()
  end

  def server_correlation_id(%__MODULE__{}), do: Ecto.UUID.generate()

  @spec websocket_request_correlation_id(t()) :: Ecto.UUID.t() | String.t()
  def websocket_request_correlation_id(%__MODULE__{
        request_metadata: %{request_id: request_id},
        transport: %{transport: "websocket"},
        continuity: %{
          request_claim_key: request_claim_key,
          turn_claim_key: turn_claim_key
        }
      }) do
    request_claim_key || turn_claim_key || request_id || Ecto.UUID.generate()
  end

  def websocket_request_correlation_id(%__MODULE__{} = options),
    do: server_correlation_id(options)

  @spec websocket_denial_correlation_id(t(), CodexPooler.Accounting.Request.t() | nil) ::
          Ecto.UUID.t() | String.t()
  def websocket_denial_correlation_id(
        %__MODULE__{},
        %CodexPooler.Accounting.Request{correlation_id: correlation_id}
      )
      when is_binary(correlation_id) and correlation_id != "",
      do: correlation_id

  def websocket_denial_correlation_id(
        %__MODULE__{} = options,
        %CodexPooler.Accounting.Request{}
      ),
      do: websocket_request_correlation_id(options)

  def websocket_denial_correlation_id(
        %__MODULE__{
          transport: %{transport: "websocket"},
          continuity: %{
            request_claim_key: request_claim_key,
            turn_claim_key: turn_claim_key
          }
        },
        nil
      )
      when is_binary(request_claim_key) and request_claim_key != turn_claim_key,
      do: request_claim_key

  def websocket_denial_correlation_id(
        %__MODULE__{
          request_metadata: %{request_id: request_id},
          transport: %{transport: "websocket"}
        },
        nil
      )
      when is_binary(request_id),
      do: request_id

  def websocket_denial_correlation_id(%__MODULE__{} = options, nil),
    do: websocket_request_correlation_id(options)

  @spec put_native_compaction_admission(
          t(),
          CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability.t(),
          NativeCompactionAdmissionContext.owner(),
          NativeCompactionAdmissionContext.lifecycle()
        ) :: t()
  def put_native_compaction_admission(%__MODULE__{} = options, capability, owner, lifecycle) do
    case NativeCompactionAdmissionContext.new(capability, owner, lifecycle) do
      {:ok, admission} -> %{options | native_compaction_admission: admission}
      {:error, :invalid_input} -> options
    end
  end

  @spec native_compaction_admission(t()) ::
          {:ok, CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability.t(),
           NativeCompactionAdmissionContext.owner(), NativeCompactionAdmissionContext.lifecycle()}
          | :none
  def native_compaction_admission(%__MODULE__{
        native_compaction_admission: %NativeCompactionAdmissionContext{} = admission
      }),
      do: NativeCompactionAdmissionContext.unwrap(admission)

  def native_compaction_admission(%__MODULE__{}), do: :none

  @spec put_first_compact_collection(t(), NativeCompactionAdmission.FirstCompactCollection.t()) ::
          t()
  def put_first_compact_collection(
        %__MODULE__{} = options,
        %NativeCompactionAdmission.FirstCompactCollection{} = provenance
      ),
      do: %{options | first_compact_collection: provenance}

  @spec acknowledge_native_compact_finalization(
          t(),
          <<_::256>>,
          NativeCompactionAdmission.Binding.t(),
          non_neg_integer()
        ) :: :ok | {:error, atom()}
  def acknowledge_native_compact_finalization(
        %__MODULE__{} = options,
        digest,
        %NativeCompactionAdmission.Binding{} = binding,
        expires_at_ms
      ) do
    with {:ok, source_phase, control_ref, owner} <- compact_confirmation_source(options),
         :ok <- record_first_compact_collection_if_needed(options, owner) do
      confirmation = %NativeCompactionAdmission.Confirmation{
        source_phase: source_phase,
        source_control_ref: control_ref,
        binding: binding
      }

      acknowledge_compact_owner(owner, digest, confirmation, expires_at_ms)
    end
  end

  defp record_first_compact_collection_if_needed(
         %__MODULE__{
           first_compact_collection:
             %NativeCompactionAdmission.FirstCompactCollection{} =
               provenance
         },
         {:direct, owner}
       ),
       do: UpstreamWebsocketSession.record_first_compact_collected(owner, provenance)

  defp record_first_compact_collection_if_needed(
         %__MODULE__{
           first_compact_collection:
             %NativeCompactionAdmission.FirstCompactCollection{} =
               provenance
         },
         {:forwarded, session, lease_token, downstream, opts}
       ) do
    attrs = %{
      version: 1,
      action: :record_first_compact_collected,
      downstream: Map.take(downstream, [:pid, :epoch, :correlation_id]),
      binding: nil,
      phase: nil,
      control_ref: nil,
      capability: nil,
      disposition: nil,
      success?: nil,
      compaction_item_digest: nil,
      confirmation: nil,
      first_compact_collection: provenance,
      expires_at_ms: nil,
      now_ms: nil
    }

    with {:ok, control} <- WebsocketOwnerAdmissionControlV1.new(attrs),
         {:ok, _result} <-
           WebsocketOwnerForwarder.admission_control(session, lease_token, control, opts) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_first_compact_collection_if_needed(%__MODULE__{}, _owner), do: :ok

  defp compact_confirmation_source(%__MODULE__{
         native_compaction_admission: %NativeCompactionAdmissionContext{} = admission
       }) do
    with {:ok, capability, owner, _lifecycle} <-
           NativeCompactionAdmissionContext.unwrap(admission) do
      {:ok, :compact, NativeCompactionAdmission.control_ref(capability), owner}
    end
  end

  defp compact_confirmation_source(
         %__MODULE__{
           first_compact_collection:
             %NativeCompactionAdmission.FirstCompactCollection{} = provenance
         } = options
       ) do
    {:ok, :first_full_history_compact, provenance.control_ref, first_compact_owner(options)}
  end

  defp compact_confirmation_source(%__MODULE__{}), do: {:error, :owner_unavailable}

  defp first_compact_owner(%__MODULE__{
         transport: %{upstream_websocket_session: owner, websocket_owner: %{enabled?: false}}
       })
       when is_pid(owner),
       do: {:direct, owner}

  defp first_compact_owner(%__MODULE__{transport: %{websocket_owner: owner}})
       when is_map(owner) and owner.enabled? == true,
       do: {:forwarded, owner.session, owner.lease_token, owner.downstream, owner.forwarder_opts}

  defp acknowledge_compact_owner({:direct, owner}, digest, confirmation, expires_at_ms),
    do:
      UpstreamWebsocketSession.acknowledge_compact_finalization(
        owner,
        {:success, digest, confirmation, expires_at_ms}
      )

  defp acknowledge_compact_owner(
         {:forwarded, session, lease_token, downstream, opts},
         digest,
         confirmation,
         expires_at_ms
       ) do
    attrs = %{
      version: 1,
      action: :finalization_ack,
      downstream: Map.take(downstream, [:pid, :epoch, :correlation_id]),
      binding: nil,
      phase: nil,
      control_ref: nil,
      capability: nil,
      disposition: nil,
      success?: true,
      compaction_item_digest: digest,
      confirmation: confirmation,
      first_compact_collection: nil,
      expires_at_ms: expires_at_ms,
      now_ms: nil
    }

    with {:ok, control} <- WebsocketOwnerAdmissionControlV1.new(attrs),
         {:ok, _result} <-
           WebsocketOwnerForwarder.admission_control(session, lease_token, control, opts) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec native_compaction_admission_digest(t(), atom()) ::
          {:ok, <<_::256>>} | :none | {:error, :invalid_input}
  def native_compaction_admission_digest(
        %__MODULE__{
          native_compaction_admission: %NativeCompactionAdmissionContext{} = admission,
          continuity: %{semantic_turn_key: semantic_turn_key, turn_claim_key: turn_claim_key}
        } = options,
        variant
      ) do
    with {:ok, serving_mode} <- admission_serving_mode(options),
         {:ok, topology} <- admission_topology(options) do
      NativeCompactionAdmissionContext.binding_digest(
        admission,
        semantic_turn_key,
        turn_claim_key,
        variant,
        serving_mode,
        topology
      )
    end
  end

  def native_compaction_admission_digest(%__MODULE__{}, _variant), do: :none

  defp admission_serving_mode(%__MODULE__{
         routing: %{model_serving_mode: nil},
         native_compaction_admission: %NativeCompactionAdmissionContext{} = admission
       }) do
    with {:ok, capability, _owner, _lifecycle} <-
           NativeCompactionAdmissionContext.unwrap(admission) do
      {:ok, capability.binding.serving_mode}
    end
  end

  defp admission_serving_mode(%__MODULE__{} = options) do
    case model_serving_mode(options) do
      "full" -> {:ok, :full}
      "lite" -> {:ok, :lite}
      _other -> {:error, :invalid_input}
    end
  end

  defp admission_topology(%__MODULE__{
         transport: %{
           upstream_websocket_session: pid,
           websocket_owner: %{enabled?: false}
         }
       })
       when is_pid(pid),
       do: {:ok, :direct}

  defp admission_topology(%__MODULE__{
         transport: %{
           upstream_websocket_session: nil,
           websocket_owner: %{
             enabled?: true,
             session: %CodexSession{},
             lease_token: lease_token,
             downstream: downstream,
             downstream_epoch: epoch,
             owner_instance_id: owner_instance_id
           }
         }
       })
       when is_binary(lease_token) and is_map(downstream) and is_integer(epoch) and epoch > 0 and
              is_binary(owner_instance_id),
       do: {:ok, :forwarded}

  defp admission_topology(%__MODULE__{}), do: {:error, :invalid_input}

  @spec mark_native_compaction_accounting_started(t(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def mark_native_compaction_accounting_started(%__MODULE__{} = options, now_ms) do
    case native_compaction_admission(options) do
      {:ok, capability, owner, _lifecycle} ->
        owner_admission_action(owner, :mark_accounting_started, capability, now_ms)

      :none ->
        :ok
    end
  end

  @spec cancel_native_compaction_reservation(t(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def cancel_native_compaction_reservation(%__MODULE__{} = options, now_ms) do
    case native_compaction_admission(options) do
      {:ok, capability, owner, _lifecycle} ->
        owner_admission_action(owner, :cancel, capability, now_ms)

      :none ->
        :ok
    end
  end

  @spec clear_native_compaction_admission(t()) :: :ok | {:error, atom()}
  def clear_native_compaction_admission(%__MODULE__{} = options) do
    case native_compaction_admission(options) do
      {:ok, _capability, {:direct, owner}, _lifecycle} ->
        UpstreamWebsocketSession.clear_compaction_admission(owner)

      {:ok, _capability, {:forwarded, session, lease_token, downstream, opts}, _lifecycle} ->
        forwarded_admission_action(session, lease_token, downstream, opts, :clear, nil, nil)

      :none ->
        :ok
    end
  end

  defp owner_admission_action({:direct, owner}, :mark_accounting_started, capability, now_ms),
    do: UpstreamWebsocketSession.mark_compaction_accounting_started(owner, capability, now_ms)

  defp owner_admission_action({:direct, owner}, :cancel, capability, now_ms),
    do: UpstreamWebsocketSession.cancel_compaction_reservation(owner, capability, now_ms)

  defp owner_admission_action(
         {:forwarded, session, lease_token, downstream, opts},
         action,
         capability,
         now_ms
       ),
       do:
         forwarded_admission_action(
           session,
           lease_token,
           downstream,
           opts,
           action,
           capability,
           now_ms
         )

  defp forwarded_admission_action(
         session,
         lease_token,
         downstream,
         opts,
         action,
         capability,
         now_ms
       ) do
    attrs = %{
      version: 1,
      action: action,
      downstream: Map.take(downstream, [:pid, :epoch, :correlation_id]),
      binding: nil,
      phase: nil,
      control_ref: nil,
      capability: capability,
      disposition: if(action == :cancel, do: :pre_accounting),
      success?: nil,
      compaction_item_digest: nil,
      confirmation: nil,
      first_compact_collection: nil,
      expires_at_ms: nil,
      now_ms: now_ms
    }

    with {:ok, control} <- WebsocketOwnerAdmissionControlV1.new(attrs),
         {:ok, _result} <-
           WebsocketOwnerForwarder.admission_control(session, lease_token, control, opts) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

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

  @spec connection_bound_compaction?(t()) :: boolean()
  def connection_bound_compaction?(%__MODULE__{
        payload_context: %{
          compaction_trigger_bridge?: true,
          compaction_input_mode: :incremental
        },
        transport: %{
          transport: "websocket",
          websocket_delivery_mode: :collect_compaction
        }
      }),
      do: true

  def connection_bound_compaction?(%__MODULE__{}), do: false

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

  @spec capture_api_key_runtime_epoch(t(), CodexPooler.Access.auth_context()) :: t()
  def capture_api_key_runtime_epoch(
        %__MODULE__{runtime: %{api_key_runtime_epoch: nil}} = options,
        %{api_key: %{runtime_revocation_epoch: epoch}}
      )
      when is_integer(epoch) and epoch >= 0 do
    put_runtime_context(options, api_key_runtime_epoch: epoch)
  end

  def capture_api_key_runtime_epoch(%__MODULE__{} = options, _auth), do: options

  @spec put_payload_context(t(), keyword()) :: t()
  def put_payload_context(%__MODULE__{} = options, updates) when is_list(updates) do
    %{options | payload_context: PayloadContext.update(options.payload_context, updates)}
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

  @type prompt_cache_controls_attempt_metadata :: %{optional(String.t()) => true}

  @spec prompt_cache_controls_attempt_metadata(t() | map() | term()) ::
          prompt_cache_controls_attempt_metadata()
  def prompt_cache_controls_attempt_metadata(%__MODULE__{
        runtime: %{prompt_cache_controls_downgraded: true}
      }) do
    %{"prompt_cache_controls_downgraded" => true}
  end

  def prompt_cache_controls_attempt_metadata(%{
        runtime: %{prompt_cache_controls_downgraded: true}
      }) do
    %{"prompt_cache_controls_downgraded" => true}
  end

  def prompt_cache_controls_attempt_metadata(_opts), do: %{}

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
      reset_probe: reset_probe(Map.get(opts, :reset_probe)),
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

  defp reset_probe(%ResetProbe{} = reset_probe), do: reset_probe
  defp reset_probe(_value), do: nil

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

  defp payload_context(opts, payload) do
    PayloadContext.build(opts, CompactionTrigger.compaction_input_mode(payload))
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
