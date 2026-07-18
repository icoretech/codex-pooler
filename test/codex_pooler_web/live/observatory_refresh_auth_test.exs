defmodule CodexPoolerWeb.ObservatoryRefreshAuthTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Repo
  alias CodexPoolerWeb.ObservatoryControllerTestHelpers

  @login_path "/observatory/login"
  @observatory_path "/observatory"

  for reason <- ~w(manual periodic reconnect) do
    test "#{reason} refresh fails closed against canonical session state", %{conn: conn} do
      %{view: view, api_key: api_key} = authenticated_view(conn)
      disable_dashboard_access_without_event(api_key)

      render_hook(view, "observatory-refresh", %{"reason" => unquote(reason)})

      assert_redirect(view, @login_path)
    end
  end

  test "window refresh fails closed against canonical session state", %{conn: conn} do
    %{view: view, api_key: api_key} = authenticated_view(conn)
    disable_dashboard_access_without_event(api_key)

    render_click(view, "select-window", %{"window" => "1h"})

    assert_redirect(view, @login_path)
  end

  test "resume refresh fails closed against canonical session state", %{conn: conn} do
    %{view: view, api_key: api_key} = authenticated_view(conn)
    render_click(view, "pause-refresh")
    disable_dashboard_access_without_event(api_key)

    render_click(view, "resume-refresh")

    assert_redirect(view, @login_path)
  end

  test "key session invalidation redirects an open Observatory", %{conn: conn} do
    %{view: view, api_key: api_key} = authenticated_view(conn)

    assert :ok = Access.delete_all_dashboard_sessions(api_key)

    assert_redirect(view, @login_path)
  end

  defp authenticated_view(conn) do
    pool = pool_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    api_key = ObservatoryControllerTestHelpers.enable_dashboard_access!(api_key)

    conn =
      ObservatoryControllerTestHelpers.post_login(conn, CodexPoolerWeb.Endpoint, %{
        "observatory" => %{"api_key" => raw_key}
      })

    {:ok, view, _html} = live(conn, @observatory_path)
    render_async(view)
    %{api_key: api_key, view: view}
  end

  defp disable_dashboard_access_without_event(api_key) do
    api_key
    |> APIKey.changeset(%{dashboard_access: false})
    |> Repo.update!()
  end
end
