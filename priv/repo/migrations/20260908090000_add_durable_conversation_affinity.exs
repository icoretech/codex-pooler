defmodule CodexPooler.Repo.Migrations.AddDurableConversationAffinity do
  use Ecto.Migration

  def up do
    alter table(:pool_routing_settings, primary_key: false) do
      add :durable_conversation_affinity_enabled, :boolean, null: false, default: false
      add :durable_conversation_affinity_idle_seconds, :integer, null: false, default: 86_400
    end

    create constraint(:pool_routing_settings, :durable_conversation_affinity_idle_bounds,
             check: "durable_conversation_affinity_idle_seconds BETWEEN 60 AND 2592000"
           )

    alter table(:bridge_affinities) do
      add :generation, :bigint, null: false, default: 0
      add :expires_at, :utc_datetime_usec
    end

    create index(:bridge_affinities, [:expires_at, :id],
             name: :bridge_affinities_durable_expiry_idx,
             where: "affinity_kind = 'durable_conversation' AND status = 'active'"
           )
  end

  def down do
    execute "DELETE FROM bridge_affinities WHERE affinity_kind = 'durable_conversation'"

    drop index(:bridge_affinities, [:expires_at, :id],
           name: :bridge_affinities_durable_expiry_idx
         )

    alter table(:bridge_affinities) do
      remove :generation
      remove :expires_at
    end

    drop constraint(:pool_routing_settings, :durable_conversation_affinity_idle_bounds)

    alter table(:pool_routing_settings, primary_key: false) do
      remove :durable_conversation_affinity_enabled
      remove :durable_conversation_affinity_idle_seconds
    end
  end
end
