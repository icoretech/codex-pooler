defmodule CodexPooler.Alerts.AlertsContextTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertIncident,
    AlertIncidentReceipt,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Jobs.AlertEvaluationWorker
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport
  alias Ecto.Adapters.SQL.Sandbox

  test "an edit waits for an earlier worker and retires the worker's old-condition match" do
    assert_rule_edit_order(:evaluation)
  end

  test "a worker with stale candidates waits for an edit and discards its old condition" do
    assert_rule_edit_order(:edit)
  end

  test "editing a condition retires its old incident even after both conditions recover" do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner)
    pool = pool_fixture()
    {:ok, rule} = Alerts.create_rule(scope, rule_attrs(pool, %{}))
    timestamp = now()
    assert :ok = evaluate_rule_job(rule, timestamp)
    incident = Repo.one!(from row in AlertIncident, where: row.pool_id == ^pool.id)

    assert {:ok, updated} = Alerts.update_rule(scope, rule, %{rule_kind: "pool_low_usable_assignments", min_usable_assignments: 2})
    assert Repo.get!(AlertIncident, incident.id).state == "resolved"
    assert incident_targets(incident) == []

    for _ <- 1..2 do
      %{identity: identity} = upstream_assignment_fixture(pool)
      seed_available_quota(identity, timestamp)
    end

    assert [%{action: :clear}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert [%{action: :clear}] = Alerts.evaluate_rule(updated, at: timestamp)
    assert :ok = evaluate_rule_job(updated, timestamp)
    assert {:ok, []} = Alerts.resolve_orphaned_incidents(timestamp)
    assert Repo.get!(AlertIncident, incident.id).state == "resolved"
  end

  test "threshold edits retire only the changed rule target of a shared incident" do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner)
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    timestamp = now()
    seed_available_quota(identity, timestamp, "95")
    first_channel = alert_channel_fixture(created_by_user_id: owner.id)
    second_channel = alert_channel_fixture(created_by_user_id: owner.id)
    attrs = rule_attrs(pool, %{scope_type: "upstream_identity", rule_kind: "upstream_quota_threshold", threshold_used_percent: "90", window_selector: "account_primary"})
    {:ok, first} = Alerts.create_rule(scope, Map.put(attrs, :channel_ids, [first_channel.id]))
    {:ok, second} = Alerts.create_rule(scope, Map.merge(attrs, %{display_name: "Second threshold rule", channel_ids: [second_channel.id]}))
    assert :ok = evaluate_rule_job(first, timestamp)
    assert :ok = evaluate_rule_job(second, timestamp)
    incident = Repo.one!(from row in AlertIncident, where: row.upstream_identity_id == ^identity.id)

    assert {:ok, unchanged} = Alerts.update_rule(scope, first, %{threshold_used_percent: "90.0", display_name: "Renamed threshold rule", cooldown_minutes: 60})
    assert Repo.get!(AlertIncident, incident.id).state == "open"
    assert Enum.all?(incident_targets(incident), &is_nil(&1.resolved_at))

    assert {:ok, changed} = Alerts.update_rule(scope, unchanged, %{threshold_used_percent: "99"})
    assert Repo.get!(AlertIncident, incident.id).state == "open"
    assert [%{rule_id: remaining_rule, resolved_at: nil}] = incident_targets(incident)
    assert remaining_rule == second.id
    assert [%{channel_id: remaining_channel}] = Alerts.list_incident_delivery_channels_due(incident)
    assert remaining_channel == second_channel.id
    assert :ok = evaluate_rule_job(changed, timestamp)
    assert Repo.get!(AlertIncident, incident.id).state == "open"

    assert {:ok, _} = Alerts.update_rule(scope, second.id, %{threshold_used_percent: "99"})
    assert Repo.get!(AlertIncident, incident.id).state == "resolved"
    assert incident_targets(incident) == []

    assert {:ok, current} = Alerts.update_rule(scope, first, %{display_name: "Edited through stale struct"})
    assert Decimal.equal?(current.threshold_used_percent, Decimal.new(99))
  end

  test "model and route condition edits retire targets while rejected edits preserve them" do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner)
    pool = pool_fixture()
    {:ok, rule} = Alerts.create_rule(scope, rule_attrs(pool, %{}))
    timestamp = now()
    assert :ok = evaluate_rule_job(rule, timestamp)
    incident = Repo.one!(from row in AlertIncident, where: row.pool_id == ^pool.id)

    assert {:error, _} = Alerts.update_rule(scope, rule, %{model: "example-model", channel_ids: [Ecto.UUID.generate()]})
    assert is_nil(Repo.get!(AlertRule, rule.id).model)
    assert Repo.get!(AlertIncident, incident.id).state == "open"
    assert Enum.all?(incident_targets(incident), &is_nil(&1.resolved_at))

    assert {:ok, changed} = Alerts.update_rule(scope, rule, %{model: "example-model"})
    assert Repo.get!(AlertIncident, incident.id).state == "resolved"
    assert :ok = evaluate_rule_job(changed, timestamp)
    next_incident = Repo.one!(from row in AlertIncident, where: row.pool_id == ^pool.id and row.state == "open")
    refute next_incident.id == incident.id

    assert {:ok, _} = Alerts.update_rule(scope, changed, %{route_class: "proxy_stream"})
    assert Repo.get!(AlertIncident, next_incident.id).state == "resolved"
  end

  test "owner and assigned admins list manageable active pool targets" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})

    assigned_pool =
      pool_fixture(%{slug: "alerts-target-assigned", name: "Alerts Target Assigned"})

    hidden_pool = pool_fixture(%{slug: "alerts-target-hidden", name: "Alerts Target Hidden"})

    disabled_pool =
      pool_fixture(%{
        slug: "alerts-target-disabled",
        name: "Alerts Target Disabled",
        status: "disabled"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)
    operator_pool_assignment_fixture(admin, disabled_pool, created_by_user_id: owner.id)

    assert {:ok, owner_pools} = Alerts.list_manageable_pools(owner_scope)
    owner_pool_ids = owner_pools |> Enum.map(& &1.id) |> MapSet.new()
    assert assigned_pool.id in owner_pool_ids
    assert hidden_pool.id in owner_pool_ids
    refute disabled_pool.id in owner_pool_ids

    assert {:ok, admin_pools} = Alerts.list_manageable_pools(Scope.for_user(admin))
    assert Enum.map(admin_pools, & &1.id) == [assigned_pool.id]
  end

  test "owner manages rules and channels through the Alerts facade" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "alerts-owner-rule", name: "Alerts Owner Rule"})

    assert {:ok, channel} =
             Alerts.create_channel(owner_scope, %{
               channel_type: "webhook",
               display_name: "Webhook operations",
               state: "active",
               email_to: nil,
               endpoint_scheme: "https",
               endpoint_host: "hooks.example.com",
               endpoint_path_prefix: "/alerts",
               endpoint_fingerprint: "sha256:example",
               webhook_signing_secret_ciphertext: <<1, 2, 3>>,
               webhook_signing_secret_nonce: <<4, 5, 6>>,
               webhook_signing_secret_aad: %{"channel_id" => "pending"},
               webhook_signing_secret_key_version: "v1",
               metadata: %{}
             })

    refute Map.has_key?(channel, :webhook_signing_secret_ciphertext)
    refute Map.has_key?(channel, :webhook_signing_secret_nonce)
    refute Map.has_key?(channel, :webhook_signing_secret_aad)

    assert {:ok, rule} =
             Alerts.create_rule(
               owner_scope,
               rule_attrs(pool, %{display_name: "Owner coverage", channel_ids: [channel.id]})
             )

    assert rule.pool_id == pool.id
    assert rule.created_by_user_id == owner.id

    assert {:ok, [listed_rule]} = Alerts.list_rules(owner_scope, pool_id: pool.id)
    assert listed_rule.id == rule.id

    assert {:ok, updated_rule} = Alerts.update_rule(owner_scope, rule.id, %{state: "disabled"})
    assert updated_rule.state == "disabled"
    assert updated_rule.disabled_at

    assert {:ok, deleted_rule} = Alerts.delete_rule(owner_scope, updated_rule.id)
    assert deleted_rule.id == rule.id
    assert {:ok, []} = Alerts.list_rules(owner_scope, pool_id: pool.id)

    assert {:ok, deleted_channel} = Alerts.delete_channel(owner_scope, channel.id)
    assert deleted_channel.id == channel.id
  end

  test "real rule creation and update persist route class for usability rules" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "alerts-route-class", name: "Alerts Route Class"})

    for rule_kind <- ["pool_no_usable_assignments", "pool_low_usable_assignments"] do
      attrs =
        rule_attrs(pool, %{
          display_name: "Route class #{rule_kind}",
          rule_kind: rule_kind,
          route_class: "proxy_stream",
          min_usable_assignments: if(rule_kind == "pool_low_usable_assignments", do: 2, else: nil)
        })

      assert {:ok, rule} = Alerts.create_rule(owner_scope, attrs)
      assert Map.get(rule, :route_class) == "proxy_stream"
      assert Map.get(Repo.get!(AlertRule, rule.id), :route_class) == "proxy_stream"

      assert {:ok, updated_rule} =
               Alerts.update_rule(owner_scope, rule.id, %{route_class: "proxy_compact"})

      assert Map.get(updated_rule, :route_class) == "proxy_compact"
      assert Map.get(Repo.get!(AlertRule, rule.id), :route_class) == "proxy_compact"

      assert {:ok, unscoped_rule} =
               Alerts.update_rule(owner_scope, rule.id, %{route_class: " "})

      assert is_nil(Map.get(unscoped_rule, :route_class))
    end
  end

  test "unsupported rule kinds reject direct route class input and clear stale scope on transition" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "alerts-route-rejection", name: "Alerts Route Rejection"})

    unsupported_attrs =
      rule_attrs(pool, %{
        rule_kind: "pool_all_assignments_in_state",
        target_state: "exhausted",
        route_class: "proxy_stream"
      })

    assert {:error, create_changeset} = Alerts.create_rule(owner_scope, unsupported_attrs)
    assert "is not supported for this rule kind" in errors_on(create_changeset).route_class

    assert {:ok, scoped_rule} =
             Alerts.create_rule(
               owner_scope,
               rule_attrs(pool, %{route_class: "proxy_stream"})
             )

    assert {:error, update_changeset} =
             Alerts.update_rule(owner_scope, scoped_rule, unsupported_attrs)

    assert "is not supported for this rule kind" in errors_on(update_changeset).route_class

    assert {:ok, transitioned_rule} =
             Alerts.update_rule(owner_scope, scoped_rule, %{
               rule_kind: "pool_all_assignments_in_state",
               target_state: "exhausted"
             })

    assert transitioned_rule.rule_kind == "pool_all_assignments_in_state"
    assert is_nil(Map.get(transitioned_rule, :route_class))
  end

  test "assigned admins manage rules only for assigned pools" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)
    assigned_pool = pool_fixture(%{slug: "alerts-admin-assigned", name: "Alerts Admin Assigned"})
    hidden_pool = pool_fixture(%{slug: "alerts-admin-hidden", name: "Alerts Admin Hidden"})

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    assert {:ok, admin_rule} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(assigned_pool, %{display_name: "Admin rule"})
             )

    assert {:ok, _hidden_rule} =
             Alerts.create_rule(
               owner_scope,
               rule_attrs(hidden_pool, %{display_name: "Hidden rule"})
             )

    assert {:ok, [listed_rule]} = Alerts.list_rules(admin_scope)
    assert listed_rule.id == admin_rule.id

    assert {:ok, updated_rule} =
             Alerts.update_rule(admin_scope, admin_rule.id, %{display_name: "Admin rule updated"})

    assert updated_rule.display_name == "Admin rule updated"

    assert {:error, denied_create} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(hidden_pool, %{display_name: "Denied rule"})
             )

    assert denied_create.code == :capability_denied
    refute denied_create.message =~ hidden_pool.id
    refute denied_create.message =~ hidden_pool.name

    assert {:error, denied_filter} = Alerts.list_rules(admin_scope, pool_id: hidden_pool.id)
    assert denied_filter.code == :capability_denied
    refute denied_filter.message =~ hidden_pool.id
    refute denied_filter.message =~ hidden_pool.name

    assert {:ok, deleted_rule} = Alerts.delete_rule(admin_scope, admin_rule.id)
    assert deleted_rule.id == admin_rule.id
  end

  @tag :saved_reset_banked_first_seen_authorization
  test "saved reset first-seen rule management follows pool and channel visibility" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    assigned_pool =
      pool_fixture(%{
        slug: "saved-reset-alert-assigned-#{unique_suffix()}",
        name: "Saved Reset Alert Assigned"
      })

    hidden_pool =
      pool_fixture(%{
        slug: "saved-reset-alert-hidden-#{unique_suffix()}",
        name: "Saved Reset Alert Hidden"
      })

    disabled_pool =
      pool_fixture(%{
        slug: "saved-reset-alert-disabled-#{unique_suffix()}",
        name: "Saved Reset Alert Disabled",
        status: "disabled"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)
    operator_pool_assignment_fixture(admin, disabled_pool, created_by_user_id: owner.id)

    owner_channel =
      alert_channel_fixture(
        created_by_user_id: owner.id,
        display_name: "Owner saved reset channel",
        email_to: "owner-saved-reset@example.com"
      )

    admin_channel =
      alert_channel_fixture(
        created_by_user_id: admin.id,
        display_name: "Admin saved reset channel",
        email_to: "admin-saved-reset@example.com"
      )

    assert {:ok, owner_rule} =
             Alerts.create_rule(
               owner_scope,
               saved_reset_rule_attrs(hidden_pool, %{
                 display_name: "Owner saved reset rule",
                 channel_ids: [owner_channel.id]
               })
             )

    assert owner_rule.pool_id == hidden_pool.id

    assert {:ok, admin_rule} =
             Alerts.create_rule(
               admin_scope,
               saved_reset_rule_attrs(assigned_pool, %{
                 display_name: "Admin saved reset rule",
                 channel_ids: [admin_channel.id]
               })
             )

    assert admin_rule.pool_id == assigned_pool.id

    assert {:error, hidden_pool_error} =
             Alerts.create_rule(
               admin_scope,
               saved_reset_rule_attrs(hidden_pool, %{display_name: "Hidden saved reset rule"})
             )

    assert hidden_pool_error.code == :capability_denied
    refute hidden_pool_error.message =~ hidden_pool.id
    refute hidden_pool_error.message =~ hidden_pool.name
    refute hidden_pool_error.message =~ hidden_pool.slug

    assert {:error, disabled_pool_error} =
             Alerts.create_rule(
               admin_scope,
               saved_reset_rule_attrs(disabled_pool, %{display_name: "Disabled saved reset rule"})
             )

    assert disabled_pool_error.code in [:capability_denied, :pool_not_found]
    refute disabled_pool_error.message =~ disabled_pool.id
    refute disabled_pool_error.message =~ disabled_pool.name
    refute disabled_pool_error.message =~ disabled_pool.slug

    assert {:error, hidden_channel_error} =
             Alerts.create_rule(
               admin_scope,
               saved_reset_rule_attrs(assigned_pool, %{
                 display_name: "Hidden channel saved reset rule",
                 channel_ids: [owner_channel.id]
               })
             )

    assert hidden_channel_error.code == :channel_not_found
    refute hidden_channel_error.message =~ owner_channel.display_name
    refute hidden_channel_error.message =~ owner_channel.email_to

    assert [%AlertRuleChannel{alert_channel_id: owner_channel_id}] =
             Repo.all(from link in AlertRuleChannel, where: link.alert_rule_id == ^owner_rule.id)

    assert owner_channel_id == owner_channel.id

    assert [%AlertRuleChannel{alert_channel_id: admin_channel_id}] =
             Repo.all(from link in AlertRuleChannel, where: link.alert_rule_id == ^admin_rule.id)

    assert admin_channel_id == admin_channel.id
  end

  test "assigned admins manage only their own channels" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    %{user: other_admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    owner_channel =
      alert_channel_fixture(
        created_by_user_id: owner.id,
        display_name: "Owner private channel",
        email_to: "owner-alerts@example.com"
      )

    other_channel =
      alert_channel_fixture(
        created_by_user_id: other_admin.id,
        display_name: "Other private channel",
        email_to: "other-alerts@example.com"
      )

    assert {:ok, admin_channel} =
             Alerts.create_channel(admin_scope, %{
               channel_type: "email",
               display_name: "Admin owned channel",
               email_to: "alerts@example.com",
               metadata: %{}
             })

    assert admin_channel.created_by_user_id == admin.id

    assert {:ok, [listed_channel]} = Alerts.list_channels(admin_scope)
    assert listed_channel.id == admin_channel.id

    assert {:ok, updated_channel} =
             Alerts.update_channel(admin_scope, admin_channel.id, %{state: "disabled"})

    assert updated_channel.state == "disabled"

    assert {:error, update_error} =
             Alerts.update_channel(admin_scope, owner_channel.id, %{state: "disabled"})

    assert update_error.code == :channel_not_found
    refute update_error.message =~ owner_channel.display_name
    refute update_error.message =~ owner_channel.email_to

    assert {:error, delete_error} = Alerts.delete_channel(admin_scope, other_channel.id)
    assert delete_error.code == :channel_not_found
    refute delete_error.message =~ other_channel.display_name
    refute delete_error.message =~ other_channel.email_to

    assert %AlertChannel{state: "active"} = Repo.get(AlertChannel, owner_channel.id)
    assert %AlertChannel{state: "active"} = Repo.get(AlertChannel, other_channel.id)
    assert {:ok, deleted_channel} = Alerts.delete_channel(admin_scope, admin_channel.id)
    assert deleted_channel.id == admin_channel.id
  end

  test "assigned admins cannot attach hidden channels to rules" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)
    assigned_pool = pool_fixture(%{slug: "alerts-admin-channels", name: "Alerts Admin Channels"})
    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    admin_channel = alert_channel_fixture(created_by_user_id: admin.id)

    owner_channel =
      alert_channel_fixture(
        created_by_user_id: owner.id,
        display_name: "Owner hidden alerts",
        email_to: "hidden-owner-alerts@example.com"
      )

    assert {:ok, admin_rule} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(assigned_pool, %{
                 display_name: "Admin owned channel rule",
                 channel_ids: [admin_channel.id]
               })
             )

    assert 1 ==
             Repo.aggregate(
               from(link in AlertRuleChannel, where: link.alert_rule_id == ^admin_rule.id),
               :count,
               :id
             )

    before_rule_count = Repo.aggregate(from(rule in AlertRule), :count, :id)

    assert {:error, create_error} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(assigned_pool, %{
                 display_name: "Hidden channel rule",
                 channel_ids: [owner_channel.id]
               })
             )

    assert create_error.code == :channel_not_found
    refute create_error.message =~ owner_channel.display_name
    refute create_error.message =~ owner_channel.email_to
    assert Repo.aggregate(from(rule in AlertRule), :count, :id) == before_rule_count

    assert {:error, update_error} =
             Alerts.update_rule(admin_scope, admin_rule.id, %{channel_ids: [owner_channel.id]})

    assert update_error.code == :channel_not_found
    refute update_error.message =~ owner_channel.display_name
    refute update_error.message =~ owner_channel.email_to

    assert [%AlertRuleChannel{alert_channel_id: linked_channel_id}] =
             Repo.all(from link in AlertRuleChannel, where: link.alert_rule_id == ^admin_rule.id)

    assert linked_channel_id == admin_channel.id
  end

  test "pool-scoped incident actions require a manageable pool" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    assigned_pool =
      pool_fixture(%{slug: "alerts-action-assigned", name: "Alerts Action Assigned"})

    hidden_pool = pool_fixture(%{slug: "alerts-action-hidden", name: "Alerts Action Hidden"})

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    assigned_incident =
      alert_incident_fixture(
        pool: assigned_pool,
        dedupe_key: "alert:action:#{System.unique_integer([:positive])}"
      )

    hidden_incident =
      alert_incident_fixture(
        pool: hidden_pool,
        dedupe_key: "alert:hidden:#{System.unique_integer([:positive])}"
      )

    assert {:ok, acknowledged} = Alerts.acknowledge_incident(admin_scope, assigned_incident.id)
    assert acknowledged.state == "acknowledged"
    assert acknowledged.acknowledged_at

    assert {:ok, resolved} = Alerts.resolve_incident(owner_scope, acknowledged.id)
    assert resolved.state == "resolved"
    assert resolved.resolved_at

    assert {:error, hidden_error} = Alerts.acknowledge_incident(admin_scope, hidden_incident.id)
    assert hidden_error.code == :incident_not_found
    refute hidden_error.message =~ hidden_pool.id
    refute hidden_error.message =~ hidden_pool.name
  end

  test "operator notification receipts are idempotent and do not mutate global incident lifecycle" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)
    pool = pool_fixture(%{slug: "alerts-receipt-idempotent", name: "Alerts Receipt Idempotent"})
    operator_pool_assignment_fixture(admin, pool, created_by_user_id: owner.id)
    incident = bell_incident_fixture(pool, "alert:receipt:idempotent")

    assert {:ok, read_receipt} = Alerts.mark_incident_notification_read(owner_scope, incident.id)

    assert {:ok, reread_receipt} =
             Alerts.mark_incident_notification_read(owner_scope, incident.id)

    assert read_receipt.id == reread_receipt.id
    assert reread_receipt.operator_id == owner.id
    assert reread_receipt.incident_id == incident.id
    assert DateTime.compare(reread_receipt.read_at, incident.last_seen_at) in [:gt, :eq]

    assert {:ok, dismissed_receipt} =
             Alerts.dismiss_incident_notification(admin_scope, incident.id)

    assert {:ok, redismissed_receipt} =
             Alerts.dismiss_incident_notification(admin_scope, incident.id)

    assert dismissed_receipt.id == redismissed_receipt.id
    assert redismissed_receipt.operator_id == admin.id
    assert redismissed_receipt.dismissed_at
    assert redismissed_receipt.read_at

    assert 2 ==
             Repo.aggregate(
               from(receipt in AlertIncidentReceipt, where: receipt.incident_id == ^incident.id),
               :count,
               :id
             )

    persisted_incident = Repo.get!(AlertIncident, incident.id)
    assert persisted_incident.state == incident.state
    assert persisted_incident.acknowledged_at == incident.acknowledged_at
    assert persisted_incident.resolved_at == incident.resolved_at
  end

  test "notification receipt writes do not reveal or mutate hidden incidents" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    assigned_pool =
      pool_fixture(%{slug: "alerts-receipt-assigned", name: "Alerts Receipt Assigned"})

    hidden_pool = pool_fixture(%{slug: "alerts-receipt-hidden", name: "Alerts Receipt Hidden"})
    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)
    hidden_incident = bell_incident_fixture(hidden_pool, "alert:receipt:hidden")

    assert {:error, read_error} =
             Alerts.mark_incident_notification_read(admin_scope, hidden_incident.id)

    assert read_error.code == :incident_not_found
    refute read_error.message =~ hidden_pool.id
    refute read_error.message =~ hidden_pool.name

    assert {:error, dismiss_error} =
             Alerts.dismiss_incident_notification(admin_scope, hidden_incident.id)

    assert dismiss_error.code == :incident_not_found
    refute dismiss_error.message =~ hidden_pool.id
    refute dismiss_error.message =~ hidden_pool.name

    refute Repo.exists?(
             from(receipt in AlertIncidentReceipt,
               where: receipt.incident_id == ^hidden_incident.id
             )
           )

    assert Repo.get!(AlertIncident, hidden_incident.id).state == hidden_incident.state
  end

  test "dismiss all recomputes visible bell-eligible incidents server-side" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    assigned_pool =
      pool_fixture(%{slug: "alerts-dismiss-all-assigned", name: "Alerts Dismiss All Assigned"})

    hidden_pool =
      pool_fixture(%{slug: "alerts-dismiss-all-hidden", name: "Alerts Dismiss All Hidden"})

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    visible_open = bell_incident_fixture(assigned_pool, "alert:dismiss-all:open")

    visible_acknowledged =
      bell_incident_fixture(assigned_pool, "alert:dismiss-all:ack", %{
        state: "acknowledged",
        acknowledged_at: now()
      })

    hidden = bell_incident_fixture(hidden_pool, "alert:dismiss-all:hidden")

    no_target =
      alert_incident_fixture(pool: assigned_pool, dedupe_key: "alert:dismiss-all:no-target")

    resolved =
      bell_incident_fixture(assigned_pool, "alert:dismiss-all:resolved", %{
        state: "resolved",
        resolved_at: now()
      })

    assert {:ok, 2} = Alerts.dismiss_all_visible_incident_notifications(admin_scope)

    dismissed_ids =
      Repo.all(
        from receipt in AlertIncidentReceipt,
          where: receipt.operator_id == ^admin.id,
          select: receipt.incident_id
      )

    assert Enum.sort(dismissed_ids) == Enum.sort([visible_open.id, visible_acknowledged.id])
    refute hidden.id in dismissed_ids
    refute no_target.id in dismissed_ids
    refute resolved.id in dismissed_ids
  end

  test "read and dismiss recurrence semantics follow incident last_seen_at" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "alerts-receipt-recurrence", name: "Alerts Receipt Recurrence"})
    first_seen_at = DateTime.add(now(), -120, :second)

    incident =
      bell_incident_fixture(pool, "alert:receipt:recurrence", %{
        first_seen_at: first_seen_at,
        last_seen_at: first_seen_at
      })

    assert {:ok, read_receipt} = Alerts.mark_incident_notification_read(owner_scope, incident.id)
    assert Alerts.incident_notification_read?(incident, read_receipt)
    refute Alerts.incident_notification_unread?(incident, read_receipt)

    assert {:ok, dismissed_receipt} =
             Alerts.dismiss_incident_notification(owner_scope, incident.id)

    assert Alerts.incident_notification_dismissed?(incident, dismissed_receipt)

    recurred_at = DateTime.add(dismissed_receipt.dismissed_at, 1, :microsecond)

    recurred_incident =
      incident
      |> AlertIncident.changeset(%{
        last_seen_at: recurred_at,
        occurrence_count: incident.occurrence_count + 1,
        updated_at: recurred_at
      })
      |> Repo.update!()

    refute Alerts.incident_notification_read?(recurred_incident, dismissed_receipt)
    assert Alerts.incident_notification_unread?(recurred_incident, dismissed_receipt)
    refute Alerts.incident_notification_dismissed?(recurred_incident, dismissed_receipt)

    assert {:ok, 1} = Alerts.dismiss_all_visible_incident_notifications(owner_scope)
    updated_receipt = Repo.get!(AlertIncidentReceipt, dismissed_receipt.id)
    assert Alerts.incident_notification_dismissed?(recurred_incident, updated_receipt)
  end

  defp rule_attrs(pool, overrides) do
    overrides = Map.new(overrides)

    %{
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      display_name: Map.get(overrides, :display_name, "Pool usable assignment coverage"),
      severity: "critical",
      cooldown_minutes: 30,
      state: "active",
      metadata: %{}
    }
    |> Map.merge(overrides)
  end

  defp evaluate_rule_job(rule, timestamp) do
    perform_job(AlertEvaluationWorker, %{"alert_rule_id" => rule.id, "evaluation_window_started_at" => DateTime.to_iso8601(timestamp)}, attempted_at: timestamp)
  end

  defp assert_rule_edit_order(first_kind) do
    %{user: owner} = committed_bootstrap_owner_fixture!()
    scope = Scope.for_user(owner)

    {rule, incident} =
      UnboxedFixture.run_unboxed(fn ->
        pool = pool_fixture(%{created_by_user_id: owner.id})
        {:ok, rule} = Alerts.create_rule(scope, rule_attrs(pool, %{}))
        assert :ok = evaluate_rule_job(rule, now())
        {rule, Repo.one!(from row in AlertIncident, where: row.pool_id == ^pool.id)}
      end)

    tasks = start_supervised!({Task.Supervisor, []})
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.hold_rule_query/4, nil)
    operations = %{evaluation: fn -> evaluate_rule_job(rule, now()) end, edit: fn -> Alerts.update_rule(scope, rule, %{rule_kind: "pool_low_usable_assignments", min_usable_assignments: 2}) end}
    first = start_rule_actor(tasks, operations[first_kind], true)
    assert_receive {:rule_actor_backend, first_pid, first_backend}
    assert first_pid == first.pid
    assert_receive {:rule_lock_held, ^first_pid}

    second_kind = if first_kind == :edit, do: :evaluation, else: :edit
    second = start_rule_actor(tasks, operations[second_kind], false)
    assert_receive {:rule_actor_backend, second_pid, second_backend}
    assert second_pid == second.pid
    refute first_backend == second_backend
    assert_rule_actor_blocked(second_backend, first_backend, System.monotonic_time(:millisecond) + 5_000)
    send(first.pid, :release_rule_lock)
    results = [{first_kind, finish_rule_actor(first)}, {second_kind, finish_rule_actor(second)}] |> Map.new()
    assert results.evaluation == :ok
    assert {:ok, %AlertRule{rule_kind: "pool_low_usable_assignments"}} = results.edit

    UnboxedFixture.run_unboxed(fn ->
      current = Repo.get!(AlertIncident, incident.id)
      assert current.state == "resolved"
      assert current.occurrence_count == if(first_kind == :evaluation, do: 2, else: 1)
      refute Repo.exists?(from row in AlertIncident, where: row.pool_id == ^rule.pool_id and row.state == "open")
    end)
  end

  defp start_rule_actor(tasks, operation, hold?) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(tasks, fn -> Sandbox.unboxed_run(Repo, fn -> run_rule_actor(parent, operation, hold?) end) end)

    %{task: task, pid: task.pid, monitor: Process.monitor(task.pid)}
  end

  defp run_rule_actor(parent, operation, hold?) do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:rule_actor_backend, self(), backend})
    if hold?, do: Process.put({__MODULE__, :hold_rule}, parent)
    operation.()
  end

  defp finish_rule_actor(%{task: task, pid: pid, monitor: monitor}) do
    result = Task.await(task, 10_000)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    result
  end

  def hold_rule_query(_event, _measurements, %{source: "alert_rules", query: query}, _config) do
    if String.contains?(query, "FOR UPDATE") do
      case Process.delete({__MODULE__, :hold_rule}) do
        nil ->
          :ok

        parent ->
          send(parent, {:rule_lock_held, self()})

          receive do
            :release_rule_lock -> :ok
          after
            10_000 -> raise "rule lock barrier was not released"
          end
      end
    end
  end

  def hold_rule_query(_event, _measurements, _metadata, _config), do: :ok

  defp assert_rule_actor_blocked(waiter, holder, deadline) do
    blocked? = UnboxedFixture.run_unboxed(fn -> Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [holder, waiter]).rows == [[true]] end)

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline, "rule actor did not wait on the other backend's rule lock"

      receive do
      after
        10 -> :ok
      end

      assert_rule_actor_blocked(waiter, holder, deadline)
    end
  end

  defp seed_available_quota(identity, timestamp, used_percent \\ "10") do
    attrs = BackendCodexTestSupport.primary_quota_window_attrs(%{used_percent: Decimal.new(used_percent), reset_at: DateTime.add(timestamp, 3600, :second), observed_at: timestamp})
    assert {:ok, [_]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
  end

  defp incident_targets(incident), do: Repo.all(from target in AlertIncidentTarget, where: target.incident_id == ^incident.id)

  defp saved_reset_rule_attrs(pool, overrides) do
    rule_attrs(
      pool,
      Map.merge(
        %{
          scope_type: "upstream_identity",
          rule_kind: "upstream_saved_reset_banked_first_seen",
          severity: "info",
          cooldown_minutes: 30
        },
        Map.new(overrides)
      )
    )
  end

  defp bell_incident_fixture(pool, dedupe_key, incident_attrs \\ %{}) do
    now = now()

    rule =
      alert_rule_fixture(pool, %{display_name: "Bell rule #{System.unique_integer([:positive])}"})

    incident =
      incident_attrs
      |> Map.new()
      |> Map.merge(%{pool: pool, dedupe_key: dedupe_key})
      |> alert_incident_fixture()

    alert_incident_target_fixture(incident, rule, pool, %{
      first_matched_at: Map.get(incident_attrs, :first_seen_at, now),
      last_matched_at: Map.get(incident_attrs, :last_seen_at, now)
    })

    incident
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unique_suffix, do: System.unique_integer([:positive])
end
