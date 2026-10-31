defmodule CodexPoolerWeb.LocaleFlowTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Locale
  alias Phoenix.LiveView.Static

  test "root HTML and response language follow a cookie, browser detection, and the English fallback", %{conn: conn} do
    bootstrap_owner_fixture()

    for {request, tag} <- [
          {conn, "en"},
          {put_locale(conn, "zh-CN"), "zh-CN"},
          {put_req_header(conn, "accept-language", "zh-Hans"), "zh-CN"},
          {put_req_header(conn, "accept-language", "zh-TW, zh-Hant;q=0.9"), "en"}
        ] do
      response = get(request, ~p"/login")
      document = response |> html_response(200) |> LazyHTML.from_document()
      assert document |> LazyHTML.query("html") |> LazyHTML.attribute("lang") == [tag]
      assert document |> LazyHTML.query("html") |> LazyHTML.attribute("dir") == ["ltr"]
      assert get_resp_header(response, "content-language") == [tag]
      assert get_resp_header(response, "vary") == ["accept-language"]
      assert get_session(response, :locale) == nil
      assert get_session(response, :locale_preference) == nil
    end
  end

  test "a signed-out chooser performs a full POST and remounts with the signed locale", %{conn: conn} do
    bootstrap_owner_fixture()
    {:ok, view, html} = live(conn, ~p"/login")

    assert view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("form[action='/locale']") |> Enum.count() == 1
    assert has_element?(view, "#auth-footer #auth-footer-language-switcher-form[action='/locale'][method='post']")
    assert has_element?(view, "#auth-footer-language-switcher button[name='locale'][value='auto'][aria-current='true']")
    assert html =~ "Browser default"

    response =
      conn
      |> put_req_header("referer", "http://www.example.com/login")
      |> post(~p"/locale", %{"locale" => "zh-CN"})

    assert redirected_to(response) == "/login"
    conn = recycle(response)
    {:ok, translated, _html} = live(conn, ~p"/login")

    assert has_element?(translated, "#auth-footer-language-switcher", "浏览器默认")
    assert has_element?(translated, "#auth-footer-language-switcher button[value='zh-CN'][aria-current='true']")
    assert has_element?(translated, "#auth-footer-language-switcher summary", "简体中文")

    response = get(recycle(response), ~p"/login")
    assert html_response(response, 200) =~ ~s(lang="zh-CN")
    assert signed_live_session(response)["locale"] == "zh-CN"
    assert signed_live_session(response)["locale_preference"] == "zh-CN"
    assert get_session(response, :locale) == nil
  end

  test "the separate Observatory browser pipeline resolves locale before rendering", %{conn: conn} do
    response = conn |> put_locale("zh-CN") |> put_req_header("accept-language", "en") |> get(~p"/observatory/login")
    document = response |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("html") |> LazyHTML.attribute("lang") == ["zh-CN"]
    assert response.assigns.locale.tag == "zh-CN"
    assert response.assigns.locale_preference == "zh-CN"
    assert get_resp_header(response, "content-language") == ["zh-CN"]
    assert get_resp_header(response, "vary") == ["accept-language"]
    assert document |> LazyHTML.query("button[value='zh-CN'][aria-current='true']") |> LazyHTML.text() |> String.trim() == "简体中文"
    assert get_session(response, :locale) == nil
  end

  test "an account chooser persists across requests and the database beats a conflicting browser cookie", %{conn: conn} do
    fixture = bootstrap_owner_fixture()
    conn = log_in_user(conn, fixture.user, fixture.token)
    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=appearance")

    assert has_element?(view, "#admin-language-switcher-form[action='/locale'][method='post']")

    response = post(conn, ~p"/locale", %{"locale" => "zh-CN", "return_to" => "/admin/settings?tab=appearance"})
    assert redirected_to(response) == "/admin/settings?tab=appearance"
    assert Repo.reload!(fixture.user).locale == "zh-CN"
    assert response.resp_cookies[Locale.cookie_name()].value == "zh-CN"

    conn = response |> recycle() |> put_locale("en")
    {:ok, translated, _html} = live(conn, ~p"/admin/settings?tab=appearance")
    assert has_element?(translated, "#admin-language-switcher", "浏览器默认")
    assert has_element?(translated, "#admin-language-switcher button[value='zh-CN'][aria-current='true']")

    response = get(conn, ~p"/admin/settings?tab=appearance")
    assert response.assigns.locale.tag == "zh-CN"
    assert signed_live_session(response)["locale"] == "zh-CN"
    assert signed_live_session(response)["locale_preference"] == "zh-CN"
    assert get_session(response, :locale) == nil
  end

  test "automatic browser detection does not freeze the language in the cookie or session", %{conn: conn} do
    %{user: user} = bootstrap_owner_fixture()
    assert {:ok, _user} = Accounts.update_user_locale(user, nil)

    response = conn |> put_req_header("accept-language", "zh-CN") |> get(~p"/login")
    assert signed_live_session(response) == %{"locale" => "zh-CN"}
    refute Map.has_key?(response.resp_cookies, Locale.cookie_name())
    assert get_session(response, :locale) == nil

    response = response |> recycle() |> put_req_header("accept-language", "en-US") |> get(~p"/login")
    assert response.assigns.locale.tag == "en"
    assert signed_live_session(response) == %{"locale" => "en"}
  end

  defp signed_live_session(conn) do
    [_, token] = Regex.run(~r/data-phx-session="([^"]+)"/, html_response(conn, 200))
    {:ok, payload} = Static.verify_token(CodexPoolerWeb.Endpoint, token)
    Map.take(payload.session, ["locale", "locale_preference"])
  end
end
