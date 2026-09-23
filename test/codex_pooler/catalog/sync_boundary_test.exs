defmodule CodexPooler.Catalog.SyncBoundaryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Catalog.{JobWorkflow, Model, Sync, SyncRun}
  alias CodexPooler.Catalog.Sync.Discovery
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  test "malformed upstream catalog entries fail the source without losing existing models" do
    for invalid <- [nil, 42, "invalid", []] do
      upstream = upstream(%{"data" => [%{"id" => "sample-valid"}, invalid]})
      pool = pool_fixture()
      %{assignment: assignment} = source(pool, FakeUpstream.url(upstream))
      existing = model_fixture(pool, %{metadata: %{"source_assignment_ids" => [assignment.id]}})

      assert {:error, run, %{code: :catalog_sync_failed}} = Sync.sync_pool_catalog(pool)
      assert run.status == "failed"
      assert run.error_message == "upstream model catalog contains invalid entries"
      assert Repo.reload!(existing).status == "active"
      assert is_nil(Repo.reload!(assignment).last_successful_sync_at)
      assert Repo.aggregate(from(m in Model, where: m.pool_id == ^pool.id), :count) == 1
    end
  end

  test "accepts bare model arrays with explicit capabilities and no account header" do
    upstream = upstream([%{"slug" => "sample-bare", "supports_tools" => true}])
    pool = pool_fixture()
    source(pool, FakeUpstream.url(upstream))
    assert {:ok, %{models: [model]}} = Sync.sync_pool_catalog(pool)
    assert model.exposed_model_id == "sample-bare"
    assert model.supports_tools
    assert [request] = FakeUpstream.requests(upstream)
    refute List.keymember?(request.headers, "chatgpt-account-id", 0)
  end

  # Every other upstream call omits `chatgpt-account-id` for a synthetic
  # `email_`/`local_` account id; catalog discovery is not an exception.
  test "catalog discovery scopes a real account id and omits a synthetic one" do
    for {account_id, expected} <- [
          {"acct-catalog-real", "acct-catalog-real"},
          {"  acct-catalog-untrimmed  ", "acct-catalog-untrimmed"},
          {"email_catalog@example.com", nil},
          {"local_catalog_identity", nil}
        ] do
      upstream = upstream([%{"slug" => "sample-scope", "supports_tools" => true}])
      pool = pool_fixture()
      source = source(pool, FakeUpstream.url(upstream))

      source.identity
      |> Ecto.Changeset.change(chatgpt_account_id: account_id)
      |> Repo.update!()

      assert {:ok, %{models: [_model]}} = Sync.sync_pool_catalog(pool)
      assert [request] = FakeUpstream.requests(upstream)

      case expected do
        nil ->
          refute List.keymember?(request.headers, "chatgpt-account-id", 0),
                 "expected #{inspect(account_id)} to be omitted"

        scope ->
          assert {"chatgpt-account-id", ^scope} =
                   List.keyfind(request.headers, "chatgpt-account-id", 0)
      end
    end
  end

  test "invalid base URLs and closed transport produce finalized failed syncs" do
    for url <- ["not-a-url", "http://127.0.0.1:1"] do
      pool = pool_fixture()
      source(pool, url)
      assert {:error, run, %{code: :catalog_sync_failed}} = Sync.sync_pool_catalog(pool)
      assert run.status == "failed"
      assert %DateTime{} = run.finished_at
    end
  end

  test "stale cleanup respects exact cutoff and leaves recent and completed runs alone" do
    pool = pool_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    cutoff = DateTime.add(now, -900, :second)
    stale = run(pool, %{started_at: cutoff})
    recent = run(pool, %{started_at: DateTime.add(cutoff, 1, :microsecond)})
    completed = run(pool, %{status: "succeeded", started_at: cutoff})
    assert {:ok, %{stale_catalog_sync_runs_failed: 1}} = Sync.cleanup_stale_sync_runs(now)
    assert Repo.reload!(stale).finished_at == now
    assert Repo.reload!(recent).status == "running"
    assert Repo.reload!(completed).status == "succeeded"
    assert {:ok, %{stale_catalog_sync_runs_failed: 0}} = Sync.cleanup_stale_sync_runs(now)
  end

  test "running sync blocks fetching and invalid cancellation attrs return a changeset" do
    pool = pool_fixture()
    source(pool, "http://127.0.0.1:1")
    run(pool)
    opts = [fetcher: fn _ -> flunk("must not fetch while sync is running") end]
    assert {:error, %{code: :catalog_sync_in_progress}} = Sync.sync_pool_catalog(pool, opts)

    assert {:error, %Ecto.Changeset{}} =
             Sync.sync_pool_catalog(pool, Keyword.put(opts, :trigger_kind, "invalid"))
  end

  test "job workflow normalizes failure and broadcasts success and failure" do
    pool = pool_fixture()
    assert :ok = Events.subscribe_pool(pool)

    assert {:ok, %{skipped?: true}} =
             Task.async(fn -> JobWorkflow.sync_catalog(pool.id, "scheduled") end)
             |> Task.await(15_000)

    assert_receive {Events, %{reason: "job_status_updated", payload: %{"status" => "succeeded"}}}
    source(pool, "not-a-url")

    assert {:error, %{code: :catalog_sync_failed}} =
             Task.async(fn -> JobWorkflow.sync_catalog(pool.id, "scheduled") end)
             |> Task.await(15_000)

    assert_receive {Events, %{reason: "job_status_updated", payload: %{"status" => "failed"}}}
  end

  test "invalid pool ref and empty discovery return explicit results" do
    assert {:error, %{code: :pool_not_found}} = Sync.sync_pool_catalog(nil)
    assert {:ok, [], [], []} = Discovery.discover_models([], fn _ -> flunk("no sources") end)
  end

  test "non-success HTTP responses and unsupported bodies fail without retiring existing models" do
    for status <- [200, 403, 503] do
      {:ok, server} =
        FakeUpstream.start_link(FakeUpstream.json_response(%{"unexpected" => true}, status))

      on_exit(fn -> FakeUpstream.stop(server) end)
      pool = pool_fixture()
      source(pool, FakeUpstream.url(server))
      model = model_fixture(pool)

      assert {:error, run, %{code: :catalog_sync_failed}} = Sync.sync_pool_catalog(pool)
      assert run.error_message == "model list request failed with #{status}"
      assert Repo.reload!(model).status == "active"
    end
  end

  test "custom catalog fetchers accept atom slug identifiers" do
    pool = pool_fixture()
    source(pool, "http://127.0.0.1:1")

    assert {:ok, %{models: [model]}} =
             Sync.sync_pool_catalog(pool, fetcher: fn _ -> {:ok, [%{slug: "sample-atom"}]} end)

    assert model.exposed_model_id == "sample-atom"
  end

  test "malformed source preserves prior metadata while healthy sources still update" do
    pool = pool_fixture()
    bad_upstream = upstream(%{"models" => [nil]})
    good_upstream = upstream(%{"models" => [%{"id" => "sample-shared"}]})
    bad = source(pool, FakeUpstream.url(bad_upstream))
    good = source(pool, FakeUpstream.url(good_upstream))
    prior_run_id = Ecto.UUID.generate()

    model_fixture(pool, %{
      exposed_model_id: "sample-shared",
      metadata: %{
        "source_assignment_ids" => [bad.assignment.id],
        "source_assignment_models" => %{bad.assignment.id => %{"id" => "sample-shared"}},
        "source_assignment_missing_sync_run_ids" => %{bad.assignment.id => prior_run_id}
      }
    })

    assert {:ok, %{partial?: true, models: [model], sync_run: run}} = Sync.sync_pool_catalog(pool)
    assert model.source_assignment_count == 2

    assert model.metadata["source_assignment_missing_sync_run_ids"] == %{
             bad.assignment.id => prior_run_id
           }

    assert run.stats["failed_source_assignment_count"] == 1
    assert is_nil(Repo.reload!(bad.assignment).last_successful_sync_at)
    assert %DateTime{} = Repo.reload!(good.assignment).last_successful_sync_at
  end

  test "invalid aggregate rolls back model writes and source timestamps and finalizes the run" do
    pool = pool_fixture()
    assignment = source(pool, "http://127.0.0.1:1").assignment
    existing = model_fixture(pool)

    assert {:error, run, %{code: :catalog_sync_failed}} =
             Sync.sync_pool_catalog(pool,
               fetcher: fn _ ->
                 {:ok, [%{"id" => "sample-new"}, %{"id" => "sample-invalid", "exposed_model_id" => ""}]}
               end
             )

    assert run.status == "failed"
    assert run.error_message == "model catalog sync failed"
    assert Repo.reload!(existing).status == "active"
    assert is_nil(Repo.reload!(assignment).last_successful_sync_at)
    assert Repo.aggregate(from(m in Model, where: m.pool_id == ^pool.id), :count) == 1
  end

  defp source(pool, url) do
    source = upstream_assignment_fixture(pool, %{assignment_metadata: %{"base_url" => url}})

    assert {:ok, _} =
             Upstreams.store_encrypted_secret(source.identity, %{
               secret_kind: "access_token",
               plaintext: "synthetic-catalog-token"
             })

    source
  end

  defp upstream(body) do
    {:ok, server} = FakeUpstream.start_link(FakeUpstream.json_response(body))
    on_exit(fn -> FakeUpstream.stop(server) end)
    server
  end

  defp run(pool, attrs \\ %{}) do
    %SyncRun{}
    |> SyncRun.changeset(
      Map.merge(
        %{
          pool_id: pool.id,
          trigger_kind: "manual",
          status: "running",
          started_at: DateTime.utc_now(),
          discovered_model_count: 0,
          upserted_model_count: 0,
          stale_marked_count: 0,
          stats: %{}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
