defmodule CodexPooler.Gateway.Websocket.Adapter do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.ErrorSanitizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.OwnerErrorVocabulary
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DownstreamSession

  @overload_code "server_is_overloaded"

  # An OpenAI-compatible SDK branches on `type`, not on `status`:
  # `invalid_request_error` is the terminal, do-not-retry class, and it used to
  # be this renderer's default for everything except the overload code. That
  # inverted findings#168's classification at the last step — an owner-lifecycle
  # 503 told the client never to retry the one case that should be (findings#184)
  # — and a default is how it happened, so the vocabulary is enumerated instead.
  #
  # Server class: the turn failed for a reason on this side of the wire and the
  # same request can succeed on a retry. `owner_busy` is backpressure and
  # `stale_owner` is a lease that moved, so both belong here even at 409.
  # `upstream_websocket_terminal_delivery_timeout` is a vocabulary name that is
  # never emitted as a wire code (it renders as `upstream_stream_error`); it is
  # classified so the exhaustiveness check below covers the whole vocabulary.
  @server_error_codes [
    @overload_code,
    "owner_busy",
    "owner_crashed",
    "owner_drained",
    "owner_forward_timeout",
    "owner_forwarding_disabled",
    "owner_unavailable",
    "server_error",
    "stale_owner",
    "upstream_stream_error",
    "upstream_websocket_terminal_delivery_timeout",
    "websocket_request_failed"
  ]

  # Client class: this connection is the problem, and retrying the same frame on
  # it cannot work. A downstream that was replaced or is speaking on a
  # superseded epoch was superseded by the client's own newer connection, and
  # `client_disconnected` cannot reach a live client at all.
  @client_error_codes [
    "client_disconnected",
    "duplicate_downstream",
    "stale_downstream"
  ]

  @unclassified_owner_error_codes OwnerErrorVocabulary.owner_error_codes() --
                                    (@server_error_codes ++ @client_error_codes)

  if @unclassified_owner_error_codes != [] do
    raise "websocket owner error codes are unclassified in Adapter.error_type/3: " <>
            Enum.join(@unclassified_owner_error_codes, ", ") <>
            ". Classify each one as server or client class rather than letting it " <>
            "inherit a default (findings#184)."
  end

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

  @spec cancel_owner_turn(socket_state(), pid(), :owner_drained) :: :ok
  def cancel_owner_turn(state, owner_turn_id, reason) do
    DownstreamSession.cancel_owner_turn(state, owner_turn_id, reason)
  end

  @spec downstream_response_chunk(binary()) :: binary()
  def downstream_response_chunk(data) when is_binary(data) do
    StreamProtocol.canonicalize_native_codex_responses_json_message(data)
  end

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
        "type" => error_type(code, status, Map.get(reason, :retryable)),
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
      "type" => "server_error",
      "code" => ErrorCodes.websocket_request_failed_code(),
      "param" => nil
    }
  end

  # The enumerated vocabulary decides first. Anything outside it is classified
  # from what the error itself carries rather than from a constant: an error
  # that already declares `retryable: false` (the hard pinned-continuation
  # recoveries) is terminal for this request whatever its status, and a
  # remaining 5xx is a server-side failure. Only a non-5xx, non-vocabulary code
  # — a relayed provider or local validation rejection — is a client error.
  defp error_type(code, status, retryable) do
    code = to_string(code)

    cond do
      code in @server_error_codes -> "server_error"
      code in @client_error_codes -> "invalid_request_error"
      retryable == false -> "invalid_request_error"
      is_integer(status) and status >= 500 -> "server_error"
      true -> "invalid_request_error"
    end
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
