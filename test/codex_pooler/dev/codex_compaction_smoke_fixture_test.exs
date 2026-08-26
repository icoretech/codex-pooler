defmodule CodexPooler.Dev.CodexCompactionSmokeFixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.CodexCompactionSmokeFixture
  alias CodexPooler.Dev.CodexCompactionSmokeFixture.Journal
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  setup do
    run_id = "compaction-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "codex-compaction-smoke-#{run_id}")
    bootstrap_owner_fixture()

    on_exit(fn -> File.rm_rf!(root) end)
    %{run_id: run_id, root: root}
  end

  test "journal and one-time secret are private, disjoint, and reject links", context do
    paths = Journal.paths(context.root, context.run_id)
    journal = Journal.new(context.run_id, "pool-id", "identity-id", "assignment-id", "model-id")
    secret = Journal.secret(context.run_id, "raw-key", "key-id", "pool-id", "gpt-5.5")

    assert :ok = Journal.write_journal(paths, journal)
    assert :ok = Journal.write_secret(paths, secret)
    assert {:ok, ^journal} = Journal.read_journal(paths, context.run_id)
    assert {:ok, ^secret} = Journal.read_secret(paths, context.run_id)
    assert file_mode(paths.root) == 0o700
    assert file_mode(paths.journal) == 0o600
    assert file_mode(paths.secret) == 0o600
    refute File.read!(paths.journal) =~ "raw-key"

    File.rm!(paths.journal)
    File.ln_s!(paths.secret, paths.journal)
    assert {:error, :unsafe_file} = Journal.read_journal(paths, context.run_id)
  end

  test "journal reads require the current uid and descriptor-safe ownership", context do
    paths = Journal.paths(context.root, context.run_id)
    journal = Journal.prepared(context.run_id)
    :ok = Journal.write_journal(paths, journal)

    assert {:ok, ^journal} =
             Journal.read_journal(paths, context.run_id, expected_uid: current_uid())

    assert {:error, :unsafe_owner} =
             Journal.read_journal(paths, context.run_id, expected_uid: current_uid() + 1)
  end

  test "journal exists before provisioning and a pre-commit interruption rolls back all rows",
       context do
    options = Keyword.put(fixture_options(context), :interrupt_after, :pool)

    assert {:error, "fixture provisioning failed; release the retained journal"} =
             CodexCompactionSmokeFixture.acquire(options)

    paths = Journal.paths(context.root, context.run_id)
    assert {:ok, %{"state" => "preparing"}} = Journal.read_journal(paths, context.run_id)
    assert is_nil(Repo.get_by(Pool, slug: "codex-compact-#{context.run_id}"))

    assert {:ok, %{status: "released"}} =
             CodexCompactionSmokeFixture.release(fixture_options(context))

    refute File.exists?(paths.root)
  end

  test "acquire provisions exact run resources and release is idempotent", context do
    options = fixture_options(context)

    assert {:ok, acquired} = CodexCompactionSmokeFixture.acquire(options)
    assert acquired.status == "ready"
    assert acquired.run_id == context.run_id
    assert acquired.model == "gpt-5.5"
    assert_safe_public_status(acquired, context)

    paths = Journal.paths(context.root, context.run_id)
    assert {:ok, secret} = Journal.read_secret(paths, context.run_id)

    assert Map.keys(secret) |> Enum.sort() ==
             ~w(api_key api_key_id model pool_id run_id version)

    assert %Pool{status: "active"} = Repo.get(Pool, secret["pool_id"])
    assert %APIKey{status: "active"} = Repo.get(APIKey, secret["api_key_id"])
    assert %Model{status: "active"} = Repo.get_by(Model, pool_id: secret["pool_id"])

    assert {:ok, released} = CodexCompactionSmokeFixture.release(options)
    assert released.status == "released"
    assert %Pool{status: "archived"} = Repo.get(Pool, secret["pool_id"])
    assert %APIKey{status: "revoked"} = Repo.get(APIKey, secret["api_key_id"])
    assert %Model{status: "retired"} = Repo.get_by(Model, pool_id: secret["pool_id"])

    assignment = Repo.get(PoolUpstreamAssignment, acquired.assignment_id)
    assert is_nil(assignment) or match?(%PoolUpstreamAssignment{status: "deleted"}, assignment)

    assert %UpstreamIdentity{status: "disabled"} =
             Repo.get(UpstreamIdentity, acquired.identity_id)

    assert Repo.aggregate(
             from(secret in EncryptedSecret,
               where: secret.upstream_identity_id == ^acquired.identity_id
             ),
             :count
           ) == 0

    refute File.exists?(paths.root)

    assert {:ok, %{status: "absent"}} = CodexCompactionSmokeFixture.release(options)
  end

  test "status output retains safe lifecycle identifiers without filesystem paths", context do
    options = fixture_options(context)
    assert {:ok, acquired} = CodexCompactionSmokeFixture.acquire(options)
    assert {:ok, status} = CodexCompactionSmokeFixture.status(options)

    assert status == acquired
    assert_safe_public_status(status, context)

    assert {:ok, released} = CodexCompactionSmokeFixture.release(options)
    assert released == %{status: "released", run_id: context.run_id}
    refute public_json(released) =~ context.root

    assert {:ok, absent} = CodexCompactionSmokeFixture.status(options)
    assert absent == %{status: "absent", run_id: context.run_id}
    refute public_json(absent) =~ context.root
  end

  test "prepared journal recovers committed resources and cleanup retains no raw secret",
       context do
    options = Keyword.put(fixture_options(context), :interrupt_after, :provision)

    assert {:error, "fixture interrupted after provisioning"} =
             CodexCompactionSmokeFixture.acquire(options)

    paths = Journal.paths(context.root, context.run_id)
    assert {:ok, journal} = Journal.read_journal(paths, context.run_id)
    refute Map.has_key?(journal, "api_key")
    assert File.exists?(paths.secret)

    assert {:ok, %{status: "released"}} =
             CodexCompactionSmokeFixture.release(fixture_options(context))

    refute File.exists?(paths.root)
  end

  test "isolated application config disables Endpoint and Oban and restores exact values",
       context do
    endpoint = Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint)
    oban = Application.get_env(:codex_pooler, Oban)
    repo = Application.get_env(:codex_pooler, Repo)

    assert :ok =
             CodexCompactionSmokeFixture.with_isolated_config(
               context.run_id,
               fn application_name ->
                 assert application_name == "codex_compaction_smoke_#{context.run_id}"

                 assert Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint)[:server] ==
                          false

                 assert Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint)[:watchers] ==
                          []

                 assert Application.get_env(:codex_pooler, Oban)[:queues] == false
                 assert Application.get_env(:codex_pooler, Oban)[:plugins] == false

                 assert Application.get_env(:codex_pooler, Repo)[:parameters][:application_name] ==
                          application_name

                 :ok
               end
             )

    assert Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint) == endpoint
    assert Application.get_env(:codex_pooler, Oban) == oban
    assert Application.get_env(:codex_pooler, Repo) == repo
  end

  test "argument parser accepts only exact acquire/status/release forms", context do
    assert {:ok, :acquire, options} =
             CodexCompactionSmokeFixture.parse_args([
               "acquire",
               "--run-id",
               context.run_id,
               "--upstream-base-url",
               "http://127.0.0.1:4567"
             ])

    assert options[:run_id] == context.run_id

    assert {:ok, :status, _} =
             CodexCompactionSmokeFixture.parse_args(["status", "--run-id", context.run_id])

    assert {:ok, :release, _} =
             CodexCompactionSmokeFixture.parse_args(["release", "--run-id", context.run_id])

    assert {:error, _} = CodexCompactionSmokeFixture.parse_args(["status"])

    assert {:error, _} =
             CodexCompactionSmokeFixture.parse_args([
               "acquire",
               "--run-id",
               context.run_id,
               "--upstream-base-url",
               "https://example.com"
             ])
  end

  defp fixture_options(context) do
    [
      run_id: context.run_id,
      upstream_base_url: "http://127.0.0.1:4567",
      root: context.root,
      environment: :test,
      allow_test_database: true
    ]
  end

  defp file_mode(path) do
    {:ok, stat} = File.lstat(path)
    Bitwise.band(stat.mode, 0o777)
  end

  defp assert_safe_public_status(status, context) do
    assert Map.keys(status) |> Enum.sort() ==
             [:assignment_id, :identity_id, :model, :pool_id, :run_id, :status]

    encoded = public_json(status)
    refute encoded =~ context.root
    refute encoded =~ Path.join(context.root, context.run_id)
    refute encoded =~ "journal.json"
    refute encoded =~ "secret.json"
    refute encoded =~ "CODEX_HOME"
    refute encoded =~ "MIX_BUILD_PATH"
    refute encoded =~ ~r/"(?:root|journal|secret|path|paths)"/
  end

  defp public_json(status), do: Jason.encode!(status)

  defp current_uid do
    {value, 0} = System.cmd("id", ["-u"])
    value |> String.trim() |> String.to_integer()
  end
end
