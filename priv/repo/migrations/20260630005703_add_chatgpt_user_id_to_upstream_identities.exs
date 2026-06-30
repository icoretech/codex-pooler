defmodule CodexPooler.Repo.Migrations.AddChatgptUserIdToUpstreamIdentities do
  use Ecto.Migration

  def up do
    alter table(:upstream_identities) do
      add :chatgpt_user_id, :text
    end

    execute("DROP INDEX IF EXISTS public.upstream_identities_chatgpt_legacy_workspace_uq")
    execute("DROP INDEX IF EXISTS public.upstream_identities_chatgpt_workspace_slot_uq")

    create unique_index(:upstream_identities, [:chatgpt_account_id],
             name: :upstream_identities_chatgpt_legacy_workspace_uq,
             where:
               "chatgpt_account_id IS NOT NULL AND workspace_id IS NULL AND chatgpt_user_id IS NULL"
           )

    create unique_index(:upstream_identities, [:chatgpt_account_id, :workspace_id],
             name: :upstream_identities_chatgpt_workspace_slot_uq,
             where:
               "chatgpt_account_id IS NOT NULL AND workspace_id IS NOT NULL AND chatgpt_user_id IS NULL"
           )

    create unique_index(:upstream_identities, [:chatgpt_account_id, :chatgpt_user_id],
             name: :upstream_identities_chatgpt_user_legacy_workspace_uq,
             where:
               "chatgpt_account_id IS NOT NULL AND workspace_id IS NULL AND chatgpt_user_id IS NOT NULL"
           )

    create unique_index(
             :upstream_identities,
             [
               :chatgpt_account_id,
               :workspace_id,
               :chatgpt_user_id
             ],
             name: :upstream_identities_chatgpt_user_workspace_slot_uq,
             where:
               "chatgpt_account_id IS NOT NULL AND workspace_id IS NOT NULL AND chatgpt_user_id IS NOT NULL"
           )
  end

  def down do
    raise Ecto.MigrationError,
          "upstream identity subject fields cannot be safely removed without losing subject data"
  end
end
