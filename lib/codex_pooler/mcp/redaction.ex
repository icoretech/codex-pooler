defmodule CodexPooler.MCP.Redaction do
  @moduledoc """
  Reusable MCP redaction sentinel assertions for structured and text outputs.
  """

  @type category :: atom()

  @forbidden_sentinel_specs [
    {~w(raw mcp token), "REDACTION_RAW_MCP_TOKEN_SENTINEL"},
    {~w(mcp token hash), "REDACTION_MCP_TOKEN_HASH_SENTINEL"},
    {~w(raw pool api key), "REDACTION_RAW_POOL_API_KEY_SENTINEL"},
    {~w(pool api key hash), "REDACTION_POOL_API_KEY_HASH_SENTINEL"},
    {~w(invite url), "https://example.com/invites/REDACTION_INVITE_URL_SENTINEL"},
    {~w(invite token), "REDACTION_INVITE_TOKEN_SENTINEL"},
    {~w(temporary password), "REDACTION_TEMPORARY_PASSWORD_SENTINEL"},
    {~w(session token), "REDACTION_SESSION_TOKEN_SENTINEL"},
    {~w(totp secret), "REDACTION_TOTP_SECRET_SENTINEL"},
    {~w(recovery secret), "REDACTION_RECOVERY_SECRET_SENTINEL"},
    {~w(upstream auth json), ~s({"REDACTION_UPSTREAM_AUTH_JSON_SENTINEL":"secret"})},
    {~w(access token), "REDACTION_ACCESS_TOKEN_SENTINEL"},
    {~w(refresh token), "REDACTION_REFRESH_TOKEN_SENTINEL"},
    {~w(upstream secret), "REDACTION_UPSTREAM_SECRET_SENTINEL"},
    {~w(smtp secret), "REDACTION_SMTP_SECRET_SENTINEL"},
    {~w(metrics hmac), "REDACTION_METRICS_HMAC_SENTINEL"},
    {~w(metrics fingerprint), "REDACTION_METRICS_FINGERPRINT_SENTINEL"},
    {~w(raw headers), "REDACTION_RAW_HEADERS_SENTINEL"},
    {~w(raw metadata), "REDACTION_RAW_METADATA_SENTINEL"},
    {~w(raw evidence), "REDACTION_RAW_EVIDENCE_SENTINEL"},
    {~w(provider payload), "REDACTION_PROVIDER_PAYLOAD_SENTINEL"},
    {~w(cookies), "REDACTION_COOKIE_SENTINEL"},
    {~w(upload url), "https://uploads.example.com/REDACTION_UPLOAD_URL_SENTINEL"},
    {~w(filename), "REDACTION_PRIVATE_FILENAME_SENTINEL.txt"},
    {~w(prompt), "REDACTION_RAW_PROMPT_SENTINEL"},
    {~w(request body), "REDACTION_REQUEST_BODY_SENTINEL"},
    {~w(response body), "REDACTION_RESPONSE_BODY_SENTINEL"},
    {~w(raw tool command), "RAW_TOOL_COMMAND_SENTINEL"},
    {~w(raw tool output), "RAW_TOOL_OUTPUT_SENTINEL"},
    {~w(raw tool file output), "RAW_TOOL_FILE_OUTPUT_SENTINEL"},
    {~w(multipart body), "REDACTION_MULTIPART_BODY_SENTINEL"},
    {~w(websocket frame), "REDACTION_WEBSOCKET_FRAME_SENTINEL"},
    {~w(raw idempotency key), "REDACTION_RAW_IDEMPOTENCY_KEY_SENTINEL"},
    {~w(audit before blob), "REDACTION_AUDIT_BEFORE_BLOB_SENTINEL"},
    {~w(audit after blob), "REDACTION_AUDIT_AFTER_BLOB_SENTINEL"},
    {~w(disallowed email), "REDACTION_DISALLOWED_EMAIL_SENTINEL@example.com"},
    {~w(disallowed pii), "REDACTION_DISALLOWED_PII_SENTINEL"}
  ]

  @forbidden_sentinels Enum.map(@forbidden_sentinel_specs, fn {category_parts, sentinel} ->
                         category =
                           category_parts
                           |> Enum.join("_")
                           |> String.to_atom()

                         {category, sentinel}
                       end)

  @spec forbidden_sentinels() :: [{category(), String.t()}]
  def forbidden_sentinels, do: @forbidden_sentinels

  @spec forbidden_categories() :: [category()]
  def forbidden_categories, do: Keyword.keys(@forbidden_sentinels)

  @spec forbidden_sentinel!(category()) :: String.t()
  def forbidden_sentinel!(category), do: Keyword.fetch!(@forbidden_sentinels, category)

  @spec assert_structured_content_safe!(term()) :: :ok
  def assert_structured_content_safe!(structured_content) do
    assert_no_raw_struct!(structured_content, [])
    assert_no_forbidden_value!(structured_content, :structuredContent)
    assert_no_disallowed_pii!(structured_content, [])
    :ok
  end

  @spec assert_text_content_safe!(term()) :: :ok
  def assert_text_content_safe!(text) when is_binary(text) do
    assert_no_forbidden_text!(text, :text)
    assert_no_disallowed_text_pii!(text)
    :ok
  end

  def assert_text_content_safe!(text) do
    raise_assertion("text content must be a string, got #{inspect(text)}")
  end

  @spec assert_mcp_output_safe!(map()) :: :ok
  def assert_mcp_output_safe!(output) when is_map(output) do
    structured = Map.get(output, :structuredContent) || Map.get(output, "structuredContent")
    content = Map.get(output, :content) || Map.get(output, "content") || []

    if structured != nil do
      assert_structured_content_safe!(structured)
    end

    text = text_content(content)

    if text != "" do
      assert_text_content_safe!(text)
      assert_text_not_structured_mirror!(structured, text)
    end

    :ok
  end

  def assert_mcp_output_safe!(output) do
    raise_assertion("MCP output must be a map, got #{inspect(output)}")
  end

  defp text_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: "text", text: text} when is_binary(text) -> [text]
      _part -> []
    end)
    |> Enum.join("\n")
  end

  defp text_content(text) when is_binary(text), do: text
  defp text_content(_content), do: ""

  defp assert_no_forbidden_text!(text, surface) do
    for {category, sentinel} <- @forbidden_sentinels do
      if String.contains?(text, sentinel) do
        raise_assertion("#{surface} leaked forbidden #{category} sentinel")
      end
    end
  end

  defp assert_no_forbidden_value!(value, surface) when is_binary(value) do
    assert_no_forbidden_text!(value, surface)
  end

  defp assert_no_forbidden_value!(%{} = map, surface) do
    Enum.each(map, fn {key, value} ->
      assert_no_forbidden_value!(to_string(key), surface)
      assert_no_forbidden_value!(value, surface)
    end)
  end

  defp assert_no_forbidden_value!(list, surface) when is_list(list) do
    Enum.each(list, &assert_no_forbidden_value!(&1, surface))
  end

  defp assert_no_forbidden_value!(_value, _surface), do: :ok

  defp assert_no_raw_struct!(%{__struct__: struct}, path) do
    raise_assertion(
      "structuredContent contains raw struct #{inspect(struct)} at #{format_path(path)}"
    )
  end

  defp assert_no_raw_struct!(%{} = map, path) do
    Enum.each(map, fn {key, value} -> assert_no_raw_struct!(value, [key | path]) end)
  end

  defp assert_no_raw_struct!(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> assert_no_raw_struct!(value, [index | path]) end)
  end

  defp assert_no_raw_struct!(_value, _path), do: :ok

  defp assert_no_disallowed_pii!(%{} = map, path) do
    Enum.each(map, fn {key, value} ->
      normalized = normalize_key(key)
      next_path = [key | path]

      cond do
        normalized in [
          "email",
          "operator_email",
          "upstream_account_email",
          "invited_email",
          "actor_user_email"
        ] and raw_email?(value) ->
          raise_assertion("structuredContent leaked raw email at #{format_path(next_path)}")

        normalized in ["ip", "ip_address", "client_ip", "immediate_peer_ip"] and
            raw_ip?(value) ->
          raise_assertion("structuredContent leaked raw ip_address at #{format_path(next_path)}")

        normalized in ["upload_url", "download_url", "signed_url", "sas_url"] and raw_url?(value) ->
          raise_assertion("structuredContent leaked raw upload_url at #{format_path(next_path)}")

        true ->
          assert_no_disallowed_pii!(value, next_path)
      end
    end)
  end

  defp assert_no_disallowed_pii!(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> assert_no_disallowed_pii!(value, [index | path]) end)
  end

  defp assert_no_disallowed_pii!(_value, _path), do: :ok

  defp assert_no_disallowed_text_pii!(text) do
    cond do
      Regex.match?(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, text) ->
        raise_assertion("text content leaked raw email")

      Regex.match?(~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/, text) ->
        raise_assertion("text content leaked raw ip_address")

      Regex.match?(~r/https:\/\/(?:uploads|upload|files)\.example\.com\/\S+/, text) ->
        raise_assertion("text content leaked raw upload_url")

      true ->
        :ok
    end
  end

  defp assert_text_not_structured_mirror!(nil, _text), do: :ok

  defp assert_text_not_structured_mirror!(structured, text) do
    encoded = Jason.encode!(structured)

    if String.contains?(text, encoded) do
      raise_assertion("text content mirrors structuredContent")
    end

    :ok
  end

  defp raw_email?(value) when is_binary(value) do
    Regex.match?(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, value)
  end

  defp raw_email?(_value), do: false

  defp raw_ip?(value) when is_binary(value) do
    case :inet.parse_address(:binary.bin_to_list(value)) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp raw_ip?(_value), do: false

  defp raw_url?(value) when is_binary(value),
    do: String.starts_with?(value, "http://") or String.starts_with?(value, "https://")

  defp raw_url?(_value), do: false

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end

  defp format_path(path) do
    path
    |> Enum.reverse()
    |> Enum.map_join(".", &to_string/1)
  end

  defp raise_assertion(message) do
    raise ExUnit.AssertionError, message: message
  end
end
