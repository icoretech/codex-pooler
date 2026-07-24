unless Code.ensure_loaded?(
         CodexPooler.Repo.Migrations.AddSavedResetFirstSeenLedgerToUpstreamIdentities
       ) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260724031931_add_saved_reset_first_seen_ledger_to_upstream_identities.exs",
      __DIR__
    )
  )
end

defmodule CodexPooler.Upstreams.SavedResetFirstSeenLedgerMigrationTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Repo
  alias CodexPooler.Repo.Migrations.AddSavedResetFirstSeenLedgerToUpstreamIdentities
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  @migration_version 20_260_724_031_931
  @saved_reset_detail_max_bytes 1_048_576

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Migrator.up(
        Repo,
        @migration_version,
        AddSavedResetFirstSeenLedgerToUpstreamIdentities,
        log: false
      )

      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "migration seeds only valid canonical expiration and first-seen pairs" do
    assert :ok =
             Migrator.down(
               Repo,
               @migration_version,
               AddSavedResetFirstSeenLedgerToUpstreamIdentities,
               log: false
             )

    identity_id = Ecto.UUID.generate()
    delete_identity_on_exit(identity_id)

    metadata = %{
      "saved_resets" => %{
        "available_expirations" => [
          entry("2026-08-01T02:00:00.100+02:00", "2026-07-03T00:00:00Z"),
          entry("2026-08-01T00:00:00.100000Z", "2026-07-01T02:00:00+02:00"),
          entry("2026-08-02T00:00:00Z", "2026-07-02T00:00:00.250Z"),
          entry("malformed", "2026-07-01T00:00:00Z"),
          %{"expires_at" => "2026-08-03T00:00:00Z"},
          %{"expires_at" => 123, "first_seen_at" => "2026-07-01T00:00:00Z"},
          "not-an-entry"
        ]
      }
    }

    insert_identity!(identity_id, metadata)

    assert :ok =
             Migrator.up(
               Repo,
               @migration_version,
               AddSavedResetFirstSeenLedgerToUpstreamIdentities,
               log: false
             )

    assert [[ledger]] =
             Repo.query!(
               """
               SELECT saved_reset_first_seen_ledger
               FROM upstream_identities
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(identity_id)]
             ).rows

    assert ledger == %{
             "version" => 1,
             "entries" => [
               entry("2026-08-01T00:00:00.100000Z", "2026-07-01T00:00:00Z"),
               entry("2026-08-02T00:00:00Z", "2026-07-02T00:00:00.250000Z")
             ]
           }
  end

  test "database column is non-null and supplies the empty version one default" do
    identity_id = Ecto.UUID.generate()
    delete_identity_on_exit(identity_id)
    insert_identity!(identity_id, %{})

    assert [[false, default_expression]] =
             Repo.query!("""
             SELECT is_nullable = 'YES', column_default
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'upstream_identities'
               AND column_name = 'saved_reset_first_seen_ledger'
             """).rows

    assert default_expression =~ "::jsonb"

    assert [[%{"version" => 1, "entries" => []}]] =
             Repo.query!(
               """
               SELECT saved_reset_first_seen_ledger
               FROM upstream_identities
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(identity_id)]
             ).rows
  end

  test "migration leaves oversized legacy metadata unchanged and ledger empty" do
    assert :ok =
             Migrator.down(
               Repo,
               @migration_version,
               AddSavedResetFirstSeenLedgerToUpstreamIdentities,
               log: false
             )

    identity_id = Ecto.UUID.generate()
    delete_identity_on_exit(identity_id)

    metadata = %{
      "saved_resets" => %{
        "available_expirations" => [
          Map.put(
            entry("2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z"),
            "padding",
            String.duplicate("x", @saved_reset_detail_max_bytes)
          )
        ]
      }
    }

    insert_identity!(identity_id, metadata)

    assert [[stored_size]] =
             Repo.query!(
               """
               SELECT pg_column_size(metadata -> 'saved_resets' -> 'available_expirations')
               FROM upstream_identities
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(identity_id)]
             ).rows

    assert stored_size > @saved_reset_detail_max_bytes

    assert :ok =
             Migrator.up(
               Repo,
               @migration_version,
               AddSavedResetFirstSeenLedgerToUpstreamIdentities,
               log: false
             )

    assert [[^metadata, %{"version" => 1, "entries" => []}]] =
             Repo.query!(
               """
               SELECT metadata, saved_reset_first_seen_ledger
               FROM upstream_identities
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(identity_id)]
             ).rows
  end

  defp insert_identity!(identity_id, metadata) do
    Repo.query!(
      """
      INSERT INTO upstream_identities (
        id,
        account_label,
        onboarding_method,
        metadata
      )
      VALUES ($1::uuid, 'Synthetic migration identity', 'import', $2::jsonb)
      """,
      [Ecto.UUID.dump!(identity_id), metadata]
    )
  end

  defp delete_identity_on_exit(identity_id) do
    on_exit(fn ->
      Repo.query!(
        "DELETE FROM upstream_identities WHERE id = $1::uuid",
        [Ecto.UUID.dump!(identity_id)]
      )
    end)
  end

  defp entry(expires_at, first_seen_at) do
    %{"expires_at" => expires_at, "first_seen_at" => first_seen_at}
  end
end
