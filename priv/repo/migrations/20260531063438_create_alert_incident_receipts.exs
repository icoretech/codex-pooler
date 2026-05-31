defmodule CodexPooler.Repo.Migrations.CreateAlertIncidentReceipts do
  use Ecto.Migration

  def change do
    create table(:alert_incident_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :operator_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :incident_id, references(:alert_incidents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :read_at, :utc_datetime_usec
      add :dismissed_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:alert_incident_receipts, [:operator_id, :incident_id],
             name: :alert_incident_receipts_operator_incident_uq
           )

    create index(:alert_incident_receipts, [:incident_id],
             name: :alert_incident_receipts_incident_id_idx
           )

    create index(:alert_incident_receipts, [:operator_id, :dismissed_at],
             name: :alert_incident_receipts_operator_dismissed_idx
           )
  end
end
