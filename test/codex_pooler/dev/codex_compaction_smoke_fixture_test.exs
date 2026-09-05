defmodule CodexPooler.Dev.CodexCompactionSmokeFixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.CodexCompactionSmokeFixture
  alias CodexPooler.Dev.CodexCompactionSmokeFixture.Journal
  alias CodexPooler.Gateway.Runtime.Finalization.SideEffects
  alias CodexPooler.Jobs.AccountReconciliationWorker
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

  @tag :unix_integration
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

  @tag :unix_integration
  test "journal reads require the current uid and descriptor-safe ownership", context do
    paths = Journal.paths(context.root, context.run_id)
    journal = Journal.prepared(context.run_id)
    :ok = Journal.write_journal(paths, journal)

    assert {:ok, ^journal} =
             Journal.read_journal(paths, context.run_id, expected_uid: current_uid())

    assert {:error, :unsafe_owner} =
             Journal.read_journal(paths, context.run_id, expected_uid: current_uid() + 1)
  end

  @tag :unix_integration
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

  @tag :unix_integration
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

    assert %Model{status: "active", metadata: metadata} =
             Repo.get_by(Model, pool_id: secret["pool_id"])

    source_model = get_in(metadata, ["source_assignment_models", acquired.assignment_id])
    assert source_model["use_responses_lite"] == true
    assert source_model["input_modalities"] == ["text", "image"]
    assert source_model["supports_image_detail_original"] == true
    assert source_model["context_window"] == 128_000
    assert source_model["auto_compact_token_limit"] == 200

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

  @tag :unix_integration
  test "release cancels gateway reconciliation for its exact graph and preserves foreign jobs",
       context do
    options = fixture_options(context)
    assert {:ok, acquired} = CodexCompactionSmokeFixture.acquire(options)
    foreign_context = %{context | run_id: context.run_id <> "-foreign"}
    foreign_options = fixture_options(foreign_context)
    assert {:ok, foreign} = CodexCompactionSmokeFixture.acquire(foreign_options)

    owned_job = enqueue_gateway_reconciliation(acquired)
    foreign_job = enqueue_gateway_reconciliation(foreign)
    assert owned_job.state == "available"

    assert {:ok, %{status: "released"}} = CodexCompactionSmokeFixture.release(options)
    assert Repo.get!(Oban.Job, owned_job.id).state == "cancelled"
    assert Repo.get!(Oban.Job, foreign_job.id).state == "available"
    refute File.exists?(Journal.paths(context.root, context.run_id).root)
    assert Repo.get!(Pool, foreign.pool_id).status == "active"
    assert {:ok, %{status: "released"}} = CodexCompactionSmokeFixture.release(foreign_options)
  end

  @tag :unix_integration
  test "executing reconciliation retains the journal and fails release", context do
    options = fixture_options(context)
    assert {:ok, acquired} = CodexCompactionSmokeFixture.acquire(options)
    job = enqueue_gateway_reconciliation(acquired)
    job |> Ecto.Changeset.change(state: "executing") |> Repo.update!()

    assert {:error, "fixture cleanup incomplete; metadata journal retained"} =
             CodexCompactionSmokeFixture.release(options)

    assert Repo.get!(Oban.Job, job.id).state == "executing"
    assert File.exists?(Journal.paths(context.root, context.run_id).journal)
  end

  for pending_state <- ["scheduled", "retryable"] do
    @pending_state pending_state
    @tag :unix_integration
    test "release cancels #{@pending_state} reconciliation", context do
      options = fixture_options(context)
      assert {:ok, acquired} = CodexCompactionSmokeFixture.acquire(options)
      job = enqueue_gateway_reconciliation(acquired)
      job |> Ecto.Changeset.change(state: @pending_state) |> Repo.update!()

      assert {:ok, %{status: "released"}} = CodexCompactionSmokeFixture.release(options)
      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    end
  end

  @tag :unix_integration
  test "release preserves reconciliation that does not match the complete owned graph", context do
    options = fixture_options(context)
    assert {:ok, acquired} = CodexCompactionSmokeFixture.acquire(options)
    job = enqueue_gateway_reconciliation(acquired)
    args = Map.put(job.args, "upstream_identity_id", Ecto.UUID.generate())
    job |> Ecto.Changeset.change(args: args) |> Repo.update!()

    assert {:error, "fixture cleanup incomplete; metadata journal retained"} =
             CodexCompactionSmokeFixture.release(options)

    assert Repo.get!(Oban.Job, job.id).state == "available"
    assert File.exists?(Journal.paths(context.root, context.run_id).journal)
  end

  @tag :unix_integration
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

  @tag :unix_integration
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

    assert {:ok, :receipt, receipt_options} =
             CodexCompactionSmokeFixture.parse_args([
               "receipt",
               "--run-id",
               context.run_id,
               "--upstream-frame-count",
               "2",
               "--duplicate-error-count",
               "0"
             ])

    assert receipt_options[:upstream_frame_count] == 2
    assert receipt_options[:duplicate_error_count] == 0

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

  @tag :unix_integration
  test "native tool continuation receipt is metadata-only", context do
    options = fixture_options(context)
    assert {:ok, _acquired} = CodexCompactionSmokeFixture.acquire(options)

    assert {:ok, receipt} =
             CodexCompactionSmokeFixture.receipt(
               Keyword.merge(options,
                 upstream_frame_count: 2,
                 duplicate_error_count: 0
               )
             )

    assert Map.keys(receipt) |> Enum.sort() ==
             [
               :attempt_count,
               :codex_turn_count,
               :duplicate_error_count,
               :logical_turn_fingerprints,
               :request_count,
               :request_fingerprints,
               :settlement_count,
               :status,
               :turn_sequences,
               :upstream_frame_count
             ]

    assert receipt.status == "closed"
    assert receipt.request_count == 0
    assert receipt.attempt_count == 0
    assert receipt.codex_turn_count == 0
    assert receipt.settlement_count == 0
    assert receipt.turn_sequences == []
    assert receipt.upstream_frame_count == 2
    assert receipt.duplicate_error_count == 0
    assert receipt.logical_turn_fingerprints == []
    assert receipt.request_fingerprints == []

    encoded = Jason.encode!(receipt)
    refute encoded =~ context.run_id
    refute encoded =~ context.root
    refute encoded =~ "pool_id"
    refute encoded =~ "identity_id"
  end

  defp enqueue_gateway_reconciliation(acquired) do
    assignment = Repo.get!(PoolUpstreamAssignment, acquired.assignment_id)
    assert :ok = SideEffects.maybe_enqueue_gateway_reconciliation(acquired.pool_id, assignment)

    assert_enqueued(
      worker: AccountReconciliationWorker,
      args: %{pool_id: acquired.pool_id, pool_upstream_assignment_id: assignment.id}
    )

    Repo.one!(from job in Oban.Job, where: job.args["pool_id"] == ^acquired.pool_id)
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
