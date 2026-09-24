defmodule CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation do
  @moduledoc false

  require Logger

  alias CodexPooler.Access
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Accounting.PricingResolution
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.NativeHttpTurnIdentity
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.PayloadContext
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Payloads.RequestOptions.Routing
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.RouteClass

  @type auth :: Access.auth_context()
  @type reset_probe_scope_error ::
          {:reset_probe_scope_mismatch, CodexPooler.Gateway.Contracts.gateway_error()}

  @spec validate_reset_probe_scope(
          [CandidateEligibility.FilterInput.candidate()],
          RequestOptions.t(),
          RouteState.t()
        ) :: :ok | {:error, reset_probe_scope_error()}
  def validate_reset_probe_scope(
        candidates,
        %RequestOptions{} = request_options,
        %RouteState{} = route_state
      )
      when is_list(candidates) do
    case {request_options.routing.reset_probe, route_state.reset_probe} do
      {nil, nil} ->
        :ok

      {%ResetProbe{} = probe, nil} ->
        if ResetProbe.unbound?(probe), do: :ok, else: reset_probe_scope_error()

      {%ResetProbe{} = probe, %ResetProbe{} = route_probe} ->
        validate_bound_reset_probe_scope(candidates, request_options, probe, route_probe)

      _mismatch ->
        reset_probe_scope_error()
    end
  end

  @doc false
  @spec pre_attempt_failure(term(), RequestOptions.t()) :: Contracts.gateway_error()
  def pre_attempt_failure(:rollback, %RequestOptions{} = request_options) do
    pre_attempt_failure_response(:rollback, request_options, 503, true)
  end

  def pre_attempt_failure(:stale_owner, %RequestOptions{} = request_options) do
    pre_attempt_failure_response(
      :stale_owner,
      request_options,
      409,
      false,
      "stale_owner",
      "session owner lease is stale"
    )
  end

  def pre_attempt_failure(:owner_unavailable, %RequestOptions{} = request_options) do
    pre_attempt_failure_response(
      :owner_unavailable,
      request_options,
      503,
      false,
      "owner_unavailable",
      "session owner lease is unavailable"
    )
  end

  def pre_attempt_failure(reason, %RequestOptions{} = request_options) do
    pre_attempt_failure_response(reason, request_options, 500, false)
  end

  defp pre_attempt_failure_response(
         reason,
         request_options,
         status,
         retryable,
         code \\ "gateway_reservation_failed",
         message \\ "gateway request reservation failed"
       ) do
    failure_reason = FailureResponse.safe_failure_reason(reason)

    Logger.error([
      "gateway pre-attempt reservation failed",
      " phase=pre_attempt",
      " operation=reserve_and_start_turn",
      " failure_code=#{code}",
      " status=#{status}",
      " request_id=#{DiagnosticTaxonomy.safe_correlator(request_options.request_metadata.request_id)}",
      native_lifecycle_log_metadata(request_options),
      " failure_reason=#{failure_reason}",
      " retryable=#{retryable}"
    ])

    %{
      status: status,
      code: code,
      message: message,
      retryable: retryable
    }
  end

  defp native_lifecycle_log_metadata(request_options) do
    case RequestOptions.native_compaction_admission(request_options) do
      {:ok, _capability, _owner, %{lifecycle_id: lifecycle_id}} ->
        " native_lifecycle_id=#{DiagnosticTaxonomy.safe_correlator(lifecycle_id)}"

      _no_valid_admission ->
        ""
    end
  end

  @spec attrs(auth(), map(), String.t(), RequestOptions.t()) :: map()
  def attrs(auth, payload, endpoint, %RequestOptions{} = request_options) when is_map(payload),
    do: attrs(auth, payload, endpoint, request_options, nil, nil)

  @spec attrs(auth(), map(), String.t(), RequestOptions.t(), RouteState.t() | nil) :: map()
  def attrs(auth, payload, endpoint, %RequestOptions{} = request_options, route_state)
      when is_map(payload) do
    attrs(auth, payload, endpoint, request_options, route_state, nil)
  end

  @spec attrs(
          auth(),
          map(),
          String.t(),
          RequestOptions.t(),
          RouteState.t() | nil,
          String.t() | nil
        ) :: map()
  def attrs(
        auth,
        payload,
        endpoint,
        %RequestOptions{} = request_options,
        route_state,
        authorized_correlation_id
      )
      when is_map(payload) do
    attrs(
      auth,
      payload,
      endpoint,
      request_options,
      route_state,
      authorized_correlation_id,
      NativeHttpTurnIdentity.request_claim(request_options, payload)
    )
  end

  @doc """
  `attrs/6` with the native HTTP turn claim the caller already resolved
  (`NativeHttpTurnIdentity.request_claim/2` for this payload and these request
  options), so a caller that also reads the claim, such as the final-refusal
  lookup before a native HTTP reservation, derives it (and hashes the payload
  for its resend witness) once per request.
  """
  @spec attrs(
          auth(),
          map(),
          String.t(),
          RequestOptions.t(),
          RouteState.t() | nil,
          String.t() | nil,
          {:ok, NativeHttpTurnIdentity.request_claim()} | :none
        ) :: map()
  def attrs(
        auth,
        payload,
        endpoint,
        %RequestOptions{} = request_options,
        route_state,
        authorized_correlation_id,
        native_http_claim
      )
      when is_map(payload) do
    %RequestOptions{
      request_metadata: request_metadata,
      transport: transport
    } = request_options

    accounting_endpoint = accounting_endpoint(endpoint, request_options)

    %{
      endpoint: accounting_endpoint,
      direct_cleanup_bind: direct_cleanup_bind(request_options.runtime.direct_cleanup),
      transport: transport.transport,
      correlation_id:
        authorized_correlation_id ||
          durable_request_correlation_id(request_options, payload, native_http_claim),
      client_ip: request_metadata.client_ip,
      user_agent: request_metadata.user_agent,
      runtime_revocation_epoch: request_options.runtime.api_key_runtime_epoch,
      native_client_retry_witness: native_http_retry_witness(native_http_claim, request_options),
      native_http_input_count: native_http_input_count(native_http_claim),
      native_http_semantic_turn_key: native_http_semantic_turn_key(native_http_claim),
      websocket_compaction_claims: websocket_compaction_claims(native_http_claim),
      native_http_steered_claim: native_http_steered_claim(native_http_claim),
      native_http_turn_progress: native_http_turn_progress(native_http_claim),
      native_http_turn_position: native_http_turn_position(native_http_claim),
      api_key_policy: request_options.routing.api_key_policy,
      codex_session: Map.get(request_options.continuity, :codex_session),
      semantic_turn_digest: Map.get(request_options.continuity, :semantic_turn_key),
      anchor_present?: not is_nil(Map.get(request_options.continuity, :previous_response_id)),
      request_metadata:
        request_metadata_attrs(
          auth,
          payload,
          accounting_endpoint,
          request_options,
          route_state,
          native_http_claim
        )
    }
  end

  defp durable_request_correlation_id(
         %RequestOptions{
           transport: %{transport: "websocket"},
           continuity: %{request_claim_key: request_claim_key}
         },
         _payload,
         _native_http_claim
       )
       when is_binary(request_claim_key),
       do: request_claim_key

  # A native Codex HTTP turn carries the same turn identity a websocket frame
  # does, as the inbound `x-codex-turn-metadata` header, so it reserves under
  # the same payload-scoped claim instead of a fresh UUID and a resend meets
  # `requests_correlation_id_uq` (findings#212). Every other request, and every
  # request without a usable identity, keeps the generated correlation id.
  defp durable_request_correlation_id(%RequestOptions{} = request_options, payload, claim) do
    case claim do
      {:ok, %{key: key}} -> key
      :none -> RequestOptions.server_correlation_id(request_options, payload)
    end
  end

  defp direct_cleanup_bind(nil), do: nil

  defp direct_cleanup_bind(context),
    do: fn request -> DirectCleanup.bind(context, request) end

  @spec reservation_snapshot_inputs(auth(), Model.t(), map(), String.t(), RequestOptions.t()) ::
          RouteState.reservation_snapshot_inputs()
  def reservation_snapshot_inputs(
        %{pool: pool, api_key: api_key},
        %Model{} = model,
        payload,
        endpoint,
        %RequestOptions{} = request_options
      )
      when is_map(payload) do
    effective_model = request_options.routing.effective_model || model.exposed_model_id

    {:ok, estimate} =
      PricingResolution.reservation_estimate(
        payload,
        nil,
        nil
      )

    %{}
    |> Map.put(:pool_id, pool.id)
    |> Map.put(:api_key_id, api_key.id)
    |> Map.put(:effective_model, effective_model)
    |> Map.put(:route_class, RequestOptions.route_class(request_options))
    |> Map.put(:request_class, request_class(endpoint, request_options))
    |> Map.put(:estimated_input_tokens, estimate.input_tokens)
    |> Map.put(:estimated_output_tokens, estimate.output_tokens)
    |> Map.put(:estimated_total_tokens, estimate.total_tokens)
    |> Map.put(:reservation_estimate, estimate)
    |> Map.put(:quota_window_dimension_keys, quota_window_dimension_keys(api_key.id))
  end

  @spec reservation_estimate(RouteState.t()) :: map() | nil
  def reservation_estimate(%RouteState{
        reservation_snapshot_inputs: %{reservation_estimate: estimate}
      }),
      do: estimate

  def reservation_estimate(%RouteState{}), do: nil

  defp accounting_endpoint(
         _endpoint,
         %RequestOptions{
           transport: %{transport: "websocket"},
           openai_compatibility: %{source_endpoint: source_endpoint}
         }
       )
       when is_binary(source_endpoint),
       do: source_endpoint

  defp accounting_endpoint(endpoint, _request_options), do: endpoint

  defp validate_bound_reset_probe_scope(
         [{assignment, identity}],
         %RequestOptions{} = request_options,
         %ResetProbe{} = probe,
         %ResetProbe{} = route_probe
       ) do
    effective_model =
      request_options.routing.effective_model || request_options.routing.requested_model

    if probe == route_probe and
         ResetProbe.matches?(
           probe,
           assignment.id,
           identity.id,
           effective_model,
           RequestOptions.route_class(request_options)
         ) do
      :ok
    else
      reset_probe_scope_error()
    end
  end

  defp validate_bound_reset_probe_scope(
         _candidates,
         %RequestOptions{},
         %ResetProbe{},
         %ResetProbe{}
       ),
       do: reset_probe_scope_error()

  defp reset_probe_scope_error do
    {:error,
     {:reset_probe_scope_mismatch,
      %{
        status: 503,
        code: "no_eligible_backend",
        message: "no healthy eligible backend is currently available",
        param: "model"
      }}}
  end

  defp request_metadata_attrs(
         auth,
         payload,
         endpoint,
         request_options,
         route_state,
         native_http_claim
       ) do
    %RequestOptions{
      request_metadata: request_metadata,
      transport: transport,
      routing: routing
    } = request_options

    %{
      "key_prefix" => auth.key_prefix,
      "transport" => transport.transport,
      "requested_stream" => RouteClass.streaming?(payload),
      "endpoint" => endpoint,
      "requested_model" => routing.requested_model,
      "effective_model" => routing.effective_model,
      "enforced_model" => Denials.enforced_model_metadata(request_options),
      "request_bytes" => request_metadata.request_bytes,
      "upload_bytes" => request_metadata.upload_bytes,
      "request_content_type" => request_metadata.request_content_type,
      "quota_decision" => Routing.accounting_quota_decision(routing)
    }
    |> Map.merge(RequestOptions.client_request_metadata(request_options))
    |> Map.merge(RequestOptions.openai_compatibility_metadata(request_options))
    |> Map.merge(owner_forwarding_metadata(request_options))
    |> Map.merge(reservation_snapshot_metadata(route_state))
    |> Map.merge(compaction_bridge_metadata(request_options.payload_context))
    |> Map.merge(native_http_claim_metadata(native_http_claim))
    |> Map.merge(native_websocket_turn_progress_metadata(request_options))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> SessionContinuity.put_session_metadata(request_options)
  end

  defp reservation_snapshot_metadata(%RouteState{reservation_snapshot_inputs: snapshot_inputs})
       when is_map(snapshot_inputs) do
    %{
      "reservation_snapshot_inputs" => %{
        "pool_id" => snapshot_inputs.pool_id,
        "api_key_id" => snapshot_inputs.api_key_id,
        "effective_model" => snapshot_inputs.effective_model,
        "route_class" => snapshot_inputs.route_class,
        "request_class" => snapshot_inputs.request_class,
        "estimated_input_tokens" => snapshot_inputs.estimated_input_tokens,
        "estimated_output_tokens" => snapshot_inputs.estimated_output_tokens,
        "estimated_total_tokens" => snapshot_inputs.estimated_total_tokens,
        "quota_window_dimension_keys" => snapshot_inputs.quota_window_dimension_keys
      }
    }
  end

  defp reservation_snapshot_metadata(_route_state), do: %{}

  defp compaction_bridge_metadata(%PayloadContext{
         compaction_trigger_bridge?: true,
         compaction_result_transport: result_transport
       })
       when result_transport in [:buffered, :sse] do
    %{
      "compaction_bridge" => %{
        "applied" => true,
        "result_transport" => Atom.to_string(result_transport)
      }
    }
  end

  defp compaction_bridge_metadata(%PayloadContext{}), do: %{}

  defp native_http_claim_metadata({:ok, %{arm: arm, input_count: input_count} = claim}) do
    %{"native_http_claim_arm" => Atom.to_string(arm)}
    |> maybe_put_native_http_input_count(input_count)
    |> maybe_put_native_http_turn_progress(Map.get(claim, :turn_progress), Map.get(claim, :turn_position))
  end

  defp native_http_claim_metadata(:none), do: %{}

  defp native_http_retry_witness(
         {:ok,
          %{
            native_client_retry_witness: %CodexPooler.Accounting.ClientRetry.OriginalWitness{} = witness
          }},
         _request_options
       ),
       do: witness

  defp native_http_retry_witness(_native_http_claim, request_options),
    do: request_options.native_client_retry_witness

  defp native_http_input_count({:ok, %{input_count: input_count}}), do: input_count
  defp native_http_input_count(:none), do: nil

  defp native_http_semantic_turn_key({:ok, %{semantic_turn_key: semantic_turn_key}}),
    do: semantic_turn_key

  defp native_http_semantic_turn_key(:none), do: nil

  defp websocket_compaction_claims({:ok, %{websocket_compaction_claims: claims}}) when is_list(claims), do: claims
  defp websocket_compaction_claims(_native_http_claim), do: []

  defp maybe_put_native_http_input_count(metadata, input_count)
       when is_integer(input_count) and input_count >= 0,
       do: Map.put(metadata, "native_http_input_count", input_count)

  defp maybe_put_native_http_input_count(metadata, _input_count), do: metadata

  # What the reservation compares a later `:opening` request of the same turn
  # against (findings#206 row 206-403); an opaque digest, never the body.
  defp maybe_put_native_http_turn_progress(metadata, <<_::256>> = progress, position),
    do: Map.put(metadata, "native_http_turn_progress", recorded_turn_progress(progress, position))

  defp maybe_put_native_http_turn_progress(metadata, _progress, _position), do: metadata

  # The full-history progress digest of a native websocket request, when its
  # socket knew it, so a later request of the same turn on another socket or
  # over HTTPS is compared against this row (findings#206 row 206-412); an
  # opaque digest, never the body.
  defp native_websocket_turn_progress_metadata(%RequestOptions{transport: %{transport: "websocket"}, extra: %{native_turn_progress: <<_::256>> = progress} = extra}),
    do: %{"native_turn_progress" => recorded_turn_progress(progress, Map.get(extra, :native_turn_position))}

  defp native_websocket_turn_progress_metadata(%RequestOptions{}), do: %{}

  # The digest, and beside it the position that orders a later request of the
  # turn against this row (findings#206 row 206-423): the compaction pivot's
  # digest, absent when there is none, and the count of user messages after it.
  # Readers of the previous release match only `version` and `digest`.
  defp recorded_turn_progress(progress, position) do
    %{"version" => 1, "digest" => Base.url_encode64(progress, padding: false)}
    |> put_recorded_turn_position(position)
  end

  defp put_recorded_turn_position(recorded, {pivot, user_messages}) when is_integer(user_messages) and user_messages >= 0 do
    recorded
    |> Map.put("user_messages", user_messages)
    |> then(&if is_binary(pivot), do: Map.put(&1, "pivot", Base.url_encode64(pivot, padding: false)), else: &1)
  end

  defp put_recorded_turn_position(recorded, _position), do: recorded

  defp native_http_steered_claim({:ok, %{steered_claim: claim}}) when is_binary(claim), do: claim
  defp native_http_steered_claim(_native_http_claim), do: nil

  defp native_http_turn_progress({:ok, %{turn_progress: <<_::256>> = progress}}), do: progress
  defp native_http_turn_progress(_native_http_claim), do: nil

  defp native_http_turn_position({:ok, %{turn_position: {_pivot, _user_messages} = position}}), do: position
  defp native_http_turn_position(_native_http_claim), do: nil

  defp request_class(
         _endpoint,
         %RequestOptions{transport: %{transport: transport}}
       )
       when is_binary(transport),
       do: transport

  defp request_class(endpoint, _request_options), do: endpoint

  defp quota_window_dimension_keys(api_key_id) do
    [
      %{
        api_key_id: api_key_id,
        window_kind: "minute",
        metric: "request_count",
        policy_field: "max_requests_per_minute"
      },
      %{
        api_key_id: api_key_id,
        window_kind: "daily",
        metric: "total_tokens",
        policy_field: "max_tokens_per_day"
      },
      %{
        api_key_id: api_key_id,
        window_kind: "weekly",
        metric: "total_tokens",
        policy_field: "max_tokens_per_week"
      }
    ]
  end

  defp owner_forwarding_metadata(%RequestOptions{
         transport: %{
           websocket_owner: %{
             enabled?: true,
             downstream_epoch: downstream_epoch,
             proxy_instance_id: proxy_instance_id,
             owner_instance_id: owner_instance_id
           }
         }
       }) do
    %{
      "websocket_owner_forwarding" => %{
        "enabled" => true,
        "downstream_epoch" => downstream_epoch,
        "proxy_instance_id" => proxy_instance_id,
        "owner_instance_id" => owner_instance_id
      }
    }
  end

  defp owner_forwarding_metadata(_request_options), do: %{}
end
