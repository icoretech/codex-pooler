defmodule CodexPooler.Gateway.Facade.FileCapabilityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Facade.FileCapability

  @origin "http://127.0.0.1:4567"

  test "maximum accepted signed URL stays below the HTTP/1 request-line limit" do
    prefix = "https://upload.example.invalid/blob?sig="
    raw_url = prefix <> String.duplicate("a", 4_096 - byte_size(prefix))
    file = file_record("file_boundary", 12)

    assert byte_size(raw_url) == 4_096
    assert {:ok, local_url} = FileCapability.mint(raw_url, file, :upload, origin: @origin)
    assert String.starts_with?(local_url, @origin <> "/file-capabilities/cpfc_")
    assert byte_size("PUT " <> URI.parse(local_url).path <> " HTTP/1.1\r\n") < 10_000

    assert {:ok, %{url: ^raw_url, file_id: "file_boundary"}} =
             FileCapability.resolve(local_url, :upload)

    too_long = raw_url <> "x"
    assert {:error, :invalid} = FileCapability.mint(too_long, file, :upload, origin: @origin)
  end

  test "capabilities hide provider data and fail closed across kind expiry and tampering" do
    now = System.system_time(:second)

    raw_url =
      "https://provider-account.example.invalid/blob/file_a?sig=PRIVATE_SIGNATURE_SENTINEL"

    file = file_record("file_a", 12, DateTime.from_unix!(now + 60))

    assert {:ok, local_url} =
             FileCapability.mint(raw_url, file, :download,
               origin: @origin,
               now: now,
               expires_at: now + 5
             )

    refute local_url =~ "provider-account"
    refute local_url =~ "PRIVATE_SIGNATURE_SENTINEL"
    assert FileCapability.local_url?(local_url, :download)
    refute FileCapability.local_url?(local_url, :upload)
    assert {:error, :invalid} = FileCapability.resolve(local_url, :upload, now: now)
    assert {:error, :invalid} = FileCapability.resolve(local_url, :download, now: now + 5)

    last = String.last(local_url)
    replacement = if last == "x", do: "y", else: "x"
    tampered = String.replace_suffix(local_url, last, replacement)
    assert {:error, :invalid} = FileCapability.resolve(tampered, :download, now: now)

    other_file = file_record("file_b", 12, file.expires_at)

    assert {:ok, other_url} =
             FileCapability.mint(raw_url, other_file, :download, origin: @origin, now: now)

    assert {:ok, %{file_id: "file_a"}} = FileCapability.resolve(local_url, :download, now: now)
    assert {:ok, %{file_id: "file_b"}} = FileCapability.resolve(other_url, :download, now: now)
    refute local_url == other_url
  end

  defp file_record(
         file_id,
         byte_size,
         expires_at \\ DateTime.add(DateTime.utc_now(), 60, :second)
       ) do
    %FileRecord{
      pool_id: Ecto.UUID.generate(),
      api_key_id: Ecto.UUID.generate(),
      file_id: file_id,
      byte_size: byte_size,
      pool_upstream_assignment_id: Ecto.UUID.generate(),
      upstream_identity_id: Ecto.UUID.generate(),
      expires_at: DateTime.truncate(expires_at, :microsecond)
    }
  end
end
