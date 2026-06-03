defmodule CodexPooler.Repo.Migrations.AddDatetimeDisplayPreferencesToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :datetime_format, :string, null: false, default: "default"
      add :timezone, :string, null: false, default: "Etc/UTC"
    end

    create constraint(:users, :users_datetime_format_check,
             check:
               "datetime_format = ANY (ARRAY['default'::text, 'short'::text, 'long'::text, 'iso8601'::text])"
           )
  end

  def down do
    execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS users_datetime_format_check")

    alter table(:users) do
      remove :timezone
      remove :datetime_format
    end
  end
end
