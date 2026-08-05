defmodule CodexPooler.Catalog.ModelSelectorTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  describe "api key model selector state" do
    test "returns visible routable catalog models as options and preserves unavailable selections" do
      pool = pool_fixture()
      routed = upstream_assignment_fixture(pool)
      sync_run_fixture(pool, %{status: "succeeded"})

      visible =
        model_fixture(pool, %{
          exposed_model_id: "gpt-visible",
          display_name: "GPT Visible",
          metadata: %{
            "source_assignment_ids" => [routed.assignment.id],
            "source_assignment_models" => %{
              routed.assignment.id => %{
                "description" => "Synthetic visible model.",
                "visibility" => "hide",
                "supported_in_api" => false
              }
            }
          }
        })

      model_fixture(pool, %{
        exposed_model_id: "gpt-non-routable",
        display_name: "GPT Non-routable",
        metadata: %{"source_assignment_ids" => []}
      })

      state =
        Catalog.api_key_model_selector_state(pool, %{
          model_mode: "selected_models",
          allowed_model_identifiers: ["GPT-Visible", "gpt-non-routable", "legacy-model"],
          manual_model_identifiers: ["custom/manual-model"]
        })

      assert state.catalog.status == :synced
      assert [%{identifier: "gpt-visible", display_name: "GPT Visible"}] = state.options

      assert [
               %{
                 model_info: %{
                   description: "Synthetic visible model.",
                   description_state: :available,
                   visibility: :hidden,
                   api_support: :unsupported
                 }
               }
             ] = state.options

      assert [%{identifier: "gpt-visible", selected?: true}] = state.selected_options

      assert Enum.map(state.selected_unavailable_chips, & &1.identifier) == [
               "gpt-non-routable",
               "legacy-model"
             ]

      assert Enum.all?(state.selected_unavailable_chips, &(&1.status == :unavailable))
      assert [%{identifier: "custom/manual-model", status: :custom}] = state.manual_chips
      assert visible.id
    end

    test "preserves saved model identifiers when catalog is unavailable" do
      pool = pool_fixture()

      state =
        Catalog.api_key_model_selector_state(pool, %{
          model_mode: "selected_models",
          allowed_model_identifiers: ["Legacy-Model"],
          manual_model_identifiers: ["manual/model"]
        })

      assert state.catalog.status == :unavailable
      assert state.catalog.requires_acknowledgement?
      assert state.options == []
      assert [%{identifier: "legacy-model", status: :stale}] = state.selected_unavailable_chips
      assert [%{identifier: "manual/model", status: :manual_unverified}] = state.manual_chips

      assert {:error, %{code: :catalog_acknowledgement_required}} =
               Catalog.validate_model_selector_acknowledgement(state, %{})

      assert :ok =
               Catalog.validate_model_selector_acknowledgement(state, %{
                 acknowledge_catalog_warning: "true"
               })
    end

    test "does not require catalog acknowledgement for unrestricted all-model mode" do
      pool = pool_fixture()

      state =
        Catalog.api_key_model_selector_state(pool, %{
          model_mode: "all_models",
          manual_model_identifiers: ["manual/model"]
        })

      assert state.catalog.status == :unavailable
      assert :ok = Catalog.validate_model_selector_acknowledgement(state, %{})
    end

    test "returns explicit warning metadata for non-synced catalog states" do
      syncing_pool = pool_fixture()
      sync_run_fixture(syncing_pool, %{status: "running", finished_at: nil})

      failed_pool = pool_fixture()
      sync_run_fixture(failed_pool, %{status: "failed", error_message: "upstream timeout"})

      empty_pool = pool_fixture()
      sync_run_fixture(empty_pool, %{status: "succeeded"})

      stale_pool = pool_fixture()
      routed = upstream_assignment_fixture(stale_pool)

      sync_run_fixture(stale_pool, %{
        status: "succeeded",
        started_at: DateTime.add(DateTime.utc_now(), -90_000, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -90_000, :second)
      })

      model_fixture(stale_pool, %{
        exposed_model_id: "gpt-stale-catalog",
        metadata: %{"source_assignment_ids" => [routed.assignment.id]}
      })

      for {pool, status} <- [
            {syncing_pool, :syncing},
            {failed_pool, :failed},
            {empty_pool, :empty},
            {stale_pool, :stale}
          ] do
        state = Catalog.api_key_model_selector_state(pool)

        assert state.catalog.status == status
        assert state.catalog.message
        assert state.catalog.requires_acknowledgement?
        assert [%{code: ^status, message: message}] = state.warnings
        assert message
      end
    end

    test "tracks empty, stale, failed, removed, and enforced saved model edge states" do
      empty_pool = pool_fixture()
      sync_run_fixture(empty_pool, %{status: "succeeded"})

      assert %{catalog: %{status: :empty}, options: []} =
               Catalog.api_key_model_selector_state(empty_pool)

      failed_pool = pool_fixture()
      sync_run_fixture(failed_pool, %{status: "failed", error_message: "upstream failed"})

      assert %{catalog: %{status: :failed}, warnings: [%{code: :failed}]} =
               Catalog.api_key_model_selector_state(failed_pool, %{
                 model_mode: "selected_models",
                 allowed_model_identifiers: ["legacy-model"]
               })

      stale_pool = pool_fixture()
      routed = upstream_assignment_fixture(stale_pool)

      sync_run_fixture(stale_pool, %{
        status: "succeeded",
        started_at: DateTime.add(DateTime.utc_now(), -90_000, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -90_000, :second)
      })

      model_fixture(stale_pool, %{
        exposed_model_id: "gpt-still-visible",
        metadata: %{"source_assignment_ids" => [routed.assignment.id]}
      })

      stale_state =
        Catalog.api_key_model_selector_state(stale_pool, %{
          model_mode: "selected_models",
          allowed_model_identifiers: ["gpt-still-visible", "removed-enforced-model"]
        })

      assert stale_state.catalog.status == :stale

      assert [%{identifier: "removed-enforced-model", status: :stale}] =
               stale_state.selected_unavailable_chips

      assert [%{identifier: "gpt-still-visible", selected?: true}] = stale_state.selected_options
    end

    test "validates manual model identifier syntax" do
      assert {:ok, "gpt-valid"} = Catalog.validate_manual_model_identifier(" GPT-Valid ")

      assert {:ok, ["gpt-one", "gpt-two"]} =
               Catalog.validate_manual_model_identifiers("gpt-one\ngpt-two")

      assert {:error, %{code: :invalid_model_identifier}} =
               Catalog.validate_manual_model_identifier(" ")

      assert {:error, %{code: :invalid_model_identifier}} =
               Catalog.validate_manual_model_identifier("gpt invalid")

      assert {:error, %{code: :invalid_model_identifier}} =
               Catalog.validate_manual_model_identifier("gpt\tinvalid")

      assert {:error, %{code: :invalid_model_identifier}} =
               Catalog.validate_manual_model_identifiers(["gpt-ok", "bad model"])
    end
  end

  defp sync_run_fixture(pool, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %SyncRun{}
    |> SyncRun.changeset(%{
      pool_id: pool.id,
      trigger_kind: Map.get(attrs, :trigger_kind, "manual"),
      status: Map.get(attrs, :status, "succeeded"),
      started_at: Map.get(attrs, :started_at, now),
      finished_at: Map.get(attrs, :finished_at, now),
      discovered_model_count: Map.get(attrs, :discovered_model_count, 0),
      upserted_model_count: Map.get(attrs, :upserted_model_count, 0),
      stale_marked_count: Map.get(attrs, :stale_marked_count, 0),
      retired_count: Map.get(attrs, :retired_count, 0),
      error_message: Map.get(attrs, :error_message),
      stats: Map.get(attrs, :stats, %{})
    })
    |> Repo.insert!()
  end
end
