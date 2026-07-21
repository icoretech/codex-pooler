defmodule CodexPooler.Gateway.Transports.UpstreamDispatch do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: PersistenceSessionContinuity
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Transports.BoundedResponseBody
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @regular_runtime_metadata_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/responses/compact"
  ]
  @regular_runtime_metadata_header_names [
    "x-codex-turn-metadata",
    "x-codex-window-id",
    "x-codex-parent-thread-id",
    "x-codex-installation-id",
    "x-codex-turn-state",
    "x-openai-subagent"
  ]
  @responses_lite_header_name "x-openai-internal-codex-responses-lite"
  @stable_downstream_keys [:active_turn_reconnect?, :correlation_id, :epoch, :pid]
  @public_per_call_downstream_keys [:owner_turn_id | @stable_downstream_keys]

  @type header :: {String.t(), String.t()}
  @type owner_transport ::
          {:ok, CodexSession.t(), String.t(), map(), keyword()}
          | :local
          | {:error, WebsocketOwnerContract.owner_error()}

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
      :assignment_advertised?,
      :request_options
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            token: String.t(),
            upstream_payload: binary() | {:multipart, list()},
            original_payload: map() | nil,
            identity: UpstreamIdentity.t(),
            accounting_request: AccountingRequest.t() | nil,
            writer: Transport.websocket_writer(),
            assignment_advertised?: boolean(),
            request_options: RequestOptions.t()
          }
  end

  alias __MODULE__.Request, as: DispatchRequest

  @doc false
  @spec regular_runtime_headers(
          UpstreamIdentity.t(),
          String.t(),
          RequestOptions.t(),
          [header()],
          keyword()
        ) :: [header()]
  def regular_runtime_headers(
        identity,
        token,
        %RequestOptions{} = request_options,
        headers,
        opts \\ []
      )
      when is_list(headers) and is_list(opts) do
    envelope_opts =
      opts
      |> Keyword.put(:include_codex_identity?, true)
      |> Keyword.put(
        :forwarded_headers,
        regular_runtime_forwarded_metadata_headers(request_options)
      )

    headers = maybe_put_responses_lite_header(headers, request_options)

    TransportEnvelope.headers(identity, token, headers, envelope_opts)
  end

  @doc false
  @spec regular_runtime_forwarded_metadata_headers(RequestOptions.t()) :: [header()]
  def regular_runtime_forwarded_metadata_headers(%RequestOptions{
        transport: %{
          upstream_endpoint: endpoint,
          forwarded_metadata_headers: forwarded_headers
        },
        openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
      })
      when endpoint in @regular_runtime_metadata_endpoints and is_list(forwarded_headers) do
    filter_regular_runtime_forwarded_metadata_headers(forwarded_headers)
  end

  def regular_runtime_forwarded_metadata_headers(%RequestOptions{}), do: []

  defp filter_regular_runtime_forwarded_metadata_headers(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)

        if name in @regular_runtime_metadata_header_names do
          [{name, value}]
        else
          []
        end

      _other ->
        []
    end)
  end

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
        into: BoundedResponseBody.collector(BoundedResponseBody.default_max_bytes()),
        headers:
          CloudflareCookies.request_headers(
            url,
            upstream_headers(identity, token, [
              {"accept", "application/json"}
            ])
          )
      ]
      |> Keyword.merge(TransportEnvelope.req_timeout_options(timeouts))

    result = Req.post(url, request_options)
    CloudflareCookies.store_from_result(url, result)

    result
    |> normalize_upstream_transport_result(identity, opts)
  rescue
    exception in [
      Req.TransportError,
      Req.HTTPError,
      Finch.TransportError,
      Finch.HTTPError,
      Mint.TransportError,
      Mint.HTTPError
    ] ->
      log_upstream_transport_exception(exception, identity, opts)
      {:error, upstream_transport_error(exception)}
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
          CloudflareCookies.request_headers(
            url,
            regular_runtime_headers(identity, token, opts, [
              {"content-type", "application/json"},
              {"accept",
               if(RouteClass.streaming?(payload),
                 do: "text/event-stream",
                 else: "application/json"
               )}
            ])
          )
      ]
      |> Keyword.merge(TransportEnvelope.req_timeout_options(timeouts))

    request_options =
      if RouteClass.streaming?(payload) do
        Keyword.put(request_options, :into, :self)
      else
        Keyword.put(
          request_options,
          :into,
          BoundedResponseBody.collector(BoundedResponseBody.default_max_bytes())
        )
      end

    result = Req.post(url, request_options)
    CloudflareCookies.store_from_result(url, result)

    result
    |> normalize_upstream_transport_result(identity, opts)
  rescue
    exception in [
      Req.TransportError,
      Req.HTTPError,
      Finch.TransportError,
      Finch.HTTPError,
      Mint.TransportError,
      Mint.HTTPError
    ] ->
      log_upstream_transport_exception(exception, identity, opts)
      {:error, upstream_transport_error(exception)}
  end

  @spec websocket_request(DispatchRequest.t()) :: {:ok, map()} | {:error, map()}
  def websocket_request(%DispatchRequest{
        url: url,
        token: token,
        upstream_payload: payload_body,
        identity: identity,
        accounting_request: request,
        writer: writer,
        assignment_advertised?: assignment_advertised?,
        request_options: %RequestOptions{} = request_options
      }) do
    headers = websocket_headers(identity, token)
    timeouts = request_options.timeout_config
    message_mapper = &StreamProtocol.canonicalize_codex_responses_json_message/1

    upstream_request = %UpstreamWebsocketSession.Request{
      url: url,
      headers: headers,
      payload: payload_body,
      timeouts: timeouts,
      writer: writer,
      message_mapper: message_mapper,
      frame_observer: websocket_frame_observer(identity),
      assignment_advertised?: assignment_advertised?,
      forward_error_body?: false
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

      {:error, reason} ->
        owner_request_result({:error, reason}, identity, request)
    end
  end

  defp owner_request_forwarder_opts(forwarder_opts, %RequestOptions{} = request_options) do
    timeout =
      max(
        request_options.timeout_config.receive_timeout_ms + 1_000,
        OperationalSettings.current().websocket_idle_timeout_ms + 1_000
      )

    Keyword.put_new(
      forwarder_opts,
      :timeout,
      timeout
    )
  end

  defp direct_websocket_request(request_options, upstream_request, identity, request) do
    case request_options.transport.upstream_websocket_session do
      pid when is_pid(pid) ->
        result = UpstreamWebsocketSession.request(pid, upstream_request)

        record_upstream_websocket_body(result, identity, request)

      _pid ->
        UpstreamWebsocketSession.request_once(upstream_request)
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

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp forward_response_processed_direct(payload, request_options) do
    with pid when is_pid(pid) <- request_options.transport.upstream_websocket_session,
         {:ok, :sent} <-
           UpstreamWebsocketSession.send_request_frame(
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

  @spec owner_transport(RequestOptions.t()) :: owner_transport()
  defp owner_transport(
         %RequestOptions{
           transport: %{websocket_owner: %{enabled?: true}}
         } = request_options
       ) do
    owner_forwarded_transport(request_options)
  end

  defp owner_transport(%RequestOptions{transport: transport}) do
    if owner_transport_bundle_present?(transport.websocket_owner),
      do: {:error, :owner_forwarding_disabled},
      else: :local
  end

  defp owner_forwarded_transport(%RequestOptions{
         openai_compatibility: openai_compatibility,
         continuity: %{codex_session: continuity_session},
         transport: %{
           upstream_websocket_bridge?: upstream_websocket_bridge?,
           websocket_owner: %{
             session: owner_session,
             lease_token: owner_lease_token,
             downstream: downstream,
             downstream_epoch: downstream_epoch,
             proxy_instance_id: proxy_instance_id,
             owner_instance_id: owner_instance_id,
             forwarder_opts: forwarder_opts
           }
         }
       }) do
    with :ok <- validate_owner_sessions(continuity_session, owner_session, owner_lease_token),
         :ok <-
           validate_owner_downstream(
             downstream,
             downstream_epoch,
             openai_compatibility.public_openai_responses_stream,
             upstream_websocket_bridge?
           ),
         :ok <- validate_owner_instances(proxy_instance_id, owner_instance_id, owner_session),
         :ok <- validate_owner_forwarder_opts(forwarder_opts) do
      {:ok, owner_session, owner_lease_token, downstream, forwarder_opts}
    end
  end

  defp validate_owner_sessions(continuity_session, owner_session, owner_lease_token) do
    cond do
      not match?(%CodexSession{}, continuity_session) ->
        {:error, :stale_owner}

      not match?(%CodexSession{}, owner_session) ->
        {:error, :stale_owner}

      continuity_session.id != owner_session.id ->
        {:error, :stale_owner}

      not clean_binary?(owner_lease_token) ->
        {:error, :stale_owner}

      clean_string(owner_session.owner_lease_token) != clean_string(owner_lease_token) ->
        {:error, :stale_owner}

      true ->
        :ok
    end
  end

  defp validate_owner_downstream(
         downstream,
         downstream_epoch,
         public_responses_stream?,
         upstream_websocket_bridge?
       ) do
    cond do
      not owner_downstream?(downstream) ->
        {:error, :stale_owner}

      not owner_downstream_epoch_matches?(downstream_epoch, downstream) ->
        {:error, :stale_owner}

      true ->
        validate_owner_downstream_contract(
          downstream,
          public_responses_stream?,
          upstream_websocket_bridge?
        )
    end
  end

  defp validate_owner_downstream_contract(_downstream, false, _upstream_websocket_bridge?),
    do: :ok

  defp validate_owner_downstream_contract(downstream, true, true),
    do: valid_owner_downstream_result(valid_bridge_owner_downstream?(downstream))

  defp validate_owner_downstream_contract(downstream, true, false),
    do: valid_owner_downstream_result(valid_public_owner_turn_downstream?(downstream))

  defp valid_owner_downstream_result(true), do: :ok
  defp valid_owner_downstream_result(false), do: {:error, :stale_owner}

  defp validate_owner_instances(proxy_instance_id, owner_instance_id, owner_session) do
    cond do
      not clean_binary?(proxy_instance_id) ->
        {:error, :stale_owner}

      not owner_instance_matches?(owner_instance_id, owner_session) ->
        {:error, :stale_owner}

      true ->
        :ok
    end
  end

  defp validate_owner_forwarder_opts(forwarder_opts) when is_list(forwarder_opts), do: :ok

  defp validate_owner_forwarder_opts(_forwarder_opts), do: {:error, :stale_owner}

  defp owner_transport_bundle_present?(owner) do
    not is_nil(owner.session) or
      clean_binary?(owner.lease_token) or
      is_map(owner.downstream) or
      is_integer(owner.downstream_epoch) or
      clean_binary?(owner.proxy_instance_id) or
      clean_binary?(owner.owner_instance_id)
  end

  defp owner_downstream?(%{pid: pid, correlation_id: correlation_id}),
    do: is_pid(pid) and clean_binary?(correlation_id)

  defp owner_downstream?(_downstream), do: false

  defp owner_downstream_epoch_matches?(epoch, %{epoch: epoch})
       when is_integer(epoch) and epoch > 0,
       do: true

  defp owner_downstream_epoch_matches?(_epoch, _downstream), do: false

  defp valid_public_owner_turn_downstream?(downstream) do
    map_size(downstream) == length(@public_per_call_downstream_keys) and
      Enum.all?(@public_per_call_downstream_keys, &Map.has_key?(downstream, &1)) and
      is_pid(Map.get(downstream, :owner_turn_id)) and
      Map.get(downstream, :owner_turn_id) == self() and
      is_boolean(Map.get(downstream, :active_turn_reconnect?))
  end

  defp valid_bridge_owner_downstream?(downstream) do
    map_size(downstream) == length(@stable_downstream_keys) and
      Enum.all?(@stable_downstream_keys, &Map.has_key?(downstream, &1)) and
      is_boolean(Map.get(downstream, :active_turn_reconnect?))
  end

  defp owner_instance_matches?(owner_instance_id, %CodexSession{
         owner_instance_id: owner_instance_id
       })
       when is_binary(owner_instance_id),
       do: clean_binary?(owner_instance_id)

  defp owner_instance_matches?(_owner_instance_id, _owner_session), do: false

  defp owner_request_result(:ok, identity, request) do
    {:ok, %{body: "", terminal: "response.completed", status: 200, headers: []}}
    |> record_upstream_websocket_body(identity, request)
  end

  defp owner_request_result({:ok, result}, identity, request) when is_map(result) do
    {:ok, result}
    |> record_upstream_websocket_body(identity, request)
  end

  defp owner_request_result(
         {:error, %{body: _body, reason: _reason} = response},
         _identity,
         _request
       ) do
    {:error, response}
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
    mark_visible_output(request, body)
    result
  end

  defp record_upstream_websocket_body({:ok, %{body: body}} = result, _identity, request) do
    mark_visible_output(request, body)
    result
  end

  defp record_upstream_websocket_body(
         {:error, %{body: body, websocket_frame_headers: frame_headers}} = result,
         identity,
         request
       ) do
    RateLimitObserver.record_websocket_frame_headers(identity, frame_headers)
    mark_visible_output(request, body)
    result
  end

  defp record_upstream_websocket_body({:error, %{body: body}} = result, _identity, request) do
    mark_visible_output(request, body)
    result
  end

  defp websocket_frame_observer(identity) do
    fn frame ->
      RateLimitObserver.record_complete_events(identity, frame)
    end
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
    {:error, upstream_transport_error(exception)}
  end

  defp normalize_upstream_transport_result(
         {:error, %Req.TransportError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error(exception)}
  end

  defp normalize_upstream_transport_result(
         {:error, %Req.HTTPError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error(exception)}
  end

  defp normalize_upstream_transport_result(
         {:error, %Mint.TransportError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error(exception)}
  end

  defp normalize_upstream_transport_result(
         {:error, %Mint.HTTPError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error(exception)}
  end

  defp normalize_upstream_transport_result(
         {:error, %Finch.HTTPError{} = exception},
         identity,
         opts
       ) do
    log_upstream_transport_exception(exception, identity, opts)
    {:error, upstream_transport_error(exception)}
  end

  defp normalize_upstream_transport_result({:ok, %Req.Response{} = response}, _identity, _opts),
    do: {:ok, BoundedResponseBody.finalize(response)}

  defp normalize_upstream_transport_result(result, _identity, _opts), do: result

  defp upstream_transport_error(reason) do
    TransportFailureReason.upstream_transport_error(reason, %{phase: :request})
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
    TransportEnvelope.headers(identity, token, headers, include_codex_identity?: true)
  end

  defp mark_visible_output(request, data) when is_binary(data) and data != "" do
    PersistenceSessionContinuity.mark_codex_turn_visible(request)
  end

  defp mark_visible_output(_request, _data), do: :ok

  defp maybe_put_responses_lite_header(headers, %RequestOptions{} = request_options) do
    headers =
      Enum.reject(headers, fn
        {name, _value} when is_binary(name) ->
          String.downcase(name) == @responses_lite_header_name

        _header ->
          false
      end)

    if RequestOptions.use_responses_lite?(request_options) and
         regular_responses_endpoint?(request_options) do
      [{@responses_lite_header_name, "true"} | headers]
    else
      headers
    end
  end

  defp regular_responses_endpoint?(%RequestOptions{
         transport: %{upstream_endpoint: endpoint}
       }) do
    endpoint in @regular_runtime_metadata_endpoints
  end

  defp response_processed_response_id(payload) do
    case clean_string(Map.get(payload, "response_id")) do
      response_id when is_binary(response_id) -> {:ok, response_id}
      _missing -> {:error, :missing_response_id}
    end
  end

  defp clean_binary?(value), do: is_binary(clean_string(value))

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp configured_timeouts(%RequestOptions{} = request_options),
    do: request_options.timeout_config
end
