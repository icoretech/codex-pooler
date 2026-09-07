defmodule CodexPooler.Gateway.Routing.ModelMetadataBoundariesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.ModelMetadata

  test "pricing context buckets cap and promote only applicable advertised windows" do
    model = %Model{exposed_model_id: "sample-model", upstream_model_id: "sample-model"}

    for {buckets, metadata, expected} <- [
          {["short_context"], %{"context_window" => 200_000}, 128_000},
          {["short_context"], %{"context_window" => 50_000}, 50_000},
          {["long_context"], %{"context_window" => 200_000, "max_context_window" => 300_000},
           300_000},
          {["long_context"], %{"context_window" => 200_000}, 200_000},
          {["standard"], %{"context_window" => 200_000}, 200_000}
        ] do
      result =
        ModelMetadata.apply_context_window_policy(
          metadata,
          model,
          %{"sample-model" => buckets},
          %{}
        )

      assert result["context_window"] == expected
    end

    metadata = %{"context_window" => 200_000, "effective_context_window_percent" => 80}
    assert ModelMetadata.apply_context_window_policy(metadata, model, %{}) == metadata
  end

  test "capability flags recognize explicit support and explicit streaming denial" do
    for value <- [false, "false", "unsupported", "disabled"] do
      assert ModelMetadata.streaming_explicitly_unsupported?(%{
               "capabilities" => %{"streaming" => value}
             })

      assert ModelMetadata.streaming_explicitly_unsupported?(%{"supports_streaming" => value})
    end

    refute ModelMetadata.streaming_explicitly_unsupported?(%{"streaming" => true})

    for value <- [true, "true", "enabled", "supported"] do
      assert ModelMetadata.supports_tools?(%{"capabilities" => %{"tools" => value}})
      assert ModelMetadata.supports_tools?(%{"supports_tools" => value})
      assert ModelMetadata.supports_reasoning?(%{"capabilities" => %{"reasoning" => value}})
      assert ModelMetadata.supports_reasoning?(%{"supports_reasoning" => value})
    end

    assert ModelMetadata.supports_reasoning?(%{"reasoning_efforts" => "high"})

    assert ModelMetadata.input_modalities(%{
             "input_modalities" => %{"primary" => ["text"], "secondary" => "image"}
           })
           |> Enum.sort() == ["image", "text"]
  end

  test "advertised typed fields and inferred default survive payload serialization" do
    for mode <- ["direct", "code_mode", "code_mode_only"] do
      model = %Model{
        supports_reasoning: true,
        metadata: %{
          "tool_mode" => mode,
          "supported_reasoning_levels" => ["high"],
          "model_messages" => %{"notice" => "sample"},
          "truncation_policy" => %{"mode" => "tokens", "limit" => 25},
          "service_tiers" => ["default"]
        }
      }

      payload =
        ModelMetadata.codex_model_payload(model, %{}, nil, %{})
        |> CodexPooler.JSON.encode!()
        |> CodexPooler.JSON.decode!()

      assert payload["tool_mode"] == mode
      assert payload["default_reasoning_level"] == "high"
      assert payload["model_messages"] == %{"notice" => "sample"}
      assert payload["truncation_policy"] == %{"mode" => "tokens", "limit" => 25}
      assert payload["service_tiers"] == ["default"]
    end
  end

  test "malformed input modalities do not crash the advertised model payload" do
    model = %Model{
      exposed_model_id: "sample-model",
      metadata: %{
        "input_modalities" => ["text", %{"unexpected" => true}, ["image"], nil, " image "]
      }
    }

    payload = ModelMetadata.codex_model_payload(model, %{}, nil, %{})
    assert payload["input_modalities"] == ["text", "image"]

    assert CodexPooler.JSON.decode!(CodexPooler.JSON.encode!(payload))["input_modalities"] == [
             "text",
             "image"
           ]
  end

  test "context policy respects explicit overrides and safe compaction bounds" do
    model = %Model{exposed_model_id: "sample-model"}

    for {limit, expected} <- [{20, 20}, {500, 90}, {nil, 90}, {"50", 90}] do
      metadata = %{"context_window" => 1_000, "auto_compact_token_limit" => limit}

      result =
        ModelMetadata.apply_context_window_policy(metadata, model, %{}, %{"sample-model" => 100})

      assert result["context_window"] == 100
      assert result["max_context_window"] == 100
      assert result["auto_compact_token_limit"] == expected
      assert result["effective_context_window_percent"] == 95
    end
  end

  test "reasoning metadata keeps descriptions while dropping blanks and duplicates" do
    model = %Model{
      supports_reasoning: true,
      metadata: %{
        "supported_reasoning_levels" => [
          %{effort: " HIGH ", description: "Detailed"},
          %{effort: " "},
          %{"effort" => ""},
          " ",
          12,
          "high",
          " future "
        ],
        "default_reasoning_level" => " future "
      }
    }

    assert ModelMetadata.reasoning_level_maps_and_default(model) == {
             [
               %{"effort" => "high", description: "Detailed"},
               %{"effort" => "future", "description" => "future"}
             ],
             "future"
           }

    assert ModelMetadata.reasoning_levels_and_default(model) == {["high", "future"], " future "}

    assert ModelMetadata.reasoning_level_maps_and_default(%Model{supports_reasoning: false}) ==
             {[], nil}

    assert {[_ | _], "medium"} =
             ModelMetadata.reasoning_level_maps_and_default(%Model{supports_reasoning: true})
  end

  test "capability helpers reject absent or malformed evidence" do
    for value <- [nil, [], "invalid"] do
      refute ModelMetadata.has_capability_evidence?(value)
      refute ModelMetadata.supports_audio_transcription?(value)
      refute ModelMetadata.supports_image_input?(value)
      refute ModelMetadata.supports_tools?(value)
      refute ModelMetadata.supports_reasoning?(value)
      refute ModelMetadata.streaming_explicitly_unsupported?(value)
      assert ModelMetadata.supports_reasoning_summary_parameter?(value)
      assert ModelMetadata.metadata_map(value, "capabilities") == %{}
      assert ModelMetadata.input_modalities(value) == ["text"]
      refute ModelMetadata.supports_image_detail_original?(value)
    end

    model = %Model{
      metadata: %{
        "upstream_model" => %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
      }
    }

    assert ModelMetadata.has_capability_evidence?(model)
    assert ModelMetadata.supports_audio_transcription?(model)
    refute ModelMetadata.supports_image_input?(model)
    assert ModelMetadata.supports_reasoning_summary_parameter?(model)

    assert ModelMetadata.input_modalities(%{"capabilities" => %{"vision" => true}}) == [
             "text",
             "image"
           ]

    assert ModelMetadata.input_modalities(%{}) == ["text"]
    assert ModelMetadata.has_capability_evidence?(%{"capabilities" => %{"tools" => true}})
    refute ModelMetadata.assignment_source?(model, nil)
  end

  test "payload defaults discard invalid typed metadata" do
    payload =
      ModelMetadata.codex_model_payload(
        %Model{
          metadata: %{
            "minimal_client_version" => :invalid,
            "tool_mode" => "unknown",
            "default_service_tier" => 1,
            "priority" => "1",
            "model_messages" => [],
            "supports_image_detail_original" => false
          }
        },
        %{},
        nil,
        %{}
      )

    assert payload["minimal_client_version"] == nil
    assert payload["tool_mode"] == nil
    assert payload["priority"] == 0
    assert payload["model_messages"] == nil
    refute payload["supports_image_detail_original"]
  end
end
