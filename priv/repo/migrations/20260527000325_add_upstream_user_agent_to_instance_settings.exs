defmodule CodexPooler.Repo.Migrations.AddUpstreamUserAgentToInstanceSettings do
  use Ecto.Migration

  @default_upstream_user_agent "codex_cli_rs/0.0.0"

  def up do
    execute("""
    UPDATE instance_settings
    SET gateway = jsonb_set(
      COALESCE(gateway, '{}'::jsonb),
      '{upstream_user_agent}',
      to_jsonb('#{@default_upstream_user_agent}'::text),
      true
    )
    WHERE NOT COALESCE(gateway, '{}'::jsonb) ? 'upstream_user_agent'
    """)

    alter table(:instance_settings) do
      modify :gateway, :map,
        null: false,
        default: fragment(~s('{"upstream_user_agent": "#{@default_upstream_user_agent}"}'::jsonb))
    end
  end

  def down do
    execute("""
    UPDATE instance_settings
    SET gateway = COALESCE(gateway, '{}'::jsonb) - 'upstream_user_agent'
    """)

    alter table(:instance_settings) do
      modify :gateway, :map, null: false, default: fragment("'{}'::jsonb")
    end
  end
end
