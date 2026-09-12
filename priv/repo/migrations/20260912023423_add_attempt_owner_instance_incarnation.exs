defmodule CodexPooler.Repo.Migrations.AddAttemptOwnerInstanceIncarnation do
  use Ecto.Migration

  # An instance identity is the node name plus the VM incarnation that minted
  # it. The node name derives from the pod IP, so a container restarting in
  # place reuses it; without the incarnation its predecessor's presence row is
  # simply refreshed by the successor and the orphans it left can never be
  # recognised.
  #
  # `instance_presences.instance_id` keeps its single-column primary key and
  # now holds `"<node>#<boot id>"`, so incarnations coexist as separate rows
  # and a previous release's heartbeat upsert (`ON CONFLICT (instance_id)`)
  # still works while a rollout is in flight. `node_name` and `boot_id` are the
  # join targets, and both are null on rows and attempts written before this
  # change: a null never equals an attempt's owner, so the old shape is out of
  # the ownership pass by SQL semantics and stays with the six-hour sweep.
  def change do
    alter table(:attempts) do
      add :owner_instance_boot_id, :string
    end

    alter table(:instance_presences) do
      add :node_name, :string
      add :boot_id, :string
    end

    create unique_index(:instance_presences, [:node_name, :boot_id],
             name: :instance_presences_incarnation_idx
           )

    drop index(:attempts, [:owner_instance_id, :started_at],
           name: :attempts_open_owner_instance_idx,
           where: "status IN ('queued', 'in_progress') AND owner_instance_id IS NOT NULL"
         )

    create index(:attempts, [:owner_instance_id, :owner_instance_boot_id, :started_at],
             name: :attempts_open_owner_incarnation_idx,
             where: "status IN ('queued', 'in_progress') AND owner_instance_boot_id IS NOT NULL"
           )
  end
end
