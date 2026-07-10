defmodule CodexPooler.Repo.Migrations.RemoveUpstreamUserAgentOverride do
  use Ecto.Migration

  @automatic_user_agent "auto"

  def up do
    execute("""
    UPDATE instance_settings
    SET gateway = COALESCE(gateway, '{}'::jsonb) - 'upstream_user_agent'
    """)

    alter table(:instance_settings) do
      modify :gateway, :map, null: false, default: fragment("'{}'::jsonb")
    end
  end

  def down do
    execute("""
    UPDATE instance_settings
    SET gateway = jsonb_set(
      COALESCE(gateway, '{}'::jsonb),
      '{upstream_user_agent}',
      to_jsonb('#{@automatic_user_agent}'::text),
      true
    )
    """)

    alter table(:instance_settings) do
      modify :gateway, :map,
        null: false,
        default: fragment(~s('{"upstream_user_agent": "#{@automatic_user_agent}"}'::jsonb))
    end
  end
end
