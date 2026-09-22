defmodule CodexPooler.Gateway.Routing.ModelMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.ModelMetadata

  test "effective context follows native context precedence and rejects invalid limits" do
    for {metadata, expected} <- [
          {%{"max_context_window" => 200_000}, 190_000},
          {%{"context_window" => nil, "max_context_window" => 200_000}, 190_000},
          {%{"context_window" => 100_000, "max_context_window" => 200_000}, 95_000},
          {%{"max_context_window" => 200_000, "effective_context_window_percent" => 90}, 180_000},
          {%{"context_window" => 0, "max_context_window" => 200_000}, nil},
          {%{"context_window" => "100000", "max_context_window" => 200_000}, nil},
          {%{"context_window" => false, "max_context_window" => 200_000}, nil},
          {%{"max_context_window" => 0}, nil},
          {%{"max_context_window" => -1}, nil},
          {%{"max_context_window" => "200000"}, nil},
          {%{"max_context_window" => 200_000, "effective_context_window_percent" => 101}, nil},
          {%{}, nil},
          {nil, nil}
        ] do
      assert ModelMetadata.effective_context_window(metadata) == expected
    end
  end

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
