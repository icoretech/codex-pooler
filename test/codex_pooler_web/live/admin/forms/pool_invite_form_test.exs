defmodule CodexPoolerWeb.Admin.PoolInviteFormTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounts.User
  alias CodexPoolerWeb.Admin.PoolInviteForm

  test "known recipient language takes precedence over the inviter interface language" do
    recipient = %User{email: "recipient@example.com", locale: "zh-CN"}
    assert PoolInviteForm.invite_locale(" Recipient@Example.COM ", recipient, "en") == "zh-CN"
    assert PoolInviteForm.locale_default("zh-CN", "en") == %{locale: "zh-CN", source: :recipient}
  end

  test "unknown recipients use the current resolved UI language rather than a guessed email domain" do
    assert PoolInviteForm.invite_locale("recipient@example.cn", nil, "en") == "en"
    assert PoolInviteForm.invite_locale("recipient@example.com", nil, "zh-CN") == "zh-CN"
    assert PoolInviteForm.locale_default(nil, "zh-CN") == %{locale: "zh-CN", source: :inviter}
  end

  test "recipient without a preference uses the current resolved interface language" do
    recipient = %User{email: "recipient@example.com", locale: nil}
    assert PoolInviteForm.invite_locale(recipient.email, recipient, "zh-CN") == "zh-CN"
  end

  test "unsupported or missing recipient and inviter languages fall back to English" do
    assert PoolInviteForm.locale_default(nil, nil) == %{locale: "en", source: :default}
    assert PoolInviteForm.locale_default("retired-locale", "zh-TW") == %{locale: "en", source: :default}
    assert PoolInviteForm.invite_locale("unknown@example.com", %User{email: "other@example.com", locale: "zh-CN"}, nil) == "en"
  end

  test "derived defaults follow recipient changes until the operator makes an explicit selection" do
    recipient = %User{email: "known@example.com", locale: "zh-CN"}
    params = %{"invited_email" => recipient.email, "locale" => "en"}
    assert {derived, %{source: :recipient}} = PoolInviteForm.derive_locale(params, recipient, "en", false)
    assert derived["locale"] == "zh-CN"

    changed = Map.put(derived, "invited_email", "unknown@example.com")
    assert {derived, %{source: :inviter}} = PoolInviteForm.derive_locale(changed, nil, "en", false)
    assert derived["locale"] == "en"

    chosen = Map.put(changed, "locale", "zh-CN")
    assert {^chosen, %{locale: "zh-CN", source: :explicit}} = PoolInviteForm.derive_locale(chosen, nil, "en", true)
  end

  test "invalid explicit language stays invalid rather than silently changing the operator choice" do
    params = %{"pool_id" => "pool-id", "invited_email" => "recipient@example.com", "locale" => "zh-TW"}
    assert {^params, %{source: :explicit}} = PoolInviteForm.derive_locale(params, nil, "en", true)
    changeset = PoolInviteForm.changeset(params, %{id: "pool-id"})
    refute changeset.valid?
    assert {"is invalid", _opts} = Keyword.fetch!(changeset.errors, :locale)
  end
end
