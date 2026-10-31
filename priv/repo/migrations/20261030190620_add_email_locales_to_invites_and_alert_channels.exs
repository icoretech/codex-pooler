defmodule CodexPooler.Repo.Migrations.AddEmailLocalesToInvitesAndAlertChannels do
  use Ecto.Migration

  def up do
    alter table(:invites) do
      add :locale, :string, null: true
    end

    alter table(:alert_channels) do
      add :locale, :string, null: true
    end

    create constraint(:invites, :invites_locale_check, check: "locale IS NULL OR locale IN ('en', 'zh-CN')")

    create constraint(:alert_channels, :alert_channels_locale_check, check: "locale IS NULL OR locale IN ('en', 'zh-CN')")

    create constraint(:alert_channels, :alert_channels_email_locale_check, check: "channel_type = 'email' OR locale IS NULL")
  end

  def down do
    drop constraint(:alert_channels, :alert_channels_email_locale_check)
    drop constraint(:alert_channels, :alert_channels_locale_check)
    drop constraint(:invites, :invites_locale_check)

    alter table(:alert_channels) do
      remove :locale
    end

    alter table(:invites) do
      remove :locale
    end
  end
end
