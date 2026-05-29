defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol do
  @moduledoc """
  Pure helpers for Codex Responses SSE parsing and stream event classification.
  """

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses

  @terminal_event_types ["response.failed", "response.incomplete", "error"]
  @downstream_visible_event_types @terminal_event_types ++
                                    ["response.created", "response.in_progress"]
  @retryable_first_event_codes [
    "upstream_request_timeout",
    "stream_incomplete",
    "server_error",
    "overloaded_error",
    "websocket_connection_limit_reached"
  ]
  @websocket_auth_refresh_event_codes ["invalid_api_key", "invalid_authentication"]
  @metadata_header_names ~w(openai-request-id x-openai-request-id x-request-id)
  @quota_header_prefixes ~w(x-ratelimit-limit- x-ratelimit-remaining- x-ratelimit-reset-)
  @quota_window_header_suffixes ~w(
    -primary-reset-at
    -primary-used-percent
    -primary-window-minutes
    -secondary-reset-at
    -secondary-used-percent
    -secondary-window-minutes
  )

  @type terminal_failure :: %{
          required(:code) => String.t(),
          optional(:upstream_code) => String.t() | nil,
          optional(:event_type) => String.t() | nil,
          optional(:data_type) => String.t() | nil
        }
  @type public_openai_responses_stream_state :: %{
          required(:buffer) => binary(),
          required(:created?) => boolean(),
          required(:text_delta?) => boolean()
        }
  @type websocket_frame_headers :: %{optional(String.t()) => String.t()}

  @spec public_openai_responses_stream_state() :: public_openai_responses_stream_state()
  def public_openai_responses_stream_state do
    PublicResponses.new_state()
  end

  @spec normalize_codex_responses_sse_data(binary()) :: binary()
  def normalize_codex_responses_sse_data(data) do
    case complete_sse_blocks(data, bounded?: false) do
      {[], _buffer} ->
        normalize_codex_responses_sse_block(data, "")

      {blocks, buffer} ->
        [Enum.map(blocks, &normalize_codex_responses_sse_block/1), buffer]
    end
    |> IO.iodata_to_binary()
  end

  @spec normalize_codex_responses_sse_block(binary(), binary()) :: iodata()
  def normalize_codex_responses_sse_block(block, separator \\ "\n\n") do
    {event_type, decoded} = codex_responses_stream_block_event(block)

    if codex_responses_error_needs_canonical_response?(event_type, decoded) do
      encode_codex_responses_error_sse(decoded)
    else
      [block, separator]
    end
  end

  @spec normalize_public_openai_responses_sse_data(
          binary(),
          public_openai_responses_stream_state()
        ) ::
          {binary(), public_openai_responses_stream_state()}
  def normalize_public_openai_responses_sse_data(data, state),
    do: PublicResponses.normalize_data(data, state)

  @spec canonicalize_codex_responses_json_message(binary()) :: binary()
  def canonicalize_codex_responses_json_message(data) when is_binary(data) do
    with {:ok, %{} = decoded} <- Jason.decode(data),
         {event_type, _decoded} <- {decoded_string(decoded, "type"), decoded},
         true <- codex_responses_error_needs_canonical_response?(event_type, decoded) do
      Jason.encode!(canonical_codex_responses_error_event(decoded))
    else
      _other -> data
    end
  end

  @spec websocket_error_frame_headers(binary()) :: websocket_frame_headers()
  def websocket_error_frame_headers(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => type, "headers" => %{} = headers}}
      when type in ["response.failed", "response.incomplete", "error"] ->
        sanitized_websocket_error_headers(headers)

      _other ->
        %{}
    end
  end

  def websocket_error_frame_headers(_data), do: %{}

  @spec complete_sse_blocks(binary(), keyword()) :: {[binary()], binary()}
  def complete_sse_blocks(data, opts) do
    data = String.replace(data, "\r\n", "\n")
    bounded? = Keyword.fetch!(opts, :bounded?)

    if String.contains?(data, "\n\n") do
      parts = String.split(data, "\n\n")
      ends_with_separator? = String.ends_with?(data, "\n\n")

      {complete, buffer} =
        if ends_with_separator? do
          {parts, ""}
        else
          {Enum.drop(parts, -1), List.last(parts) || ""}
        end

      {Enum.reject(complete, &(&1 == "")), maybe_bound_incomplete_sse_block(buffer, bounded?)}
    else
      {[], maybe_bound_incomplete_sse_block(data, bounded?)}
    end
  end

  @spec first_complete_event(binary()) :: {:ok, map()} | :incomplete
  def first_complete_event(buffer) do
    case complete_sse_blocks(buffer, bounded?: false) do
      {[block | _rest], _remaining} -> {:ok, sse_event_summary(block)}
      {[], _remaining} -> incomplete_sse_or_direct_stream_event_summary(buffer)
    end
  end

  @spec terminal_failure(binary()) :: {:ok, terminal_failure()} | :error
  def terminal_failure(data) when is_binary(data) do
    {blocks, _buffer} = complete_sse_blocks(data, bounded?: false)

    blocks
    |> Enum.find_value(fn block -> terminal_failure_event(sse_event_summary(block)) end)
    |> Kernel.||(direct_terminal_stream_failure(data))
  end

  @spec terminal_failure_event(map()) :: {:ok, terminal_failure()} | nil
  def terminal_failure_event(%{event_type: event_type} = event)
      when event_type in @terminal_event_types do
    {:ok,
     %{
       code: event.error_code || event.event_type || "upstream_terminal_failure",
       upstream_code: event.upstream_error_code,
       event_type: event.event_type,
       data_type: event.data_type
     }}
  end

  def terminal_failure_event(_event), do: nil

  @spec retryable_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  def retryable_first_terminal_failure(%{event_type: event_type, error_code: code} = event)
      when event_type in @terminal_event_types and code in @retryable_first_event_codes do
    if previous_response_miss_code?(Map.get(event, :upstream_error_code)) do
      :error
    else
      {:ok,
       %{
         code: code,
         upstream_code: Map.get(event, :upstream_error_code),
         event_type: event_type,
         data_type: Map.get(event, :data_type)
       }}
    end
  end

  def retryable_first_terminal_failure(_event), do: :error

  @spec auth_refresh_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  def auth_refresh_first_terminal_failure(%{event_type: event_type, error_code: code} = event)
      when event_type in @terminal_event_types and code in @websocket_auth_refresh_event_codes do
    {:ok,
     %{
       code: code,
       upstream_code: Map.get(event, :upstream_error_code),
       event_type: event_type,
       data_type: Map.get(event, :data_type)
     }}
  end

  def auth_refresh_first_terminal_failure(_event), do: :error

  @spec internal_rate_limit_event?(term()) :: boolean()
  def internal_rate_limit_event?(%{} = event) do
    event_type = Map.get(event, :event_type) || Map.get(event, "event_type")

    data_type =
      Map.get(event, :data_type) || Map.get(event, "data_type") || Map.get(event, "type")

    event_type == "codex.rate_limits" or data_type == "codex.rate_limits"
  end

  def internal_rate_limit_event?(data) when is_binary(data) do
    case incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> internal_rate_limit_event?(event)
      :incomplete -> false
    end
  end

  def internal_rate_limit_event?(_data), do: false

  @spec downstream_visible_event?(term()) :: boolean()
  def downstream_visible_event?(%{} = event) do
    not internal_rate_limit_event?(event) and visible_downstream_event?(event)
  end

  def downstream_visible_event?(data) when is_binary(data) do
    case incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> downstream_visible_event?(event)
      :incomplete -> false
    end
  end

  def downstream_visible_event?(_event), do: false

  @spec stream_data_visible?(term()) :: boolean()
  def stream_data_visible?(data) when is_binary(data) do
    {blocks, _buffer} = complete_sse_blocks(data, bounded?: false)

    Enum.any?(blocks, fn block ->
      event_type = sse_field(block, "event")
      decoded = block |> sse_field("data") |> decode_sse_data()
      data_type = decoded_string(decoded, "type")
      downstream_visible_event?(%{event_type: event_type, data_type: data_type})
    end)
  end

  def stream_data_visible?(_data), do: false

  @spec terminal_error_code(binary(), String.t() | nil) :: String.t()
  def terminal_error_code(body, terminal) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> error_code_from_decoded(decoded)
        {:error, _error} -> nil
      end
    end) || terminal || "upstream_websocket_terminal_failure"
  end

  @spec client_visible_error_code(String.t() | nil) :: String.t() | nil
  def client_visible_error_code("previous_response_not_found"), do: "stream_incomplete"
  def client_visible_error_code("invalid_previous_response_id"), do: "stream_incomplete"
  def client_visible_error_code(code), do: code

  @spec upstream_error_code(map()) :: String.t() | nil
  def upstream_error_code(decoded) when is_map(decoded) do
    upstream_sse_error_code_from_error(decoded) ||
      nested_string(decoded, ["response", "incomplete_details", "reason"]) ||
      nested_string(decoded, ["incomplete_details", "reason"]) ||
      decoded_string(decoded, "code")
  end

  @spec error_code_from_nested_error(map()) :: String.t() | nil
  def error_code_from_nested_error(error) do
    explicit_code = nested_string(error, ["code"])
    explicit_type = nested_string(error, ["type"])
    semantic_code = websocket_error_code_from_error(error)

    cond do
      previous_response_miss_code?(explicit_code) ->
        explicit_code

      previous_response_miss_code?(semantic_code) ->
        semantic_code

      previous_response_id_param?(error) and explicit_code == "stream_incomplete" ->
        "previous_response_not_found"

      true ->
        useful_error_code(explicit_code) || useful_error_code(explicit_type) || semantic_code
    end
  end

  @spec sse_field(binary(), binary()) :: binary() | nil
  def sse_field(block, name) do
    prefix = name <> ": "

    block
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
  end

  @spec decode_sse_data(term()) :: map()
  def decode_sse_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  def decode_sse_data(_data), do: %{}

  @spec valid_json?(term()) :: boolean()
  def valid_json?(body) when is_binary(body), do: match?({:ok, _}, Jason.decode(body))
  def valid_json?(_body), do: false

  defp codex_responses_stream_block_event(block) do
    data = sse_field(block, "data")
    decoded = if is_binary(data), do: decode_sse_data(data), else: decode_sse_data(block)
    event_type = sse_field(block, "event") || decoded_string(decoded, "type")

    {event_type, decoded}
  end

  defp codex_responses_error_needs_canonical_response?("error", decoded),
    do: not is_nil(sse_error_code(decoded))

  defp codex_responses_error_needs_canonical_response?("response.failed", decoded) do
    is_nil(nested_string(decoded, ["response", "error", "code"])) and
      not is_nil(sse_error_code(decoded))
  end

  defp codex_responses_error_needs_canonical_response?(_event_type, _decoded), do: false

  defp encode_codex_responses_error_sse(decoded) do
    [
      "event: response.failed\n",
      "data: ",
      Jason.encode!(canonical_codex_responses_error_event(decoded)),
      "\n\n"
    ]
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

  defp sanitized_websocket_error_headers(headers) do
    Enum.reduce(headers, %{}, fn header, acc ->
      put_allowed_websocket_error_header(acc, header)
    end)
  end

  defp put_allowed_websocket_error_header(acc, {name, value}) do
    name = name |> to_string() |> String.downcase()

    case allowed_scalar_header_value(name, value) do
      {:ok, value} -> Map.put(acc, name, value)
      :error -> acc
    end
  end

  defp allowed_scalar_header_value(name, value) do
    if allowed_websocket_error_header?(name), do: scalar_header_value(value), else: :error
  end

  defp allowed_websocket_error_header?(name) when name in @metadata_header_names, do: true
  defp allowed_websocket_error_header?("x-codex-rate-limit-reached-type"), do: true

  defp allowed_websocket_error_header?(name) do
    Enum.any?(@quota_header_prefixes, &String.starts_with?(name, &1)) or
      (String.starts_with?(name, "x-") and
         Enum.any?(@quota_window_header_suffixes, &String.ends_with?(name, &1)))
  end

  defp scalar_header_value(value) when is_binary(value), do: {:ok, value}
  defp scalar_header_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp scalar_header_value(value) when is_float(value), do: {:ok, to_string(value)}
  defp scalar_header_value(value) when is_boolean(value), do: {:ok, to_string(value)}
  defp scalar_header_value(_value), do: :error

  defp canonical_codex_responses_error(decoded) do
    error = canonical_codex_responses_error_source(decoded) || %{}

    upstream_code = upstream_error_code(decoded)
    code = client_visible_error_code(upstream_code)
    code = code || "upstream_terminal_failure"
    message = canonical_codex_responses_error_message(decoded, code, upstream_code)

    error = Map.put(error, "code", code)

    if previous_response_miss_code?(upstream_code) do
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
    |> Map.put_new("status", "failed")
  end

  defp canonical_codex_responses_error_message(_decoded, _code, upstream_code)
       when upstream_code in ["previous_response_not_found", "invalid_previous_response_id"],
       do: "upstream stream incomplete"

  defp canonical_codex_responses_error_message(decoded, code, _upstream_code) do
    nested_string(decoded, ["response", "error", "message"]) ||
      nested_string(decoded, ["error", "message"]) ||
      nested_string(decoded, ["response", "status_details", "error", "message"]) ||
      nested_string(decoded, ["status_details", "error", "message"]) ||
      nested_string(decoded, ["message"]) ||
      "upstream stream returned terminal event #{code}"
  end

  defp sse_event_summary(block) do
    {event_type, decoded} = codex_responses_stream_block_event(block)

    %{
      event_type: event_type,
      error_code: sse_error_code(decoded),
      upstream_error_code: upstream_error_code(decoded),
      data_type: decoded_string(decoded, "type")
    }
  end

  defp direct_stream_event_summary(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        {:ok,
         %{
           event_type: decoded_string(decoded, "type"),
           error_code: sse_error_code(decoded),
           upstream_error_code: upstream_error_code(decoded),
           data_type: decoded_string(decoded, "type")
         }}

      _other ->
        :incomplete
    end
  end

  defp incomplete_sse_or_direct_stream_event_summary(data) do
    case sse_event_summary(data) do
      %{event_type: event_type} = event when is_binary(event_type) -> {:ok, event}
      _event -> direct_stream_event_summary(data)
    end
  end

  defp direct_terminal_stream_failure(data) do
    case incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> terminal_failure_event(event) || :error
      :incomplete -> :error
    end
  end

  defp visible_downstream_event?(event) do
    {event_type, data_type} = event_stream_types(event)

    visible_event_type?(event_type) or visible_event_type?(data_type)
  end

  defp event_stream_types(event) do
    event_type = Map.get(event, :event_type) || Map.get(event, "event_type")

    data_type =
      Map.get(event, :data_type) || Map.get(event, "data_type") || Map.get(event, "type")

    {event_type, data_type}
  end

  defp visible_event_type?(type) when type in @downstream_visible_event_types, do: true

  defp visible_event_type?(type) when is_binary(type) do
    String.contains?(type, ".delta") or String.contains?(type, "output") or
      String.contains?(type, "message") or String.contains?(type, "tool")
  end

  defp visible_event_type?(_type), do: false

  defp error_code_from_decoded(%{"response" => %{"error" => %{} = error}}) do
    error_code_from_nested_error(error)
  end

  defp error_code_from_decoded(%{"error" => %{} = error}) do
    error_code_from_nested_error(error)
  end

  defp error_code_from_decoded(%{
         "response" => %{"status_details" => %{"error" => %{} = error}}
       }) do
    error_code_from_nested_error(error)
  end

  defp error_code_from_decoded(%{"status_details" => %{"error" => %{} = error}}) do
    error_code_from_nested_error(error)
  end

  defp error_code_from_decoded(_decoded), do: nil

  defp upstream_sse_error_code_from_error(decoded) do
    [
      get_in(decoded, ["response", "error"]),
      get_in(decoded, ["error"]),
      get_in(decoded, ["response", "status_details", "error"]),
      get_in(decoded, ["status_details", "error"])
    ]
    |> first_map()
    |> case do
      %{} = error -> error_code_from_nested_error(error)
      _error -> wrapped_error_envelope_code(decoded)
    end
  end

  defp canonical_codex_responses_error_source(decoded) do
    first_map([
      get_in(decoded, ["response", "error"]),
      get_in(decoded, ["error"]),
      get_in(decoded, ["response", "status_details", "error"]),
      get_in(decoded, ["status_details", "error"]),
      wrapped_top_level_error(decoded)
    ])
  end

  defp wrapped_top_level_error(%{"type" => "error"} = decoded) do
    decoded
    |> Map.take(["code", "message", "param"])
    |> reject_nil_values()
    |> case do
      map when map == %{} -> nil
      map -> map
    end
  end

  defp wrapped_top_level_error(_decoded), do: nil

  defp wrapped_error_envelope_code(%{"type" => "error"} = decoded) do
    decoded
    |> wrapped_top_level_error()
    |> case do
      %{} = error -> error_code_from_nested_error(error)
      _error -> nil
    end || status_error_code(decoded_status(decoded))
  end

  defp wrapped_error_envelope_code(_decoded), do: nil

  defp status_error_code(status) when is_integer(status) and status >= 500 and status <= 599,
    do: "server_error"

  defp status_error_code(429), do: "rate_limit_exceeded"
  defp status_error_code(_status), do: nil

  defp decoded_status(decoded) do
    case Map.fetch(decoded, "status") do
      {:ok, status} -> parse_status(status)
      :error -> parse_status(Map.get(decoded, "status_code"))
    end
  end

  defp parse_status(status) when is_integer(status), do: status

  defp parse_status(status) when is_binary(status) do
    case Integer.parse(status) do
      {status, ""} -> status
      _other -> nil
    end
  end

  defp parse_status(_status), do: nil

  defp websocket_error_code_from_error(%{"param" => "previous_response_id", "message" => message})
       when is_binary(message) do
    if String.contains?(message, "Previous response with id") or
         String.contains?(message, "previous_response_id") do
      "previous_response_not_found"
    end
  end

  defp websocket_error_code_from_error(%{"message" => message}) when is_binary(message) do
    if String.contains?(message, "Previous response with id") or
         String.contains?(message, "previous_response_id") do
      "previous_response_not_found"
    end
  end

  defp websocket_error_code_from_error(%{"code" => code}) when is_binary(code),
    do: useful_error_code(code)

  defp websocket_error_code_from_error(%{"type" => type}) when is_binary(type),
    do: useful_error_code(type)

  defp websocket_error_code_from_error(_error), do: nil

  defp sse_error_code(decoded) when is_map(decoded) do
    decoded
    |> upstream_error_code()
    |> client_visible_error_code()
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp nested_string(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:cont, value}
        _other -> {:halt, nil}
      end
    end)
    |> case do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp previous_response_miss_code?(code)
       when code in ["previous_response_not_found", "invalid_previous_response_id"],
       do: true

  defp previous_response_miss_code?(_code), do: false

  defp previous_response_id_param?(%{"param" => "previous_response_id"}), do: true
  defp previous_response_id_param?(_error), do: false

  defp useful_error_code("error"), do: nil
  defp useful_error_code(code) when is_binary(code) and code != "", do: code
  defp useful_error_code(_code), do: nil

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_bound_incomplete_sse_block(buffer, false), do: buffer
  defp first_map(values), do: Enum.find(values, &is_map/1)
end
