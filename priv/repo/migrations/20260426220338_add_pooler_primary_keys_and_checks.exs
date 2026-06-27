defmodule CodexPooler.Repo.Migrations.AddPoolerPrimaryKeysAndChecks do
  use Ecto.Migration

  # Migration lifecycle note:
  # A generated 20260426220333 monolithic bootstrap migration briefly existed before
  # this schema was split into the 20260426220335-20260426220340 cluster. That
  # monolithic file is intentionally absent from the repository, but early local or
  # pre-release databases may still have its version recorded in schema_migrations.
  # Keep this guard so those databases skip duplicate DDL while fresh installs run
  # the split migrations normally.
  @monolithic_migration_version "20260426220333"

  def up do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      ALTER TABLE ONLY public.account_quota_windows
      ADD CONSTRAINT account_quota_windows_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.api_key_policy_bindings
      ADD CONSTRAINT api_key_policy_bindings_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.api_keys
      ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.attempts
      ADD CONSTRAINT attempts_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.audit_events
      ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.bridge_affinities
      ADD CONSTRAINT bridge_affinities_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.bridge_demotions
      ADD CONSTRAINT bridge_demotions_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.bridge_owner_leases
      ADD CONSTRAINT bridge_owner_leases_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.bridge_session_aliases
      ADD CONSTRAINT bridge_session_aliases_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.codex_file_uploads
      ADD CONSTRAINT codex_file_uploads_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.codex_files
      ADD CONSTRAINT codex_files_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.codex_sessions
      ADD CONSTRAINT codex_sessions_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.codex_turns
      ADD CONSTRAINT codex_turns_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.daily_rollups
      ADD CONSTRAINT daily_rollups_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.encrypted_secrets
      ADD CONSTRAINT encrypted_secrets_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.gateway_idempotency_keys
      ADD CONSTRAINT gateway_idempotency_keys_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.invite_redemptions
      ADD CONSTRAINT invite_redemptions_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.invites
      ADD CONSTRAINT invites_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.memberships
      ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.models
      ADD CONSTRAINT models_pkey PRIMARY KEY (id);

      ALTER TABLE public.oban_jobs
      ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0));

      ALTER TABLE ONLY public.oban_jobs
      ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.oban_peers
      ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);

      ALTER TABLE ONLY public.platform_bootstrap_state
      ADD CONSTRAINT platform_bootstrap_state_pkey PRIMARY KEY (singleton);

      ALTER TABLE ONLY public.pool_routing_settings
      ADD CONSTRAINT pool_routing_settings_pkey PRIMARY KEY (pool_id);

      ALTER TABLE ONLY public.pool_upstream_assignments
      ADD CONSTRAINT pool_upstream_assignments_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.pools
      ADD CONSTRAINT pools_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.pricing_snapshots
      ADD CONSTRAINT pricing_snapshots_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.recovery_codes
      ADD CONSTRAINT recovery_codes_pkey PRIMARY KEY (id);

      ALTER TABLE public.requests
      ADD CONSTRAINT requests_endpoint_check CHECK ((endpoint = ANY (ARRAY['/backend-api/codex/models'::text, '/backend-api/codex/responses'::text, '/backend-api/codex/responses/compact'::text, '/backend-api/transcribe'::text, '/backend-api/files'::text, '/backend-api/files/uploaded'::text, '/api/codex/usage'::text])));

      ALTER TABLE ONLY public.requests
      ADD CONSTRAINT requests_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.routing_circuit_states
      ADD CONSTRAINT routing_circuit_states_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.sessions
      ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.sync_runs
      ADD CONSTRAINT sync_runs_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.totp_settings
      ADD CONSTRAINT totp_settings_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.totp_settings
      ADD CONSTRAINT totp_settings_user_id_key UNIQUE (user_id);

      ALTER TABLE ONLY public.upstream_identities
      ADD CONSTRAINT upstream_identities_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.users
      ADD CONSTRAINT users_pkey PRIMARY KEY (id);
      """)
    end
  end

  def down do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      ALTER TABLE IF EXISTS public.users DROP CONSTRAINT IF EXISTS users_pkey;
      ALTER TABLE IF EXISTS public.upstream_identities DROP CONSTRAINT IF EXISTS upstream_identities_pkey;
      ALTER TABLE IF EXISTS public.totp_settings DROP CONSTRAINT IF EXISTS totp_settings_user_id_key;
      ALTER TABLE IF EXISTS public.totp_settings DROP CONSTRAINT IF EXISTS totp_settings_pkey;
      ALTER TABLE IF EXISTS public.sync_runs DROP CONSTRAINT IF EXISTS sync_runs_pkey;
      ALTER TABLE IF EXISTS public.sessions DROP CONSTRAINT IF EXISTS sessions_pkey;
      ALTER TABLE IF EXISTS public.routing_circuit_states DROP CONSTRAINT IF EXISTS routing_circuit_states_pkey;
      ALTER TABLE IF EXISTS public.requests DROP CONSTRAINT IF EXISTS requests_pkey;
      ALTER TABLE IF EXISTS public.requests DROP CONSTRAINT IF EXISTS requests_endpoint_check;
      ALTER TABLE IF EXISTS public.recovery_codes DROP CONSTRAINT IF EXISTS recovery_codes_pkey;
      ALTER TABLE IF EXISTS public.pricing_snapshots DROP CONSTRAINT IF EXISTS pricing_snapshots_pkey;
      ALTER TABLE IF EXISTS public.pools DROP CONSTRAINT IF EXISTS pools_pkey;
      ALTER TABLE IF EXISTS public.pool_upstream_assignments DROP CONSTRAINT IF EXISTS pool_upstream_assignments_pkey;
      ALTER TABLE IF EXISTS public.pool_routing_settings DROP CONSTRAINT IF EXISTS pool_routing_settings_pkey;
      ALTER TABLE IF EXISTS public.platform_bootstrap_state DROP CONSTRAINT IF EXISTS platform_bootstrap_state_pkey;
      ALTER TABLE IF EXISTS public.oban_peers DROP CONSTRAINT IF EXISTS oban_peers_pkey;
      ALTER TABLE IF EXISTS public.oban_jobs DROP CONSTRAINT IF EXISTS oban_jobs_pkey;
      ALTER TABLE IF EXISTS public.oban_jobs DROP CONSTRAINT IF EXISTS non_negative_priority;
      ALTER TABLE IF EXISTS public.models DROP CONSTRAINT IF EXISTS models_pkey;
      ALTER TABLE IF EXISTS public.memberships DROP CONSTRAINT IF EXISTS memberships_pkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_pkey;
      ALTER TABLE IF EXISTS public.invites DROP CONSTRAINT IF EXISTS invites_pkey;
      ALTER TABLE IF EXISTS public.invite_redemptions DROP CONSTRAINT IF EXISTS invite_redemptions_pkey;
      ALTER TABLE IF EXISTS public.gateway_idempotency_keys DROP CONSTRAINT IF EXISTS gateway_idempotency_keys_pkey;
      ALTER TABLE IF EXISTS public.encrypted_secrets DROP CONSTRAINT IF EXISTS encrypted_secrets_pkey;
      ALTER TABLE IF EXISTS public.daily_rollups DROP CONSTRAINT IF EXISTS daily_rollups_pkey;
      ALTER TABLE IF EXISTS public.codex_turns DROP CONSTRAINT IF EXISTS codex_turns_pkey;
      ALTER TABLE IF EXISTS public.codex_sessions DROP CONSTRAINT IF EXISTS codex_sessions_pkey;
      ALTER TABLE IF EXISTS public.codex_files DROP CONSTRAINT IF EXISTS codex_files_pkey;
      ALTER TABLE IF EXISTS public.codex_file_uploads DROP CONSTRAINT IF EXISTS codex_file_uploads_pkey;
      ALTER TABLE IF EXISTS public.bridge_session_aliases DROP CONSTRAINT IF EXISTS bridge_session_aliases_pkey;
      ALTER TABLE IF EXISTS public.bridge_owner_leases DROP CONSTRAINT IF EXISTS bridge_owner_leases_pkey;
      ALTER TABLE IF EXISTS public.bridge_demotions DROP CONSTRAINT IF EXISTS bridge_demotions_pkey;
      ALTER TABLE IF EXISTS public.bridge_affinities DROP CONSTRAINT IF EXISTS bridge_affinities_pkey;
      ALTER TABLE IF EXISTS public.audit_events DROP CONSTRAINT IF EXISTS audit_events_pkey;
      ALTER TABLE IF EXISTS public.attempts DROP CONSTRAINT IF EXISTS attempts_pkey;
      ALTER TABLE IF EXISTS public.api_keys DROP CONSTRAINT IF EXISTS api_keys_pkey;
      ALTER TABLE IF EXISTS public.api_key_policy_bindings DROP CONSTRAINT IF EXISTS api_key_policy_bindings_pkey;
      ALTER TABLE IF EXISTS public.account_quota_windows DROP CONSTRAINT IF EXISTS account_quota_windows_pkey;
      """)
    end
  end

  defp monolithic_migration_applied? do
    %{num_rows: rows} =
      repo().query!("SELECT 1 FROM schema_migrations WHERE version::text = $1", [
        @monolithic_migration_version
      ])

    rows > 0
  end

  defp execute_statements(sql) do
    sql
    |> statements()
    |> Enum.each(&execute/1)
  end

  defp statements(sql) do
    sql
    |> String.split(~r/; *\n/,
      trim: true
    )
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
