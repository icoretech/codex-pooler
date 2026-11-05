defmodule CodexPooler.Files.UploadHeadersTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.UploadHeaders
  alias Mint.HTTP1.Request

  test "normalizes upstream storage header names without changing value bytes" do
    headers = %{
      "Content-Type" => "application/octet-stream",
      "Content-Disposition" => ~s(attachment; filename="sample file.txt"),
      "x-amz-tagging" => "group=sample%20files&kind=input",
      "X-MS-Blob-Type" => "BlockBlob",
      "X-MS-Meta-Label" => "  sample\tvalue  "
    }

    assert {:ok, normalized} = UploadHeaders.normalize(headers)

    assert Map.new(normalized) == %{
             "content-type" => "application/octet-stream",
             "content-disposition" => ~s(attachment; filename="sample file.txt"),
             "x-amz-tagging" => "group=sample%20files&kind=input",
             "x-ms-blob-type" => "BlockBlob",
             "x-ms-meta-label" => "  sample\tvalue  "
           }
  end

  test "accepts missing and empty optional headers" do
    for input <- [nil, %{}] do
      assert UploadHeaders.normalize(input) == {:ok, []}
    end
  end

  test "accepted token punctuation and value whitespace encode with the installed Mint client" do
    name = "X-!#$%&'*+.^_`|~0123456789"
    value = " \tstorage; key=sample%20value \t"
    assert {:ok, headers} = UploadHeaders.normalize(%{name => value, "x-empty" => ""})
    assert {:ok, encoded} = Request.encode("PUT", "/upload", headers, nil)
    wire = IO.iodata_to_binary(encoded)
    assert wire =~ String.downcase(name, :ascii) <> ": " <> value <> "\r\n"
    assert wire =~ "x-empty: \r\n"
  end

  test "rejects non-object headers and non-string fields with the fixed safe error" do
    for input <- [[], "headers", 1, false, %{"x-storage" => ["sample"]}, %{"x-storage" => nil}, %{"x-storage" => 1}, %{storage: "sample"}, %URI{}] do
      assert_invalid_headers(input)
    end
  end

  test "rejects malformed HTTP header names" do
    for name <- ["", "x storage", "x:storage", "x/storage", "x=storage", "x\tstorage", "x\r\nstorage", "x-é", <<255>>] do
      assert_invalid_headers(%{name => "sample"})
    end
  end

  test "rejects control characters in values before a transport error can expose them" do
    for byte <- Enum.to_list(0..8) ++ Enum.to_list(10..31) ++ [127] do
      assert_invalid_headers(%{"x-storage" => "sample" <> <<byte>> <> "value"})
    end
  end

  test "rejects invalid UTF8 and non-ASCII values unsupported by Mint HTTP1" do
    for value <- [<<255>>, "café"] do
      assert_invalid_headers(%{"x-storage" => value})
    end
  end

  test "rejects case-insensitive duplicate names instead of choosing an arbitrary value" do
    assert_invalid_headers(%{"Content-Type" => "image/png", "content-type" => "application/octet-stream"})
  end

  test "rejects headers that could change storage destination or request framing" do
    for name <- ["Host", "Content-Length", "TRANSFER-ENCODING", "Connection", "Expect"] do
      assert_invalid_headers(%{name => "sample"})
    end
  end

  test "rejects credentials and backend account identity on storage uploads" do
    for name <- ["Authorization", "Proxy-Authorization", "Cookie", "ChatGPT-Account-ID", "X-OpenAI-API-Key", "OpenAI-Organization", "OpenAI-Project", "X-API-Key"] do
      assert_invalid_headers(%{name => "synthetic-value"})
    end
  end

  defp assert_invalid_headers(input) do
    result = UploadHeaders.normalize(input)

    assert result == {:error, %{status: 502, code: :upstream_file_bridge_invalid_response, message: "upstream file create returned invalid upload_headers"}},
           "invalid upload headers must return only the fixed sanitized error"
  end
end
