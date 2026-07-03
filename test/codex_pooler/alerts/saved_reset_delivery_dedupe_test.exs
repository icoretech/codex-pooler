defmodule CodexPooler.Alerts.SavedResetDeliveryDedupeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts

  alias CodexPooler.Alerts.Schemas.{
    AlertDeliveryAttempt,
    AlertIncident,
    AlertRuleChannel
  }

  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Mailer
  alias CodexPooler.Repo

  @rule_kind "upstream_saved_reset_banked_first_seen"
  @next_expires_at "2026-06-01T00:00:00Z"
  @latest_expires_at "2026-06-08T00:00:00Z"

  @tag :saved_reset_banked_first_seen_authorization
  test "records one delivery attempt per due channel across aggregate targets and repeats" do
    use_test_mailer()
    Repo.delete_all(AlertDeliveryAttempt)
    Repo.delete_all(Oban.Job)

    {_pool_without_channel, rule_without_channel, identity} = saved_reset_pool("pool-no-channel")
    {_pool_alpha, rule_alpha, _identity} = saved_reset_pool("pool-alpha")
    {_pool_beta, rule_beta, _identity} = saved_reset_pool("pool-beta")
    channel = alert_channel_fixture(%{display_name: "Saved reset shared email"})
    beta_channel = alert_channel_fixture(%{display_name: "Saved reset beta email"})
    linked_seen = timestamp(~U[2026-05-30 15:05:00Z])
    dedupe_key = saved_reset_dedupe_key(identity)

    no_channel_result =
      record_saved_reset!(
        rule_without_channel,
        identity,
        timestamp(~U[2026-05-30 15:00:00Z]),
        "no-channel-first"
      )

    assert no_channel_result.delivery_channel_ids_due == []
    assert no_channel_result.incident.dedupe_key == dedupe_key
    refute no_channel_result.incident.dedupe_key =~ "reset_expires_at"
    assert :ok = enqueue_lifecycle_deliveries(no_channel_result)
    assert delivery_job_count() == 0

    link_rule_channel!(rule_alpha, channel, linked_seen)
    link_rule_channel!(rule_beta, channel, linked_seen)

    alpha_result = record_saved_reset!(rule_alpha, identity, linked_seen, "channel-linked-alpha")
    assert alpha_result.delivery_channel_ids_due == [channel.id]
    assert :ok = enqueue_lifecycle_deliveries(alpha_result)
    assert delivery_job_count() == 1

    alpha_repeat = record_saved_reset!(rule_alpha, identity, linked_seen, "channel-linked-alpha")
    assert alpha_repeat.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(alpha_repeat)
    assert delivery_job_count() == 1

    beta_result = record_saved_reset!(rule_beta, identity, linked_seen, "channel-linked-beta")
    assert beta_result.incident.id == alpha_result.incident.id
    assert beta_result.target_inserted? == true
    assert beta_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(beta_result)
    assert delivery_job_count() == 1

    link_rule_channel!(rule_beta, beta_channel, linked_seen)

    beta_channel_result =
      record_saved_reset!(rule_beta, identity, linked_seen, "channel-linked-beta-new-channel")

    assert beta_channel_result.incident.id == alpha_result.incident.id
    assert beta_channel_result.target_inserted? == false
    assert beta_channel_result.delivery_channel_ids_due == [beta_channel.id]
    assert :ok = enqueue_lifecycle_deliveries(beta_channel_result)
    assert delivery_job_count() == 2

    all_enqueued(worker: AlertDeliveryWorker)
    |> Enum.each(fn job -> assert :ok = perform_job(AlertDeliveryWorker, job.args) end)

    assert [attempt] = delivery_attempts_for(alpha_result.incident, channel)
    assert attempt.status == "sent"
    assert attempt.attempt_number == 1

    assert [beta_attempt] = delivery_attempts_for(alpha_result.incident, beta_channel)
    assert beta_attempt.status == "sent"
    assert beta_attempt.attempt_number == 1

    repeat_result =
      record_saved_reset!(rule_alpha, identity, timestamp(~U[2026-05-30 15:10:00Z]), "repeat")

    assert repeat_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(repeat_result)
    assert delivery_attempts_for(alpha_result.incident, channel) == [attempt]
    assert delivery_attempts_for(alpha_result.incident, beta_channel) == [beta_attempt]

    assert {:ok, %AlertIncident{state: "resolved"}} =
             Alerts.clear_incident_condition(%{
               dedupe_key: dedupe_key,
               cleared_at: timestamp(~U[2026-05-30 15:20:00Z])
             })

    resolved_result =
      record_saved_reset!(
        rule_beta,
        identity,
        timestamp(~U[2026-05-30 15:20:00Z]),
        "after-resolve-repeat"
      )

    assert resolved_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(resolved_result)
    assert delivery_attempts_for(alpha_result.incident, channel) == [attempt]
    assert delivery_attempts_for(alpha_result.incident, beta_channel) == [beta_attempt]
    assert delivery_job_count() == 2
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
          metadata: saved_reset_evidence(rule, identity, matched_at, source)
        }
      ]
    }
  end

  defp saved_reset_evidence(rule, identity, matched_at, source) do
    %{
      "reason_code" => "saved_reset_banked_first_seen",
      "available_count" => 2,
      "new_reset_count" => 2,
      "earliest_reset_first_seen_at" => DateTime.to_iso8601(matched_at),
      "latest_reset_first_seen_at" => DateTime.to_iso8601(matched_at),
      "next_reset_expires_at" => @next_expires_at,
      "latest_reset_expires_at" => @latest_expires_at,
      "path_style" => "available_expirations",
      "pool_id" => rule.pool_id,
      "pool_upstream_assignment_id" => "test-assignment",
      "upstream_identity_id" => identity.id,
      "source" => source
    }
  end

  defp saved_reset_dedupe_key(identity) do
    "alerts:v2:#{@rule_kind}:upstream_identity:#{identity.id}"
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

  defp enqueue_lifecycle_deliveries(result, opts \\ [])

  defp enqueue_lifecycle_deliveries(%{delivery_due?: true} = result, opts) do
    fail_channel_id = Keyword.get(opts, :fail_channel_id)

    Enum.reduce_while(result.delivery_channel_ids_due, :ok, fn channel_id, :ok ->
      case enqueue_lifecycle_delivery(result, channel_id, fail_channel_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp enqueue_lifecycle_deliveries(_result, _opts), do: :ok

  defp enqueue_lifecycle_delivery(_result, channel_id, channel_id),
    do: {:error, :forced_enqueue_failure}

  defp enqueue_lifecycle_delivery(result, channel_id, _fail_channel_id) do
    case Jobs.enqueue_alert_delivery(result.incident, channel_id,
           trigger_kind: "incident_match",
           now: result.incident.last_seen_at
         ) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp use_test_mailer do
    mailer_config = Application.get_env(:codex_pooler, Mailer)
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
    on_exit(fn -> Application.put_env(:codex_pooler, Mailer, mailer_config) end)
  end

  defp delivery_job_count, do: length(all_enqueued(worker: AlertDeliveryWorker))

  defp delivery_attempts_for(incident, channel) do
    Repo.all(
      from attempt in AlertDeliveryAttempt,
        where: attempt.incident_id == ^incident.id and attempt.channel_id == ^channel.id,
        order_by: [asc: attempt.attempt_number, asc: attempt.id]
    )
  end
end
