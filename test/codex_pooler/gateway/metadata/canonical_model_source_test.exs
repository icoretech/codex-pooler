defmodule CodexPooler.Gateway.Metadata.CanonicalModelSourceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CanonicalModelSource
  alias CodexPooler.Gateway.Metadata.CodexCatalog

  @forbidden_keys ~w[
    manual_smoke_provisioned
    source_assignment_ids
    source_assignment_missing_sync_run_ids
    source_assignment_models
    upstream_model
  ]

  test "uses pristine assignment metadata as the base and applies only Pooler overlays" do
    source = source_metadata()
    model = model(source)

    assert {:ok, payload} =
             CanonicalModelSource.project(
               source,
               model,
               %{},
               %{"gpt-schema-fixture" => 256_000},
               "lite"
             )

    expected =
      source
      |> Map.drop(@forbidden_keys)
      |> Map.merge(%{
        "context_window" => 256_000,
        "max_context_window" => 256_000,
        "auto_compact_token_limit" => 230_400,
        "use_responses_lite" => true
      })

    assert payload == expected
    assert payload["multi_agent_version"] == "v2"
    assert payload["future_schema_field"] == source["future_schema_field"]
    assert payload["supported_reasoning_levels"] == source["supported_reasoning_levels"]
    assert payload["service_tiers"] == source["service_tiers"]
    assert Enum.all?(@forbidden_keys, &(not Map.has_key?(payload, &1)))
  end

  test "reasoning and tier policy inputs cannot mutate an included pristine entry" do
    source = source_metadata()
    model = model(source)

    assert {:ok, payload} = CanonicalModelSource.project(source, model, %{}, %{}, "full")

    assert payload["default_reasoning_level"] == source["default_reasoning_level"]
    assert payload["supported_reasoning_levels"] == source["supported_reasoning_levels"]
    assert payload["default_service_tier"] == source["default_service_tier"]
    assert payload["service_tiers"] == source["service_tiers"]
  end

  test "serving mode overlays do not alter context-window policy" do
    source =
      Map.merge(source_metadata(), %{
        "context_window" => 272_000,
        "max_context_window" => 300_000,
        "effective_context_window_percent" => 90,
        "auto_compact_token_limit" => nil
      })

    model = model(source)
    pricing_buckets = %{"gpt-schema-fixture" => ["long_context"]}
    context_window_overrides = %{"unrelated-model" => 256_000}

    assert {:ok, lite} =
             CanonicalModelSource.project(
               source,
               model,
               pricing_buckets,
               context_window_overrides,
               "lite"
             )

    assert {:ok, full} =
             CanonicalModelSource.project(
               source,
               model,
               pricing_buckets,
               context_window_overrides,
               "full"
             )

    context_fields = [
      "context_window",
      "max_context_window",
      "effective_context_window_percent",
      "auto_compact_token_limit"
    ]

    assert Map.take(lite, context_fields) == %{
             "context_window" => 270_000,
             "max_context_window" => 300_000,
             "effective_context_window_percent" => 90,
             "auto_compact_token_limit" => 243_000
           }

    assert Map.take(full, context_fields) == Map.take(lite, context_fields)
    assert Map.delete(lite, "use_responses_lite") == Map.delete(full, "use_responses_lite")
    assert lite["use_responses_lite"]
    refute full["use_responses_lite"]
  end

  test "canonical source removes atom-form provenance after safe key normalization" do
    clean_source = %{"slug" => "gpt-schema-fixture"}

    source =
      Map.merge(clean_source, %{
        manual_smoke_provisioned: true,
        source_assignment_ids: ["synthetic-assignment"],
        source_assignment_missing_sync_run_ids: %{"synthetic-assignment" => "synthetic-sync"},
        source_assignment_models: %{"synthetic-assignment" => %{}},
        upstream_model: %{"slug" => "synthetic-aggregate"}
      })

    assert {:ok, clean} = CanonicalModelSource.canonical_source(clean_source)

    assert {:ok, %{source: canonical_source} = canonical} =
             CanonicalModelSource.canonical_source(source)

    assert canonical_source == clean_source
    assert canonical.digest == clean.digest
  end

  test "cosmetic hint drift keeps one canonical digest while staying in the served source" do
    base = source_metadata()

    drifted =
      Map.merge(base, %{
        "default_reasoning_level" => "low",
        "default_service_tier" => "flex",
        "description" => "Drifted synthetic copy",
        "visibility" => "internal"
      })

    assert {:ok, canonical_base} = CanonicalModelSource.canonical_source(base)
    assert {:ok, canonical_drifted} = CanonicalModelSource.canonical_source(drifted)

    assert canonical_drifted.digest == canonical_base.digest

    # Excluding a field from the digest must not remove it from what the
    # catalog serves: partitioning narrows, the payload stays pristine.
    assert canonical_drifted.source["default_reasoning_level"] == "low"
    assert canonical_drifted.source["default_service_tier"] == "flex"
    assert canonical_drifted.source["description"] == "Drifted synthetic copy"
    assert canonical_drifted.source["visibility"] == "internal"
    refute canonical_drifted.source == canonical_base.source
  end

  test "canonical shell digest groups feature-equivalent shell values and isolates disabled" do
    known_shell_types = ~w(default local shell_command unified_exec)
    unknown_shell_type = "future_shell"
    non_string_shell_type = %{"unexpected" => true}

    shell_types =
      known_shell_types ++ ["disabled", unknown_shell_type, non_string_shell_type, :missing]

    canonical_by_shell_type =
      Map.new(shell_types, fn shell_type ->
        source =
          if shell_type == :missing do
            source_metadata()
          else
            Map.put(source_metadata(), "shell_type", shell_type)
          end

        assert {:ok, canonical} = CanonicalModelSource.canonical_source(source)

        if shell_type == :missing do
          refute Map.has_key?(canonical.source, "shell_type")
        else
          assert canonical.source["shell_type"] == shell_type
        end

        {shell_type, canonical}
      end)

    known_digests =
      Enum.map(known_shell_types, &canonical_by_shell_type[&1].digest)

    assert Enum.uniq(known_digests) == [canonical_by_shell_type["shell_command"].digest]

    isolated_digests =
      Enum.map(["disabled", unknown_shell_type, non_string_shell_type, :missing], fn shell_type ->
        canonical_by_shell_type[shell_type].digest
      end)

    assert Enum.all?(isolated_digests, &(&1 not in known_digests))
    assert isolated_digests |> MapSet.new() |> MapSet.size() == 4
  end

  test "behavioral drift still splits the canonical digest" do
    base = source_metadata()
    assert {:ok, canonical_base} = CanonicalModelSource.canonical_source(base)

    behavioral_drift = [
      {"slug", "gpt-schema-fixture-successor"},
      {"use_responses_lite", true},
      {"context_window", 400_000},
      {"max_context_window", 400_000},
      {"auto_compact_token_limit", 300_000},
      {"supported_reasoning_levels", []},
      {"service_tiers", []},
      {"multi_agent_version", "v3"},
      {"capabilities", %{"image_input" => false}}
    ]

    for {key, value} <- behavioral_drift do
      assert {:ok, drifted} =
               CanonicalModelSource.canonical_source(Map.put(base, key, value))

      refute drifted.digest == canonical_base.digest
    end
  end

  test "canonical source rejects atom and string collisions before provenance removal" do
    source = %{
      :source_assignment_ids => ["atom-value"],
      "source_assignment_ids" => ["string-value"],
      "slug" => "gpt-schema-fixture"
    }

    assert {:error, :invalid_model_metadata} = CanonicalModelSource.canonical_source(source)
  end

  test "body ETag is derived from the exact final projected body" do
    source = source_metadata()
    model = model(source)

    assert {:ok, full} = CanonicalModelSource.project(source, model, %{}, %{}, "full")
    assert {:ok, lite} = CanonicalModelSource.project(source, model, %{}, %{}, "lite")

    full_body = %{"models" => [full]}
    lite_body = %{"models" => [lite]}

    assert CodexCatalog.etag(full_body) ==
             CodexCatalog.etag(Jason.decode!(Jason.encode!(full_body)))

    refute CodexCatalog.etag(full_body) == CodexCatalog.etag(lite_body)
  end

  test "rejects malformed JSON terms and ambiguous keys without including raw values" do
    model = model(%{})
    private_marker = "fixture-private-marker"

    for source <- [
          %{"slug" => "gpt-schema-fixture", "future" => {private_marker, :invalid}},
          %{:slug => private_marker, "slug" => "gpt-schema-fixture"},
          %{1 => private_marker}
        ] do
      assert {:error, :invalid_model_metadata} =
               CanonicalModelSource.project(source, model, %{}, %{}, "full")
    end
  end

  defp source_metadata do
    %{
      "slug" => "gpt-schema-fixture",
      "display_name" => "Schema Fixture",
      "description" => "Synthetic compatibility model",
      "multi_agent_version" => "v2",
      "default_reasoning_level" => "high",
      "supported_reasoning_levels" => [
        %{"effort" => "high", "description" => "Deep"},
        %{"effort" => "future", "description" => "Future effort"}
      ],
      "service_tiers" => [
        %{"id" => "priority", "name" => "Priority", "description" => "Synthetic tier"}
      ],
      "default_service_tier" => "priority",
      "context_window" => 272_000,
      "max_context_window" => 272_000,
      "auto_compact_token_limit" => 244_800,
      "use_responses_lite" => false,
      "future_schema_field" => %{"nested" => [true, 7, nil]},
      "source_assignment_ids" => ["assignment-fixture"],
      "source_assignment_models" => %{"assignment-fixture" => %{}},
      "source_assignment_missing_sync_run_ids" => %{"assignment-fixture" => "sync-fixture"},
      "upstream_model" => %{"slug" => "aggregate-fixture"},
      "manual_smoke_provisioned" => true
    }
  end

  defp model(metadata) do
    %Model{
      upstream_model_id: "gpt-schema-fixture",
      exposed_model_id: "gpt-schema-fixture",
      display_name: "Schema Fixture",
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      metadata: metadata
    }
  end
end
