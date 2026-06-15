defmodule CodexPooler.Repo.Migrations.AddRequestCompressionEnabledToPoolRoutingSettings do
  use Ecto.Migration

  def change do
    alter table(:pool_routing_settings) do
      add :request_compression_enabled, :boolean, null: false, default: false
    end

    execute(
      "UPDATE pool_routing_settings SET request_compression_enabled = FALSE WHERE request_compression_enabled IS NULL",
      "UPDATE pool_routing_settings SET request_compression_enabled = FALSE"
    )
  end
end
