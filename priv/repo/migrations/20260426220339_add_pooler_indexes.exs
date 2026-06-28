defmodule CodexPooler.Repo.Migrations.AddPoolerIndexes do
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
      CREATE UNIQUE INDEX account_quota_windows_evidence_identity_uq ON public.account_quota_windows USING btree (upstream_identity_id, quota_scope, quota_family, COALESCE(lower(model), ''::text), COALESCE(lower(upstream_model), ''::text), quota_key, window_kind, window_minutes, source, COALESCE(raw_limit_id, ''::text), COALESCE(raw_limit_name, ''::text), COALESCE(raw_metered_feature, ''::text));

      CREATE INDEX account_quota_windows_freshness_idx ON public.account_quota_windows USING btree (window_kind, freshness_state, last_sync_at DESC);

      CREATE INDEX account_quota_windows_identity_sync_idx ON public.account_quota_windows USING btree (upstream_identity_id, last_sync_at DESC);

      CREATE INDEX account_quota_windows_merge_idx ON public.account_quota_windows USING btree (upstream_identity_id, quota_scope, quota_family, quota_key, window_kind, merge_precedence DESC, observed_at DESC);

      CREATE INDEX account_quota_windows_quota_freshness_idx ON public.account_quota_windows USING btree (quota_key, freshness_state, last_sync_at DESC);

      CREATE UNIQUE INDEX api_key_policy_default_active_uq ON public.api_key_policy_bindings USING btree (api_key_id) WHERE ((binding_scope = 'default'::text) AND (status = 'active'::text));

      CREATE UNIQUE INDEX api_key_policy_model_active_uq ON public.api_key_policy_bindings USING btree (api_key_id, lower(model_identifier)) WHERE ((binding_scope = 'model'::text) AND (status = 'active'::text));

      CREATE UNIQUE INDEX api_keys_hash_uq ON public.api_keys USING btree (key_hash);

      CREATE INDEX api_keys_pool_created_idx ON public.api_keys USING btree (pool_id, created_at DESC);

      CREATE UNIQUE INDEX api_keys_prefix_uq ON public.api_keys USING btree (key_prefix);

      CREATE INDEX attempts_assignment_started_idx ON public.attempts USING btree (pool_upstream_assignment_id, started_at DESC);

      CREATE UNIQUE INDEX attempts_id_request_id_uq ON public.attempts USING btree (id, request_id);

      CREATE UNIQUE INDEX attempts_request_number_uq ON public.attempts USING btree (request_id, attempt_number);

      CREATE INDEX audit_events_correlation_idx ON public.audit_events USING btree (correlation_id) WHERE (correlation_id IS NOT NULL);

      CREATE INDEX audit_events_scope_occurred_idx ON public.audit_events USING btree (pool_id, occurred_at DESC);

      CREATE UNIQUE INDEX bridge_affinities_active_key_uq ON public.bridge_affinities USING btree (pool_id, api_key_id, model_identifier, affinity_kind, affinity_key_hash) WHERE (status = 'active'::text);

      CREATE INDEX bridge_affinities_assignment_updated_idx ON public.bridge_affinities USING btree (pool_upstream_assignment_id, updated_at);

      CREATE UNIQUE INDEX bridge_demotions_active_assignment_uq ON public.bridge_demotions USING btree (pool_id, api_key_id, model_identifier, pool_upstream_assignment_id) WHERE (status = 'active'::text);

      CREATE INDEX bridge_demotions_pool_status_updated_idx ON public.bridge_demotions USING btree (pool_id, status, updated_at);

      CREATE UNIQUE INDEX bridge_owner_leases_active_session_uq ON public.bridge_owner_leases USING btree (codex_session_id) WHERE (status = 'active'::text);

      CREATE INDEX bridge_owner_leases_expiry_idx ON public.bridge_owner_leases USING btree (status, expires_at);

      CREATE INDEX bridge_owner_leases_owner_active_idx ON public.bridge_owner_leases USING btree (owner_instance_id, expires_at) WHERE (status = 'active'::text);

      CREATE UNIQUE INDEX bridge_owner_leases_token_uq ON public.bridge_owner_leases USING btree (lease_token);

      CREATE UNIQUE INDEX bridge_session_aliases_active_key_uq ON public.bridge_session_aliases USING btree (pool_id, api_key_id, alias_kind, alias_hash) WHERE (status = 'active'::text);

      CREATE INDEX bridge_session_aliases_expiry_idx ON public.bridge_session_aliases USING btree (status, expires_at);

      CREATE INDEX bridge_session_aliases_session_status_idx ON public.bridge_session_aliases USING btree (codex_session_id, status);

      CREATE INDEX codex_file_uploads_expiry_idx ON public.codex_file_uploads USING btree (status, expires_at);

      CREATE INDEX codex_file_uploads_file_created_idx ON public.codex_file_uploads USING btree (codex_file_id, created_at);

      CREATE UNIQUE INDEX codex_file_uploads_upload_key_uq ON public.codex_file_uploads USING btree (upload_key);

      CREATE INDEX codex_files_expiry_idx ON public.codex_files USING btree (status, expires_at);

      CREATE UNIQUE INDEX codex_files_file_id_uq ON public.codex_files USING btree (file_id);

      CREATE INDEX codex_files_owner_created_idx ON public.codex_files USING btree (pool_id, api_key_id, created_at);

      CREATE INDEX codex_files_upload_expiry_idx ON public.codex_files USING btree (status, upload_expires_at);

      CREATE INDEX codex_sessions_owner_active_idx ON public.codex_sessions USING btree (owner_instance_id, owner_lease_expires_at) WHERE (owner_instance_id IS NOT NULL);

      CREATE UNIQUE INDEX codex_sessions_owner_lease_token_uq ON public.codex_sessions USING btree (owner_lease_token) WHERE (owner_lease_token IS NOT NULL);

      CREATE UNIQUE INDEX codex_sessions_pool_conversation_key_uq ON public.codex_sessions USING btree (pool_id, lower(conversation_key)) WHERE ((conversation_key IS NOT NULL) AND (status = ANY (ARRAY['active'::text, 'interrupted'::text])));

      CREATE UNIQUE INDEX codex_sessions_pool_session_key_uq ON public.codex_sessions USING btree (pool_id, lower(session_key)) WHERE (status = ANY (ARRAY['active'::text, 'interrupted'::text]));

      CREATE INDEX codex_sessions_pool_status_updated_idx ON public.codex_sessions USING btree (pool_id, status, updated_at DESC);

      CREATE UNIQUE INDEX codex_turns_final_attempt_id_uq ON public.codex_turns USING btree (final_attempt_id) WHERE (final_attempt_id IS NOT NULL);

      CREATE UNIQUE INDEX codex_turns_request_id_uq ON public.codex_turns USING btree (request_id);

      CREATE UNIQUE INDEX codex_turns_session_sequence_uq ON public.codex_turns USING btree (codex_session_id, turn_sequence);

      CREATE INDEX codex_turns_session_started_idx ON public.codex_turns USING btree (codex_session_id, started_at DESC);

      CREATE INDEX codex_turns_status_started_idx ON public.codex_turns USING btree (status, started_at DESC);

      CREATE INDEX codex_turns_visible_output_idx ON public.codex_turns USING btree (first_visible_output_at) WHERE (first_visible_output_at IS NOT NULL);

      CREATE UNIQUE INDEX daily_rollups_api_key_uq ON public.daily_rollups USING btree (rollup_date, api_key_id) WHERE (dimension_kind = 'api_key'::text);

      CREATE UNIQUE INDEX daily_rollups_assignment_uq ON public.daily_rollups USING btree (rollup_date, pool_upstream_assignment_id) WHERE (dimension_kind = 'pool_upstream_assignment'::text);

      CREATE UNIQUE INDEX daily_rollups_identity_uq ON public.daily_rollups USING btree (rollup_date, upstream_identity_id) WHERE (dimension_kind = 'upstream_identity'::text);

      CREATE UNIQUE INDEX daily_rollups_model_uq ON public.daily_rollups USING btree (rollup_date, model_id) WHERE (dimension_kind = 'model'::text);

      CREATE UNIQUE INDEX daily_rollups_pool_uq ON public.daily_rollups USING btree (rollup_date, pool_id) WHERE (dimension_kind = 'pool'::text);

      CREATE UNIQUE INDEX encrypted_secrets_active_kind_uq ON public.encrypted_secrets USING btree (upstream_identity_id, secret_kind) WHERE (status = 'active'::text);

      CREATE UNIQUE INDEX gateway_idempotency_keys_active_key_uq ON public.gateway_idempotency_keys USING btree (api_key_id, scope, key_hash) WHERE (status = ANY (ARRAY['in_progress'::text, 'succeeded'::text]));

      CREATE INDEX gateway_idempotency_keys_expiry_idx ON public.gateway_idempotency_keys USING btree (status, expires_at);

      CREATE UNIQUE INDEX invite_redemptions_invite_identity_uq ON public.invite_redemptions USING btree (invite_id, upstream_identity_id);

      CREATE INDEX invite_redemptions_pool_consumed_idx ON public.invite_redemptions USING btree (pool_id, consumed_at DESC);

      CREATE INDEX invites_pool_status_idx ON public.invites USING btree (pool_id, status, created_at DESC);

      CREATE UNIQUE INDEX invites_token_hash_uq ON public.invites USING btree (token_hash);

      CREATE INDEX ledger_entries_pool_occurred_idx ON public.ledger_entries USING btree (pool_id, occurred_at DESC);

      CREATE INDEX ledger_entries_request_occurred_idx ON public.ledger_entries USING btree (request_id, occurred_at);

      CREATE UNIQUE INDEX ledger_entries_settlement_request_uq ON public.ledger_entries USING btree (request_id) WHERE ((entry_kind = 'settlement'::text) AND (amount_status = 'recorded'::text));

      CREATE UNIQUE INDEX ledger_entries_source_event_uq ON public.ledger_entries USING btree (source_event_id) WHERE (source_event_id IS NOT NULL);

      CREATE UNIQUE INDEX memberships_global_role_active_uq ON public.memberships USING btree (user_id, role) WHERE (status = 'active'::text);

      CREATE UNIQUE INDEX memberships_single_instance_owner_active_uq ON public.memberships USING btree (role) WHERE ((role = 'instance_owner'::text) AND (status = 'active'::text));

      CREATE INDEX memberships_user_active_idx ON public.memberships USING btree (user_id, created_at DESC) WHERE (status = 'active'::text);

      CREATE UNIQUE INDEX models_pool_exposed_uq ON public.models USING btree (pool_id, lower(exposed_model_id));

      CREATE INDEX models_pool_status_idx ON public.models USING btree (pool_id, status, last_seen_at DESC);

      CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);

      CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);

      CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);

      CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);

      CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);

      CREATE UNIQUE INDEX pool_upstream_assignments_identity_uq ON public.pool_upstream_assignments USING btree (pool_id, upstream_identity_id);

      CREATE INDEX pool_upstream_assignments_routing_idx ON public.pool_upstream_assignments USING btree (pool_id, status, eligibility_status, health_status, cooldown_until);

      CREATE UNIQUE INDEX pools_slug_uq ON public.pools USING btree (lower(slug));

      CREATE UNIQUE INDEX pricing_snapshots_version_uq ON public.pricing_snapshots USING btree (lower(model_identifier), price_version, COALESCE((config ->> 'service_tier'::text), ''::text), COALESCE((config ->> 'price_bucket'::text), ''::text));

      CREATE UNIQUE INDEX recovery_codes_hash_uq ON public.recovery_codes USING btree (code_hash);

      CREATE INDEX recovery_codes_user_active_idx ON public.recovery_codes USING btree (user_id, created_at DESC) WHERE (status = 'active'::text);

      CREATE UNIQUE INDEX requests_api_key_idempotency_uq ON public.requests USING btree (api_key_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);

      CREATE UNIQUE INDEX requests_correlation_id_uq ON public.requests USING btree (correlation_id);

      CREATE INDEX requests_pool_admitted_idx ON public.requests USING btree (pool_id, admitted_at DESC);

      CREATE INDEX requests_status_idx ON public.requests USING btree (status, admitted_at DESC);

      CREATE UNIQUE INDEX routing_circuit_states_active_assignment_uq ON public.routing_circuit_states USING btree (pool_id, pool_upstream_assignment_id, model_identifier, route_class) WHERE (status = ANY (ARRAY['open'::text, 'half_open'::text]));

      CREATE INDEX routing_circuit_states_assignment_probe_idx ON public.routing_circuit_states USING btree (pool_upstream_assignment_id, status, next_probe_at);

      CREATE INDEX routing_circuit_states_pool_status_updated_idx ON public.routing_circuit_states USING btree (pool_id, status, updated_at);

      CREATE UNIQUE INDEX sessions_token_hash_uq ON public.sessions USING btree (session_token_hash);

      CREATE INDEX sessions_user_active_idx ON public.sessions USING btree (user_id, created_at DESC) WHERE (status = 'active'::text);

      CREATE INDEX sync_runs_pool_started_idx ON public.sync_runs USING btree (pool_id, started_at DESC);

      CREATE UNIQUE INDEX upstream_identities_chatgpt_identity_uq ON public.upstream_identities USING btree (chatgpt_account_id) WHERE (chatgpt_account_id IS NOT NULL);

      CREATE UNIQUE INDEX users_email_active_uq ON public.users USING btree (lower(email)) WHERE (deleted_at IS NULL);
      """)
    end
  end

  def down do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      DROP INDEX IF EXISTS public.users_email_active_uq;
      DROP INDEX IF EXISTS public.upstream_identities_chatgpt_identity_uq;
      DROP INDEX IF EXISTS public.sync_runs_pool_started_idx;
      DROP INDEX IF EXISTS public.sessions_user_active_idx;
      DROP INDEX IF EXISTS public.sessions_token_hash_uq;
      DROP INDEX IF EXISTS public.routing_circuit_states_pool_status_updated_idx;
      DROP INDEX IF EXISTS public.routing_circuit_states_assignment_probe_idx;
      DROP INDEX IF EXISTS public.routing_circuit_states_active_assignment_uq;
      DROP INDEX IF EXISTS public.requests_status_idx;
      DROP INDEX IF EXISTS public.requests_pool_admitted_idx;
      DROP INDEX IF EXISTS public.requests_correlation_id_uq;
      DROP INDEX IF EXISTS public.requests_api_key_idempotency_uq;
      DROP INDEX IF EXISTS public.recovery_codes_user_active_idx;
      DROP INDEX IF EXISTS public.recovery_codes_hash_uq;
      DROP INDEX IF EXISTS public.pricing_snapshots_version_uq;
      DROP INDEX IF EXISTS public.pools_slug_uq;
      DROP INDEX IF EXISTS public.pool_upstream_assignments_routing_idx;
      DROP INDEX IF EXISTS public.pool_upstream_assignments_identity_uq;
      DROP INDEX IF EXISTS public.oban_jobs_state_queue_priority_scheduled_at_id_index;
      DROP INDEX IF EXISTS public.oban_jobs_state_discarded_at_index;
      DROP INDEX IF EXISTS public.oban_jobs_state_cancelled_at_index;
      DROP INDEX IF EXISTS public.oban_jobs_meta_index;
      DROP INDEX IF EXISTS public.oban_jobs_args_index;
      DROP INDEX IF EXISTS public.models_pool_status_idx;
      DROP INDEX IF EXISTS public.models_pool_exposed_uq;
      DROP INDEX IF EXISTS public.memberships_user_active_idx;
      DROP INDEX IF EXISTS public.memberships_single_instance_owner_active_uq;
      DROP INDEX IF EXISTS public.memberships_global_role_active_uq;
      DROP INDEX IF EXISTS public.ledger_entries_source_event_uq;
      DROP INDEX IF EXISTS public.ledger_entries_settlement_request_uq;
      DROP INDEX IF EXISTS public.ledger_entries_request_occurred_idx;
      DROP INDEX IF EXISTS public.ledger_entries_pool_occurred_idx;
      DROP INDEX IF EXISTS public.invites_token_hash_uq;
      DROP INDEX IF EXISTS public.invites_pool_status_idx;
      DROP INDEX IF EXISTS public.invite_redemptions_pool_consumed_idx;
      DROP INDEX IF EXISTS public.invite_redemptions_invite_identity_uq;
      DROP INDEX IF EXISTS public.gateway_idempotency_keys_expiry_idx;
      DROP INDEX IF EXISTS public.gateway_idempotency_keys_active_key_uq;
      DROP INDEX IF EXISTS public.encrypted_secrets_active_kind_uq;
      DROP INDEX IF EXISTS public.daily_rollups_pool_uq;
      DROP INDEX IF EXISTS public.daily_rollups_model_uq;
      DROP INDEX IF EXISTS public.daily_rollups_identity_uq;
      DROP INDEX IF EXISTS public.daily_rollups_assignment_uq;
      DROP INDEX IF EXISTS public.daily_rollups_api_key_uq;
      DROP INDEX IF EXISTS public.codex_turns_visible_output_idx;
      DROP INDEX IF EXISTS public.codex_turns_status_started_idx;
      DROP INDEX IF EXISTS public.codex_turns_session_started_idx;
      DROP INDEX IF EXISTS public.codex_turns_session_sequence_uq;
      DROP INDEX IF EXISTS public.codex_turns_request_id_uq;
      DROP INDEX IF EXISTS public.codex_turns_final_attempt_id_uq;
      DROP INDEX IF EXISTS public.codex_sessions_pool_status_updated_idx;
      DROP INDEX IF EXISTS public.codex_sessions_pool_session_key_uq;
      DROP INDEX IF EXISTS public.codex_sessions_pool_conversation_key_uq;
      DROP INDEX IF EXISTS public.codex_sessions_owner_lease_token_uq;
      DROP INDEX IF EXISTS public.codex_sessions_owner_active_idx;
      DROP INDEX IF EXISTS public.codex_files_upload_expiry_idx;
      DROP INDEX IF EXISTS public.codex_files_owner_created_idx;
      DROP INDEX IF EXISTS public.codex_files_file_id_uq;
      DROP INDEX IF EXISTS public.codex_files_expiry_idx;
      DROP INDEX IF EXISTS public.codex_file_uploads_upload_key_uq;
      DROP INDEX IF EXISTS public.codex_file_uploads_file_created_idx;
      DROP INDEX IF EXISTS public.codex_file_uploads_expiry_idx;
      DROP INDEX IF EXISTS public.bridge_session_aliases_session_status_idx;
      DROP INDEX IF EXISTS public.bridge_session_aliases_expiry_idx;
      DROP INDEX IF EXISTS public.bridge_session_aliases_active_key_uq;
      DROP INDEX IF EXISTS public.bridge_owner_leases_token_uq;
      DROP INDEX IF EXISTS public.bridge_owner_leases_owner_active_idx;
      DROP INDEX IF EXISTS public.bridge_owner_leases_expiry_idx;
      DROP INDEX IF EXISTS public.bridge_owner_leases_active_session_uq;
      DROP INDEX IF EXISTS public.bridge_demotions_pool_status_updated_idx;
      DROP INDEX IF EXISTS public.bridge_demotions_active_assignment_uq;
      DROP INDEX IF EXISTS public.bridge_affinities_assignment_updated_idx;
      DROP INDEX IF EXISTS public.bridge_affinities_active_key_uq;
      DROP INDEX IF EXISTS public.audit_events_scope_occurred_idx;
      DROP INDEX IF EXISTS public.audit_events_correlation_idx;
      DROP INDEX IF EXISTS public.attempts_request_number_uq;
      DROP INDEX IF EXISTS public.attempts_id_request_id_uq;
      DROP INDEX IF EXISTS public.attempts_assignment_started_idx;
      DROP INDEX IF EXISTS public.api_keys_prefix_uq;
      DROP INDEX IF EXISTS public.api_keys_pool_created_idx;
      DROP INDEX IF EXISTS public.api_keys_hash_uq;
      DROP INDEX IF EXISTS public.api_key_policy_model_active_uq;
      DROP INDEX IF EXISTS public.api_key_policy_default_active_uq;
      DROP INDEX IF EXISTS public.account_quota_windows_quota_freshness_idx;
      DROP INDEX IF EXISTS public.account_quota_windows_merge_idx;
      DROP INDEX IF EXISTS public.account_quota_windows_identity_sync_idx;
      DROP INDEX IF EXISTS public.account_quota_windows_freshness_idx;
      DROP INDEX IF EXISTS public.account_quota_windows_evidence_identity_uq;
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
