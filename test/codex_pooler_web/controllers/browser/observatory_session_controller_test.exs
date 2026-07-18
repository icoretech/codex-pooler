defmodule CodexPoolerWeb.Browser.ObservatorySessionControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Repo

  @login_path "/observatory/login"
  @logout_path "/observatory/logout"
  @cookie_name "_codex_pooler_observatory_token"

  test "GET /observatory/login does not renew an existing dashboard session", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    assert {:ok, %{token: token}} = Access.issue_dashboard_session(raw_key)
    before = Repo.get_by!(APIKeyDashboardSession, api_key_id: api_key.id).expires_at

    conn =
      conn
      |> Plug.Conn.put_req_header("cookie", @cookie_name <> "=" <> token)
      |> get(@login_path)

    assert conn.status == 200
    assert Repo.get_by!(APIKeyDashboardSession, api_key_id: api_key.id).expires_at == before
  end

  test "logout deletes the dashboard session, clears only its cookie, and is idempotent", %{
    conn: conn
  } do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = post_login(conn, %{"api_key" => raw_key})
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 1

    conn = get(conn |> recycle(), @login_path)
    conn = delete(conn, @logout_path, %{"_csrf_token" => csrf_token_from(conn.resp_body)})

    assert redirected_to(conn) == @login_path
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    assert get_session(conn, :user_token) == nil
    assert get_session(conn, :live_socket_id) == nil
    assert deleted_cookie_names(conn) == [@cookie_name]

    conn = get(conn |> recycle(), @login_path)
    conn = delete(conn, @logout_path, %{"_csrf_token" => csrf_token_from(conn.resp_body)})

    assert redirected_to(conn) == @login_path
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    assert deleted_cookie_names(conn) == [@cookie_name]
  end

  test "logout remains generic for forged, persisted stale, and missing dedicated cookies", %{
    conn: conn
  } do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)
    assert {:ok, %{token: stale_token}} = Access.issue_dashboard_session(raw_key)
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 1
    assert :ok = Access.delete_dashboard_session(stale_token)

    stale =
      build_conn()
      |> Plug.Conn.put_req_header("cookie", @cookie_name <> "=" <> stale_token)
      |> get(@login_path)

    stale = delete(stale, @logout_path, %{"_csrf_token" => csrf_token_from(stale.resp_body)})
    assert redirected_to(stale) == @login_path

    forged =
      conn
      |> Plug.Conn.put_req_header("cookie", @cookie_name <> "=forged-observatory-cookie")
      |> get(@login_path)

    forged = delete(forged, @logout_path, %{"_csrf_token" => csrf_token_from(forged.resp_body)})
    assert redirected_to(forged) == @login_path
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0

    missing = get(build_conn(), @login_path)

    missing =
      delete(missing, @logout_path, %{"_csrf_token" => csrf_token_from(missing.resp_body)})

    assert redirected_to(missing) == @login_path
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  defp post_login(conn, body) do
    conn = get(conn, @login_path)

    post(conn, @login_path, %{
      "observatory" => body,
      "_csrf_token" => csrf_token_from(conn.resp_body)
    })
  end

  defp csrf_token_from(html) do
    [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, html)
    token
  end

  defp enable_dashboard_access!(%APIKey{} = api_key) do
    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp deleted_cookie_names(conn) do
    conn
    |> get_resp_cookies()
    |> Enum.filter(fn {_name, cookie} -> cookie[:max_age] == 0 end)
    |> Enum.map(&elem(&1, 0))
  end
end
