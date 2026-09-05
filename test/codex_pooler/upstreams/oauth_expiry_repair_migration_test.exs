unless Code.ensure_loaded?(CodexPooler.Repo.Migrations.RepairStaleOauthAccessTokenExpiry) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260905050035_repair_stale_oauth_access_token_expiry.exs",
      __DIR__
    )
  )
end

defmodule CodexPooler.Upstreams.OauthExpiryRepairMigrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias CodexPooler.Repo
  alias CodexPooler.Repo.Migrations.RepairStaleOauthAccessTokenExpiry
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Ecto.Migrator

  @migration_version 20_260_905_050_035
  @detection_budget 15_000
  @observer_budget 5_000

  setup do
    Sandbox.mode(Repo, :auto)
    assert :ok = migrate_down()

    on_exit(fn ->
      migrate_down()
      migrate_up()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "repairs only markerless imported OAuth metadata and preserves related state" do
    browser = insert_identity!(candidate_metadata("oauth_browser_link", :both), status: "active")

    device =
      insert_identity!(candidate_metadata("oauth_device_link", :canonical), status: "paused")

    legacy =
      insert_identity!(candidate_metadata("oauth_browser_link", :legacy), status: "refresh_due")

    excluded = %{
      marker:
        insert_identity!(
          candidate_metadata("oauth_browser_link", :both)
          |> put_in(["token_refresh", "access_token_expiry"], unknown_marker())
        ),
      wrong_status:
        insert_identity!(
          put_in(
            candidate_metadata("oauth_browser_link", :both),
            ["token_refresh", "status"],
            "succeeded"
          )
        ),
      wrong_trigger:
        insert_identity!(
          put_in(
            candidate_metadata("oauth_browser_link", :both),
            ["token_refresh", "trigger_kind"],
            "auth_json_import"
          )
        ),
      missing_expiry: insert_identity!(candidate_metadata("oauth_device_link", :none)),
      missing_refresh:
        insert_identity!(
          Map.delete(candidate_metadata("oauth_device_link", :both), "token_refresh")
        ),
      scalar_refresh:
        insert_identity!(
          Map.put(candidate_metadata("oauth_device_link", :both), "token_refresh", "invalid")
        ),
      malformed_metadata: insert_identity!(["invalid"])
    }

    related = insert_related_candidate!()
    related_before = related_snapshot(related)
    updated_at_before = updated_at_for(related.identity_id)

    assert :ok = migrate_up()

    for identity_id <- [browser, device, legacy, related.identity_id] do
      metadata = metadata_for(identity_id)
      refute Map.has_key?(metadata, "access_token_expires_at")
      refute Map.has_key?(metadata, "secret_expires_at")
      assert metadata["credential_epoch"] == 7
      assert metadata["preserve"] == %{"nested" => [1, %{"value" => "kept"}]}
    end

    assert metadata_for(browser)["token_refresh"]["trigger_kind"] == "oauth_browser_link"
    assert metadata_for(device)["token_refresh"]["trigger_kind"] == "oauth_device_link"
    assert metadata_for(legacy)["token_refresh"]["generation"] == 4

    for {kind, identity_id} <- excluded do
      assert metadata_for(identity_id) == excluded_metadata(kind)
    end

    assert updated_at_for(related.identity_id) == updated_at_before
    assert related_snapshot(related) == related_before

    repaired_snapshot = identities_snapshot([browser, device, legacy, related.identity_id])
    unrecord_migration!()
    assert :ok = migrate_up()

    assert identities_snapshot([browser, device, legacy, related.identity_id]) ==
             repaired_snapshot
  end

  test "a committed replacement writer wins while the migration waits on its row" do
    identity_id = insert_identity!(candidate_metadata("oauth_browser_link", :both))
    replacement = replacement_metadata()
    parent = self()

    writer =
      Task.async(fn ->
        Repo.checkout(fn ->
          Repo.transaction(fn ->
            writer_backend = backend_pid()

            Repo.query!(
              "SELECT id FROM upstream_identities WHERE id = $1::uuid FOR UPDATE",
              [Ecto.UUID.dump!(identity_id)]
            )

            send(parent, {:writer_locked, writer_backend})
            assert_receive :commit_writer, @detection_budget

            Repo.query!(
              "UPDATE upstream_identities SET metadata = $2::jsonb WHERE id = $1::uuid",
              [Ecto.UUID.dump!(identity_id), replacement]
            )
          end)
        end)

        send(parent, :writer_committed)
      end)

    assert_receive {:writer_locked, writer_backend}, @detection_budget

    migration =
      Task.async(fn ->
        send(parent, :migration_started)
        result = migrate_up()
        send(parent, {:migration_finished, result})
      end)

    assert_receive :migration_started, @detection_budget
    {migration_backend, migration_lock_modes} = await_migration_waiter!(writer_backend)
    assert writer_backend != migration_backend
    assert "RowExclusiveLock" in migration_lock_modes
    refute "AccessExclusiveLock" in migration_lock_modes

    send(writer.pid, :commit_writer)
    assert_receive :writer_committed, @detection_budget
    assert_receive {:migration_finished, :ok}, @detection_budget
    Task.await(writer, @detection_budget)
    Task.await(migration, @detection_budget)

    assert metadata_for(identity_id) == replacement

    assert get_in(metadata_for(identity_id), ["token_refresh", "access_token_expiry"]) ==
             unknown_marker()
  end

  test "rollback is a no-op, local budgets restore, and late legacy writes remain unknown" do
    identity_id = insert_identity!(candidate_metadata("oauth_device_link", :both))

    Repo.checkout(fn ->
      lock_timeout = show("lock_timeout")
      statement_timeout = show("statement_timeout")

      assert {:ok, true} =
               Repo.transaction(fn ->
                 run_migration_body!()
                 assert show("lock_timeout") == "15s"
                 assert show("statement_timeout") == "1min"
               end)

      assert show("lock_timeout") == lock_timeout
      assert show("statement_timeout") == statement_timeout
    end)

    assert :ok = migrate_up()
    repaired = metadata_for(identity_id)
    assert TokenRefreshMetadata.project_access_token_expiry(repaired).state == :unknown

    assert :ok = migrate_down()
    assert metadata_for(identity_id) == repaired

    late_old_writer =
      repaired
      |> Map.put("access_token_expires_at", "2031-01-02T03:04:05Z")
      |> Map.put("secret_expires_at", "2031-02-03T04:05:06Z")

    update_metadata!(identity_id, late_old_writer)

    assert TokenRefreshMetadata.project_access_token_expiry(metadata_for(identity_id)).state ==
             :unknown
  end

  defp candidate_metadata(trigger_kind, expiry_shape) do
    %{
      "credential_epoch" => 7,
      "preserve" => %{"nested" => [1, %{"value" => "kept"}]},
      "token_refresh" => %{
        "status" => "imported",
        "trigger_kind" => trigger_kind,
        "generation" => 4,
        "imported_at" => "2026-09-01T00:00:00Z",
        "diagnostic" => %{"kept" => true}
      }
    }
    |> put_expiry(expiry_shape)
  end

  defp put_expiry(metadata, :both) do
    metadata
    |> Map.put("access_token_expires_at", "2026-08-01T00:00:00Z")
    |> Map.put("secret_expires_at", "2026-08-02T00:00:00Z")
  end

  defp put_expiry(metadata, :canonical),
    do: Map.put(metadata, "access_token_expires_at", "2026-08-01T00:00:00Z")

  defp put_expiry(metadata, :legacy),
    do: Map.put(metadata, "secret_expires_at", "2026-08-02T00:00:00Z")

  defp put_expiry(metadata, :none), do: metadata

  defp replacement_metadata do
    candidate_metadata("oauth_browser_link", :none)
    |> put_in(["token_refresh", "access_token_expiry"], unknown_marker())
    |> put_in(["token_refresh", "generation"], 5)
    |> put_in(["token_refresh", "diagnostic"], %{"writer" => "committed"})
  end

  defp unknown_marker do
    %{
      "version" => 1,
      "credential_epoch" => 7,
      "state" => "unknown",
      "source" => "unavailable"
    }
  end

  defp excluded_metadata(:marker),
    do:
      candidate_metadata("oauth_browser_link", :both)
      |> put_in(["token_refresh", "access_token_expiry"], unknown_marker())

  defp excluded_metadata(:wrong_status),
    do:
      put_in(
        candidate_metadata("oauth_browser_link", :both),
        ["token_refresh", "status"],
        "succeeded"
      )

  defp excluded_metadata(:wrong_trigger),
    do:
      put_in(
        candidate_metadata("oauth_browser_link", :both),
        ["token_refresh", "trigger_kind"],
        "auth_json_import"
      )

  defp excluded_metadata(:missing_expiry), do: candidate_metadata("oauth_device_link", :none)

  defp excluded_metadata(:missing_refresh),
    do: Map.delete(candidate_metadata("oauth_device_link", :both), "token_refresh")

  defp excluded_metadata(:scalar_refresh),
    do: Map.put(candidate_metadata("oauth_device_link", :both), "token_refresh", "invalid")

  defp excluded_metadata(:malformed_metadata), do: ["invalid"]

  defp insert_identity!(metadata, opts \\ []) do
    identity_id = Ecto.UUID.generate()
    status = Keyword.get(opts, :status, "active")
    updated_at = ~U[2026-08-31 12:34:56.123456Z]

    Repo.query!(
      """
      INSERT INTO upstream_identities (
        id, account_label, onboarding_method, status, headers_profile_version,
        created_at, updated_at, metadata
      )
      VALUES ($1::uuid, $2, 'import', $3, 1, $4, $4, $5::jsonb)
      """,
      [
        Ecto.UUID.dump!(identity_id),
        "Synthetic OAuth expiry repair #{identity_id}",
        status,
        updated_at,
        metadata
      ]
    )

    on_exit(fn -> delete_identity!(identity_id) end)
    identity_id
  end

  defp insert_related_candidate! do
    pool_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    secret_id = Ecto.UUID.generate()
    now = ~U[2026-08-31 12:34:56.123456Z]

    Repo.query!(
      "INSERT INTO pools (id, slug, name, status, created_at, updated_at) VALUES ($1, $2, $3, 'active', $4, $4)",
      [Ecto.UUID.dump!(pool_id), "expiry-repair-#{pool_id}", "Synthetic expiry repair pool", now]
    )

    Repo.query!(
      """
      INSERT INTO upstream_identities (
        id, account_label, onboarding_method, status, headers_profile_version,
        created_at, updated_at, metadata
      ) VALUES ($1, $2, 'import', 'active', 1, $3, $3, $4::jsonb)
      """,
      [
        Ecto.UUID.dump!(identity_id),
        "Synthetic related expiry repair #{identity_id}",
        now,
        candidate_metadata("oauth_device_link", :both)
      ]
    )

    Repo.query!(
      """
      INSERT INTO pool_upstream_assignments (
        id, pool_id, upstream_identity_id, assignment_label, status,
        health_status, eligibility_status, created_at, updated_at, metadata
      ) VALUES ($1, $2, $3, 'Synthetic related assignment', 'active', 'active', 'eligible', $4, $4, $5::jsonb)
      """,
      [
        Ecto.UUID.dump!(assignment_id),
        Ecto.UUID.dump!(pool_id),
        Ecto.UUID.dump!(identity_id),
        now,
        %{"preserve" => true}
      ]
    )

    Repo.query!(
      """
      INSERT INTO encrypted_secrets (
        id, upstream_identity_id, secret_kind, key_version, ciphertext,
        nonce, aad, status, created_at
      ) VALUES ($1, $2, 'access_token', 'synthetic-v1', $3, $4, $5::jsonb, 'active', $6)
      """,
      [
        Ecto.UUID.dump!(secret_id),
        Ecto.UUID.dump!(identity_id),
        <<1, 2, 3, 4>>,
        <<5, 6, 7, 8>>,
        %{"purpose" => "synthetic"},
        now
      ]
    )

    on_exit(fn ->
      Repo.query!("DELETE FROM encrypted_secrets WHERE id = $1", [Ecto.UUID.dump!(secret_id)])

      Repo.query!("DELETE FROM pool_upstream_assignments WHERE id = $1", [
        Ecto.UUID.dump!(assignment_id)
      ])

      delete_identity!(identity_id)
      Repo.query!("DELETE FROM pools WHERE id = $1", [Ecto.UUID.dump!(pool_id)])
    end)

    %{identity_id: identity_id, assignment_id: assignment_id, secret_id: secret_id}
  end

  defp related_snapshot(related) do
    assert [[assignment]] =
             Repo.query!(
               "SELECT row_to_json(a) FROM pool_upstream_assignments a WHERE id = $1",
               [Ecto.UUID.dump!(related.assignment_id)]
             ).rows

    assert [[secret]] =
             Repo.query!("SELECT row_to_json(s) FROM encrypted_secrets s WHERE id = $1", [
               Ecto.UUID.dump!(related.secret_id)
             ]).rows

    %{assignment: assignment, secret: secret}
  end

  defp identities_snapshot(identity_ids), do: Map.new(identity_ids, &{&1, metadata_for(&1)})

  defp metadata_for(identity_id) do
    assert [[metadata]] =
             Repo.query!("SELECT metadata FROM upstream_identities WHERE id = $1::uuid", [
               Ecto.UUID.dump!(identity_id)
             ]).rows

    metadata
  end

  defp updated_at_for(identity_id) do
    assert [[updated_at]] =
             Repo.query!("SELECT updated_at FROM upstream_identities WHERE id = $1::uuid", [
               Ecto.UUID.dump!(identity_id)
             ]).rows

    updated_at
  end

  defp update_metadata!(identity_id, metadata) do
    Repo.query!("UPDATE upstream_identities SET metadata = $2::jsonb WHERE id = $1::uuid", [
      Ecto.UUID.dump!(identity_id),
      metadata
    ])
  end

  defp delete_identity!(identity_id) do
    Repo.query!("DELETE FROM upstream_identities WHERE id = $1::uuid", [
      Ecto.UUID.dump!(identity_id)
    ])
  end

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp await_migration_waiter!(blocker_pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @observer_budget

    rows =
      Repo.query!("""
      SELECT pid, pg_blocking_pids(pid)
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND wait_event_type = 'Lock'
        AND query LIKE 'UPDATE public.upstream_identities%'
      """).rows

    case Enum.find(rows, fn [_pid, blocking_pids] -> blocker_pid in blocking_pids end) do
      [waiter_pid, _blocking_pids] ->
        lock_modes =
          Repo.query!(
            """
            SELECT DISTINCT mode
            FROM pg_locks
            WHERE pid = $1
              AND relation = 'public.upstream_identities'::regclass
              AND granted
            ORDER BY mode
            """,
            [waiter_pid]
          ).rows
          |> Enum.map(&hd/1)

        {waiter_pid, lock_modes}

      nil ->
        retry_blocking_observation!(blocker_pid, deadline)
    end
  end

  defp retry_blocking_observation!(blocker_pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("no expiry repair UPDATE was lock-blocked by writer backend #{blocker_pid}")
    else
      receive do
      after
        20 -> await_migration_waiter!(blocker_pid, deadline)
      end
    end
  end

  defp show(setting), do: Repo.query!("SHOW #{setting}").rows |> hd() |> hd()

  defp run_migration_body! do
    Runner.run(
      Repo,
      Repo.config(),
      @migration_version,
      RepairStaleOauthAccessTokenExpiry,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp unrecord_migration! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@migration_version])
  end

  defp migrate_up do
    {result, _log} =
      with_log(fn ->
        Migrator.up(Repo, @migration_version, RepairStaleOauthAccessTokenExpiry, log: false)
      end)

    result
  end

  defp migrate_down do
    {result, _log} =
      with_log(fn ->
        Migrator.down(Repo, @migration_version, RepairStaleOauthAccessTokenExpiry, log: false)
      end)

    result
  end
end
