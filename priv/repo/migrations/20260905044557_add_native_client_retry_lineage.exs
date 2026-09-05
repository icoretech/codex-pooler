defmodule CodexPooler.Repo.Migrations.AddNativeClientRetryLineage do
  use Ecto.Migration

  def up do
    alter table(:requests) do
      add :native_client_retry_version, :integer
      add :native_client_retry_digest, :binary
      add :native_client_retry_auth_epoch, :bigint
    end

    create constraint(:requests, :requests_native_client_retry_witness_check,
             check:
               "(native_client_retry_version IS NULL AND native_client_retry_digest IS NULL AND native_client_retry_auth_epoch IS NULL) OR (native_client_retry_version = 1 AND octet_length(native_client_retry_digest) = 32 AND native_client_retry_auth_epoch >= 0)"
           )

    create table(:request_client_retry_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :predecessor_request_id,
          references(:requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :successor_request_id,
          references(:requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:request_client_retry_links, [:predecessor_request_id],
             name: :request_client_retry_links_predecessor_request_id_uq
           )

    create unique_index(:request_client_retry_links, [:successor_request_id],
             name: :request_client_retry_links_successor_request_id_uq
           )

    create constraint(
             :request_client_retry_links,
             :request_client_retry_links_distinct_requests_check,
             check: "predecessor_request_id <> successor_request_id"
           )
  end

  def down do
    drop table(:request_client_retry_links)

    alter table(:requests) do
      remove :native_client_retry_auth_epoch
      remove :native_client_retry_digest
      remove :native_client_retry_version
    end
  end
end
