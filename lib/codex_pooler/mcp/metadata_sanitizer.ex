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

  @dangerous_exact_keys MapSet.new(~w(
    connection_id
    previous_response_id
    provider_message
    raw_anchor
    typed_state
    websocket_frame
    websocket_owner_request_v2
  ))
  @projection_actions ~w(invalid absent introduced dropped preserved changed)
  @projection_classes ~w(compaction_trigger tool_call tool_output message reasoning other)
  @projection_stages ~w(downstream_frame compact_projection upstream_payload)
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
    cond do
      normalize_key(key) == "compaction_projection" -> scrub_compaction_projection(value)
      dangerous_key?(key) -> nil
      true -> value |> Enum.reduce(%{}, &scrub_map_entry/2) |> limit_map()
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

  defp raw_ip?(value) do
    case :inet.parse_address(:binary.bin_to_list(value)) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp raw_url?(value), do: Regex.match?(~r/^https?:\/\//, value)
  defp bearer_or_key?(value), do: Regex.match?(~r/(?i)\bbearer\s+|sk-cxp-[a-z0-9_-]+/, value)

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end

  defp scrub_compaction_projection(value) do
    value
    |> Map.take(["action" | @projection_stages])
    |> Enum.reduce(%{}, fn
      {"action", action}, safe when action in @projection_actions ->
        Map.put(safe, "action", action)

      {stage, stage_value}, safe when stage in @projection_stages and is_map(stage_value) ->
        Map.put(safe, stage, scrub_compaction_projection_stage(stage_value))

      {_key, _value}, safe ->
        safe
    end)
  end

  defp scrub_compaction_projection_stage(stage) do
    stage
    |> Map.take(~w(state anchor_fingerprint item_count count_capped item_classes))
    |> Enum.reduce(%{}, fn
      {"state", state}, safe when state in ~w(absent valid invalid) ->
        Map.put(safe, "state", state)

      {"anchor_fingerprint", fingerprint}, safe
      when is_binary(fingerprint) and byte_size(fingerprint) == 16 ->
        if fingerprint =~ ~r/\A[0-9a-f]{16}\z/,
          do: Map.put(safe, "anchor_fingerprint", fingerprint),
          else: safe

      {"item_count", count}, safe when is_integer(count) and count in 0..1_000_000 ->
        Map.put(safe, "item_count", count)

      {"count_capped", capped?}, safe when is_boolean(capped?) ->
        Map.put(safe, "count_capped", capped?)

      {"item_classes", classes}, safe when is_map(classes) ->
        classes =
          classes
          |> Map.take(@projection_classes)
          |> Enum.filter(fn {_class, count} -> is_integer(count) and count in 0..1_000_000 end)
          |> Map.new()

        Map.put(safe, "item_classes", classes)

      {_key, _value}, safe ->
        safe
    end)
  end
end
