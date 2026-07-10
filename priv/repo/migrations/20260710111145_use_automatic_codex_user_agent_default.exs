defmodule CodexPooler.Repo.Migrations.UseAutomaticCodexUserAgentDefault do
  use Ecto.Migration

  @automatic_user_agent "auto"
  @legacy_user_agent "codex_cli_rs/0.0.0"

  def up do
    execute("""
    UPDATE instance_settings
    SET gateway = jsonb_set(
      COALESCE(gateway, '{}'::jsonb),
      '{upstream_user_agent}',
      to_jsonb('#{@automatic_user_agent}'::text),
      true
    )
    WHERE gateway ->> 'upstream_user_agent' = '#{@legacy_user_agent}'
    """)

    alter table(:instance_settings) do
      modify :gateway, :map,
        null: false,
        default: fragment(~s('{"upstream_user_agent": "#{@automatic_user_agent}"}'::jsonb))
    end
  end

  def down do
    execute("""
    UPDATE instance_settings
    SET gateway = jsonb_set(
      COALESCE(gateway, '{}'::jsonb),
      '{upstream_user_agent}',
      to_jsonb('#{@legacy_user_agent}'::text),
      true
    )
    WHERE gateway ->> 'upstream_user_agent' = '#{@automatic_user_agent}'
    """)

    alter table(:instance_settings) do
      modify :gateway, :map,
        null: false,
        default: fragment(~s('{"upstream_user_agent": "#{@legacy_user_agent}"}'::jsonb))
    end
  end
end
