defmodule CodexPoolerWeb.Admin.AdminShellOpenAIStatusTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.OpenAIStatus

  setup :register_and_log_in_user

  test "shows one aggregate banner with bounded titles and dismisses it", %{conn: conn} do
    now = DateTime.utc_now()

    for {id, title} <- [
          {"one", "First outage"},
          {"two", "Second outage"},
          {"three", "Third outage"},
          {"four", "Fourth outage"}
        ] do
      {:ok, _} =
        OpenAIStatus.upsert_incident(
          %{
            guid: "banner-#{id}",
            title: title,
            status: "Investigating",
            summary: "safe summary",
            component: "Responses API",
            link: "https://status.openai.com/incidents/banner-#{id}",
            published_at: now,
            content_hash: "hash-#{id}"
          },
          now
        )
    end

    assert {:ok, _} =
             OpenAIStatus.upsert_feed_state(%{
               last_success_at: now,
               active_count: 4,
               aggregate_revision: 1,
               updated_at: now
             })

    {:ok, view, html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#admin-openai-status-banner[role='status'][aria-live='polite']")
    assert has_element?(view, "#admin-openai-status-link[href='/admin/incidents']")
    assert has_element?(view, "#admin-openai-status-dismiss")
    assert html =~ "+1 more"
    assert html =~ "First outage"
    assert html =~ "Second outage"
    assert html =~ "Third outage"
    refute html =~ "Fourth outage"

    view |> element("#admin-openai-status-dismiss") |> render_click()
    refute has_element?(view, "#admin-openai-status-banner")
  end

  test "omits the banner on the incidents page and suppresses it after 24 hours", %{conn: conn} do
    now = DateTime.utc_now()
    old = DateTime.add(now, -86_401, :second)

    {:ok, _} =
      OpenAIStatus.upsert_incident(
        %{
          guid: "old-banner",
          title: "Old outage",
          status: "Investigating",
          summary: "safe summary",
          component: "Responses API",
          link: "https://status.openai.com/incidents/old-banner",
          published_at: old,
          content_hash: "hash-old"
        },
        old
      )

    assert {:ok, _} =
             OpenAIStatus.upsert_feed_state(%{
               last_success_at: old,
               active_count: 1,
               aggregate_revision: 2,
               updated_at: now
             })

    {:ok, pool_view, _html} = live(conn, ~p"/admin/pools")
    refute has_element?(pool_view, "#admin-openai-status-banner")

    {:ok, incidents_view, _html} = live(conn, ~p"/admin/incidents")
    refute has_element?(incidents_view, "#admin-openai-status-banner")
    assert has_element?(incidents_view, "#admin-incidents-page")
  end
end
