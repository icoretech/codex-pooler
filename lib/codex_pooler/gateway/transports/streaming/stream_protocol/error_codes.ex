defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes do
  @moduledoc false

  @retryable_first_event_codes [
    "upstream_request_timeout",
    "stream_incomplete",
    "server_error",
    "overloaded_error",
    "server_is_overloaded",
    "websocket_connection_limit_reached"
  ]
  @websocket_auth_refresh_event_codes ["invalid_api_key", "invalid_authentication"]

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

      previous_response_id_param?(error) and explicit_code == "stream_incomplete" ->
        "previous_response_not_found"

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

  @spec websocket_auth_refresh_event_code?(String.t() | nil) :: boolean()
  def websocket_auth_refresh_event_code?(code) when code in @websocket_auth_refresh_event_codes,
    do: true

  def websocket_auth_refresh_event_code?(_code), do: false

  @spec previous_response_miss_code?(String.t() | nil) :: boolean()
  def previous_response_miss_code?(code)
      when code in ["previous_response_not_found", "invalid_previous_response_id"],
      do: true

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

  defp error_code_from_decoded(decoded) when is_map(decoded), do: structured_error_code(decoded)
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

  defp previous_response_id_param?(%{"param" => "previous_response_id"}), do: true
  defp previous_response_id_param?(_error), do: false

  defp useful_error_code("error"), do: nil
  defp useful_error_code(code) when is_binary(code) and code != "", do: code
  defp useful_error_code(_code), do: nil

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
