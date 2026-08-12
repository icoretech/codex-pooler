defmodule CodexPooler.Upstreams.CredentialProvenanceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "authenticated Codex ChatGPT provenance accepts only the allowlisted persisted enum" do
    assert UpstreamIdentity.authenticated_codex_chatgpt?(%UpstreamIdentity{
             credential_provenance: "codex_chatgpt_oauth"
           })

    for provenance <- [nil, "", "codex_chatgpt", "forged_provenance", 42] do
      refute UpstreamIdentity.authenticated_codex_chatgpt?(%UpstreamIdentity{
               credential_provenance: provenance
             })
    end
  end
end
