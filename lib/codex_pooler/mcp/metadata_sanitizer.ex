defmodule CodexPooler.MCP.MetadataSanitizer do
  @moduledoc false

  alias CodexPooler.MCP.Redaction

  @dangerous_key_fragments ~w(
    api_key apikey authorization bearer token access_token refresh_token upstream_token
    upstream_secret cookie set_cookie secret password prompt messages input output completion
    raw_request raw_response request_body response_body multipart_body body payload
    file filename audio image transcript transcription upload_url download_url sas_url signed_url
    idempotency_key raw_idempotency_key audit_before_blob audit_after_blob raw_headers headers
    before after raw_before raw_after auth_json metrics_hmac metrics_fingerprint smtp_secret
    session_token totp_secret recovery_secret temporary_password pii_sentinel
  )

  @dangerous_exact_keys MapSet.new(~w(previous_response_id websocket_frame))
  @safe_content_keys MapSet.new(~w(content_type request_content_type response_content_type))
  @safe_dangerous_keys MapSet.new(~w(token_refresh_reason_code_preview))

  @spec safe_metadata(term()) :: map()
  def safe_metadata(value) when is_map(value), do: value |> scrub_value(nil) |> safe_value()
  def safe_metadata(_value), do: %{}

  @spec safe_value(term()) :: term()
  def safe_value(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  def safe_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def safe_value(%Date{} = date), do: Date.to_iso8601(date)

  def safe_value(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), safe_value(value))
    end)
    |> limit_map()
  end

  def safe_value(list) when is_list(list), do: Enum.map(Enum.take(list, 10), &safe_value/1)
  def safe_value(value), do: value

  defp scrub_value(value, key) when is_map(value) do
    if dangerous_key?(key) do
      nil
    else
      value
      |> Enum.reduce(%{}, &scrub_map_entry/2)
      |> limit_map()
    end
  end

  defp scrub_value(value, key) when is_list(value) do
    if dangerous_key?(key) do
      nil
    else
      value
      |> Enum.map(&scrub_value(&1, key))
      |> Enum.reject(&is_nil/1)
      |> Enum.take(10)
    end
  end

  defp scrub_value(value, key) when is_binary(value) do
    cond do
      dangerous_key?(key) -> nil
      forbidden_sentinel?(value) -> "[REDACTED]"
      raw_email?(value) -> "[REDACTED]"
      raw_ip?(value) -> "[REDACTED]"
      raw_url?(value) -> "[REDACTED]"
      bearer_or_key?(value) -> "[REDACTED]"
      true -> String.slice(value, 0, 200)
    end
  end

  defp scrub_value(value, key), do: if(dangerous_key?(key), do: nil, else: value)

  defp scrub_map_entry({child_key, child_value}, acc) do
    case scrub_value(child_value, child_key) do
      nil -> acc
      scrubbed -> Map.put(acc, child_key, scrubbed)
    end
  end

  defp limit_map(map) when map_size(map) <= 20, do: map

  defp limit_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(20)
    |> Map.new()
  end

  defp dangerous_key?(nil), do: false

  defp dangerous_key?(key) do
    normalized = normalize_key(key)

    normalized not in @safe_content_keys and
      not MapSet.member?(@safe_dangerous_keys, normalized) and
      (MapSet.member?(@dangerous_exact_keys, normalized) or
         Enum.any?(@dangerous_key_fragments, &String.contains?(normalized, &1)))
  end

  defp forbidden_sentinel?(value) do
    Enum.any?(Redaction.forbidden_sentinels(), fn {_category, sentinel} ->
      String.contains?(value, sentinel)
    end)
  end

  defp raw_email?(value),
    do: Regex.match?(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, value)

  defp raw_ip?(value), do: Regex.match?(~r/^\d{1,3}(?:\.\d{1,3}){3}$/, value)
  defp raw_url?(value), do: Regex.match?(~r/^https?:\/\//, value)
  defp bearer_or_key?(value), do: Regex.match?(~r/(?i)\bbearer\s+|sk-cxp-[a-z0-9_-]+/, value)

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end
end
