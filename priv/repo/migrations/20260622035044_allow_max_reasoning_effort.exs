defmodule CodexPooler.Repo.Migrations.AllowMaxReasoningEffort do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_reasoning_effort_check
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_reasoning_effort_check
    CHECK (enforced_reasoning_effort IS NULL OR enforced_reasoning_effort = ANY (ARRAY['minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text, 'max'::text]))
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
    WHERE enforced_reasoning_effort = 'max'
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_reasoning_effort_check
    CHECK (enforced_reasoning_effort IS NULL OR enforced_reasoning_effort = ANY (ARRAY['minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text]))
    """
  end
end
