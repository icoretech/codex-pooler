defmodule CodexPooler.Dev.ResponsesToolCompatSmokeTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Dev.ResponsesToolCompatSmoke, as: Smoke
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @owner_id "11111111-1111-4111-8111-111111111111"
  @labels ~w(codex01 codex02 codex03)

  setup do
    run_id = "20260803T120000Z-#{random_hex(6)}"
    run_dir = Path.join(["tmp", "issue-241", "runtime", run_id])
    receipt_path = Path.join(["tmp", "issue-241", "receipts", "#{run_id}.json"])

    on_exit(fn ->
      File.rm_rf(run_dir)
      File.rm(receipt_path)
    end)

    %{run_id: run_id, run_dir: run_dir, receipt_path: receipt_path}
  end

  describe "parse_args/1" do
    test "accepts the exact provisioning shape" do
      assert {:ok,
              %{
                mode: :provision,
                owner_id: @owner_id,
                identity_labels: @labels,
                dry_run?: true,
                base_url: %URI{scheme: "http", host: "localhost", port: 4000}
              }} =
               Smoke.parse_args([
                 "--base-url",
                 "http://localhost:4000",
                 "--owner-id",
                 @owner_id,
                 "--identity-label",
                 "codex01",
                 "--identity-label",
                 "codex02",
                 "--identity-label",
                 "codex03",
                 "--dry-run"
               ])
    end

    test "accepts cleanup only with the same explicit owner contract", %{run_id: run_id} do
      assert {:ok, %{mode: :cleanup, cleanup_run_id: ^run_id, owner_id: @owner_id}} =
               Smoke.parse_args(["--cleanup-run-id", run_id, "--owner-id", @owner_id])
    end

    test "accepts owner resolution only as a standalone mode" do
      assert {:ok, %{mode: :resolve_owner}} = Smoke.parse_args(["--resolve-owner-id"])

      assert {:error, "--resolve-owner-id must be used alone"} =
               Smoke.parse_args(["--resolve-owner-id", "--owner-id", @owner_id])
    end

    test "rejects non-loopback, malformed, duplicate, incomplete, and unknown input", %{
      run_id: run_id
    } do
      common = [
        "--owner-id",
        @owner_id,
        "--identity-label",
        "codex01",
        "--identity-label",
        "codex02",
        "--identity-label",
        "codex03"
      ]

      assert {:error, "base URL must be an origin-only HTTP loopback URL"} =
               Smoke.parse_args(["--base-url", "https://example.com" | common])

      assert {:error, "base URL must be an origin-only HTTP loopback URL"} =
               Smoke.parse_args(["--base-url", "http://localhost:4000/v1" | common])

      assert {:error, "owner id must be a UUID"} =
               Smoke.parse_args([
                 "--base-url",
                 "http://127.0.0.1:4000",
                 "--owner-id",
                 "wrong"
                 | Enum.drop(common, 2)
               ])

      assert {:error, "identity labels must be distinct"} =
               Smoke.parse_args([
                 "--base-url",
                 "http://127.0.0.1:4000",
                 "--owner-id",
                 @owner_id,
                 "--identity-label",
                 "codex01",
                 "--identity-label",
                 "codex01",
                 "--identity-label",
                 "codex03"
               ])

      assert {:error, "exactly three --identity-label values are required"} =
               Smoke.parse_args(["--base-url", "http://localhost:4000" | Enum.drop(common, -2)])

      assert {:error, "cleanup accepts only --cleanup-run-id and --owner-id"} =
               Smoke.parse_args([
                 "--cleanup-run-id",
                 run_id,
                 "--owner-id",
                 @owner_id,
                 "--dry-run"
               ])

      assert {:error, "unknown or positional arguments are not allowed"} =
               Smoke.parse_args(["--unknown"])
    end
  end

  test "synthetic dry-run validates fixtures without boot, writes, or network" do
    command = provision_command()

    inspection = %{
      owners: [@owner_id],
      identities:
        Enum.with_index(@labels, 1)
        |> Enum.map(fn {label, index} ->
          %{
            id:
              "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
            label: label,
            status: "active"
          }
        end),
      other_client_application_names: []
    }

    assert {:ok,
            "dry-run passed: localhost, sole owner, three distinct active identities, no writes"} =
             Smoke.execute(command,
               inspection: inspection,
               server_check: fn _uri -> :ok end
             )
  end

  test "synthetic dry-run fails closed on owner, identity, database, and port guards" do
    command = provision_command()
    valid = valid_inspection()

    assert {:error, "owner id is not the sole active instance owner"} =
             Smoke.execute(command,
               inspection: %{valid | owners: []},
               server_check: fn _uri -> :ok end
             )

    assert {:error, "identity labels must resolve to exactly three distinct active identities"} =
             Smoke.execute(command,
               inspection: %{valid | identities: Enum.drop(valid.identities, 1)},
               server_check: fn _uri -> :ok end
             )

    assert {:error, "database has another client backend"} =
             Smoke.execute(command,
               inspection: %{valid | other_client_application_names: ["other-client"]},
               server_check: fn _uri -> :ok end
             )

    assert {:error, "localhost port is already occupied"} =
             Smoke.execute(command,
               inspection: valid,
               server_check: fn _uri -> {:error, "localhost port is already occupied"} end
             )
  end

  test "journal replacement is private, exact, and rejects symlink traversal", %{
    run_id: run_id,
    run_dir: run_dir
  } do
    journal = Smoke.new_journal(run_id, @owner_id, @labels)
    :ok = Smoke.write_journal!(run_dir, journal)

    assert {:ok, ^journal} = Smoke.read_journal(run_id)
    assert {:ok, %File.Stat{type: :directory, mode: directory_mode}} = File.lstat(run_dir)
    assert Bitwise.band(directory_mode, 0o077) == 0

    manifest = Path.join(run_dir, "manifest.json")
    assert {:ok, %File.Stat{type: :regular, mode: file_mode}} = File.lstat(manifest)
    assert Bitwise.band(file_mode, 0o077) == 0

    File.rm!(manifest)
    File.ln_s!(Path.join(run_dir, "missing"), manifest)

    assert {:error, "expected a regular file and refused a link or special file"} =
             Smoke.read_journal(run_id)
  end

  test "cleanup plan contains exact recorded ids only and has dependency order", %{run_id: run_id} do
    journal =
      Smoke.new_journal(run_id, @owner_id, @labels)
      |> Smoke.record_resource("pool", "pool-exact", %{slug: "issue-241-#{run_id}-01"})
      |> Smoke.record_resource("model", "model-exact", %{pool_id: "pool-exact"})
      |> Smoke.record_resource("api_key", "key-exact", %{pool_id: "pool-exact"})
      |> Smoke.record_resource("assignment", "assignment-exact", %{pool_id: "pool-exact"})
      |> Smoke.record_resource("serving_override", "override-exact", %{
        pool_id: "pool-exact",
        model_id: "gpt-example"
      })
      |> Smoke.record_resource("pool", "pool-exact", %{})
      |> Smoke.record_resource("unknown", "must-not-clean", %{})

    assert Enum.map(Smoke.exact_cleanup_plan(journal), &{&1["kind"], &1["id"]}) == [
             {"serving_override", "override-exact"},
             {"assignment", "assignment-exact"},
             {"api_key", "key-exact"},
             {"model", "model-exact"},
             {"pool", "pool-exact"}
           ]
  end

  test "receipt publication strips forbidden owner and secret-bearing fields", %{
    run_id: run_id,
    receipt_path: receipt_path
  } do
    assert {:error, "receipt contains a field outside the metadata allowlist"} =
             Smoke.validate_receipt(%{run_id: run_id, owner_user_id: @owner_id})

    assert ^receipt_path =
             Smoke.publish_receipt!(%{
               run_id: run_id,
               certification_status: "failed",
               cleanup_status: "completed",
               owner_user_id: @owner_id,
               raw_key: "forbidden-raw-key",
               provider_identifier: "forbidden-provider"
             })

    assert {:ok, content} = File.read(receipt_path)
    assert {:ok, receipt} = Jason.decode(content)

    assert receipt == %{
             "certification_status" => "failed",
             "cleanup_status" => "completed",
             "run_id" => run_id
           }

    refute content =~ @owner_id
    refute content =~ "forbidden-raw-key"
    refute content =~ "forbidden-provider"
  end

  test "direct Pool and assignment lifecycle does not enqueue catalog sync jobs" do
    owner = owner_fixture!()
    scope = Scope.for_user(owner)
    identity = active_identity_fixture!()
    slug = "issue-241-no-job-#{System.unique_integer([:positive])}"

    assert {:ok, pool} =
             Pools.create_pool(scope, %{slug: slug, name: "No job smoke", status: "active"},
               broadcast?: false
             )

    assert :ok =
             Upstreams.sync_pool_assignments_for_pool_edit(pool, [identity.id],
               select_by: :upstream_identity_id,
               skip_quota_priming: true
             )

    assert [%PoolUpstreamAssignment{status: "active", upstream_identity_id: identity_id}] =
             Upstreams.list_pool_assignments(pool)

    assert identity_id == identity.id

    refute_enqueued(
      worker: CodexPooler.Jobs.CatalogSyncWorker,
      args: %{"pool_id" => pool.id}
    )

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == "Elixir.CodexPooler.Jobs.CatalogSyncWorker" and
                   fragment("?->>'pool_id' = ?", job.args, ^pool.id)
             ),
             :count
           ) == 0
  end

  defp provision_command do
    %{
      mode: :provision,
      owner_id: @owner_id,
      identity_labels: @labels,
      base_url: URI.parse("http://localhost:4000"),
      dry_run?: true
    }
  end

  defp valid_inspection do
    %{
      owners: [@owner_id],
      identities:
        Enum.with_index(@labels, 1)
        |> Enum.map(fn {label, index} ->
          %{
            id:
              "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
            label: label,
            status: "active"
          }
        end),
      other_client_application_names: []
    }
  end

  defp owner_fixture! do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    user =
      %User{}
      |> User.bootstrap_changeset(%{
        "email" => "issue-241-owner-#{System.unique_integer([:positive])}@example.com",
        "display_name" => "Issue 241 Owner",
        "password" => "bootstrap-pass-123"
      })
      |> Repo.insert!()

    %Membership{}
    |> Membership.changeset(%{
      user_id: user.id,
      role: "instance_owner",
      status: "active",
      created_by_user_id: user.id,
      created_at: now
    })
    |> Repo.insert!()

    user
  end

  defp active_identity_fixture! do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    unique = System.unique_integer([:positive])

    %UpstreamIdentity{
      chatgpt_account_id: "acct_issue241_#{unique}",
      account_label: "issue-241-identity-#{unique}",
      onboarding_method: "import",
      status: "active",
      headers_profile_version: 1,
      created_at: now,
      updated_at: now,
      metadata: %{}
    }
    |> Repo.insert!()
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
