defmodule CodexPooler.Repo.Migrations.AddPromptCacheAffinityEnabledToPoolRoutingSettings do
  use Ecto.Migration

  def change do
    alter table(:pool_routing_settings) do
      add :prompt_cache_affinity_enabled, :boolean, null: false, default: true
    end

    execute(
      "UPDATE pool_routing_settings SET prompt_cache_affinity_enabled = TRUE WHERE prompt_cache_affinity_enabled IS NULL",
      "UPDATE pool_routing_settings SET prompt_cache_affinity_enabled = TRUE"
    )
  end
end
