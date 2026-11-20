defmodule CodexPooler.Gateway.Metadata.CodexModelDecodeContractTest do
  # The released Codex client decodes the whole
  # catalog as one `ModelsResponse`, so one entry it cannot decode discards
  # every entry. Every body the catalog builders serve must satisfy the
  # client's `ModelInfo` decode, and for a client inside the verified window an
  # entry that does not is left out instead of served. The vectors' verdicts
  # are checked against released decoders (`codex debug
  # models` with `model_catalog_json`, the same serde path as the network
  # fetch): every vector the contract rejects the client rejects, and every
  # tolerated vector and served body the client decodes.
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.CodexCatalogShapes
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.Metadata.CodexModelDecodeContract

  describe "every served projection" do
    test "is decodable after the JSON round trip the client receives" do
      bodies = CodexCatalogShapes.served_bodies()

      assert length(bodies) == 24

      for {label, _representation, body} <- bodies do
        wire = body |> Jason.encode!() |> Jason.decode!()

        assert [_ | _] = wire["models"], label

        for entry <- wire["models"] do
          assert CodexModelDecodeContract.violations(entry) == [], "#{label} #{entry["slug"]}"
        end
      end
    end

    test "loses nothing under the decode check when every entry decodes" do
      by_label = Map.new(CodexCatalogShapes.served_bodies(), fn {label, _representation, body} -> {label, body} end)

      checked = Enum.filter(Map.keys(by_label), &String.ends_with?(&1, "/decode_checked"))
      assert length(checked) == 8

      for label <- checked do
        template_label = String.replace_suffix(label, "/decode_checked", "/instructions_template")
        assert Map.fetch!(by_label, label) == Map.fetch!(by_label, template_label), label
      end
    end
  end

  describe "violations/1" do
    test "the checked catalog preserves the multi-agent code mode flag across decoder versions" do
      slug = "sample-code-mode-model"
      source = CodexCatalogShapes.synced_source(slug)

      for flag <- [nil, true, false, "unrecognized"] do
        entry = Map.put(source, "multi_agent_tools_in_code_mode", flag)
        assert {:ok, catalog} = build([{model(slug), entry}], :decode_checked)
        assert [%{"multi_agent_tools_in_code_mode" => ^flag}] = catalog.body["models"]
      end
    end

    test "the common decoder ignores current-only guidance while preserving its value" do
      for guidance <- [nil, "Synthetic guidance", 7, false, %{}] do
        entry = "sample-guidance-model" |> CodexCatalogShapes.synced_source() |> put_in(["model_messages", "content_filter_guidance"], guidance)
        assert CodexModelDecodeContract.violations(entry) == []
        assert {:ok, catalog} = build([{model("sample-guidance-model"), entry}], :decode_checked)
        assert [served] = catalog.body["models"]
        assert served["model_messages"]["content_filter_guidance"] == guidance
      end
    end

    test "the common decoder preserves permission prefixes added inside its window" do
      for prefixes <- [nil, "Synthetic {{ approved_prefixes }}", 7, false, %{}] do
        entry = "sample-permissions-model" |> CodexCatalogShapes.synced_source() |> put_in(["model_messages", "permissions"], %{"approved_prefixes" => prefixes})
        assert CodexModelDecodeContract.violations(entry) == []
        assert {:ok, catalog} = build([{model("sample-permissions-model"), entry}], :decode_checked)
        assert [served] = catalog.body["models"]
        assert served["model_messages"]["permissions"]["approved_prefixes"] == prefixes
      end
    end

    test "diagnostics distinguish unknown enum variants from malformed values without retaining content" do
      base = CodexCatalogShapes.synced_source("sample-diagnostic-model")
      assert CodexModelDecodeContract.violation_classes(Map.put(base, "shell_type", "new_provider_variant")) == ["new_enum_variant"]
      assert CodexModelDecodeContract.violation_classes(Map.put(base, "shell_type", 17)) == ["malformed_entry"]
      assert CodexModelDecodeContract.violation_classes(base |> Map.put("shell_type", "new_provider_variant") |> Map.delete("priority")) == ["malformed_entry", "new_enum_variant"]
      assert CodexModelDecodeContract.violation_classes(Map.put(base, "input_modalities", ["text", "future_modality"])) == ["new_enum_variant"]
    end

    test "names exactly the fields the client fails to decode, before and after the JSON round trip" do
      vectors = CodexCatalogShapes.decode_vectors()
      assert Enum.count(vectors, fn {_label, _entry, expected} -> expected != [] end) == 42

      for {label, entry, expected} <- vectors do
        assert CodexModelDecodeContract.violations(entry) == expected, label
        assert entry |> Jason.encode!() |> Jason.decode!() |> CodexModelDecodeContract.violations() == expected, label
      end
    end

    test "does not judge the fields outside the window's common contract" do
      for {label, entry} <- CodexCatalogShapes.blind_vectors() do
        assert CodexModelDecodeContract.violations(entry) == [], label
      end
    end

    test "rejects an entry that is not an object" do
      for entry <- [nil, "gpt-vector", ["gpt-vector"], 7] do
        assert CodexModelDecodeContract.violations(entry) == ["<entry>"]
      end
    end

    test "the managed client release stays inside the independently verified window" do
      samples = CodexCatalogShapes.version_samples()
      current = Version.parse!(samples.current)
      assert CodexModelDecodeContract.verified_version?({current.major, current.minor, current.patch}), "qualify the managed Codex release's decoder before extending the verified window"
    end

    test "accepts both verified boundaries and refuses versions outside them" do
      samples = CodexCatalogShapes.version_samples()

      for version <- [samples.since, samples.through] do
        parsed = Version.parse!(version)
        assert CodexModelDecodeContract.verified_version?({parsed.major, parsed.minor, parsed.patch}), version
      end

      for version <- [samples.before, samples.after, "1.0.0"] do
        parsed = Version.parse!(version)
        refute CodexModelDecodeContract.verified_version?({parsed.major, parsed.minor, parsed.patch}), version
      end
    end
  end

  describe "the served catalog" do
    test "leaves out only the entry its client cannot decode, and only under the decode check" do
      sources = [
        {model("gpt-decodable"), CodexCatalogShapes.synced_source("gpt-decodable")},
        {model("gpt-undecodable"), Map.delete(CodexCatalogShapes.synced_source("gpt-undecodable"), "priority")},
        {model("gpt-legacy"), CodexCatalogShapes.legacy_source("gpt-legacy")}
      ]

      assert {:ok, checked} = build(sources, :decode_checked)
      assert Enum.map(checked.body["models"], & &1["slug"]) == ["gpt-decodable", "gpt-legacy"]
      assert checked.undecodable_models == [%{slug: "gpt-undecodable", fields: ["priority"], classes: ["malformed_entry"]}]
      assert checked.etag == CodexCatalog.etag(checked.body)

      for representation <- [:instructions_template, :verbatim] do
        assert {:ok, unchecked} = build(sources, representation)
        assert Enum.map(unchecked.body["models"], & &1["slug"]) == ["gpt-decodable", "gpt-legacy", "gpt-undecodable"]
        assert unchecked.undecodable_models == []
      end

      assert {:ok, template} = build(sources, :instructions_template)
      assert checked.body["models"] == Enum.reject(template.body["models"], &(&1["slug"] == "gpt-undecodable"))
      refute checked.etag == template.etag
    end

    test "serves an empty catalog when no entry decodes" do
      sources = [{model("gpt-undecodable"), Map.delete(CodexCatalogShapes.synced_source("gpt-undecodable"), "truncation_policy")}]

      assert {:ok, checked} = build(sources, :decode_checked)
      assert checked.body == %{"models" => []}
      assert checked.undecodable_models == [%{slug: "gpt-undecodable", fields: ["truncation_policy"], classes: ["malformed_entry"]}]
    end
  end

  defp build(sources, representation) do
    policy = %{allowed_model_identifiers: nil, enforced_model_identifier: nil, enforced_reasoning_effort: nil, maximum_reasoning_effort: nil}
    CodexCatalog.build_selected_sources(sources, policy, %{}, %{}, representation)
  end

  defp model(slug) do
    %Model{
      exposed_model_id: slug,
      upstream_model_id: "provider-#{slug}",
      display_name: slug,
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      metadata: %{}
    }
  end
end
