defmodule CodexPooler.Gateway.Websocket.Adapter do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.ErrorClassification
  alias CodexPooler.Gateway.ErrorSanitizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.{Metadata, ValidationRejection}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DownstreamSession

  @type socket_state :: map()

  @spec put_runtime(socket_state(), Websocket.websocket_runtime()) :: socket_state()
  def put_runtime(state, runtime), do: DownstreamSession.put_runtime(state, runtime)

  @spec owner?(socket_state()) :: boolean()
  def owner?(state), do: DownstreamSession.owner?(state)

  @spec owner_error?(term()) :: boolean()
  def owner_error?(reason), do: WebsocketOwnerContract.owner_error?(reason)

  @spec close_detail(term()) :: {pos_integer(), String.t()}
  def close_detail(reason), do: DownstreamSession.close_detail(reason)

  @spec accept_downstream_message(term(), socket_state()) ::
          WebsocketOwnerContract.downstream_match_result() | :drop
  def accept_downstream_message(message, state) do
    DownstreamSession.accept_downstream_message(message, state)
  end

  @spec accept_handoff_message(term(), socket_state()) ::
          {:ok, WebsocketOwnerContract.handoff_outcome()}
          | {:ok, {:ready, pid()}}
          | {:ok, {{:failed, :owner_forward_timeout | :owner_drained}, pid()}}
          | :drop
  def accept_handoff_message(message, state) do
    DownstreamSession.accept_handoff_message(message, state)
  end

  @spec preflight_reconnect(socket_state(), <<_::256>>, reference()) ::
          CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.reconnect_preflight_result()
  def preflight_reconnect(state, semantic_turn_key, control_ref) do
    DownstreamSession.preflight_reconnect(state, semantic_turn_key, control_ref)
  end

  @spec reconnect_control_v2(
          socket_state(),
          CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2.t()
        ) :: term()
  def reconnect_control_v2(state, control),
    do: DownstreamSession.reconnect_control_v2(state, control)

  @spec cancel_reconnect(socket_state(), <<_::256>>, reference()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def cancel_reconnect(state, semantic_turn_key, control_ref) do
    DownstreamSession.cancel_reconnect(state, semantic_turn_key, control_ref)
  end

  @spec accept_recovered_runtime(term(), socket_state()) :: {:ok, socket_state()} | :drop
  def accept_recovered_runtime(message, state) do
    DownstreamSession.accept_recovered_runtime(message, state)
  end

  @spec handle_monitor_down(socket_state(), pid(), term()) :: DownstreamSession.monitor_result()
  def handle_monitor_down(state, owner_pid, reason) do
    DownstreamSession.handle_monitor_down(state, owner_pid, reason)
  end

  @spec maybe_retarget_before_start(binary(), socket_state()) ::
          {:ok, socket_state()} | {:error, WebsocketOwnerContract.owner_error()}
  def maybe_retarget_before_start(payload, state) do
    DownstreamSession.maybe_retarget_before_start(payload, state)
  end

  @spec retarget_error_payload(term()) :: {:error, term()}
  def retarget_error_payload(reason), do: DownstreamSession.retarget_error_payload(reason)

  @spec response_options(socket_state(), boolean()) :: RequestOptions.t()
  def response_options(state, reuse_upstream_session?) do
    response_options(state, reuse_upstream_session?, nil)
  end

  @spec response_options(socket_state(), boolean(), pid() | nil) :: RequestOptions.t()
  def response_options(state, reuse_upstream_session?, owner_turn_id) do
    if owner?(state) do
      DownstreamSession.response_options(state, owner_turn_id)
    else
      Websocket.websocket_response_options(
        Map.get(state, :opts, %{}),
        Map.get(state, :codex_session),
        Map.get(state, :upstream_websocket_session),
        reuse_upstream_session?
      )
    end
  end

  @spec cleanup_owner_session(socket_state(), term()) :: :ok
  def cleanup_owner_session(state, reason), do: DownstreamSession.cleanup(state, reason)

  @spec detach_previsible_owner_downstream(socket_state(), term()) :: :suspended | :not_previsible
  def detach_previsible_owner_downstream(state, reason),
    do: DownstreamSession.detach_previsible(state, reason)

  @spec cancel_owner_turn(socket_state(), pid(), :owner_drained) :: :ok
  def cancel_owner_turn(state, owner_turn_id, reason) do
    DownstreamSession.cancel_owner_turn(state, owner_turn_id, reason)
  end

  @spec downstream_response_chunk(binary()) :: binary()
  def downstream_response_chunk(data) when is_binary(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} ->
        {canonical, canonical_decoded} = StreamProtocol.canonicalize_native_codex_responses_json_message(data, decoded)
        native_refusal_frame(canonical, canonical_decoded)

      _other ->
        StreamProtocol.canonicalize_native_codex_responses_json_message(data)
    end
  end

  # A provider 400 refusal arrives as the wrapped
  # `{"type":"error","status":400,...}` frame and is canonicalized to the
  # `response.failed` the response task, the owner and the socket settle and
  # account on (attempt rejection fields included). Only the frame the native
  # client receives is projected here. The released client's parser reads a
  # wrapped 400 as a final invalid request, as it reads the HTTP 400 of the
  # same refusal, and a `response.failed` as a retryable stream error unless it
  # names a code the client classifies itself, so a refusal that can never
  # succeed was resent up to the stream retry budget and then over HTTPS.
  #
  #   * A relayable parameter-validation rejection becomes the wrapped event
  #     with the Pooler-authored error the native HTTP answer relays
  #     (`ValidationRejection`: type, code, bounded param, supported values;
  #     findings#254 row 254-31).
  #   * A code the client classifies from `response.failed`
  #     (`context_length_exceeded`, the quota codes, `usage_not_included`,
  #     `invalid_prompt`, the policy codes, overload and rate limits), and a
  #     code the Pooler itself treats as retryable, keeps the canonical frame.
  #   * Every other refusal, the provider's usual codeless one included,
  #     becomes the wrapped event with the Pooler-authored error built from
  #     its sanitized tokens only (`ValidationRejection.refusal_error/1`,
  #     row 254-52).
  #
  # A refusal with a final status other than 400 (404, 409, 413, 422, ...)
  # goes out as the same wrapped 400, never as a wrapped event of its own
  # status: the client maps any other wrapped status to a retryable unexpected
  # status, so the 400 is the one status it reads as final; the message names
  # the provider status (findings#254 row 254-71, released Codex 0.156.0 lane:
  # before, four websocket resends refused 409 and then six HTTPS requests that
  # all reached the provider; after, one final failure). The same exceptions
  # keep the canonical frame, and so do 401 and 408 (credentials the Pooler
  # refreshes, a timeout) and a 403 that demotes the assignment (a known code
  # outside the health-neutral set, `ErrorCodes.provider_refusal_health_neutral?/2`):
  # the client's HTTPS fallback is then routed to another assignment first and
  # its retry can succeed, while a 403 that demotes nothing (codeless, a
  # health-neutral code, or an unknown code since row 254-81) would reach the
  # same account again.
  #
  # Provider message text never travels: it can quote Pooler-rewritten request
  # fields. The socket holds no per-turn input index map, so an `input[N]`
  # param loses its index rather than name a position a Lite rewrite moved
  # (row 254-61). Every other frame passes unchanged.
  defp native_refusal_frame(canonical, %{"type" => "response.failed", "error" => %{} = error} = canonical_decoded) do
    case wrapped_status(canonical_decoded) do
      400 = status -> native_400_refusal_frame(canonical, status, error)
      status when is_integer(status) -> native_final_refusal_frame(canonical, status, error)
      _other -> canonical
    end
  end

  defp native_refusal_frame(canonical, _canonical_decoded), do: canonical

  defp native_400_refusal_frame(canonical, status, error) do
    response = %Req.Response{status: status, body: CodexPooler.JSON.encode!(%{"error" => error})}

    case ValidationRejection.fetch_ordinary_route(response) do
      %{} = rejection ->
        wrapped_refusal(status, ValidationRejection.error(ValidationRejection.for_client(rejection, :unknown)))

      nil ->
        if classified_or_retryable_code?(Map.get(error, "code")),
          do: canonical,
          else: wrapped_refusal(status, ValidationRejection.refusal_error(provider_rejection_error(status, error)))
    end
  end

  defp native_final_refusal_frame(canonical, status, error) do
    code = Map.get(error, "code")

    cond do
      not final_refusal_status?(status) -> canonical
      classified_or_retryable_code?(code) -> canonical
      status == 403 and not ErrorCodes.provider_refusal_health_neutral?(status, code) -> canonical
      true -> wrapped_refusal(400, ValidationRejection.refusal_error(provider_rejection_error(status, error), upstream_status: status))
    end
  end

  # Every 4xx the released client would only retry into the same refusal:
  # 400 has its own projection above, 401 is the upstream credential the
  # Pooler refreshes, 408 a timeout and 429 a throttle.
  defp final_refusal_status?(status), do: status in 402..499 and status not in [408, 429]

  # Only the wrapped provider frame keeps an integer `status` through the
  # canonicalization; a provider `response.failed` carries none.
  defp wrapped_status(canonical_decoded) do
    case Map.get(canonical_decoded, "status", Map.get(canonical_decoded, "status_code")) do
      status when is_integer(status) -> status
      _other -> nil
    end
  end

  defp classified_or_retryable_code?(code) do
    ErrorCodes.codex_response_failed_classified_code?(code) or ErrorCodes.retryable_first_event_code?(code) or
      ErrorCodes.previous_response_miss_code?(code) or ErrorCodes.websocket_auth_refresh_event_code?(code)
  end

  # The canonicalization writes a code into an error the provider sent without
  # one (its type, or the `upstream_terminal_failure` fallback). That code is
  # the Pooler's derivation, so it is dropped before the relayed code is
  # chosen, as `Finalization.Websocket` drops it from the attempt's rejection
  # fields (findings#254 row 254-60).
  defp provider_rejection_error(status, error) do
    error =
      case error do
        %{"code" => code, "type" => code} -> Map.delete(error, "code")
        %{"code" => "upstream_terminal_failure"} -> Map.delete(error, "code")
        error -> error
      end

    Metadata.rejection_error(%Req.Response{status: status, body: CodexPooler.JSON.encode!(%{"error" => error})})
  end

  defp wrapped_refusal(status, error), do: CodexPooler.JSON.encode!(%{"type" => "error", "status" => status, "error" => error})

  @spec downstream_response_chunk(
          binary(),
          StreamProtocol.public_openai_responses_websocket_state()
        ) ::
          {:push, binary(), StreamProtocol.public_openai_responses_websocket_state()}
          | {:drop, StreamProtocol.public_openai_responses_websocket_state()}
          | {:error, map(), StreamProtocol.public_openai_responses_websocket_state()}
  def downstream_response_chunk(data, turn_state) when is_binary(data) and is_map(turn_state) do
    StreamProtocol.normalize_public_openai_responses_websocket_data(data, turn_state)
  end

  @spec public_responses_turn_state() ::
          StreamProtocol.public_openai_responses_websocket_state()
  @spec public_responses_turn_state(String.t() | nil) ::
          StreamProtocol.public_openai_responses_websocket_state()
  def public_responses_turn_state(stream_id \\ nil) do
    StreamProtocol.public_openai_responses_websocket_state(stream_id)
  end

  @spec public_responses_stream?(socket_state()) :: boolean()
  def public_responses_stream?(%RequestOptions{
        openai_compatibility: %{public_openai_responses_stream: true}
      }),
      do: true

  def public_responses_stream?(%{
        opts: %RequestOptions{
          openai_compatibility: %{public_openai_responses_stream: true}
        }
      }),
      do: true

  def public_responses_stream?(_state), do: false

  @spec request_row_producing_response_payload?(term()) :: boolean()
  def request_row_producing_response_payload?(payload) when is_binary(payload) do
    WebsocketCodec.request_row_producing_response_payload?(payload)
  end

  def request_row_producing_response_payload?(_payload), do: false

  @spec continuity_ordered_payload?(term()) :: boolean()
  def continuity_ordered_payload?(payload) when is_binary(payload) do
    WebsocketCodec.continuity_ordered_payload?(payload)
  end

  def continuity_ordered_payload?(_payload), do: false

  @spec websocket_error(term()) :: map()
  def websocket_error(%{status: status} = reason) do
    %{
      "type" => "error",
      "status" => status,
      "error" => error_payload(reason, status)
    }
  end

  def websocket_error(reason) do
    %{
      "type" => "error",
      "status" => 500,
      "error" => error_payload(reason, 500)
    }
  end

  @spec request_id(term()) :: String.t() | nil
  def request_id(%RequestOptions{} = opts), do: opts.request_metadata.request_id
  def request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id
  def request_id(_opts), do: "none"

  @spec init_failure_metadata(socket_state(), integer()) :: map()
  def init_failure_metadata(state, started_at) do
    opts = Map.get(state, :opts)

    %{
      request_id: request_id(opts),
      endpoint: metadata_endpoint(opts),
      transport: metadata_transport(opts),
      route_class: metadata_route_class(opts),
      phase: "init",
      elapsed_ms: socket_elapsed_ms(started_at),
      codex_session_id: metadata_codex_session_id(state, opts),
      owner_instance_id: metadata_owner_instance_id(state, opts),
      proxy_instance_id: metadata_proxy_instance_id(opts),
      downstream_epoch: metadata_downstream_epoch(state, opts)
    }
  end

  @spec terminate_close_metadata(socket_state()) :: map()
  def terminate_close_metadata(state) do
    opts = Map.get(state, :opts)

    %{
      request_id: request_id(opts),
      endpoint: metadata_endpoint(opts),
      transport: metadata_transport(opts),
      route_class: metadata_route_class(opts),
      phase: "terminate",
      elapsed_ms: socket_elapsed_ms(Map.get(state, :connection_started_at_monotonic_ms)),
      codex_session_id: metadata_codex_session_id(state, opts),
      owner_instance_id: metadata_owner_instance_id(state, opts),
      proxy_instance_id: metadata_proxy_instance_id(opts),
      downstream_epoch: metadata_downstream_epoch(state, opts)
    }
  end

  defp error_payload(%{code: code, message: message} = reason, status) do
    Map.merge(
      %{
        "message" => message,
        "type" => ErrorClassification.error_type(code, status),
        "code" => to_string(code),
        "param" => Map.get(reason, :param)
      },
      Contracts.recovery_error_fields(reason)
    )
  end

  # An unrecognized reason renders as a status-500 gateway failure, which is a
  # server-side failure by construction; typing it `invalid_request_error` told
  # the client its own frame was malformed (findings#184).
  defp error_payload(reason, _status) do
    %{
      "message" => "websocket request failed: #{ErrorSanitizer.safe_reason(reason)}",
      "type" => ErrorClassification.server_error_type(),
      "code" => ErrorCodes.websocket_request_failed_code(),
      "param" => nil
    }
  end

  defp metadata_endpoint(%RequestOptions{transport: %{upstream_endpoint: endpoint}})
       when is_binary(endpoint),
       do: endpoint

  defp metadata_endpoint(%{endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp metadata_endpoint(%{upstream_endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp metadata_endpoint(_opts), do: nil

  defp metadata_transport(%RequestOptions{transport: %{transport: transport}})
       when is_binary(transport),
       do: transport

  defp metadata_transport(%{transport: transport}) when is_binary(transport), do: transport
  defp metadata_transport(_opts), do: nil

  defp metadata_route_class(%RequestOptions{} = opts), do: RequestOptions.route_class(opts)

  defp metadata_route_class(%{route_class: route_class}) when is_binary(route_class),
    do: route_class

  defp metadata_route_class(_opts), do: nil

  defp metadata_codex_session_id(%{codex_session: %{id: id}}, _opts) when is_binary(id), do: id

  defp metadata_codex_session_id(_state, %RequestOptions{continuity: %{codex_session: %{id: id}}})
       when is_binary(id),
       do: id

  defp metadata_codex_session_id(_state, _opts), do: nil

  defp metadata_owner_instance_id(
         %{codex_session: %{owner_instance_id: owner_instance_id}},
         _opts
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(
         _state,
         %RequestOptions{transport: %{websocket_owner: %{owner_instance_id: owner_instance_id}}}
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(
         _state,
         %RequestOptions{continuity: %{owner_instance_id: owner_instance_id}}
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(_state, %{owner_instance_id: owner_instance_id})
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(_state, _opts), do: nil

  defp metadata_proxy_instance_id(%RequestOptions{
         transport: %{websocket_owner: %{proxy_instance_id: proxy_instance_id}}
       })
       when is_binary(proxy_instance_id),
       do: proxy_instance_id

  defp metadata_proxy_instance_id(%{websocket_owner_proxy_instance_id: proxy_instance_id})
       when is_binary(proxy_instance_id),
       do: proxy_instance_id

  defp metadata_proxy_instance_id(_opts), do: nil

  defp metadata_downstream_epoch(%{websocket_owner_downstream: %{epoch: epoch}}, _opts)
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(
         _state,
         %RequestOptions{transport: %{websocket_owner: %{downstream_epoch: epoch}}}
       )
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(_state, %{websocket_owner_downstream_epoch: epoch})
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(_state, _opts), do: nil

  defp socket_elapsed_ms(started_at) when is_integer(started_at) do
    max(System.monotonic_time(:millisecond) - started_at, 0)
  end

  defp socket_elapsed_ms(_started_at), do: nil
end
