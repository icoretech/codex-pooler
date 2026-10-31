defmodule CodexPoolerWeb.Admin.AdminShellOpenAIStatusTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.OpenAIStatus

  setup :register_and_log_in_user

  test "Chinese incident banner binds the automatic plural count even for the singular source", %{conn: conn} do
    now = DateTime.utc_now()

    assert {:ok, _incident} =
             OpenAIStatus.upsert_incident(%{guid: "zh-banner", title: "Provider incident", status: "Investigating", summary: "bounded", component: nil, link: "https://status.openai.com/incidents/zh-banner", published_at: now, content_hash: "zh-banner-hash"}, now)

    assert {:ok, _feed} = OpenAIStatus.upsert_feed_state(%{last_success_at: now, active_count: 1, aggregate_revision: 1})

    {:ok, view, _html} = live(put_locale(conn, "zh-CN"), ~p"/admin/settings")

    assert has_element?(view, "#admin-openai-status-banner", "OpenAI 正在报告 1 起事件")
    assert has_element?(view, "#admin-openai-status-link[aria-label='查看 OpenAI 事件']", "查看")
  end

  test "dismissal conflict reloads current revisions and explains why the banner remains", %{
    conn: conn
  } do
    now = DateTime.utc_now()

    attrs = %{
      guid: "conflict",
      title: "Service recovering",
      status: "Investigating",
      summary: "bounded",
      component: nil,
      link: "https://status.openai.com/incidents/conflict",
      published_at: now,
      content_hash: "first"
    }

    assert {:ok, _} = OpenAIStatus.upsert_incident(attrs, now)

    assert {:ok, _} =
             OpenAIStatus.upsert_feed_state(%{last_success_at: now, aggregate_revision: 1})

    {:ok, view, _} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#admin-openai-status-banner", "OpenAI is reporting an incident")

    assert {:ok, _} =
             OpenAIStatus.upsert_incident(
               %{attrs | title: "Service monitoring", content_hash: "second"},
               DateTime.add(now, 1, :second)
             )

    view |> element("#admin-openai-status-dismiss") |> render_click()
    assert has_element?(view, "#admin-openai-status-banner", "Service monitoring")

    assert has_element?(
             view,
             "#flash-error",
             "Incidents changed. Review the latest updates before dismissing."
           )

    view |> element("#admin-openai-status-dismiss") |> render_click()
    refute has_element?(view, "#admin-openai-status-banner")
  end

  test "shows one aggregate banner with bounded titles and dismisses it", %{conn: conn} do
    now = DateTime.utc_now()

    for {{id, title}, index} <-
          Enum.with_index([
            {"one", "First outage"},
            {"two", "Second outage"},
            {"three", "Third outage"},
            {"four", "Fourth outage"}
          ]) do
      {:ok, _} =
        OpenAIStatus.upsert_incident(
          %{
            guid: "banner-#{id}",
            title: title,
            status: "Investigating",
            summary: "safe summary",
            component: "Responses API",
            link: "https://status.openai.com/incidents/banner-#{id}",
            published_at: DateTime.add(now, -index, :second),
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
    assert has_element?(view, "#admin-openai-status-banner", "OpenAI is reporting 4 incidents")
    assert has_element?(view, "#admin-openai-status-banner", "First outage")
    assert has_element?(view, "#admin-openai-status-banner", "Second outage")
    assert has_element?(view, "#admin-openai-status-banner", "+2 more")
    assert has_element?(view, "#admin-openai-status-banner div[title='First outage · Second outage · Third outage']")
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
