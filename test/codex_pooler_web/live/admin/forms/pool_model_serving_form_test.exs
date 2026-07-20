defmodule CodexPoolerWeb.Admin.PoolModelServingFormTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPoolerWeb.Admin.PoolForm

  test "projects sorted active models and sorted saved-unavailable overrides with resolved mode state" do
    snapshot = %{
      revision: "catalog-revision",
      overrides: [
        override("gpt-z-unavailable", "full"),
        override("gpt-a-unavailable", "lite"),
        override("gpt-beta", "lite")
      ]
    }

    visible_models = [
      model("gpt-zeta", "Zeta", %{"use_responses_lite" => false}),
      model("gpt-beta", "Beta", %{"use_responses_lite" => true})
    ]

    projection = PoolForm.model_serving_form(snapshot, visible_models)

    assert projection.revision == "catalog-revision"
    assert projection.revision_name == "pool_model_serving[revision]"

    assert [
             %{
               index: 0,
               exposed_model_id: "gpt-beta",
               display_name: "Beta",
               configured_mode: "lite",
               effective_mode: "lite",
               source: "override",
               available?: true,
               warning: nil,
               identifier_name: "pool_model_serving[rows][0][exposed_model_id]",
               mode_name: "pool_model_serving[rows][0][mode]"
             },
             %{
               index: 1,
               exposed_model_id: "gpt-zeta",
               configured_mode: "auto",
               effective_mode: "full",
               source: "catalog",
               available?: true,
               warning: nil,
               effective_badge: %{label: "Effective: Full", mode: "full"}
             },
             %{
               index: 2,
               exposed_model_id: "gpt-a-unavailable",
               configured_mode: "lite",
               effective_mode: "lite",
               source: "override",
               available?: false,
               warning: "gpt-a-unavailable is not available in the current routable catalog"
             },
             %{
               index: 3,
               exposed_model_id: "gpt-z-unavailable",
               configured_mode: "full",
               effective_mode: "full",
               source: "override",
               available?: false,
               warning: "gpt-z-unavailable is not available in the current routable catalog"
             }
           ] = projection.rows

    assert projection.warnings == [
             "gpt-a-unavailable is not available in the current routable catalog",
             "gpt-z-unavailable is not available in the current routable catalog"
           ]
  end

  test "uses exact resolver output for Auto rows and stable collision-safe accessible ids" do
    snapshot = %{revision: "revision", overrides: []}

    visible_models = [
      model("gpt alpha", "Alpha", %{"use_responses_lite" => true}),
      model("gpt-alpha", "Alpha Dash", %{"use_responses_lite" => false})
    ]

    [first, second] = PoolForm.model_serving_form(snapshot, visible_models).rows

    assert first.effective_mode == "lite"
    assert first.source == "catalog"
    assert second.effective_mode == "full"
    assert first.dom_id != second.dom_id
    assert first.dom_id =~ ~r/^pool-model-serving-row-gpt-alpha-[a-f0-9]{8}$/
    assert second.dom_id =~ ~r/^pool-model-serving-row-gpt-alpha-[a-f0-9]{8}$/

    assert first.labels == %{
             fieldset: "Model serving mode for gpt alpha",
             auto: "Auto for gpt alpha",
             lite: "Lite for gpt alpha",
             full: "Full for gpt alpha"
           }

    assert first.input_ids == %{
             auto: first.dom_id <> "-auto",
             lite: first.dom_id <> "-lite",
             full: first.dom_id <> "-full"
           }
  end

  test "retains recognized submitted modes and revision without synthesizing submitted-only rows" do
    snapshot = %{revision: "current-revision", overrides: [override("gpt-unavailable", "lite")]}
    visible_models = [model("gpt-active", "Active", %{"use_responses_lite" => false})]

    projection =
      PoolForm.model_serving_form(snapshot, visible_models, %{
        "revision" => "submitted-stale-revision",
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-active", "mode" => "full"},
          "1" => %{"exposed_model_id" => "gpt-unavailable", "mode" => "auto"},
          "2" => %{"exposed_model_id" => "made-up-model", "mode" => "lite"},
          "3" => %{"exposed_model_id" => "gpt-active", "mode" => "unsupported"}
        }
      })

    assert projection.revision == "submitted-stale-revision"
    assert Enum.map(projection.rows, & &1.exposed_model_id) == ["gpt-active", "gpt-unavailable"]
    assert Enum.map(projection.rows, & &1.configured_mode) == ["full", "auto"]
  end

  test "an unavailable override switched to Auto previews removal instead of a runtime mode" do
    snapshot = %{revision: "current-revision", overrides: [override("gpt-unavailable", "lite")]}

    projection =
      PoolForm.model_serving_form(snapshot, [], %{
        "revision" => "current-revision",
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-unavailable", "mode" => "auto"}
        }
      })

    assert [row] = projection.rows
    assert row.configured_mode == "auto"
    assert row.effective_mode == "removed"
    assert row.source == "removal"
    assert row.effective_badge == %{label: "Will be removed on save", mode: "removed"}
  end

  defp model(exposed_model_id, display_name, metadata) do
    model = %Model{
      exposed_model_id: exposed_model_id,
      display_name: display_name,
      metadata: Map.put_new(metadata, "source_assignment_ids", ["assignment-1"])
    }

    {model, ["assignment-1"]}
  end

  defp override(exposed_model_id, mode) do
    %ModelServingOverride{exposed_model_id: exposed_model_id, mode: mode}
  end
end
