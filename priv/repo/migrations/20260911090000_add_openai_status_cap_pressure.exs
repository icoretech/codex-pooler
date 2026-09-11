defmodule CodexPooler.Repo.Migrations.AddOpenAIStatusCapPressure do
  use Ecto.Migration

  def change do
    alter table(:openai_status_feed_states) do
      add :cap_pressure, :string, null: false, default: "none"
    end

    create constraint(:openai_status_feed_states, :openai_status_feed_states_cap_pressure_check,
             check: "cap_pressure IN ('none', 'active_over_cap', 'terminal_exhausted')"
           )
  end
end
