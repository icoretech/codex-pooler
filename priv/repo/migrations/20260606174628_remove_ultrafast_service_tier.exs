defmodule CodexPooler.Repo.Migrations.RemoveUltrafastServiceTier do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_service_tier_check
    """

    execute """
    UPDATE api_keys
    SET enforced_service_tier = NULL
    WHERE enforced_service_tier = 'ultrafast'
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_service_tier_check
    CHECK (enforced_service_tier IS NULL OR enforced_service_tier = ANY (ARRAY['auto'::text, 'default'::text, 'flex'::text, 'priority'::text, 'scale'::text]))
    """
  end

  def down do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_service_tier_check
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_service_tier_check
    CHECK (enforced_service_tier IS NULL OR enforced_service_tier = ANY (ARRAY['auto'::text, 'default'::text, 'flex'::text, 'priority'::text, 'ultrafast'::text]))
    """
  end
end
