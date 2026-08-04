unless Code.ensure_loaded?(CodexPooler.Repo.Migrations.ClassifyLegacySavedResetRecovery) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260804110945_classify_legacy_saved_reset_recovery.exs",
      __DIR__
    )
  )
end

defmodule CodexPooler.Upstreams.SavedResetLegacyRecoveryMigrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias CodexPooler.Repo
  alias CodexPooler.Repo.Migrations.ClassifyLegacySavedResetRecovery
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  @migration_version 20_260_804_110_945
  @legacy_marker %{"version" => 1, "state" => "unresolved"}

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

  test "globally marks only markerless pre-v1 consuming rows and preserves their remaining JSON" do
    active_candidate = insert_identity!(pre_v1_consuming_metadata())
    inactive_candidate = insert_identity!(pre_v1_consuming_metadata(), status: "paused")
    marked = insert_identity!(pre_v1_consuming_metadata(legacy_recovery: @legacy_marker))

    changed_marker =
      insert_identity!(
        pre_v1_consuming_metadata(legacy_recovery: %{"version" => 2, "state" => "changed"})
      )

    replay_controls =
      for provider_replay <- [nil, "invalid", [], %{"version" => 2, "mode" => "future"}] do
        {provider_replay,
         insert_identity!(pre_v1_consuming_metadata(provider_replay: provider_replay))}
      end

    terminal =
      insert_identity!(%{
        "saved_reset_redemption" => %{"status" => "succeeded", "phase" => "confirmed_by_quota"}
      })

    malformed_redemption = insert_identity!(%{"saved_reset_redemption" => "invalid"})
    non_object_metadata = insert_identity!(["invalid"])

    assert :ok = migrate_up()

    assert legacy_marker(metadata_for(active_candidate)) == @legacy_marker
    assert legacy_marker(metadata_for(inactive_candidate)) == @legacy_marker

    assert remove_legacy_marker(metadata_for(active_candidate)) == pre_v1_consuming_metadata()
    assert remove_legacy_marker(metadata_for(inactive_candidate)) == pre_v1_consuming_metadata()

    assert metadata_for(marked) == pre_v1_consuming_metadata(legacy_recovery: @legacy_marker)

    assert metadata_for(changed_marker) ==
             pre_v1_consuming_metadata(legacy_recovery: %{"version" => 2, "state" => "changed"})

    for {provider_replay, identity_id} <- replay_controls do
      assert metadata_for(identity_id) ==
               pre_v1_consuming_metadata(provider_replay: provider_replay)
    end

    assert metadata_for(terminal) == %{
             "saved_reset_redemption" => %{
               "status" => "succeeded",
               "phase" => "confirmed_by_quota"
             }
           }

    assert metadata_for(malformed_redemption) == %{"saved_reset_redemption" => "invalid"}
    assert metadata_for(non_object_metadata) == ["invalid"]

    unrecord_migration!()
    assert :ok = migrate_up()
    assert legacy_marker(metadata_for(active_candidate)) == @legacy_marker

    late_markerless = insert_identity!(pre_v1_consuming_metadata())
    assert metadata_for(late_markerless) == pre_v1_consuming_metadata()
  end

  test "down removes only the exact owned marker and up after down restores the candidate set" do
    candidate = insert_identity!(pre_v1_consuming_metadata())
    phase_changed = insert_identity!(pre_v1_consuming_metadata())
    replay_changed = insert_identity!(pre_v1_consuming_metadata())

    changed_marker =
      insert_identity!(
        pre_v1_consuming_metadata(legacy_recovery: %{"version" => 2, "state" => "changed"})
      )

    versioned = insert_identity!(pre_v1_consuming_metadata(provider_replay: %{"version" => 1}))

    assert :ok = migrate_up()
    assert legacy_marker(metadata_for(candidate)) == @legacy_marker

    update_metadata!(phase_changed, fn metadata ->
      put_in(metadata, ["saved_reset_redemption", "phase"], "consumed_pending_probe")
    end)

    update_metadata!(replay_changed, fn metadata ->
      put_in(metadata, ["saved_reset_redemption", "provider_replay"], "present_after_up")
    end)

    assert :ok = migrate_down()

    assert metadata_for(candidate) == pre_v1_consuming_metadata()

    assert get_in(metadata_for(phase_changed), ["saved_reset_redemption", "legacy_recovery"]) ==
             @legacy_marker

    assert get_in(metadata_for(replay_changed), ["saved_reset_redemption", "legacy_recovery"]) ==
             @legacy_marker

    assert metadata_for(changed_marker) ==
             pre_v1_consuming_metadata(legacy_recovery: %{"version" => 2, "state" => "changed"})

    assert metadata_for(versioned) ==
             pre_v1_consuming_metadata(provider_replay: %{"version" => 1})

    record_migration!()
    assert :ok = migrate_down()
    assert :ok = migrate_up()

    assert legacy_marker(metadata_for(candidate)) == @legacy_marker

    assert get_in(metadata_for(phase_changed), ["saved_reset_redemption", "legacy_recovery"]) ==
             @legacy_marker

    assert get_in(metadata_for(replay_changed), ["saved_reset_redemption", "legacy_recovery"]) ==
             @legacy_marker

    assert metadata_for(changed_marker) ==
             pre_v1_consuming_metadata(legacy_recovery: %{"version" => 2, "state" => "changed"})
  end

  defp pre_v1_consuming_metadata(opts \\ []) do
    redemption = %{
      "status" => "redeeming",
      "phase" => "consuming",
      "preserve" => %{"nested" => [1, %{"x" => "y"}]}
    }

    Enum.reduce(opts, redemption, fn
      {:legacy_recovery, value}, redemption -> Map.put(redemption, "legacy_recovery", value)
      {:provider_replay, value}, redemption -> Map.put(redemption, "provider_replay", value)
    end)
    |> then(&%{"saved_reset_redemption" => &1})
  end

  defp insert_identity!(metadata, opts \\ []) do
    identity_id = Ecto.UUID.generate()
    status = Keyword.get(opts, :status, "active")

    Repo.query!(
      """
      INSERT INTO upstream_identities (
        id,
        account_label,
        onboarding_method,
        status,
        headers_profile_version,
        created_at,
        updated_at,
        metadata
      )
      VALUES ($1::uuid, $2, 'import', $3, 1, NOW(), NOW(), $4::jsonb)
      """,
      [
        Ecto.UUID.dump!(identity_id),
        "Synthetic migration identity #{identity_id}",
        status,
        metadata
      ]
    )

    on_exit(fn ->
      Repo.query!("DELETE FROM upstream_identities WHERE id = $1::uuid", [
        Ecto.UUID.dump!(identity_id)
      ])
    end)

    identity_id
  end

  defp metadata_for(identity_id) do
    assert [[metadata]] =
             Repo.query!(
               "SELECT metadata FROM upstream_identities WHERE id = $1::uuid",
               [Ecto.UUID.dump!(identity_id)]
             ).rows

    metadata
  end

  defp update_metadata!(identity_id, update) do
    metadata = metadata_for(identity_id) |> update.()

    Repo.query!(
      "UPDATE upstream_identities SET metadata = $2::jsonb WHERE id = $1::uuid",
      [Ecto.UUID.dump!(identity_id), metadata]
    )
  end

  defp unrecord_migration! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@migration_version])
  end

  defp record_migration! do
    Repo.query!("INSERT INTO schema_migrations (version, inserted_at) VALUES ($1, NOW())", [
      @migration_version
    ])
  end

  defp legacy_marker(metadata),
    do: get_in(metadata, ["saved_reset_redemption", "legacy_recovery"])

  defp remove_legacy_marker(metadata),
    do: update_in(metadata, ["saved_reset_redemption"], &Map.delete(&1, "legacy_recovery"))

  defp migrate_up do
    {result, _log} =
      with_log(fn ->
        Migrator.up(
          Repo,
          @migration_version,
          ClassifyLegacySavedResetRecovery,
          log: false
        )
      end)

    result
  end

  defp migrate_down do
    {result, _log} =
      with_log(fn ->
        Migrator.down(
          Repo,
          @migration_version,
          ClassifyLegacySavedResetRecovery,
          log: false
        )
      end)

    result
  end
end
