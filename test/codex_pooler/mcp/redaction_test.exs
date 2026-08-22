defmodule CodexPooler.MCP.RedactionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.MCP.Redaction

  @safe_structured %{
    "items" => [
      %{
        "id" => "req_123",
        "pool" => "Sample Pool",
        "operator_email" => "op***@example.com",
        "upstream_account_email" => "up***@example.com",
        "client_ip" => "203.0.113.xxx",
        "route" => "/backend-api/codex/responses",
        "summary" => "metadata only"
      }
    ]
  }

  @safe_text "1 request for Sample Pool, operator op***@example.com, route /backend-api/codex/responses"

  test "forbidden sentinel catalog covers every redaction category with synthetic values" do
    categories = Redaction.forbidden_categories()

    for category <- [
          :raw_mcp_token,
          :mcp_token_hash,
          :raw_pool_api_key,
          :pool_api_key_hash,
          :invite_url,
          :invite_token,
          :temporary_password,
          :session_token,
          :totp_secret,
          :recovery_secret,
          :upstream_auth_json,
          :access_token,
          :refresh_token,
          :upstream_secret,
          :smtp_secret,
          :metrics_hmac,
          :metrics_fingerprint,
          :raw_headers,
          :raw_metadata,
          :raw_evidence,
          :provider_payload,
          :cookies,
          :upload_url,
          :filename,
          :prompt,
          :request_body,
          :response_body,
          :raw_tool_command,
          :raw_tool_output,
          :raw_tool_file_output,
          :multipart_body,
          :websocket_frame,
          :raw_idempotency_key,
          :audit_before_blob,
          :audit_after_blob,
          :disallowed_email,
          :disallowed_pii
        ] do
      assert category in categories
      sentinel = Redaction.forbidden_sentinel!(category)
      assert is_binary(sentinel)
      assert sentinel =~ ~r/(?:REDACTION|RAW_TOOL)_/
    end
  end

  test "helpers reject raw structured tool command and output sentinels" do
    for category <- [:raw_tool_command, :raw_tool_output, :raw_tool_file_output] do
      sentinel = Redaction.forbidden_sentinel!(category)

      assert_raise ExUnit.AssertionError, ~r/#{category}/, fn ->
        Redaction.assert_structured_content_safe!(%{"tool_result" => %{"value" => sentinel}})
      end

      assert_raise ExUnit.AssertionError, ~r/#{category}/, fn ->
        Redaction.assert_text_content_safe!("metadata summary #{sentinel}")
      end
    end
  end

  test "structuredContent and text helper accepts sanitized MCP output" do
    assert :ok = Redaction.assert_structured_content_safe!(@safe_structured)
    assert :ok = Redaction.assert_text_content_safe!(@safe_text)

    assert :ok =
             Redaction.assert_mcp_output_safe!(%{
               structuredContent: @safe_structured,
               content: [%{"type" => "text", "text" => @safe_text}]
             })
  end

  test "structuredContent helper detects all forbidden sentinels recursively" do
    for {category, sentinel} <- Redaction.forbidden_sentinels() do
      assert_raise ExUnit.AssertionError, ~r/#{category}/, fn ->
        Redaction.assert_structured_content_safe!(%{
          "safe" => "metadata",
          "nested" => [%{"value" => sentinel}]
        })
      end
    end
  end

  test "text helper detects all forbidden sentinels without relying on structuredContent" do
    for {category, sentinel} <- Redaction.forbidden_sentinels() do
      assert_raise ExUnit.AssertionError, ~r/#{category}/, fn ->
        Redaction.assert_text_content_safe!("metadata summary #{sentinel}")
      end
    end
  end

  test "helpers reject raw Ecto structs and other structs in structuredContent" do
    assert_raise ExUnit.AssertionError, ~r/raw struct/, fn ->
      Redaction.assert_structured_content_safe!(%{
        "raw" => %CodexPooler.Accounting.Request{id: "req_123"}
      })
    end
  end

  test "helpers reject raw disallowed PII shapes even when not planted as exact sentinels" do
    assert_raise ExUnit.AssertionError, ~r/email/, fn ->
      Redaction.assert_structured_content_safe!(%{"email" => "operator.privacy@example.com"})
    end

    assert_raise ExUnit.AssertionError, ~r/ip_address/, fn ->
      Redaction.assert_structured_content_safe!(%{"ip_address" => "198.51.100.99"})
    end

    assert_raise ExUnit.AssertionError, ~r/upload_url/, fn ->
      Redaction.assert_text_content_safe!(
        "upload destination https://uploads.example.com/private/file"
      )
    end
  end

  test "structuredContent helper rejects raw IPv4 and IPv6 immediate peer addresses" do
    for peer_ip <- ["192.0.2.91", "2001:db8::91"] do
      assert_raise ExUnit.AssertionError, ~r/ip_address/, fn ->
        Redaction.assert_structured_content_safe!(%{"immediate_peer_ip" => peer_ip})
      end
    end

    assert :ok =
             Redaction.assert_structured_content_safe!(%{
               "immediate_peer_ip" => "[REDACTED]",
               "client_ip_source" => "x_forwarded_for",
               "inspected_hops" => 2
             })
  end

  test "text compatibility does not mirror entire structured payload into text" do
    structured = %{
      "items" => [%{"id" => "req_123", "secret_like_safe_label" => "structured-only"}]
    }

    assert :ok =
             Redaction.assert_mcp_output_safe!(%{
               structuredContent: structured,
               content: [%{"type" => "text", "text" => "1 sanitized request"}]
             })

    assert_raise ExUnit.AssertionError, ~r/text content mirrors structuredContent/, fn ->
      Redaction.assert_mcp_output_safe!(%{
        structuredContent: structured,
        content: [%{"type" => "text", "text" => Jason.encode!(structured)}]
      })
    end
  end
end
