defmodule CodexPooler.CatalogTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.EncryptedSecret

  import CodexPooler.PoolerFixtures

  describe "catalog sync" do
    test "excludes reauth-required identities even if assignment state is still eligible" do
      pool = pool_fixture()

      %{assignment: assignment} =
        upstream_assignment_fixture(pool, %{
          identity_status: "reauth_required",
          assignment_status: "active",
          health_status: "active",
          eligibility_status: "eligible"
        })

      model_fixture(pool, %{
        exposed_model_id: "reauth-only-model",
        status: "active",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

      assert Catalog.list_catalog_sync_assignments(pool) == []
      assert Catalog.list_visible_models(pool) == []
    end

    test "excludes active identities without an active access token" do
      pool = pool_fixture()

      assert {:ok, identity} =
               IdentityLifecycle.create_upstream_identity(%{
                 chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
                 account_label: "Secretless catalog account",
                 onboarding_method: "import",
                 metadata: %{}
               })

      assert {:ok, identity} = IdentityLifecycle.activate_upstream_identity(identity)

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{
                 assignment_label: "Secretless catalog assignment",
                 metadata: %{}
               })

      assert {:ok, _assignment} = PoolAssignments.activate_pool_assignment(assignment)

      assert Catalog.list_catalog_sync_assignments(pool) == []
      assert {:ok, %{sync_runs: [], models: [], skipped?: true}} = Catalog.sync_pool_catalog(pool)
    end

    test "syncs models from eligible assignments through the fake upstream" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "data" => [
              %{
                "id" => "gpt-5.4-mini",
                "display_name" => "GPT 5.4 Mini",
                "owned_by" => "upstream",
                "capabilities" => %{"responses" => true, "streaming" => true}
              }
            ]
          })
        )

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      assert {:ok, %{sync_run: sync_run, models: [model]}} = Catalog.sync_pool_catalog(pool)

      assert sync_run.status == "succeeded"
      assert sync_run.discovered_model_count == 1
      assert sync_run.upserted_model_count == 1
      assert sync_run.retired_count == 0
      assert model.exposed_model_id == "gpt-5.4-mini"
      assert model.supports_responses
      assert model.supports_streaming
      assert model.metadata["source_assignment_ids"] == [assignment.id]

      assert [request] = FakeUpstream.requests(upstream)
      assert request.path == "/backend-api/codex/models"
      assert Repo.get!(Model, model.id).last_sync_run_id == sync_run.id
    end

    test "sync is idempotent and marks missing active models stale" do
      upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-5.4-mini"}]}))

      {pool, _assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})
      stale_candidate = model_fixture(pool, %{exposed_model_id: "stale-model", status: "active"})

      assert {:ok, %{models: [first_model]}} = Catalog.sync_pool_catalog(pool)
      assert {:ok, %{models: [second_model]}} = Catalog.sync_pool_catalog(pool)

      assert first_model.id == second_model.id
      assert Repo.aggregate(Model, :count) == 2
      assert Repo.get!(Model, stale_candidate.id).status == "stale"

      assert [visible_model] = Catalog.list_visible_models(pool)
      assert visible_model.exposed_model_id == "gpt-5.4-mini"
    end

    test "sync preserves smoke-provisioned manual models" do
      upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-5.4-mini"}]}))

      {pool, assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      manual_model =
        model_fixture(pool, %{
          exposed_model_id: "gpt-4o-transcribe",
          upstream_model_id: "provider-gpt-4o-transcribe",
          status: "active",
          supports_responses: false,
          supports_streaming: false,
          supports_tools: false,
          supports_reasoning: false,
          metadata: %{
            "manual_smoke_provisioned" => true,
            "source_assignment_ids" => [assignment.id],
            "source_assignment_models" => %{
              assignment.id => %{"modes" => ["transcription"], "input_modalities" => ["audio"]}
            },
            "modes" => ["transcription"],
            "input_modalities" => ["audio"]
          }
        })

      assert {:ok, %{models: [_model]}} = Catalog.sync_pool_catalog(pool)

      assert Repo.get!(Model, manual_model.id).status == "active"
      assert Catalog.get_model_by_exposed_id(pool, "gpt-4o-transcribe").status == "active"
    end

    test "respects explicit false upstream endpoint capabilities" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "data" => [
              %{
                "id" => "gpt-limited",
                "capabilities" => %{
                  "responses" => false,
                  "streaming" => true,
                  "tools" => false,
                  "reasoning" => false
                }
              }
            ]
          })
        )

      {pool, _assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      assert {:ok, %{models: [model]}} = Catalog.sync_pool_catalog(pool)

      refute model.supports_responses
      assert model.supports_streaming
      refute model.supports_tools
      refute model.supports_reasoning
    end

    test "explicit false capabilities override conflicting upstream fallback hints" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "data" => [
              %{
                "id" => "gpt-fallback-conflict",
                "prefer_websockets" => true,
                "supports_parallel_tool_calls" => true,
                "supported_reasoning_levels" => ["low", "medium"],
                "capabilities" => %{
                  "streaming" => false,
                  "tools" => false,
                  "reasoning" => false
                }
              }
            ]
          })
        )

      {pool, _assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      assert {:ok, %{models: [model]}} = Catalog.sync_pool_catalog(pool)

      refute model.supports_streaming
      refute model.supports_tools
      refute model.supports_reasoning
    end

    test "records source assignments for shared and account-specific models" do
      shared_upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "data" => [
              %{
                "id" => "gpt-shared",
                "additional_speed_tiers" => [],
                "service_tiers" => [],
                "capabilities" => %{"responses" => true, "streaming" => true}
              },
              %{"id" => "gpt-masterkain-only"}
            ]
          })
        )

      pro_upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "data" => [
              %{
                "id" => "gpt-shared",
                "additional_speed_tiers" => ["fast"],
                "tool_mode" => "code_mode_only",
                "service_tiers" => [
                  %{
                    "id" => "priority",
                    "name" => "Fast",
                    "description" => "1.5x speed, increased usage"
                  }
                ],
                "capabilities" => %{"tools" => true, "reasoning" => true}
              },
              %{"id" => "gpt-5.5"}
            ]
          })
        )

      pool = pool_fixture()

      {_pool, masterkain_assignment} =
        active_assignment_fixture(pool, %{"base_url" => FakeUpstream.url(shared_upstream)}, %{
          account_label: "masterkain@gmail.com",
          assignment_label: "Masterkain Free"
        })

      {_pool, pro_assignment} =
        active_assignment_fixture(pool, %{"base_url" => FakeUpstream.url(pro_upstream)}, %{
          account_label: "Pro account",
          assignment_label: "Codex Pro"
        })

      assert {:ok, %{models: models}} = Catalog.sync_pool_catalog(pool)
      assert length(models) == 3

      shared = Catalog.get_model_by_exposed_id(pool, "gpt-shared")
      pro_only = Catalog.get_model_by_exposed_id(pool, "gpt-5.5")
      masterkain_only = Catalog.get_model_by_exposed_id(pool, "gpt-masterkain-only")

      assert shared.source_assignment_count == 2

      assert shared.metadata["source_assignment_ids"] ==
               Enum.sort([masterkain_assignment.id, pro_assignment.id])

      assert shared.metadata["source_assignment_models"][masterkain_assignment.id][
               "service_tiers"
             ] == []

      assert shared.metadata["source_assignment_models"][pro_assignment.id]["service_tiers"] == [
               %{
                 "id" => "priority",
                 "name" => "Fast",
                 "description" => "1.5x speed, increased usage"
               }
             ]

      assert shared.metadata["upstream_model"]["additional_speed_tiers"] == ["fast"]
      assert shared.metadata["upstream_model"]["tool_mode"] == "code_mode_only"

      assert shared.metadata["upstream_model"]["service_tiers"] == [
               %{
                 "id" => "priority",
                 "name" => "Fast",
                 "description" => "1.5x speed, increased usage"
               }
             ]

      assert shared.metadata["upstream_model"]["capabilities"] == %{
               "responses" => true,
               "streaming" => true,
               "tools" => true,
               "reasoning" => true
             }

      assert pro_only.source_assignment_count == 1
      assert pro_only.metadata["source_assignment_ids"] == [pro_assignment.id]

      assert masterkain_only.source_assignment_count == 1
      assert masterkain_only.metadata["source_assignment_ids"] == [masterkain_assignment.id]
    end

    test "preserves an active absent source for one successful sync before retiring it" do
      pool = pool_fixture()

      {_pool, source_a} =
        active_assignment_fixture(pool, %{}, %{
          account_label: "Synthetic source A",
          assignment_label: "Synthetic assignment A"
        })

      {_pool, source_b} =
        active_assignment_fixture(pool, %{}, %{
          account_label: "Synthetic source B",
          assignment_label: "Synthetic assignment B"
        })

      assert {:ok, %{models: [_model]}} =
               sync_catalog_step(pool, %{
                 source_a.id => [shared_sync_model(%{"source_marker" => "a-first"})],
                 source_b.id => [shared_sync_model(%{"source_marker" => "b-first"})]
               })

      assert_shared_source_assignments(pool, [source_a.id, source_b.id])

      assert {:ok, %{models: [_model]}} =
               sync_catalog_step(pool, %{
                 source_a.id => [],
                 source_b.id => [shared_sync_model(%{"source_marker" => "b-second"})]
               })

      model = Catalog.get_model_by_exposed_id(pool, "gpt-preserved-shared")

      assert model.source_assignment_count == 2
      assert model.metadata["source_assignment_ids"] == Enum.sort([source_a.id, source_b.id])
      assert model.metadata["source_assignment_models"][source_a.id]["source_marker"] == "a-first"

      assert model.metadata["source_assignment_models"][source_b.id]["source_marker"] ==
               "b-second"

      assert {:ok, %{models: [_model]}} =
               sync_catalog_step(pool, %{
                 source_a.id => [],
                 source_b.id => [shared_sync_model(%{"source_marker" => "b-third"})]
               })

      model = Catalog.get_model_by_exposed_id(pool, "gpt-preserved-shared")

      assert model.source_assignment_count == 1
      assert model.metadata["source_assignment_ids"] == [source_b.id]
      assert model.metadata["source_assignment_models"][source_b.id]["source_marker"] == "b-third"
    end

    test "does not preserve disabled absent sources" do
      assert_absent_source_not_preserved("disabled", fn _pool, assignment ->
        assert {:ok, _assignment} = PoolAssignments.disable_pool_assignment(assignment)
      end)
    end

    test "does not preserve deleted absent sources" do
      assert_absent_source_not_preserved("deleted", fn pool, assignment ->
        assert {:ok, _result} = PoolAssignments.delete_pool_assignment(pool, assignment)
      end)
    end

    test "does not preserve ineligible absent sources" do
      assert_absent_source_not_preserved("ineligible", fn _pool, assignment ->
        assert {:ok, _assignment} =
                 PoolAssignments.update_pool_assignment(assignment, %{
                   eligibility_status: "ineligible"
                 })
      end)
    end

    test "does not preserve secretless absent sources" do
      assert_absent_source_not_preserved("secretless", fn _pool, assignment ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        Repo.update_all(
          from(secret in EncryptedSecret,
            where:
              secret.upstream_identity_id == ^assignment.upstream_identity_id and
                secret.status == "active"
          ),
          set: [status: "revoked", superseded_at: now]
        )
      end)
    end

    test "attributes model metadata to the highest-plan active source identity" do
      pool = pool_fixture()

      {_pool, free_assignment} =
        active_assignment_fixture(pool, %{}, %{
          account_label: "Free metadata source",
          assignment_label: "Free source"
        })

      {_pool, pro_assignment} =
        active_assignment_fixture(pool, %{}, %{
          account_label: "Pro metadata source",
          assignment_label: "Pro source"
        })

      assert {:ok, _free_identity} =
               IdentityLifecycle.activate_upstream_identity_with_plan(
                 free_assignment.upstream_identity_id,
                 %{plan_family: "free", plan_label: "Free"}
               )

      assert {:ok, pro_identity} =
               IdentityLifecycle.activate_upstream_identity_with_plan(
                 pro_assignment.upstream_identity_id,
                 %{plan_family: "pro", plan_label: "Pro"}
               )

      model =
        model_fixture(pool, %{
          exposed_model_id: "gpt-source-attribution",
          metadata: %{"source_assignment_ids" => [free_assignment.id, pro_assignment.id]}
        })

      assert Catalog.model_source_identity([model]).id == pro_identity.id

      assert Catalog.model_source_snapshot(pro_identity) == %{
               "upstream_identity_id" => pro_identity.id,
               "upstream_account_label" => "Pro metadata source",
               "upstream_account_plan_family" => "pro",
               "upstream_account_plan_label" => "Pro"
             }
    end

    test "suppressed models are protected and retired models remain hidden" do
      upstream =
        start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "suppressed-model"}]}))

      {pool, _assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})
      existing = model_fixture(pool, %{exposed_model_id: "suppressed-model", status: "active"})

      assert {:ok, suppressed} = Catalog.suppress_model(existing)
      assert {:ok, %{models: [synced_model]}} = Catalog.sync_pool_catalog(pool)

      assert synced_model.id == suppressed.id
      assert synced_model.status == "suppressed"
      assert %DateTime{} = synced_model.suppressed_at
      assert Catalog.list_visible_models(pool) == []

      active = model_fixture(pool, %{exposed_model_id: "retired-model", status: "active"})
      assert {:ok, retired} = Catalog.retire_model(active)
      assert retired.status == "retired"
    end

    test "records failed sync runs with sanitized errors" do
      {pool, _assignment} = active_assignment_fixture(%{"base_url" => "http://127.0.0.1:1"})

      assert {:error, sync_run, %{code: :catalog_sync_failed, message: message}} =
               Catalog.sync_pool_catalog(pool,
                 fetcher: fn _source ->
                   {:error, %{message: "Bearer sensitive-value failed"}}
                 end
               )

      assert message == "model catalog sync failed"
      assert sync_run.status == "failed"
      assert Repo.get!(SyncRun, sync_run.id).error_message == "model catalog sync failed"

      assert %{status: :failed, reason: "model catalog sync failed"} =
               Catalog.catalog_read_state(pool)
    end

    test "stale running sync runs are finalized before blocking later syncs" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_started_at = DateTime.add(now, -16, :minute)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-next"}]}))
      {pool, _assignment} = active_assignment_fixture(%{"base_url" => FakeUpstream.url(upstream)})

      stale_run = sync_run_fixture(pool, %{status: "running", started_at: stale_started_at})

      assert {:ok, %{models: [%Model{exposed_model_id: "gpt-next"}]}} =
               Catalog.sync_pool_catalog(pool)

      assert Repo.get!(SyncRun, stale_run.id).status == "failed"
    end

    test "returns no sync runs when no eligible assignment exists" do
      pool = pool_fixture()

      assert {:ok, %{sync_runs: [], models: [], skipped?: true}} = Catalog.sync_pool_catalog(pool)
    end
  end

  defp active_assignment_fixture(metadata) do
    pool = pool_fixture()

    active_assignment_fixture(pool, metadata, %{})
  end

  defp active_assignment_fixture(pool, metadata, attrs) do
    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: Map.get(attrs, :account_label, "Catalog account"),
               onboarding_method: "import",
               metadata: %{}
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "catalog-test-token"
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: Map.get(attrs, :assignment_label, "Catalog assignment"),
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    {pool, assignment}
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp sync_catalog_step(pool, assignment_models) when is_map(assignment_models) do
    Catalog.sync_pool_catalog(pool,
      fetcher: fn %{assignment: assignment} ->
        {:ok, Map.fetch!(assignment_models, assignment.id)}
      end
    )
  end

  defp assert_shared_source_assignments(pool, expected_assignment_ids) do
    model = Catalog.get_model_by_exposed_id(pool, "gpt-preserved-shared")

    assert model.source_assignment_count == length(expected_assignment_ids)
    assert model.metadata["source_assignment_ids"] == Enum.sort(expected_assignment_ids)
  end

  defp shared_sync_model(attrs) when is_map(attrs) do
    Map.merge(
      %{
        "id" => "gpt-preserved-shared",
        "display_name" => "Synthetic Preserved Shared",
        "owned_by" => "synthetic",
        "capabilities" => %{"responses" => true, "streaming" => true}
      },
      attrs
    )
  end

  defp assert_absent_source_not_preserved(case_name, invalidate_source)
       when is_binary(case_name) and is_function(invalidate_source, 2) do
    pool = pool_fixture()

    {_pool, missing_source} =
      active_assignment_fixture(pool, %{}, %{
        account_label: "Synthetic #{case_name} source A",
        assignment_label: "Synthetic #{case_name} assignment A"
      })

    {_pool, current_source} =
      active_assignment_fixture(pool, %{}, %{
        account_label: "Synthetic #{case_name} source B",
        assignment_label: "Synthetic #{case_name} assignment B"
      })

    assert {:ok, %{models: [_model]}} =
             sync_catalog_step(pool, %{
               missing_source.id => [
                 shared_sync_model(%{"source_marker" => "#{case_name}-a-first"})
               ],
               current_source.id => [
                 shared_sync_model(%{"source_marker" => "#{case_name}-b-first"})
               ]
             })

    invalidate_source.(pool, missing_source)

    assert {:ok, %{models: [_model]}} =
             sync_catalog_step(pool, %{
               current_source.id => [
                 shared_sync_model(%{"source_marker" => "#{case_name}-b-second"})
               ]
             })

    model = Catalog.get_model_by_exposed_id(pool, "gpt-preserved-shared")

    assert model.source_assignment_count == 1
    assert model.metadata["source_assignment_ids"] == [current_source.id]

    assert model.metadata["source_assignment_models"][current_source.id]["source_marker"] ==
             "#{case_name}-b-second"
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
