defmodule CodexPoolerWeb.Admin.PageTitlesTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Pools

  setup :register_and_log_in_user

  test "admin index pages use section titles with product suffix", %{conn: conn} do
    pages = [
      {"Pools", ~p"/admin/pools"},
      {"Upstreams", ~p"/admin/upstreams"},
      {"Request logs", ~p"/admin/request-logs"},
      {"Stats", ~p"/admin/stats"},
      {"API keys", ~p"/admin/api-keys"},
      {"Jobs", ~p"/admin/jobs"},
      {"Audit logs", ~p"/admin/audit-logs"},
      {"Invites", ~p"/admin/invites"},
      {"Operators", ~p"/admin/operators"},
      {"Settings", ~p"/admin/settings"},
      {"System", ~p"/admin/system"}
    ]

    for {section, path} <- pages do
      html = conn |> get(path) |> html_response(200)

      assert extracted_page_title(html) == "#{section} - Codex Pooler"
      refute html =~ "<title>Admin "
    end
  end

  test "upstream cockpit uses section title with product suffix", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "title-cockpit", name: "Title Cockpit"})
    %{identity: identity} = upstream_assignment_fixture(pool, %{account_label: "Title Account"})

    {:ok, _view, html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert extracted_page_title(html) == "Upstream cockpit - Codex Pooler"
  end

  defp extracted_page_title(html) do
    [_, title] = Regex.run(~r/<title[^>]*>(.*?)<\/title>/s, html)

    title
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
