defmodule CodexPoolerWeb.LocaleTest do
  use ExUnit.Case, async: true

  alias CodexPooler.SupportedLocales
  alias CodexPoolerWeb.{Locale, ObservatoryAuth}

  test "every persisted tag has exactly one presentation and catalog mapping" do
    locales = Locale.locales()

    assert Enum.map(locales, & &1.tag) == SupportedLocales.tags()
    assert Enum.uniq_by(locales, & &1.tag) == locales
    assert Enum.all?(locales, &(&1.label != "" and &1.dir == "ltr"))
    assert Enum.all?(locales, &(&1.gettext == SupportedLocales.gettext_locale(&1.tag)))
    assert Locale.default() == %{tag: "en", label: "English", dir: "ltr", gettext: "en"}
    assert SupportedLocales.gettext_locale(nil) == "en"
    assert SupportedLocales.gettext_locale("unsupported") == "en"
  end

  test "normalization accepts supported spellings and English browser variants" do
    for tag <- ["zh-CN", "zh_CN", "zh-cn", "zh-Hans", "zh-Hans-CN", "zh-SG", "zh", "  zh_CN  "] do
      assert Locale.normalize(tag) == "zh-CN"
      assert Locale.fetch(tag).gettext == "zh_CN"
    end

    for tag <- ["en", "EN", "en-US", "en-GB", " en_US "] do
      assert Locale.normalize(tag) == "en"
    end
  end

  test "Traditional Chinese and malformed or unsupported tags never match Simplified Chinese" do
    for tag <- ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "zh-Hant-CN", "zh-Hans-TW", "zh--CN", "zh-CN;q=1", "en-", "de", "", "  ", nil, 7, %{}, <<255>>] do
      assert Locale.normalize(tag) == nil
      assert Locale.fetch(tag) == nil
    end

    assert_raise ArgumentError, fn -> Locale.fetch!("zh-TW") end
  end

  test "Accept-Language quality orders supported tags and keeps equal-quality header order" do
    assert Locale.from_accept_language("en-US;q=0.4, zh-Hans;q=0.9").tag == "zh-CN"
    assert Locale.from_accept_language("zh-CN;q=0.5, en;q=0.8").tag == "en"
    assert Locale.from_accept_language("zh-CN;q=0.8, en;q=0.8").tag == "zh-CN"
    assert Locale.from_accept_language("en;q=0.8, zh-CN;q=0.8").tag == "en"
    assert Locale.from_accept_language("fr;q=1, ZH-cn;Q=0.7, en;q=0.2").tag == "zh-CN"
    assert Locale.from_accept_language("zh-CN;q=0, en;q=0.1").tag == "en"
    assert Locale.from_accept_language("en;q=0, zh-CN;q=0") == nil
  end

  test "wildcard negotiation does not reselect an explicitly excluded language" do
    assert Locale.from_accept_language("*;q=1, en;q=0").tag == "zh-CN"
    assert Locale.from_accept_language("en;q=0, *;q=0.5").tag == "zh-CN"
    assert Locale.from_accept_language("*;q=1, zh-CN;q=0").tag == "en"
    assert Locale.from_accept_language("*;q=1, en;q=0, zh-CN;q=0") == nil
    assert Locale.from_accept_language("*;q=0, zh-CN;q=0.8").tag == "zh-CN"
  end

  test "Accept-Language skips malformed entries instead of promoting them to quality one" do
    for malformed <- ["zh-CN;q=wrong", "zh-CN;q=1.1", "zh-CN;q=-0.1", "zh-CN;q=0.1234", "zh-CN;q=.9", "zh-CN;q=0.9junk", "zh-CN;p=0.9", "zh-CN;q=0.9;q=1", "zh--CN", "zh_CN"] do
      assert Locale.from_accept_language(malformed <> ", en;q=0.1").tag == "en"
    end

    assert Locale.from_accept_language("zh-CN;q=wrong") == nil
    assert Locale.from_accept_language("*").tag == "en"
    assert Locale.from_accept_language("*;q=0") == nil
    assert Locale.from_accept_language("zh-Hant, zh-TW;q=0.8") == nil
    assert Locale.resolve(nil, nil, "zh-Hant, zh-TW;q=0.8").tag == "en"
    assert Locale.from_accept_language(nil) == nil
    assert Locale.from_accept_language("") == nil
    assert Locale.from_accept_language(<<255>>) == nil
  end

  test "resolution prefers the account, then a valid cookie, then browser detection" do
    assert Locale.resolve("en", "zh-CN", "zh-CN").tag == "en"
    assert Locale.resolve("zh-CN", "en", "en").tag == "zh-CN"
    assert Locale.resolve(nil, "zh_CN", "en").tag == "zh-CN"
    assert Locale.resolve("unsupported", "zh-CN", "en").tag == "zh-CN"
    assert Locale.resolve(nil, "unsupported", "zh-Hans").tag == "zh-CN"
    assert Locale.resolve(nil, nil, nil).tag == "en"
    assert Locale.html_lang(nil) == "en"
    assert Locale.dir(nil) == "ltr"
    assert Locale.html_lang(Locale.fetch!("zh-CN")) == "zh-CN"
    assert Locale.gettext_locale(Locale.fetch!("zh-CN")) == "zh_CN"
  end

  test "the signed LiveView handoff separates the resolved language from an explicit preference" do
    conn =
      Plug.Test.conn(:get, "/login")
      |> Plug.Conn.assign(:locale, Locale.fetch!("zh-CN"))
      |> Plug.Conn.assign(:locale_preference, nil)

    assert Locale.live_session(conn) == %{"locale" => "zh-CN"}

    conn = Plug.Conn.assign(conn, :locale_preference, "en")
    assert Locale.live_session(conn) == %{"locale" => "zh-CN", "locale_preference" => "en"}
    assert Locale.live_session(Plug.Test.conn(:get, "/login")) == %{"locale" => "en"}
  end

  test "the mount hook revalidates the session and sets Gettext before subsequent hooks" do
    session = %{"locale" => "zh-CN", "locale_preference" => "zh_CN"}
    assert {:cont, socket} = Locale.on_mount(:assign_locale, %{}, session, %Phoenix.LiveView.Socket{})
    assert socket.assigns.locale.tag == "zh-CN"
    assert socket.assigns.locale_preference == "zh-CN"
    assert Gettext.get_locale() == "zh_CN"

    assert {:cont, socket} = Locale.on_mount(:assign_locale, %{}, %{"locale" => "zh-TW", "locale_preference" => "invalid"}, socket)
    assert socket.assigns.locale.tag == "en"
    assert socket.assigns.locale_preference == nil
    assert Gettext.get_locale() == "en"
  end

  test "Observatory session merging retains both a validated handoff and locale assignments" do
    conn =
      Plug.Test.conn(:get, "/observatory")
      |> Phoenix.ConnTest.init_test_session(%{"observatory_handoff" => %{dashboard_session_id: "synthetic-dashboard-session"}})
      |> Plug.Conn.assign(:locale, Locale.fetch!("zh-CN"))
      |> Plug.Conn.assign(:locale_preference, "zh-CN")

    assert ObservatoryAuth.live_session(conn) == %{
             "observatory_handoff" => %{dashboard_session_id: "synthetic-dashboard-session"},
             "locale" => "zh-CN",
             "locale_preference" => "zh-CN"
           }

    conn = Plug.Conn.put_session(conn, "observatory_handoff", %{dashboard_session_id: "synthetic-dashboard-session", extra: true})
    assert ObservatoryAuth.live_session(conn) == %{"locale" => "zh-CN", "locale_preference" => "zh-CN"}
  end
end
