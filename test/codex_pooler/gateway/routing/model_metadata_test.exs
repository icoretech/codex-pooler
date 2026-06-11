defmodule CodexPooler.Gateway.Routing.ModelMetadataTest do
  use ExUnit.Case, async: true

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

  defp model_payload(metadata) do
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
    |> ModelMetadata.codex_model_payload(%{})
  end
end
