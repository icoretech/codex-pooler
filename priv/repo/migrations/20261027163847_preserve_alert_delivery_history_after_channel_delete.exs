defmodule CodexPooler.Repo.Migrations.PreserveAlertDeliveryHistoryAfterChannelDelete do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE alert_delivery_attempts DROP CONSTRAINT alert_delivery_attempts_channel_id_fkey"

    alter table(:alert_delivery_attempts) do
      modify :channel_id, references(:alert_channels, type: :binary_id, on_delete: :nilify_all), null: true
      add :channel_created_by_user_id, :binary_id
      add :channel_display_name, :text
      add :channel_type, :text
      add :channel_deleted_at, :utc_datetime_usec
    end

    execute """
    UPDATE alert_delivery_attempts AS attempts
    SET channel_created_by_user_id = channels.created_by_user_id,
        channel_display_name = channels.display_name,
        channel_type = channels.channel_type
    FROM alert_channels AS channels
    WHERE attempts.channel_id = channels.id
    """

    create index(:alert_delivery_attempts, [:channel_created_by_user_id, :channel_deleted_at], name: :alert_delivery_attempts_deleted_channel_scope_idx, where: "channel_id IS NULL")
  end

  def down do
    execute "DROP INDEX alert_delivery_attempts_deleted_channel_scope_idx"
    execute "ALTER TABLE alert_delivery_attempts DROP CONSTRAINT alert_delivery_attempts_channel_id_fkey"

    alter table(:alert_delivery_attempts) do
      remove :channel_created_by_user_id
      remove :channel_display_name
      remove :channel_type
      remove :channel_deleted_at
      modify :channel_id, references(:alert_channels, type: :binary_id, on_delete: :delete_all), null: false
    end
  end
end
