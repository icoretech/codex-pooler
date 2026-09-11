defmodule CodexPoolerWeb.Admin.IncidentsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Repo
  alias CodexPooler.Status.Events
  alias CodexPooler.Status.Schemas.Incident

  setup :register_and_log_in_user

  test "redirects unauthenticated operators to login" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/incidents")
  end

  test "renders an empty read-only incidents page for authenticated operators", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/incidents")

    assert has_element?(view, "#admin-incidents-page")

    assert has_element?(
             view,
             "#admin-nav-incidents[href='/admin/incidents'][aria-current='page']"
           )

    assert has_element?(view, "#admin-incidents-active-section")
    assert has_element?(view, "#admin-incidents-history-section")
    assert has_element?(view, "#admin-incidents-active-empty")
    assert has_element?(view, "#admin-incidents-history-empty")
    assert has_element?(view, "#admin-incidents-feed-unavailable")

    assert has_element?(
             view,
             "#admin-incidents-feed-unavailable",
             "first successful refresh is still pending"
           )

    refute html =~ "last successful fetch was ."
    refute html =~ "Acknowledge"
    refute html =~ "Resolve incident"
    refute html =~ "Delete incident"
  end

  test "renders active and terminal incidents on equivalent desktop and mobile surfaces", %{
    conn: conn
  } do
    now = ~U[2026-09-10 12:00:00Z]
    active = incident_fixture("active-guid", "Investigating outage", "Investigating", now)

    resolved =
      incident_fixture(
        "resolved-guid",
        "Resolved outage",
        "Resolved",
        DateTime.add(now, -3600, :second)
      )

    retired =
      incident_fixture(
        "retired-guid",
        "Retired outage",
        "Monitoring",
        DateTime.add(now, -7200, :second)
      )

    Repo.update!(Incident.changeset(retired, %{retired_at: now, updated_at: now}))

    OpenAIStatus.upsert_feed_state(%{
      last_success_at: now,
      last_attempt_at: now,
      active_count: 1,
      aggregate_revision: 3,
      updated_at: now
    })

    {:ok, view, html} = live(conn, ~p"/admin/incidents")

    assert has_element?(view, "#admin-incidents-active-desktop")
    assert has_element?(view, "#admin-incidents-active-mobile")
    assert has_element?(view, "#admin-incidents-history-desktop")
    assert has_element?(view, "#admin-incidents-history-mobile")

    assert has_element?(
             view,
             "#admin-incidents-active-desktop-row-#{active.id}[data-role='openai-incident-row']"
           )

    assert has_element?(
             view,
             "#admin-incidents-active-mobile-card-#{active.id}[data-role='openai-incident-card']"
           )

    assert has_element?(
             view,
             "#admin-incidents-history-desktop-row-#{resolved.id}",
             "Resolved outage"
           )

    assert has_element?(
             view,
             "#admin-incidents-history-desktop-row-#{retired.id}",
             "Retired outage"
           )

    assert has_element?(
             view,
             "[data-role='incident-source-link'][href='https://status.openai.com/incidents/active-guid']"
           )

    assert has_element?(
             view,
             "[data-role='incident-status'][data-status='investigating']",
             "Investigating"
           )

    assert has_element?(view, "[data-role='incident-status'][data-status='resolved']", "Resolved")
    assert html =~ "Retired"
    refute html =~ "admin-alerts-incident"
    refute html =~ "phx-click=\"acknowledge"
    refute html =~ "phx-click=\"resolve"
  end

  test "shows stale and failed feed state while preserving incident metadata", %{conn: conn} do
    now = DateTime.utc_now()
    stale = DateTime.add(now, -1_800, :second)
    incident_fixture("stale-guid", "Stale outage", "Unknown", stale)

    assert {:ok, _state} =
             OpenAIStatus.upsert_feed_state(%{
               last_success_at: stale,
               last_attempt_at: now,
               last_error_at: now,
               last_error_code: "network_error",
               active_count: 1,
               aggregate_revision: 1,
               updated_at: now
             })

    {:ok, view, html} = live(conn, ~p"/admin/incidents")

    assert has_element?(view, "#admin-incidents-stale")
    refute has_element?(view, "#admin-incidents-stale", "was .")
    assert has_element?(view, "#admin-incidents-feed-error")
    assert has_element?(view, "#admin-incidents-feed-state[data-state='error']")
    assert has_element?(view, "#admin-incidents-active-desktop", "Stale outage")
    refute html =~ "<rss"
    refute html =~ "<item"
    refute html =~ "network_error"
  end

  test "shows a complete stale message when no successful fetch exists", %{conn: conn} do
    now = DateTime.utc_now()

    assert {:ok, _state} =
             OpenAIStatus.upsert_feed_state(%{
               last_success_at: nil,
               last_attempt_at: now,
               active_count: 0,
               aggregate_revision: 1,
               updated_at: now
             })

    {:ok, view, html} = live(conn, ~p"/admin/incidents")

    assert has_element?(
             view,
             "#admin-incidents-stale",
             "No successful refresh has been recorded yet"
           )

    refute html =~ "last successful fetch was ."
  end

  test "caps visible history and reports overflow", %{conn: conn} do
    now = DateTime.utc_now()

    for index <- 1..51 do
      incident_fixture(
        "history-#{index}",
        "History #{index}",
        "Resolved",
        DateTime.add(now, -index, :second)
      )
    end

    OpenAIStatus.upsert_feed_state(%{
      last_success_at: now,
      active_count: 0,
      aggregate_revision: 1,
      updated_at: now
    })

    {:ok, view, _html} = live(conn, ~p"/admin/incidents")

    assert has_element?(view, "#admin-incidents-history-overflow", "+1 more")

    assert 50 ==
             render(view)
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#admin-incidents-history-desktop tbody tr")
             |> Enum.count()
  end

  test "refreshes the page projection after a newer status event", %{conn: conn} do
    now = DateTime.utc_now()

    OpenAIStatus.upsert_feed_state(%{
      last_success_at: now,
      active_count: 0,
      aggregate_revision: 1,
      updated_at: now
    })

    {:ok, view, _html} = live(conn, ~p"/admin/incidents")
    refute has_element?(view, "[data-role='openai-incident-row']")

    incident_fixture("event-guid", "Event outage", "Investigating", now)

    assert :ok =
             Events.broadcast(%{
               event_version: 1,
               changed_count: 1,
               active_count: 1,
               aggregate_revision: 2,
               emitted_at: now
             })

    event = %{
      event_version: 1,
      changed_count: 1,
      active_count: 1,
      aggregate_revision: 2,
      emitted_at: now
    }

    assert {:ok, decoded_event} = Events.decode(event)
    send(view.pid, {:openai_status_updated, decoded_event})
    _ = render(view)
    assert has_element?(view, "[data-role='openai-incident-row']", "Event outage")
  end

  defp incident_fixture(guid, title, status, timestamp) do
    {:ok, incident} =
      OpenAIStatus.upsert_incident(
        %{
          guid: guid,
          title: title,
          status: status,
          summary: "safe incident summary",
          component: "Responses API",
          link: "https://status.openai.com/incidents/#{guid}",
          published_at: timestamp,
          content_hash: "hash-#{guid}"
        },
        timestamp
      )

    incident
  end
end
