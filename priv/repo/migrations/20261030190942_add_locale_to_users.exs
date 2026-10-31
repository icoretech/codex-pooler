defmodule CodexPooler.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :locale, :string, null: true
    end

    create constraint(:users, :users_locale_check, check: "locale IS NULL OR locale IN ('en', 'zh-CN')")
  end

  def down do
    drop constraint(:users, :users_locale_check)

    alter table(:users) do
      remove :locale
    end
  end
end
