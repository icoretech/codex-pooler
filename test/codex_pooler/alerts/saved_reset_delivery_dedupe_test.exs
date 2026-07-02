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
  @expires_at "2026-06-01T00:00:00Z"

  @tag :saved_reset_banked_first_seen_authorization
  test "records one delivery attempt across shared-channel targets and repeats" do
    use_test_mailer()
    Repo.delete_all(AlertDeliveryAttempt)
    Repo.delete_all(Oban.Job)

    {_pool_without_channel, rule_without_channel, identity} = saved_reset_pool("pool-no-channel")
    {_pool_alpha, rule_alpha, _identity} = saved_reset_pool("pool-alpha")
    {_pool_beta, rule_beta, _identity} = saved_reset_pool("pool-beta")
    channel = alert_channel_fixture(%{display_name: "Saved reset shared email"})
    linked_seen = timestamp(~U[2026-05-30 15:05:00Z])

    no_channel_result =
      record_saved_reset!(
        rule_without_channel,
        identity,
        timestamp(~U[2026-05-30 15:00:00Z]),
        "no-channel-first"
      )

    assert no_channel_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(no_channel_result)
    assert delivery_job_count() == 0

    link_rule_channel!(rule_alpha, channel, linked_seen)
    link_rule_channel!(rule_beta, channel, linked_seen)

    alpha_result = record_saved_reset!(rule_alpha, identity, linked_seen, "channel-linked-alpha")
    assert alpha_result.delivery_channel_ids_due == [channel.id]
    assert :ok = enqueue_lifecycle_deliveries(alpha_result)
    assert delivery_job_count() == 1

    beta_result = record_saved_reset!(rule_beta, identity, linked_seen, "channel-linked-beta")
    assert beta_result.incident.id == alpha_result.incident.id
    assert beta_result.target_inserted? == true
    assert :ok = enqueue_lifecycle_deliveries(beta_result)
    assert delivery_job_count() == 1

    assert [job] = all_enqueued(worker: AlertDeliveryWorker)
    assert :ok = perform_job(AlertDeliveryWorker, job.args)
    assert [attempt] = delivery_attempts_for(alpha_result.incident, channel)
    assert attempt.status == "sent"
    assert attempt.attempt_number == 1

    repeat_result =
      record_saved_reset!(rule_alpha, identity, timestamp(~U[2026-05-30 15:10:00Z]), "repeat")

    assert repeat_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(repeat_result)
    assert delivery_attempts_for(alpha_result.incident, channel) == [attempt]

    assert {:ok, %AlertIncident{state: "resolved"}} =
             Alerts.clear_incident_condition(%{
               dedupe_key: saved_reset_dedupe_key(identity),
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
    assert delivery_job_count() == 1
  end

  @tag :saved_reset_banked_first_seen
  test "retry schedules only the channel whose enqueue failed after target insert" do
    Repo.delete_all(Oban.Job)
    {_pool, rule, identity} = saved_reset_pool("pool-partial-enqueue")
    channel_success = alert_channel_fixture(%{display_name: "Saved reset success email"})
    channel_failed = alert_channel_fixture(%{display_name: "Saved reset retried email"})
    first_seen = timestamp(~U[2026-05-30 16:00:00Z])

    link_rule_channel!(rule, channel_success, first_seen)
    link_rule_channel!(rule, channel_failed, first_seen)
    first_result = record_saved_reset!(rule, identity, first_seen, "partial-enqueue-first")
    assert first_result.target_inserted? == true
    assert first_result.delivery_due? == true

    assert MapSet.new(first_result.delivery_channel_ids_due) ==
             channel_ids([channel_success, channel_failed])

    assert [successful_channel_id, failed_channel_id] = first_result.delivery_channel_ids_due

    assert {:error, :forced_enqueue_failure} =
             enqueue_lifecycle_deliveries(first_result, fail_channel_id: failed_channel_id)

    assert delivery_job_channel_ids() == [successful_channel_id]

    retry_result =
      record_saved_reset!(
        rule,
        identity,
        timestamp(~U[2026-05-30 16:05:00Z]),
        "partial-enqueue-retry"
      )

    assert retry_result.incident.id == first_result.incident.id
    assert retry_result.delivery_channel_ids_due == [failed_channel_id]
    assert :ok = enqueue_lifecycle_deliveries(retry_result)

    assert MapSet.new(delivery_job_channel_ids()) ==
             MapSet.new(first_result.delivery_channel_ids_due)

    final_result =
      record_saved_reset!(
        rule,
        identity,
        timestamp(~U[2026-05-30 16:10:00Z]),
        "partial-enqueue-final-repeat"
      )

    assert final_result.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(final_result)
    assert delivery_job_count() == 2
  end

  @tag :saved_reset_banked_first_seen
  test "resolved incident suppresses retry after partial enqueue failure" do
    Repo.delete_all(Oban.Job)
    {_pool, rule, identity} = saved_reset_pool("pool-resolved-partial-enqueue")
    first_seen = timestamp(~U[2026-05-30 17:00:00Z])

    Enum.each(["Saved reset scheduled email", "Saved reset failed email"], fn name ->
      rule
      |> link_rule_channel!(alert_channel_fixture(%{display_name: name}), first_seen)
    end)

    first_result = record_saved_reset!(rule, identity, first_seen, "partial-enqueue-resolved")
    assert [successful_channel_id, failed_channel_id] = first_result.delivery_channel_ids_due

    assert {:error, :forced_enqueue_failure} =
             enqueue_lifecycle_deliveries(first_result, fail_channel_id: failed_channel_id)

    assert delivery_job_channel_ids() == [successful_channel_id]

    assert {:ok, %AlertIncident{state: "resolved"}} =
             clear_saved_reset_condition(identity, timestamp(~U[2026-05-30 17:05:00Z]))

    resolved_retry =
      record_saved_reset!(rule, identity, timestamp(~U[2026-05-30 17:10:00Z]), "resolved-retry")

    assert resolved_retry.incident.id == first_result.incident.id
    assert resolved_retry.delivery_channel_ids_due == []
    assert :ok = enqueue_lifecycle_deliveries(resolved_retry)
    assert delivery_job_channel_ids() == [successful_channel_id]
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

  defp saved_reset_dedupe_key(identity) do
    "alerts:v1:#{@rule_kind}:upstream_identity:#{identity.id}:reset_expires_at:#{@expires_at}"
  end

  defp clear_saved_reset_condition(identity, cleared_at) do
    Alerts.clear_incident_condition(%{
      dedupe_key: saved_reset_dedupe_key(identity),
      cleared_at: cleared_at
    })
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

  defp delivery_job_channel_ids do
    all_enqueued(worker: AlertDeliveryWorker)
    |> Enum.map(& &1.args["alert_channel_id"])
    |> Enum.sort()
  end

  defp channel_ids(channels), do: channels |> Enum.map(& &1.id) |> MapSet.new()

  defp delivery_attempts_for(incident, channel) do
    Repo.all(
      from attempt in AlertDeliveryAttempt,
        where: attempt.incident_id == ^incident.id and attempt.channel_id == ^channel.id,
        order_by: [asc: attempt.attempt_number, asc: attempt.id]
    )
  end
end
