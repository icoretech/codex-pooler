defmodule CodexPoolerWeb.Browser.ObservatoryLogoutControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.ObservatoryControllerTestHelpers

  alias CodexPooler.Access.APIKeyDashboardSession
  alias CodexPooler.Accounts
  alias CodexPooler.Repo

  @login_path "/observatory/login"
  @logout_path "/observatory/logout"
  @cookie_name "_codex_pooler_observatory_token"

  test "logout deletes the dashboard session, clears its cookie, and renews browser state", %{
    conn: conn
  } do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = post_login(conn, @endpoint, %{"observatory" => %{"api_key" => raw_key}})
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 1

    conn = conn |> recycle() |> logout(@endpoint)

    assert redirected_to(conn) == @login_path
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    assert conn.private[:plug_session_info] == :renew
    assert get_session(conn, :user_token) == nil
    assert get_session(conn, :live_socket_id) == nil
    assert get_resp_cookies(conn)[@cookie_name][:max_age] == 0
    assert_cleared_observatory_cookie!(conn)
  end

  test "logout rejects missing and invalid CSRF before deleting the dashboard session" do
    for csrf_params <- [%{}, %{"_csrf_token" => "synthetic-invalid-csrf"}] do
      %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
      enable_dashboard_access!(api_key)

      conn = post_login(build_conn(), @endpoint, %{"observatory" => %{"api_key" => raw_key}})
      assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 1

      conn = conn |> recycle() |> get(@login_path) |> recycle()

      conn = %{
        conn
        | private:
            conn.private
            |> Map.delete(:plug_skip_csrf_protection)
            |> Map.put(:phoenix_recycled, true)
      }

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        delete(conn, @logout_path, csrf_params)
      end

      assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 1
      Repo.delete_all(APIKeyDashboardSession)
    end
  end

  test "logout is generic and idempotent for missing, malformed, expired, and deleted cookies" do
    missing = logout(build_conn(), @endpoint)

    forged_marker = "forged-observatory-cookie"

    {forged, logs} =
      capture_log_and_result(fn ->
        build_conn()
        |> put_req_header("cookie", @cookie_name <> "=" <> forged_marker)
        |> logout(@endpoint)
      end)

    assert redirected_to(missing) == @login_path
    assert redirected_to(forged) == @login_path
    refute logs =~ forged_marker
    refute response(forged, 302) =~ forged_marker
    assert_cleared_observatory_cookie!(missing)
    assert_cleared_observatory_cookie!(forged)

    %{api_key: expired_api_key, raw_key: expired_raw_key} = active_api_key_fixture()
    enable_dashboard_access!(expired_api_key)

    expired_conn =
      post_login(build_conn(), @endpoint, %{"observatory" => %{"api_key" => expired_raw_key}})

    Repo.get_by!(APIKeyDashboardSession, api_key_id: expired_api_key.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    expired = expired_conn |> recycle() |> logout(@endpoint)
    assert redirected_to(expired) == @login_path
    assert_cleared_observatory_cookie!(expired)
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0

    %{api_key: deleted_api_key, raw_key: deleted_raw_key} = active_api_key_fixture()
    enable_dashboard_access!(deleted_api_key)

    deleted_conn =
      post_login(build_conn(), @endpoint, %{"observatory" => %{"api_key" => deleted_raw_key}})

    deleted_cookie = get_resp_cookies(deleted_conn)[@cookie_name]
    assert :ok = CodexPooler.Access.delete_dashboard_session(deleted_cookie[:value])

    already_deleted = deleted_conn |> recycle() |> logout(@endpoint)
    assert redirected_to(already_deleted) == @login_path
    assert_cleared_observatory_cookie!(already_deleted)
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  test "logout does not use or delete operator session state", %{conn: conn} do
    %{user: user, token: operator_token} = bootstrap_owner_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn =
      conn
      |> log_in_user(user, operator_token)
      |> post_login(@endpoint, %{"observatory" => %{"api_key" => raw_key}})
      |> recycle()
      |> logout(@endpoint)

    assert redirected_to(conn) == @login_path
    assert Accounts.get_user_by_session_token(operator_token)
    assert get_session(conn, :user_token) == nil
    assert get_session(conn, :live_socket_id) == nil
  end
end
