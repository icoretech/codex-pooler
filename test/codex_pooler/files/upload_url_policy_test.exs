defmodule CodexPooler.Files.UploadUrlPolicyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.UploadUrlPolicy
  alias CodexPooler.Files.UploadUrlPolicy.Target

  @invalid_response_error %{
    status: 502,
    code: :upstream_file_bridge_invalid_response,
    message: "upstream file create returned an invalid upload_url",
    param: nil
  }

  @tag :upload_url_policy
  test "resolves both address families and pins one answer without changing the signed URL" do
    owner = self()
    url = "https://storage.example.com:8443/a%2Fb?signature=synthetic%2Bvalue"

    resolver = fn host, family ->
      send(owner, {:resolved, host, family})

      case family do
        :inet -> {:ok, [{93, 184, 216, 34}, {93, 184, 216, 35}]}
        :inet6 -> {:ok, [{0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}]}
      end
    end

    assert {:ok, %Target{url: ^url, address: {93, 184, 216, 34}}} = UploadUrlPolicy.resolve(url, resolver)
    assert_received {:resolved, ~c"storage.example.com", :inet}
    assert_received {:resolved, ~c"storage.example.com", :inet6}
    refute_received {:resolved, _, _}
  end

  @tag :upload_url_policy
  test "rejects every unsafe DNS answer including mixed public and private families" do
    unsafe_addresses = [
      {0, 0, 0, 0},
      {10, 1, 2, 3},
      {100, 64, 0, 1},
      {127, 0, 0, 1},
      {169, 254, 169, 254},
      {172, 16, 0, 1},
      {192, 168, 1, 1},
      {192, 0, 2, 1},
      {198, 18, 0, 1},
      {198, 51, 100, 1},
      {203, 0, 113, 1},
      {224, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1},
      {0xFC00, 0, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
      {0x3FFF, 0, 0, 0, 0, 0, 0, 1},
      {0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1}
    ]

    for address <- unsafe_addresses, unsafe_family <- [:inet, :inet6] do
      resolver = fn _host, family ->
        if family == unsafe_family, do: {:ok, [{93, 184, 216, 34}, address]}, else: {:ok, [{93, 184, 216, 34}]}
      end

      assert {:error, @invalid_response_error} = UploadUrlPolicy.resolve("https://storage.example.com/upload", resolver)
    end
  end

  @tag :upload_url_policy
  test "resolution failures are closed even when the other family succeeds" do
    for replies <- [
          %{inet: {:error, :nxdomain}, inet6: {:error, :nxdomain}},
          %{inet: {:ok, []}, inet6: {:ok, []}},
          %{inet: {:ok, [{93, 184, 216, 34}]}, inet6: {:error, :timeout}},
          %{inet: {:error, :timeout}, inet6: {:ok, [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]}}
        ] do
      assert {:error, @invalid_response_error} = UploadUrlPolicy.resolve("https://storage.example.com/upload", fn _host, family -> Map.fetch!(replies, family) end)
    end
  end

  @tag :upload_url_policy
  test "public literals require no resolver and unsafe syntax never resolves" do
    resolver = fn _host, _family -> flunk("unexpected DNS lookup") end
    assert {:ok, %Target{address: {93, 184, 216, 34}}} = UploadUrlPolicy.resolve("https://93.184.216.34/upload", resolver)
    assert {:error, @invalid_response_error} = UploadUrlPolicy.resolve("https://127.0.0.1/upload", resolver)
    assert {:error, @invalid_response_error} = UploadUrlPolicy.resolve("http://storage.example.com/upload", resolver)
  end

  @tag :upload_url_policy
  test "accepts syntactically valid public HTTPS upload hosts" do
    assert :ok = UploadUrlPolicy.validate("https://fake-upload.invalid/upload/file?sig=fake")

    assert :ok =
             UploadUrlPolicy.validate("https://bucket.s3.eu-west-1.amazonaws.com/upload/file?X-Amz-Signature=fake")

    assert :ok =
             UploadUrlPolicy.validate("HTTPS://storage-account.blob.core.windows.net/container/file?sig=fake")

    assert :ok =
             UploadUrlPolicy.validate("https://upload.example.invalid/a%20b/file?filename=a%20b.txt&sig=fake%2Bvalue")
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
