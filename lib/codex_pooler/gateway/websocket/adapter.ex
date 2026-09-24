defmodule CodexPooler.Gateway.Websocket.Adapter do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.ErrorClassification
  alias CodexPooler.Gateway.ErrorSanitizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.{Metadata, NativeRateLimitRelay, ProviderUsageLimit, ValidationRejection}
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

  @spec detach_previsible_owner_downstream(socket_state(), term()) :: :suspended | :detached | :not_previsible
  def detach_previsible_owner_downstream(state, reason),
    do: DownstreamSession.detach_previsible(state, reason)

  @spec cleanup_detached_owner_session(socket_state()) :: :ok
  def cleanup_detached_owner_session(state), do: DownstreamSession.cleanup_detached(state)

  @spec take_over_inherited_owner_turn(socket_state(), <<_::256>> | nil) :: :taken_over | :unsettled | :not_taken_over
  def take_over_inherited_owner_turn(state, request_turn_digest \\ nil), do: DownstreamSession.take_over_inherited_turn(state, request_turn_digest)

  @spec cancel_owner_turn(socket_state(), pid(), :owner_drained) :: :ok
  def cancel_owner_turn(state, owner_turn_id, reason) do
    DownstreamSession.cancel_owner_turn(state, owner_turn_id, reason)
  end

  @spec downstream_response_chunk(binary()) :: binary()
  def downstream_response_chunk(data) when is_binary(data), do: native_downstream_response_chunk(data, fn -> false end)

  @doc """
  The native frame the client receives. `sole_account?` is asked only for a
  provider 403 that demotes the account: when the Pool has no other routable
  assignment for the turn, that refusal goes out final (row 254-93).
  """
  @spec native_downstream_response_chunk(binary(), (-> boolean())) :: binary()
  def native_downstream_response_chunk(data, sole_account?) when is_binary(data) and is_function(sole_account?, 0) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} ->
        {canonical, canonical_decoded} = StreamProtocol.canonicalize_native_codex_responses_json_message(data, decoded)
        native_refusal_frame(canonical, canonical_decoded, sole_account?)

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
  # same account again. A demoting 403 on a Pool with no other routable
  # assignment for the turn's model is final too (row 254-93).
  #
  # Provider message text never travels in a wrapped refusal: it can quote
  # Pooler-rewritten request fields. A kept 401 or demoting 403 carries the
  # Pooler message naming the status instead (row 254-91). The socket holds no per-turn input index map, so an `input[N]`
  # param loses its index rather than name a position a Lite rewrite moved
  # (row 254-61). Every other frame passes unchanged.
  defp native_refusal_frame(canonical, %{"type" => "response.failed", "error" => %{} = error} = canonical_decoded, sole_account?) do
    case wrapped_status(canonical_decoded) do
      400 = status -> native_400_refusal_frame(canonical, status, error)
      429 -> native_usage_limit_frame(canonical, canonical_decoded)
      status when is_integer(status) -> native_final_refusal_frame(canonical, canonical_decoded, status, error, sole_account?)
      _other -> canonical
    end
  end

  defp native_refusal_frame(canonical, _canonical_decoded, _sole_account?), do: canonical

  # A provider usage limit with a reset still ahead goes out as the wrapped
  # terminal `429` event of an all-exhausted Pool (findings#206 rows 206-508,
  # 206-546): the released client maps a wrapped `429` naming
  # `usage_limit_reached` to its terminal usage limit and shows the reset,
  # while it reads a `response.failed` naming that code as a retryable stream
  # error and resends the turn. The provider's message and plan never travel.
  # Any other 429 keeps the canonical frame.
  #
  # A usage limit whose Pool advice was withheld, or whose reset is not known,
  # goes out as the wrapped `429` with the classified error native HTTP sends
  # for the same refusal (`NativeRateLimitRelay`: type, code, the provider's
  # reset, the Pooler's message; findings#206 rows 206-589, 206-592). The
  # canonical `response.failed` it used to keep is a retryable stream error to
  # the released client, which reconnected five times and then fell back to
  # HTTP.
  defp native_usage_limit_frame(canonical, canonical_decoded) do
    case ProviderUsageLimit.frame_projection(canonical_decoded) do
      {:terminal, error} -> error |> websocket_error() |> CodexPooler.JSON.encode!()
      {:relay, provider_error} -> relay_usage_limit_frame(provider_error)
      :canonical -> canonical
    end
  end

  # The canonical frame carries the error type again as its code when the
  # provider sent none; that derived code is not the provider's and is dropped,
  # so the relay reads the same tokens native HTTP does.
  defp relay_usage_limit_frame(provider_error) do
    provider_error = if provider_error["code"] == provider_error["type"], do: Map.delete(provider_error, "code"), else: provider_error
    error = NativeRateLimitRelay.error(%Req.Response{status: 429, body: CodexPooler.JSON.encode!(%{"error" => provider_error})})
    CodexPooler.JSON.encode!(%{"type" => "error", "status" => 429, "error" => error})
  end

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

  defp native_final_refusal_frame(canonical, canonical_decoded, status, error, sole_account?) do
    case final_refusal_projection(status, Map.get(error, "code"), sole_account?) do
      :final -> wrapped_refusal(400, ValidationRejection.refusal_error(provider_rejection_error(status, error), upstream_status: status))
      :account -> account_refusal_frame(canonical_decoded, status, error)
      :canonical -> canonical
    end
  end

  @doc """
  The error of the final wrapped 400 a native websocket turn received for a
  provider refusal, rebuilt from its attempt's recorded rejection metadata
  (the provider status and the sanitized tokens), or `:none` when that refusal
  kept a retryable frame, was never recorded with its status, or is not a
  refusal at all. A resend of that turn is answered with this error instead of
  `409 duplicate_turn`: the released client's in-band compaction resends a
  refused compaction frame up to five times and then showed the duplicate
  refusal instead of the provider's (findings#254 row 254-100). A demoting 403
  is read as retryable here, as it is on a Pool with another assignment.

  A refusal an HTTP predecessor received (`rejection_predecessor_transport`,
  set by `ClientRetry.final_refusal_predecessor/2`) is answered only when it is
  a relayable validation rejection, which the provider repeats for the same
  body (findings#254 row 254-141). Every other relayed 4xx of an HTTP turn keeps
  the native HTTP claim's step-over and is served again (findings#212 row
  212-50, "a resend after a relayed 4xx is served, not refused").
  """
  @spec recorded_final_refusal_error(map() | term()) :: {:ok, map()} | :none
  def recorded_final_refusal_error(%{"rejection_predecessor_transport" => "http"} = metadata) do
    if metadata["rejection_upstream_status"] == 400 and metadata["rejection_error_type"] == "invalid_request_error" and
         metadata["rejection_error_code"] in ValidationRejection.relayable_codes(),
       do: metadata |> Map.delete("rejection_predecessor_transport") |> recorded_final_refusal_error(),
       else: :none
  end

  def recorded_final_refusal_error(%{"rejection_upstream_status" => status} = metadata) when is_integer(status) do
    error =
      %{"code" => metadata["rejection_error_code"], "type" => metadata["rejection_error_type"], "param" => metadata["rejection_error_param"]}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case recorded_refusal_projection(status, error, metadata) do
      %{"code" => _code, "message" => _message} = refusal -> {:ok, refusal}
      :none -> :none
    end
  end

  def recorded_final_refusal_error(_metadata), do: :none

  defp recorded_refusal_projection(400 = status, error, metadata) do
    cond do
      error["type"] == "invalid_request_error" and error["code"] in ValidationRejection.relayable_codes() ->
        %{
          code: error["code"],
          param: error["param"],
          supported_values: metadata["rejection_supported_values"],
          supported_values_state: metadata["rejection_supported_values_state"]
        }
        |> ValidationRejection.for_client(:unknown)
        |> ValidationRejection.error()

      classified_or_retryable_code?(error["code"]) ->
        :none

      # The provider's codeless refusal of an anchor the connection could not
      # resolve went out as the `previous_response_not_found` retry event, not
      # as a final refusal (findings#232 row 232-278).
      metadata["rejection_message_class"] == "invalid_previous_response_id" ->
        :none

      true ->
        ValidationRejection.refusal_error(provider_rejection_error(status, error))
    end
  end

  defp recorded_refusal_projection(status, error, _metadata) do
    case final_refusal_projection(status, error["code"], fn -> false end) do
      :final -> ValidationRejection.refusal_error(provider_rejection_error(status, error), upstream_status: status)
      _retryable -> :none
    end
  end

  defp final_refusal_projection(401, code, _sole_account?) do
    if ErrorCodes.codex_response_failed_classified_code?(code), do: :canonical, else: :account
  end

  defp final_refusal_projection(403 = status, code, sole_account?) do
    cond do
      not demoting_account_refusal?(status, code) -> ordinary_final_refusal_projection(status, code)
      sole_account?.() -> :final
      true -> :account
    end
  end

  defp final_refusal_projection(status, code, _sole_account?), do: ordinary_final_refusal_projection(status, code)

  defp ordinary_final_refusal_projection(status, code) do
    cond do
      not ValidationRejection.final_refusal_status?(status) -> :canonical
      classified_or_retryable_code?(code) -> :canonical
      true -> :final
    end
  end

  # A 401 and a 403 that demotes the account keep the retryable canonical
  # `response.failed` (above), but they are about the Pooler's upstream account,
  # never about the client's request, so the provider's text is replaced by the
  # Pooler-written message naming the status; code, type and status stay.
  # A code the client classifies keeps its provider message (row 254-83), and a
  # 408 or 429 keeps the provider's retry or limit detail the client acts on
  # (findings#254 row 254-91).
  #
  # A demoting 403 is retryable because its HTTPS fallback meets another
  # assignment first. With no other routable assignment the retry reaches the
  # demoted account again: on a single-assignment Pool the released client spent
  # four refused websocket resends and one HTTPS provider request on it (P33
  # lane), so it goes out as the final wrapped 400 naming the status instead
  # (findings#254 row 254-93).
  defp demoting_account_refusal?(status, code),
    do: not ErrorCodes.codex_response_failed_classified_code?(code) and not ErrorCodes.provider_refusal_health_neutral?(status, code)

  defp account_refusal_frame(canonical_decoded, status, error) do
    %{"message" => message} = ValidationRejection.refusal_error(provider_rejection_error(status, error), upstream_status: status)

    canonical_decoded
    |> put_in(["error", "message"], message)
    |> Map.replace_lazy("response", fn
      %{"error" => %{} = response_error} = response -> Map.put(response, "error", Map.put(response_error, "message", message))
      response -> response
    end)
    |> CodexPooler.JSON.encode!()
  end

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
    |> put_policy_retry_headers(reason)
  end

  def websocket_error(reason) do
    %{
      "type" => "error",
      "status" => 500,
      "error" => error_payload(reason, 500)
    }
  end

  # A key policy window's retry hint travels as the wrapped error's `headers`,
  # the field the released client reads as the HTTP response headers of a
  # websocket error, like HTTP's `Retry-After` (findings#206 row 206-427).
  defp put_policy_retry_headers(event, %{pooler_policy: true, status: 429, retry_after_seconds: seconds})
       when is_integer(seconds) and seconds > 0,
       do: Map.put(event, "headers", %{"retry-after" => Integer.to_string(seconds)})

  # An all-exhausted Pool's retry hint rides the same field (findings#206 row
  # 206-508); the released client reads it with the wrapped error's body.
  defp put_policy_retry_headers(event, %{status: 429, usage_limit: %{resets_in_seconds: seconds}}),
    do: Map.put(event, "headers", %{"retry-after" => Integer.to_string(seconds)})

  # A retryable `503` with an open-circuit candidate carries the seconds until
  # that circuit admits a probe the same way (findings#206 row 206-532).
  defp put_policy_retry_headers(event, %{status: 503, circuit_retry_after_seconds: seconds}) when is_integer(seconds) and seconds > 0,
    do: Map.put(event, "headers", %{"retry-after" => Integer.to_string(seconds)})

  defp put_policy_retry_headers(event, _reason), do: event

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
      reason |> Contracts.recovery_error_fields() |> Map.merge(Contracts.usage_limit_error_fields(reason))
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
