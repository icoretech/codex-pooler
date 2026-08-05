defmodule CodexPooler.Catalog.ModelInfoTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.ModelInfo

  test "projects description and exceptional facts from the selected source" do
    metadata = %{
      "source_assignment_models" => %{
        "assignment-a" => %{
          "description" => "Synthetic work routing alias.",
          "visibility" => "hide",
          "supported_in_api" => false
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
             api_support: :unsupported
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
end
