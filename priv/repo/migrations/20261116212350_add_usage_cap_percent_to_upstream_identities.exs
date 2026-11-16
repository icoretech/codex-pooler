defmodule CodexPooler.Repo.Migrations.AddUsageCapPercentToUpstreamIdentities do
  use Ecto.Migration

  def change do
    alter table(:upstream_identities) do
      add :usage_cap_percent, :integer, null: true
    end

    create constraint(
             :upstream_identities,
             :upstream_identities_usage_cap_percent_check,
             check: "usage_cap_percent IS NULL OR (usage_cap_percent >= 1 AND usage_cap_percent <= 99)"
           )
  end
end
