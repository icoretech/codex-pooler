defmodule CodexPoolerWeb.Mcp.ProtocolTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Mcp.Protocol

  @modern_version "2026-07-28"
  @legacy_versions ["2025-11-25", "2025-06-18"]

  describe "protocol version lists" do
    test "Given the protocol contract, When versions are listed, Then modern versions precede legacy versions" do
      assert Protocol.modern_protocol_versions() == [@modern_version]
      assert Protocol.legacy_protocol_versions() == @legacy_versions

      assert Protocol.supported_protocol_versions() == [@modern_version | @legacy_versions]
    end
  end

  describe "detect_era/3" do
    test "Given initialize requests, When headers or metadata disagree, Then legacy semantics always win" do
      cases = [
        {%{}, nil},
        {%{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => @modern_version}},
         @modern_version},
        {%{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "unknown-version"}},
         "unknown-version"}
      ]

      for {params, header} <- cases do
        assert Protocol.detect_era("initialize", params, header) == {:ok, :legacy}
      end
    end

    test "Given modern metadata, When its protocol header agrees, Then the request is modern" do
      params = modern_params()

      assert Protocol.detect_era("tools/list", params, @modern_version) ==
               {:ok, {:modern, @modern_version}}
    end

    test "Given a modern protocol version, When the header is absent or differs, Then it is a header mismatch" do
      params = modern_params()

      for header <- [nil | @legacy_versions] do
        assert Protocol.detect_era("tools/list", params, header) == {:error, :header_mismatch}
      end
    end

    test "Given no modern metadata, When the header is absent or legacy, Then the request is legacy" do
      for {params, header} <- [
            {%{}, nil},
            {%{}, "2025-11-25"},
            {%{"_meta" => %{}}, "2025-06-18"},
            {%{"_meta" => "not-a-map"}, nil}
          ] do
        assert Protocol.detect_era("tools/list", params, header) == {:ok, :legacy}
      end
    end

    test "Given no modern metadata, When a modern header is present, Then it is a header mismatch" do
      assert Protocol.detect_era("tools/list", %{}, @modern_version) == {:error, :header_mismatch}
    end

    test "Given malformed or unsupported protocol values, When eras are detected, Then unsupported wins" do
      cases = [
        {%{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "unknown-version"}}, nil},
        {%{}, "unknown-version"},
        {%{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2025-11-25"}},
         "2025-11-25"},
        {modern_params(), "unknown-version"}
      ]

      for {params, header} <- cases do
        assert Protocol.detect_era("tools/list", params, header) ==
                 {:error, :unsupported_protocol_version}
      end
    end
  end

  describe "validate_modern_meta/1" do
    test "Given modern metadata with client capabilities, When validated, Then its contents are not interpreted" do
      for client_capabilities <- [%{"unknownCapability" => true}, nil] do
        assert Protocol.validate_modern_meta(%{
                 "_meta" => %{
                   "io.modelcontextprotocol/clientCapabilities" => client_capabilities,
                   "io.modelcontextprotocol/clientInfo" => %{"name" => "ignored"},
                   "io.modelcontextprotocol/logLevel" => "debug"
                 }
               }) == :ok
      end
    end

    test "Given missing or malformed metadata, When modern metadata is validated, Then params are invalid" do
      for params <- [
            %{},
            %{"_meta" => nil},
            %{"_meta" => "not-a-map"},
            %{"_meta" => %{}}
          ] do
        assert Protocol.validate_modern_meta(params) == {:error, :invalid_params}
      end
    end
  end

  defp modern_params do
    %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => @modern_version}}
  end
end
