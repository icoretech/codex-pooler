defmodule CodexPooler.Gateway.Metadata.CodexCatalogTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  # findings#258 row 258-61: production serves only the canonical pristine
  # source path; the aggregate-model builder these cases used to exercise had no
  # caller outside tests and was removed. The cases that still describe served
  # behaviour run through `build_selected_sources/5`.

  test "projects GPT-5.6 long-context metadata into the raw native Codex catalog" do
    source = Map.put(gpt56_context_metadata(), "slug", "gpt-5.6-context")

    assert {:ok, result} =
             CodexCatalog.build_selected_sources(
               [{model("gpt-5.6-context", %{}), source}],
               unrestricted_policy(),
               %{"gpt-5.6-context" => ["long_context"]},
               %{},
               %{}
             )

    [model] = result.body["models"]

    assert model["context_window"] == 872_000
    assert model["max_context_window"] == 872_000
    assert model["auto_compact_token_limit"] == 784_800
    assert model["effective_context_window_percent"] == 95
  end

  test "builds a slug-sorted catalog with an exact deterministic weak revision" do
    sources = [{model("gpt-a", %{}), pristine_source("gpt-a")}, {model("gpt-b", %{}), pristine_source("gpt-b")}]

    assert {:ok, result} = selected(Enum.reverse(sources))

    assert Enum.map(result.body["models"], & &1["slug"]) == ["gpt-a", "gpt-b"]
    assert result.etag =~ ~r/^W\/"cp-models-v1-[0-9a-f]{64}"$/
    assert {:ok, ^result} = selected(sources)
  end

  test "canonical fixture source preserves released-client capability booleans" do
    source = %{
      "slug" => "gpt-6-sol",
      "supports_responses" => true,
      "supports_streaming" => true,
      "supports_tools" => true,
      "supports_reasoning" => true,
      "prefer_websockets" => true,
      "capabilities" => %{
        "responses" => true,
        "streaming" => true,
        "tools" => true,
        "reasoning" => true
      }
    }

    assert {:ok, result} = selected([{model("gpt-6-sol", %{}), source}])

    assert [projected] = result.body["models"]
    assert projected["supports_responses"]
    assert projected["supports_streaming"]
    assert projected["supports_tools"]
  end

  test "canonicalizes equivalent JSON object forms and preserves list semantics" do
    atom_body = %{models: [%{slug: "gpt-a", nested: %{enabled: true}, values: [1, 1.0, nil]}]}

    string_body = %{
      "models" => [
        Map.new([
          {"values", [1, 1.0, nil]},
          {"nested", Map.new([{"enabled", true}])},
          {"slug", "gpt-a"}
        ])
      ]
    }

    assert CodexCatalog.etag(atom_body) == CodexCatalog.etag(string_body)

    refute CodexCatalog.etag(string_body) ==
             CodexCatalog.etag(put_in(string_body, ["models", Access.at(0), "values"], [1.0, 1, nil]))
  end

  test "rejects unsupported values and ambiguous equivalent object keys" do
    assert_raise ArgumentError, ~r/ambiguous JSON object key/, fn ->
      CodexCatalog.etag(%{:slug => "gpt-a", "slug" => "gpt-a"})
    end

    assert_raise ArgumentError, ~r/unsupported JSON object key/, fn ->
      CodexCatalog.etag(%{1 => "gpt-a"})
    end

    assert_raise ArgumentError, ~r/unsupported JSON value/, fn ->
      CodexCatalog.etag(%{"slug" => {:not, :json}})
    end
  end

  test "changes the revision for any final field or model membership change" do
    sources = [{model("gpt-a", %{}), pristine_source("gpt-a")}, {model("gpt-b", %{}), pristine_source("gpt-b")}]
    [{gpt_a, source_a} | _rest] = sources

    assert {:ok, result} = selected(sources)
    assert {:ok, changed_field} = selected([{gpt_a, Map.put(source_a, "description", "changed")} | tl(sources)])
    assert {:ok, changed_membership} = selected([hd(sources)])

    refute result.etag == changed_field.etag
    refute result.etag == changed_membership.etag
  end

  test "missing and malformed effective mode entries default to Full without source fallback" do
    source = Map.put(pristine_source("gpt-a"), "use_responses_lite", true)
    sources = [{model("gpt-a", %{}), source}]

    assert {:ok, explicit_lite} =
             CodexCatalog.build_selected_sources(sources, unrestricted_policy(), %{}, %{}, %{"gpt-a" => "lite"})

    assert get_in(explicit_lite.body, ["models", Access.at(0), "use_responses_lite"])

    for effective_modes <- [
          %{"other-model" => "full"},
          %{"gpt-a" => "auto"},
          %{"gpt-a" => true},
          %{gpt_a: "full"}
        ] do
      assert {:ok, result} =
               CodexCatalog.build_selected_sources(sources, unrestricted_policy(), %{}, %{}, effective_modes)

      refute get_in(result.body, ["models", Access.at(0), "use_responses_lite"])
      refute result.etag == explicit_lite.etag
    end
  end

  test "restrictive reasoning and tier policies preserve included pristine source entries" do
    model = model("gpt-a", %{})
    source = pristine_source("gpt-a")
    sources = [{model, source}]

    policies = [
      unrestricted_policy(),
      policy(maximum_reasoning_effort: "medium", enforced_service_tier: "default"),
      policy(enforced_reasoning_effort: "high", enforced_service_tier: "priority")
    ]

    results =
      Enum.map(policies, fn policy ->
        assert {:ok, result} =
                 CodexCatalog.build_selected_sources(sources, policy, %{}, %{}, %{})

        result
      end)

    assert Enum.uniq_by(results, & &1.body) == [hd(results)]
    assert Enum.uniq_by(results, & &1.etag) == [hd(results)]

    for result <- results do
      assert result.body == %{"models" => [source]}
      assert result.etag == CodexCatalog.etag(result.body)
    end
  end

  test "selected source catalog policy changes only model membership" do
    sources = [
      {model("gpt-a", %{}), pristine_source("gpt-a")},
      {model("gpt-b", %{}), pristine_source("gpt-b")}
    ]

    restrictive_policy =
      policy(
        allowed_model_identifiers: ["gpt-b"],
        maximum_reasoning_effort: "low",
        enforced_service_tier: "priority"
      )

    assert {:ok, unrestricted} =
             CodexCatalog.build_selected_sources(
               sources,
               unrestricted_policy(),
               %{},
               %{},
               %{}
             )

    assert {:ok, restricted} =
             CodexCatalog.build_selected_sources(sources, restrictive_policy, %{}, %{}, %{})

    assert restricted.body == %{"models" => [pristine_source("gpt-b")]}
    assert restricted.etag == CodexCatalog.etag(restricted.body)
    assert restricted.body["models"] == Enum.drop(unrestricted.body["models"], 1)
  end

  test "anchors the selected largest partition on its oldest assignment" do
    model = model("gpt-partition", %{"source_assignment_models" => %{}})
    shared = pristine_source("gpt-partition")
    divergent = Map.put(shared, "future_schema_field", %{"variant" => "divergent"})
    {oldest_id, matching_id, divergent_id} = assignment_ids()
    timestamp = ~U[2026-07-30 08:00:00.000000Z]

    model =
      put_source_models(model, %{
        divergent_id => divergent,
        matching_id => Map.put(shared, :source_assignment_ids, [matching_id]),
        oldest_id => Map.put(shared, "source_assignment_ids", [oldest_id])
      })

    candidates = %{
      model.id => [
        candidate(divergent_id, DateTime.add(timestamp, 60, :second)),
        candidate(matching_id, timestamp),
        candidate(oldest_id, timestamp)
      ]
    }

    assert [%{assignment_ids: selected_ids, digest: digest} = partition] =
             CodexCatalog.select_canonical_sources([model], candidates)

    assert selected_ids == Enum.sort([oldest_id, matching_id])
    assert is_binary(digest) and byte_size(digest) == 64

    assert {:ok, result} =
             CodexCatalog.build_selected_partitions(
               [partition],
               unrestricted_policy(),
               %{},
               %{},
               %{}
             )

    assert get_in(result.body, ["models", Access.at(0), "future_schema_field"]) ==
             shared["future_schema_field"]

    refute get_in(result.body, ["models", Access.at(0)])
           |> Map.has_key?("source_assignment_ids")

    assert result.etag == CodexCatalog.etag(result.body)
  end

  test "anchors on the chronologically oldest assignment across month boundaries" do
    model = model("gpt-boundary", %{"source_assignment_models" => %{}})
    source = pristine_source("gpt-boundary")
    {july_id, august_id, _unused} = assignment_ids()

    model =
      put_source_models(model, %{
        july_id => source,
        august_id => Map.put(source, "context_window", 111_111)
      })

    # Structural DateTime ordering compares day before month, so 2026-08-01
    # would sort before 2026-07-31; the anchor contract is chronological.
    candidates = %{
      model.id => [
        candidate(august_id, ~U[2026-08-01 00:00:00.000000Z]),
        candidate(july_id, ~U[2026-07-31 23:00:00.000000Z])
      ]
    }

    assert [partition] = CodexCatalog.select_canonical_sources([model], candidates)

    assert partition.assignment_ids == [july_id]
    assert partition.partition_count == 2
  end

  describe "quota-aware anchor selection" do
    setup do
      {anchor_id, sibling_id, alternate_id} = assignment_ids()
      source = pristine_source("gpt-anchored")

      model =
        "gpt-anchored"
        |> model(%{"source_assignment_models" => %{}})
        |> put_source_models(%{
          anchor_id => source,
          sibling_id => source,
          alternate_id => Map.put(source, "context_window", 111_111)
        })

      %{
        model: model,
        candidates: partition_candidates(model, [anchor_id, sibling_id, alternate_id]),
        anchor_id: anchor_id,
        sibling_id: sibling_id,
        alternate_id: alternate_id
      }
    end

    test "keeps the largest cohort when routable membership is tied", context do
      assert [partition] =
               CodexCatalog.select_canonical_sources([context.model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{context.model.id => MapSet.new([context.sibling_id, context.alternate_id])}
                 end
               )

      assert partition.assignment_ids == Enum.sort([context.anchor_id, context.sibling_id])
      assert partition.partition_count == 2
      refute partition.routable_selection?
    end

    test "moves to the only cohort with routable capacity", context do
      assert [partition] =
               CodexCatalog.select_canonical_sources([context.model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{context.model.id => MapSet.new([context.alternate_id])}
                 end
               )

      assert partition.assignment_ids == [context.alternate_id]
      assert partition.partition_count == 2
      assert partition.routable_selection?
      assert partition.source["context_window"] == 111_111
    end

    test "keeps the largest cohort when nothing is routable anywhere", context do
      assert [partition] =
               CodexCatalog.select_canonical_sources([context.model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{context.model.id => MapSet.new()}
                 end
               )

      assert partition.assignment_ids == Enum.sort([context.anchor_id, context.sibling_id])
      refute partition.routable_selection?
    end

    test "selects the largest cohort when no routability resolver is supplied", context do
      assert [partition] =
               CodexCatalog.select_canonical_sources([context.model], context.candidates)

      assert partition.assignment_ids == Enum.sort([context.anchor_id, context.sibling_id])
      assert partition.partition_count == 2
      refute partition.routable_selection?
    end

    test "never resolves routability for a single-partition model", context do
      single =
        update_source(context.model, context.alternate_id, &Map.delete(&1, "context_window"))

      assert [partition] =
               CodexCatalog.select_canonical_sources([single], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   flunk("routability must not be resolved for a single partition")
                 end
               )

      assert partition.partition_count == 1

      assert partition.assignment_ids ==
               Enum.sort([context.anchor_id, context.sibling_id, context.alternate_id])
    end

    test "admits reasoning variants and projects the routable family union", context do
      base_source = context.model.metadata["source_assignment_models"][context.anchor_id]

      max_source =
        base_source
        |> Map.put("default_reasoning_level", "max")
        |> Map.put("description", "alternate reasoning rollout")
        |> Map.put("supported_reasoning_levels", [
          %{"effort" => "low", "description" => "low"},
          %{"effort" => "max", "description" => "max"}
        ])

      model =
        put_source_models(context.model, %{
          context.anchor_id => base_source,
          context.sibling_id => base_source,
          context.alternate_id => max_source
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{
                     model.id =>
                       MapSet.new([
                         context.anchor_id,
                         context.sibling_id,
                         context.alternate_id
                       ])
                   }
                 end
               )

      assert partition.assignment_ids ==
               Enum.sort([context.anchor_id, context.sibling_id, context.alternate_id])

      refute partition.routable_selection?
      assert partition.source["default_reasoning_level"] == base_source["default_reasoning_level"]
      assert partition.source["description"] == base_source["description"]

      assert Enum.map(partition.source["supported_reasoning_levels"], & &1["effort"]) ==
               ~w(low high max)
    end

    test "excludes an unroutable variant from the advertised union without removing its allowance",
         context do
      base_source = context.model.metadata["source_assignment_models"][context.anchor_id]

      max_source =
        base_source
        |> Map.put("default_reasoning_level", "max")
        |> Map.delete("supported_reasoning_levels")
        |> Map.put("reasoning_efforts", ["low", "max"])

      model =
        put_source_models(context.model, %{
          context.anchor_id => base_source,
          context.sibling_id => base_source,
          context.alternate_id => max_source
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{model.id => MapSet.new([context.anchor_id, context.sibling_id])}
                 end
               )

      assert partition.assignment_ids ==
               Enum.sort([context.anchor_id, context.sibling_id, context.alternate_id])

      assert partition.source["default_reasoning_level"] == base_source["default_reasoning_level"]
      refute Map.has_key?(partition.source, "reasoning_efforts")
      refute "max" in Enum.map(partition.source["supported_reasoning_levels"], & &1["effort"])
    end

    test "does not admit a reasoning variant from a different capability family", context do
      max_source =
        context.model.metadata["source_assignment_models"][context.alternate_id]
        |> Map.put("supported_reasoning_levels", [
          %{"effort" => "low", "description" => "low"},
          %{"effort" => "max", "description" => "max"}
        ])

      model =
        put_source_models(context.model, %{
          context.anchor_id => context.model.metadata["source_assignment_models"][context.anchor_id],
          context.sibling_id => context.model.metadata["source_assignment_models"][context.sibling_id],
          context.alternate_id => max_source
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{
                     model.id =>
                       MapSet.new([
                         context.anchor_id,
                         context.sibling_id,
                         context.alternate_id
                       ])
                   }
                 end
               )

      assert partition.assignment_ids == Enum.sort([context.anchor_id, context.sibling_id])
      assert partition.source["context_window"] != max_source["context_window"]
      refute "max" in Enum.map(partition.source["supported_reasoning_levels"], & &1["effort"])
    end

    test "ranks aggregate capability-family capacity across reasoning variants", context do
      base_source = context.model.metadata["source_assignment_models"][context.anchor_id]

      max_source =
        Map.put(base_source, "supported_reasoning_levels", [
          %{"effort" => "low", "description" => "low"},
          %{"effort" => "max", "description" => "max"}
        ])

      older_singleton = Map.put(base_source, "context_window", 111_111)

      model =
        put_source_models(context.model, %{
          context.anchor_id => older_singleton,
          context.sibling_id => base_source,
          context.alternate_id => max_source
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{
                     model.id =>
                       MapSet.new([
                         context.anchor_id,
                         context.sibling_id,
                         context.alternate_id
                       ])
                   }
                 end
               )

      assert partition.assignment_ids == Enum.sort([context.sibling_id, context.alternate_id])
      assert partition.partition_count == 2
      assert partition.source["context_window"] != older_singleton["context_window"]

      assert Enum.map(partition.source["supported_reasoning_levels"], & &1["effort"]) ==
               ~w(low high max)
    end

    test "does not leak reasoning metadata from an unroutable family anchor", context do
      anchor_source =
        context.model.metadata["source_assignment_models"][context.anchor_id]
        |> Map.put("default_reasoning_level", "max")
        |> Map.put("supported_reasoning_levels", [
          %{"effort" => "max", "description" => "max"}
        ])

      routable_source =
        context.model.metadata["source_assignment_models"][context.sibling_id]
        |> Map.delete("default_reasoning_level")
        |> Map.delete("supported_reasoning_levels")

      model =
        put_source_models(context.model, %{
          context.anchor_id => anchor_source,
          context.sibling_id => routable_source,
          context.alternate_id => Map.put(anchor_source, "context_window", 111_111)
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{model.id => MapSet.new([context.sibling_id])}
                 end
               )

      assert partition.assignment_ids == Enum.sort([context.anchor_id, context.sibling_id])
      refute Map.has_key?(partition.source, "default_reasoning_level")
      refute Map.has_key?(partition.source, "supported_reasoning_levels")
      refute Map.has_key?(partition.source, "reasoning_efforts")
    end

    test "derives the default only from routable reasoning metadata", context do
      anchor_source =
        context.model.metadata["source_assignment_models"][context.anchor_id]
        |> Map.put("default_reasoning_level", "max")
        |> Map.put("supported_reasoning_levels", [
          %{"effort" => "max", "description" => "max"}
        ])

      routable_source =
        context.model.metadata["source_assignment_models"][context.sibling_id]
        |> Map.delete("default_reasoning_level")
        |> Map.put("supported_reasoning_levels", [
          %{"effort" => "max", "description" => "max"},
          %{"effort" => "low", "description" => "low"}
        ])

      model =
        put_source_models(context.model, %{
          context.anchor_id => anchor_source,
          context.sibling_id => routable_source,
          context.alternate_id => Map.put(anchor_source, "context_window", 111_111)
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   %{model.id => MapSet.new([context.sibling_id])}
                 end
               )

      assert partition.source["default_reasoning_level"] == "low"

      assert Enum.map(partition.source["supported_reasoning_levels"], & &1["effort"]) ==
               ~w(low max)
    end

    test "canonicalizes equivalent reasoning-level order for stable ETags", context do
      base_source = context.model.metadata["source_assignment_models"][context.anchor_id]

      first =
        base_source
        |> Map.put("default_reasoning_level", "high")
        |> Map.put("supported_reasoning_levels", [
          %{"effort" => "high", "description" => "high"},
          %{"effort" => "low", "description" => "low"}
        ])

      second =
        base_source
        |> Map.put("default_reasoning_level", "high")
        |> Map.put("supported_reasoning_levels", [
          %{"effort" => "low", "description" => "low"},
          %{"effort" => "high", "description" => "high"}
        ])

      first_model =
        put_source_models(context.model, %{
          context.anchor_id => first,
          context.sibling_id => second,
          context.alternate_id => Map.put(first, "context_window", 111_111)
        })

      second_model =
        put_source_models(context.model, %{
          context.anchor_id => first,
          context.sibling_id => second,
          context.alternate_id => Map.put(first, "context_window", 111_111)
        })

      first_partition =
        CodexCatalog.select_canonical_sources([first_model], context.candidates,
          routable_assignment_ids_by_model_id: fn ->
            %{first_model.id => MapSet.new([context.anchor_id])}
          end
        )

      second_partition =
        CodexCatalog.select_canonical_sources([second_model], context.candidates,
          routable_assignment_ids_by_model_id: fn ->
            %{second_model.id => MapSet.new([context.sibling_id])}
          end
        )

      assert [first_selected] = first_partition
      assert [second_selected] = second_partition
      assert first_selected.source == second_selected.source

      assert {:ok, first_catalog} =
               CodexCatalog.build_selected_partitions(
                 first_partition,
                 unrestricted_policy(),
                 %{},
                 %{},
                 %{}
               )

      assert {:ok, second_catalog} =
               CodexCatalog.build_selected_partitions(
                 second_partition,
                 unrestricted_policy(),
                 %{},
                 %{},
                 %{}
               )

      assert first_catalog.body == second_catalog.body
      assert first_catalog.etag == second_catalog.etag
    end

    test "resolves routability when only the reasoning default differs", context do
      base_source = context.model.metadata["source_assignment_models"][context.anchor_id]

      exhausted_anchor = Map.put(base_source, "default_reasoning_level", "high")
      routable_sibling = Map.put(base_source, "default_reasoning_level", "low")

      model =
        put_source_models(context.model, %{
          context.anchor_id => exhausted_anchor,
          context.sibling_id => routable_sibling,
          context.alternate_id => Map.put(base_source, "context_window", 111_111)
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   send(self(), :resolved_default_routability)
                   %{model.id => MapSet.new([context.sibling_id])}
                 end
               )

      assert_received :resolved_default_routability
      assert partition.source["default_reasoning_level"] == "low"
    end

    test "does not resolve routability for blank versus absent reasoning defaults", context do
      base_source = context.model.metadata["source_assignment_models"][context.anchor_id]

      model =
        put_source_models(context.model, %{
          context.anchor_id => Map.put(base_source, "default_reasoning_level", "   "),
          context.sibling_id => Map.delete(base_source, "default_reasoning_level"),
          context.alternate_id =>
            base_source
            |> Map.delete("default_reasoning_level")
            |> Map.delete("context_window")
        })

      assert [partition] =
               CodexCatalog.select_canonical_sources([model], context.candidates,
                 routable_assignment_ids_by_model_id: fn ->
                   flunk("blank and absent defaults must not trigger a quota read")
                 end
               )

      assert partition.partition_count == 1
    end
  end

  test "selects a newer routable majority instead of pinning an older singleton" do
    {old_id, new_first_id, new_second_id} = assignment_ids()
    source = pristine_source("gpt-rollout")
    updated = Map.put(source, "max_context_window", 872_000)
    timestamp = ~U[2026-08-17 08:00:00.000000Z]

    model =
      "gpt-rollout"
      |> model(%{"source_assignment_models" => %{}})
      |> put_source_models(%{
        old_id => source,
        new_first_id => updated,
        new_second_id => updated
      })

    candidates = %{
      model.id => [
        candidate(old_id, timestamp),
        candidate(new_first_id, DateTime.add(timestamp, 60, :second)),
        candidate(new_second_id, DateTime.add(timestamp, 120, :second))
      ]
    }

    assert [partition] =
             CodexCatalog.select_canonical_sources([model], candidates,
               routable_assignment_ids_by_model_id: fn ->
                 %{model.id => MapSet.new([old_id, new_first_id, new_second_id])}
               end
             )

    assert partition.assignment_ids == Enum.sort([new_first_id, new_second_id])
    assert partition.source["max_context_window"] == 872_000
    refute partition.routable_selection?
  end

  test "catalog resolver selects per-model partitions from one lazy map" do
    {primary_id, alternate_id, _unused_id} = assignment_ids()
    timestamp = ~U[2026-07-30 08:00:00.000000Z]

    model_a =
      "gpt-model-a"
      |> model(%{"source_assignment_models" => %{}})
      |> put_source_models(%{
        primary_id => pristine_source("gpt-model-a"),
        alternate_id => pristine_source("gpt-model-a") |> Map.put("context_window", 111_111)
      })

    model_b =
      "gpt-model-b"
      |> model(%{"source_assignment_models" => %{}})
      |> put_source_models(%{
        primary_id => pristine_source("gpt-model-b"),
        alternate_id => pristine_source("gpt-model-b") |> Map.put("context_window", 222_222)
      })

    candidates = %{
      model_a.id => [
        candidate(primary_id, timestamp),
        candidate(alternate_id, DateTime.add(timestamp, 1, :second))
      ],
      model_b.id => [
        candidate(primary_id, timestamp),
        candidate(alternate_id, DateTime.add(timestamp, 1, :second))
      ]
    }

    assert [partition_a, partition_b] =
             CodexCatalog.select_canonical_sources([model_a, model_b], candidates,
               routable_assignment_ids_by_model_id: fn ->
                 send(self(), :resolved_routability)

                 %{
                   model_a.id => MapSet.new([alternate_id]),
                   model_b.id => MapSet.new([primary_id])
                 }
               end
             )

    assert_received :resolved_routability
    refute_received :resolved_routability
    assert partition_a.assignment_ids == [alternate_id]
    assert partition_b.assignment_ids == [primary_id]
  end

  test "cosmetic source drift joins one partition without moving the served anchor body" do
    anchor_source = pristine_source("gpt-cosmetic")

    drifted =
      Map.merge(anchor_source, %{
        "default_reasoning_level" => "low",
        "default_service_tier" => "flex",
        "description" => "per-account copy",
        "visibility" => "internal"
      })

    {anchor_id, first_id, second_id} = assignment_ids()

    identical_model =
      "gpt-cosmetic"
      |> model(%{"source_assignment_models" => %{}})
      |> put_source_models(%{
        anchor_id => anchor_source,
        first_id => anchor_source,
        second_id => anchor_source
      })

    drifted_model =
      "gpt-cosmetic"
      |> model(%{"source_assignment_models" => %{}})
      |> put_source_models(%{
        anchor_id => anchor_source,
        first_id => drifted,
        second_id => Map.put(drifted, "description", "another per-account copy")
      })

    identical_candidates = partition_candidates(identical_model, [anchor_id, first_id, second_id])
    drifted_candidates = partition_candidates(drifted_model, [anchor_id, first_id, second_id])

    assert [%{assignment_ids: selected_ids, source: source}] =
             CodexCatalog.select_canonical_sources([drifted_model], drifted_candidates)

    assert selected_ids == Enum.sort([anchor_id, first_id, second_id])

    # The anchor still decides the served payload, so the advertised catalog is
    # byte-identical to the no-drift control.
    assert source == anchor_source

    identical = build_canonical([identical_model], identical_candidates)
    drifted_result = build_canonical([drifted_model], drifted_candidates)

    assert drifted_result.body == identical.body
    assert drifted_result.etag == identical.etag

    assert get_in(drifted_result.body, ["models", Access.at(0), "description"]) ==
             anchor_source["description"]
  end

  test "shell capability partitions preserve raw payload while isolating disabled" do
    source = pristine_source("gpt-shell-capability")

    shell_sources = [
      {"00000000-0000-4000-8000-000000000001", "default"},
      {"00000000-0000-4000-8000-000000000002", "local"},
      {"00000000-0000-4000-8000-000000000003", "shell_command"},
      {"00000000-0000-4000-8000-000000000004", "unified_exec"},
      {"00000000-0000-4000-8000-000000000005", "disabled"}
    ]

    model =
      "gpt-shell-capability"
      |> model(%{"source_assignment_models" => %{}})
      |> put_source_models(
        Map.new(shell_sources, fn {assignment_id, shell_type} ->
          {assignment_id, Map.put(source, "shell_type", shell_type)}
        end)
      )

    assignment_ids = Enum.map(shell_sources, &elem(&1, 0))
    shell_capable_ids = Enum.take(assignment_ids, 4)
    disabled_id = List.last(assignment_ids)
    candidates = partition_candidates(model, assignment_ids)
    shell_capable_source = Map.put(source, "shell_type", "default")
    disabled_source = Map.put(source, "shell_type", "disabled")

    assert [
             %{
               assignment_ids: ^shell_capable_ids,
               partition_count: 2,
               source: ^shell_capable_source
             }
           ] = CodexCatalog.select_canonical_sources([model], candidates)

    assert [
             %{
               assignment_ids: [^disabled_id],
               partition_count: 2,
               source: ^disabled_source
             }
           ] =
             CodexCatalog.select_canonical_sources([model], candidates,
               routable_assignment_ids_by_model_id: fn ->
                 %{model.id => MapSet.new([disabled_id])}
               end
             )
  end

  test "keeps body and ETag stable across matching anchor replacement and non-selected divergence" do
    model = model("gpt-stable", %{"source_assignment_models" => %{}})
    source = pristine_source("gpt-stable")
    {anchor_id, matching_id, divergent_id} = assignment_ids()
    timestamp = ~U[2026-07-30 08:00:00.000000Z]

    model =
      put_source_models(model, %{
        anchor_id => source,
        matching_id => source,
        divergent_id => Map.put(source, "future_schema_field", %{"variant" => "first"})
      })

    candidates = %{
      model.id => [
        candidate(anchor_id, timestamp),
        candidate(matching_id, DateTime.add(timestamp, 1, :second)),
        candidate(divergent_id, DateTime.add(timestamp, 2, :second))
      ]
    }

    first = build_canonical([model], candidates)

    without_anchor = %{candidates | model.id => tl(candidates[model.id])}
    replacement = build_canonical([model], without_anchor)

    diverged_model =
      update_source(model, divergent_id, fn source ->
        Map.put(source, "future_schema_field", %{"variant" => "second"})
      end)

    non_selected_changed = build_canonical([diverged_model], candidates)

    assert first.body == replacement.body
    assert first.etag == replacement.etag
    assert first.body == non_selected_changed.body
    assert first.etag == non_selected_changed.etag
  end

  test "changes the selected body for anchor content, overlays, and complete group fallback" do
    model = model("gpt-changing", %{"source_assignment_models" => %{}})
    selected = pristine_source("gpt-changing")
    fallback = Map.put(selected, "future_schema_field", %{"variant" => "fallback"})
    {anchor_id, matching_id, fallback_id} = assignment_ids()
    timestamp = ~U[2026-07-30 08:00:00.000000Z]

    model =
      put_source_models(model, %{
        anchor_id => selected,
        matching_id => selected,
        fallback_id => fallback
      })

    candidates = %{
      model.id => [
        candidate(anchor_id, timestamp),
        candidate(matching_id, DateTime.add(timestamp, 1, :second)),
        candidate(fallback_id, DateTime.add(timestamp, 2, :second))
      ]
    }

    initial = build_canonical([model], candidates)

    changed_anchor =
      model
      |> update_source(anchor_id, &Map.put(&1, "description", "changed anchor"))
      |> then(&build_canonical([&1], candidates))

    lite = build_canonical([model], candidates, %{}, %{"gpt-changing" => "lite"})

    fallback_only = %{
      candidates
      | model.id => [candidate(fallback_id, DateTime.add(timestamp, 2, :second))]
    }

    fallback_result = build_canonical([model], fallback_only)

    refute initial.etag == changed_anchor.etag
    refute initial.etag == lite.etag
    refute initial.etag == fallback_result.etag
    assert get_in(lite.body, ["models", Access.at(0), "use_responses_lite"])

    assert get_in(fallback_result.body, ["models", Access.at(0), "future_schema_field"]) ==
             fallback["future_schema_field"]
  end

  test "omits models without a valid routable pristine source partition" do
    model = model("gpt-invalid", %{})
    {valid_id, second_id, third_id} = assignment_ids()
    unsupported = %{"slug" => "gpt-invalid", "future" => {:not, :json}}
    ambiguous = %{:slug => "gpt-invalid", "slug" => "gpt-invalid"}

    model =
      put_source_models(model, %{
        valid_id => unsupported,
        second_id => ambiguous,
        third_id => "not-a-map",
        "not-a-uuid" => pristine_source("gpt-invalid")
      })

    candidates = %{
      model.id => [
        candidate(valid_id),
        candidate(second_id),
        candidate(third_id),
        candidate("not-a-uuid")
      ]
    }

    assert CodexCatalog.select_canonical_sources([model], candidates) == []
    assert build_canonical([model], candidates).body == %{"models" => []}
  end

  defp model(slug, metadata) do
    %Model{
      upstream_model_id: slug,
      exposed_model_id: slug,
      display_name: slug,
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      metadata: metadata
    }
  end

  defp unrestricted_policy do
    %{
      allowed_model_identifiers: nil,
      enforced_model_identifier: nil,
      enforced_reasoning_effort: nil,
      maximum_reasoning_effort: nil
    }
  end

  defp policy(overrides), do: Map.merge(unrestricted_policy(), Map.new(overrides))

  defp selected(sources),
    do: CodexCatalog.build_selected_sources(sources, unrestricted_policy(), %{}, %{}, %{})

  defp pristine_source(slug) do
    %{
      "slug" => slug,
      "description" => "synthetic",
      "multi_agent_version" => "v2",
      "default_reasoning_level" => "high",
      "supported_reasoning_levels" => [
        %{"effort" => "low", "description" => "low"},
        %{"effort" => "high", "description" => "high"}
      ],
      "default_service_tier" => "priority",
      "service_tiers" => [%{"id" => "priority", "name" => "Priority"}],
      "future_schema_field" => %{"nested" => [true, 7, nil]},
      "use_responses_lite" => false
    }
  end

  defp assignment_ids do
    {
      "00000000-0000-4000-8000-000000000001",
      "00000000-0000-4000-8000-000000000002",
      "00000000-0000-4000-8000-000000000003"
    }
  end

  defp candidate(id, created_at \\ ~U[2026-07-30 08:00:00.000000Z]) do
    {%PoolUpstreamAssignment{id: id, created_at: created_at}, nil}
  end

  # Oldest assignment first, then one second apart, so the partition anchor is
  # the head of `assignment_ids`.
  defp partition_candidates(model, assignment_ids) do
    base = ~U[2026-07-30 08:00:00.000000Z]

    candidates =
      assignment_ids
      |> Enum.with_index()
      |> Enum.map(fn {assignment_id, index} ->
        candidate(assignment_id, DateTime.add(base, index, :second))
      end)

    %{model.id => candidates}
  end

  defp put_source_models(model, source_models) do
    %{
      model
      | id: model.id || Ecto.UUID.generate(),
        metadata: %{"source_assignment_models" => source_models}
    }
  end

  defp update_source(model, assignment_id, update) do
    update_in(model.metadata["source_assignment_models"][assignment_id], update)
  end

  defp build_canonical(models, candidates, context_overrides \\ %{}, modes \\ %{}) do
    partitions = CodexCatalog.select_canonical_sources(models, candidates)

    assert {:ok, result} =
             CodexCatalog.build_selected_partitions(
               partitions,
               unrestricted_policy(),
               %{},
               context_overrides,
               modes
             )

    result
  end

  defp gpt56_context_metadata do
    %{
      "context_window" => 272_000,
      "max_context_window" => 872_000,
      "effective_context_window_percent" => 95,
      "auto_compact_token_limit" => nil
    }
  end
end
