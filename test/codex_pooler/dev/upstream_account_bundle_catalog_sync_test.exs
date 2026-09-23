defmodule CodexPooler.Dev.UpstreamAccountBundleCatalogSyncTest do
  # An imported copy is unroutable until a catalog sync has read the provider's
  # model list for its assignment. `mix dev.upstreams.import --sync-catalog`
  # enqueues that product job after the import commits, and only then; the
  # task also refuses a target Pool that serves from synthetic upstreams, so a
  # real copy never shares a model with a fake source.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.UpstreamAccountBundle
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, UpstreamIdentity}

  @password "synthetic-bundle-password-12345"
  @models_path "/backend-api/codex/models"

  setup do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{scope: Scope.for_user(user, ["instance_owner"])}
  end

  test "--sync-catalog enqueues one manual catalog sync whose run makes the copy a model source", %{scope: scope} do
    target_pool = pool_fixture()
    {bundle, account_id} = bundle!()

    assert {:ok, %{imported: 1, catalog_sync: "enqueued"}} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password, import_options(["--sync-catalog"]))

    assert [%Oban.Job{args: args}] = all_enqueued(worker: CatalogSyncWorker)
    assert args == %{"pool_id" => target_pool.id, "trigger_kind" => "manual"}

    identity = Upstreams.get_upstream_identity_by_chatgpt_account(account_id)
    assert [assignment] = target_pool |> Upstreams.list_active_pool_assignments() |> Enum.filter(&(&1.upstream_identity_id == identity.id))

    # The bundle carries no base URL, so the copy reads the configured provider
    # default; point it at a loopback fake model list.
    {:ok, upstream} = FakeUpstream.start_link({:path_json, %{@models_path => {200, %{"data" => [%{"id" => "gpt-sync-example"}]}}}})
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    TestAppEnv.restore_on_exit(:codex_upstream_base_url)
    Application.put_env(:codex_pooler, :codex_upstream_base_url, FakeUpstream.url(upstream))

    assert :ok = perform_job(CatalogSyncWorker, args)

    assert %Model{status: "active", metadata: %{"source_assignment_ids" => sources}} =
             Repo.get_by(Model, pool_id: target_pool.id, exposed_model_id: "gpt-sync-example")

    assert sources == [assignment.id]
  end

  test "a dry run with --sync-catalog enqueues nothing", %{scope: scope} do
    {bundle, _account_id} = bundle!()

    assert {:ok, %{valid: 1, imported: 0, catalog_sync: "skipped_dry_run"}} =
             UpstreamAccountBundle.import_bundle(bundle, pool_fixture(), scope, @password, import_options(["--dry-run", "--sync-catalog"]))

    refute_enqueued(worker: CatalogSyncWorker)
  end

  test "an import without --sync-catalog enqueues nothing", %{scope: scope} do
    {bundle, _account_id} = bundle!()

    assert {:ok, %{imported: 1} = receipt} = UpstreamAccountBundle.import_bundle(bundle, pool_fixture(), scope, @password, import_options([]))
    refute Map.has_key?(receipt, :catalog_sync)
    refute_enqueued(worker: CatalogSyncWorker)
  end

  for args <- [["--dry-run"], ["--sync-catalog"]] do
    @args args
    test "the task refuses a target Pool that serves from a synthetic upstream (#{Enum.join(args, " ")})", %{scope: scope} do
      target_pool = pool_fixture()
      _synthetic = active_upstream_assignment_fixture(target_pool, metadata: %{"base_url" => "http://127.0.0.1:4058"})
      {bundle, account_id} = bundle!()

      assert {:error, %{code: :target_pool_has_synthetic_sources}} =
               UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password, import_options(@args))

      refute Upstreams.get_upstream_identity_by_chatgpt_account(account_id)
      refute_enqueued(worker: CatalogSyncWorker)
    end
  end

  test "the import task parses --sync-catalog once and always refuses synthetic sources" do
    assert {:ok, %{sync_catalog?: false, import_options: default}} = UpstreamAccountBundle.parse_import_args(["b.bin", "--pool", "one"])
    assert default == [dry_run: false, refresh_tokens: :omit, sync_catalog: false, synthetic_sources: :refuse]

    assert {:ok, %{sync_catalog?: true, import_options: options}} =
             UpstreamAccountBundle.parse_import_args(["b.bin", "--pool", "one", "--sync-catalog"])

    assert Keyword.fetch!(options, :sync_catalog)

    for args <- [["b.bin", "--pool", "one", "--sync-catalog", "--sync-catalog"], ["b.bin", "--pool", "one", "--sync-catalog", "--no-sync-catalog"]] do
      assert {:error, "duplicate or contradictory bundle task option"} = UpstreamAccountBundle.parse_import_args(args)
    end
  end

  defp import_options(args) do
    {:ok, %{import_options: options}} = UpstreamAccountBundle.parse_import_args(["b.bin", "--pool", "one" | args])
    options
  end

  # Exports one synthetic account access-token-only and removes the source rows,
  # so the import creates a fresh identity as it would in another database.
  defp bundle! do
    source_pool = pool_fixture()
    unique = System.unique_integer([:positive])
    account_id = "acct_catalog_sync_#{unique}"

    fixture =
      active_upstream_assignment_fixture(source_pool, %{
        chatgpt_account_id: account_id,
        account_email: "catalog-sync-#{unique}@example.com",
        account_label: "Synthetic catalog sync #{unique}",
        access_token: "synthetic-access-token-#{unique}"
      })

    fixture.identity |> Ecto.Changeset.change() |> UpstreamIdentity.put_credential_provenance(:codex_chatgpt) |> Repo.update!()

    assert {:ok, bundle, %{exported: 1}} = UpstreamAccountBundle.export_bundle(source_pool, @password, refresh_tokens: :omit)

    Repo.delete!(Repo.reload!(fixture.assignment))
    Repo.delete_all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^fixture.identity.id)
    Repo.delete!(Repo.reload!(fixture.identity))

    {bundle, account_id}
  end
end
