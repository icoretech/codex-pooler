defmodule CodexPooler.Catalog.ModelInfoTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.ModelInfo

  test "projects description and exceptional facts from the selected source" do
    metadata = %{
      "source_assignment_models" => %{
        "assignment-a" => %{
          "description" => "Synthetic work routing alias.",
          "visibility" => "hide",
          "supported_in_api" => false,
          "context_window" => 272_000,
          "max_context_window" => 872_000,
          "effective_context_window_percent" => 95
        },
        "assignment-b" => %{
          "description" => "Different source description.",
          "visibility" => "list",
          "supported_in_api" => true
        }
      }
    }

    assert ModelInfo.from_metadata(metadata, ["assignment-a"]) == %{
             description: "Synthetic work routing alias.",
             description_state: :available,
             visibility: :hidden,
             api_support: :unsupported,
             context_profiles: [
               %{
                 raw_window: 272_000,
                 usable_window: 258_400,
                 raw_max_window: 872_000,
                 usable_max_window: 828_400,
                 effective_percent: 95
               }
             ]
           }
  end

  test "reports conflicting per-source metadata instead of choosing an arbitrary source" do
    metadata = %{
      "source_assignment_models" => %{
        "assignment-a" => %{
          "description" => "First description.",
          "visibility" => "hide",
          "supported_in_api" => false
        },
        "assignment-b" => %{
          "description" => "Second description.",
          "visibility" => "list",
          "supported_in_api" => true
        }
      }
    }

    assert ModelInfo.from_metadata(metadata, ["assignment-a", "assignment-b"]) == %{
             description: nil,
             description_state: :conflicting,
             visibility: :mixed,
             api_support: :mixed
           }
  end

  test "uses the merged upstream model only when per-source metadata is absent" do
    metadata = %{
      "upstream_model" => %{
        "description" => "Fallback catalog description.",
        "visibility" => "list",
        "supported_in_api" => true
      }
    }

    assert ModelInfo.from_metadata(metadata, []) == %{
             description: "Fallback catalog description.",
             description_state: :available,
             visibility: :listed,
             api_support: :supported
           }
  end

  test "merges assignment projections without inventing missing facts" do
    hidden =
      ModelInfo.from_sources([
        %{
          "description" => "Shared description.",
          "visibility" => "hide",
          "supported_in_api" => false
        }
      ])

    listed =
      ModelInfo.from_sources([
        %{
          "description" => "Shared description.",
          "visibility" => "list",
          "supported_in_api" => true
        }
      ])

    assert ModelInfo.merge([hidden, listed]) == %{
             description: "Shared description.",
             description_state: :available,
             visibility: :mixed,
             api_support: :mixed
           }

    refute ModelInfo.present?(ModelInfo.empty())
    assert ModelInfo.present?(hidden)
  end

  test "keeps distinct context profiles when upstream source windows differ" do
    info =
      ModelInfo.from_sources([
        %{"context_window" => 272_000, "max_context_window" => 272_000},
        %{
          "context_window" => 272_000,
          "max_context_window" => 872_000,
          "effective_context_window_percent" => 90
        }
      ])

    assert info.context_profiles == [
             %{
               raw_window: 272_000,
               usable_window: 258_400,
               raw_max_window: 272_000,
               usable_max_window: 258_400,
               effective_percent: 95
             },
             %{
               raw_window: 272_000,
               usable_window: 244_800,
               raw_max_window: 872_000,
               usable_max_window: 784_800,
               effective_percent: 90
             }
           ]

    assert ModelInfo.present?(info)
  end

  test "keeps minimum client versions and the latest real catalog observation" do
    older =
      ModelInfo.from_sources([
        %{"minimal_client_version" => "0.144.0"}
      ])
      |> ModelInfo.with_catalog_updated_at(~U[2026-08-22 00:30:00Z])

    newer =
      ModelInfo.from_sources([
        %{"minimal_client_version" => "0.142.2"}
      ])
      |> ModelInfo.with_catalog_updated_at(~U[2026-08-22 01:00:00Z])

    info = ModelInfo.merge([older, newer])

    assert info.minimal_client_versions == ["0.142.2", "0.144.0"]
    assert info.catalog_updated_at == ~U[2026-08-22 01:00:00Z]
    assert ModelInfo.present?(info)
  end
end
