defmodule CodexPooler.Repo.Migrations.AddUpstreamWebsocketBridgeEnabledToPoolRoutingSettings do
  use Ecto.Migration

  def change do
    alter table(:pool_routing_settings) do
      add :upstream_websocket_bridge_enabled, :boolean, null: false, default: false
    end

    execute(
      "UPDATE pool_routing_settings SET upstream_websocket_bridge_enabled = FALSE WHERE upstream_websocket_bridge_enabled IS NULL",
      "UPDATE pool_routing_settings SET upstream_websocket_bridge_enabled = FALSE"
    )
  end
end
