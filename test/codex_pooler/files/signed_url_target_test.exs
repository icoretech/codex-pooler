defmodule CodexPooler.Files.SignedUrlTargetTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.SignedUrlTarget

  @url "https://signed-upload.example.invalid:8443/container/file?sig=private-signature"

  test "rejects the complete DNS answer when either A or AAAA is private" do
    resolver = fn
      "signed-upload.example.invalid", :inet ->
        {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]}

      "signed-upload.example.invalid", :inet6 ->
        {:ok, [{0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]}
    end

    assert {:error, :invalid_target} = SignedUrlTarget.pin(@url, resolver: resolver)
  end

  test "rejects a private AAAA answer even when every A answer is public" do
    resolver = fn
      "signed-upload.example.invalid", :inet -> {:ok, [{93, 184, 216, 34}]}
      "signed-upload.example.invalid", :inet6 -> {:ok, [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]}
    end

    assert {:error, :invalid_target} = SignedUrlTarget.pin(@url, resolver: resolver)
  end

  test "pins the connection address while retaining the signed host for Host SNI and TLS checks" do
    resolver = fn
      "signed-upload.example.invalid", :inet -> {:ok, [{93, 184, 216, 34}]}
      "signed-upload.example.invalid", :inet6 -> {:error, :nxdomain}
    end

    assert {:ok, target} = SignedUrlTarget.pin(@url, resolver: resolver)
    assert target.url == "https://93.184.216.34:8443/container/file?sig=private-signature"
    assert target.host_header == "signed-upload.example.invalid:8443"
    assert target.connect_options[:hostname] == "signed-upload.example.invalid"
    refute target.connect_options[:transport_opts][:verify] == :verify_none
  end

  test "revalidates a rebinding hostname on every use rather than reusing an earlier answer" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    resolver = fn "signed-upload.example.invalid", family ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      case {call, family} do
        {0, :inet} -> {:ok, [{93, 184, 216, 34}]}
        {1, :inet6} -> {:error, :nxdomain}
        {2, :inet} -> {:ok, [{10, 0, 0, 9}]}
        {3, :inet6} -> {:error, :nxdomain}
      end
    end

    assert {:ok, _first_target} = SignedUrlTarget.pin(@url, resolver: resolver)
    assert {:error, :invalid_target} = SignedUrlTarget.pin(@url, resolver: resolver)
  end
end
