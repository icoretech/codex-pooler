defmodule CodexPooler.Repo.Migrations.AddApiKeyDashboardPersistence do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :dashboard_access, :boolean, null: false, default: false
    end

    create table(:api_key_dashboard_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :api_key_id,
          references(:api_keys,
            type: :binary_id,
            on_delete: :delete_all,
            name: :api_key_dashboard_sessions_api_key_id_fkey
          ),
          null: false

      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(
             :api_key_dashboard_sessions,
             :api_key_dashboard_sessions_token_hash_shape_check,
             check: "octet_length(token_hash) = 32"
           )

    create unique_index(:api_key_dashboard_sessions, [:token_hash],
             name: :api_key_dashboard_sessions_token_hash_uq
           )

    create index(:api_key_dashboard_sessions, [:api_key_id, :expires_at],
             name: :api_key_dashboard_sessions_api_key_expires_idx
           )

    create index(:api_key_dashboard_sessions, [:expires_at],
             name: :api_key_dashboard_sessions_expires_idx
           )
  end
end
