defmodule CodexPooler.Gateway.Metadata.CodexCatalogTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  test "build/3 is independent of operational context-window settings" do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    on_exit(fn -> restore_operational_settings(previous_env) end)

    inputs = {[context_model()], unrestricted_policy(), %{}}

    put_context_window_override(128_000)
    first = apply(CodexCatalog, :build, Tuple.to_list(inputs))

    put_context_window_override(256_000)
    second = apply(CodexCatalog, :build, Tuple.to_list(inputs))

    assert first.body == second.body
    assert first.etag == second.etag
  end

  test "keeps the existing effective context projection contract" do
    result = CodexCatalog.build([context_model()], unrestricted_policy(), %{})
    [model] = result.body["models"]

    assert model["context_window"] == 258_400
    assert model["max_context_window"] == 272_000
    assert model["auto_compact_token_limit"] == 232_560
    assert model["effective_context_window_percent"] == 95
  end

  test "projects GPT-5.6 raw context into the effective Codex metadata" do
    result =
      CodexCatalog.build(
        [model("gpt-5.6-context", gpt56_context_metadata())],
        unrestricted_policy(),
        %{},
        %{}
      )

    [model] = result.body["models"]

    assert model["context_window"] == 258_400
    assert model["max_context_window"] == 272_000
    assert model["auto_compact_token_limit"] == 232_560
    assert model["effective_context_window_percent"] == 95
  end

  test "builds a slug-sorted catalog with an exact deterministic weak revision" do
    result = CodexCatalog.build(Enum.reverse(models()), unrestricted_policy(), %{})

    assert Enum.map(result.body["models"], & &1["slug"]) == ["gpt-a", "gpt-b"]
    assert result.etag =~ ~r/^W\/"cp-models-v1-[0-9a-f]{64}"$/
    assert result == CodexCatalog.build(models(), unrestricted_policy(), %{})
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
             CodexCatalog.etag(
               put_in(string_body, ["models", Access.at(0), "values"], [1.0, 1, nil])
             )
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
    result = CodexCatalog.build(models(), unrestricted_policy(), %{})

    changed_field =
      CodexCatalog.build(
        [model("gpt-a", %{"description" => "changed"})],
        unrestricted_policy(),
        %{}
      )

    changed_membership = CodexCatalog.build([hd(models())], unrestricted_policy(), %{})

    refute result.etag == changed_field.etag
    refute result.etag == changed_membership.etag
  end

  test "projects unrestricted, maximum, and enforced reasoning from normalized policy" do
    model = model("gpt-a", reasoning_metadata())

    unrestricted = CodexCatalog.build([model], unrestricted_policy(), %{})
    maximum = CodexCatalog.build([model], policy(maximum_reasoning_effort: "medium"), %{})
    enforced = CodexCatalog.build([model], policy(enforced_reasoning_effort: "high"), %{})

    assert reasoning_projection(unrestricted) == {~w(low medium high), "medium"}
    assert reasoning_projection(maximum) == {~w(low medium), "medium"}
    assert reasoning_projection(enforced) == {["high"], "high"}
    refute unrestricted.etag == maximum.etag
    refute maximum.etag == enforced.etag
  end

  test "different policies with the same final body have the same revision" do
    model = model("gpt-a", reasoning_metadata())

    unrestricted = CodexCatalog.build([model], unrestricted_policy(), %{})
    maximum = CodexCatalog.build([model], policy(maximum_reasoning_effort: "ultra"), %{})

    assert unrestricted.body == maximum.body
    assert unrestricted.etag == maximum.etag
  end

  test "effective serving modes determine only the emitted Lite boolean and final-body revision" do
    aggregate_lite_model = model("gpt-a", %{"use_responses_lite" => true})
    aggregate_full_model = model("gpt-a", %{"use_responses_lite" => false})

    aggregate_lite =
      CodexCatalog.build(
        [aggregate_lite_model],
        unrestricted_policy(),
        %{},
        %{}
      )

    explicit_lite =
      CodexCatalog.build(
        [aggregate_full_model],
        unrestricted_policy(),
        %{},
        %{},
        %{"gpt-a" => "lite"}
      )

    explicit_full =
      CodexCatalog.build(
        [aggregate_lite_model],
        unrestricted_policy(),
        %{},
        %{},
        %{"gpt-a" => "full"}
      )

    assert get_in(aggregate_lite.body, ["models", Access.at(0), "use_responses_lite"])
    assert explicit_lite.body == aggregate_lite.body
    assert explicit_lite.etag == aggregate_lite.etag

    refute get_in(explicit_full.body, ["models", Access.at(0), "use_responses_lite"])
    refute explicit_full.body == aggregate_lite.body
    refute explicit_full.etag == aggregate_lite.etag

    assert get_in(explicit_full.body, ["models", Access.at(0), "supports_parallel_tool_calls"])
  end

  test "missing and malformed effective mode entries default to Full without aggregate fallback" do
    aggregate_lite_model = model("gpt-a", %{"use_responses_lite" => true})

    aggregate_fallback =
      CodexCatalog.build([aggregate_lite_model], unrestricted_policy(), %{}, %{})

    for effective_modes <- [
          %{"other-model" => "full"},
          %{"gpt-a" => "auto"},
          %{"gpt-a" => true},
          %{gpt_a: "full"}
        ] do
      result =
        CodexCatalog.build(
          [aggregate_lite_model],
          unrestricted_policy(),
          %{},
          %{},
          effective_modes
        )

      refute get_in(result.body, ["models", Access.at(0), "use_responses_lite"])
      refute result.body == aggregate_fallback.body
      refute result.etag == aggregate_fallback.etag
    end
  end

  test "filters the complete routable list through normalized model policy" do
    result =
      CodexCatalog.build(
        models(),
        unrestricted_policy()
        |> Map.put(:allowed_model_identifiers, ["gpt-b"])
        |> Map.put(:api_key_id, "ignored-source-identity"),
        %{}
      )

    assert Enum.map(result.body["models"], & &1["slug"]) == ["gpt-b"]

    assert result.etag ==
             CodexCatalog.build(
               Enum.reverse(models()),
               Map.delete(result_policy("gpt-b"), :api_key_id),
               %{}
             ).etag
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

  test "selects the canonical partition containing the oldest routable assignment anchor" do
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

  defp models do
    [
      model("gpt-a", %{"reasoning_levels" => [%{"effort" => "low"}, %{"effort" => "high"}]}),
      model("gpt-b", %{"reasoning_levels" => [%{"effort" => "medium"}]})
    ]
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

  defp result_policy(model_identifier) do
    Map.put(unrestricted_policy(), :allowed_model_identifiers, [model_identifier])
  end

  defp reasoning_metadata do
    %{
      "default_reasoning_level" => "medium",
      "supported_reasoning_levels" => [
        %{"effort" => "low", "description" => "low"},
        %{"effort" => "medium", "description" => "medium"},
        %{"effort" => "high", "description" => "high"}
      ]
    }
  end

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

  defp reasoning_projection(result) do
    [model] = result.body["models"]

    {Enum.map(model["supported_reasoning_levels"], & &1["effort"]),
     model["default_reasoning_level"]}
  end

  defp context_model do
    model("gpt-context", %{
      "context_window" => 272_000,
      "max_context_window" => 272_000,
      "auto_compact_token_limit" => nil
    })
  end

  defp gpt56_context_metadata do
    %{
      "context_window" => 272_000,
      "max_context_window" => 272_000,
      "effective_context_window_percent" => 95,
      "auto_compact_token_limit" => nil
    }
  end

  defp put_context_window_override(context_window) do
    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        model_context_window_overrides: %{"gpt-context" => context_window}
      }
    )
  end

  defp restore_operational_settings(nil),
    do: Application.delete_env(:codex_pooler, OperationalSettings)

  defp restore_operational_settings(previous_env),
    do: Application.put_env(:codex_pooler, OperationalSettings, previous_env)
end
