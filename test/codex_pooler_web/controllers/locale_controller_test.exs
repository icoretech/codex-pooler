defmodule CodexPoolerWeb.LocaleControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Repo
  alias CodexPoolerWeb.{Locale, LocaleController}

  test "signed-out choices set the preference cookie and flash in the newly selected language", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "zh_CN", "return_to" => "/login"})

    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "语言已更新"
    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == "zh-CN"
    assert get_resp_header(conn, "content-language") == ["zh-CN"]
    assert %{value: "zh-CN", path: "/", http_only: true, same_site: "Lax", max_age: 31_536_000, secure: false} = conn.resp_cookies[Locale.cookie_name()]
    assert get_session(conn, :locale) == nil
    assert get_session(conn, :locale_preference) == nil
  end

  test "HTTPS choices and deletion carry the complete secure cookie policy", %{conn: conn} do
    selected = post(conn, "https://www.example.com/locale", %{"locale" => "zh-CN"})

    assert %{value: "zh-CN", path: "/", http_only: true, same_site: "Lax", secure: true, max_age: 31_536_000} = selected.resp_cookies[Locale.cookie_name()]

    cleared = selected |> recycle() |> post("https://www.example.com/locale", %{"locale" => "auto"})
    assert %{path: "/", http_only: true, same_site: "Lax", secure: true, max_age: 0} = cleared.resp_cookies[Locale.cookie_name()]
  end

  test "signed-in choices persist only to the trusted current account and cookie", %{conn: conn} do
    %{user: user, token: token} = bootstrap_owner_fixture()
    %{user: other_user} = operator_fixture(user)

    conn =
      conn
      |> log_in_user(user, token)
      |> post(~p"/locale", %{"locale" => "zh-CN", "user_id" => other_user.id, "return_to" => "/admin/settings?tab=appearance"})

    assert redirected_to(conn) == "/admin/settings?tab=appearance"
    assert Repo.reload!(user).locale == "zh-CN"
    assert Repo.reload!(other_user).locale == nil
    assert conn.resp_cookies[Locale.cookie_name()].value == "zh-CN"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "语言已更新"
  end

  test "auto clears the account and cookie then resolves from the current browser header", %{conn: conn} do
    fixture = bootstrap_owner_fixture()

    conn =
      conn
      |> put_locale("zh-CN")
      |> sign_in_with_locale(fixture, "zh-CN")
      |> put_req_header("accept-language", "en-US")
      |> post(~p"/locale", %{"locale" => "auto"})

    assert Repo.reload!(fixture.user).locale == nil
    assert conn.resp_cookies[Locale.cookie_name()].max_age == 0
    assert conn.assigns.locale.tag == "en"
    assert conn.assigns.locale_preference == nil
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Language updated"

    conn = conn |> recycle() |> put_req_header("accept-language", "zh-Hans") |> post(~p"/locale", %{"locale" => "auto"})
    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == nil
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "语言已更新"
  end

  test "signed-out auto removes only the explicit preference and uses browser negotiation", %{conn: conn} do
    conn =
      conn
      |> put_locale("en")
      |> put_req_header("accept-language", "zh-CN")
      |> post(~p"/locale", %{"locale" => "auto"})

    assert conn.resp_cookies[Locale.cookie_name()].max_age == 0
    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == nil
  end

  test "invalid values leave database and cookie unchanged", %{conn: conn} do
    fixture = bootstrap_owner_fixture()
    conn = conn |> put_locale("en") |> sign_in_with_locale(fixture, "en")

    for locale <- ["unsupported", "zh-TW", "", nil, ["zh-CN"], %{"tag" => "zh-CN"}] do
      response = post(conn, ~p"/locale", %{"locale" => locale})
      assert Repo.reload!(fixture.user).locale == "en"
      refute Map.has_key?(response.resp_cookies, Locale.cookie_name())
      assert Phoenix.Flash.get(response.assigns.flash, :error) == "Unsupported language."
    end
  end

  test "a failed database write does not overwrite the browser cookie and flashes in the current language", %{conn: conn} do
    %{user: user} = bootstrap_owner_fixture()
    stale = %{user | id: Ecto.UUID.generate()}

    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> put_locale("zh-CN")
      |> fetch_cookies()
      |> assign(:current_scope, %Scope{user: stale})
      |> CodexPoolerWeb.Plugs.Locale.call([])
      |> LocaleController.create(%{"locale" => "en"})

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "无法更新语言。请重试。"
    assert conn.assigns.locale.tag == "zh-CN"
    refute Map.has_key?(conn.resp_cookies, Locale.cookie_name())
    assert conn.req_cookies[Locale.cookie_name()] == "zh-CN"
    assert Repo.reload!(user).locale == nil
  end

  test "unsafe return_to values cannot become redirects", %{conn: conn} do
    for return_to <- ["https://example.com/evil", "//example.com", "/\\example.com", "/%09/example.com", "/%0A/example.com", "/%0d/example.com", "/%5Cexample.com", "/%2Fexample.com", "/%2509/example.com"] do
      response = post(conn, ~p"/locale", %{"locale" => "en", "return_to" => return_to})
      assert redirected_to(response) == "/"
    end
  end

  test "a validated same-origin Referer path is the fallback and preserves its query", %{conn: conn} do
    conn =
      conn
      |> put_req_header("referer", "http://www.example.com/admin/settings?tab=appearance#language")
      |> post(~p"/locale", %{"locale" => "en"})

    assert redirected_to(conn) == "/admin/settings?tab=appearance"

    conn = conn |> recycle() |> put_req_header("referer", "https://example.com/evil") |> post(~p"/locale", %{"locale" => "en"})
    assert redirected_to(conn) == "/"
  end

  test "the locale POST uses the browser CSRF protection", %{conn: conn} do
    conn = %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, ~p"/locale", %{"locale" => "zh-CN"})
    end
  end

  test "login mirrors a non-null account preference and logout retains it", %{conn: conn} do
    %{user: user} = bootstrap_owner_fixture()
    {:ok, user} = Accounts.update_user_locale(user, "zh-CN")

    conn =
      conn
      |> put_locale("en")
      |> post(~p"/login", %{"user" => %{"email" => user.email, "password" => valid_user_password()}})

    assert conn.resp_cookies[Locale.cookie_name()].value == "zh-CN"
    assert conn.resp_cookies[Locale.cookie_name()].http_only
    assert conn.resp_cookies[Locale.cookie_name()].same_site == "Lax"

    conn = conn |> recycle() |> delete(~p"/logout") |> recycle() |> get(~p"/login")
    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == "zh-CN"
  end

  test "login without an account preference leaves the signed-out language choice in place", %{conn: conn} do
    %{user: user} = bootstrap_owner_fixture()

    conn =
      conn
      |> put_locale("zh-CN")
      |> post(~p"/login", %{"user" => %{"email" => user.email, "password" => valid_user_password()}})

    refute Map.has_key?(conn.resp_cookies, Locale.cookie_name())
    conn = conn |> recycle() |> get(~p"/admin/settings")
    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == "zh-CN"
  end
end
