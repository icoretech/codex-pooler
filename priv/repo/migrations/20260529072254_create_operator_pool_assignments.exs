defmodule CodexPooler.Repo.Migrations.CreateOperatorPoolAssignments do
  use Ecto.Migration

  def up do
    create table(:operator_pool_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :pool_id, references(:pools, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "active"
      add :created_by_user_id, references(:users, type: :binary_id)
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :revoked_at, :utc_datetime_usec
    end

    create constraint(:operator_pool_assignments, :operator_pool_assignments_status_check,
             check: "status = ANY (ARRAY['active'::text, 'revoked'::text])"
           )

    create unique_index(:operator_pool_assignments, [:user_id, :pool_id],
             name: :operator_pool_assignments_user_pool_active_uq,
             where: "status = 'active'"
           )

    drop_single_active_owner_index()
    rewrite_legacy_instance_admin_memberships()
  end

  def down do
    raise Ecto.MigrationError,
          "operator_pool_assignments rollback is irreversible because instance_admin memberships are rewritten to instance_owner"
  end

  defp drop_single_active_owner_index do
    execute("DROP INDEX IF EXISTS public.memberships_single_instance_owner_active_uq")
  end

  defp rewrite_legacy_instance_admin_memberships do
    execute("""
    UPDATE public.memberships legacy_admin
    SET status = 'revoked',
        revoked_at = COALESCE(legacy_admin.revoked_at, now())
    WHERE legacy_admin.role = 'instance_admin'
      AND legacy_admin.status = 'active'
      AND EXISTS (
        SELECT 1
        FROM public.memberships active_owner
        WHERE active_owner.user_id = legacy_admin.user_id
          AND active_owner.role = 'instance_owner'
          AND active_owner.status = 'active'
      )
    """)

    execute("""
    UPDATE public.memberships membership
    SET role = 'instance_owner'
    WHERE membership.role = 'instance_admin'
    """)
  end
end
