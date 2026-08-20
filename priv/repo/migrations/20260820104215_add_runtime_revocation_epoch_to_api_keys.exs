defmodule CodexPooler.Repo.Migrations.AddRuntimeRevocationEpochToApiKeys do
  use Ecto.Migration

  def up do
    alter table(:api_keys) do
      add :runtime_revocation_epoch, :bigint, null: false, default: 0
    end
  end

  def down do
    alter table(:api_keys) do
      remove :runtime_revocation_epoch
    end
  end
end
