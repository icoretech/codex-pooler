defmodule CodexPooler.Files.UploadUrlPolicyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.UploadUrlPolicy

  @invalid_response_error %{
    status: 502,
    code: :upstream_file_bridge_invalid_response,
    message: "upstream file create returned an invalid upload_url",
    param: nil
  }

  @tag :upload_url_policy
  test "accepts syntactically valid public HTTPS upload hosts" do
    assert :ok = UploadUrlPolicy.validate("https://fake-upload.invalid/upload/file?sig=fake")

    assert :ok =
             UploadUrlPolicy.validate(
               "https://bucket.s3.eu-west-1.amazonaws.com/upload/file?X-Amz-Signature=fake"
             )

    assert :ok =
             UploadUrlPolicy.validate(
               "HTTPS://storage-account.blob.core.windows.net/container/file?sig=fake"
             )

    assert :ok =
             UploadUrlPolicy.validate(
               "https://upload.example.invalid/a%20b/file?filename=a%20b.txt&sig=fake%2Bvalue"
             )
  end

  @tag :upload_url_policy
  test "rejects local-resolving hostnames before direct upload" do
    invalid_urls = [
      "https://localhost.localdomain/upload/file",
      "https://service.localhost.localdomain/upload/file",
      "https://localhost.localdomain./upload/file",
      "https://broadcasthost/upload/file",
      "https://Broadcasthost/upload/file",
      "https://ip6-localnet/upload/file",
      "https://ip6-mcastprefix/upload/file"
    ]

    for upload_url <- invalid_urls do
      assert {:error, @invalid_response_error} == UploadUrlPolicy.validate(upload_url),
             "expected #{inspect(upload_url)} to be rejected"
    end
  end

  @tag :upload_url_policy
  test "rejects NAT64 IPv6 translation prefix literals" do
    invalid_urls = [
      "https://[64:ff9b::7f00:1]/upload/file",
      "https://[64:ff9b::a00:1]/upload/file",
      "https://[64:ff9b::a9fe:a9fe]/latest/meta-data",
      "https://[64:ff9b:1::7f00:1]/upload/file",
      "https://[64:ff9b:1::a00:1]/upload/file",
      "https://[64:ff9b:1::a9fe:a9fe]/latest/meta-data"
    ]

    for upload_url <- invalid_urls do
      assert {:error, @invalid_response_error} == UploadUrlPolicy.validate(upload_url),
             "expected #{inspect(upload_url)} to be rejected"
    end
  end

  @tag :upload_url_policy
  test "rejects raw control characters and whitespace anywhere in upload URL" do
    invalid_urls = [
      "https://upload.example.invalid/upload\r\nHost:127.0.0.1",
      "https://upload.example.invalid/upload\nnext",
      "https://upload.example.invalid/upload\tfile",
      "https://upload.example.invalid/a b",
      "https://upload.example.invalid/upload?name=a b",
      "https://upload.example.invalid/upload?name=a\rb",
      "https://upload.example.invalid/upload?name=a\nb",
      "https://upload.example.invalid/upload?name=a\tb",
      "https://upload.example.invalid/upload\u0085next",
      "https://upload.example.invalid/a\u00A0b",
      "https://upload.example.invalid/upload?name=a\u2028b"
    ]

    for upload_url <- invalid_urls do
      assert {:error, @invalid_response_error} == UploadUrlPolicy.validate(upload_url),
             "expected #{inspect(upload_url)} to be rejected"
    end
  end

  @tag :upload_url_policy
  test "rejects malformed URLs, unsupported schemes, userinfo, and unsafe hosts" do
    invalid_urls = [
      "",
      "   ",
      "not a url",
      "//fake-upload.invalid/upload/file",
      "https://",
      "https:///upload/file",
      "https://[::1",
      "https://example .invalid/upload/file",
      "http://fake-upload.invalid/upload/file",
      "ftp://fake-upload.invalid/upload/file",
      "https://user:pass@fake-upload.invalid/upload/file",
      "https://localhost/upload/file",
      "https://localhost./upload/file",
      "https://service.localhost./upload/file",
      "https://127.0.0.1/upload/file",
      "http://127.0.0.1/upload/file",
      "https://127.0.0.1./upload/file",
      "https://10.0.0.1/upload/file",
      "https://172.16.0.1/upload/file",
      "https://192.168.0.1/upload/file",
      "https://169.254.169.254/latest/meta-data",
      "https://192.0.2.10/upload/file",
      "https://198.51.100.10/upload/file",
      "https://203.0.113.10/upload/file",
      "https://[::1]/upload/file",
      "https://[::]/upload/file",
      "https://[fc00::1]/upload/file",
      "https://[fe80::1]/upload/file",
      "https://[2001:db8::1]/upload/file",
      "https://[::ffff:127.0.0.1]/upload/file",
      "https://[::ffff:10.0.0.1]/upload/file",
      "https://[::ffff:169.254.169.254]/latest/meta-data"
    ]

    for upload_url <- invalid_urls do
      assert {:error, @invalid_response_error} == UploadUrlPolicy.validate(upload_url),
             "expected #{inspect(upload_url)} to be rejected"
    end
  end
end
