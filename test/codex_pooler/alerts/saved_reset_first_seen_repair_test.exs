defmodule CodexPooler.Alerts.SavedResetFirstSeenRepairTest do
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
  @repair_reason "saved_reset_first_seen_v1_predates_rule_baseline"

  @tag :saved_reset_banked_first_seen
  test "migration resolves stale v1 saved-reset first-seen incidents without deliveries" do
    Repo.delete_all(Oban.Job)

    baseline = timestamp(~U[2026-07-03 08:50:27Z])
    stale_first_seen = timestamp(~U[2026-07-01 20:27:02Z])
    post_baseline_first_seen = timestamp(~U[2026-07-03 09:15:00Z])
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    rule =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        metadata: %{@baseline_key => DateTime.to_iso8601(baseline)},
        created_at: timestamp(~U[2026-07-03 08:45:00Z])
      )

    fallback_rule =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        metadata: %{},
        created_at: baseline
      )

    stale_incidents =
      [
        legacy_saved_reset_incident!(
          pool,
          rule,
          identity,
          "2026-07-05T00:00:00Z",
          stale_first_seen
        ),
        legacy_saved_reset_incident!(
          pool,
          rule,
          identity,
          "2026-07-06T00:00:00Z",
          stale_first_seen
        ),
        legacy_saved_reset_incident!(
          pool,
          fallback_rule,
          identity,
          "2026-07-10T00:00:00Z",
          stale_first_seen
        )
      ]

    post_baseline_incident =
      legacy_saved_reset_incident!(
        pool,
        rule,
        identity,
        "2026-07-07T00:00:00Z",
        post_baseline_first_seen
      )

    other_kind_incident =
      alert_incident_fixture(
        pool: pool,
        rule_kind: "upstream_auth_state",
        state: AlertIncident.open_state(),
        safe_evidence_snapshot: %{
          "reason_code" => "upstream_auth_state",
          "reset_first_seen_at" => DateTime.to_iso8601(stale_first_seen)
        }
      )

    missing_first_seen_incident =
      legacy_saved_reset_incident!(pool, rule, identity, "2026-07-08T00:00:00Z", nil)

    malformed_first_seen_incident =
      legacy_saved_reset_incident!(
        pool,
        rule,
        identity,
        "2026-07-09T00:00:00Z",
        "not-a-timestamp"
      )

    malformed_dedupe_incident =
      saved_reset_incident_with_dedupe_key!(
        pool,
        rule,
        identity,
        "alerts:legacy:#{@rule_kind}:upstream_identity:#{identity.id}:reset_expires_at:bad",
        "2026-07-11T00:00:00Z",
        stale_first_seen
      )

    run_repair_migration!()

    for incident <- stale_incidents do
      repaired = Repo.get!(AlertIncident, incident.id)
      assert repaired.state == AlertIncident.resolved_state()
      assert %DateTime{} = repaired.resolved_at
      assert repaired.suppression_metadata["repair_reason"] == @repair_reason

      assert repaired.suppression_metadata["repair_source"] ==
               "saved_reset_first_seen_v1_migration"

      assert repaired.suppression_metadata["repaired_dedupe_version"] == "v1"

      assert {:ok, _repaired_at, _offset} =
               DateTime.from_iso8601(repaired.suppression_metadata["repaired_at"])

      assert [target] =
               Repo.all(
                 from target in AlertIncidentTarget,
                   where: target.incident_id == ^incident.id
               )

      assert %DateTime{} = target.resolved_at
    end

    assert Repo.get!(AlertIncident, post_baseline_incident.id).state == AlertIncident.open_state()
    assert Repo.get!(AlertIncident, other_kind_incident.id).state == AlertIncident.open_state()

    assert Repo.get!(AlertIncident, missing_first_seen_incident.id).state ==
             AlertIncident.open_state()

    assert Repo.get!(AlertIncident, malformed_first_seen_incident.id).state ==
             AlertIncident.open_state()

    assert Repo.get!(AlertIncident, malformed_dedupe_incident.id).state ==
             AlertIncident.open_state()

    assert all_enqueued(worker: AlertDeliveryWorker) == []

    repaired_states =
      Map.new(stale_incidents, fn incident ->
        repaired = Repo.get!(AlertIncident, incident.id)
        {incident.id, {repaired.resolved_at, repaired.suppression_metadata}}
      end)

    run_repair_migration!()

    assert Map.new(stale_incidents, fn incident ->
             repaired = Repo.get!(AlertIncident, incident.id)
             {incident.id, {repaired.resolved_at, repaired.suppression_metadata}}
           end) == repaired_states

    assert all_enqueued(worker: AlertDeliveryWorker) == []
  end

  defp legacy_saved_reset_incident!(pool, rule, identity, expires_at, first_seen_at) do
    first_seen_iso = maybe_iso8601(first_seen_at)

    incident =
      alert_incident_fixture(
        pool: pool,
        upstream_identity: identity,
        dedupe_key: saved_reset_v1_dedupe_key(identity, expires_at),
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        state: AlertIncident.open_state(),
        safe_evidence_snapshot: %{
          "reason_code" => "saved_reset_banked_first_seen",
          "reset_expires_at" => expires_at,
          "reset_first_seen_at" => first_seen_iso
        }
      )

    alert_incident_target_fixture(incident, rule, pool,
      metadata: %{
        "reason_code" => "saved_reset_banked_first_seen",
        "reset_expires_at" => expires_at,
        "reset_first_seen_at" => first_seen_iso
      }
    )

    incident
  end

  defp saved_reset_incident_with_dedupe_key!(
         pool,
         rule,
         identity,
         dedupe_key,
         expires_at,
         first_seen_at
       ) do
    first_seen_iso = maybe_iso8601(first_seen_at)

    incident =
      alert_incident_fixture(
        pool: pool,
        upstream_identity: identity,
        dedupe_key: dedupe_key,
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        state: AlertIncident.open_state(),
        safe_evidence_snapshot: %{
          "reason_code" => "saved_reset_banked_first_seen",
          "reset_expires_at" => expires_at,
          "reset_first_seen_at" => first_seen_iso
        }
      )

    alert_incident_target_fixture(incident, rule, pool,
      metadata: %{
        "reason_code" => "saved_reset_banked_first_seen",
        "reset_expires_at" => expires_at,
        "reset_first_seen_at" => first_seen_iso
      }
    )

    incident
  end

  defp saved_reset_v1_dedupe_key(identity, expires_at) do
    "alerts:v1:#{@rule_kind}:upstream_identity:#{identity.id}:reset_expires_at:#{expires_at}"
  end

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp maybe_iso8601(value), do: value

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
