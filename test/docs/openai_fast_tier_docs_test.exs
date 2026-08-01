defmodule CodexPooler.OpenAIFastTierDocsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.CompatibilityMatrix

  @owned_docs_paths [
    "RUNBOOK.md",
    "docs-site/public/llms.txt",
    "docs-site/src/content/_docs-contract.md",
    "docs-site/src/content/docs/clients/openai-compatible.mdx",
    "docs-site/src/content/docs/clients/opencode.mdx"
  ]
  @english_client_guides [
    "docs-site/src/content/docs/clients/opencode.mdx",
    "docs-site/src/content/docs/clients/openai-compatible.mdx"
  ]

  test "owns exactly the non-README documentation contract paths" do
    assert @owned_docs_paths == Enum.sort(@owned_docs_paths)

    assert Enum.all?(@owned_docs_paths, &File.regular?/1)
    refute "README.md" in @owned_docs_paths
    refute "README.zh-CN.md" in @owned_docs_paths
  end

  test "English client guides name priority as canonical and fast as accepted" do
    for path <- @english_client_guides do
      content = File.read!(path)
      assert content =~ "priority"
      assert content =~ "fast"
      assert content =~ "canonical"
      assert Regex.match?(~r/accepted\s+equivalent request spelling/, content)
    end
  end

  test "public contract distinguishes backend relay from v1 translation fidelity" do
    contract = File.read!("docs-site/src/content/_docs-contract.md")
    static = File.read!("docs-site/public/llms.txt")
    backend = CompatibilityMatrix.by_slug!(:backend_fast_service_tier)
    translated = CompatibilityMatrix.by_slug!(:responses_chat)

    assert contract =~ "Backend `/backend-api/codex` relay routes preserve provider bytes"

    assert contract =~
             "The narrow `/v1` surface\ntranslates supported request and response shapes"

    assert static =~
             "/backend-api/codex relays provider bytes, frames, and service-tier vocabulary unchanged."

    assert static =~ "/v1 translates supported OpenAI request and response shapes"

    assert backend.contract =~
             "relay provider bytes, frames, and service-tier vocabulary unchanged"

    assert translated.contract =~ "literal provider service_tier output"
  end

  test "changed service-tier fragments contain only allowed runtime endpoints" do
    for path <- @english_client_guides do
      path
      |> File.read!()
      |> service_tier_fragments()
      |> validate_fragments()
      |> then(&assert(&1 == :ok))
    end
  end

  test "fragment extraction and validation reject unsafe or collapsed claims" do
    assert validate_fragments(
             service_tier_fragments("""
             ## Service tier compatibility

             Use `service_tier: \"priority\"`. `fast` is an accepted equivalent request spelling.
             https://codex-pooler.example.com/v1
             """)
           ) == :ok

    assert validate_fragments(
             service_tier_fragments("""
             ## Service tier compatibility

             `service_tier: "priority"` https://internal.example.net/v1
             """)
           ) ==
             {:error, :disallowed_runtime_endpoint}

    assert validate_fragments(
             service_tier_fragments("""
             ## Service tier compatibility

             `service_tier: "priority"` reference .omo/runbook
             """)
           ) == {:error, :forbidden_internal_path}

    assert validate_fragments(
             service_tier_fragments("""
             ## Service tier compatibility

             `serviceTier: "priority"` see scripts/dev/check
             """)
           ) == {:error, :forbidden_internal_path}

    assert validate_fragments(
             service_tier_fragments("""
             ## Service tier compatibility

             `service_tier: "priority"` backend and /v1 preserve provider bytes and service-tier vocabulary unchanged
             """)
           ) == {:error, :collapsed_fidelity_claim}

    assert validate_fragments(
             service_tier_fragments("""
             ## Service tier compatibility

             `service_tier: "priority"` See [OpenAI docs](https://platform.openai.com/docs) for SDK details.
             """)
           ) == :ok
  end

  defp service_tier_fragments(document) do
    document
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.filter(fn {line, _index} ->
      String.contains?(line, "service_tier") or String.contains?(line, "serviceTier")
    end)
    |> Enum.map(fn {_line, index} ->
      document
      |> String.split("\n")
      |> Enum.slice(max(index - 2, 0), 5)
      |> Enum.join("\n")
    end)
  end

  defp validate_fragments(fragments) do
    with :ok <- reject_internal_paths(fragments),
         :ok <- reject_disallowed_runtime_endpoints(fragments),
         :ok <- reject_collapsed_fidelity_claim(fragments) do
      :ok
    end
  end

  defp reject_internal_paths(fragments) do
    if Enum.any?(
         fragments,
         &(String.contains?(&1, ".omo/") or String.contains?(&1, "scripts/dev/"))
       ) do
      {:error, :forbidden_internal_path}
    else
      :ok
    end
  end

  defp reject_disallowed_runtime_endpoints(fragments) do
    fragments
    |> Enum.flat_map(&Regex.scan(~r{https?://[^\s)`]+}, &1))
    |> List.flatten()
    |> Enum.find_value(:ok, fn endpoint ->
      if allowed_runtime_endpoint?(endpoint) or external_docs_link?(endpoint) do
        nil
      else
        {:error, :disallowed_runtime_endpoint}
      end
    end)
  end

  defp allowed_runtime_endpoint?(endpoint) do
    String.starts_with?(endpoint, "http://localhost:4000") or
      String.starts_with?(endpoint, "https://codex-pooler.example.com") or
      String.starts_with?(endpoint, "https://docs.codex-pooler.com")
  end

  defp external_docs_link?(endpoint),
    do: String.starts_with?(endpoint, "https://platform.openai.com/docs")

  defp reject_collapsed_fidelity_claim(fragments) do
    if Enum.any?(fragments, fn fragment ->
         String.contains?(fragment, "backend and /v1 preserve provider bytes")
       end) do
      {:error, :collapsed_fidelity_claim}
    else
      :ok
    end
  end
end
