defmodule CodexPooler.Admin.AlertNotificationQueryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.AlertNotificationQuery
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Repo

  test "load/1 returns visible notification metadata and full unread count" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: unique_slug("owner"), name: "Owner Visible"})
    raw_prompt = "raw prompt #{unique_suffix()}"

    open =
      bell_incident_fixture(pool, %{
        severity: "critical",
        safe_evidence_snapshot: %{"prompt" => raw_prompt}
      })

    resolved = bell_incident_fixture(pool, %{state: "resolved", resolved_at: now()})
    targetless = alert_incident_fixture(pool: pool, dedupe_key: unique_dedupe("targetless"))

    page = AlertNotificationQuery.load(scope)
    row_ids = Enum.map(page.rows, & &1.id)

    assert open.id in row_ids
    refute resolved.id in row_ids
    refute targetless.id in row_ids
    assert page.unread_count == 1
    assert page.page_size == 50

    open_row = Enum.find(page.rows, &(&1.id == open.id))
    assert open_row.rule_kind == "pool_no_usable_assignments"
    assert open_row.severity == "critical"
    assert open_row.state == "open"
    assert open_row.unread?
    assert open_row.last_seen_at == open.last_seen_at
    assert [%{id: pool_id, name: "Owner Visible", slug: pool_slug}] = open_row.impacted_pools
    assert pool_id == pool.id
    assert pool_slug == pool.slug
    refute Map.has_key?(open_row, :safe_evidence_snapshot)
    refute Map.has_key?(open_row, :suppression_metadata)
    refute Map.has_key?(open_row, :dedupe_key)
    refute inspect(page) =~ raw_prompt
  end

  test "load/1 scopes impacted pools for assigned admins" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    assigned_pool = pool_fixture(%{slug: unique_slug("assigned"), name: "Assigned Visible"})
    hidden_pool = pool_fixture(%{slug: unique_slug("hidden"), name: "Hidden Secret Pool"})

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)
    admin_scope = Scope.for_user(admin)

    mixed = multi_target_incident_fixture(assigned_pool, hidden_pool)
    hidden = bell_incident_fixture(hidden_pool, %{dedupe_key: unique_dedupe("hidden")})

    page = AlertNotificationQuery.load(admin_scope)
    row_ids = Enum.map(page.rows, & &1.id)

    assert mixed.id in row_ids
    refute hidden.id in row_ids
    assert page.unread_count == 1

    mixed_row = Enum.find(page.rows, &(&1.id == mixed.id))
    assert [%{id: assigned_pool_id, name: "Assigned Visible"}] = mixed_row.impacted_pools
    assert assigned_pool_id == assigned_pool.id
    refute inspect(page) =~ hidden_pool.id
    refute inspect(page) =~ hidden_pool.name
    refute inspect(page) =~ hidden_pool.slug
  end

  test "load/1 applies receipt freshness and keeps dismissed recurrences visible" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: unique_slug("receipts"), name: "Receipts Pool"})
    first_seen_at = DateTime.add(now(), -120, :second)

    incident =
      bell_incident_fixture(pool, %{first_seen_at: first_seen_at, last_seen_at: first_seen_at})

    assert %{rows: [%{id: incident_id, unread?: true}], unread_count: 1} =
             AlertNotificationQuery.load(scope)

    assert incident_id == incident.id
    assert {:ok, _receipt} = Alerts.mark_incident_notification_read(scope, incident.id)

    assert %{rows: [%{id: ^incident_id, unread?: false}], unread_count: 0} =
             AlertNotificationQuery.load(scope)

    assert {:ok, _receipt} = Alerts.dismiss_incident_notification(scope, incident.id)
    assert %{rows: [], unread_count: 0} = AlertNotificationQuery.load(scope)

    recurred_at = DateTime.add(now(), 60, :second)

    incident
    |> AlertIncident.changeset(%{
      last_seen_at: recurred_at,
      occurrence_count: incident.occurrence_count + 1,
      updated_at: recurred_at
    })
    |> Repo.update!()

    assert %{rows: [%{id: ^incident_id, unread?: true}], unread_count: 1} =
             AlertNotificationQuery.load(scope)
  end

  test "load/1 caps rows while unread_count covers all visible unread notifications" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: unique_slug("cap"), name: "Cap Pool"})

    for offset <- 1..55 do
      bell_incident_fixture(pool, %{
        severity: "info",
        last_seen_at: DateTime.add(timestamp(~U[2026-05-31 09:00:00Z]), offset, :second)
      })
    end

    page = AlertNotificationQuery.load(scope)

    assert length(page.rows) == 50
    assert page.page_size == 50
    assert page.unread_count == 55
  end

  defp bell_incident_fixture(pool, attrs) do
    attrs = Map.new(attrs)
    rule = alert_rule_fixture(pool, %{display_name: "Bell rule #{unique_suffix()}"})

    incident =
      attrs
      |> Map.put_new(:dedupe_key, unique_dedupe("bell"))
      |> Map.put(:pool, pool)
      |> alert_incident_fixture()

    alert_incident_target_fixture(incident, rule, pool, %{
      first_matched_at: Map.get(attrs, :first_seen_at, incident.first_seen_at),
      last_matched_at: Map.get(attrs, :last_seen_at, incident.last_seen_at)
    })

    incident
  end

  defp multi_target_incident_fixture(assigned_pool, hidden_pool) do
    assigned_rule =
      alert_rule_fixture(assigned_pool, %{display_name: "Assigned rule #{unique_suffix()}"})

    hidden_rule =
      alert_rule_fixture(hidden_pool, %{display_name: "Hidden rule #{unique_suffix()}"})

    incident = alert_incident_fixture(dedupe_key: unique_dedupe("mixed"), pool_id: nil, pool: nil)

    alert_incident_target_fixture(incident, assigned_rule, assigned_pool)
    alert_incident_target_fixture(incident, hidden_rule, hidden_pool)

    incident
  end

  defp unique_slug(prefix), do: "admin-alert-notifications-#{prefix}-#{unique_suffix()}"
  defp unique_dedupe(prefix), do: "admin:alert:notification:#{prefix}:#{unique_suffix()}"
  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unique_suffix, do: System.unique_integer([:positive])
end
