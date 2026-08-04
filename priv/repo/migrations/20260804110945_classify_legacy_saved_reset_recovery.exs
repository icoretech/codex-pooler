defmodule CodexPooler.Repo.Migrations.ClassifyLegacySavedResetRecovery do
  use Ecto.Migration

  def up do
    execute ~S"""
    UPDATE upstream_identities AS identity
    SET metadata = jsonb_set(
      identity.metadata,
      '{saved_reset_redemption,legacy_recovery}',
      '{"version": 1, "state": "unresolved"}'::jsonb,
      true
    )
    WHERE jsonb_typeof(identity.metadata) = 'object'
      AND jsonb_typeof(identity.metadata -> 'saved_reset_redemption') = 'object'
      AND identity.metadata #>> '{saved_reset_redemption,status}' = 'redeeming'
      AND identity.metadata #>> '{saved_reset_redemption,phase}' = 'consuming'
      AND NOT (identity.metadata -> 'saved_reset_redemption' ? 'provider_replay')
      AND NOT (identity.metadata -> 'saved_reset_redemption' ? 'legacy_recovery')
    """
  end

  def down do
    execute ~S"""
    UPDATE upstream_identities AS identity
    SET metadata = identity.metadata #- '{saved_reset_redemption,legacy_recovery}'
    WHERE jsonb_typeof(identity.metadata) = 'object'
      AND jsonb_typeof(identity.metadata -> 'saved_reset_redemption') = 'object'
      AND identity.metadata #>> '{saved_reset_redemption,status}' = 'redeeming'
      AND identity.metadata #>> '{saved_reset_redemption,phase}' = 'consuming'
      AND NOT (identity.metadata -> 'saved_reset_redemption' ? 'provider_replay')
      AND identity.metadata #> '{saved_reset_redemption,legacy_recovery}' =
        '{"version": 1, "state": "unresolved"}'::jsonb
    """
  end
end
