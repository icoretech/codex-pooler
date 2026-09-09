defmodule CodexPooler.Repo.Migrations.AddUpstreamImportLockIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @account_index :upstream_identities_account_sibling_selection_idx
  @email_index :upstream_identities_email_workspace_fallback_idx
  @assignment_index :pool_upstream_assignments_identity_lock_idx

  def up do
    drop_supporting_indexes()

    create index(
             :upstream_identities,
             [:chatgpt_account_id, :workspace_id, :chatgpt_user_id, :created_at, :id],
             name: @account_index,
             where: "chatgpt_account_id IS NOT NULL",
             concurrently: true
           )

    create index(
             :upstream_identities,
             [:account_email, :workspace_id, :created_at, :id],
             name: @email_index,
             where: "account_email IS NOT NULL",
             concurrently: true
           )

    create index(:pool_upstream_assignments, [:upstream_identity_id, :id],
             name: @assignment_index,
             concurrently: true
           )
  end

  def down do
    drop_supporting_indexes()
  end

  defp drop_supporting_indexes do
    drop_if_exists index(
                     :pool_upstream_assignments,
                     [:upstream_identity_id, :id],
                     name: @assignment_index,
                     concurrently: true
                   )

    drop_if_exists index(
                     :upstream_identities,
                     [:account_email, :workspace_id, :created_at, :id],
                     name: @email_index,
                     concurrently: true
                   )

    drop_if_exists index(
                     :upstream_identities,
                     [:chatgpt_account_id, :workspace_id, :chatgpt_user_id, :created_at, :id],
                     name: @account_index,
                     concurrently: true
                   )
  end
end
