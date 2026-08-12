defmodule CodexPooler.Files.CapabilitySpoolTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.CapabilitySpool

  test "creates a private directory and 0600 upload file before writing" do
    assert {:ok, path, io} = CapabilitySpool.open()

    try do
      assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert :ok = IO.binwrite(io, "private bytes")
    after
      File.close(io)
      CapabilitySpool.remove(path)
    end

    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
  end
end
