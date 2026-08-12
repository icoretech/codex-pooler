defmodule CodexPooler.Gateway.Facade.Error do
  @moduledoc false

  @type protocol :: :ollama | :anthropic | :openai | :codex | :runtime_metadata

  @authentication_codes ~w(
    api_key_missing
    api_key_invalid
    invalid_api_key
    api_key_disabled
    api_key_inactive
    api_key_paused
    api_key_revoked
    api_key_expired
  )

  @local_message_codes ~w(
    invalid_request
    invalid_model
    unsupported_parameter
    access_denied
    settings_unavailable
    image_generation_disabled
    request_decompression_timeout
    unsupported_content_encoding
    compressed_request_too_large
    decompressed_request_too_large
    decompression_ratio_exceeded
    unsupported_media_type
  )

  @safe_protocol_codes ~w(
    previous_response_not_found
    stream_incomplete
    upstream_request_timeout
    server_error
    upstream_error
    context_length_exceeded
    overloaded_error
    server_is_overloaded
    websocket_connection_limit_reached
    rate_limit_exceeded
    upstream_websocket_terminal_failure
    upstream_request_failed
    websocket_request_failed
  )

  @previous_response_not_found_message "Previous response was not found. Retrying the full request."

  @spec body(protocol(), pos_integer(), map()) :: map()
  def body(:ollama, status, error) do
    %{"error" => public_message(status, error)}
  end

  def body(:anthropic, status, error) do
    %{
      "type" => "error",
      "error" => %{
        "type" => anthropic_type(status),
        "message" => public_message(status, error)
      }
    }
  end

  def body(protocol, status, error)
      when protocol in [:openai, :codex, :runtime_metadata] do
    %{
      "error" => %{
        "message" => public_message(status, error),
        "type" => "invalid_request_error",
        "code" => public_code(status, error),
        "param" => public_param(error)
      }
    }
  end

  @spec public_message(pos_integer(), map()) :: String.t()
  def public_message(status, error) when is_map(error) do
    code = normalized_code(error)

    cond do
      code in @authentication_codes ->
        "Pool API key is required or invalid"

      code == "v1_compatibility_disabled" ->
        "Compatibility access is disabled for this Pool"

      code in ["facade_policy_conflict", "facade_invariant_failed"] ->
        "Request denied by local Pool policy"

      code == "facade_model_unavailable" ->
        "gemma3 is temporarily unavailable"

      code == "unsupported_endpoint" ->
        "Endpoint is not supported"

      code == "previous_response_not_found" ->
        @previous_response_not_found_message

      code in @safe_protocol_codes ->
        generic_message(status)

      code in @local_message_codes ->
        local_message(error, generic_message(status))

      true ->
        generic_message(status)
    end
  end

  defp public_code(status, error) do
    code = normalized_code(error)

    cond do
      code in @authentication_codes -> code
      code == "v1_compatibility_disabled" -> code
      code in ["facade_policy_conflict", "facade_invariant_failed"] -> "local_policy_denied"
      code == "facade_model_unavailable" -> code
      code == "unsupported_endpoint" -> code
      code in @local_message_codes -> code
      code in @safe_protocol_codes -> code
      true -> generic_code(status)
    end
  end

  defp public_param(error) do
    code = normalized_code(error)
    param = Map.get(error, :param) || Map.get(error, "param")

    if code in @local_message_codes and is_binary(param) and
         Regex.match?(~r/^[A-Za-z0-9_.\[\]-]{1,128}$/, param) do
      param
    end
  end

  defp normalized_code(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp normalized_code(%{code: code}) when is_binary(code), do: code
  defp normalized_code(%{"code" => code}) when is_atom(code), do: Atom.to_string(code)
  defp normalized_code(%{"code" => code}) when is_binary(code), do: code
  defp normalized_code(_error), do: "request_failed"

  defp local_message(%{message: message}, _fallback) when is_binary(message) and message != "",
    do: message

  defp local_message(%{"message" => message}, _fallback)
       when is_binary(message) and message != "",
       do: message

  defp local_message(_error, fallback), do: fallback

  defp generic_message(400), do: "Request is invalid"
  defp generic_message(401), do: "Pool API key is required or invalid"
  defp generic_message(403), do: "Request denied by local Pool policy"
  defp generic_message(404), do: "Endpoint was not found"
  defp generic_message(408), do: "Request timed out"
  defp generic_message(413), do: "Request is too large"
  defp generic_message(415), do: "Request media type is not supported"
  defp generic_message(429), do: "Local request limit exceeded"
  defp generic_message(503), do: "gemma3 is temporarily unavailable"
  defp generic_message(504), do: "gemma3 request timed out"
  defp generic_message(status) when status >= 500, do: "gemma3 request failed"
  defp generic_message(_status), do: "Request failed"

  defp generic_code(400), do: "invalid_request"
  defp generic_code(401), do: "invalid_api_key"
  defp generic_code(403), do: "local_policy_denied"
  defp generic_code(404), do: "not_found"
  defp generic_code(408), do: "request_timeout"
  defp generic_code(413), do: "request_too_large"
  defp generic_code(415), do: "unsupported_media_type"
  defp generic_code(429), do: "rate_limit_exceeded"
  defp generic_code(503), do: "service_unavailable"
  defp generic_code(504), do: "gateway_timeout"
  defp generic_code(status) when status >= 500, do: "service_error"
  defp generic_code(_status), do: "request_failed"

  defp anthropic_type(400), do: "invalid_request_error"
  defp anthropic_type(401), do: "authentication_error"
  defp anthropic_type(403), do: "permission_error"
  defp anthropic_type(404), do: "not_found_error"
  defp anthropic_type(429), do: "rate_limit_error"
  defp anthropic_type(_status), do: "api_error"
end
