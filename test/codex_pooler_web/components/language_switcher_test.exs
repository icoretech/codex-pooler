defmodule CodexPoolerWeb.Components.LanguageSwitcherTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Components.LanguageSwitcher
  alias CodexPoolerWeb.Locale

  setup do
    Gettext.put_locale("en")
    :ok
  end

  test "the chooser submits plain POST buttons with CSRF and an English fallback" do
    document = render_component(&LanguageSwitcher.language_switcher/1, id: "test-language") |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#test-language-form[action='/locale'][method='post']") |> Enum.count() == 1
    assert document |> LazyHTML.query("input[name='_csrf_token']") |> Enum.count() == 1
    assert document |> LazyHTML.query("button[type='submit'][name='locale'][value='auto'][aria-current='true']") |> Enum.count() == 1
    assert document |> LazyHTML.query("button[type='submit'][name='locale'][value='en']") |> LazyHTML.text() =~ "English"
    assert document |> LazyHTML.query("button[type='submit'][name='locale'][value='zh-CN']") |> LazyHTML.text() =~ "简体中文"
    assert document |> LazyHTML.query("summary[aria-label='Language']") |> LazyHTML.text() =~ "English"
  end

  test "the resolved language and explicit preference stay separate in Chinese" do
    Gettext.put_locale("zh_CN")

    document =
      render_component(&LanguageSwitcher.language_switcher/1, id: "zh-language", locale: Locale.fetch!("zh-CN"), preference: nil)
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("summary[aria-label='语言']") |> LazyHTML.text() =~ "简体中文"
    assert document |> LazyHTML.query("button[value='auto'][aria-current='true']") |> LazyHTML.text() =~ "浏览器默认"
    assert document |> LazyHTML.query("button[value='zh-CN'][aria-current='true']") |> Enum.empty?()
  end
end
