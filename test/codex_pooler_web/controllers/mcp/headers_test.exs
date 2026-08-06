defmodule CodexPoolerWeb.Mcp.HeadersTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Mcp.Headers

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  describe "protocol_version/1" do
    test "Given no protocol header When reading the version Then it reports an absent version" do
      # Given
      request = request([])

      # When
      result = Headers.protocol_version(request)

      # Then
      assert result == {:ok, nil}
    end

    test "Given a plain protocol header When reading the version Then it returns the decoded value" do
      # Given
      request = request([{"mcp-protocol-version", "2026-07-28"}])

      # When
      result = Headers.protocol_version(request)

      # Then
      assert result == {:ok, "2026-07-28"}
    end

    test "Given an encoded protocol header When reading the version Then it returns the decoded value" do
      # Given
      request = request([{"mcp-protocol-version", encoded("2026-07-28")}])

      # When
      result = Headers.protocol_version(request)

      # Then
      assert result == {:ok, "2026-07-28"}
    end

    test "Given duplicate protocol headers When reading the version Then it reports a header mismatch" do
      # Given
      request = duplicate_request("mcp-protocol-version", "2026-07-28", "2025-11-25")

      # When
      result = Headers.protocol_version(request)

      # Then
      assert result == {:error, :header_mismatch}
    end
  end

  describe "validate_modern/3" do
    test "Given matching plain method headers When validating a non-tool call Then it accepts the request" do
      # Given
      request = request([{"mcp-method", "tools/list"}])

      # When
      result = Headers.validate_modern(request, "tools/list", %{})

      # Then
      assert result == :ok
    end

    test "Given an encoded matching tool name When validating a tool call Then it accepts the request" do
      # Given
      name = "codex_pooler_get_mcp_service_status"

      request =
        request([
          {"mcp-method", "tools/call"},
          {"mcp-name", encoded(name)}
        ])

      # When
      result = Headers.validate_modern(request, "tools/call", %{"name" => name})

      # Then
      assert result == :ok
    end

    test "Given no method header When validating a modern request Then it reports a header mismatch" do
      # Given
      request = request([])

      # When
      result = Headers.validate_modern(request, "tools/list", %{})

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given a mismatched method header When validating a modern request Then it reports a header mismatch" do
      # Given
      request = request([{"mcp-method", "tools/call"}])

      # When
      result = Headers.validate_modern(request, "tools/list", %{})

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given no name header for a tool call When validating the request Then it reports a header mismatch" do
      # Given
      request = request([{"mcp-method", "tools/call"}])

      # When
      result = Headers.validate_modern(request, "tools/call", %{"name" => "tool-name"})

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given a mismatched name header for a tool call When validating the request Then it reports a header mismatch" do
      # Given
      request = request([{"mcp-method", "tools/call"}, {"mcp-name", "another-tool"}])

      # When
      result = Headers.validate_modern(request, "tools/call", %{"name" => "tool-name"})

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given a duplicate method header When validating a modern request Then it reports a header mismatch" do
      # Given
      request = duplicate_request("mcp-method", "tools/list", "tools/list")

      # When
      result = Headers.validate_modern(request, "tools/list", %{})

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given an unsafe name header for a non-tool call When validating the request Then it ignores that header" do
      # Given
      request = request([{"mcp-method", "tools/list"}, {"mcp-name", " tool-name"}])

      # When
      result = Headers.validate_modern(request, "tools/list", %{})

      # Then
      assert result == :ok
    end
  end

  describe "decode_value/1" do
    test "Given malformed base64 sentinel content When decoding a header value Then it reports a header mismatch" do
      # Given
      value = "=?base64?not-base64?="

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given encoded invalid UTF-8 When decoding a header value Then it reports a header mismatch" do
      # Given
      value = encoded(<<255>>)

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given leading whitespace When decoding a plain header value Then it reports a header mismatch" do
      # Given
      value = " tools/list"

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given trailing whitespace When decoding a plain header value Then it reports a header mismatch" do
      # Given
      value = "tools/list "

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given an ASCII control byte When decoding a plain header value Then it reports a header mismatch" do
      # Given
      value = "tools/\tlist"

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given a non-ASCII byte sequence When decoding a plain header value Then it reports a header mismatch" do
      # Given
      value = "tools/líst"

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given a sentinel without its closing marker When decoding a header value Then it reports a header mismatch" do
      # Given
      value = "=?base64?dG9vbHMvbGlzdA=="

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:error, :header_mismatch}
    end

    test "Given an internal ASCII space When decoding a plain header value Then it accepts the value" do
      # Given
      value = "tools list"

      # When
      result = Headers.decode_value(value)

      # Then
      assert result == {:ok, "tools list"}
    end
  end

  defp request(headers) do
    Enum.reduce(headers, conn("POST", "/mcp"), fn {name, value}, request ->
      put_req_header(request, name, value)
    end)
  end

  defp duplicate_request(name, first_value, second_value) do
    request = request([{name, first_value}])
    %{request | req_headers: [{name, second_value} | request.req_headers]}
  end

  defp encoded(value), do: "=?base64?#{Base.encode64(value)}?="
end
