defmodule CodexPoolerWeb.Plugs.LocaleTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPoolerWeb.Locale
  alias CodexPoolerWeb.Plugs.Locale, as: LocalePlug

  test "the default assigns English and leaves the browser session and cookies alone", %{conn: conn} do
    conn = conn |> init_test_session(%{"existing" => "value"}) |> fetch_cookies() |> LocalePlug.call([])

    assert conn.assigns.locale == Locale.default()
    assert conn.assigns.locale_preference == nil
    assert get_resp_header(conn, "content-language") == ["en"]
    assert get_resp_header(conn, "vary") == ["accept-language"]
    assert get_session(conn) == %{"existing" => "value"}
    assert conn.resp_cookies == %{}
    assert Gettext.get_locale() == "en"
  end

  test "a signed-out cookie is the explicit choice and beats the browser header", %{conn: conn} do
    conn =
      conn
      |> put_locale("zh_CN")
      |> put_req_header("accept-language", "en-US")
      |> init_test_session(%{})
      |> fetch_cookies()
      |> LocalePlug.call([])

    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == "zh-CN"
    assert get_resp_header(conn, "content-language") == ["zh-CN"]
    assert Gettext.get_locale() == "zh_CN"
    assert get_session(conn) == %{}
    assert conn.resp_cookies == %{}
  end

  test "signed-out browser negotiation is not converted to an explicit preference", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "fr;q=1, zh-Hans;q=0.9, en;q=0.1")
      |> init_test_session(%{})
      |> fetch_cookies()
      |> LocalePlug.call([])

    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == nil
    assert get_session(conn) == %{}
    assert conn.resp_cookies == %{}
  end

  test "a signed-in database preference wins over a conflicting cookie", %{conn: conn} do
    conn =
      conn
      |> put_locale("en")
      |> init_test_session(%{})
      |> fetch_cookies()
      |> assign(:current_scope, %Scope{user: %User{locale: "zh-CN"}})
      |> LocalePlug.call([])

    assert conn.assigns.locale.tag == "zh-CN"
    assert conn.assigns.locale_preference == "zh-CN"
  end

  test "an unset or unsupported account preference falls back to the explicit cookie", %{conn: conn} do
    for preference <- [nil, "unsupported"] do
      resolved =
        conn
        |> put_locale("zh-CN")
        |> init_test_session(%{})
        |> fetch_cookies()
        |> assign(:current_scope, %Scope{user: %User{locale: preference}})
        |> LocalePlug.call([])

      assert resolved.assigns.locale.tag == "zh-CN"
      assert resolved.assigns.locale_preference == "zh-CN"
    end
  end

  test "invalid cookies are ignored and Traditional Chinese never matches Simplified Chinese", %{conn: conn} do
    conn =
      conn
      |> put_locale("zh-TW")
      |> put_req_header("accept-language", "en-US")
      |> init_test_session(%{})
      |> fetch_cookies()
      |> LocalePlug.call([])

    assert conn.assigns.locale.tag == "en"
    assert conn.assigns.locale_preference == nil
  end

  test "Vary preserves existing values without duplicating Accept-Language", %{conn: conn} do
    resolved =
      conn
      |> init_test_session(%{})
      |> fetch_cookies()
      |> put_resp_header("vary", "accept-encoding, Origin")
      |> LocalePlug.call([])

    assert get_resp_header(resolved, "vary") == ["accept-encoding, Origin, accept-language"]

    resolved = conn |> init_test_session(%{}) |> fetch_cookies() |> put_resp_header("vary", "Accept-Language, Origin") |> LocalePlug.call([])
    assert get_resp_header(resolved, "vary") == ["Accept-Language, Origin"]

    resolved = conn |> init_test_session(%{}) |> fetch_cookies() |> put_resp_header("vary", "*") |> LocalePlug.call([])
    assert get_resp_header(resolved, "vary") == ["*"]
  end
end
