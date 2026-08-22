defmodule CodexPooler.Gateway.Transports.UpstreamDispatch do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.Gateway.Payloads.RequestOptions.{ResetProbe, TimeoutConfig}
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: PersistenceSessionContinuity
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Transports.BoundedResponseBody
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.RejectionBody
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  # Every field an owner success reply must carry, taken from what the local
  # producer emits (`UpstreamWebsocketSession` request_success) and what the
  # consumers destructure without a default: `record_upstream_websocket_body/3`
  # needs `:body`, `WebsocketAttempt` dispatches on `:terminal`, and
  # `Finalization.Websocket` destructures `:status` and `:headers`. Extend this
  # list whenever a consumer starts requiring another field.
  @owner_success_fields [:body, :terminal, :status, :headers]

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
  @routing_hint_header_name "x-codex-routing-hint"
  @stable_downstream_keys [:active_turn_reconnect?, :correlation_id, :epoch, :pid]
  @public_per_call_downstream_keys [:owner_turn_id | @stable_downstream_keys]

  @type header :: {String.t(), String.t()}
  @type owner_transport ::
          {:ok, CodexSession.t(), String.t(), map(), keyword()}
          | :local
          | {:error, WebsocketOwnerContract.owner_error()}
  @type websocket_request_data :: %{
          required(:url) => String.t(),
          required(:headers) => [header()],
          required(:payload) => binary(),
          required(:timeouts) => TimeoutConfig.t(),
          required(:mapper) => WebsocketOwnerRequest.mapper(),
          required(:identity) => UpstreamIdentity.t(),
          required(:observation) => WebsocketOwnerRequest.observation(),
          required(:reset_probe) => ResetProbe.t() | nil,
          required(:native_codex_response_control) =>
            CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot.t() | nil,
          required(:assignment_advertised?) => boolean(),
          required(:connection_bound_continuation?) => boolean(),
          required(:forward_error_body?) => boolean()
        }

  defmodule Request do
    @moduledoc false

    alias CodexPooler.Accounting.Attempt, as: AccountingAttempt
    alias CodexPooler.Accounting.Request, as: AccountingRequest
    alias CodexPooler.Gateway.Payloads.RequestOptions
    alias CodexPooler.Gateway.Payloads.RequestOptions.Transport
    alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
    alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

    defstruct [
      :url,
      :token,
      :upstream_payload,
      :original_payload,
      :identity,
      :routing_hint_authorized?,
      :accounting_request,
      :accounting_attempt,
      :writer,
      :assignment_advertised?,
      :native_codex_response_control,
      :request_options
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            token: String.t(),
            upstream_payload: binary() | {:multipart, list()},
            original_payload: map() | nil,
            identity: UpstreamIdentity.t(),
            routing_hint_authorized?: boolean(),
            accounting_request: AccountingRequest.t() | nil,
            accounting_attempt: AccountingAttempt.t() | nil,
            writer: Transport.websocket_writer(),
            assignment_advertised?: boolean(),
            native_codex_response_control: TurnSnapshot.t() | nil,
            request_options: RequestOptions.t()
          }
  end

  defimpl Inspect, for: Request do
    def inspect(_request, _opts) do
      "#CodexPooler.Gateway.Transports.UpstreamDispatch.Request<redacted>"
    end
  end

  defmodule RejectionDrain do
    @moduledoc false

    @max_bytes 65_536
    @timeout_ms 2_000

    @spec drain(Req.Response.t()) :: binary()
    def drain(%Req.Response{body: %Req.Response.Async{ref: ref}} = response) do
      deadline = System.monotonic_time(:millisecond) + @timeout_ms
      drain(response, ref, deadline, [], 0)
    end

    defp drain(response, ref, deadline, chunks, seen_bytes) do
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, _part} = message ->
          case Req.parse_message(response, message) do
            {:ok, parts} when is_list(parts) ->
              drain_parts(response, ref, deadline, parts, chunks, seen_bytes)

            {:error, _reason} ->
              cancel(response)
              ""

            :unknown ->
              cancel(response)
              raise "unexpected Req async rejection message"

            _other ->
              cancel(response)
              raise "unexpected Req async rejection message"
          end
      after
        timeout ->
          cancel(response)
          ""
      end
    end

    defp drain_parts(response, ref, deadline, [], chunks, seen_bytes) do
      drain(response, ref, deadline, chunks, seen_bytes)
    end

    defp drain_parts(response, ref, deadline, [{:data, data} | parts], chunks, seen_bytes)
         when is_binary(data) do
      next_seen_bytes = seen_bytes + byte_size(data)

      if next_seen_bytes > @max_bytes do
        cancel(response)
        ""
      else
        drain_parts(response, ref, deadline, parts, [data | chunks], next_seen_bytes)
      end
    end

    defp drain_parts(
           response,
           ref,
           deadline,
           [{:trailers, _trailers} | parts],
           chunks,
           seen_bytes
         ) do
      drain_parts(response, ref, deadline, parts, chunks, seen_bytes)
    end

    defp drain_parts(_response, _ref, _deadline, [:done | _parts], chunks, _seen_bytes) do
      chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end

    defp drain_parts(response, _ref, _deadline, [_part | _parts], _chunks, _seen_bytes) do
      cancel(response)
      raise "unexpected Req async rejection message"
    end

    defp cancel(response) do
      Req.cancel_async_response(response)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  alias __MODULE__.RejectionDrain
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
    headers = maybe_put_routing_hint_header(headers, Keyword.get(opts, :routing_hint))

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
          [{name, maybe_project_turn_metadata_header(name, value)}]
        else
          []
        end

      _other ->
        []
    end)
  end

  defp maybe_project_turn_metadata_header("x-codex-turn-metadata", value) do
    case Jason.decode(value) do
      {:ok, %{"code_mode_tool_names" => _value} = metadata} ->
        encode_projected_turn_metadata(metadata, value)

      _other ->
        value
    end
  end

  defp maybe_project_turn_metadata_header(_name, value), do: value

  defp encode_projected_turn_metadata(metadata, original) do
    case metadata
         |> Map.delete("code_mode_tool_names")
         |> Jason.encode(escape: :unicode_safe) do
      {:ok, projected} -> projected
      {:error, _error} -> original
    end
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
    result = maybe_drain_rejection_body(result, opts)

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
        routing_hint_authorized?: routing_hint_authorized?,
        request_options: %RequestOptions{} = opts
      }) do
    timeouts = configured_timeouts(opts)

    upstream_header_list =
      CloudflareCookies.request_headers(
        url,
        regular_runtime_headers(
          identity,
          token,
          opts,
          [
            {"content-type", "application/json"},
            {"accept",
             if(streaming_request?(payload, opts),
               do: "text/event-stream",
               else: "application/json"
             )}
          ],
          routing_hint: routing_hint_header(body, routing_hint_authorized?, opts)
        )
      )

    emit_egress_observation(:http, upstream_header_list, opts, :none)

    request_options =
      [
        body: body,
        decode_body: false,
        retry: false,
        headers: upstream_header_list
      ]
      |> Keyword.merge(TransportEnvelope.req_timeout_options(timeouts))

    request_options =
      if streaming_request?(payload, opts) do
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
    result = maybe_drain_rejection_body(result, opts)

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
        routing_hint_authorized?: routing_hint_authorized?,
        accounting_request: request,
        accounting_attempt: attempt,
        writer: writer,
        assignment_advertised?: assignment_advertised?,
        native_codex_response_control: native_codex_response_control,
        request_options: %RequestOptions{} = request_options
      }) do
    headers =
      websocket_headers(
        identity,
        token,
        routing_hint_header(payload_body, routing_hint_authorized?, request_options)
      )

    emit_egress_observation(:websocket, headers, request_options, payload_body)

    timeouts = request_options.timeout_config
    observation = task14_observation_context(request, attempt, request_options)

    request_data = %{
      url: url,
      headers: headers,
      payload: payload_body,
      timeouts: timeouts,
      mapper: websocket_message_mapper(request_options),
      identity: identity,
      observation: observation,
      reset_probe: request_options.routing.reset_probe,
      native_codex_response_control: native_codex_response_control,
      assignment_advertised?: assignment_advertised? == true,
      connection_bound_continuation?: connection_bound_continuation?(request_options),
      forward_error_body?: false
    }

    case owner_transport(request_options) do
      {:ok, session, owner_lease_token, downstream, forwarder_opts} ->
        request_data
        |> owner_websocket_request(request_options)
        |> submit_owner_websocket_request(
          session,
          owner_lease_token,
          downstream,
          owner_request_forwarder_opts(forwarder_opts, request_options),
          request_options
        )
        |> owner_request_result(identity, request, request_options)

      :local ->
        request_data
        |> direct_websocket_request_data(writer, request_options)
        |> direct_websocket_request(request_options, identity, request)

      {:error, reason} ->
        owner_request_result({:error, reason}, identity, request, request_options)
    end
  end

  @egress_observation_flag :task10_egress_observation_enabled
  @egress_observation_event [:codex_pooler, :gateway, :upstream, :egress_observation]

  # Metadata-only egress observation for the dev-runtime Task 10 observer.
  # Emits upstream header *names* and websocket `client_metadata` *keys* only —
  # never values, payloads, tokens, or frames — and only while the dev observer
  # has armed the flag; production emits nothing. Observation must never affect
  # dispatch, so every failure path collapses to :ok.
  defp emit_egress_observation(transport, headers, %RequestOptions{} = opts, payload) do
    if Application.get_env(:codex_pooler, @egress_observation_flag, false) do
      :telemetry.execute(@egress_observation_event, %{count: 1}, %{
        transport: transport,
        client_request_id: egress_client_request_id(opts),
        header_names: Enum.map(headers, fn {name, _value} -> to_string(name) end),
        websocket_client_metadata: egress_websocket_client_metadata(payload)
      })
    end

    :ok
  rescue
    _error -> :ok
  end

  defp egress_client_request_id(%RequestOptions{
         request_metadata: %{client_request_id: client_request_id}
       }),
       do: client_request_id

  defp egress_client_request_id(%RequestOptions{}), do: nil

  defp egress_websocket_client_metadata(:none), do: :none

  defp egress_websocket_client_metadata(payload) do
    case Jason.decode(IO.iodata_to_binary(payload)) do
      {:ok, %{"client_metadata" => client_metadata}} when is_map(client_metadata) ->
        {:keys, Map.keys(client_metadata)}

      {:ok, _decoded} ->
        {:keys, []}

      {:error, _reason} ->
        :unparseable
    end
  end

  defp websocket_message_mapper(%RequestOptions{
         openai_compatibility: %{public_openai_responses_stream: true}
       }),
       do: :public_openai_responses

  defp websocket_message_mapper(%RequestOptions{
         openai_compatibility: %{
           source_endpoint: nil,
           public_openai_responses_stream: false
         }
       }),
       do: :native_codex_responses

  defp websocket_message_mapper(%RequestOptions{}), do: :codex_responses

  defp connection_bound_continuation?(%RequestOptions{
         continuity: %{upstream_previous_response_id?: true},
         transport: %{transport: "websocket"},
         openai_compatibility: %{
           source_endpoint: nil,
           public_openai_responses_stream: false
         }
       }),
       do: true

  defp connection_bound_continuation?(%RequestOptions{}), do: false

  defp owner_request_forwarder_opts(forwarder_opts, %RequestOptions{} = request_options) do
    derived_timeout =
      max(
        request_options.timeout_config.receive_timeout_ms + 1_000,
        OperationalSettings.current().websocket_idle_timeout_ms + 1_000
      )

    request_timeout = Keyword.get(forwarder_opts, :request_timeout, derived_timeout)

    forwarder_opts
    |> Keyword.delete(:request_timeout)
    |> Keyword.put(:timeout, request_timeout)
  end

  @spec direct_websocket_request_data(
          websocket_request_data(),
          UpstreamWebsocketSession.Request.writer(),
          RequestOptions.t()
        ) :: UpstreamWebsocketSession.Request.t()
  defp direct_websocket_request_data(request_data, writer, request_options) do
    {:ok, message_mapper} = WebsocketRequestCallbacks.mapper(request_data.mapper)

    struct!(
      UpstreamWebsocketSession.Request,
      request_data
      |> Map.drop([:mapper, :identity, :observation])
      |> Map.merge(%{
        writer: WebsocketRequestCallbacks.observing_writer(writer, request_data.observation),
        message_mapper: message_mapper,
        frame_observer:
          WebsocketRequestCallbacks.frame_observer(
            request_data.identity,
            request_data.observation
          ),
        submission_observer: request_options.transport.websocket_owner_submission_observer
      })
    )
  end

  @spec owner_websocket_request(websocket_request_data(), RequestOptions.t()) ::
          {:ok, WebsocketOwnerRequest.t()} | {:error, WebsocketOwnerRequest.validation_error()}
  defp owner_websocket_request(request_data, request_options) do
    case request_data.identity.id do
      upstream_identity_id when is_binary(upstream_identity_id) ->
        WebsocketOwnerRequest.new(%{
          version: 1,
          url: request_data.url,
          headers: request_data.headers,
          payload: request_data.payload,
          timeouts: request_data.timeouts,
          mapper: request_data.mapper,
          upstream_identity_id: upstream_identity_id,
          observation: request_data.observation,
          reset_probe: request_data.reset_probe,
          native_codex_response_control: request_data.native_codex_response_control,
          assignment_advertised?: request_data.assignment_advertised?,
          connection_bound_continuation?: request_data.connection_bound_continuation?,
          forward_error_body?: request_data.forward_error_body?,
          submission_notification?:
            is_function(request_options.transport.websocket_owner_submission_observer, 0)
        })

      _invalid_identity ->
        {:error, {:invalid_field, :upstream_identity_id}}
    end
  end

  defp submit_owner_websocket_request(
         {:ok, owner_request},
         session,
         owner_lease_token,
         downstream,
         forwarder_opts,
         request_options
       ) do
    WebsocketOwnerForwarder.submit_request(
      session,
      owner_lease_token,
      downstream,
      owner_request,
      forwarder_opts
    )
    |> observe_owner_request_submission(request_options)
  end

  defp submit_owner_websocket_request(
         {:error, _validation_error},
         _session,
         _owner_lease_token,
         _downstream,
         _forwarder_opts,
         _request_options
       ),
       do: {:error, :owner_unavailable}

  defp direct_websocket_request(upstream_request, request_options, identity, request) do
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

  defp owner_request_result(:ok, identity, request, _request_options) do
    {:ok, %{body: "", terminal: "response.completed", status: 200, headers: []}}
    |> record_upstream_websocket_body(identity, request)
  end

  # An owner success reply crosses a node boundary, so validate the producer's
  # contract before any consumer destructures or combines its values. A bad
  # shape settles as one normal owner-crash failure without logging the reply.
  defp owner_request_result({:ok, result}, identity, request, request_options) do
    case owner_reply_problem(result) do
      :ok ->
        record_upstream_websocket_body({:ok, result}, identity, request)

      problem ->
        contain_malformed_owner_reply(problem, request_options)
    end
  end

  defp owner_request_result(
         {:error, %{body: _body, reason: _reason} = response},
         _identity,
         _request,
         _request_options
       ) do
    {:error, response}
  end

  defp owner_request_result({:error, reason}, _identity, _request, _request_options) do
    {:error, %{body: "", reason: reason, headers: [], started: false}}
  end

  defp observe_owner_request_submission(
         {:websocket_owner_submission_accepted, result},
         %RequestOptions{transport: %{websocket_owner_submission_observer: observer}}
       )
       when is_function(observer, 0) do
    observe_owner_request_submission(observer)
    result
  end

  defp observe_owner_request_submission(
         {:websocket_owner_submission_accepted, result},
         %RequestOptions{}
       ),
       do: result

  defp observe_owner_request_submission(result, %RequestOptions{}), do: result

  defp observe_owner_request_submission(observer) do
    observer.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp contain_malformed_owner_reply(problem, request_options) do
    {reply_shape, detail} = owner_reply_log_detail(problem)

    Logger.warning(
      "websocket owner reply malformed boundary=submit " <>
        "reply_shape=#{reply_shape} " <>
        "#{detail} " <>
        "canonical_error=owner_crashed " <>
        "request_id=#{DiagnosticTaxonomy.safe_correlator(owner_request_id(request_options))}"
    )

    {:error, %{body: "", reason: :owner_crashed, headers: [], started: false}}
  end

  defp owner_reply_problem(reply) when is_map(reply) do
    case Enum.reject(@owner_success_fields, &Map.has_key?(reply, &1)) do
      [] ->
        case owner_reply_invalid_fields(reply) do
          [] -> :ok
          invalid -> {:invalid, invalid}
        end

      missing ->
        {:missing, missing}
    end
  end

  defp owner_reply_problem(_reply), do: :not_a_map

  defp owner_reply_invalid_fields(reply) do
    [
      {:body, not is_binary(reply.body)},
      {:terminal, not clean_binary?(reply.terminal)},
      {:status, reply.status != 200},
      {:headers, not owner_response_headers?(reply.headers)},
      {:response_id, invalid_optional_owner_field?(reply, :response_id, &clean_binary?/1)},
      {:upstream_websocket_connection,
       invalid_optional_owner_field?(reply, :upstream_websocket_connection, &is_map/1)},
      {:websocket_frame_headers,
       invalid_optional_owner_field?(reply, :websocket_frame_headers, &is_map/1)},
      {:upstream_error_code,
       invalid_optional_owner_field?(reply, :upstream_error_code, &nil_or_clean_binary?/1)},
      {:upstream_error_param,
       invalid_optional_owner_field?(reply, :upstream_error_param, &nil_or_clean_binary?/1)},
      {:transport_failure, invalid_optional_owner_field?(reply, :transport_failure, &is_map/1)}
    ]
    |> Enum.flat_map(fn
      {field, true} -> [Atom.to_string(field)]
      {_field, false} -> []
    end)
  end

  defp invalid_optional_owner_field?(reply, field, valid?) do
    case Map.fetch(reply, field) do
      {:ok, value} -> not valid?.(value)
      :error -> false
    end
  end

  defp owner_response_headers?(headers) when is_list(headers) do
    Enum.all?(headers, fn
      {name, value} -> is_binary(name) and is_binary(value)
      _header -> false
    end)
  end

  defp owner_response_headers?(_headers), do: false

  defp nil_or_clean_binary?(nil), do: true
  defp nil_or_clean_binary?(value), do: clean_binary?(value)

  # `reply_shape` is the classification both containment boundaries emit, so one
  # query finds them; field names carry safe detail without exposing values.
  defp owner_reply_log_detail(:not_a_map), do: {"not_a_map", "missing=not_a_map"}

  defp owner_reply_log_detail({:missing, fields}),
    do: {"map_missing_fields", "missing=#{Enum.join(fields, ",")}"}

  defp owner_reply_log_detail({:invalid, fields}),
    do: {"map_invalid_fields", "invalid=#{Enum.join(fields, ",")}"}

  # The correlator is the upgrade request id the websocket lifecycle and owner
  # diagnostics emit under this key, so the containment warning joins those
  # lines instead of sharing a key name with a different id space. This runs
  # inside the containment warning, which must not raise; a fallback clause is
  # not the way to guarantee that here, because the caller's type makes one
  # unreachable and the Dialyzer gate rejects it. Totality rests on convention
  # rather than on the type: `websocket_request/1` requires a `%RequestOptions{}`
  # and every constructor fills `:request_metadata` with a `%RequestMetadata{}`
  # (`@enforce_keys` requires the key, not a non-nil value). Keep it that way.
  defp owner_request_id(%RequestOptions{request_metadata: %{request_id: request_id}}),
    do: request_id

  defp record_upstream_websocket_body(result, identity, request)

  defp record_upstream_websocket_body(
         {:error,
          %{
            body: _body,
            reason: {:websocket_upgrade_failed, _status, headers}
          }} = result,
         identity,
         request
       ) do
    RateLimitObserver.record_websocket_upgrade_headers(identity, headers)
    mark_visible_output(request, result)
    result
  end

  defp record_upstream_websocket_body(
         {:ok, %{body: _body, websocket_frame_headers: frame_headers}} = result,
         identity,
         request
       ) do
    RateLimitObserver.record_websocket_frame_headers(identity, frame_headers)
    mark_visible_output(request, result)
    result
  end

  defp record_upstream_websocket_body({:ok, %{body: _body}} = result, _identity, request) do
    mark_visible_output(request, result)
    result
  end

  defp record_upstream_websocket_body(
         {:error, %{body: _body, websocket_frame_headers: frame_headers}} = result,
         identity,
         request
       ) do
    RateLimitObserver.record_websocket_frame_headers(identity, frame_headers)
    mark_visible_output(request, result)
    result
  end

  defp record_upstream_websocket_body({:error, %{body: _body}} = result, _identity, request) do
    mark_visible_output(request, result)
    result
  end

  defp task14_observation_context(request, attempt, %RequestOptions{} = request_options) do
    %{
      request_id: task14_request_id(request, request_options),
      client_request_id: request_options.request_metadata.client_request_id,
      attempt_id: if(is_map(attempt), do: Map.get(attempt, :id)),
      mode: RequestOptions.model_serving_mode(request_options)
    }
  end

  defp task14_request_id(%{id: id}, _request_options) when is_binary(id), do: id

  defp task14_request_id(_request, %RequestOptions{} = request_options),
    do: request_options.request_metadata.request_id

  defp websocket_headers(identity, token, routing_hint) do
    upstream_headers(
      identity,
      token,
      maybe_put_routing_hint_header(
        [{"openai-beta", "responses_websockets=2026-02-06"}],
        routing_hint
      )
    )
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

  defp maybe_drain_rejection_body(
         {:ok,
          %Req.Response{
            status: status,
            body: %Req.Response.Async{}
          } = response},
         %RequestOptions{} = request_options
       )
       when status in 400..499 and status != 429 do
    body = RejectionDrain.drain(response)

    response =
      response
      |> RejectionBody.put(body)
      |> maybe_put_misalignment_policy_violation(status, body, request_options)

    {:ok, response}
  end

  defp maybe_drain_rejection_body(result, %RequestOptions{}), do: result

  defp maybe_put_misalignment_policy_violation(response, status, body, request_options) do
    case MisalignmentPolicyViolation.classify_http(status, body, request_options) do
      {:ok, summary} -> MisalignmentPolicyViolation.put_summary(response, summary)
      :no_match -> response
    end
  end

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

  defp mark_visible_output(request, {status, %{body: body} = result})
       when status in [:ok, :error] and is_binary(body) and body != "" do
    if downstream_output_visible?(status, result, body) do
      PersistenceSessionContinuity.mark_codex_turn_visible(request)
    end
  end

  defp mark_visible_output(_request, _result), do: :ok

  defp downstream_output_visible?(
         :error,
         %{transport_failure: %{pre_visible_output: true}},
         _body
       ),
       do: false

  defp downstream_output_visible?(_status, _result, body),
    do: not StreamProtocol.internal_control_event?(body)

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

  defp maybe_put_routing_hint_header(headers, routing_hint) when is_list(headers) do
    headers =
      Enum.reject(headers, fn
        {name, _value} when is_binary(name) -> String.downcase(name) == @routing_hint_header_name
        _header -> false
      end)

    case routing_hint do
      value when is_binary(value) -> [{@routing_hint_header_name, value} | headers]
      _other -> headers
    end
  end

  defp routing_hint_header(
         body,
         true,
         %RequestOptions{
           transport: %{upstream_endpoint: endpoint},
           openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
         }
       )
       when endpoint in @regular_runtime_metadata_endpoints and is_binary(body) do
    with {:ok, %{} = payload} <- Jason.decode(body),
         {:ok, model} <- routing_hint_component(Map.get(payload, "model")),
         {:ok, service_tier} <- routing_hint_service_tier(payload) do
      case service_tier do
        nil -> "model=#{model}"
        tier -> "model=#{model};tier=#{tier}"
      end
    else
      _other -> nil
    end
  end

  defp routing_hint_header(_body, _routing_hint_authorized?, %RequestOptions{}), do: nil

  defp routing_hint_service_tier(payload) do
    case Map.fetch(payload, "service_tier") do
      :error -> {:ok, nil}
      {:ok, tier} -> routing_hint_component(tier)
    end
  end

  defp routing_hint_component(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..128 and
         Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, value) do
      {:ok, value}
    else
      :error
    end
  end

  defp routing_hint_component(_value), do: :error

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

  defp streaming_request?(payload, %RequestOptions{} = request_options) do
    RouteClass.streaming?(payload) or CompactionTrigger.streaming_result?(request_options)
  end
end
