defmodule CodexPooler.Repo.Migrations.ReplaceUpstreamWebsocketBridgeWithImageGeneration do
  use Ecto.Migration

  def up do
    alter table(:pool_routing_settings) do
      add :allow_image_generation, :boolean, null: false, default: true
      remove :upstream_websocket_bridge_enabled, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:pool_routing_settings) do
      add :upstream_websocket_bridge_enabled, :boolean, null: false, default: false
      remove :allow_image_generation, :boolean, null: false, default: true
    end
  end
end
