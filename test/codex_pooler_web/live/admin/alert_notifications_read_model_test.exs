defmodule CodexPoolerWeb.Admin.AlertNotificationsReadModelTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AlertNotificationsReadModel

  setup :register_and_log_in_user

  test "owner load returns visible open and acknowledged metadata-only rows", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("owner"), name: "Owner Visible"})

    raw_prompt = "raw prompt #{unique_suffix()}"

    open =
      bell_incident_fixture(pool, %{
        severity: "critical",
        safe_evidence_snapshot: %{"prompt" => raw_prompt}
      })

    acknowledged =
      bell_incident_fixture(pool, %{
        state: "acknowledged",
        acknowledged_at: now(),
        severity: "warning"
      })

    resolved = bell_incident_fixture(pool, %{state: "resolved", resolved_at: now()})
    targetless = alert_incident_fixture(pool: pool, dedupe_key: unique_dedupe("targetless"))

    page = AlertNotificationsReadModel.load(scope)
    row_ids = Enum.map(page.rows, & &1.id)

    assert open.id in row_ids
    assert acknowledged.id in row_ids
    refute resolved.id in row_ids
    refute targetless.id in row_ids
    assert page.unread_count == 2
    assert page.badge_count == 2
    assert page.has_rows?
    refute page.empty?

    open_row = Enum.find(page.rows, &(&1.id == open.id))
    assert open_row.anchor_id == "alert-incident-#{open.id}"

    {:ok, alerts_view, _html} = live(conn, ~p"/admin/alerts?tab=incidents")
    assert has_element?(alerts_view, "#alert-incident-#{targetless.id}")

    assert open_row.reason_title == "No usable assignments"
    assert open_row.severity == "critical"
    assert open_row.state == "open"
    assert open_row.unread?
    assert open_row.last_seen_at == open.last_seen_at
    assert [%{id: pool_id, name: "Owner Visible", slug: pool_slug}] = open_row.impacted_pools
    assert pool_id == pool.id
    assert pool_slug == pool.slug
    refute inspect(page) =~ raw_prompt
  end

  test "assigned admin load redacts hidden pool targets and excludes hidden incidents", %{
    scope: owner_scope
  } do
    {:ok, assigned_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("assigned"), name: "Assigned Visible"})

    {:ok, hidden_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("hidden"), name: "Hidden Secret Pool"})

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool,
      created_by_user_id: owner_scope.user.id
    )

    admin_scope = Scope.for_user(admin)

    mixed = multi_target_incident_fixture(assigned_pool, hidden_pool)
    hidden = bell_incident_fixture(hidden_pool, %{dedupe_key: unique_dedupe("hidden")})

    page = AlertNotificationsReadModel.load(admin_scope)
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

  test "orders rows by severity, state, last seen, and id", %{scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug("ordering"), name: "Ordering Pool"})

    same_time = timestamp(~U[2026-05-31 09:00:00Z])

    info_open =
      bell_incident_fixture(pool, %{
        severity: "info",
        last_seen_at: timestamp(~U[2026-05-31 12:00:00Z])
      })

    warning_ack =
      bell_incident_fixture(pool, %{
        severity: "warning",
        state: "acknowledged",
        acknowledged_at: now(),
        last_seen_at: timestamp(~U[2026-05-31 13:00:00Z])
      })

    warning_open =
      bell_incident_fixture(pool, %{
        severity: "warning",
        state: "open",
        last_seen_at: timestamp(~U[2026-05-31 10:00:00Z])
      })

    critical_ack =
      bell_incident_fixture(pool, %{
        severity: "critical",
        state: "acknowledged",
        acknowledged_at: now(),
        last_seen_at: timestamp(~U[2026-05-31 15:00:00Z])
      })

    critical_open_old =
      bell_incident_fixture(pool, %{severity: "critical", state: "open", last_seen_at: same_time})

    critical_open_new =
      bell_incident_fixture(pool, %{
        severity: "critical",
        state: "open",
        last_seen_at: timestamp(~U[2026-05-31 11:00:00Z])
      })

    critical_open_same_time =
      bell_incident_fixture(pool, %{severity: "critical", state: "open", last_seen_at: same_time})

    ordered_ids = AlertNotificationsReadModel.load(scope).rows |> Enum.map(& &1.id)

    assert ordered_ids == [
             critical_open_new.id,
             Enum.min_by([critical_open_old, critical_open_same_time], & &1.id).id,
             Enum.max_by([critical_open_old, critical_open_same_time], & &1.id).id,
             critical_ack.id,
             warning_open.id,
             warning_ack.id,
             info_open.id
           ]
  end

  test "caps rows at 50 while unread count covers the full scoped unread set", %{scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("cap"), name: "Cap Pool"})

    for offset <- 1..55 do
      bell_incident_fixture(pool, %{
        severity: "info",
        last_seen_at: DateTime.add(timestamp(~U[2026-05-31 09:00:00Z]), offset, :second)
      })
    end

    page = AlertNotificationsReadModel.load(scope)

    assert length(page.rows) == 50
    assert page.page_size == 50
    assert page.unread_count == 55
    assert page.badge_count == 55
  end

  test "read and dismissed receipts reappear unread after recurrence", %{scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug("receipts"), name: "Receipts Pool"})

    first_seen_at = DateTime.add(now(), -120, :second)

    incident =
      bell_incident_fixture(pool, %{first_seen_at: first_seen_at, last_seen_at: first_seen_at})

    assert %{rows: [%{id: incident_id, unread?: true}], unread_count: 1} =
             AlertNotificationsReadModel.load(scope)

    assert incident_id == incident.id

    assert {:ok, _receipt} = Alerts.mark_incident_notification_read(scope, incident.id)

    assert %{rows: [%{id: ^incident_id, unread?: false}], unread_count: 0} =
             AlertNotificationsReadModel.load(scope)

    assert {:ok, _receipt} = Alerts.dismiss_incident_notification(scope, incident.id)
    assert %{rows: [], unread_count: 0, empty?: true} = AlertNotificationsReadModel.load(scope)

    recurred_at = DateTime.add(now(), 60, :second)

    incident
    |> AlertIncident.changeset(%{
      last_seen_at: recurred_at,
      occurrence_count: incident.occurrence_count + 1,
      updated_at: recurred_at
    })
    |> Repo.update!()

    assert %{rows: [%{id: ^incident_id, unread?: true}], unread_count: 1} =
             AlertNotificationsReadModel.load(scope)
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

  defp unique_slug(prefix), do: "alert-notifications-#{prefix}-#{unique_suffix()}"
  defp unique_dedupe(prefix), do: "alert:notification:#{prefix}:#{unique_suffix()}"
  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unique_suffix, do: System.unique_integer([:positive])
end
