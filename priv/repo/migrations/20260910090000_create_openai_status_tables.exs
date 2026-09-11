defmodule CodexPooler.Repo.Migrations.CreateOpenAIStatusTables do
  use Ecto.Migration

  def change do
    create table(:openai_status_feed_states, primary_key: false) do
      add :singleton, :boolean, primary_key: true, default: true
      add :etag, :string
      add :last_modified, :string
      add :last_success_at, :utc_datetime_usec
      add :last_attempt_at, :utc_datetime_usec
      add :last_error_code, :string
      add :last_error_at, :utc_datetime_usec
      add :active_count, :integer, null: false, default: 0
      add :aggregate_revision, :integer, null: false, default: 0
      add :content_hash, :string
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:openai_status_feed_states, :openai_status_feed_states_singleton_check,
             check: "singleton = true"
           )

    create table(:openai_status_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :guid, :string, null: false
      add :title, :string, null: false
      add :status, :string, null: false
      add :summary, :string, null: false, default: ""
      add :component, :string
      add :link, :string, null: false
      add :published_at, :utc_datetime_usec, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec
      add :omission_count, :integer, null: false, default: 0
      add :revision, :integer, null: false, default: 1
      add :content_hash, :string, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:openai_status_incidents, [:guid], name: :openai_status_incidents_guid_uq)

    create index(:openai_status_incidents, [:resolved_at, :retired_at, :updated_at],
             name: :openai_status_incidents_retention_idx
           )

    create index(:openai_status_incidents, [:status, :resolved_at, :retired_at],
             name: :openai_status_incidents_active_idx
           )

    create table(:openai_status_dismissals, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :operator_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :incident_id,
          references(:openai_status_incidents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :incident_revision, :integer, null: false
      add :dismissed_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(
             :openai_status_dismissals,
             [:operator_id, :incident_id, :incident_revision],
             name: :openai_status_dismissals_operator_incident_revision_uq
           )

    create index(:openai_status_dismissals, [:operator_id, :dismissed_at],
             name: :openai_status_dismissals_operator_idx
           )
  end
end
