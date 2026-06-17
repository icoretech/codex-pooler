defmodule CodexPooler.Repo.Migrations.RemoveControlPlaneAnalyticsForwardingFromPoolRoutingSettings do
  use Ecto.Migration

  def change do
    alter table(:pool_routing_settings) do
      remove :control_plane_analytics_forwarding_enabled, :boolean, null: false, default: true
    end
  end
end
