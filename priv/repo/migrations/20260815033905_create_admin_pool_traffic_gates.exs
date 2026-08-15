defmodule CodexPooler.Repo.Migrations.CreateAdminPoolTrafficGates do
  use Ecto.Migration

  def up do
    create table(:admin_pool_traffic_gates, primary_key: false) do
      add :operator_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :owner_token, :uuid
      add :lease_expires_at, :utc_datetime_usec
      add :cooldown_until, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :admin_pool_traffic_gates,
             :admin_pool_traffic_gates_owner_lease_pair_check,
             check: "(owner_token IS NULL) = (lease_expires_at IS NULL)"
           )
  end

  def down do
    drop table(:admin_pool_traffic_gates)
  end
end
