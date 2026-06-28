defmodule CodexPooler.Repo.Migrations.AddPoolerForeignKeysAndBootstrapSeed do
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
      ADD CONSTRAINT account_quota_windows_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.api_key_policy_bindings
      ADD CONSTRAINT api_key_policy_bindings_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.api_keys
      ADD CONSTRAINT api_keys_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.api_keys
      ADD CONSTRAINT api_keys_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.attempts
      ADD CONSTRAINT attempts_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id);

      ALTER TABLE ONLY public.attempts
      ADD CONSTRAINT attempts_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.attempts
      ADD CONSTRAINT attempts_pricing_snapshot_id_fkey FOREIGN KEY (pricing_snapshot_id) REFERENCES public.pricing_snapshots(id);

      ALTER TABLE ONLY public.attempts
      ADD CONSTRAINT attempts_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.attempts
      ADD CONSTRAINT attempts_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.audit_events
      ADD CONSTRAINT audit_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.audit_events
      ADD CONSTRAINT audit_events_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.audit_events
      ADD CONSTRAINT audit_events_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.bridge_affinities
      ADD CONSTRAINT bridge_affinities_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_affinities
      ADD CONSTRAINT bridge_affinities_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_affinities
      ADD CONSTRAINT bridge_affinities_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_affinities
      ADD CONSTRAINT bridge_affinities_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.bridge_demotions
      ADD CONSTRAINT bridge_demotions_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_demotions
      ADD CONSTRAINT bridge_demotions_last_request_id_fkey FOREIGN KEY (last_request_id) REFERENCES public.requests(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.bridge_demotions
      ADD CONSTRAINT bridge_demotions_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_demotions
      ADD CONSTRAINT bridge_demotions_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_demotions
      ADD CONSTRAINT bridge_demotions_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.bridge_owner_leases
      ADD CONSTRAINT bridge_owner_leases_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_owner_leases
      ADD CONSTRAINT bridge_owner_leases_codex_session_id_fkey FOREIGN KEY (codex_session_id) REFERENCES public.codex_sessions(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_owner_leases
      ADD CONSTRAINT bridge_owner_leases_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_owner_leases
      ADD CONSTRAINT bridge_owner_leases_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.bridge_session_aliases
      ADD CONSTRAINT bridge_session_aliases_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_session_aliases
      ADD CONSTRAINT bridge_session_aliases_codex_session_id_fkey FOREIGN KEY (codex_session_id) REFERENCES public.codex_sessions(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.bridge_session_aliases
      ADD CONSTRAINT bridge_session_aliases_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_file_uploads
      ADD CONSTRAINT codex_file_uploads_codex_file_id_fkey FOREIGN KEY (codex_file_id) REFERENCES public.codex_files(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_files
      ADD CONSTRAINT codex_files_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_files
      ADD CONSTRAINT codex_files_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_files
      ADD CONSTRAINT codex_files_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.codex_sessions
      ADD CONSTRAINT codex_sessions_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_sessions
      ADD CONSTRAINT codex_sessions_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_sessions
      ADD CONSTRAINT codex_sessions_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_turns
      ADD CONSTRAINT codex_turns_codex_session_id_fkey FOREIGN KEY (codex_session_id) REFERENCES public.codex_sessions(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.codex_turns
      ADD CONSTRAINT codex_turns_final_attempt_id_request_id_fkey FOREIGN KEY (final_attempt_id, request_id) REFERENCES public.attempts(id, request_id);

      ALTER TABLE ONLY public.codex_turns
      ADD CONSTRAINT codex_turns_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.daily_rollups
      ADD CONSTRAINT daily_rollups_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.daily_rollups
      ADD CONSTRAINT daily_rollups_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.daily_rollups
      ADD CONSTRAINT daily_rollups_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.daily_rollups
      ADD CONSTRAINT daily_rollups_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.daily_rollups
      ADD CONSTRAINT daily_rollups_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.encrypted_secrets
      ADD CONSTRAINT encrypted_secrets_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.gateway_idempotency_keys
      ADD CONSTRAINT gateway_idempotency_keys_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.gateway_idempotency_keys
      ADD CONSTRAINT gateway_idempotency_keys_codex_file_id_fkey FOREIGN KEY (codex_file_id) REFERENCES public.codex_files(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.gateway_idempotency_keys
      ADD CONSTRAINT gateway_idempotency_keys_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.gateway_idempotency_keys
      ADD CONSTRAINT gateway_idempotency_keys_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.invite_redemptions
      ADD CONSTRAINT invite_redemptions_invite_id_fkey FOREIGN KEY (invite_id) REFERENCES public.invites(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.invite_redemptions
      ADD CONSTRAINT invite_redemptions_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.invite_redemptions
      ADD CONSTRAINT invite_redemptions_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.invite_redemptions
      ADD CONSTRAINT invite_redemptions_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.invites
      ADD CONSTRAINT invites_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.invites
      ADD CONSTRAINT invites_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.attempts(id);

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_correction_of_entry_id_fkey FOREIGN KEY (correction_of_entry_id) REFERENCES public.ledger_entries(id);

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id);

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_pricing_snapshot_id_fkey FOREIGN KEY (pricing_snapshot_id) REFERENCES public.pricing_snapshots(id);

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.ledger_entries
      ADD CONSTRAINT ledger_entries_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.memberships
      ADD CONSTRAINT memberships_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.memberships
      ADD CONSTRAINT memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.models
      ADD CONSTRAINT models_last_sync_run_id_fkey FOREIGN KEY (last_sync_run_id) REFERENCES public.sync_runs(id);

      ALTER TABLE ONLY public.models
      ADD CONSTRAINT models_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.platform_bootstrap_state
      ADD CONSTRAINT platform_bootstrap_state_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.pool_routing_settings
      ADD CONSTRAINT pool_routing_settings_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.pool_upstream_assignments
      ADD CONSTRAINT pool_upstream_assignments_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.pool_upstream_assignments
      ADD CONSTRAINT pool_upstream_assignments_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.pool_upstream_assignments
      ADD CONSTRAINT pool_upstream_assignments_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.pools
      ADD CONSTRAINT pools_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.recovery_codes
      ADD CONSTRAINT recovery_codes_totp_setting_id_fkey FOREIGN KEY (totp_setting_id) REFERENCES public.totp_settings(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.recovery_codes
      ADD CONSTRAINT recovery_codes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.requests
      ADD CONSTRAINT requests_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.requests
      ADD CONSTRAINT requests_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id);

      ALTER TABLE ONLY public.requests
      ADD CONSTRAINT requests_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.routing_circuit_states
      ADD CONSTRAINT routing_circuit_states_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.routing_circuit_states
      ADD CONSTRAINT routing_circuit_states_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.routing_circuit_states
      ADD CONSTRAINT routing_circuit_states_pool_upstream_assignment_id_fkey FOREIGN KEY (pool_upstream_assignment_id) REFERENCES public.pool_upstream_assignments(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.routing_circuit_states
      ADD CONSTRAINT routing_circuit_states_upstream_identity_id_fkey FOREIGN KEY (upstream_identity_id) REFERENCES public.upstream_identities(id) ON DELETE SET NULL;

      ALTER TABLE ONLY public.sessions
      ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.sync_runs
      ADD CONSTRAINT sync_runs_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES public.pools(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.totp_settings
      ADD CONSTRAINT totp_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

      ALTER TABLE ONLY public.upstream_identities
      ADD CONSTRAINT upstream_identities_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);

      INSERT INTO public.platform_bootstrap_state (singleton, status) VALUES (TRUE, 'pending');;
      """)
    end
  end

  def down do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      DELETE FROM public.platform_bootstrap_state WHERE singleton = TRUE AND status = 'pending';
      ALTER TABLE IF EXISTS public.upstream_identities DROP CONSTRAINT IF EXISTS upstream_identities_created_by_user_id_fkey;
      ALTER TABLE IF EXISTS public.totp_settings DROP CONSTRAINT IF EXISTS totp_settings_user_id_fkey;
      ALTER TABLE IF EXISTS public.sync_runs DROP CONSTRAINT IF EXISTS sync_runs_pool_id_fkey;
      ALTER TABLE IF EXISTS public.sessions DROP CONSTRAINT IF EXISTS sessions_user_id_fkey;
      ALTER TABLE IF EXISTS public.routing_circuit_states DROP CONSTRAINT IF EXISTS routing_circuit_states_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.routing_circuit_states DROP CONSTRAINT IF EXISTS routing_circuit_states_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.routing_circuit_states DROP CONSTRAINT IF EXISTS routing_circuit_states_pool_id_fkey;
      ALTER TABLE IF EXISTS public.routing_circuit_states DROP CONSTRAINT IF EXISTS routing_circuit_states_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.requests DROP CONSTRAINT IF EXISTS requests_pool_id_fkey;
      ALTER TABLE IF EXISTS public.requests DROP CONSTRAINT IF EXISTS requests_model_id_fkey;
      ALTER TABLE IF EXISTS public.requests DROP CONSTRAINT IF EXISTS requests_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.recovery_codes DROP CONSTRAINT IF EXISTS recovery_codes_user_id_fkey;
      ALTER TABLE IF EXISTS public.recovery_codes DROP CONSTRAINT IF EXISTS recovery_codes_totp_setting_id_fkey;
      ALTER TABLE IF EXISTS public.pools DROP CONSTRAINT IF EXISTS pools_created_by_user_id_fkey;
      ALTER TABLE IF EXISTS public.pool_upstream_assignments DROP CONSTRAINT IF EXISTS pool_upstream_assignments_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.pool_upstream_assignments DROP CONSTRAINT IF EXISTS pool_upstream_assignments_pool_id_fkey;
      ALTER TABLE IF EXISTS public.pool_upstream_assignments DROP CONSTRAINT IF EXISTS pool_upstream_assignments_created_by_user_id_fkey;
      ALTER TABLE IF EXISTS public.pool_routing_settings DROP CONSTRAINT IF EXISTS pool_routing_settings_pool_id_fkey;
      ALTER TABLE IF EXISTS public.platform_bootstrap_state DROP CONSTRAINT IF EXISTS platform_bootstrap_state_owner_user_id_fkey;
      ALTER TABLE IF EXISTS public.models DROP CONSTRAINT IF EXISTS models_pool_id_fkey;
      ALTER TABLE IF EXISTS public.models DROP CONSTRAINT IF EXISTS models_last_sync_run_id_fkey;
      ALTER TABLE IF EXISTS public.memberships DROP CONSTRAINT IF EXISTS memberships_user_id_fkey;
      ALTER TABLE IF EXISTS public.memberships DROP CONSTRAINT IF EXISTS memberships_created_by_user_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_request_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_pricing_snapshot_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_pool_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_model_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_correction_of_entry_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_attempt_id_fkey;
      ALTER TABLE IF EXISTS public.ledger_entries DROP CONSTRAINT IF EXISTS ledger_entries_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.invites DROP CONSTRAINT IF EXISTS invites_pool_id_fkey;
      ALTER TABLE IF EXISTS public.invites DROP CONSTRAINT IF EXISTS invites_created_by_user_id_fkey;
      ALTER TABLE IF EXISTS public.invite_redemptions DROP CONSTRAINT IF EXISTS invite_redemptions_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.invite_redemptions DROP CONSTRAINT IF EXISTS invite_redemptions_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.invite_redemptions DROP CONSTRAINT IF EXISTS invite_redemptions_pool_id_fkey;
      ALTER TABLE IF EXISTS public.invite_redemptions DROP CONSTRAINT IF EXISTS invite_redemptions_invite_id_fkey;
      ALTER TABLE IF EXISTS public.gateway_idempotency_keys DROP CONSTRAINT IF EXISTS gateway_idempotency_keys_request_id_fkey;
      ALTER TABLE IF EXISTS public.gateway_idempotency_keys DROP CONSTRAINT IF EXISTS gateway_idempotency_keys_pool_id_fkey;
      ALTER TABLE IF EXISTS public.gateway_idempotency_keys DROP CONSTRAINT IF EXISTS gateway_idempotency_keys_codex_file_id_fkey;
      ALTER TABLE IF EXISTS public.gateway_idempotency_keys DROP CONSTRAINT IF EXISTS gateway_idempotency_keys_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.encrypted_secrets DROP CONSTRAINT IF EXISTS encrypted_secrets_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.daily_rollups DROP CONSTRAINT IF EXISTS daily_rollups_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.daily_rollups DROP CONSTRAINT IF EXISTS daily_rollups_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.daily_rollups DROP CONSTRAINT IF EXISTS daily_rollups_pool_id_fkey;
      ALTER TABLE IF EXISTS public.daily_rollups DROP CONSTRAINT IF EXISTS daily_rollups_model_id_fkey;
      ALTER TABLE IF EXISTS public.daily_rollups DROP CONSTRAINT IF EXISTS daily_rollups_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.codex_turns DROP CONSTRAINT IF EXISTS codex_turns_request_id_fkey;
      ALTER TABLE IF EXISTS public.codex_turns DROP CONSTRAINT IF EXISTS codex_turns_final_attempt_id_request_id_fkey;
      ALTER TABLE IF EXISTS public.codex_turns DROP CONSTRAINT IF EXISTS codex_turns_codex_session_id_fkey;
      ALTER TABLE IF EXISTS public.codex_sessions DROP CONSTRAINT IF EXISTS codex_sessions_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.codex_sessions DROP CONSTRAINT IF EXISTS codex_sessions_pool_id_fkey;
      ALTER TABLE IF EXISTS public.codex_sessions DROP CONSTRAINT IF EXISTS codex_sessions_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.codex_files DROP CONSTRAINT IF EXISTS codex_files_request_id_fkey;
      ALTER TABLE IF EXISTS public.codex_files DROP CONSTRAINT IF EXISTS codex_files_pool_id_fkey;
      ALTER TABLE IF EXISTS public.codex_files DROP CONSTRAINT IF EXISTS codex_files_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.codex_file_uploads DROP CONSTRAINT IF EXISTS codex_file_uploads_codex_file_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_session_aliases DROP CONSTRAINT IF EXISTS bridge_session_aliases_pool_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_session_aliases DROP CONSTRAINT IF EXISTS bridge_session_aliases_codex_session_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_session_aliases DROP CONSTRAINT IF EXISTS bridge_session_aliases_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_owner_leases DROP CONSTRAINT IF EXISTS bridge_owner_leases_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_owner_leases DROP CONSTRAINT IF EXISTS bridge_owner_leases_pool_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_owner_leases DROP CONSTRAINT IF EXISTS bridge_owner_leases_codex_session_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_owner_leases DROP CONSTRAINT IF EXISTS bridge_owner_leases_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_demotions DROP CONSTRAINT IF EXISTS bridge_demotions_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_demotions DROP CONSTRAINT IF EXISTS bridge_demotions_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_demotions DROP CONSTRAINT IF EXISTS bridge_demotions_pool_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_demotions DROP CONSTRAINT IF EXISTS bridge_demotions_last_request_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_demotions DROP CONSTRAINT IF EXISTS bridge_demotions_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_affinities DROP CONSTRAINT IF EXISTS bridge_affinities_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_affinities DROP CONSTRAINT IF EXISTS bridge_affinities_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_affinities DROP CONSTRAINT IF EXISTS bridge_affinities_pool_id_fkey;
      ALTER TABLE IF EXISTS public.bridge_affinities DROP CONSTRAINT IF EXISTS bridge_affinities_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.audit_events DROP CONSTRAINT IF EXISTS audit_events_request_id_fkey;
      ALTER TABLE IF EXISTS public.audit_events DROP CONSTRAINT IF EXISTS audit_events_pool_id_fkey;
      ALTER TABLE IF EXISTS public.audit_events DROP CONSTRAINT IF EXISTS audit_events_actor_user_id_fkey;
      ALTER TABLE IF EXISTS public.attempts DROP CONSTRAINT IF EXISTS attempts_upstream_identity_id_fkey;
      ALTER TABLE IF EXISTS public.attempts DROP CONSTRAINT IF EXISTS attempts_request_id_fkey;
      ALTER TABLE IF EXISTS public.attempts DROP CONSTRAINT IF EXISTS attempts_pricing_snapshot_id_fkey;
      ALTER TABLE IF EXISTS public.attempts DROP CONSTRAINT IF EXISTS attempts_pool_upstream_assignment_id_fkey;
      ALTER TABLE IF EXISTS public.attempts DROP CONSTRAINT IF EXISTS attempts_model_id_fkey;
      ALTER TABLE IF EXISTS public.api_keys DROP CONSTRAINT IF EXISTS api_keys_pool_id_fkey;
      ALTER TABLE IF EXISTS public.api_keys DROP CONSTRAINT IF EXISTS api_keys_created_by_user_id_fkey;
      ALTER TABLE IF EXISTS public.api_key_policy_bindings DROP CONSTRAINT IF EXISTS api_key_policy_bindings_api_key_id_fkey;
      ALTER TABLE IF EXISTS public.account_quota_windows DROP CONSTRAINT IF EXISTS account_quota_windows_upstream_identity_id_fkey;
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
