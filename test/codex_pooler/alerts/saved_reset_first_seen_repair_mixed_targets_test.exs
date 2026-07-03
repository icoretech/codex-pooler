defmodule CodexPooler.Alerts.SavedResetFirstSeenRepairMixedTargetsTest do
  use CodexPooler.DataCase, async: false

  alias Ecto.Migration.Runner

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts.Schemas.{
    AlertIncident,
    AlertIncidentTarget
  }

  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Repo

  @rule_kind "upstream_saved_reset_banked_first_seen"
  @baseline_key "saved_reset_first_seen_baseline_at"

  @tag :saved_reset_banked_first_seen
  test "migration resolves only stale targets for mixed v1 saved-reset first-seen incidents" do
    Repo.delete_all(Oban.Job)

    baseline = timestamp(~U[2026-07-03 08:50:27Z])
    stale_first_seen = timestamp(~U[2026-07-01 20:27:02Z])
    post_baseline_first_seen = timestamp(~U[2026-07-03 09:15:00Z])
    pool = pool_fixture()
    valid_pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    stale_rule =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        metadata: %{@baseline_key => DateTime.to_iso8601(baseline)},
        created_at: timestamp(~U[2026-07-03 08:45:00Z])
      )

    valid_rule =
      alert_rule_fixture(valid_pool,
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        metadata: %{@baseline_key => DateTime.to_iso8601(baseline)},
        created_at: timestamp(~U[2026-07-03 08:45:00Z])
      )

    incident =
      alert_incident_fixture(
        pool: nil,
        pool_id: nil,
        upstream_identity: identity,
        dedupe_key: saved_reset_v1_dedupe_key(identity, "2026-07-05T00:00:00Z"),
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        state: AlertIncident.open_state(),
        safe_evidence_snapshot: %{
          "reason_code" => "saved_reset_banked_first_seen",
          "reset_expires_at" => "2026-07-05T00:00:00Z",
          "reset_first_seen_at" => DateTime.to_iso8601(stale_first_seen)
        }
      )

    stale_target =
      alert_incident_target_fixture(incident, stale_rule, pool,
        metadata:
          saved_reset_target_metadata(
            "2026-07-05T00:00:00Z",
            DateTime.to_iso8601(stale_first_seen)
          )
      )

    valid_target =
      alert_incident_target_fixture(incident, valid_rule, valid_pool,
        metadata:
          saved_reset_target_metadata(
            "2026-07-06T00:00:00Z",
            DateTime.to_iso8601(post_baseline_first_seen)
          )
      )

    run_repair_migration!()

    repaired_incident = Repo.get!(AlertIncident, incident.id)
    assert repaired_incident.state == AlertIncident.open_state()
    assert repaired_incident.resolved_at == nil
    assert repaired_incident.suppression_metadata == %{}

    assert %DateTime{} = Repo.get!(AlertIncidentTarget, stale_target.id).resolved_at
    assert Repo.get!(AlertIncidentTarget, valid_target.id).resolved_at == nil
    assert all_enqueued(worker: AlertDeliveryWorker) == []
  end

  defp saved_reset_v1_dedupe_key(identity, expires_at) do
    "alerts:v1:#{@rule_kind}:upstream_identity:#{identity.id}:reset_expires_at:#{expires_at}"
  end

  defp saved_reset_target_metadata(expires_at, first_seen_at) do
    %{
      "reason_code" => "saved_reset_banked_first_seen",
      "reset_expires_at" => expires_at,
      "reset_first_seen_at" => first_seen_at
    }
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}

  defp run_repair_migration! do
    Runner.run(
      Repo,
      Repo.config(),
      20_260_703_102_811,
      repair_migration(),
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp repair_migration do
    module = CodexPooler.Repo.Migrations.RepairSavedResetFirstSeenV1Incidents

    unless Code.ensure_loaded?(module) do
      Code.require_file(
        "../../../priv/repo/migrations/20260703102811_repair_saved_reset_first_seen_v1_incidents.exs",
        __DIR__
      )
    end

    module
  end
end
