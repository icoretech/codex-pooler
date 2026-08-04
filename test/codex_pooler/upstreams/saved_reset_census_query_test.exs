defmodule CodexPooler.Upstreams.SavedResetCensusQueryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo

  test "aggregate-only saved reset censuses distinguish active, exact-marked, and markerless pre-v1 rows" do
    insert_assignment_identity!(pre_v1_consuming_metadata())
    insert_assignment_identity!(pre_v1_consuming_metadata(legacy_recovery: exact_legacy_marker()))
    insert_assignment_identity!(pre_v1_consuming_metadata(provider_replay: %{"version" => 1}))
    insert_assignment_identity!(pre_v1_consuming_metadata(legacy_recovery: %{"version" => 2}))

    insert_assignment_identity!(
      pre_v1_consuming_metadata(legacy_recovery: exact_legacy_marker()),
      identity_status: "paused"
    )

    upstream_identity_fixture(metadata: pre_v1_consuming_metadata())

    assert [[2]] = Repo.query!(active_operational_impact_query()).rows
    assert [[2, 2]] = Repo.query!(global_legacy_totals_query()).rows
  end

  defp insert_assignment_identity!(metadata, opts \\ []) do
    upstream_assignment_fixture(pool_fixture(), %{
      identity_metadata: metadata,
      identity_status: Keyword.get(opts, :identity_status, "active")
    })
  end

  defp pre_v1_consuming_metadata(opts \\ []) do
    redemption = %{
      "status" => "redeeming",
      "phase" => "consuming"
    }

    redemption =
      case Keyword.fetch(opts, :legacy_recovery) do
        {:ok, value} -> Map.put(redemption, "legacy_recovery", value)
        :error -> redemption
      end

    redemption =
      case Keyword.fetch(opts, :provider_replay) do
        {:ok, value} -> Map.put(redemption, "provider_replay", value)
        :error -> redemption
      end

    %{"saved_reset_redemption" => redemption}
  end

  defp exact_legacy_marker, do: %{"version" => 1, "state" => "unresolved"}

  defp active_operational_impact_query do
    """
    SELECT COUNT(*) AS active_pre_v1_consuming_rows
    FROM upstream_identities AS identities
    JOIN pool_upstream_assignments AS assignments
      ON assignments.upstream_identity_id = identities.id
    JOIN pools
      ON pools.id = assignments.pool_id
    WHERE identities.status = 'active'
      AND assignments.status = 'active'
      AND pools.status = 'active'
      AND identities.metadata #>> '{saved_reset_redemption,status}' = 'redeeming'
      AND identities.metadata #>> '{saved_reset_redemption,phase}' = 'consuming'
      AND NOT (identities.metadata #> '{saved_reset_redemption}' ? 'provider_replay')
      AND (
        identities.metadata #> '{saved_reset_redemption,legacy_recovery}' =
          '{"version": 1, "state": "unresolved"}'::jsonb
        OR NOT (identities.metadata #> '{saved_reset_redemption}' ? 'legacy_recovery')
      )
    """
  end

  defp global_legacy_totals_query do
    """
    SELECT
      COUNT(*) FILTER (
        WHERE identities.metadata #> '{saved_reset_redemption,legacy_recovery}' =
          '{"version": 1, "state": "unresolved"}'::jsonb
      ) AS exact_marked_pre_v1_consuming_rows,
      COUNT(*) FILTER (
        WHERE NOT (identities.metadata #> '{saved_reset_redemption}' ? 'legacy_recovery')
      ) AS markerless_pre_v1_consuming_rows
    FROM upstream_identities AS identities
    WHERE identities.metadata #>> '{saved_reset_redemption,status}' = 'redeeming'
      AND identities.metadata #>> '{saved_reset_redemption,phase}' = 'consuming'
      AND NOT (identities.metadata #> '{saved_reset_redemption}' ? 'provider_replay')
    """
  end
end
