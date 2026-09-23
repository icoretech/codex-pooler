defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCanonicalization do
  @moduledoc false

  alias CodexPooler.Gateway.ErrorClassification
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.EventSummary
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser

  @synthetic_public_openai_responses_failure_message "upstream request failed: stream interrupted before terminal response event"
  @native_previous_response_not_found_message "Previous response was not found. Retrying the full request."
  @provider_previous_response_refusal_status 400

  @type event_summary :: EventSummary.t()

  @spec synthetic_public_openai_responses_failure_message() :: String.t()
  def synthetic_public_openai_responses_failure_message,
    do: @synthetic_public_openai_responses_failure_message

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
    {wire, _changed} = normalize_decoded_block(block, separator, event_type, decoded, false)
    wire
  end

  @spec normalize_private_native_misalignment_block(binary(), binary()) :: iodata()
  def normalize_private_native_misalignment_block(block, separator \\ "\n\n") do
    {event_type, decoded} = SSEParser.stream_block_event(block)
    {wire, _changed} = normalize_decoded_block(block, separator, event_type, decoded, true)
    wire
  end

  @doc false
  @spec normalize_decoded_block(binary(), binary(), String.t() | nil, map(), boolean()) ::
          {iodata(), map() | nil}
  def normalize_decoded_block(block, separator, event_type, decoded, private_details?) do
    misalignment = if private_details?, do: private_native_misalignment(event_type, decoded)

    cond do
      not is_nil(misalignment) ->
        event = private_native_misalignment_event(decoded, misalignment)
        {encode_error_event_sse(event), event}

      codex_responses_error_needs_canonical_response?(event_type, decoded) ->
        event = canonical_codex_responses_error_event(decoded)
        {encode_error_event_sse(event), event}

      true ->
        {[block, separator], nil}
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

  # D6 hazard 1: Wire code "server_error" belongs to the health-neutral and
  # retryable classifier sets. Current consumers use accounting/dispatch reason
  # values instead of rereading emitted bytes, so there is no behavior test;
  # keep that distinction explicit if a future consumer reads this frame.
  @spec synthetic_public_openai_responses_error_sse(term(), non_neg_integer()) :: binary()
  def synthetic_public_openai_responses_error_sse(_reason, sequence_number)
      when is_integer(sequence_number) and sequence_number >= 0 do
    error = %{
      "type" => "server_error",
      "code" => "server_error",
      "message" => @synthetic_public_openai_responses_failure_message,
      "param" => nil
    }

    event = %{
      "type" => "error",
      "sequence_number" => sequence_number,
      "code" => "server_error",
      "message" => @synthetic_public_openai_responses_failure_message,
      "param" => nil,
      "error" => error
    }

    [
      "event: error\n",
      "data: ",
      CodexPooler.JSON.encode!(event),
      "\n\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec canonicalize_codex_responses_json_message(binary()) :: binary()
  def canonicalize_codex_responses_json_message(data) when is_binary(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} ->
        {canonical, _decoded} = canonicalize_codex_responses_json_message(data, decoded)
        canonical

      _other ->
        data
    end
  end

  @spec canonicalize_codex_responses_json_message(binary(), map()) :: {binary(), map()}
  def canonicalize_codex_responses_json_message(data, decoded)
      when is_binary(data) and is_map(decoded) do
    canonicalize_codex_responses_json_decoded_message(decoded, data)
  end

  @spec canonicalize_native_codex_responses_json_message(binary()) :: binary()
  def canonicalize_native_codex_responses_json_message(data) when is_binary(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok,
       %{
         "type" => "error",
         "error" => %{"code" => "previous_response_not_found"}
       }} ->
        CodexPooler.JSON.encode!(native_previous_response_not_found_event())

      {:ok, %{} = decoded} ->
        if provider_previous_response_refusal?(decoded),
          do: CodexPooler.JSON.encode!(provider_previous_response_miss_event()),
          else: canonicalize_codex_responses_json_message(data)

      _other ->
        canonicalize_codex_responses_json_message(data)
    end
  end

  @spec canonicalize_native_codex_responses_json_message(binary(), map()) :: {binary(), map()}
  def canonicalize_native_codex_responses_json_message(data, decoded)
      when is_binary(data) and is_map(decoded) do
    case decoded do
      %{
        "type" => "error",
        "error" => %{"code" => "previous_response_not_found"}
      } ->
        canonical = native_previous_response_not_found_event()
        {CodexPooler.JSON.encode!(canonical), canonical}

      _other ->
        if provider_previous_response_refusal?(decoded) do
          canonical = provider_previous_response_miss_event()
          {CodexPooler.JSON.encode!(canonical), canonical}
        else
          canonicalize_codex_responses_json_message(data, decoded)
        end
    end
  end

  # The Codex backend refuses an anchor the websocket connection cannot resolve
  # (a connection that did not produce the response) with a codeless wrapped
  # 400 whose message is exactly `ErrorCodes.invalid_previous_response_id_message/0`
  # (findings#232 row 232-277, live probe 2026-09-23). It is given the
  # `previous_response_not_found` code the Pooler's own connection-bound guard
  # sends (row 232-278): the refusal's meaning, the released client's
  # designated signal to resend the full request (rust-v0.156.1
  # `responses_websocket.rs`) and the stale-chain code other native clients
  # recover on. Before, it became the canonical `response.failed`
  # `stream_incomplete`, a generic retryable stream error. The provider's fixed
  # message is kept on this first pass, which the upstream websocket session
  # applies and the attempt settles on, so the attempt records the provider's
  # message class and not a code the provider never sent
  # (`Finalization.Websocket.provider_rejection_metadata/2`). The native socket
  # applies this canonicalization again to every frame it pushes, where the
  # coded frame becomes the guard's own retry event.
  defp provider_previous_response_refusal?(%{"type" => "error", "error" => %{"type" => "invalid_request_error", "message" => message} = error} = decoded) do
    message == ErrorCodes.invalid_previous_response_id_message() and is_nil(Map.get(error, "code")) and
      Map.get(decoded, "status") == @provider_previous_response_refusal_status
  end

  defp provider_previous_response_refusal?(_decoded), do: false

  defp provider_previous_response_miss_event do
    %{
      "type" => "error",
      "status" => @provider_previous_response_refusal_status,
      "error" => %{
        "type" => "invalid_request_error",
        "code" => "previous_response_not_found",
        "message" => ErrorCodes.invalid_previous_response_id_message()
      }
    }
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

  defp codex_responses_error_needs_canonical_response?("error", decoded),
    do: not is_nil(ErrorCodes.sse_error_code(decoded))

  defp codex_responses_error_needs_canonical_response?("response.failed", decoded) do
    upstream_code = ErrorCodes.upstream_error_code(decoded)

    upstream_code == MisalignmentPolicyViolation.code() or
      (is_nil(ErrorCodes.nested_string(decoded, ["response", "error", "code"])) and
         not is_nil(ErrorCodes.sse_error_code(decoded)))
  end

  defp codex_responses_error_needs_canonical_response?("response.incomplete", decoded),
    do: failed_incomplete_decoded?(decoded)

  defp codex_responses_error_needs_canonical_response?(_event_type, _decoded), do: false

  defp failed_incomplete_decoded?(decoded) do
    "response.incomplete"
    |> EventSummary.build(decoded)
    |> EventSummary.incomplete_failure?()
  end

  defp canonicalize_codex_responses_json_decoded_message(decoded, data) do
    cond do
      EventSummary.typeless_detail_error?(decoded) ->
        canonical = EventSummary.canonical_typeless_detail_error_event()
        {CodexPooler.JSON.encode!(canonical), canonical}

      codex_responses_error_needs_canonical_response?(
        ErrorCodes.decoded_string(decoded, "type"),
        decoded
      ) ->
        canonical = canonical_codex_responses_error_event(decoded)
        {CodexPooler.JSON.encode!(canonical), canonical}

      true ->
        {data, decoded}
    end
  end

  # findings#191: a Codex Pooler-authored envelope that named its own type could
  # not follow the classification either surface applies, so it is derived from
  # the same status this event already declares.
  @native_previous_response_not_found_status 400

  defp native_previous_response_not_found_event do
    %{
      "type" => "error",
      "status" => @native_previous_response_not_found_status,
      "error" => %{
        "type" =>
          ErrorClassification.error_type(
            "previous_response_not_found",
            @native_previous_response_not_found_status
          ),
        "code" => "previous_response_not_found",
        "message" => @native_previous_response_not_found_message
      }
    }
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
    error =
      decoded
      |> canonical_codex_responses_error_source()
      |> Kernel.||(%{})
      |> Map.delete("misalignment")

    upstream_code = ErrorCodes.upstream_error_code(decoded)
    code = ErrorCodes.client_visible_error_code(upstream_code) || "upstream_terminal_failure"
    message = canonical_codex_responses_error_message(decoded, code, upstream_code)

    error = Map.put(error, "code", code)

    cond do
      upstream_code == MisalignmentPolicyViolation.code() ->
        Map.put(
          error,
          "message",
          error |> Map.get("message") |> MisalignmentPolicyViolation.normalize_message()
        )

      ErrorCodes.previous_response_miss_code?(upstream_code) ->
        Map.put(error, "message", message)

      true ->
        Map.put_new(error, "message", message)
    end
  end

  defp private_native_misalignment("response.failed", %{
         "response" => %{
           "status" => "failed",
           "error" => %{"code" => code} = error
         }
       }) do
    if code == MisalignmentPolicyViolation.code() do
      MisalignmentPolicyViolation.normalize_details(Map.get(error, "misalignment"))
    end
  end

  defp private_native_misalignment(_event_type, _decoded), do: nil

  defp private_native_misalignment_event(decoded, misalignment) do
    event = canonical_codex_responses_error_event(decoded)
    error = Map.put(event["response"]["error"], "misalignment", misalignment)

    event
    |> Map.put("error", error)
    |> put_in(["response", "error"], error)
  end

  defp encode_error_event_sse(event) do
    ["event: response.failed\n", "data: ", CodexPooler.JSON.encode!(event), "\n\n"]
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
