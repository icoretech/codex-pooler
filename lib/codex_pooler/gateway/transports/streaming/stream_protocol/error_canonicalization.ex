defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCanonicalization do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.EventSummary
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser

  @synthetic_public_openai_responses_failure_code "upstream_stream_error"
  @synthetic_public_openai_responses_failure_message "upstream request failed: stream interrupted before terminal response event"

  @type event_summary :: EventSummary.t()

  @spec normalize_data(binary()) :: binary()
  def normalize_data(data) do
    case SSEParser.complete_sse_blocks(data, bounded?: false) do
      {[], _buffer} ->
        normalize_block(data, "")

      {blocks, buffer} ->
        [Enum.map(blocks, &normalize_block/1), buffer]
    end
    |> IO.iodata_to_binary()
  end

  @spec normalize_block(binary(), binary()) :: iodata()
  def normalize_block(block, separator \\ "\n\n") do
    {event_type, decoded} = SSEParser.stream_block_event(block)

    if codex_responses_error_needs_canonical_response?(event_type, decoded) do
      encode_codex_responses_error_sse(decoded)
    else
      [block, separator]
    end
  end

  @spec normalize_terminal_event(String.t() | nil, map()) :: {String.t() | nil, map()}
  def normalize_terminal_event(event_type, decoded) when is_map(decoded) do
    if event_type == "response.incomplete" and failed_incomplete_decoded?(decoded) do
      {"response.failed", canonical_codex_responses_error_event(decoded)}
    else
      {event_type, decoded}
    end
  end

  @spec synthetic_public_openai_responses_failure_sse(String.t() | nil, term()) :: binary()
  def synthetic_public_openai_responses_failure_sse(response_id, _reason) do
    error = %{
      "code" => @synthetic_public_openai_responses_failure_code,
      "message" => @synthetic_public_openai_responses_failure_message
    }

    response =
      %{"status" => "failed", "error" => error}
      |> put_synthetic_response_id(response_id)

    [
      "event: response.failed\n",
      "data: ",
      Jason.encode!(%{
        "type" => "response.failed",
        "error" => error,
        "response" => response
      }),
      "\n\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec canonicalize_codex_responses_json_message(binary()) :: binary()
  def canonicalize_codex_responses_json_message(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        canonicalize_codex_responses_json_decoded_message(decoded, data)

      _other ->
        data
    end
  end

  @spec terminal_error_code(binary(), String.t() | nil) :: String.t()
  defdelegate terminal_error_code(body, terminal), to: ErrorCodes

  @spec client_visible_error_code(String.t() | nil) :: String.t() | nil
  defdelegate client_visible_error_code(code), to: ErrorCodes

  @spec upstream_error_code(map()) :: String.t() | nil
  defdelegate upstream_error_code(decoded), to: ErrorCodes

  @spec error_code_from_nested_error(map()) :: String.t() | nil
  defdelegate error_code_from_nested_error(error), to: ErrorCodes

  @spec event_summary_from_block(binary()) :: event_summary()
  defdelegate event_summary_from_block(block), to: EventSummary, as: :from_block

  @spec event_summary(String.t() | nil, map()) :: event_summary()
  defdelegate event_summary(event_type, decoded), to: EventSummary, as: :build

  @spec incomplete_sse_or_direct_stream_event_summary(binary()) ::
          {:ok, event_summary()} | :incomplete
  defdelegate incomplete_sse_or_direct_stream_event_summary(data),
    to: EventSummary,
    as: :incomplete_sse_or_direct

  @spec retryable_first_event_code?(String.t() | nil) :: boolean()
  defdelegate retryable_first_event_code?(code), to: ErrorCodes

  @spec websocket_auth_refresh_event_code?(String.t() | nil) :: boolean()
  defdelegate websocket_auth_refresh_event_code?(code), to: ErrorCodes

  @spec previous_response_miss_code?(String.t() | nil) :: boolean()
  defdelegate previous_response_miss_code?(code), to: ErrorCodes

  @spec incomplete_failure_event?(map()) :: boolean()
  defdelegate incomplete_failure_event?(event), to: EventSummary, as: :incomplete_failure?

  @spec decoded_string(map(), String.t()) :: String.t() | nil
  defdelegate decoded_string(decoded, key), to: ErrorCodes

  @spec nested_string(map(), [String.t()]) :: String.t() | nil
  defdelegate nested_string(map, keys), to: ErrorCodes

  defp put_synthetic_response_id(response, response_id) when is_binary(response_id) do
    response_id = String.trim(response_id)

    if response_id == "" do
      response
    else
      Map.put(response, "id", response_id)
    end
  end

  defp put_synthetic_response_id(response, _response_id), do: response

  defp codex_responses_error_needs_canonical_response?("error", decoded),
    do: not is_nil(ErrorCodes.sse_error_code(decoded))

  defp codex_responses_error_needs_canonical_response?("response.failed", decoded) do
    is_nil(ErrorCodes.nested_string(decoded, ["response", "error", "code"])) and
      not is_nil(ErrorCodes.sse_error_code(decoded))
  end

  defp codex_responses_error_needs_canonical_response?("response.incomplete", decoded),
    do: failed_incomplete_decoded?(decoded)

  defp codex_responses_error_needs_canonical_response?(_event_type, _decoded), do: false

  defp failed_incomplete_decoded?(decoded) do
    "response.incomplete"
    |> EventSummary.build(decoded)
    |> EventSummary.incomplete_failure?()
  end

  defp encode_codex_responses_error_sse(decoded) do
    [
      "event: response.failed\n",
      "data: ",
      Jason.encode!(canonical_codex_responses_error_event(decoded)),
      "\n\n"
    ]
  end

  defp canonicalize_codex_responses_json_decoded_message(decoded, data) do
    cond do
      EventSummary.typeless_detail_error?(decoded) ->
        Jason.encode!(EventSummary.canonical_typeless_detail_error_event())

      codex_responses_error_needs_canonical_response?(
        ErrorCodes.decoded_string(decoded, "type"),
        decoded
      ) ->
        Jason.encode!(canonical_codex_responses_error_event(decoded))

      true ->
        data
    end
  end

  defp canonical_codex_responses_error_event(decoded) do
    error = canonical_codex_responses_error(decoded)
    response = canonical_codex_responses_error_response(decoded, error)

    decoded
    |> Map.drop(["headers"])
    |> Map.put("type", "response.failed")
    |> Map.put("error", error)
    |> Map.put("response", response)
  end

  defp canonical_codex_responses_error(decoded) do
    error = canonical_codex_responses_error_source(decoded) || %{}

    upstream_code = ErrorCodes.upstream_error_code(decoded)
    code = ErrorCodes.client_visible_error_code(upstream_code) || "upstream_terminal_failure"
    message = canonical_codex_responses_error_message(decoded, code, upstream_code)

    error = Map.put(error, "code", code)

    if ErrorCodes.previous_response_miss_code?(upstream_code) do
      Map.put(error, "message", message)
    else
      Map.put_new(error, "message", message)
    end
  end

  defp canonical_codex_responses_error_response(decoded, error) do
    response =
      case get_in(decoded, ["response"]) do
        %{} = response -> response
        _value -> %{}
      end

    response
    |> Map.put("error", error)
    |> Map.put("status", "failed")
  end

  defp canonical_codex_responses_error_message(_decoded, _code, upstream_code)
       when upstream_code in ["previous_response_not_found", "invalid_previous_response_id"],
       do: "upstream stream incomplete"

  defp canonical_codex_responses_error_message(decoded, code, _upstream_code) do
    ErrorCodes.nested_string(decoded, ["response", "error", "message"]) ||
      ErrorCodes.nested_string(decoded, ["error", "message"]) ||
      ErrorCodes.nested_string(decoded, ["response", "status_details", "error", "message"]) ||
      ErrorCodes.nested_string(decoded, ["status_details", "error", "message"]) ||
      ErrorCodes.nested_string(decoded, ["message"]) ||
      "upstream stream returned terminal event #{code}"
  end

  defp canonical_codex_responses_error_source(decoded) do
    [
      get_in(decoded, ["response", "error"]),
      get_in(decoded, ["error"]),
      get_in(decoded, ["response", "status_details", "error"]),
      get_in(decoded, ["status_details", "error"]),
      ErrorCodes.wrapped_top_level_error(decoded)
    ]
    |> Enum.find(&is_map/1)
  end
end
