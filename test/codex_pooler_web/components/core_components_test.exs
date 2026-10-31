defmodule CodexPoolerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents

  setup do
    Gettext.put_locale("en")
    :ok
  end

  test "Chinese OTP slots expose localized digit labels" do
    Gettext.put_locale("zh_CN")

    document =
      render_component(&otp_input/1, %{id: "zh_totp", name: "user[totp_code]", value: ""})
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#zh_totp_digit_0[aria-label='第 1 位，共 6 位']") |> Enum.count() == 1
    assert document |> LazyHTML.query("#zh_totp_digit_5[aria-label='第 6 位，共 6 位']") |> Enum.count() == 1
  end

  test "Chinese validation translates the real count error branch" do
    Gettext.put_locale("zh_CN")

    assert translate_error({"should be at least %{count} character(s)", count: 3}) == "长度应至少为 3 个字符"
  end

  test "otp input does not autofocus a slot by default" do
    document =
      render_component(&otp_input/1, %{
        id: "user_totp_code",
        name: "user[totp_code]",
        value: ""
      })
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, "[data-otp-slot][autofocus]") |> Enum.empty?()
  end

  test "otp input autofocuses only the first visible slot when requested" do
    document =
      render_component(&otp_input/1, %{
        id: "user_totp_code",
        name: "user[totp_code]",
        value: "",
        autofocus: true
      })
      |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query("#user_totp_code_digit_0[autofocus]")
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query("[data-otp-slot][autofocus]")
           |> Enum.count() == 1

    assert LazyHTML.query(document, "#user_totp_code[autofocus]") |> Enum.empty?()
    assert LazyHTML.query(document, "#user_totp_code_digit_1[autofocus]") |> Enum.empty?()
  end
end
