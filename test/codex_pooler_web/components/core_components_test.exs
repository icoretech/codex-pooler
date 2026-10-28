defmodule CodexPoolerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents

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
