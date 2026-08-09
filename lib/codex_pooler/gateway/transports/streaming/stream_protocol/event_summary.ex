defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.EventSummary do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam

  @incomplete_failure_reason_codes [
    "upstream_request_timeout",
    "stream_incomplete",
    "server_error",
    "overloaded_error",
    "server_is_overloaded",
    "websocket_connection_limit_reached",
    "invalid_api_key",
    "invalid_authentication",
    "context_length_exceeded",
    "insufficient_quota",
    "invalid_previous_response_id",
    "invalid_request",
    "invalid_request_error",
    "previous_response_not_found",
    "rate_limit_exceeded",
    "unauthorized",
    "usage_limit_exceeded",
    "usage_limit_reached",
    "workspace_member_credits_depleted",
    "workspace_member_usage_limit_reached",
    "workspace_owner_credits_depleted",
    "workspace_owner_usage_limit_reached"
  ]

  @type t :: %{
          required(:event_type) => String.t() | nil,
          required(:error_code) => String.t() | nil,
          required(:upstream_error_code) => String.t() | nil,
          required(:upstream_error_param) => UpstreamErrorParam.t(),
          required(:data_type) => String.t() | nil,
          required(:explicit_error?) => boolean(),
          required(:incomplete_reason) => String.t() | nil
        }

  @spec from_block(binary()) :: t()
  def from_block(block) do
    {event_type, decoded} = SSEParser.stream_block_event(block)
    build(event_type, decoded)
  end

  @spec build(String.t() | nil, map()) :: t()
  def build(event_type, decoded) do
    %{
      event_type: event_type,
      error_code: ErrorCodes.sse_error_code(decoded),
      upstream_error_code: ErrorCodes.upstream_error_code(decoded),
      upstream_error_param: UpstreamErrorParam.extract(decoded),
      data_type: ErrorCodes.decoded_string(decoded, "type"),
      explicit_error?: explicit_terminal_error?(decoded),
      incomplete_reason: incomplete_reason(decoded)
    }
  end

  @spec incomplete_sse_or_direct(binary()) :: {:ok, t()} | :incomplete
  def incomplete_sse_or_direct(data) do
    case from_block(data) do
      %{event_type: event_type} = event when is_binary(event_type) -> {:ok, event}
      _event -> direct_stream_event_summary(data)
    end
  end

  @spec incomplete_failure?(map()) :: boolean()
  def incomplete_failure?(event) do
    Map.get(event, :explicit_error?) == true or
      incomplete_failure_reason?(Map.get(event, :incomplete_reason)) or
      incomplete_failure_reason?(Map.get(event, :upstream_error_code))
  end

  @spec typeless_detail_error?(map()) :: boolean()
  def typeless_detail_error?(%{"detail" => _detail} = decoded) do
    is_nil(ErrorCodes.decoded_string(decoded, "type")) and not Map.has_key?(decoded, "error") and
      not Map.has_key?(decoded, "response")
  end

  def typeless_detail_error?(_decoded), do: false

  @spec canonical_typeless_detail_error_event() :: map()
  def canonical_typeless_detail_error_event do
    error = %{
      "code" => "upstream_terminal_failure",
      "message" => "upstream websocket returned terminal detail"
    }

    %{
      "type" => "response.failed",
      "error" => error,
      "response" => %{"status" => "failed", "error" => error}
    }
  end

  defp direct_stream_event_summary(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        decoded =
          if typeless_detail_error?(decoded),
            do: canonical_typeless_detail_error_event(),
            else: decoded

        {:ok, build(ErrorCodes.decoded_string(decoded, "type"), decoded)}

      _other ->
        :incomplete
    end
  end

  defp explicit_terminal_error?(decoded) when is_map(decoded) do
    is_map(get_in(decoded, ["response", "error"])) or is_map(get_in(decoded, ["error"])) or
      is_map(get_in(decoded, ["response", "status_details", "error"])) or
      is_map(get_in(decoded, ["status_details", "error"])) or typeless_detail_error?(decoded)
  end

  defp incomplete_reason(decoded) when is_map(decoded) do
    ErrorCodes.nested_string(decoded, ["response", "incomplete_details", "reason"]) ||
      ErrorCodes.nested_string(decoded, ["incomplete_details", "reason"])
  end

  defp incomplete_failure_reason?(reason) when reason in @incomplete_failure_reason_codes,
    do: true

  defp incomplete_failure_reason?(_reason), do: false
end
