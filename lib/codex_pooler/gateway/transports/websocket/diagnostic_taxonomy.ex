defmodule CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract

  @fingerprint_length 12
  @max_correlator_length 120
  @known_error_codes MapSet.new(ErrorCodes.known_error_codes())
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
    if known_error_code?(value), do: value, else: fingerprint(value)
  end

  def identifier(_value), do: nil

  @spec reason_code(term()) :: String.t() | nil
  def reason_code({code, _details}) when is_atom(code), do: identifier(code)
  def reason_code(%{code: code}) when is_atom(code) or is_binary(code), do: identifier(code)
  def reason_code(%{"code" => code}) when is_atom(code) or is_binary(code), do: identifier(code)
  def reason_code(code) when is_atom(code) or is_binary(code), do: identifier(code)
  def reason_code(_reason), do: nil

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

  defp known_error_code?(value) do
    MapSet.member?(@known_error_codes, value) or
      Enum.any?(WebsocketOwnerContract.owner_errors(), &(Atom.to_string(&1) == value))
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
