defmodule CodexPooler.Gateway.Transports.UpstreamDispatch do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: PersistenceSessionContinuity
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.RouteClass

  defmodule Request do
    @moduledoc false

    alias CodexPooler.Accounting.Request, as: AccountingRequest
    alias CodexPooler.Gateway.Payloads.RequestOptions
    alias CodexPooler.Gateway.Payloads.RequestOptions.Transport
    alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

    defstruct [
      :url,
      :token,
      :upstream_payload,
      :original_payload,
      :identity,
      :accounting_request,
      :writer,
      :request_options
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            token: String.t(),
            upstream_payload: binary() | {:multipart, list()},
            original_payload: map(),
            identity: UpstreamIdentity.t(),
            accounting_request: AccountingRequest.t() | nil,
            writer: Transport.websocket_writer(),
            request_options: RequestOptions.t()
          }
  end

  alias __MODULE__.Request, as: DispatchRequest

  @spec http_request(DispatchRequest.t()) :: {:ok, Req.Response.t()} | {:error, map()}
  def http_request(%DispatchRequest{
        url: url,
        token: token,
        upstream_payload: {:multipart, fields},
        identity: identity,
        request_options: %RequestOptions{} = opts
      }) do
    timeouts = configured_timeouts(opts)

    request_options =
      [
        form_multipart: fields,
        decode_body: false,
        retry: false,
        headers:
          upstream_headers(identity, token, [
            {"accept", "application/json"}
          ])
      ]
      |> Keyword.merge(TransportEnvelope.req_timeout_options(timeouts))

    url
    |> Req.post(request_options)
    |> normalize_upstream_transport_result(identity, opts)
  rescue
    exception in [Req.TransportError, Finch.TransportError, Mint.TransportError, Mint.HTTPError] ->
      log_upstream_transport_exception(exception, identity, opts)
      {:error, upstream_transport_error()}
  end

  def http_request(%DispatchRequest{
        url: url,
        token: token,
        upstream_payload: body,
        original_payload: payload,
        identity: identity,
        request_options: %RequestOptions{} = opts
      }) do
    timeouts = configured_timeouts(opts)

    request_options =
      [
        body: body,
        decode_body: false,
        retry: false,
        headers:
          upstream_headers(identity, token, [
            {"content-type", "application/json"},
            {"accept",
             if(RouteClass.streaming?(payload), do: "text/event-stream", else: "application/json")}
          ])
      ]
      |> Keyword.merge(TransportEnvelope.req_timeout_options(timeouts))

    request_options =
      if RouteClass.streaming?(payload),
        do: Keyword.put(request_options, :into, :self),
        else: request_options

    url
    |> Req.post(request_options)
    |> normalize_upstream_transport_result(identity, opts)
  rescue
    exception in [Req.TransportError, Finch.TransportError, Mint.TransportError, Mint.HTTPError] ->
      log_upstream_transport_exception(exception, identity, opts)
      {:error, upstream_transport_error()}
  end

  @spec websocket_request(DispatchRequest.t()) :: {:ok, map()} | {:error, map()}
  def websocket_request(%DispatchRequest{
        url: url,
        token: token,
        upstream_payload: payload_body,
        identity: identity,
        accounting_request: request,
        writer: writer,
        request_options: %RequestOptions{} = request_options
      }) do
    headers = websocket_headers(identity, token)
    timeouts = request_options.timeout_config
    message_mapper = &StreamProtocol.canonicalize_codex_responses_json_message/1

    upstream_request = %UpstreamWebSocketSession.Request{
      url: url,
      headers: headers,
      payload: payload_body,
      timeouts: timeouts,
      writer: writer,
      message_mapper: message_mapper
    }

    case owner_transport(request_options) do
      {:ok, session, owner_lease_token, downstream, forwarder_opts} ->
        WebsocketOwnerForwarder.submit_request(
          session,
          owner_lease_token,
          downstream,
          upstream_request,
          owner_request_forwarder_opts(forwarder_opts, request_options)
        )
        |> owner_request_result(identity, request)

      :local ->
        direct_websocket_request(request_options, upstream_request, identity, request)
    end
  end

  defp owner_request_forwarder_opts(forwarder_opts, %RequestOptions{} = request_options) do
    Keyword.put_new(
      forwarder_opts,
      :timeout,
      request_options.timeout_config.receive_timeout_ms + 1_000
    )
  end

  defp direct_websocket_request(request_options, upstream_request, identity, request) do
    case request_options.transport.upstream_websocket_session do
      pid when is_pid(pid) ->
        result = UpstreamWebSocketSession.request(pid, upstream_request)

        record_upstream_websocket_body(result, identity, request)

      _pid ->
        UpstreamWebSocketSession.request_once(upstream_request)
        |> record_upstream_websocket_body(identity, request)
    end
  end

  @spec forward_response_processed(map(), RequestOptions.t()) :: :ok | {:error, term()}
  def forward_response_processed(payload, %RequestOptions{} = request_options) do
    with {:ok, _response_id} <- response_processed_response_id(payload) do
      case owner_transport(request_options) do
        {:ok, session, owner_lease_token, downstream, forwarder_opts} ->
          WebsocketOwnerForwarder.submit_frame(
            session,
            owner_lease_token,
            downstream,
            Jason.encode!(response_processed_upstream_payload(payload)),
            forwarder_opts
          )

        :local ->
          forward_response_processed_direct(payload, request_options)
      end
    end
  end

  defp forward_response_processed_direct(payload, request_options) do
    with pid when is_pid(pid) <- request_options.transport.upstream_websocket_session,
         {:ok, :sent} <-
           UpstreamWebSocketSession.send_request_frame(
             pid,
             Jason.encode!(response_processed_upstream_payload(payload))
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _not_forwardable -> {:error, :upstream_websocket_session_missing}
    end
  end

  defp response_processed_upstream_payload(payload) when is_map(payload),
    do: Map.drop(payload, ["request_id", :request_id])

  defp owner_transport(%RequestOptions{
         transport: %{
           websocket_owner_forwarding_enabled?: true,
           websocket_owner_session: session,
           websocket_owner_lease_token: owner_lease_token,
           websocket_owner_downstream: downstream,
           websocket_owner_forwarder_opts: forwarder_opts
         }
       })
       when not is_nil(session) and is_binary(owner_lease_token) and is_map(downstream) and
              is_list(forwarder_opts) do
    {:ok, session, owner_lease_token, downstream, forwarder_opts}
  end

  defp owner_transport(_request_options), do: :local

  defp owner_request_result(:ok, identity, request) do
    {:ok, %{body: "", terminal: "response.completed", status: 200, headers: []}}
    |> record_upstream_websocket_body(identity, request)
  end

  defp owner_request_result({:ok, result}, identity, request) when is_map(result) do
    {:ok, result}
    |> record_upstream_websocket_body(identity, request)
  end

  defp owner_request_result({:error, reason}, _identity, _request) do
    {:error, %{body: "", reason: reason, headers: [], started: false}}
  end

  defp record_upstream_websocket_body(result, identity, request)

  defp record_upstream_websocket_body(
         {:ok, %{body: body, websocket_frame_headers: frame_headers}} = result,
         identity,
         request
       ) do
    RateLimitObserver.record_websocket_frame_headers(identity, frame_headers)
    RateLimitObserver.record_complete_events(identity, body)
    mark_visible_output(request, body)
    result
  end

  defp record_upstream_websocket_body({:ok, %{body: body}} = result, identity, request) do
    RateLimitObserver.record_complete_events(identity, body)
    mark_visible_output(request, body)
    result
  end

  defp record_upstream_websocket_body(
         {:error, %{body: body, websocket_frame_headers: frame_headers}} = result,
         identity,
         request
       ) do
    RateLimitObserver.record_websocket_frame_headers(identity, frame_headers)
    RateLimitObserver.record_complete_events(identity, body)
    mark_visible_output(request, body)
    result
  end

  defp record_upstream_websocket_body({:error, %{body: body}} = result, identity, request) do
    RateLimitObserver.record_complete_events(identity, body)
    mark_visible_output(request, body)
    result
  end

  defp websocket_headers(identity, token) do
    upstream_headers(identity, token, [
      {"openai-beta", "responses_websockets=2026-02-06"}
    ])
  end

  defp normalize_upstream_transport_result(
         {:error, %Finch.TransportError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error()}
  end

  defp normalize_upstream_transport_result(
         {:error, %Req.TransportError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error()}
  end

  defp normalize_upstream_transport_result(
         {:error, %Mint.TransportError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error()}
  end

  defp normalize_upstream_transport_result(
         {:error, %Mint.HTTPError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error()}
  end

  defp normalize_upstream_transport_result(result, _identity, _opts), do: result

  defp upstream_transport_error do
    %{status: 502, code: "upstream_network_error", message: "upstream request failed", param: nil}
  end

  defp log_upstream_transport_exception(exception, identity, opts) do
    Logger.warning(fn ->
      metadata =
        opts
        |> upstream_transport_exception_metadata(exception, identity)
        |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

      "gateway upstream transport failed #{metadata}"
    end)
  end

  defp upstream_transport_exception_metadata(
         %RequestOptions{} = request_options,
         exception,
         identity
       ) do
    routing_metadata = request_options.routing.routing_attempt_metadata || %{}
    routing = Map.get(routing_metadata, "routing", %{})

    [
      transport: safe_log_value(request_options.transport.transport),
      endpoint: safe_log_value(request_options.transport.upstream_endpoint),
      request_id: safe_log_value(request_options.request_metadata.request_id),
      exception: exception |> TransportFailureReason.safe_exception() |> safe_log_value(),
      reason: exception |> TransportFailureReason.safe_reason() |> safe_log_value(),
      upstream_identity_id: safe_log_value(identity.id),
      pool_upstream_assignment_id: safe_log_value(routing["bridge_candidate_id"]),
      route_class: safe_log_value(request_options.transport.route_class),
      routing_strategy: safe_log_value(routing["routing_strategy"])
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp safe_log_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_log_value(value) when is_binary(value), do: value
  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_log_value(_value), do: nil

  defp upstream_headers(identity, token, headers) do
    TransportEnvelope.headers(identity, token, headers, include_user_agent?: true)
  end

  defp mark_visible_output(request, data) when is_binary(data) and data != "" do
    PersistenceSessionContinuity.mark_codex_turn_visible(request)
  end

  defp mark_visible_output(_request, _data), do: :ok

  defp response_processed_response_id(payload) do
    case clean_string(Map.get(payload, "response_id")) do
      response_id when is_binary(response_id) -> {:ok, response_id}
      _missing -> {:error, :missing_response_id}
    end
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp configured_timeouts(%RequestOptions{} = request_options),
    do: request_options.timeout_config
end
