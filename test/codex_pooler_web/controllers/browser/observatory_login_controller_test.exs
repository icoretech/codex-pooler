defmodule CodexPoolerWeb.Browser.ObservatoryLoginControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.ObservatoryControllerTestHelpers

  alias CodexPooler.Access.APIKeyDashboardSession
  alias CodexPooler.Accounts
  alias CodexPooler.Repo

  @login_path "/observatory/login"
  @cookie_name "_codex_pooler_observatory_token"
  @cookie_max_age 14 * 24 * 60 * 60
  @invalid_copy "The API key is invalid or unavailable."

  test "GET /observatory/login renders the dedicated access form without echoing query input", %{
    conn: conn
  } do
    marker = "sentinel-not-rendered"

    conn = get(conn, @login_path <> "?api_key=" <> marker)
    html = html_response(conn, 200)

    assert html =~ ~s(id="observatory-login")
    assert html =~ ~s(id="observatory-login-form")
    assert html =~ ~s(action="/observatory/login")
    assert html =~ ~s(method="post")
    assert html =~ ~s(id="observatory-api-key")
    assert html =~ ~s(name="observatory[api_key]")
    assert html =~ ~s(type="password")
    assert html =~ ~s(autocomplete="current-password")
    assert html =~ ~s(id="observatory-login-submit")
    assert html =~ ~s(name="_csrf_token")
    refute html =~ marker
    refute Map.has_key?(conn.assigns, :current_scope)
  end

  test "observatory login is a dedicated GET route and dashboard routes remain absent" do
    routes =
      CodexPoolerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path, &1.plug, &1.plug_opts})

    assert {:get, @login_path, CodexPoolerWeb.Observatory.LoginController, :new} in routes

    refute Enum.any?(routes, fn {_verb, path, _plug, _opts} ->
             String.starts_with?(path, "/dashboard/")
           end)

    assert {:post, @login_path, CodexPoolerWeb.Observatory.LoginController, :create} in routes

    assert {:delete, "/observatory/logout", CodexPoolerWeb.Observatory.LoginController, :delete} in routes

    refute Enum.any?(routes, fn {verb, path, _plug, _opts} ->
             verb == :get and path == "/observatory/logout"
           end)
  end

  test "successful login exchanges a real API key and renews the browser session", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = post_login(conn, @endpoint, %{"observatory" => %{"api_key" => raw_key}})

    assert redirected_to(conn) == "/observatory"
    assert conn.private[:plug_session_info] == :renew
    assert conn.params == %{}
    assert get_session(conn, :user_token) == nil
    assert get_session(conn, :live_socket_id) == nil
    refute Map.has_key?(conn.assigns, :current_scope)

    cookie = get_resp_cookies(conn)[@cookie_name]
    assert cookie[:http_only]
    assert cookie[:same_site] == "Lax"
    assert cookie[:max_age] == @cookie_max_age
    assert cookie[:path] == "/"
    assert Map.get(cookie, :secure, false) == (conn.scheme == :https)

    session = Repo.get_by!(APIKeyDashboardSession, api_key_id: api_key.id)
    assert :crypto.hash(:sha256, cookie[:value]) == session.token_hash
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 1
  end

  test "HTTPS login marks the credential cookie Secure", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    https_conn = get(conn, "https://observatory.example.invalid#{@login_path}")

    https_conn =
      post(https_conn, "https://observatory.example.invalid#{@login_path}", %{
        "observatory" => %{"api_key" => raw_key},
        "_csrf_token" => csrf_token_from(https_conn.resp_body)
      })

    assert redirected_to(https_conn) == "/observatory"
    assert get_resp_cookies(https_conn)[@cookie_name][:secure] == true
  end

  test "invalid submissions never appear in response, flash, query, or logs", %{conn: conn} do
    marker = "synthetic-observatory-secret-value"

    {conn, logs} =
      capture_log_and_result(fn ->
        post_login(conn, @endpoint, %{"observatory" => %{"api_key" => marker}})
      end)

    assert conn.status == 422
    refute response(conn, 422) =~ marker
    refute inspect(flash_error(conn)) =~ marker
    refute conn.query_string =~ marker
    refute logs =~ marker
  end

  test "a raw API key in the query string cannot authenticate", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = get(conn, @login_path)

    conn =
      post(conn, @login_path <> "?api_key=" <> URI.encode_www_form(raw_key), %{
        "_csrf_token" => csrf_token_from(conn.resp_body)
      })

    assert conn.status == 422
    assert response(conn, 422) =~ @invalid_copy
    refute response(conn, 422) =~ raw_key
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  test "a nested query credential cannot authenticate through merged action params", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = get(conn, @login_path)
    csrf_token = csrf_token_from(conn.resp_body)

    {conn, logs} =
      capture_log_and_result(fn ->
        post(
          conn,
          @login_path <> "?observatory%5Bapi_key%5D=" <> URI.encode_www_form(raw_key),
          %{"_csrf_token" => csrf_token}
        )
      end)

    body = response(conn, 422)
    assert body =~ @invalid_copy
    assert String.contains?(body, raw_key) == false
    assert String.contains?(inspect(flash_error(conn)), raw_key) == false
    assert String.contains?(logs, raw_key) == false
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  test "login rejects a missing CSRF token before exchanging credentials", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, @login_path, %{"observatory" => %{"api_key" => raw_key}})
    end

    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  test "operator browser state is irrelevant to the Observatory exchange", %{conn: conn} do
    %{user: user, token: operator_token} = bootstrap_owner_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn =
      conn
      |> log_in_user(user, operator_token)
      |> get(@login_path)

    refute Map.has_key?(conn.assigns, :current_scope)

    conn =
      post(conn, @login_path, %{
        "observatory" => %{"api_key" => raw_key},
        "_csrf_token" => csrf_token_from(conn.resp_body)
      })

    assert redirected_to(conn) == "/observatory"
    assert get_session(conn, :user_token) == nil
    assert get_session(conn, :live_socket_id) == nil
    assert Accounts.get_user_by_session_token(operator_token)
  end
end
