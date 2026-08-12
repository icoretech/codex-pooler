defmodule CodexPooler.Dev.ExactAssignmentFullProofTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Dev.ExactAssignmentFullProof, as: Proof
  alias CodexPooler.Dev.GatewayPerfFakeUpstream, as: FakeUpstream
  alias CodexPooler.Dev.ResponsesToolCompatSmoke, as: Journal
  alias CodexPooler.PoolerFixtures
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures

  @owner_id "11111111-1111-4111-8111-111111111111"

  setup do
    run_id = "20260811T120000Z-#{random_hex(6)}"
    run_dir = Path.join(["tmp", "issue-241", "runtime", run_id])

    on_exit(fn -> File.rm_rf(run_dir) end)

    %{run_id: run_id, run_dir: run_dir}
  end

  describe "parse_args/1" do
    test "accepts only an explicitly scoped proof command" do
      assert {:ok, %{mode: :proof, owner_id: @owner_id, dry_run?: true}} =
               Proof.parse_args([
                 "--scope",
                 "loopback-fake",
                 "--owner-id",
                 @owner_id,
                 "--dry-run"
               ])
    end

    test "rejects missing scope, invalid owner, duplicate flags, and malformed cleanup run ids" do
      assert {:error, "--scope loopback-fake is required"} =
               Proof.parse_args(["--owner-id", @owner_id])

      assert {:error, "owner id must be a UUID"} =
               Proof.parse_args(["--scope", "loopback-fake", "--owner-id", "invalid"])

      assert {:error, "an option that accepts one value was supplied more than once"} =
               Proof.parse_args([
                 "--scope",
                 "loopback-fake",
                 "--scope",
                 "loopback-fake",
                 "--owner-id",
                 @owner_id
               ])

      assert {:error, "run id is invalid"} =
               Proof.parse_args([
                 "--scope",
                 "loopback-fake",
                 "--owner-id",
                 @owner_id,
                 "--cleanup-run-id",
                 "not-a-run"
               ])
    end
  end

  test "dry-run preflight performs no database writes" do
    {:ok, command} =
      Proof.parse_args([
        "--scope",
        "loopback-fake",
        "--owner-id",
        @owner_id,
        "--dry-run"
      ])

    before_count = Repo.aggregate(Pool, :count)

    assert {:ok, %{"mode" => "dry_run", "scope" => "loopback-fake", "writes" => false}} =
             Proof.execute(command, port_check: fn _port -> :ok end)

    assert Repo.aggregate(Pool, :count) == before_count
  end

  test "verified loopback fake cleanup removes only exact journaled ids", %{run_id: run_id} do
    profile = Enum.find(FakeUpstream.profiles(), &(&1["name"] == "opencode-text-ok"))

    {:ok, fake} =
      FakeUpstream.start_link(host: "127.0.0.1", port: 0, profiles: [profile], run_id: run_id)

    on_exit(fn -> FakeUpstream.stop(fake) end)

    assert :ok = Proof.verify_loopback_fake(fake)

    owned = PoolerFixtures.pool_fixture(%{slug: "issue-241-#{String.downcase(run_id)}-01"})
    unrelated = PoolerFixtures.pool_fixture()
    journal = journal_for_pool(run_id, owned.id, owned.slug)

    assert {:ok, %{"readback_zero" => %{"plan_rows_gone" => true}, "run_dir_removed" => true}} =
             Proof.cleanup_journal(journal, remove_run_dir?: true)

    assert Repo.get(Pool, owned.id) == nil
    assert %Pool{id: unrelated_id} = Repo.get(Pool, unrelated.id)
    assert unrelated_id == unrelated.id
  end

  test "production injected failure after a journaled row rolls back with exact readback" do
    %{user: owner} = bootstrap_owner_fixture()

    {:ok, command} =
      Proof.parse_args([
        "--scope",
        "loopback-fake",
        "--owner-id",
        owner.id
      ])

    unrelated = PoolerFixtures.pool_fixture()
    before_count = Repo.aggregate(Pool, :count)

    assert {:error, "proof_failed_rolled_back:" <> fingerprint} =
             Proof.execute(command,
               port_check: fn _port -> :ok end,
               inject_failure_after_owned_rows: 1,
               rollback_observer: self()
             )

    assert Regex.match?(~r/\A[0-9a-f]{12}\z/, fingerprint)

    assert_receive {:exact_assignment_full_proof, :rollback,
                    %{
                      "readback_zero" => %{"plan_rows_gone" => true},
                      "run_dir_removed" => true
                    }}

    assert Repo.aggregate(Pool, :count) == before_count
    assert %Pool{id: unrelated_id} = Repo.get(Pool, unrelated.id)
    assert unrelated_id == unrelated.id
  end

  test "task-visible exception messages are fingerprinted instead of returning raw values" do
    raw_value = "sentinel-raw-value-never-returned"

    {:ok, command} =
      Proof.parse_args([
        "--scope",
        "loopback-fake",
        "--owner-id",
        @owner_id,
        "--dry-run"
      ])

    assert {:error, message} =
             Proof.execute(command,
               port_check: fn _port -> raise raw_value end
             )

    assert "unexpected_exception:" <> fingerprint = message
    assert Regex.match?(~r/\A[0-9a-f]{12}\z/, fingerprint)
    refute message =~ raw_value

    assert {:error, preflight_message} =
             Proof.execute(command,
               port_check: fn _port -> {:error, raw_value} end
             )

    assert "preflight_failed:" <> preflight_fingerprint = preflight_message
    assert Regex.match?(~r/\A[0-9a-f]{12}\z/, preflight_fingerprint)
    refute preflight_message =~ raw_value
  end

  test "cleanup dry-run validates the exact run id and journal owner without writing", %{
    run_id: run_id,
    run_dir: run_dir
  } do
    journal = Journal.new_journal(run_id, @owner_id, ["synthetic-loopback"])
    :ok = Journal.write_journal!(run_dir, journal)

    {:ok, command} =
      Proof.parse_args([
        "--scope",
        "loopback-fake",
        "--owner-id",
        @owner_id,
        "--cleanup-run-id",
        run_id,
        "--dry-run"
      ])

    assert {:ok,
            %{
              "mode" => "dry_run_cleanup",
              "owned_cleanup_ids" => 0,
              "scope" => "loopback-fake",
              "writes" => false
            }} = Proof.execute(command)

    assert {:ok, ^journal} = Journal.read_journal(run_id)
  end

  defp journal_for_pool(run_id, pool_id, slug) do
    Journal.new_journal(run_id, @owner_id, ["synthetic-loopback"])
    |> Journal.record_resource("pool", pool_id, %{slug: slug})
  end

  defp random_hex(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
