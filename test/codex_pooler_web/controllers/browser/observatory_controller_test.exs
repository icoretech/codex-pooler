defmodule CodexPoolerWeb.Browser.ObservatoryControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Accounts
  alias CodexPooler.ObservatorySecrecy
  alias CodexPooler.Repo

  @login_path "/observatory/login"
  @cookie_name "_codex_pooler_observatory_token"
  @cookie_max_age 14 * 24 * 60 * 60
  @invalid_copy "The API key is invalid or unavailable."

  test "GET /observatory/login renders a non-echoing API-key password-style form", %{
    conn: conn
  } do
    conn = get(conn, @login_path)
    html = response(conn, 200)

    assert html =~ ~s(id="observatory-login-form")
    assert html =~ ~s(id="observatory-api-key")
    assert html =~ ~s(name="observatory[api_key]")
    assert html =~ ~s(type="password")
    assert html =~ ~s(autocomplete="current-password")
  end

  test "successful login renews the operator-independent session and sets only the dedicated token cookie",
       %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = post_login(conn, %{"api_key" => raw_key})

    assert redirected_to(conn) == "/observatory"
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

  test "all dashboard credential failures use one generic response branch" do
    expired_at = DateTime.add(DateTime.utc_now(), -60, :second)

    expired = api_key_fixture(pool_fixture(), %{expires_at: expired_at})
    enable_dashboard_access!(expired.api_key)

    %{api_key: paused_api_key, raw_key: paused_key} = paused_api_key_fixture()
    enable_dashboard_access!(paused_api_key)

    %{api_key: revoked_api_key, raw_key: revoked_key} =
      api_key_fixture(pool_fixture(), %{status: "revoked"})

    enable_dashboard_access!(revoked_api_key)

    %{api_key: no_access_api_key, raw_key: no_access_key} = active_api_key_fixture()
    _ = no_access_api_key

    disabled_pool = pool_fixture()

    %{api_key: disabled_pool_api_key, raw_key: disabled_pool_key} =
      api_key_fixture(disabled_pool)

    enable_dashboard_access!(disabled_pool_api_key)
    disabled_pool |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()

    cases = [
      {:missing, %{}},
      {:malformed, %{"api_key" => "malformed-observatory-credential"}},
      {:expired, %{"api_key" => expired.raw_key}},
      {:paused, %{"api_key" => paused_key}},
      {:revoked, %{"api_key" => revoked_key}},
      {:no_dashboard_access, %{"api_key" => no_access_key}},
      {:disabled_pool, %{"api_key" => disabled_pool_key}}
    ]

    results =
      Enum.map(cases, fn {_label, body} ->
        conn = post_login(build_conn(), body)

        {
          conn.status,
          response(conn, conn.status) =~ @invalid_copy,
          Phoenix.Flash.get(conn.assigns.flash, :error)
        }
      end)

    assert Enum.uniq(results) == [{422, true, nil}]
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  test "login rejects a missing CSRF token before exchanging credentials", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> Map.update!(:private, &Map.delete(&1, :plug_skip_csrf_protection))
      |> post(@login_path, %{"observatory" => %{"api_key" => raw_key}})
    end

    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  test "a raw API key in query params never authenticates", %{conn: conn} do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn = get(conn, @login_path)
    csrf_token = csrf_token_from(conn.resp_body)

    conn =
      post(conn, @login_path <> "?api_key=" <> URI.encode_www_form(raw_key), %{
        "_csrf_token" => csrf_token
      })

    assert conn.status == 422
    assert response(conn, 422) =~ @invalid_copy
    credential_secrecy? = ObservatorySecrecy.safe_observable?(response(conn, 422), [raw_key])
    assert credential_secrecy?
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
  end

  test "invalid submissions never appear in the response, flash, or request log", %{conn: conn} do
    submitted_value = "synthetic-observatory-secret-value"

    {conn, logs} =
      with_log(fn -> post_login(conn, %{"api_key" => submitted_value}) end)

    assert conn.status == 422

    credential_secrecy? =
      ObservatorySecrecy.safe_observable?(
        [
          response(conn, 422),
          inspect(Phoenix.Flash.get(conn.assigns.flash, :error)),
          conn.query_string,
          logs
        ],
        [submitted_value]
      )

    assert credential_secrecy?
  end

  test "operator browser state is irrelevant to the Observatory exchange", %{conn: conn} do
    %{user: user, token: operator_token} = bootstrap_owner_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()
    enable_dashboard_access!(api_key)

    conn =
      conn
      |> log_in_user(user, operator_token)
      |> get(@login_path)

    assert conn.status == 200
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

  defp with_log(fun) do
    parent = self()

    logs =
      capture_log(fn ->
        send(parent, {:observatory_result, fun.()})
      end)

    assert_receive {:observatory_result, conn}
    {conn, logs}
  end
end
