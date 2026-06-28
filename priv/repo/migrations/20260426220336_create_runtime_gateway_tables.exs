defmodule CodexPooler.Repo.Migrations.CreateRuntimeGatewayTables do
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
      CREATE TABLE public.account_quota_windows (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      upstream_identity_id uuid NOT NULL,
      quota_key text NOT NULL,
      window_kind text NOT NULL,
      window_minutes integer NOT NULL,
      active_limit bigint,
      credits bigint,
      reset_at timestamp with time zone,
      used_percent numeric(6,3),
      display_label text,
      limit_name text,
      metered_feature text,
      source text NOT NULL,
      source_precision text DEFAULT 'observed'::text NOT NULL,
      quota_scope text DEFAULT 'account'::text NOT NULL,
      quota_family text DEFAULT 'account'::text NOT NULL,
      model text,
      upstream_model text,
      raw_limit_id text,
      raw_limit_name text,
      raw_metered_feature text,
      freshness_state text NOT NULL,
      last_sync_at timestamp with time zone NOT NULL,
      observed_at timestamp with time zone DEFAULT now() NOT NULL,
      merge_precedence integer DEFAULT 0 NOT NULL,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      CONSTRAINT account_quota_windows_active_limit_check CHECK (((active_limit IS NULL) OR (active_limit >= 0))),
      CONSTRAINT account_quota_windows_credits_check CHECK (((credits IS NULL) OR (credits >= 0))),
      CONSTRAINT account_quota_windows_freshness_state_check CHECK ((freshness_state = ANY (ARRAY['fresh'::text, 'stale'::text, 'unknown'::text]))),
      CONSTRAINT account_quota_windows_quota_family_check CHECK ((length(btrim(quota_family)) > 0)),
      CONSTRAINT account_quota_windows_quota_key_check CHECK ((length(btrim(quota_key)) > 0)),
      CONSTRAINT account_quota_windows_quota_scope_check CHECK ((quota_scope = ANY (ARRAY['account'::text, 'model'::text, 'upstream_model'::text, 'feature'::text]))),
      CONSTRAINT account_quota_windows_source_check CHECK ((length(btrim(source)) > 0)),
      CONSTRAINT account_quota_windows_source_precision_check CHECK ((source_precision = ANY (ARRAY['authoritative'::text, 'observed'::text, 'inferred'::text, 'unknown'::text]))),
      CONSTRAINT account_quota_windows_used_percent_check CHECK (((used_percent IS NULL) OR ((used_percent >= (0)::numeric) AND (used_percent <= (100)::numeric)))),
      CONSTRAINT account_quota_windows_window_kind_check CHECK ((window_kind = ANY (ARRAY['primary'::text, 'secondary'::text]))),
      CONSTRAINT account_quota_windows_window_minutes_check CHECK ((window_minutes > 0))
      );

      CREATE TABLE public.attempts (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      request_id uuid NOT NULL,
      attempt_number integer NOT NULL,
      pool_upstream_assignment_id uuid NOT NULL,
      upstream_identity_id uuid,
      pricing_snapshot_id uuid,
      model_id uuid,
      upstream_model_id text NOT NULL,
      transport text NOT NULL,
      status text NOT NULL,
      started_at timestamp with time zone DEFAULT now() NOT NULL,
      completed_at timestamp with time zone,
      upstream_status_code integer,
      retryable boolean DEFAULT false NOT NULL,
      network_error_code text,
      error_message text,
      latency_ms integer,
      usage_status text DEFAULT 'usage_pending'::text NOT NULL,
      response_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT attempts_attempt_number_check CHECK ((attempt_number > 0)),
      CONSTRAINT attempts_latency_ms_check CHECK (((latency_ms IS NULL) OR (latency_ms >= 0))),
      CONSTRAINT attempts_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'in_progress'::text, 'succeeded'::text, 'failed'::text, 'retryable_failed'::text, 'cancelled'::text]))),
      CONSTRAINT attempts_transport_check CHECK ((transport = ANY (ARRAY['http_json'::text, 'http_compact_json'::text, 'http_sse'::text, 'websocket'::text, 'http_multipart'::text]))),
      CONSTRAINT attempts_usage_status_check CHECK ((usage_status = ANY (ARRAY['usage_pending'::text, 'usage_known'::text, 'usage_unknown'::text, 'not_applicable'::text])))
      );

      CREATE TABLE public.audit_events (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      occurred_at timestamp with time zone DEFAULT now() NOT NULL,
      actor_type text NOT NULL,
      actor_user_id uuid,
      pool_id uuid,
      request_id uuid,
      action text NOT NULL,
      target_type text NOT NULL,
      target_id uuid,
      outcome text DEFAULT 'success'::text NOT NULL,
      correlation_id text,
      ip_address inet,
      details jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT audit_events_actor_type_check CHECK ((actor_type = ANY (ARRAY['user'::text, 'system'::text]))),
      CONSTRAINT audit_events_check CHECK ((((actor_type = 'user'::text) AND (actor_user_id IS NOT NULL)) OR ((actor_type = 'system'::text) AND (actor_user_id IS NULL)))),
      CONSTRAINT audit_events_outcome_check CHECK ((outcome = ANY (ARRAY['success'::text, 'failure'::text])))
      );

      CREATE TABLE public.bridge_affinities (
      id uuid NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      model_identifier text NOT NULL,
      affinity_kind text NOT NULL,
      affinity_key_hash bytea NOT NULL,
      pool_upstream_assignment_id uuid NOT NULL,
      upstream_identity_id uuid,
      status text DEFAULT 'active'::text NOT NULL,
      last_hit_at timestamp without time zone,
      last_miss_at timestamp without time zone,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT bridge_affinities_status_check CHECK ((status = ANY (ARRAY['active'::text, 'replaced'::text])))
      );

      CREATE TABLE public.bridge_demotions (
      id uuid NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      model_identifier text NOT NULL,
      pool_upstream_assignment_id uuid NOT NULL,
      upstream_identity_id uuid,
      reason_code text NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      demoted_until timestamp without time zone,
      last_request_id uuid,
      attempt_count integer DEFAULT 1 NOT NULL,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT bridge_demotions_attempt_count_check CHECK ((attempt_count > 0)),
      CONSTRAINT bridge_demotions_status_check CHECK ((status = ANY (ARRAY['active'::text, 'resolved'::text])))
      );

      CREATE TABLE public.bridge_owner_leases (
      id uuid NOT NULL,
      codex_session_id uuid NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      pool_upstream_assignment_id uuid,
      owner_instance_id text NOT NULL,
      lease_token uuid NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      acquired_at timestamp without time zone NOT NULL,
      renewed_at timestamp without time zone NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      released_at timestamp without time zone,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT bridge_owner_leases_owner_present CHECK ((btrim(owner_instance_id) <> ''::text)),
      CONSTRAINT bridge_owner_leases_status_check CHECK ((status = ANY (ARRAY['active'::text, 'expired'::text, 'released'::text])))
      );

      CREATE TABLE public.bridge_session_aliases (
      id uuid NOT NULL,
      codex_session_id uuid NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      alias_kind text NOT NULL,
      alias_hash bytea NOT NULL,
      alias_preview text,
      status text DEFAULT 'active'::text NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      last_seen_at timestamp without time zone,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT bridge_session_aliases_kind_check CHECK ((alias_kind = ANY (ARRAY['turn_state'::text, 'previous_response_id'::text, 'session_header'::text, 'canonical_session_key'::text]))),
      CONSTRAINT bridge_session_aliases_status_check CHECK ((status = ANY (ARRAY['active'::text, 'expired'::text, 'replaced'::text])))
      );

      CREATE TABLE public.codex_file_uploads (
      id uuid NOT NULL,
      codex_file_id uuid NOT NULL,
      upload_key text NOT NULL,
      status text DEFAULT 'pending'::text NOT NULL,
      byte_size bigint DEFAULT 0 NOT NULL,
      content_type text,
      storage_path text,
      expires_at timestamp without time zone NOT NULL,
      completed_at timestamp without time zone,
      abandoned_at timestamp without time zone,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT codex_file_uploads_byte_size_check CHECK ((byte_size >= 0)),
      CONSTRAINT codex_file_uploads_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'completed'::text, 'abandoned'::text, 'expired'::text]))),
      CONSTRAINT codex_file_uploads_upload_key_present CHECK ((btrim(upload_key) <> ''::text))
      );

      CREATE TABLE public.codex_files (
      id uuid NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      request_id uuid,
      file_id text NOT NULL,
      purpose text NOT NULL,
      filename text NOT NULL,
      content_type text,
      byte_size bigint DEFAULT 0 NOT NULL,
      status text DEFAULT 'pending_upload'::text NOT NULL,
      storage_key text,
      sha256 bytea,
      upload_expires_at timestamp without time zone NOT NULL,
      uploaded_at timestamp without time zone,
      expires_at timestamp without time zone NOT NULL,
      deleted_at timestamp without time zone,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT codex_files_byte_size_check CHECK ((byte_size >= 0)),
      CONSTRAINT codex_files_file_id_present CHECK ((btrim(file_id) <> ''::text)),
      CONSTRAINT codex_files_filename_present CHECK ((btrim(filename) <> ''::text)),
      CONSTRAINT codex_files_purpose_present CHECK ((btrim(purpose) <> ''::text)),
      CONSTRAINT codex_files_status_check CHECK ((status = ANY (ARRAY['pending_upload'::text, 'uploaded'::text, 'abandoned'::text, 'expired'::text, 'deleted'::text])))
      );

      CREATE TABLE public.codex_sessions (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      pool_id uuid NOT NULL,
      session_key text NOT NULL,
      conversation_key text,
      pool_upstream_assignment_id uuid,
      owner_instance_id text,
      owner_lease_token uuid,
      owner_lease_expires_at timestamp with time zone,
      last_heartbeat_at timestamp with time zone,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      api_key_id uuid,
      status text DEFAULT 'active'::text NOT NULL,
      disconnected_at timestamp with time zone,
      closed_at timestamp with time zone,
      CONSTRAINT codex_sessions_check CHECK ((((owner_instance_id IS NULL) AND (owner_lease_token IS NULL) AND (owner_lease_expires_at IS NULL) AND (last_heartbeat_at IS NULL)) OR ((owner_instance_id IS NOT NULL) AND (owner_lease_token IS NOT NULL) AND (owner_lease_expires_at IS NOT NULL) AND (last_heartbeat_at IS NOT NULL)))),
      CONSTRAINT codex_sessions_conversation_key_check CHECK (((conversation_key IS NULL) OR (btrim(conversation_key) <> ''::text))),
      CONSTRAINT codex_sessions_session_key_check CHECK ((btrim(session_key) <> ''::text)),
      CONSTRAINT codex_sessions_status_check CHECK ((status = ANY (ARRAY['active'::text, 'interrupted'::text, 'closed'::text])))
      );

      CREATE TABLE public.codex_turns (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      codex_session_id uuid NOT NULL,
      request_id uuid NOT NULL,
      turn_sequence integer NOT NULL,
      transport_kind text NOT NULL,
      first_visible_output_at timestamp with time zone,
      final_attempt_id uuid,
      started_at timestamp with time zone DEFAULT now() NOT NULL,
      completed_at timestamp with time zone,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      status text DEFAULT 'in_progress'::text NOT NULL,
      error_code text,
      CONSTRAINT codex_turns_status_check CHECK ((status = ANY (ARRAY['in_progress'::text, 'succeeded'::text, 'failed'::text, 'interrupted'::text]))),
      CONSTRAINT codex_turns_transport_kind_check CHECK ((transport_kind = ANY (ARRAY['http_json'::text, 'http_sse'::text, 'websocket'::text]))),
      CONSTRAINT codex_turns_turn_sequence_check CHECK ((turn_sequence > 0))
      );

      CREATE TABLE public.gateway_idempotency_keys (
      id uuid NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      request_id uuid,
      codex_file_id uuid,
      scope text NOT NULL,
      key_hash bytea NOT NULL,
      status text DEFAULT 'in_progress'::text NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      completed_at timestamp without time zone,
      response_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT gateway_idempotency_keys_scope_present CHECK ((btrim(scope) <> ''::text)),
      CONSTRAINT gateway_idempotency_keys_status_check CHECK ((status = ANY (ARRAY['in_progress'::text, 'succeeded'::text, 'failed'::text, 'expired'::text])))
      );

      CREATE TABLE public.models (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      pool_id uuid NOT NULL,
      upstream_model_id text NOT NULL,
      exposed_model_id text NOT NULL,
      display_name text NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      supports_responses boolean DEFAULT false NOT NULL,
      supports_streaming boolean DEFAULT false NOT NULL,
      supports_tools boolean DEFAULT false NOT NULL,
      supports_reasoning boolean DEFAULT false NOT NULL,
      pricing_ref text,
      source_assignment_count integer DEFAULT 0 NOT NULL,
      first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
      last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
      stale_at timestamp with time zone,
      retired_at timestamp with time zone,
      suppressed_at timestamp with time zone,
      last_sync_run_id uuid,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT models_source_assignment_count_check CHECK ((source_assignment_count >= 0)),
      CONSTRAINT models_status_check CHECK ((status = ANY (ARRAY['active'::text, 'stale'::text, 'retired'::text, 'suppressed'::text])))
      );

      CREATE TABLE public.requests (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      model_id uuid,
      requested_model text NOT NULL,
      endpoint text NOT NULL,
      transport text NOT NULL,
      status text DEFAULT 'accepted'::text NOT NULL,
      usage_status text DEFAULT 'usage_pending'::text NOT NULL,
      correlation_id text NOT NULL,
      idempotency_key text,
      client_ip inet,
      user_agent text,
      request_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      admitted_at timestamp with time zone DEFAULT now() NOT NULL,
      completed_at timestamp with time zone,
      response_status_code integer,
      retry_count integer DEFAULT 0 NOT NULL,
      last_error_code text,
      CONSTRAINT requests_retry_count_check CHECK ((retry_count >= 0)),
      CONSTRAINT requests_status_check CHECK ((status = ANY (ARRAY['accepted'::text, 'in_progress'::text, 'succeeded'::text, 'failed'::text, 'rejected'::text, 'cancelled'::text]))),
      CONSTRAINT requests_transport_check CHECK ((transport = ANY (ARRAY['http_json'::text, 'http_compact_json'::text, 'http_sse'::text, 'websocket'::text, 'http_multipart'::text]))),
      CONSTRAINT requests_usage_status_check CHECK ((usage_status = ANY (ARRAY['usage_pending'::text, 'usage_known'::text, 'usage_unknown'::text, 'not_applicable'::text])))
      );

      CREATE TABLE public.routing_circuit_states (
      id uuid NOT NULL,
      pool_id uuid NOT NULL,
      api_key_id uuid,
      pool_upstream_assignment_id uuid NOT NULL,
      upstream_identity_id uuid,
      model_identifier text NOT NULL,
      route_class text NOT NULL,
      status text DEFAULT 'closed'::text NOT NULL,
      reason_code text,
      failure_count integer DEFAULT 0 NOT NULL,
      success_count integer DEFAULT 0 NOT NULL,
      opened_at timestamp without time zone,
      half_opened_at timestamp without time zone,
      closed_at timestamp without time zone,
      next_probe_at timestamp without time zone,
      last_failure_at timestamp without time zone,
      last_success_at timestamp without time zone,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT routing_circuit_states_counts_check CHECK (((failure_count >= 0) AND (success_count >= 0))),
      CONSTRAINT routing_circuit_states_status_check CHECK ((status = ANY (ARRAY['closed'::text, 'open'::text, 'half_open'::text])))
      );

      CREATE TABLE public.sync_runs (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      pool_id uuid NOT NULL,
      trigger_kind text NOT NULL,
      status text NOT NULL,
      started_at timestamp with time zone DEFAULT now() NOT NULL,
      finished_at timestamp with time zone,
      discovered_model_count integer DEFAULT 0 NOT NULL,
      upserted_model_count integer DEFAULT 0 NOT NULL,
      stale_marked_count integer DEFAULT 0 NOT NULL,
      retired_count integer DEFAULT 0 NOT NULL,
      error_message text,
      stats jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT sync_runs_discovered_model_count_check CHECK ((discovered_model_count >= 0)),
      CONSTRAINT sync_runs_retired_count_check CHECK ((retired_count >= 0)),
      CONSTRAINT sync_runs_stale_marked_count_check CHECK ((stale_marked_count >= 0)),
      CONSTRAINT sync_runs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text]))),
      CONSTRAINT sync_runs_trigger_kind_check CHECK ((trigger_kind = ANY (ARRAY['manual'::text, 'scheduled'::text, 'bootstrap'::text, 'reconcile'::text]))),
      CONSTRAINT sync_runs_upserted_model_count_check CHECK ((upserted_model_count >= 0))
      );
      """)
    end
  end

  def down do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      DROP TABLE IF EXISTS public.routing_circuit_states CASCADE;
      DROP TABLE IF EXISTS public.gateway_idempotency_keys CASCADE;
      DROP TABLE IF EXISTS public.bridge_session_aliases CASCADE;
      DROP TABLE IF EXISTS public.bridge_owner_leases CASCADE;
      DROP TABLE IF EXISTS public.bridge_demotions CASCADE;
      DROP TABLE IF EXISTS public.bridge_affinities CASCADE;
      DROP TABLE IF EXISTS public.codex_file_uploads CASCADE;
      DROP TABLE IF EXISTS public.codex_files CASCADE;
      DROP TABLE IF EXISTS public.codex_turns CASCADE;
      DROP TABLE IF EXISTS public.codex_sessions CASCADE;
      DROP TABLE IF EXISTS public.audit_events CASCADE;
      DROP TABLE IF EXISTS public.attempts CASCADE;
      DROP TABLE IF EXISTS public.requests CASCADE;
      DROP TABLE IF EXISTS public.account_quota_windows CASCADE;
      DROP TABLE IF EXISTS public.sync_runs CASCADE;
      DROP TABLE IF EXISTS public.models CASCADE;
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
