defmodule CodexPooler.Alerts.SavedResetNewGrantAlertTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertRuleChannel}
  alias CodexPooler.Jobs.{AlertDeliveryWorker, AlertEvaluationWorker}
  alias CodexPooler.Repo

  @rule_kind "upstream_saved_reset_banked_first_seen"
  @baseline ~U[2026-05-30 17:00:00.000000Z]

  # Each saved reset the provider grants is one alert: the incident key stays
  # per upstream identity, so a grant that arrives after an earlier grant's
  # incident resolved (or while it is still open) must open a new incident and
  # reach the linked channel again, while the same grant never alerts twice.
  @tag :saved_reset_banked_first_seen
  test "a saved reset granted after an earlier grant's incident resolved alerts again, once" do
    {rule, identity} = saved_reset_rule_with_channel("new-grant-after-resolve")

    set_saved_resets!(identity, [grant(~U[2026-06-20 00:00:00Z], ~U[2026-05-30 18:01:00Z])])
    evaluate!(rule, ~U[2026-05-30 18:05:00Z])
    assert [%AlertIncident{state: "open"} = first] = incidents(identity)
    assert delivered_incident_ids() == [first.id]

    set_saved_resets!(identity, [])
    evaluate!(rule, ~U[2026-05-30 18:10:00Z])
    assert [%AlertIncident{state: "resolved"}] = incidents(identity)

    set_saved_resets!(identity, [grant(~U[2026-06-29 00:00:00Z], ~U[2026-06-05 09:31:00Z])])
    evaluate!(rule, ~U[2026-06-05 09:35:00Z])

    assert [%AlertIncident{state: "resolved", id: first_id}, %AlertIncident{state: "open"} = second] =
             incidents(identity)

    assert first_id == first.id
    assert second.safe_evidence_snapshot["latest_reset_first_seen_at"] == "2026-06-05T09:31:00Z"
    assert delivered_incident_ids() == Enum.sort([first.id, second.id])

    # The same grant stays in the bank: later evaluations never deliver it again.
    evaluate!(rule, ~U[2026-06-05 09:40:00Z])
    assert length(incidents(identity)) == 2
    assert delivered_incident_ids() == Enum.sort([first.id, second.id])
  end

  @tag :saved_reset_banked_first_seen
  test "a grant that disappears and reappears with its first-seen time never alerts twice" do
    {rule, identity} = saved_reset_rule_with_channel("grant-flap")
    banked = grant(~U[2026-06-20 00:00:00Z], ~U[2026-05-30 18:01:00Z])

    set_saved_resets!(identity, [banked])
    evaluate!(rule, ~U[2026-05-30 18:05:00Z])
    assert [%AlertIncident{} = incident] = incidents(identity)

    set_saved_resets!(identity, [])
    evaluate!(rule, ~U[2026-05-30 18:10:00Z])
    set_saved_resets!(identity, [banked])
    evaluate!(rule, ~U[2026-05-30 18:15:00Z])

    assert [%AlertIncident{id: id, state: "resolved"}] = incidents(identity)
    assert id == incident.id
    assert delivered_incident_ids() == [incident.id]
  end

  @tag :saved_reset_banked_first_seen
  test "a new grant while an earlier one is still banked supersedes its open incident" do
    {rule, identity} = saved_reset_rule_with_channel("new-grant-while-banked")
    older = grant(~U[2026-06-20 00:00:00Z], ~U[2026-05-30 18:01:00Z])

    set_saved_resets!(identity, [older])
    evaluate!(rule, ~U[2026-05-30 18:05:00Z])
    assert [%AlertIncident{state: "open"} = first] = incidents(identity)

    set_saved_resets!(identity, [older, grant(~U[2026-06-21 00:00:00Z], ~U[2026-05-31 07:02:00Z])])
    evaluate!(rule, ~U[2026-05-31 07:05:00Z])

    assert [%AlertIncident{id: first_id} = superseded, %AlertIncident{state: "open"} = second] =
             incidents(identity)

    assert first_id == first.id
    assert superseded.state == "resolved"
    assert superseded.suppression_metadata["superseded_reason"] == "newer_saved_reset_first_seen"
    assert second.safe_evidence_snapshot["new_reset_count"] == 2
    assert second.safe_evidence_snapshot["latest_reset_first_seen_at"] == "2026-05-31T07:02:00Z"
    assert delivered_incident_ids() == Enum.sort([first.id, second.id])

    # Consuming the newer grant leaves only the already-alerted older one.
    set_saved_resets!(identity, [older])
    evaluate!(rule, ~U[2026-05-31 07:10:00Z])
    assert length(incidents(identity)) == 2
    assert delivered_incident_ids() == Enum.sort([first.id, second.id])
  end

  defp saved_reset_rule_with_channel(slug) do
    pool = pool_fixture(%{slug: "#{slug}-#{System.unique_integer([:positive])}", name: slug})
    %{identity: identity} = upstream_assignment_fixture(pool)

    rule =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: @rule_kind,
        severity: "info",
        cooldown_minutes: 30,
        created_at: @baseline,
        updated_at: @baseline
      )

    channel = alert_channel_fixture(%{display_name: "Saved reset email #{slug}"})

    %AlertRuleChannel{}
    |> AlertRuleChannel.changeset(%{alert_rule_id: rule.id, alert_channel_id: channel.id, created_at: @baseline})
    |> Repo.insert!()

    {rule, identity}
  end

  defp grant(expires_at, first_seen_at) do
    %{"expires_at" => DateTime.to_iso8601(expires_at), "first_seen_at" => DateTime.to_iso8601(first_seen_at)}
  end

  defp set_saved_resets!(identity, expirations) do
    metadata = %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => length(expirations),
        "available_expirations" => expirations
      }
    }

    identity
    |> Ecto.Changeset.change(metadata: metadata)
    |> Repo.update!()
  end

  defp evaluate!(rule, at) do
    at = %{at | microsecond: {0, 6}}

    args = %{
      "alert_rule_id" => rule.id,
      "evaluation_window_started_at" => DateTime.to_iso8601(at),
      "trigger_kind" => "test"
    }

    assert :ok = perform_job(AlertEvaluationWorker, args, attempted_at: at)
  end

  defp incidents(identity) do
    Repo.all(
      from incident in AlertIncident,
        where: incident.rule_kind == @rule_kind and incident.upstream_identity_id == ^identity.id,
        order_by: [asc: incident.first_seen_at, asc: incident.id]
    )
  end

  defp delivered_incident_ids do
    [worker: AlertDeliveryWorker]
    |> all_enqueued()
    |> Enum.map(& &1.args["alert_incident_id"])
    |> Enum.sort()
  end
end
