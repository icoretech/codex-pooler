defmodule CodexPooler.Alerts.SavedResetDedupeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts

  alias CodexPooler.Alerts.Schemas.{
    AlertIncident,
    AlertIncidentTarget,
    AlertRuleChannel
  }

  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Repo

  @rule_kind "upstream_saved_reset_banked_first_seen"
  @expires_at "2026-06-01T00:00:00Z"

  @tag :saved_reset_banked_first_seen
  test "records one incident and one delayed channel delivery for first-seen saved resets" do
    Repo.delete_all(Oban.Job)
    {pool_alpha, rule_alpha, identity} = saved_reset_pool("pool-alpha")
    {pool_beta, rule_beta, _identity} = saved_reset_pool("pool-beta")
    channel = alert_channel_fixture(%{display_name: "Saved reset email"})
    first_seen = timestamp(~U[2026-05-30 13:00:00Z])
    second_seen = timestamp(~U[2026-05-30 13:05:00Z])
    dedupe_key = saved_reset_dedupe_key(identity)

    first_result = record_saved_reset!(rule_alpha, identity, first_seen, "no-channel-first")
    assert first_result.inserted? == true
    assert first_result.target_inserted? == true
    assert first_result.delivery_channel_ids_due == []
    assert delivery_job_count() == 0

    link_rule_channel!(rule_beta, channel, second_seen)

    channel_result =
      record_saved_reset!(rule_beta, identity, second_seen, "channel-linked-second")

    assert channel_result.incident.id == first_result.incident.id
    assert channel_result.target_inserted? == true
    assert channel_result.delivery_channel_ids_due == [channel.id]
    assert :ok = enqueue_lifecycle_deliveries(channel_result)
    assert delivery_job_count() == 1

    repeat_result =
      record_saved_reset!(rule_beta, identity, timestamp(~U[2026-05-30 13:10:00Z]), "repeat")

    assert repeat_result.target_inserted? == false
    assert repeat_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(repeat_result)
    assert delivery_job_count() == 1

    assert {:ok, %AlertIncident{state: "resolved"}} =
             Alerts.clear_incident_condition(%{
               dedupe_key: dedupe_key,
               cleared_at: timestamp(~U[2026-05-30 13:15:00Z])
             })

    resolved_result =
      record_saved_reset!(
        rule_beta,
        identity,
        timestamp(~U[2026-05-30 13:20:00Z]),
        "after-resolve-repeat"
      )

    assert resolved_result.target_inserted? == false
    assert resolved_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(resolved_result)
    assert delivery_job_count() == 1

    assert [incident] = Repo.all(from row in AlertIncident, where: row.dedupe_key == ^dedupe_key)
    assert incident.id == first_result.incident.id
    assert incident.state == "resolved"
    assert incident.occurrence_count == 1
    assert incident.first_seen_at == first_seen
    assert incident.safe_evidence_snapshot["source"] == "no-channel-first"
    assert target_pool_ids(incident) == MapSet.new([pool_alpha.id, pool_beta.id])
  end

  @tag :saved_reset_banked_first_seen
  test "same-rule channel link schedules once after the target exists" do
    Repo.delete_all(Oban.Job)
    {_pool, rule, identity} = saved_reset_pool("pool-same-rule-link")
    channel = alert_channel_fixture(%{display_name: "Saved reset linked email"})
    first_seen = timestamp(~U[2026-05-30 16:30:00Z])
    attrs = saved_reset_attrs(rule, identity, first_seen, "same-rule-link")

    assert {:ok, first_result} = Alerts.record_incident_once(attrs)
    assert first_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(first_result)
    assert delivery_job_count() == 0

    link_rule_channel!(rule, channel, timestamp(~U[2026-05-30 16:35:00Z]))
    assert {:ok, linked_result} = Alerts.record_incident_once(attrs)
    assert linked_result.incident.id == first_result.incident.id
    assert linked_result.delivery_channel_ids_due == [channel.id]
    assert :ok = enqueue_lifecycle_deliveries(linked_result)
    assert delivery_job_channel_ids() == [channel.id]

    assert {:ok, repeat_result} = Alerts.record_incident_once(attrs)
    assert repeat_result.incident.id == first_result.incident.id
    assert repeat_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(repeat_result)
    assert delivery_job_channel_ids() == [channel.id]
  end

  @tag :saved_reset_banked_first_seen
  test "lifecycle is safe when concurrent workers race before insert" do
    {_pool, rule, identity} = saved_reset_pool("pool-concurrent")
    matched_at = timestamp(~U[2026-05-30 14:00:00Z])
    attrs = saved_reset_attrs(rule, identity, matched_at, "race")
    parent = self()

    tasks = for _index <- 1..6, do: Task.async(fn -> await_go(parent, attrs) end)
    ready_pids = for _index <- 1..length(tasks), do: receive_ready_pid!()
    Enum.each(ready_pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, %{incident: %AlertIncident{}}}, &1))

    assert Repo.aggregate(
             from(row in AlertIncident, where: row.dedupe_key == ^attrs.dedupe_key),
             :count
           ) == 1

    incident = Repo.one!(from row in AlertIncident, where: row.dedupe_key == ^attrs.dedupe_key)
    assert incident.occurrence_count == 1
    assert incident.first_seen_at == matched_at
    assert incident.last_seen_at == matched_at

    assert Repo.aggregate(
             from(target in AlertIncidentTarget, where: target.incident_id == ^incident.id),
             :count
           ) == 1
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_suffix, do: System.unique_integer([:positive])

  defp saved_reset_pool(slug_prefix) do
    pool = pool_fixture(%{slug: "#{slug_prefix}-#{unique_suffix()}", name: slug_prefix})
    %{identity: identity} = upstream_assignment_fixture(pool)
    {pool, saved_reset_rule_fixture(pool), identity}
  end

  defp saved_reset_rule_fixture(pool) do
    alert_rule_fixture(pool,
      scope_type: "upstream_identity",
      rule_kind: @rule_kind,
      severity: "info",
      cooldown_minutes: 30
    )
  end

  defp record_saved_reset!(rule, identity, matched_at, source) do
    assert {:ok, result} =
             Alerts.record_incident_once(saved_reset_attrs(rule, identity, matched_at, source))

    result
  end

  defp saved_reset_attrs(rule, identity, matched_at, source) do
    %{
      dedupe_key: saved_reset_dedupe_key(identity),
      scope_type: "upstream_identity",
      rule_kind: @rule_kind,
      severity: "info",
      upstream_identity_id: identity.id,
      matched_at: matched_at,
      safe_evidence_snapshot: saved_reset_evidence(rule, identity, matched_at, source),
      targets: [
        %{
          rule_id: rule.id,
          pool_id: rule.pool_id,
          metadata: %{
            "reason_code" => "saved_reset_banked_first_seen",
            "reset_expires_at" => @expires_at
          }
        }
      ]
    }
  end

  defp saved_reset_evidence(rule, identity, matched_at, source) do
    %{
      "reason_code" => "saved_reset_banked_first_seen",
      "reset_expires_at" => @expires_at,
      "reset_first_seen_at" => DateTime.to_iso8601(matched_at),
      "available_count" => 1,
      "path_style" => "available_expirations",
      "pool_id" => rule.pool_id,
      "upstream_identity_id" => identity.id,
      "source" => source
    }
  end

  defp saved_reset_dedupe_key(identity),
    do: "alerts:v1:#{@rule_kind}:upstream_identity:#{identity.id}:reset_expires_at:#{@expires_at}"

  defp link_rule_channel!(rule, channel, timestamp) do
    %AlertRuleChannel{}
    |> AlertRuleChannel.changeset(%{
      alert_rule_id: rule.id,
      alert_channel_id: channel.id,
      created_at: timestamp
    })
    |> Repo.insert!()
  end

  defp enqueue_lifecycle_deliveries(%{delivery_due?: true} = result) do
    Enum.each(result.delivery_channel_ids_due, fn channel_id ->
      assert {:ok, _job} =
               Jobs.enqueue_alert_delivery(result.incident, channel_id,
                 trigger_kind: "incident_match",
                 now: result.incident.last_seen_at
               )
    end)
  end

  defp enqueue_lifecycle_deliveries(_result), do: :ok

  defp delivery_job_count, do: length(all_enqueued(worker: AlertDeliveryWorker))

  defp delivery_job_channel_ids do
    all_enqueued(worker: AlertDeliveryWorker)
    |> Enum.map(& &1.args["alert_channel_id"])
    |> Enum.sort()
  end

  defp target_pool_ids(incident) do
    AlertIncidentTarget
    |> where([target], target.incident_id == ^incident.id)
    |> Repo.all()
    |> Enum.map(& &1.pool_id)
    |> MapSet.new()
  end

  defp await_go(parent, attrs) do
    send(parent, {:ready, self()})

    receive do
      :go -> Alerts.record_incident_once(attrs)
    after
      2_000 -> flunk("concurrent saved-reset lifecycle task did not start")
    end
  end

  defp receive_ready_pid! do
    assert_receive {:ready, pid}, 2_000
    pid
  end
end
