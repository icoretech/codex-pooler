defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes do
  @moduledoc false

  @retryable_first_event_codes [
    "upstream_request_timeout",
    "stream_incomplete",
    "server_error",
    "overloaded_error",
    "server_is_overloaded",
    "slow_down",
    "websocket_connection_limit_reached"
  ]
  @websocket_auth_refresh_event_codes ["invalid_api_key", "invalid_authentication"]
  @previous_response_miss_codes [
    "previous_response_not_found",
    "invalid_previous_response_id"
  ]
  @stream_incomplete_code "stream_incomplete"
  @previous_response_not_found_code "previous_response_not_found"
  @server_error_code "server_error"
  @rate_limit_exceeded_code "rate_limit_exceeded"
  @terminal_default_code "upstream_websocket_terminal_failure"
  @upstream_request_failed_code "upstream_request_failed"
  @websocket_request_failed_code "websocket_request_failed"
  # Gateway-owned retryable code for exhausted upstream credential refresh on
  # either transport; the client-facing 401 stays reserved for API-key rejection.
  @upstream_unauthorized_code "upstream_unauthorized"

  # Keep provider vocabulary in one module while exposing separate predicates:
  # retry, terminal classification, and route health deliberately have
  # different effects for some of the same provider codes.
  @incomplete_failure_reason_codes [
    "upstream_request_timeout",
    "stream_incomplete",
    "server_error",
    "overloaded_error",
    "server_is_overloaded",
    "slow_down",
    "websocket_connection_limit_reached",
    "invalid_api_key",
    "invalid_authentication",
    "context_length_exceeded",
    "insufficient_quota",
    "usage_not_included",
    "invalid_previous_response_id",
    "invalid_request",
    "invalid_request_error",
    "invalid_prompt",
    "bio_policy",
    "cyber_policy",
    "misalignment_policy_violation",
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
  @health_neutral_error_codes [
    "context_length_exceeded",
    "cyber_policy",
    "invalid_request",
    "invalid_request_error",
    "invalid_previous_response_id",
    "invalid_prompt",
    "bio_policy",
    "max_output_tokens",
    "misalignment_policy_violation",
    "missing_required_parameter",
    "overloaded_error",
    "previous_response_not_found",
    "server_is_overloaded",
    "slow_down",
    "server_error",
    "unsupported_input_image_format",
    "unsupported_parameter",
    "unsupported_value",
    "usage_limit_exceeded",
    "usage_limit_reached"
  ]
  @codex_response_failed_non_retryable_codes [
    "context_length_exceeded",
    "insufficient_quota",
    "usage_not_included",
    "cyber_policy",
    "misalignment_policy_violation",
    "invalid_prompt",
    "bio_policy",
    "server_is_overloaded",
    "slow_down"
  ]

  @known_error_codes Enum.uniq(
                       @retryable_first_event_codes ++
                         @websocket_auth_refresh_event_codes ++
                         @previous_response_miss_codes ++
                         @incomplete_failure_reason_codes ++
                         @health_neutral_error_codes ++
                         @codex_response_failed_non_retryable_codes ++
                         [
                           @stream_incomplete_code,
                           @previous_response_not_found_code,
                           @server_error_code,
                           @rate_limit_exceeded_code,
                           @terminal_default_code,
                           @upstream_request_failed_code,
                           @websocket_request_failed_code,
                           @upstream_unauthorized_code
                         ]
                     )

  @spec known_error_codes() :: [String.t()]
  def known_error_codes, do: @known_error_codes

  @spec upstream_unauthorized_code() :: String.t()
  def upstream_unauthorized_code, do: @upstream_unauthorized_code

  @spec upstream_request_failed_code() :: String.t()
  def upstream_request_failed_code, do: @upstream_request_failed_code

  @spec websocket_request_failed_code() :: String.t()
  def websocket_request_failed_code, do: @websocket_request_failed_code

  @spec terminal_error_code(binary(), String.t() | nil) :: String.t()
  def terminal_error_code(body, terminal) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.find_value(fn line ->
      case CodexPooler.JSON.decode(line) do
        {:ok, decoded} -> error_code_from_decoded(decoded)
        {:error, _error} -> nil
      end
    end) || terminal || @terminal_default_code
  end

  @spec client_visible_error_code(String.t() | nil) :: String.t() | nil
  def client_visible_error_code(code) when code in @previous_response_miss_codes,
    do: @stream_incomplete_code

  def client_visible_error_code(code), do: code

  @spec upstream_error_code(map()) :: String.t() | nil
  def upstream_error_code(decoded) when is_map(decoded) do
    structured_error_code(decoded) ||
      nested_string(decoded, ["response", "incomplete_details", "reason"]) ||
      nested_string(decoded, ["incomplete_details", "reason"]) ||
      decoded_string(decoded, "code")
  end

  @spec structured_error_code(map()) :: String.t() | nil
  def structured_error_code(decoded) when is_map(decoded) do
    [
      get_in(decoded, ["response", "error"]),
      get_in(decoded, ["error"]),
      get_in(decoded, ["response", "status_details", "error"]),
      get_in(decoded, ["status_details", "error"])
    ]
    |> Enum.find(&is_map/1)
    |> case do
      %{} = error -> error_code_from_nested_error(error)
      _error -> wrapped_error_envelope_code(decoded)
    end
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

      previous_response_id_param?(error) and explicit_code == @stream_incomplete_code ->
        @previous_response_not_found_code

      true ->
        useful_error_code(explicit_code) || useful_error_code(explicit_type) || semantic_code
    end
  end

  @spec sse_error_code(map()) :: String.t() | nil
  def sse_error_code(decoded) when is_map(decoded) do
    decoded
    |> upstream_error_code()
    |> client_visible_error_code()
  end

  @spec retryable_first_event_code?(String.t() | nil) :: boolean()
  def retryable_first_event_code?(code) when code in @retryable_first_event_codes, do: true
  def retryable_first_event_code?(_code), do: false

  @spec incomplete_failure_reason?(String.t() | nil) :: boolean()
  def incomplete_failure_reason?(code) when code in @incomplete_failure_reason_codes, do: true
  def incomplete_failure_reason?(_code), do: false

  @spec health_neutral_error_code?(String.t() | nil) :: boolean()
  def health_neutral_error_code?(code) when code in @health_neutral_error_codes, do: true
  def health_neutral_error_code?(_code), do: false

  @spec codex_compaction_terminal_retryable?(String.t() | nil, String.t() | nil) :: boolean()
  def codex_compaction_terminal_retryable?("response.incomplete", _code), do: true

  def codex_compaction_terminal_retryable?("response.failed", code),
    do: code not in @codex_response_failed_non_retryable_codes

  def codex_compaction_terminal_retryable?(_event_type, _code), do: false

  @spec websocket_auth_refresh_event_code?(String.t() | nil) :: boolean()
  def websocket_auth_refresh_event_code?(code) when code in @websocket_auth_refresh_event_codes,
    do: true

  def websocket_auth_refresh_event_code?(_code), do: false

  @spec previous_response_miss_code?(String.t() | nil) :: boolean()
  def previous_response_miss_code?(code) when code in @previous_response_miss_codes, do: true

  def previous_response_miss_code?(_code), do: false

  @spec decoded_string(map(), String.t()) :: String.t() | nil
  def decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  def decoded_string(_decoded, _key), do: nil

  @spec nested_string(map(), [String.t()]) :: String.t() | nil
  def nested_string(map, keys) do
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

  @spec wrapped_top_level_error(map()) :: map() | nil
  def wrapped_top_level_error(%{"type" => "error"} = decoded) do
    decoded
    |> Map.take(["code", "message", "param"])
    |> reject_nil_values()
    |> case do
      map when map == %{} -> nil
      map -> map
    end
  end

  def wrapped_top_level_error(_decoded), do: nil

  # Deliberately narrower than structured_error_code/1: websocket terminal
  # classification must keep the terminal-type fallback for wrapped top-level
  # {"type":"error"} and status-only payloads, so this resolves only nested
  # error envelopes and returns nil otherwise (the pre-failover semantics).
  defp error_code_from_decoded(decoded) when is_map(decoded) do
    [
      get_in(decoded, ["response", "error"]),
      get_in(decoded, ["error"]),
      get_in(decoded, ["response", "status_details", "error"]),
      get_in(decoded, ["status_details", "error"])
    ]
    |> Enum.find(&is_map/1)
    |> case do
      %{} = error -> error_code_from_nested_error(error)
      _error -> nil
    end
  end

  defp error_code_from_decoded(_decoded), do: nil

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
    do: @server_error_code

  defp status_error_code(429), do: @rate_limit_exceeded_code
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
      @previous_response_not_found_code
    end
  end

  defp websocket_error_code_from_error(%{"message" => message}) when is_binary(message) do
    if String.contains?(message, "Previous response with id") or
         String.contains?(message, "previous_response_id") do
      @previous_response_not_found_code
    end
  end

  defp websocket_error_code_from_error(%{"code" => code}) when is_binary(code),
    do: useful_error_code(code)

  defp websocket_error_code_from_error(%{"type" => type}) when is_binary(type),
    do: useful_error_code(type)

  defp websocket_error_code_from_error(_error), do: nil

  defp previous_response_id_param?(%{"param" => "previous_response_id"}), do: true
  defp previous_response_id_param?(_error), do: false

  defp useful_error_code("error"), do: nil
  defp useful_error_code(code) when is_binary(code) and code != "", do: code
  defp useful_error_code(_code), do: nil

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
