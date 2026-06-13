defmodule CodexPooler.Gateway.Runtime.Finalization.Metadata do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Quotas.Evidence.CodexParsers.RateLimitReachedType

  @backend_turn_state_relay_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/responses/compact"
  ]

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

    opts
    |> route_attempt_metadata()
    |> Map.merge(gateway_debug_attempt_metadata(opts))
    |> Map.merge(metadata)
  end

  @spec websocket_response_metadata(list(), String.t() | nil, RequestOptions.t() | map(), map()) ::
          map()
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
    |> Map.merge(metadata)
    |> maybe_put_websocket_frame_headers(websocket_frame_headers)
  end

  @spec first_event_stream_metadata(Req.Response.t(), map(), String.t(), RequestOptions.t()) ::
          map()
  def first_event_stream_metadata(response, failure, error_kind, opts) do
    response
    |> response_metadata(error_kind, opts)
    |> maybe_put_masked_error_metadata(failure.upstream_code, failure.code)
    |> Map.put("stream_failure_stage", "first_event")
    |> Map.put("stream_terminal_type", failure.event_type)
    |> Map.put("stream_error_code", failure.code)
  end

  @spec maybe_put_masked_error_metadata(map(), String.t() | nil, String.t()) :: map()
  def maybe_put_masked_error_metadata(metadata, upstream_code, code)
      when is_binary(upstream_code) and upstream_code != code do
    metadata
    |> Map.put("upstream_error_code", upstream_code)
    |> Map.put("masked_error_code", code)
  end

  def maybe_put_masked_error_metadata(metadata, _upstream_code, _code), do: metadata

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

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_websocket_frame_headers(metadata, headers) when map_size(headers) > 0 do
    Map.put(metadata, "websocket_frame_headers", headers)
  end

  defp maybe_put_websocket_frame_headers(metadata, _headers), do: metadata

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
