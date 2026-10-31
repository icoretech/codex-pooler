defmodule CodexPooler.Accounts.UserLocaleTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{OperatorManagement, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo
  alias CodexPooler.SupportedLocales

  test "locale changesets allow the supported stored tags and nil" do
    for tag <- SupportedLocales.tags() ++ [nil] do
      changeset = User.locale_changeset(%User{locale: "en"}, %{locale: tag})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :locale) == tag
      assert %{constraint: "users_locale_check", field: :locale, type: :check} = hd(changeset.constraints)
    end
  end

  test "locale changesets reject unsupported and non-canonical storage values" do
    for tag <- ["de", "zh_CN", "zh-cn", "zh-Hant", "auto", 1, %{}] do
      changeset = User.locale_changeset(%User{}, %{locale: tag})
      refute changeset.valid?
      assert %{locale: [_ | _]} = errors_on(changeset)
    end
  end

  test "the dedicated facade persists and clears language with an updated timestamp and no audit event" do
    %{user: user} = bootstrap_owner_fixture()
    original_locale = user.locale
    audit_ids = Repo.all(from event in AuditEvent, select: event.id, order_by: event.id)
    old_timestamp = DateTime.add(DateTime.utc_now(), -60, :second)
    user = user |> Ecto.Changeset.change(updated_at: old_timestamp) |> Repo.update!()

    assert is_nil(original_locale)
    assert {:ok, updated} = Accounts.update_user_locale(user, "zh-CN")
    assert updated.locale == "zh-CN"
    assert DateTime.compare(updated.updated_at, old_timestamp) == :gt
    assert Repo.reload!(user).locale == "zh-CN"

    assert {:ok, cleared} = OperatorManagement.update_user_locale(updated, nil)
    assert cleared.locale == nil
    assert Repo.reload!(user).locale == nil
    assert Repo.all(from event in AuditEvent, select: event.id, order_by: event.id) == audit_ids
  end

  test "invalid language writes leave the account unchanged" do
    %{user: user} = bootstrap_owner_fixture()
    assert {:ok, user} = Accounts.update_user_locale(user, "en")
    assert {:error, changeset} = Accounts.update_user_locale(user, "zh-TW")
    assert %{locale: [_ | _]} = errors_on(changeset)
    assert Repo.reload!(user).locale == "en"
  end

  test "profile and lifecycle update changesets cannot change the language preference" do
    changeset = User.operator_update_changeset(%User{email: "operator@example.com", locale: "en"}, %{"locale" => "zh-CN"})
    assert Ecto.Changeset.get_field(changeset, :locale) == "en"
    assert Ecto.Changeset.fetch_change(changeset, :locale) == :error
  end

  test "the database constraint rejects invalid direct persistence and permits nil" do
    %{user: user} = bootstrap_owner_fixture()

    invalid =
      user
      |> Ecto.Changeset.change(locale: "zh-TW")
      |> Ecto.Changeset.check_constraint(:locale, name: :users_locale_check)

    assert {:error, changeset} = Repo.update(invalid, mode: :savepoint)
    assert {_, metadata} = Keyword.fetch!(changeset.errors, :locale)
    assert metadata[:constraint] == :check
    assert metadata[:constraint_name] == "users_locale_check"
    assert Repo.reload!(user).locale == nil

    assert {:ok, user} = user |> Ecto.Changeset.change(locale: "zh-CN") |> Repo.update()
    assert {:ok, user} = user |> Ecto.Changeset.change(locale: nil) |> Repo.update()
    assert user.locale == nil
  end

  test "updating a stale account returns an error instead of claiming persistence" do
    %{user: user} = bootstrap_owner_fixture()
    stale = %{user | id: Ecto.UUID.generate()}
    assert {:error, changeset} = Accounts.update_user_locale(stale, "zh-CN")
    assert %{locale: [_ | _]} = errors_on(changeset)
    assert Repo.reload!(user).locale == nil
  end
end
