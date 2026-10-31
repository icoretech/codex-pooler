defmodule CodexPooler.Access.InviteEmailTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Swoosh.TestAssertions

  alias CodexPooler.Access
  alias CodexPooler.Access.{Invite, InviteEmail}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Repo

  test "delivers Pool invite emails with the expected text body" do
    pool = pool_fixture(%{slug: "email-pool", name: "Email Pool"})
    scope = fixture_owner_scope()
    invite_url = "https://codex-pooler.example.com/onboarding/invites/raw-token"

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{"invited_email" => "invitee@example.com"})

    assert {:ok, _email} =
             InviteEmail.deliver_pool_invite(invite, invite_url, pool, scope.user)

    assert_email_sent(fn email ->
      assert email.to == [{"", "invitee@example.com"}]
      assert email.subject == "Codex Pooler Pool invite"

      assert email.text_body =~
               "#{scope.user.display_name} invited you to connect an OpenAI account to Email Pool."

      assert email.text_body =~ "Accept invite: #{invite_url}"
      assert email.text_body =~ "What happens next:"
      assert email.text_body =~ "verify it with your system administrator"
      assert email.text_body =~ "Invited by: #{scope.user.email}"
      assert email.html_body =~ "Pool invite for Email Pool"

      assert email.html_body =~
               "#{scope.user.display_name} invited you to connect an OpenAI account"

      assert email.html_body =~ "What happens after accepting"
      assert email.html_body =~ "Verify unexpected invites"
      assert email.html_body =~ ~s(href="#{invite_url}")
      assert email.html_body =~ "Accept invite"
      true
    end)
  end

  test "escapes invite email html values" do
    pool = pool_fixture(%{slug: "escape-pool", name: "Escape <Pool>"})
    scope = fixture_owner_scope()
    invite_url = "https://codex-pooler.example.com/onboarding/invites/escape-token"

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{"invited_email" => "escape@example.com"})

    email =
      InviteEmail.pool_invite_email(
        invite,
        invite_url,
        pool,
        %{scope.user | display_name: "Owner <Root>"}
      )

    assert email.html_body =~ "Escape &lt;Pool&gt;"
    assert email.html_body =~ "Owner &lt;Root&gt;"
    refute email.html_body =~ "Escape <Pool>"
    refute email.html_body =~ "Owner <Root>"
  end

  test "maybe_deliver_pool_invite records delivery flags without leaking tokens" do
    pool = pool_fixture(%{slug: "flag-pool", name: "Flag Pool"})
    scope = fixture_owner_scope()
    invite_url = "https://codex-pooler.example.com/onboarding/invites/flag-token"

    {:ok, %{invite: invite} = result} =
      Access.create_invite(scope, pool, %{"invited_email" => "flags@example.com"})

    assert %{emailed?: true, email_error?: false, invite: %Invite{} = updated_invite} =
             InviteEmail.maybe_deliver_pool_invite(result, true, invite_url, pool, scope.user)

    assert updated_invite.id == invite.id
    assert updated_invite.email_sent_at
    assert Repo.reload!(invite).email_sent_at

    assert_email_sent(to: {"", "flags@example.com"}, subject: "Codex Pooler Pool invite")
  end

  test "maybe_deliver_pool_invite marks skipped email delivery without sending" do
    pool = pool_fixture(%{slug: "skip-email-pool", name: "Skip Email Pool"})
    scope = fixture_owner_scope()
    invite_url = "https://codex-pooler.example.com/onboarding/invites/skip-email-token"

    {:ok, %{invite: invite} = result} =
      Access.create_invite(scope, pool, %{"invited_email" => "skip-email@example.com"})

    assert %{emailed?: false, email_error?: false, invite: %Invite{} = unchanged_invite} =
             InviteEmail.maybe_deliver_pool_invite(result, false, invite_url, pool, scope.user)

    assert unchanged_invite.id == invite.id
    refute unchanged_invite.email_sent_at
    refute Repo.reload!(invite).email_sent_at
    assert_no_email_sent()
  end

  test "renders Chinese invite content from the stored invite language and restores the caller locale" do
    pool = pool_fixture(%{name: "Chinese Pool"})
    scope = fixture_owner_scope()
    {:ok, %{invite: invite}} = Access.create_invite(scope, pool, %{invited_email: "chinese-invite@example.com", locale: "zh-CN"})
    Gettext.put_locale("en")

    assert {:ok, _receipt} = InviteEmail.deliver_pool_invite(invite, "https://example.com/invite", pool, scope.user)

    assert_email_sent(fn email ->
      assert email.subject == "Codex Pooler Pool 邀请"
      assert email.text_body =~ "邀请您将 OpenAI 账号连接到 Chinese Pool。"
      assert email.text_body =~ "接受邀请：https://example.com/invite"
      assert email.html_body =~ ~s(lang="zh-CN")
      assert email.html_body =~ "接受邀请"
      true
    end)

    assert Gettext.get_locale() == "en"
  end

  test "null and unsupported stored invite languages fall back to English rather than the sender locale" do
    pool = pool_fixture()
    scope = fixture_owner_scope()
    {:ok, %{invite: invite}} = Access.create_invite(scope, pool, %{invited_email: "fallback-invite@example.com"})
    Gettext.put_locale("zh_CN")

    for locale <- [nil, "retired-locale"] do
      email = InviteEmail.pool_invite_email(%{invite | locale: locale}, "https://example.com/invite", pool, scope.user)
      assert email.subject == "Codex Pooler Pool invite"
      assert email.text_body =~ "What happens next:"
      assert email.html_body =~ ~s(lang="en")
    end

    assert Gettext.get_locale() == "zh_CN"
  end

  test "reissuing an invite retains its stored language after the inviter changes language" do
    pool = pool_fixture()
    scope = fixture_owner_scope()
    {:ok, %{invite: invite}} = Access.create_invite(scope, pool, %{invited_email: "resend-locale@example.com", locale: "zh-CN"})
    {:ok, user} = CodexPooler.Accounts.update_user_locale(scope.user, "en")
    scope = Scope.for_user(user, ["instance_owner"])

    assert {:ok, %{invite: replacement}} = Access.reissue_invite(scope, invite)
    assert replacement.locale == "zh-CN"
    assert Repo.reload!(replacement).locale == "zh-CN"
    assert {:ok, _receipt} = InviteEmail.deliver_pool_invite(replacement, "https://example.com/invite", pool, user)
    assert_email_sent(subject: "Codex Pooler Pool 邀请")
  end

  test "invites reject unsupported locale values at creation and enforce the database constraint" do
    pool = pool_fixture()
    scope = fixture_owner_scope()
    assert {:error, changeset} = Access.create_invite(scope, pool, %{invited_email: "invalid-locale@example.com", locale: "zh-TW"})
    assert "is invalid" in errors_on(changeset).locale

    {:ok, %{invite: invite}} = Access.create_invite(scope, pool, %{invited_email: "constraint-locale@example.com"})
    changeset = invite |> Ecto.Changeset.change(locale: "zh-TW") |> Ecto.Changeset.check_constraint(:locale, name: :invites_locale_check)
    assert {:error, changeset} = Repo.update(changeset, mode: :savepoint)
    assert "is invalid" in errors_on(changeset).locale
  end

  defp fixture_owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end
end
