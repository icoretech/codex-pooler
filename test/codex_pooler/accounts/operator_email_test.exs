defmodule CodexPooler.Accounts.OperatorEmailTest do
  use CodexPooler.DataCase, async: false

  import Swoosh.TestAssertions

  alias CodexPooler.Accounts.OperatorEmail
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  setup do
    previous = CodexPooler.TestAppEnv.restore_on_exit(InstanceSettings)
    Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    :ok
  end

  @tag :credential_email
  test "delivers operator access emails with the expected text body" do
    operator_email = "operator@example.com"
    temporary_password = "TempPass123!"
    update_login_base_url!("https://operators.example.test/")

    expected_body =
      [
        "An administrator created or updated Codex Pooler operator access for this email.",
        "If you did not expect this email, do not sign in with this password. Contact your system administrator or ignore this email.",
        "Never forward this temporary password. Codex Pooler administrators will not ask you to send it back.",
        "",
        "Login URL: #{login_base_url()}/login",
        "Operator email: #{operator_email}",
        "Temporary password: #{temporary_password}",
        "You will be asked to change this password after sign in."
      ]
      |> Enum.join("\n")

    assert {:ok, _email} =
             OperatorEmail.deliver_operator_access(operator_email, temporary_password, true)

    assert_email_sent(
      from: sender(),
      to: operator_email,
      subject: "Codex Pooler operator access",
      text_body: expected_body
    )
  end

  @tag :text_only
  test "builds temporary password emails without html bodies" do
    operator_email = "operator@example.com"
    temporary_password = "TempPass123!"
    update_login_base_url!("https://operators.example.test")

    email =
      OperatorEmail.temporary_password_email(operator_email, temporary_password, true)

    assert email.from == sender()
    assert email.to == [{"", operator_email}]
    assert email.subject == "Codex Pooler temporary password"
    assert email.html_body == nil
    assert email.text_body =~ "If you did not expect this email"
    assert email.text_body =~ "Never forward this temporary password"
    assert email.text_body =~ "Login URL: #{login_base_url()}/login"
    assert email.text_body =~ "Operator email: #{operator_email}"
    assert email.text_body =~ "Temporary password: #{temporary_password}"
    assert email.text_body =~ "You will be asked to change this password after sign in."
    assert length(String.split(email.text_body, temporary_password)) == 2

    assert_no_email_sent()
  end

  test "reads login base url from current instance settings at render time" do
    update_login_base_url!("https://first.example.test")

    first_email =
      OperatorEmail.temporary_password_email("operator@example.com", "TempPass123!", true)

    assert first_email.text_body =~ "Login URL: https://first.example.test/login"

    update_login_base_url!("https://second.example.test")

    second_email =
      OperatorEmail.temporary_password_email("operator@example.com", "TempPass123!", true)

    assert second_email.text_body =~ "Login URL: https://second.example.test/login"
  end

  test "public operator app URL with a trailing slash appends login once" do
    update_login_base_url!("https://codex-pooler.example.com/")

    email =
      OperatorEmail.temporary_password_email("operator@example.com", "TempPass123!", true)

    assert email.text_body =~ "Login URL: https://codex-pooler.example.com/login"
    refute email.text_body =~ "https://codex-pooler.example.com//login"
  end

  defp sender do
    {"Codex Pooler", sender_address()}
  end

  defp sender_address do
    Application.get_env(:codex_pooler, :mailer_from, "codex-pooler@example.com")
  end

  defp login_base_url do
    InstanceSettings.current().operator.login_base_url
  end

  defp update_login_base_url!(url) do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(settings, %{
               "operator" => %{"login_base_url" => url}
             })
  end
end
