defmodule CodexPooler.Gateway.Routing.ModelMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.MetadataProjection
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.ModelMetadata

  test "normalizes unsupported capability terms without raising" do
    assert ModelMetadata.normalize_capability_value(%{mode: "audio"}) == ""
    assert ModelMetadata.normalize_capability_value(["image"]) == ""
  end

  test "reads supported compatibility metadata from atom keys" do
    assert ModelMetadata.input_modalities(%{input_modalities: [:text, "image"]}) == [
             "text",
             "image"
           ]

    assert ModelMetadata.supports_audio_transcription?(%{
             capabilities: %{audio_input: true, transcription: "enabled"}
           })

    assert ModelMetadata.metadata_map(%{capabilities: %{vision_input: true}}, "capabilities") ==
             %{vision_input: true}
  end

  test "codex model payload exposes comp_hash only for non-empty string metadata" do
    assert model_payload(%{"comp_hash" => " comp-fixture-hash "})["comp_hash"] ==
             "comp-fixture-hash"

    for metadata <- [
          %{},
          %{"comp_hash" => ""},
          %{"comp_hash" => "   "},
          %{"comp_hash" => 123},
          %{"comp_hash" => ["comp-fixture-hash"]},
          %{"comp_hash" => %{"value" => "comp-fixture-hash"}}
        ] do
      refute Map.has_key?(model_payload(metadata), "comp_hash")
    end
  end

  test "codex model payload applies current and legacy reasoning-summary semantics" do
    cases = [
      {:absent, %{}, nil, nil, true},
      {true, %{"supports_reasoning_summary_parameter" => true}, nil, nil, true},
      {false, %{"supports_reasoning_summary_parameter" => false}, false, nil, false},
      {:malformed, %{"supports_reasoning_summary_parameter" => "false"}, nil, nil, true},
      {:legacy_true, %{"supports_reasoning_summaries" => true}, nil, true, true},
      {:legacy_false, %{"supports_reasoning_summaries" => false}, nil, false, true},
      {:legacy_malformed, %{"supports_reasoning_summaries" => "true"}, nil, nil, true},
      {:nested_false, %{"upstream_model" => %{"supports_reasoning_summary_parameter" => false}},
       false, nil, false}
    ]

    for {_case_label, metadata, current_value, legacy_value, capability?} <- cases do
      payload = model_payload(metadata)
      encoded_payload = payload |> Jason.encode!() |> Jason.decode!()

      assert Map.get(payload, "supports_reasoning_summary_parameter") == current_value
      assert Map.get(payload, "supports_reasoning_summaries") == legacy_value
      assert ModelMetadata.supports_reasoning_summary_parameter?(metadata) == capability?

      if is_boolean(legacy_value) do
        assert Map.has_key?(payload, "supports_reasoning_summaries")
        assert encoded_payload["supports_reasoning_summaries"] == legacy_value
      else
        refute Map.has_key?(payload, "supports_reasoning_summaries")
        refute Map.has_key?(encoded_payload, "supports_reasoning_summaries")
      end
    end
  end

  test "selected assignment reasoning-summary capability overrides model metadata" do
    assignment_id = Ecto.UUID.generate()

    model =
      reasoning_model(%{
        "supports_reasoning_summary_parameter" => true,
        "source_assignment_models" => %{
          assignment_id => %{"supports_reasoning_summary_parameter" => false}
        }
      })

    assert model
           |> ModelMetadata.selected_assignment_metadata(assignment_id)
           |> ModelMetadata.supports_reasoning_summary_parameter?() == false

    malformed_model =
      put_in(
        model.metadata["source_assignment_models"][assignment_id][
          "supports_reasoning_summary_parameter"
        ],
        "false"
      )

    assert malformed_model
           |> ModelMetadata.selected_assignment_metadata(assignment_id)
           |> ModelMetadata.supports_reasoning_summary_parameter?()
  end

  test "assignment source lookup uses only exact per-assignment provenance" do
    assignment_from_ids = Ecto.UUID.generate()
    assignment_from_models = Ecto.UUID.generate()
    aggregate_only_assignment = Ecto.UUID.generate()

    model =
      reasoning_model(%{
        "source_assignment_ids" => [assignment_from_ids],
        "source_assignment_models" => %{assignment_from_models => %{"supports_responses" => true}},
        "upstream_model" => %{
          "source_assignment_ids" => [aggregate_only_assignment],
          "source_assignment_models" => %{aggregate_only_assignment => %{}}
        }
      })

    assert ModelMetadata.assignment_source?(model, assignment_from_ids)
    assert ModelMetadata.assignment_source?(model, assignment_from_models)
    refute ModelMetadata.assignment_source?(model, aggregate_only_assignment)
    refute ModelMetadata.assignment_source?(model, Ecto.UUID.generate())
  end

  test "assignment source lookup rejects malformed provenance metadata" do
    assignment_id = Ecto.UUID.generate()

    refute ModelMetadata.assignment_source?(
             reasoning_model(%{
               "source_assignment_ids" => assignment_id,
               "source_assignment_models" => [assignment_id]
             }),
             assignment_id
           )
  end

  test "codex model payload preserves all advertised GPT-5.6 reasoning levels" do
    efforts = ~w(low medium high xhigh max ultra)

    payload =
      model_payload(%{
        "default_reasoning_level" => "low",
        "supported_reasoning_levels" => efforts
      })

    assert payload["default_reasoning_level"] == "low"

    assert payload["supported_reasoning_levels"] ==
             Enum.map(efforts, &%{"effort" => &1, "description" => &1})
  end

  test "codex model payload applies an optional reasoning metadata projection verbatim" do
    projection = %MetadataProjection{
      levels: [
        %{"effort" => "low", "description" => "Quick"},
        %{"effort" => "medium", "description" => "Balanced"}
      ],
      default_effort: "medium"
    }

    payload =
      %{"supported_reasoning_levels" => ~w(low medium high), "default_reasoning_level" => "high"}
      |> reasoning_model()
      |> ModelMetadata.codex_model_payload(%{}, projection)

    assert payload["supported_reasoning_levels"] == projection.levels
    assert payload["default_reasoning_level"] == "medium"
  end

  test "codex model payload keeps a reasoning model visible with an empty projection" do
    projection = %MetadataProjection{levels: [], default_effort: nil}

    payload =
      %{"supported_reasoning_levels" => ~w(low medium), "default_reasoning_level" => "medium"}
      |> reasoning_model()
      |> ModelMetadata.codex_model_payload(%{}, projection)

    assert payload["slug"] == "gpt-test-model"
    assert payload["supported_reasoning_levels"] == []
    assert is_nil(payload["default_reasoning_level"])
  end

  test "effective serving mode overrides aggregate Lite metadata without changing tool capability" do
    cases = [
      {:full_overrides_true, %{"use_responses_lite" => true}, "full", false},
      {:lite_overrides_false, %{"use_responses_lite" => false}, "lite", true},
      {:missing_defaults_full, %{"use_responses_lite" => true}, nil, false},
      {:missing_stays_full, %{"use_responses_lite" => false}, nil, false},
      {:malformed_defaults_full, %{"use_responses_lite" => true}, "auto", false},
      {:malformed_falls_back_false, %{"use_responses_lite" => false}, :lite, false}
    ]

    for {_case_label, metadata, effective_mode, expected_lite?} <- cases do
      payload =
        metadata
        |> reasoning_model()
        |> ModelMetadata.codex_model_payload(%{}, nil, %{}, effective_mode)

      assert payload["use_responses_lite"] == expected_lite?
      assert payload["supports_parallel_tool_calls"]
    end

    assert model_payload(%{"use_responses_lite" => true})["use_responses_lite"]
  end

  test "returns explicit or fallback reasoning levels with their default" do
    explicit =
      reasoning_model(%{
        "supported_reasoning_levels" => ["low", "high"],
        "default_reasoning_level" => "high"
      })

    fallback = reasoning_model(%{})

    assert ModelMetadata.reasoning_levels_and_default(explicit) == {~w(low high), "high"}

    assert ModelMetadata.reasoning_levels_and_default(fallback) ==
             {~w(low medium high xhigh), "medium"}
  end

  test "returns effective reasoning maps with descriptions and canonical semantics" do
    model =
      reasoning_model(%{
        "supported_reasoning_levels" => [
          %{"effort" => "medium", "description" => "Balanced"},
          %{"effort" => " HIGH ", "description" => "Deep", "extra" => "preserved"},
          %{"effort" => "low", "description" => "Quick"}
        ],
        "default_reasoning_level" => " HIGH "
      })

    assert ModelMetadata.reasoning_level_maps_and_default(model) ==
             {[
                %{"effort" => "medium", "description" => "Balanced"},
                %{"effort" => "high", "description" => "Deep", "extra" => "preserved"},
                %{"effort" => "low", "description" => "Quick"}
              ], "high"}
  end

  defp model_payload(metadata) do
    metadata
    |> reasoning_model()
    |> ModelMetadata.codex_model_payload(%{})
  end

  defp reasoning_model(metadata) do
    %Model{
      upstream_model_id: "upstream-model",
      exposed_model_id: "gpt-test-model",
      display_name: "GPT Test Model",
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      metadata: metadata
    }
  end
end
