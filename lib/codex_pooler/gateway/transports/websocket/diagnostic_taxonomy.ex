defmodule CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Websocket.OwnerErrorVocabulary

  @fingerprint_length 12
  @max_correlator_length 120
  # Unknown codes render in cleartext when they satisfy the same allowlist the
  # public relay applies to upstream-provided error codes (docs-site
  # clients/openai-compatible.mdx); anything else keeps the fingerprint.
  @unknown_code_allowlist ~r/\A[A-Za-z0-9_.-]+\z/
  @max_unknown_code_bytes 80
  @known_error_codes OwnerErrorVocabulary.owner_error_codes() ++ ErrorCodes.known_error_codes()
  @reconnect_dispositions ~w(
                             same_turn_replay
                             replacement_handoff
                             identity_rejected
                             owner_busy
                           )
  @handoff_outcomes ~w(
                        ready
                        timeout
                        owner_drained
                        socket_closed
                        submission_expired
                      )
  @sensitive_value_patterns [
    "auth.json",
    "authorization",
    "bearer",
    "cookie",
    "header",
    "idempotency",
    "payload",
    "prompt",
    "raw_request_body",
    "upstream_body",
    "websocket_frame"
  ]

  @spec identifier(atom() | binary() | term()) :: String.t() | nil
  def identifier(value) when is_atom(value), do: Atom.to_string(value)

  def identifier(value) when is_binary(value) do
    cond do
      known_error_code?(value) -> value
      relayable_unknown_code?(value) -> value
      true -> fingerprint(value)
    end
  end

  def identifier(_value), do: nil

  @spec reason_code(term()) :: String.t() | nil
  def reason_code({code, _details}) when is_atom(code), do: identifier(code)
  def reason_code(%{code: code}) when is_atom(code) or is_binary(code), do: identifier(code)
  def reason_code(%{"code" => code}) when is_atom(code) or is_binary(code), do: identifier(code)
  def reason_code(code) when is_atom(code) or is_binary(code), do: identifier(code)
  def reason_code(_reason), do: nil

  @spec reconnect_disposition(term()) :: String.t() | nil
  def reconnect_disposition(value), do: fixed_vocabulary(value, @reconnect_dispositions)

  @spec handoff_outcome(term()) :: String.t() | nil
  def handoff_outcome(value), do: fixed_vocabulary(value, @handoff_outcomes)

  @spec safe_correlator(term()) :: String.t()
  def safe_correlator(value) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        "none"

      sensitive_value?(value) ->
        "redacted"

      true ->
        value
        |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
        |> String.slice(0, @max_correlator_length)
        |> case do
          "" -> "none"
          sanitized -> sanitized
        end
    end
  end

  def safe_correlator(_value), do: "none"

  defp known_error_code?(value), do: value in @known_error_codes

  defp fixed_vocabulary(value, vocabulary) when is_atom(value) do
    value
    |> Atom.to_string()
    |> fixed_vocabulary(vocabulary)
  end

  defp fixed_vocabulary(value, vocabulary) when is_binary(value) do
    if value in vocabulary, do: value
  end

  defp fixed_vocabulary(_value, _vocabulary), do: nil

  defp relayable_unknown_code?(value) do
    byte_size(value) <= @max_unknown_code_bytes and
      Regex.match?(@unknown_code_allowlist, value)
  end

  defp fingerprint(value) do
    "sha256_" <>
      (:crypto.hash(:sha256, value)
       |> Base.encode16(case: :lower)
       |> String.slice(0, @fingerprint_length))
  end

  defp sensitive_value?(value) do
    normalized = String.downcase(value)
    Enum.any?(@sensitive_value_patterns, &String.contains?(normalized, &1))
  end
end
