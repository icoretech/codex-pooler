defmodule CodexPooler.Repo.Migrations.AddInstancePresenceAndAttemptOwner do
  use Ecto.Migration

  def change do
    create table(:instance_presences, primary_key: false) do
      add :instance_id, :string, primary_key: true
      add :started_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:instance_presences, :instance_presences_instance_id_present_check,
             check: "length(btrim(instance_id)) > 0"
           )

    create index(:instance_presences, [:last_seen_at])

    alter table(:attempts) do
      add :owner_instance_id, :string
    end

    create index(:attempts, [:owner_instance_id, :started_at],
             name: :attempts_open_owner_instance_idx,
             where: "status IN ('queued', 'in_progress') AND owner_instance_id IS NOT NULL"
           )
  end
end
