defmodule CodexPooler.Alerts.SavedResetExpirationDedupeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertRuleChannel}
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Repo

  @rule_kind "upstream_saved_reset_banked_first_seen"
  @expires_at "2026-06-01T00:00:00Z"

  @tag :saved_reset_banked_first_seen
  test "zero-fraction expiration variants keep the stable v2 upstream dedupe key" do
    Repo.delete_all(Oban.Job)
    {_pool, rule, identity} = saved_reset_pool("pool-normalized-expiration")
    channel = alert_channel_fixture(%{display_name: "Saved reset normalized email"})
    link_rule_channel!(rule, channel, timestamp(~U[2026-05-30 18:00:00Z]))

    record = fn expires_at ->
      set_saved_reset_metadata!(identity, expires_at)

      assert [%{match_attrs: attrs}] =
               Alerts.evaluate_rule(rule, at: timestamp(~U[2026-05-30 18:05:00Z]))

      assert attrs.dedupe_key == saved_reset_v2_dedupe_key(identity.id),
             "v2 dedupe gap: saved-reset first-seen dedupe must be stable per upstream identity"

      refute attrs.dedupe_key =~ "reset_expires_at",
             "v2 dedupe gap: saved-reset first-seen dedupe must not include reset_expires_at"

      assert {:ok, result} = Alerts.record_incident_once(attrs)
      assert :ok = enqueue_lifecycle_deliveries(result)
      attrs
    end

    dedupe_key = record.(@expires_at).dedupe_key
    assert record.("2026-06-01T00:00:00.000000Z").dedupe_key == dedupe_key

    assert Repo.aggregate(
             from(row in AlertIncident, where: row.dedupe_key == ^dedupe_key),
             :count
           ) == 1

    assert delivery_job_count() == 1
  end

  @tag :saved_reset_banked_first_seen
  test "fractional expiration instants do not fan out aggregate upstream dedupe" do
    Repo.delete_all(Oban.Job)
    {_pool, rule, identity} = saved_reset_pool("pool-fractional-expiration")

    dedupe_key_for = fn expires_at ->
      set_saved_reset_metadata!(identity, expires_at)

      assert [%{match_attrs: attrs}] =
               Alerts.evaluate_rule(rule, at: timestamp(~U[2026-05-30 18:05:00Z]))

      attrs.dedupe_key
    end

    second_key = dedupe_key_for.(@expires_at)
    fractional_key = dedupe_key_for.("2026-06-01T00:00:00.123Z")

    assert dedupe_key_for.("2026-06-01T00:00:00.000000Z") == second_key
    assert dedupe_key_for.("2026-06-01T00:00:00.123000Z") == fractional_key

    assert fractional_key == second_key,
           "aggregate one-candidate gap: saved-reset first-seen dedupe must not fan out by reset_expires_at"
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_suffix, do: System.unique_integer([:positive])

  defp saved_reset_pool(slug_prefix) do
    pool = pool_fixture(%{slug: "#{slug_prefix}-#{unique_suffix()}", name: slug_prefix})
    %{identity: identity} = upstream_assignment_fixture(pool)
    {pool, saved_reset_rule_fixture(pool), identity}
  end

  defp saved_reset_rule_fixture(pool) do
    baseline = timestamp(~U[2026-05-30 17:00:00Z])

    alert_rule_fixture(pool,
      scope_type: "upstream_identity",
      rule_kind: @rule_kind,
      severity: "info",
      cooldown_minutes: 30,
      created_at: baseline,
      updated_at: baseline
    )
  end

  defp set_saved_reset_metadata!(identity, expires_at) do
    metadata = %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => 1,
        "available_expirations" => [
          %{"expires_at" => expires_at, "first_seen_at" => "2026-05-30T18:00:00Z"}
        ]
      }
    }

    identity
    |> Ecto.Changeset.change(metadata: metadata)
    |> Repo.update!()
  end

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

  defp saved_reset_v2_dedupe_key(upstream_identity_id) do
    Enum.join(
      [
        "alerts",
        "v2",
        @rule_kind,
        "upstream_identity",
        upstream_identity_id || "none"
      ],
      ":"
    )
  end
end
