defmodule CodexPooler.Gateway.Runtime.Finalization.Metadata do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Transports.BoundedResponseBody
  alias CodexPooler.Quotas.Evidence.CodexParsers.RateLimitReachedType

  @canonical_uuid_byte_size 36
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
        "content_type" => header(response, "content-type"),
        "status_code" => response.status,
        "rate_limit_reached_type" => RateLimitReachedType.parse_header(response.headers),
        "upstream_request_id" =>
          header(response, "x-request-id") || header(response, "openai-request-id")
      }
      |> compact_metadata()

    metadata = if error_kind, do: Map.put(metadata, "error_kind", error_kind), else: metadata
    metadata = Map.merge(metadata, response_body_limit_metadata(response))

    opts
    |> route_attempt_metadata()
    |> Map.merge(gateway_debug_attempt_metadata(opts))
    |> Map.merge(payload_compression_attempt_metadata(opts))
    |> Map.merge(reasoning_effort_attempt_metadata(opts))
    |> Map.merge(upstream_websocket_bridge_attempt_metadata(opts))
    |> Map.merge(metadata)
  end

  @spec upstream_status_error_code(integer(), RequestOptions.t() | term()) :: String.t()
  def upstream_status_error_code(429, %RequestOptions{}), do: "upstream_rate_limited"

  def upstream_status_error_code(status, %RequestOptions{} = request_options)
      when status >= 400 and status <= 499 do
    if explicit_full_ordinary_responses?(request_options) do
      "full_upstream_rejection"
    else
      "upstream_status"
    end
  end

  def upstream_status_error_code(_status, _request_options), do: "upstream_status"

  defp upstream_websocket_bridge_attempt_metadata(%RequestOptions{
         transport: %{upstream_websocket_bridge?: true}
       }) do
    %{"upstream_transport" => "websocket", "upstream_websocket_bridge" => true}
  end

  defp upstream_websocket_bridge_attempt_metadata(_opts), do: %{}

  @spec explicit_full_ordinary_responses?(RequestOptions.t() | term()) :: boolean()
  def explicit_full_ordinary_responses?(%RequestOptions{} = request_options) do
    RequestOptions.model_serving_mode_snapshot(request_options) == %{
      configured_mode: "full",
      effective_mode: "full",
      source: "override"
    } and ordinary_responses_endpoint?(request_options)
  end

  def explicit_full_ordinary_responses?(_request_options), do: false

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
        "upstream_request_id" =>
          header(headers, "x-request-id") || header(headers, "openai-request-id"),
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
  end

  @spec merge_stream_state_metadata(map(), term()) :: map()
  def merge_stream_state_metadata(metadata, state) when is_map(metadata) do
    Map.merge(metadata, public_openai_responses_stream_metadata(state))
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
  def maybe_put_upstream_error_param(metadata, %{upstream_error_param: value})
      when is_binary(value) and value != "" do
    Map.put(metadata, "upstream_error_param", value)
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

    headers = maybe_put_backend_turn_state_response_header(headers, response, request_options)

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

  defp maybe_put_websocket_frame_headers(metadata, headers) when map_size(headers) > 0 do
    Map.put(metadata, "websocket_frame_headers", headers)
  end

  defp maybe_put_websocket_frame_headers(metadata, _headers), do: metadata

  defp public_openai_responses_stream_metadata(state) do
    stream_metadata =
      case DownstreamStream.public_openai_responses_stream_metadata(state) do
        %{"public_openai_responses_stream" => summary} when is_map(summary) ->
          %{
            "public_openai_responses_stream" =>
              Map.take(summary, @public_openai_responses_stream_keys)
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
