defmodule CodexPooler.Gateway.Runtime.Finalization.Metadata do
  @moduledoc false

  alias CodexPooler.Accounting.Metadata, as: AccountingMetadata
  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Transports.BoundedResponseBody
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl
  alias CodexPooler.Gateway.Transports.RejectionBody
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Quotas.Evidence.CodexParsers.RateLimitReachedType

  @canonical_uuid_byte_size 36
  @rejection_body_max_bytes 65_536
  @rejection_token_max_bytes 80
  @rejection_token_pattern ~r/\A[A-Za-z0-9_.-]+\z/
  @rejection_detail_classes %{"Stream must be set to true" => "stream_must_be_true"}
  @unsupported_parameter_detail_prefix "Unsupported parameter: "
  @unsupported_parameter_code "unsupported_parameter"
  @invalid_request_error_type "invalid_request_error"
  @previous_response_not_found_code "previous_response_not_found"
  @rejection_param_max_bytes 160
  @rejection_param_pattern ~r/\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]{0,3})\])*\z/
  @upstream_websocket_connection_atom_keys [
    :lifecycle_id,
    :generation,
    :reused,
    :reconnected
  ]
  @upstream_websocket_connection_string_keys ~w(
    lifecycle_id
    generation
    reused
    reconnected
  )
  @backend_turn_state_relay_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/responses/compact"
  ]
  @ordinary_responses_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses",
    "/backend-api/codex/v1/chat/completions",
    "/v1/responses",
    "/v1/chat/completions"
  ]
  @compact_responses_endpoints [
    "/backend-api/codex/responses/compact",
    "/backend-api/codex/v1/responses/compact"
  ]

  @public_openai_responses_stream_keys ~w(
    schema_version
    mode
    created_seen
    visible_seen
    delta_count
    delta_bytes
    text_done_count
    text_done_bytes
    item_done_count
    terminal_seen
    terminal_kind
    terminal_status
    finish_class
    synthetic_terminal_sent
    source_chunk_count
    stream_bytes
    relay_bytes
    passthrough_seen
  )

  @typep raw_upstream_websocket_connection_fields :: {term(), term(), term(), term()}
  @typep upstream_websocket_connection_metadata :: %{
           required(String.t()) => Ecto.UUID.t() | pos_integer() | boolean()
         }
  @typep upstream_websocket_connection_attempt_metadata :: %{
           optional(String.t()) => upstream_websocket_connection_metadata()
         }

  @spec response_metadata(Req.Response.t(), String.t() | nil, RequestOptions.t() | map()) ::
          map()
  def response_metadata(response, error_kind, opts) do
    metadata =
      %{
        "content_type" => bounded_content_type(header(response, "content-type")),
        "status_code" => response.status,
        "rate_limit_reached_type" => RateLimitReachedType.parse_header(response.headers),
        "upstream_request_id" => upstream_request_id(response)
      }
      |> compact_metadata()

    metadata = if error_kind, do: Map.put(metadata, "error_kind", error_kind), else: metadata
    metadata = Map.merge(metadata, response_body_limit_metadata(response))
    metadata = Map.merge(metadata, rejection_metadata(response))

    metadata =
      Map.merge(metadata, upstream_websocket_connection_attempt_metadata(Req.Response.get_private(response, :upstream_websocket_connection)))

    opts
    |> route_attempt_metadata()
    |> Map.merge(gateway_debug_attempt_metadata(opts))
    |> Map.merge(payload_compression_attempt_metadata(opts))
    |> Map.merge(reasoning_effort_attempt_metadata(opts))
    |> Map.merge(RequestOptions.prompt_cache_controls_attempt_metadata(opts))
    |> Map.merge(upstream_websocket_bridge_attempt_metadata(opts))
    |> Map.merge(metadata)
  end

  @doc """
  Classifies a terminal upstream status for accounting and request logs.

  Serving mode is deliberately absent. A non-429 4xx under an explicit Full
  override used to be classified `full_upstream_rejection` instead of
  `upstream_status`, which made the same provider rejection carry two codes
  depending on a Pool setting (codex-pooler-findings#173): an operator
  filtering request logs on `full_upstream_rejection` silently missed every
  non-Full provider rejection, because nothing in that name says it is
  mode-scoped.

  It was narrower still: `explicit_full_ordinary_responses?/1` also gates on
  `ordinary_responses_route?/1`, so a Full-override rejection on the compact
  route never earned the code either. Over 30 days on the icoretech
  installation the code covered 62 of 496 non-429 4xx failures; the 434 it
  missed were Full-mode compact rejections, not Lite ones.

  The code encoded no fact of its own. `explicit_full_ordinary_responses?/1`
  is true exactly when the serving-mode snapshot is
  `{configured: "full", effective: "full", source: "override"}`, which
  `RequestOptions.Routing.put_model_serving_mode/2` validates at set time and
  `Accounting.Metadata` accepts verbatim, so whenever the code fired the
  request and attempt already carried `model_serving_mode`,
  `model_serving_mode_configured` and `model_serving_mode_source` under
  `routing`. That is where mode belongs and where the request-log drawer
  already reads it, independently of this code.

  What operators actually query for — "the provider refused this request" — is
  `upstream_status` plus a 4xx `upstream_status_code`, which is persisted on
  the request, the attempt and the request-log fact. Recovering the old,
  mode-scoped set costs one more clause on `routing` and is now explicit about
  being mode-scoped.
  """
  @spec upstream_status_error_code(integer(), RequestOptions.t() | term()) :: String.t()
  def upstream_status_error_code(429, %RequestOptions{}), do: "upstream_rate_limited"

  def upstream_status_error_code(_status, _request_options), do: "upstream_status"

  @doc """
  True for a refusal that says the provider cannot resolve the request's
  `previous_response_id` on this connection: the Codex backend's codeless
  `invalid_request_error` whose message is exactly
  `Invalid \`previous_response_id\`.` (a websocket connection that did not
  produce the response, a fresh one included; findings#232 row 232-277, live
  probe 2026-09-23, and the same refusal `UpstreamWebsocketSession` answers
  locally for a fresh connection), or an explicit `previous_response_not_found`
  code. Only that fixed text is compared; no provider text is kept.
  """
  @spec previous_response_miss?(Req.Response.t()) :: boolean()
  def previous_response_miss?(%Req.Response{} = response) do
    with body when is_binary(body) and byte_size(body) <= @rejection_body_max_bytes <- rejection_body(response),
         {:ok, %{"error" => %{"type" => @invalid_request_error_type} = error}} <- CodexPooler.JSON.decode(body) do
      previous_response_miss_error?(error)
    else
      _other -> false
    end
  end

  defp previous_response_miss_error?(%{"code" => @previous_response_not_found_code}), do: true

  defp previous_response_miss_error?(%{"message" => message} = error) when is_binary(message),
    do: message == ErrorCodes.invalid_previous_response_id_message() and is_nil(Map.get(error, "code"))

  defp previous_response_miss_error?(_error), do: false

  defp rejection_message_class(message) when is_binary(message) do
    if message == ErrorCodes.invalid_previous_response_id_message(), do: "invalid_previous_response_id"
  end

  defp rejection_message_class(_message), do: nil

  @spec rejection_error(Req.Response.t()) :: map()
  def rejection_error(%Req.Response{} = response) do
    response
    |> rejection_body()
    |> decode_rejection_error()
  end

  defp upstream_websocket_bridge_attempt_metadata(%RequestOptions{
         transport: %{upstream_websocket_bridge?: true}
       }) do
    %{"upstream_transport" => "websocket", "upstream_websocket_bridge" => true}
  end

  defp upstream_websocket_bridge_attempt_metadata(_opts), do: %{}

  @doc """
  True for the statuses whose sanitized rejection code/type/param are recorded
  as attempt metadata.

  Callers that relay those bounded facts back to the client must gate on the
  same predicate, so the relayed window can never drift away from the
  persisted one.
  """
  @spec rejection_metadata_status?(term()) :: boolean()
  def rejection_metadata_status?(status) when is_integer(status),
    do: status in 400..499 and status != 429

  def rejection_metadata_status?(_status), do: false

  @doc """
  The sanitized rejection facts (`rejection_error_code`/`type`/`param`, message
  presence and size, or a `{"detail": ...}` class) of a refused response, empty
  outside `rejection_metadata_status?/1`. The websocket finalizer feeds it the
  provider's wrapped error frame as the equivalent HTTP response, so both
  transports record the same fields (findings#254 row 254-15).
  """
  @spec rejection_metadata(Req.Response.t()) :: map()
  def rejection_metadata(%Req.Response{status: status} = response) do
    if rejection_metadata_status?(status) do
      response
      |> rejection_body()
      |> decode_rejection_metadata()
    else
      %{}
    end
  end

  @spec rejection_body(Req.Response.t()) :: binary()
  def rejection_body(%Req.Response{} = response) do
    case RejectionBody.fetch(response) do
      body when is_binary(body) -> body
      _absent -> response_body(response)
    end
  end

  defp decode_rejection_metadata(body)
       when is_binary(body) and byte_size(body) <= @rejection_body_max_bytes do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => error}} when is_map(error) ->
        %{}
        |> maybe_put_rejection_value("rejection_error_code", valid_rejection_token(error["code"]))
        |> maybe_put_rejection_value("rejection_error_type", valid_rejection_token(error["type"]))
        |> maybe_put_rejection_value(
          "rejection_error_param",
          valid_rejection_param(error["param"])
        )
        |> put_rejection_message_metadata(error["message"])
        |> maybe_put_rejection_value("rejection_message_class", rejection_message_class(error["message"]))

      {:ok, %{"detail" => detail}} ->
        detail_rejection_metadata(detail)

      _other ->
        %{}
    end
  end

  defp decode_rejection_metadata(_body), do: %{}

  # `{"detail": ...}` rejection bodies carry free provider text that may echo
  # request content. Only a fixed class, an identifier-shaped value, or a
  # 12-character fingerprint is recorded, next to the bounded message size.
  defp detail_rejection_metadata(detail) when is_binary(detail) do
    metadata =
      case unsupported_parameter_detail(detail) do
        {:ok, param} -> %{"rejection_detail_class" => @unsupported_parameter_code, "rejection_error_param" => param}
        :error -> %{"rejection_detail_class" => rejection_detail_class(detail)}
      end

    put_rejection_message_metadata(metadata, detail)
  end

  defp detail_rejection_metadata(_detail) do
    put_rejection_message_metadata(%{"rejection_detail_class" => "non_string_detail"}, nil)
  end

  defp rejection_detail_class(""), do: "empty_detail"

  defp rejection_detail_class(detail) do
    case Map.fetch(@rejection_detail_classes, detail) do
      {:ok, class} -> class
      :error -> DiagnosticTaxonomy.identifier(detail)
    end
  end

  defp decode_rejection_error(body)
       when is_binary(body) and byte_size(body) <= @rejection_body_max_bytes do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => error}} when is_map(error) ->
        %{}
        |> maybe_put_rejection_value(:code, valid_rejection_token(error["code"]))
        |> maybe_put_rejection_value(:type, valid_rejection_token(error["type"]))
        |> maybe_put_rejection_value(:param, valid_rejection_param(error["param"]))

      {:ok, %{"detail" => detail}} when is_binary(detail) ->
        case unsupported_parameter_detail(detail) do
          {:ok, param} -> %{code: @unsupported_parameter_code, type: @invalid_request_error_type, param: param}
          :error -> %{}
        end

      _other ->
        %{}
    end
  end

  defp decode_rejection_error(_body), do: %{}

  # The ChatGPT Codex backend answers a top-level parameter it does not accept
  # on HTTP with `400 {"detail": "Unsupported parameter: <name>"}` instead of
  # an `"error"` object: every HTTP request anchored on `previous_response_id`
  # gets it, because the backend resolves that anchor only on the websocket
  # connection that produced the response (findings#232 row 232-275). The text
  # is the OpenAI `unsupported_parameter` message, so a detail that is exactly
  # that prefix and a bounded field path is read as that code and param. Only
  # the field path is taken from the provider text; any other detail keeps the
  # fixed-class or fingerprint projection and relays nothing.
  defp unsupported_parameter_detail(@unsupported_parameter_detail_prefix <> param) do
    case valid_rejection_param(param) do
      nil -> :error
      param -> {:ok, param}
    end
  end

  defp unsupported_parameter_detail(_detail), do: :error

  defp maybe_put_rejection_value(metadata, _key, nil), do: metadata
  defp maybe_put_rejection_value(metadata, key, value), do: Map.put(metadata, key, value)

  defp valid_rejection_token(value) when is_binary(value) do
    if byte_size(value) in 1..@rejection_token_max_bytes and
         Regex.match?(@rejection_token_pattern, value),
       do: value,
       else: nil
  end

  defp valid_rejection_token(_value), do: nil

  defp valid_rejection_param(value) when is_binary(value) do
    if byte_size(value) in 1..@rejection_param_max_bytes and
         Regex.match?(@rejection_param_pattern, value),
       do: value,
       else: nil
  end

  defp valid_rejection_param(_value), do: nil

  defp put_rejection_message_metadata(metadata, message)
       when is_binary(message) and message != "" do
    metadata
    |> Map.put("rejection_message_present", true)
    |> Map.put("rejection_message_bytes", min(byte_size(message), 1_024))
  end

  defp put_rejection_message_metadata(metadata, _message) do
    metadata
    |> Map.put("rejection_message_present", false)
    |> Map.put("rejection_message_bytes", 0)
  end

  @spec explicit_full_ordinary_responses?(RequestOptions.t() | term()) :: boolean()
  def explicit_full_ordinary_responses?(%RequestOptions{} = request_options) do
    RequestOptions.model_serving_mode_snapshot(request_options) == %{
      configured_mode: "full",
      effective_mode: "full",
      source: "override"
    } and ordinary_responses_route?(request_options)
  end

  def explicit_full_ordinary_responses?(_request_options), do: false

  @spec ordinary_responses_route?(RequestOptions.t() | term()) :: boolean()
  def ordinary_responses_route?(%RequestOptions{} = request_options) do
    ordinary_responses_endpoint?(request_options) and
      not request_options.payload_context.compaction_trigger_bridge?
  end

  def ordinary_responses_route?(_request_options), do: false

  defp ordinary_responses_endpoint?(%RequestOptions{} = request_options) do
    upstream_endpoint = request_options.transport.upstream_endpoint

    source_endpoint =
      request_options.openai_compatibility.source_endpoint ||
        upstream_endpoint

    upstream_endpoint not in @compact_responses_endpoints and
      source_endpoint in @ordinary_responses_endpoints
  end

  @spec response_body_limit_exceeded?(Req.Response.t()) :: boolean()
  def response_body_limit_exceeded?(%Req.Response{} = response),
    do: BoundedResponseBody.exceeded?(response)

  @spec response_body_limit_metadata(Req.Response.t()) :: map()
  def response_body_limit_metadata(%Req.Response{} = response),
    do: BoundedResponseBody.metadata(response)

  @spec websocket_response_metadata(list(), String.t() | nil, RequestOptions.t() | map()) :: map()
  @spec websocket_response_metadata(
          list(),
          String.t() | nil,
          RequestOptions.t() | map(),
          map()
        ) :: map()
  @spec websocket_response_metadata(
          list(),
          String.t() | nil,
          RequestOptions.t() | map(),
          map(),
          term()
        ) :: map()
  def websocket_response_metadata(headers, error_kind, opts, websocket_frame_headers \\ %{}) do
    metadata =
      %{
        "content_type" => "application/json",
        "status_code" => 200,
        "upstream_request_id" => upstream_request_id(headers),
        "rate_limit_reached_type" => RateLimitReachedType.parse_header(headers),
        "upstream_transport" => "websocket"
      }
      |> compact_metadata()

    metadata = if error_kind, do: Map.put(metadata, "error_kind", error_kind), else: metadata

    opts
    |> route_attempt_metadata()
    |> Map.merge(gateway_debug_attempt_metadata(opts))
    |> Map.merge(payload_compression_attempt_metadata(opts))
    |> Map.merge(reasoning_effort_attempt_metadata(opts))
    |> Map.merge(RequestOptions.prompt_cache_controls_attempt_metadata(opts))
    |> Map.merge(metadata)
    |> maybe_put_websocket_frame_headers(websocket_frame_headers)
  end

  def websocket_response_metadata(
        headers,
        error_kind,
        opts,
        websocket_frame_headers,
        upstream_websocket_connection
      ) do
    headers
    |> websocket_response_metadata(error_kind, opts, websocket_frame_headers)
    |> Map.drop(["upstream_websocket_connection", :upstream_websocket_connection])
    |> Map.merge(upstream_websocket_connection_attempt_metadata(upstream_websocket_connection))
  end

  @spec upstream_websocket_connection_attempt_metadata(term()) ::
          upstream_websocket_connection_attempt_metadata()
  def upstream_websocket_connection_attempt_metadata(connection) when is_map(connection) do
    with {:ok, {lifecycle_id, generation, reused, reconnected}} <-
           upstream_websocket_connection_fields(connection),
         {:ok, lifecycle_id} <- canonical_uuid(lifecycle_id),
         true <- is_integer(generation) and generation > 0,
         true <- is_boolean(reused),
         true <- is_boolean(reconnected) do
      %{
        "upstream_websocket_connection" => %{
          "lifecycle_id" => lifecycle_id,
          "generation" => generation,
          "reused" => reused,
          "reconnected" => reconnected
        }
      }
    else
      _invalid -> %{}
    end
  end

  def upstream_websocket_connection_attempt_metadata(_connection), do: %{}

  @spec request_metadata(RequestOptions.t() | map() | term()) :: map()
  def request_metadata(opts), do: RequestOptions.payload_compression_request_metadata(opts)

  @spec first_event_stream_metadata(Req.Response.t(), map(), String.t(), RequestOptions.t()) ::
          map()
  def first_event_stream_metadata(response, failure, error_kind, opts) do
    response
    |> response_metadata(error_kind, opts)
    |> maybe_put_masked_error_metadata(failure.upstream_code, failure.code)
    |> maybe_put_upstream_error_param(failure)
    |> Map.put("stream_failure_stage", "first_event")
    |> Map.put("stream_terminal_type", failure.event_type)
    |> Map.put("stream_error_code", failure.code)
    |> maybe_put_quota_rejection_proof(failure)
  end

  defp maybe_put_quota_rejection_proof(metadata, %{quota_rejection_before_output?: true}),
    do: Map.put(metadata, "quota_rejection_before_output", true)

  defp maybe_put_quota_rejection_proof(metadata, _failure), do: metadata

  @spec merge_stream_state_metadata(map(), term()) :: map()
  def merge_stream_state_metadata(metadata, state) when is_map(metadata) do
    metadata
    |> Map.merge(public_openai_responses_stream_metadata(state))
    |> Map.merge(DownstreamStream.native_http_progress_metadata(state))
    |> Map.merge(DownstreamStream.native_http_tool_metadata(state))
  end

  def merge_stream_state_metadata(metadata, _state), do: metadata

  @spec maybe_put_masked_error_metadata(map(), String.t() | nil, String.t()) :: map()
  def maybe_put_masked_error_metadata(metadata, upstream_code, code)
      when is_binary(upstream_code) and upstream_code != code do
    metadata
    |> Map.put("upstream_error_code", upstream_code)
    |> Map.put("masked_error_code", code)
  end

  def maybe_put_masked_error_metadata(metadata, _upstream_code, _code), do: metadata

  @spec maybe_put_upstream_error_param(map(), term()) :: map()
  def maybe_put_upstream_error_param(metadata, %{upstream_error_param: value}) do
    case UpstreamErrorParam.sanitize(value) do
      sanitized when is_binary(sanitized) -> Map.put(metadata, "upstream_error_param", sanitized)
      nil -> metadata
    end
  end

  def maybe_put_upstream_error_param(metadata, _failure), do: metadata

  @spec route_attempt_metadata(RequestOptions.t() | map() | term()) :: map()
  def route_attempt_metadata(%RequestOptions{} = request_options),
    do: request_options.routing.routing_attempt_metadata || %{}

  def route_attempt_metadata(%{routing_attempt_metadata: metadata}), do: metadata
  def route_attempt_metadata(_opts), do: %{}

  @spec response_body(Req.Response.t()) :: binary()
  def response_body(%Req.Response{body: body}) when is_binary(body), do: body
  def response_body(%Req.Response{body: nil}), do: ""
  def response_body(%Req.Response{}), do: ""

  @spec response_headers(Req.Response.t(), boolean()) :: [{String.t(), String.t()}]
  @spec response_headers(Req.Response.t(), boolean(), RequestOptions.t() | nil) ::
          [{String.t(), String.t()}]
  def response_headers(response, streaming?, request_options \\ nil) do
    content_type =
      header(response, "content-type") ||
        if(streaming?, do: "text/event-stream", else: "application/json")

    headers = [{"content-type", content_type}]

    headers =
      headers
      |> maybe_put_backend_turn_state_response_header(response, request_options)
      |> maybe_put_native_response_control_headers(response, request_options)

    if streaming?, do: [{"cache-control", "no-cache"} | headers], else: headers
  end

  @spec json_content?(Req.Response.t()) :: boolean()
  def json_content?(response), do: (header(response, "content-type") || "") =~ "application/json"

  @spec safe_reason(term()) :: String.t()
  def safe_reason({:chunk, :closed}), do: "client disconnected while writing downstream stream"
  def safe_reason({:chunk, reason}), do: "downstream chunk failed: #{reason_class(reason)}"
  def safe_reason({:upstream_idle_timeout, _reason}), do: "upstream stream idle timeout"
  def safe_reason(:upstream_websocket_receive_timeout), do: "upstream stream idle timeout"

  def safe_reason({:terminal_stream_failure, %{code: code}}) when is_binary(code),
    do: "upstream stream returned terminal event #{safe_code(code)}"

  def safe_reason(%{code: code}), do: "gateway_error: #{safe_code(code)}"
  def safe_reason(reason), do: reason_class(reason)

  defp reason_class(%module{}) when is_atom(module), do: inspect(module)
  defp reason_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(reason) when is_binary(reason), do: safe_code(reason)
  defp reason_class(_reason), do: "non_atom_reason"

  defp safe_code(code) do
    code
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 80)
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  @spec upstream_failure_message(String.t()) :: String.t()
  def upstream_failure_message("/backend-api/codex/responses/compact"),
    do: "upstream compact request failed"

  def upstream_failure_message(_endpoint), do: "upstream request failed"

  defp gateway_debug_attempt_metadata(%RequestOptions{} = request_options) do
    DebugPayloadSummary.attempt_metadata(request_options)
  end

  defp gateway_debug_attempt_metadata(opts), do: DebugPayloadSummary.attempt_metadata(opts)

  defp payload_compression_attempt_metadata(opts) do
    RequestOptions.payload_compression_attempt_metadata(opts)
  end

  defp reasoning_effort_attempt_metadata(opts) do
    RequestOptions.reasoning_effort_attempt_metadata(opts)
  end

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp canonical_uuid(value)
       when is_binary(value) and byte_size(value) == @canonical_uuid_byte_size do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> :error
    end
  end

  defp canonical_uuid(_value), do: :error

  @spec upstream_websocket_connection_fields(map()) ::
          {:ok, raw_upstream_websocket_connection_fields()} | :error
  defp upstream_websocket_connection_fields(connection) do
    string_fields = Map.take(connection, @upstream_websocket_connection_string_keys)
    atom_fields = Map.take(connection, @upstream_websocket_connection_atom_keys)

    case {string_fields, atom_fields} do
      {%{
         "lifecycle_id" => lifecycle_id,
         "generation" => generation,
         "reused" => reused,
         "reconnected" => reconnected
       }, atom_fields}
      when map_size(atom_fields) == 0 ->
        {:ok, {lifecycle_id, generation, reused, reconnected}}

      {string_fields,
       %{
         lifecycle_id: lifecycle_id,
         generation: generation,
         reused: reused,
         reconnected: reconnected
       }}
      when map_size(string_fields) == 0 ->
        {:ok, {lifecycle_id, generation, reused, reconnected}}

      _fields ->
        :error
    end
  end

  # Frame-carried header values are persisted under the request-id bound:
  # every allowlisted name carries an id, a marker, a number or a timestamp,
  # all within `[A-Za-z0-9_.:-]`. The allowlist admits wildcard quota names,
  # so the persisted map is also capped at @max_persisted_frame_headers
  # entries, kept by sorted name so the persisted subset is deterministic;
  # the cap fits the request id, the reached-type marker, the six
  # x-ratelimit names, the account window pair and two per-model window
  # sets. Quota evidence reads the in-memory map, never this copy, so no
  # window is lost by bounding here (findings#238).
  @max_persisted_frame_headers 32

  defp maybe_put_websocket_frame_headers(metadata, headers) when map_size(headers) > 0 do
    case bounded_frame_headers(headers) do
      bounded when map_size(bounded) > 0 -> Map.put(metadata, "websocket_frame_headers", bounded)
      _blank -> metadata
    end
  end

  defp maybe_put_websocket_frame_headers(metadata, _headers), do: metadata

  defp bounded_frame_headers(headers) do
    headers
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.take(@max_persisted_frame_headers)
    |> Enum.flat_map(fn {name, value} ->
      case bounded_request_id(value) do
        nil -> []
        bounded -> [{name, bounded}]
      end
    end)
    |> Map.new()
  end

  defp public_openai_responses_stream_metadata(state) do
    stream_metadata =
      case DownstreamStream.public_openai_responses_stream_metadata(state) do
        %{"public_openai_responses_stream" => summary} when is_map(summary) ->
          %{
            "public_openai_responses_stream" => Map.take(summary, @public_openai_responses_stream_keys)
          }

        _metadata ->
          %{}
      end

    Map.merge(stream_metadata, DownstreamStream.bridge_commitment_metadata(state))
  end

  @spec maybe_put_backend_turn_state_response_header(
          [{String.t(), String.t()}],
          Req.Response.t(),
          RequestOptions.t() | nil
        ) :: [{String.t(), String.t()}]
  defp maybe_put_backend_turn_state_response_header(
         headers,
         response,
         %RequestOptions{
           transport: %{upstream_endpoint: endpoint},
           openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
         }
       )
       when endpoint in @backend_turn_state_relay_endpoints do
    case header(response, "x-codex-turn-state") do
      value when is_binary(value) -> [{"x-codex-turn-state", value} | headers]
      _value -> headers
    end
  end

  defp maybe_put_backend_turn_state_response_header(headers, _response, _request_options),
    do: headers

  defp maybe_put_native_response_control_headers(
         headers,
         response,
         %RequestOptions{
           transport: %{
             transport: transport,
             upstream_endpoint: "/backend-api/codex/responses",
             websocket_writer: nil
           },
           openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
         }
       )
       when transport in ["http_json", "http_sse"] do
    NativeCodexResponseControl.http_headers(Req.Response.to_map(response).headers) ++ headers
  end

  defp maybe_put_native_response_control_headers(headers, _response, _request_options),
    do: headers

  # The Codex backend names its server-assigned request id `x-oai-request-id`
  # (observed directly against the provider); `x-request-id` and
  # `openai-request-id` are the names other OpenAI surfaces use. The names and
  # their order live in `StreamProtocol.upstream_request_id_header_names/0`
  # (`x-request-id` first, like the released Codex client), which is also the
  # websocket error-frame allowlist, so the id the Pooler stores is the one a
  # user reads in their Codex log when both are present. Reading only the last
  # two names had left every attempt without a provider id. A blank value is
  # absent; a value outside the request-id bound is fingerprinted, never
  # erased, so a non-identifier first choice still wins over a later name.
  defp upstream_request_id(response_or_headers) do
    Enum.find_value(StreamProtocol.upstream_request_id_header_names(), fn name ->
      response_or_headers
      |> header(name)
      |> bounded_request_id()
    end)
  end

  # A provider request id is an opaque UUID-like token (`req_…` prefixes, hex
  # UUIDs, `.`/`:`-joined segments); 128 bytes is generous for every observed
  # shape and small enough that a body-sized header cannot land in jsonb
  # (findings#238).
  @request_id_pattern ~r/\A[A-Za-z0-9_.:-]+\z/
  @request_id_max_bytes 128

  defp bounded_request_id(value),
    do: AccountingMetadata.bounded_string(value, @request_id_pattern, @request_id_max_bytes)

  # A media type is `type/subtype` followed by `;`-separated parameters such
  # as `charset=utf-8` (RFC 7231 token characters plus the space after `;`);
  # 120 bytes covers every real content type with its parameters, and a
  # quoted parameter value or anything longer is fingerprinted (findings#238).
  @content_type_pattern ~r/\A[A-Za-z0-9!#$&^_.+\/;= -]+\z/
  @content_type_max_bytes 120

  defp bounded_content_type(value),
    do: AccountingMetadata.bounded_string(value, @content_type_pattern, @content_type_max_bytes)

  defp header(%Req.Response{headers: headers}, key) do
    headers
    |> Enum.find_value(fn {name, values} ->
      if String.downcase(name) == key, do: List.first(values)
    end)
  end

  defp header(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == key, do: to_string(value)
    end)
  end
end
