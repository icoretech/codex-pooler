defmodule CodexPooler.Alerts.SavedResetRuleTargetClearTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertDeliveryAttempt, AlertIncident, AlertIncidentTarget, AlertRule}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.{AlertDeliveryWorker, AlertEvaluationWorker}
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets.FirstSeenLedger
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @saved_reset_kind "upstream_saved_reset_banked_first_seen"
  @threshold_kind "upstream_quota_threshold"
  @cleanup_timeout_ms 15_000

  setup do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{scope: Scope.for_user(owner)}
  end

  @tag :saved_reset_banked_first_seen
  test "creating a later saved-reset rule preserves the older rule's banked-grant target", %{scope: scope} do
    assert_late_saved_reset_rule_preserves_target!(scope, :create)
  end

  @tag :saved_reset_banked_first_seen
  test "enabling a later saved-reset rule preserves the older rule's banked-grant target", %{scope: scope} do
    assert_late_saved_reset_rule_preserves_target!(scope, :enable)
  end

  @tag :saved_reset_banked_first_seen
  test "two matching saved-reset rules aggregate targets and queue each linked channel only once", %{scope: scope} do
    context = saved_reset_context!(scope, :active)
    {incident, _expiration, first_seen_at} = open_shared_saved_reset_incident!(context)
    original_targets = targets(incident)
    original_deliveries = queued_delivery_pairs(context)

    evaluate!(context.rule_a)
    evaluate!(context.rule_b)

    assert [%AlertIncident{id: incident_id, state: "open", occurrence_count: 1}] = incidents(context)
    assert incident_id == incident.id
    assert targets(incident) == original_targets
    assert queued_delivery_pairs(context) == original_deliveries
    assert DateTime.compare(incident_first_seen!(Repo.reload!(incident)), first_seen_at) == :eq
    assert_no_delivery_attempts(context)
  end

  @tag :saved_reset_banked_first_seen
  test "real grant removal clears both targets and a reappearing same grant stays once-only", %{scope: scope} do
    context = saved_reset_context!(scope, :active)
    {incident, expiration, first_seen_at} = open_shared_saved_reset_incident!(context)
    original_deliveries = queued_delivery_pairs(context)
    original_ledger = Repo.reload!(context.identity).saved_reset_first_seen_ledger

    removed = observe_saved_resets!(context, [])
    assert removed.metadata["saved_resets"]["available_expirations"] == []
    assert removed.saved_reset_first_seen_ledger == original_ledger

    evaluate!(context.rule_a)
    evaluate!(context.rule_b)

    assert %AlertIncident{state: "resolved", resolved_at: %DateTime{}} = Repo.reload!(incident)
    assert Enum.all?(targets(incident), &match?(%DateTime{}, &1.resolved_at))

    reappeared = observe_saved_resets!(context, [expiration])
    assert saved_reset_first_seen!(reappeared, expiration) == first_seen_at

    evaluate!(context.rule_a)
    evaluate!(context.rule_b)

    assert [%AlertIncident{id: incident_id, state: "resolved", occurrence_count: 1}] = incidents(context)
    assert incident_id == incident.id
    assert queued_delivery_pairs(context) == original_deliveries

    # A genuine later grant must still open a new lifecycle; preserving the
    # sibling target must not weaken once-per-grant history or future alerts.
    later_expiration = expiration_in_days(31)
    later_identity = observe_saved_resets!(context, [expiration, later_expiration])
    later_first_seen_at = saved_reset_first_seen!(later_identity, later_expiration)
    assert DateTime.compare(later_first_seen_at, first_seen_at) == :gt

    evaluate!(context.rule_a)
    evaluate!(context.rule_b)

    assert [%AlertIncident{id: original_id, state: "resolved"}, %AlertIncident{state: "open"} = later] = incidents(context)
    assert original_id == incident.id
    assert later.id != incident.id
    assert DateTime.compare(incident_first_seen!(later), later_first_seen_at) == :eq
    assert_target_rules(later, [context.rule_a, context.rule_b])
    assert queued_delivery_pairs(context) == expected_deliveries(context, [incident, later])
    assert_no_delivery_attempts(context)
  end

  @tag :saved_reset_banked_first_seen
  test "manual resolution does not reopen or redeliver the same still-banked grant", %{scope: scope} do
    context = saved_reset_context!(scope, :active)
    {incident, expiration, first_seen_at} = open_shared_saved_reset_incident!(context)
    original_deliveries = queued_delivery_pairs(context)

    assert {:ok, %{state: "resolved"}} = Alerts.resolve_incident(scope, incident)
    assert saved_reset_first_seen!(Repo.reload!(context.identity), expiration) == first_seen_at

    evaluate!(context.rule_a)
    evaluate!(context.rule_b)

    assert [%AlertIncident{id: incident_id, state: "resolved", occurrence_count: 1}] = incidents(context)
    assert incident_id == incident.id
    assert queued_delivery_pairs(context) == original_deliveries
    assert_no_delivery_attempts(context)
  end

  test "a model-not-served sibling preserves the serving Pool's threshold lifecycle across reevaluation", %{scope: scope} do
    context = threshold_context!(scope, false)
    evaluate!(context.rule_a)
    assert [%AlertIncident{state: "open"} = incident] = incidents(context)
    assert_target_rules(incident, [context.rule_a])
    original_deliveries = queued_delivery_pairs(context)
    assert original_deliveries == [{incident.id, context.shared_channel.id}]

    # B has the same active identity and threshold, but no active catalog
    # entry for this model. Its non-match cannot clear A's matching target.
    evaluate!(context.rule_b)
    after_sibling = Repo.reload!(incident)
    targets_after_sibling = targets(incident)

    # Finish A's next production evaluation before asserting, so a failure
    # also exposes duplicate lifecycles rather than stopping at the clear.
    evaluate!(context.rule_a)
    after_reevaluation = incidents(context)

    assert after_sibling.state == "open"
    assert is_nil(after_sibling.resolved_at)
    assert Enum.all?(targets_after_sibling, &is_nil(&1.resolved_at))
    assert [%AlertIncident{id: incident_id, state: "open", occurrence_count: 2}] = after_reevaluation
    assert incident_id == incident.id
    assert_target_rules(incident, [context.rule_a])
    assert queued_delivery_pairs(context) == original_deliveries
    assert_no_delivery_attempts(context)
  end

  test "two served-model thresholds share targets and clear when their real quota evidence expires", %{scope: scope} do
    context = threshold_context!(scope, true)
    evaluate!(context.rule_a)
    evaluate!(context.rule_b)

    assert [%AlertIncident{state: "open", occurrence_count: 2} = incident] = incidents(context)
    assert_target_rules(incident, [context.rule_a, context.rule_b])
    assert queued_delivery_pairs(context) == expected_deliveries(context, [incident])

    # Both active catalog entries and the stored 95% window survive. Only
    # the actual evaluation clock crosses the window's reset boundary.
    expired_at = DateTime.add(context.quota_window.reset_at, 1, :second)
    evaluate!(context.rule_a, expired_at)
    evaluate!(context.rule_b, expired_at)

    assert [%AlertIncident{id: incident_id, state: "resolved"}] = incidents(context)
    assert incident_id == incident.id
    assert Enum.all?(targets(incident), &match?(%DateTime{}, &1.resolved_at))
    assert Enum.any?(Windows.list_quota_windows(context.identity), &(&1.id == context.quota_window.id))
    assert queued_delivery_pairs(context) == expected_deliveries(context, [incident])
    assert_no_delivery_attempts(context)
  end

  test "a rule that cleared for itself keeps the sibling's incident open and stops notifying its own channels", %{scope: scope} do
    context = threshold_context!(scope, true)
    evaluate!(context.rule_a)
    evaluate!(context.rule_b)
    assert [%AlertIncident{state: "open"} = incident] = incidents(context)
    assert due_channel_ids(incident) == Enum.sort([context.shared_channel.id, context.sibling_channel.id])

    # Pool B stops serving the model: rule B no longer matches, rule A still does.
    Repo.delete_all(from model in CodexPooler.Catalog.Model, where: model.pool_id == ^context.pool_b.id)
    evaluate!(context.rule_b)

    assert %AlertIncident{state: "open", resolved_at: nil} = Repo.reload!(incident)
    assert [{rule_a_id, nil}, {rule_b_id, %DateTime{}}] = incident |> targets() |> Enum.map(&{&1.rule_id, &1.resolved_at}) |> Enum.sort_by(fn {rule_id, _resolved_at} -> rule_id != context.rule_a.id end)
    assert {rule_a_id, rule_b_id} == {context.rule_a.id, context.rule_b.id}
    assert due_channel_ids(incident) == [context.shared_channel.id]

    # Rule A clearing afterwards resolves the incident: no active rule still holds a target.
    expired_at = DateTime.add(context.quota_window.reset_at, 1, :second)
    evaluate!(context.rule_a, expired_at)
    assert %AlertIncident{state: "resolved"} = Repo.reload!(incident)
  end

  defp due_channel_ids(incident), do: incident |> Alerts.list_incident_delivery_channels_due() |> Enum.map(& &1.channel_id) |> Enum.sort()

  defp assert_late_saved_reset_rule_preserves_target!(scope, transition) do
    context = saved_reset_context!(scope, if(transition == :enable, do: :disabled, else: :absent))
    expiration = expiration_in_days(30)
    identity = observe_saved_resets!(context, [expiration])
    first_seen_at = saved_reset_first_seen!(identity, expiration)
    assert DateTime.compare(first_seen_at, AlertRule.saved_reset_first_seen_baseline_at(context.rule_a)) == :gt

    evaluated_a_at = now()
    evaluate!(context.rule_a, evaluated_a_at)
    assert [%AlertIncident{state: "open", occurrence_count: 1} = incident] = incidents(context)
    assert_target_rules(incident, [context.rule_a])
    original_targets = targets(incident)
    original_deliveries = queued_delivery_pairs(context)
    assert original_deliveries == [{incident.id, context.shared_channel.id}]

    later_rule = activate_later_saved_reset_rule!(context, transition)
    later_baseline = AlertRule.saved_reset_first_seen_baseline_at(later_rule)
    assert DateTime.compare(later_baseline, evaluated_a_at) == :gt
    assert DateTime.compare(later_baseline, first_seen_at) == :gt
    request_count = FakeUpstream.count(context.fake)

    evaluate!(later_rule)
    after_sibling = Repo.reload!(incident)
    targets_after_sibling = targets(incident)

    # A still selects the same grant, but once-only history must not be
    # "fixed" by reopening a falsely resolved incident on reevaluation.
    evaluate!(context.rule_a)
    after_reevaluation = Repo.reload!(incident)

    assert FakeUpstream.count(context.fake) == request_count
    assert saved_reset_first_seen!(Repo.reload!(identity), expiration) == first_seen_at
    assert after_sibling.state == "open"
    assert is_nil(after_sibling.resolved_at)
    assert targets_after_sibling == original_targets
    assert after_reevaluation.state == "open"
    assert is_nil(after_reevaluation.resolved_at)
    assert [%AlertIncident{id: incident_id, occurrence_count: 1}] = incidents(context)
    assert incident_id == incident.id
    assert_target_rules(incident, [context.rule_a])
    assert queued_delivery_pairs(context) == original_deliveries
    assert_no_delivery_attempts(context)
  end

  defp activate_later_saved_reset_rule!(context, :create) do
    create_saved_reset_rule!(context, context.pool_b, "active", [context.shared_channel, context.sibling_channel])
  end

  defp activate_later_saved_reset_rule!(context, :enable) do
    refute Map.has_key?(context.rule_b.metadata, AlertRule.saved_reset_first_seen_baseline_key())
    assert {:ok, rule} = Alerts.update_rule(context.scope, context.rule_b, %{state: "active"})
    assert rule.state == "active"
    rule
  end

  defp saved_reset_context!(scope, sibling_state) do
    fake = start_saved_reset_fake!()
    context = shared_identity_context!(scope, fake)
    rule_a = create_saved_reset_rule!(context, context.pool_a, "active", [context.shared_channel])

    rule_b =
      case sibling_state do
        :absent -> nil
        :disabled -> create_saved_reset_rule!(context, context.pool_b, "disabled", [context.shared_channel, context.sibling_channel])
        :active -> create_saved_reset_rule!(context, context.pool_b, "active", [context.shared_channel, context.sibling_channel])
      end

    Map.merge(context, %{rule_a: rule_a, rule_b: rule_b, rule_kind: @saved_reset_kind})
  end

  defp shared_identity_context!(scope, fake \\ nil) do
    pool_a = pool_fixture()
    pool_b = pool_fixture()

    %{identity: identity, assignment: assignment} =
      if fake do
        active_upstream_assignment_fixture(pool_a, %{
          metadata: %{"usage_base_url" => FakeUpstream.url(fake), "usage_path" => "/api/codex/usage"}
        })
      else
        upstream_assignment_fixture(pool_a)
      end

    assert {:ok, sibling_assignment} = PoolAssignments.create_pool_assignment(pool_b, identity)
    assert {:ok, _sibling_assignment} = PoolAssignments.activate_pool_assignment(sibling_assignment)

    shared_channel = alert_channel_fixture(%{display_name: "Target clear shared #{System.unique_integer([:positive])}", created_by_user_id: scope.user.id})
    sibling_channel = alert_channel_fixture(%{display_name: "Target clear sibling #{System.unique_integer([:positive])}", created_by_user_id: scope.user.id})

    %{
      scope: scope,
      pool_a: pool_a,
      pool_b: pool_b,
      identity: identity,
      assignment: assignment,
      fake: fake,
      shared_channel: shared_channel,
      sibling_channel: sibling_channel
    }
  end

  defp create_saved_reset_rule!(context, pool, state, channels) do
    assert {:ok, rule} =
             Alerts.create_rule(context.scope, %{
               pool_id: pool.id,
               scope_type: "upstream_identity",
               rule_kind: @saved_reset_kind,
               display_name: "Saved reset target isolation",
               severity: "info",
               cooldown_minutes: 30,
               state: state,
               channel_ids: Enum.map(channels, & &1.id)
             })

    rule
  end

  defp open_shared_saved_reset_incident!(context) do
    expiration = expiration_in_days(30)
    identity = observe_saved_resets!(context, [expiration])
    first_seen_at = saved_reset_first_seen!(identity, expiration)

    for rule <- [context.rule_a, context.rule_b] do
      assert DateTime.compare(first_seen_at, AlertRule.saved_reset_first_seen_baseline_at(rule)) == :gt
    end

    request_count = FakeUpstream.count(context.fake)
    evaluate!(context.rule_a)
    evaluate!(context.rule_b)

    assert FakeUpstream.count(context.fake) == request_count
    assert [%AlertIncident{state: "open", occurrence_count: 1} = incident] = incidents(context)
    assert_target_rules(incident, [context.rule_a, context.rule_b])
    assert queued_delivery_pairs(context) == expected_deliveries(context, [incident])
    {incident, expiration, first_seen_at}
  end

  defp start_saved_reset_fake! do
    name = :"saved_reset_target_clear_fake_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if supervisor = Process.whereis(name) do
        monitor = Process.monitor(supervisor)
        FakeUpstream.stop(%FakeUpstream{supervisor: supervisor})
        assert_receive {:DOWN, ^monitor, :process, ^supervisor, _reason}, @cleanup_timeout_ms
      end

      assert Process.whereis(name) == nil
    end)

    assert {:ok, fake} = FakeUpstream.start_link(saved_reset_mode([], now()), supervisor_name: name)
    Process.unlink(fake.supervisor)
    fake
  end

  defp observe_saved_resets!(context, expirations) do
    observed_at = now()
    FakeUpstream.set_mode(context.fake, saved_reset_mode(expirations, observed_at))
    identity = Repo.get!(UpstreamIdentity, context.identity.id)

    assert {:ok, updated} =
             PoolReconciliation.refresh_quota_from_usage(identity, context.assignment, observed_at: observed_at)

    updated = Repo.reload!(updated)
    count = length(expirations)
    assert %{"status" => "reported", "available_count" => ^count} = updated.metadata["saved_resets"]

    assert Enum.sort(Enum.map(updated.metadata["saved_resets"]["available_expirations"], & &1["expires_at"])) == Enum.sort(expirations)

    for expiration <- expirations do
      first_seen_at = saved_reset_first_seen!(updated, expiration)
      assert {:ok, ledger_first_seen} = FirstSeenLedger.lookup(updated.saved_reset_first_seen_ledger, expiration)
      assert {:ok, ledger_at, 0} = DateTime.from_iso8601(ledger_first_seen)
      assert DateTime.compare(first_seen_at, ledger_at) == :eq
    end

    updated
  end

  defp saved_reset_mode(expirations, observed_at) do
    credits = Enum.map(expirations, &%{"status" => "available", "expires_at" => &1, "granted_at" => DateTime.to_iso8601(DateTime.add(observed_at, -1, :day))})
    count = length(expirations)

    usage = %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 3_600,
          "reset_at" => observed_at |> DateTime.add(1, :hour) |> DateTime.to_unix()
        }
      }
    }

    {:path_json,
     %{
       "/api/codex/usage" => {200, usage},
       "/backend-api/wham/rate-limit-reset-credits" => {200, %{"available_count" => count, "credits" => credits}}
     }}
  end

  defp threshold_context!(scope, sibling_serves_model?) do
    context = shared_identity_context!(scope)
    model = "gpt-target-clear-#{System.unique_integer([:positive])}"
    model_fixture(context.pool_a, %{exposed_model_id: model, upstream_model_id: model})
    if sibling_serves_model?, do: model_fixture(context.pool_b, %{exposed_model_id: model, upstream_model_id: model})

    rule_a = create_threshold_rule!(context, context.pool_a, model, [context.shared_channel])
    rule_b = create_threshold_rule!(context, context.pool_b, model, [context.shared_channel, context.sibling_channel])
    observed_at = now()

    assert {:ok, window} =
             Windows.record_evidence(
               context.identity,
               %{
                 quota_key: "target_clear_meter",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: model,
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("95"),
                 reset_at: DateTime.add(observed_at, 1, :hour),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: observed_at,
                 observed_at: observed_at,
                 metadata: %{}
               },
               observed_at
             )

    assert Decimal.equal?(window.used_percent, Decimal.new("95"))
    Map.merge(context, %{rule_a: rule_a, rule_b: rule_b, rule_kind: @threshold_kind, quota_window: window})
  end

  defp create_threshold_rule!(context, pool, model, channels) do
    assert {:ok, rule} =
             Alerts.create_rule(context.scope, %{
               pool_id: pool.id,
               scope_type: "upstream_identity",
               rule_kind: @threshold_kind,
               display_name: "Served model target isolation",
               severity: "warning",
               cooldown_minutes: 30,
               state: "active",
               model: model,
               window_selector: "model_primary",
               threshold_used_percent: Decimal.new("90"),
               channel_ids: Enum.map(channels, & &1.id)
             })

    rule
  end

  defp evaluate!(rule, at \\ now()) do
    args = %{
      alert_rule_id: rule.id,
      evaluation_window_started_at: DateTime.to_iso8601(at),
      trigger_kind: "scheduled"
    }

    assert :ok =
             Oban.Testing.with_testing_mode(:manual, fn ->
               perform_job(AlertEvaluationWorker, args, attempted_at: at)
             end)
  end

  defp incidents(context) do
    Repo.all(
      from incident in AlertIncident,
        where: incident.rule_kind == ^context.rule_kind and incident.upstream_identity_id == ^context.identity.id,
        order_by: [asc: incident.first_seen_at, asc: incident.id]
    )
  end

  defp targets(incident) do
    Repo.all(from target in AlertIncidentTarget, where: target.incident_id == ^incident.id, order_by: [asc: target.rule_id])
  end

  defp assert_target_rules(incident, rules) do
    rows = targets(incident)
    assert Enum.map(rows, &{&1.rule_id, &1.pool_id}) == Enum.sort(Enum.map(rules, &{&1.id, &1.pool_id}))
    assert Enum.all?(rows, &is_nil(&1.resolved_at))
  end

  defp queued_delivery_pairs(context) do
    channel_ids = [context.shared_channel.id, context.sibling_channel.id]

    all_enqueued(worker: AlertDeliveryWorker)
    |> Enum.filter(&(&1.args["alert_channel_id"] in channel_ids))
    |> Enum.map(&{&1.args["alert_incident_id"], &1.args["alert_channel_id"]})
    |> Enum.sort()
  end

  defp expected_deliveries(context, incidents) do
    for incident <- incidents, channel <- [context.shared_channel, context.sibling_channel] do
      {incident.id, channel.id}
    end
    |> Enum.sort()
  end

  defp assert_no_delivery_attempts(context) do
    channel_ids = [context.shared_channel.id, context.sibling_channel.id]
    refute Repo.exists?(from attempt in AlertDeliveryAttempt, where: attempt.channel_id in ^channel_ids)
  end

  defp saved_reset_first_seen!(identity, expiration) do
    row = Enum.find(identity.metadata["saved_resets"]["available_expirations"], &(&1["expires_at"] == expiration))
    assert is_map(row)
    assert {:ok, first_seen_at, 0} = DateTime.from_iso8601(row["first_seen_at"])
    first_seen_at
  end

  defp incident_first_seen!(incident) do
    assert {:ok, first_seen_at, 0} = DateTime.from_iso8601(incident.safe_evidence_snapshot["latest_reset_first_seen_at"])
    first_seen_at
  end

  defp expiration_in_days(days), do: now() |> DateTime.add(days, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
