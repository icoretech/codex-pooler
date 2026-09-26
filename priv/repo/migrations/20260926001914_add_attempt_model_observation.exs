defmodule CodexPooler.Repo.Migrations.AddAttemptModelObservation do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '10s'")

    alter table(:attempts) do
      add :model_observation, :map
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '10s'")

    alter table(:attempts) do
      remove :model_observation
    end
  end
end
