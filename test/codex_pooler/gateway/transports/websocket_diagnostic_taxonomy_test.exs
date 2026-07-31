defmodule CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomyTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract

  describe "identifier/1" do
    test "renders every source-owned websocket code in cleartext" do
      Enum.each(WebsocketOwnerContract.owner_errors(), fn code ->
        assert DiagnosticTaxonomy.identifier(code) == Atom.to_string(code)
      end)

      Enum.each(ErrorCodes.known_error_codes(), fn code ->
        assert DiagnosticTaxonomy.identifier(code) == code
      end)
    end

    test "includes the native fallback codes in the static stream vocabulary" do
      assert ErrorCodes.upstream_request_failed_code() == "upstream_request_failed"
      assert ErrorCodes.websocket_request_failed_code() == "websocket_request_failed"

      assert "upstream_request_failed" in ErrorCodes.known_error_codes()
      assert "websocket_request_failed" in ErrorCodes.known_error_codes()
    end

    test "renders an unknown code in cleartext when it passes the relay allowlist" do
      assert DiagnosticTaxonomy.identifier("synthetic_unlisted_provider_code") ==
               "synthetic_unlisted_provider_code"

      assert DiagnosticTaxonomy.identifier("Provider.Code-v2") == "Provider.Code-v2"
    end

    test "fingerprints unknown binaries outside the relay allowlist" do
      assert DiagnosticTaxonomy.identifier("has spaces inside") =~ ~r/^sha256_[0-9a-f]{12}$/
      assert DiagnosticTaxonomy.identifier(<<255>>) =~ ~r/^sha256_[0-9a-f]{12}$/

      oversized = String.duplicate("a", 81)
      assert DiagnosticTaxonomy.identifier(oversized) =~ ~r/^sha256_[0-9a-f]{12}$/

      refute DiagnosticTaxonomy.identifier("has spaces inside") =~ "has spaces"
      assert DiagnosticTaxonomy.identifier(%{code: "any_code"}) == nil
    end

    test "fingerprints sensitive-looking unknown codes even when charset-clean" do
      assert DiagnosticTaxonomy.identifier("bearer_expired") =~ ~r/^sha256_[0-9a-f]{12}$/

      assert DiagnosticTaxonomy.identifier("invalid_authorization_value") =~
               ~r/^sha256_[0-9a-f]{12}$/

      refute DiagnosticTaxonomy.identifier("bearer_expired") =~ "bearer"
    end
  end

  describe "reason_code/1" do
    test "extracts atom and tuple reasons plus atom- and string-keyed map codes" do
      assert DiagnosticTaxonomy.reason_code(:owner_unavailable) == "owner_unavailable"

      assert DiagnosticTaxonomy.reason_code({:owner_forward_timeout, :details}) ==
               "owner_forward_timeout"

      assert DiagnosticTaxonomy.reason_code(%{code: :owner_busy}) == "owner_busy"
      assert DiagnosticTaxonomy.reason_code(%{"code" => "server_error"}) == "server_error"
    end

    test "relays clean unknown codes, fingerprints unclean ones, rejects non-code terms" do
      assert DiagnosticTaxonomy.reason_code("synthetic_unknown_map_code") ==
               "synthetic_unknown_map_code"

      assert DiagnosticTaxonomy.reason_code(%{"code" => "synthetic_unknown_map_code"}) ==
               "synthetic_unknown_map_code"

      unclean = "synthetic unknown with spaces"
      unclean_identifier = DiagnosticTaxonomy.reason_code(unclean)
      assert unclean_identifier =~ ~r/^sha256_[0-9a-f]{12}$/
      refute unclean_identifier =~ "spaces"

      assert DiagnosticTaxonomy.reason_code(%{"reason" => :owner_busy}) == nil
      assert DiagnosticTaxonomy.reason_code({"some_code", :details}) == nil
      assert DiagnosticTaxonomy.reason_code(code: :owner_busy) == nil
    end
  end

  describe "safe_correlator/1" do
    test "normalizes punctuation, empty values, and caps output at 120 characters" do
      assert DiagnosticTaxonomy.safe_correlator("request/id with spaces") ==
               "request_id_with_spaces"

      assert DiagnosticTaxonomy.safe_correlator("") == "none"
      assert DiagnosticTaxonomy.safe_correlator(nil) == "none"
      assert DiagnosticTaxonomy.safe_correlator(<<255>>) == "none"

      assert DiagnosticTaxonomy.safe_correlator(String.duplicate("a", 121)) ==
               String.duplicate("a", 120)
    end

    test "redacts sensitive-looking values case-insensitively" do
      assert DiagnosticTaxonomy.safe_correlator("Bearer synthetic-value") == "redacted"
      assert DiagnosticTaxonomy.safe_correlator("contains-AUTH.JSON-marker") == "redacted"
    end
  end
end
