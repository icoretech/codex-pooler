defmodule CodexPooler.Repo.Migrations.AddRouteClassToAlertRules do
  use Ecto.Migration

  @route_class_check """
  route_class IS NULL OR (
    rule_kind IN ('pool_no_usable_assignments', 'pool_low_usable_assignments')
    AND route_class IN (
      'proxy_http',
      'proxy_control',
      'proxy_stream',
      'proxy_websocket',
      'proxy_compact',
      'file_upload',
      'audio_transcription',
      'admin_browser',
      'mcp'
    )
  )
  """

  def up do
    alter table(:alert_rules) do
      add :route_class, :text
    end

    create constraint(:alert_rules, :alert_rules_route_class_check, check: @route_class_check)
  end

  def down do
    drop constraint(:alert_rules, :alert_rules_route_class_check)

    alter table(:alert_rules) do
      remove :route_class
    end
  end
end
