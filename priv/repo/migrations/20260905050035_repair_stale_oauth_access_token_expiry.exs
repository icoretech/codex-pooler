defmodule CodexPooler.Repo.Migrations.RepairStaleOauthAccessTokenExpiry do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '15s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    UPDATE public.upstream_identities
    SET metadata = (metadata - 'access_token_expires_at') - 'secret_expires_at'
    WHERE jsonb_typeof(metadata) = 'object'
      AND jsonb_typeof(metadata -> 'token_refresh') = 'object'
      AND metadata -> 'token_refresh' ->> 'status' = 'imported'
      AND metadata -> 'token_refresh' ->> 'trigger_kind'
        IN ('oauth_browser_link', 'oauth_device_link')
      AND NOT ((metadata -> 'token_refresh') ? 'access_token_expiry')
      AND (metadata ? 'access_token_expires_at' OR metadata ? 'secret_expires_at')
    """)
  end

  def down, do: :ok
end
