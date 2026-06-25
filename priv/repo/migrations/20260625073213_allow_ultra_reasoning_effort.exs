defmodule CodexPooler.Repo.Migrations.AllowUltraReasoningEffort do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_reasoning_effort_check
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_reasoning_effort_check
    CHECK (enforced_reasoning_effort IS NULL OR enforced_reasoning_effort = ANY (ARRAY['minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text, 'max'::text, 'ultra'::text]))
    """
  end

  def down do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_reasoning_effort_check
    """

    execute """
    UPDATE api_keys
    SET enforced_reasoning_effort = NULL
    WHERE enforced_reasoning_effort = 'ultra'
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_reasoning_effort_check
    CHECK (enforced_reasoning_effort IS NULL OR enforced_reasoning_effort = ANY (ARRAY['minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text, 'max'::text]))
    """
  end
end
