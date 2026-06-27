defmodule CodexPooler.Repo.Migrations.CreateIdentityAndAccessTables do
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
      CREATE TABLE public.api_key_policy_bindings (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      api_key_id uuid NOT NULL,
      binding_scope text NOT NULL,
      model_identifier text,
      status text DEFAULT 'active'::text NOT NULL,
      max_requests_per_minute integer,
      max_tokens_per_day bigint,
      max_input_tokens_per_request integer,
      max_output_tokens_per_request integer,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      max_tokens_per_week bigint,
      CONSTRAINT api_key_policy_bindings_binding_scope_check CHECK ((binding_scope = ANY (ARRAY['default'::text, 'model'::text]))),
      CONSTRAINT api_key_policy_bindings_check CHECK ((((binding_scope = 'default'::text) AND (model_identifier IS NULL)) OR ((binding_scope = 'model'::text) AND (model_identifier IS NOT NULL)))),
      CONSTRAINT api_key_policy_bindings_max_input_tokens_per_request_check CHECK (((max_input_tokens_per_request IS NULL) OR (max_input_tokens_per_request > 0))),
      CONSTRAINT api_key_policy_bindings_max_output_tokens_per_request_check CHECK (((max_output_tokens_per_request IS NULL) OR (max_output_tokens_per_request > 0))),
      CONSTRAINT api_key_policy_bindings_max_requests_per_minute_check CHECK (((max_requests_per_minute IS NULL) OR (max_requests_per_minute > 0))),
      CONSTRAINT api_key_policy_bindings_max_tokens_per_day_check CHECK (((max_tokens_per_day IS NULL) OR (max_tokens_per_day > 0))),
      CONSTRAINT api_key_policy_bindings_max_tokens_per_week_check CHECK (((max_tokens_per_week IS NULL) OR (max_tokens_per_week > 0))),
      CONSTRAINT api_key_policy_bindings_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text])))
      );

      CREATE TABLE public.api_keys (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      pool_id uuid NOT NULL,
      display_name text NOT NULL,
      key_prefix text NOT NULL,
      key_hash bytea NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      expires_at timestamp with time zone,
      last_used_at timestamp with time zone,
      created_by_user_id uuid,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      revoked_at timestamp with time zone,
      allowed_model_identifiers text[],
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      enforced_model_identifier text,
      enforced_reasoning_effort text,
      enforced_service_tier text,
      CONSTRAINT api_keys_allowed_model_identifiers_shape CHECK (((allowed_model_identifiers IS NULL) OR (array_position(allowed_model_identifiers, NULL::text) IS NULL))),
      CONSTRAINT api_keys_enforced_model_identifier_shape CHECK (((enforced_model_identifier IS NULL) OR ((enforced_model_identifier = btrim(enforced_model_identifier)) AND (enforced_model_identifier <> ''::text) AND (enforced_model_identifier !~ '[[:space:][:cntrl:]]'::text)))),
      CONSTRAINT api_keys_enforced_reasoning_effort_check CHECK (((enforced_reasoning_effort IS NULL) OR (enforced_reasoning_effort = ANY (ARRAY['minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text])))),
      CONSTRAINT api_keys_enforced_service_tier_check CHECK (((enforced_service_tier IS NULL) OR (enforced_service_tier = ANY (ARRAY['auto'::text, 'default'::text, 'flex'::text, 'priority'::text, 'ultrafast'::text])))),
      CONSTRAINT api_keys_metadata_shape CHECK (((jsonb_typeof(metadata) = 'object'::text) AND ((NOT (metadata ? 'labels'::text)) OR ((jsonb_typeof((metadata -> 'labels'::text)) = 'array'::text) AND (jsonb_path_query_array((metadata -> 'labels'::text), '$[*]?(@.type() != "string")'::jsonpath) = '[]'::jsonb))) AND ((NOT (metadata ? 'operator_notes'::text)) OR (jsonb_typeof((metadata -> 'operator_notes'::text)) = ANY (ARRAY['string'::text, 'null'::text]))))),
      CONSTRAINT api_keys_status_check CHECK ((status = ANY (ARRAY['active'::text, 'paused'::text, 'revoked'::text])))
      );

      CREATE TABLE public.encrypted_secrets (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      upstream_identity_id uuid NOT NULL,
      secret_kind text NOT NULL,
      key_version text NOT NULL,
      ciphertext bytea NOT NULL,
      nonce bytea,
      aad jsonb DEFAULT '{}'::jsonb NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      superseded_at timestamp with time zone,
      CONSTRAINT encrypted_secrets_secret_kind_check CHECK ((secret_kind = ANY (ARRAY['access_token'::text, 'refresh_token'::text, 'device_code'::text, 'web_session'::text, 'api_key'::text, 'other'::text]))),
      CONSTRAINT encrypted_secrets_status_check CHECK ((status = ANY (ARRAY['active'::text, 'superseded'::text, 'revoked'::text])))
      );

      CREATE TABLE public.invite_redemptions (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      invite_id uuid NOT NULL,
      pool_id uuid NOT NULL,
      upstream_identity_id uuid NOT NULL,
      pool_upstream_assignment_id uuid,
      status text NOT NULL,
      onboarding_method text NOT NULL,
      consumed_by_email text,
      error_message text,
      consumed_at timestamp with time zone DEFAULT now() NOT NULL,
      details jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT invite_redemptions_onboarding_method_check CHECK ((onboarding_method = ANY (ARRAY['invite'::text, 'wizard'::text, 'browser'::text, 'device'::text, 'import'::text]))),
      CONSTRAINT invite_redemptions_status_check CHECK ((status = ANY (ARRAY['completed'::text, 'noop'::text, 'failed'::text])))
      );

      CREATE TABLE public.invites (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      pool_id uuid NOT NULL,
      token_hash bytea NOT NULL,
      invited_email text,
      status text DEFAULT 'active'::text NOT NULL,
      max_redemptions integer DEFAULT 1 NOT NULL,
      redemptions_used integer DEFAULT 0 NOT NULL,
      expires_at timestamp with time zone,
      created_by_user_id uuid,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      last_consumed_at timestamp with time zone,
      revoked_at timestamp with time zone,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT invites_check CHECK ((redemptions_used <= max_redemptions)),
      CONSTRAINT invites_max_redemptions_check CHECK ((max_redemptions > 0)),
      CONSTRAINT invites_redemptions_used_check CHECK ((redemptions_used >= 0)),
      CONSTRAINT invites_status_check CHECK ((status = ANY (ARRAY['active'::text, 'revoked'::text, 'expired'::text])))
      );

      CREATE TABLE public.memberships (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      user_id uuid NOT NULL,
      role text NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      created_by_user_id uuid,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      revoked_at timestamp with time zone,
      CONSTRAINT memberships_role_check CHECK ((role = ANY (ARRAY['instance_owner'::text, 'instance_admin'::text]))),
      CONSTRAINT memberships_status_check CHECK ((status = ANY (ARRAY['active'::text, 'revoked'::text])))
      );

      CREATE TABLE public.platform_bootstrap_state (
      singleton boolean DEFAULT true NOT NULL,
      status text DEFAULT 'pending'::text NOT NULL,
      owner_user_id uuid,
      completed_at timestamp with time zone,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      CONSTRAINT platform_bootstrap_state_check CHECK ((((status = 'completed'::text) AND (owner_user_id IS NOT NULL) AND (completed_at IS NOT NULL)) OR (status <> 'completed'::text))),
      CONSTRAINT platform_bootstrap_state_singleton_check CHECK (singleton),
      CONSTRAINT platform_bootstrap_state_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'completed'::text, 'locked'::text])))
      );

      CREATE TABLE public.pool_routing_settings (
      pool_id uuid NOT NULL,
      routing_strategy text DEFAULT 'bridge_ring'::text NOT NULL,
      prefer_early_reset boolean DEFAULT false NOT NULL,
      allow_cooldown_fallback boolean DEFAULT false NOT NULL,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      bridge_ring_size integer DEFAULT 3 NOT NULL,
      sticky_websocket_sessions boolean DEFAULT true NOT NULL,
      sticky_http_sessions boolean DEFAULT false NOT NULL,
      CONSTRAINT pool_routing_settings_bridge_ring_size_check CHECK ((bridge_ring_size >= 1)),
      CONSTRAINT pool_routing_settings_routing_strategy_check CHECK ((routing_strategy = ANY (ARRAY['bridge_ring'::text, 'deterministic_rotation'::text, 'least_recent_success'::text, 'quota_first'::text])))
      );

      CREATE TABLE public.pool_upstream_assignments (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      pool_id uuid NOT NULL,
      upstream_identity_id uuid NOT NULL,
      assignment_label text NOT NULL,
      status text DEFAULT 'pending'::text NOT NULL,
      health_status text DEFAULT 'unknown'::text NOT NULL,
      eligibility_status text DEFAULT 'eligible'::text NOT NULL,
      cooldown_until timestamp with time zone,
      last_healthcheck_at timestamp with time zone,
      last_successful_refresh_at timestamp with time zone,
      last_successful_sync_at timestamp with time zone,
      disabled_at timestamp with time zone,
      created_by_user_id uuid,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT pool_upstream_assignments_eligibility_status_check CHECK ((eligibility_status = ANY (ARRAY['eligible'::text, 'ineligible'::text]))),
      CONSTRAINT pool_upstream_assignments_health_status_check CHECK ((health_status = ANY (ARRAY['unknown'::text, 'active'::text, 'cooldown'::text, 'degraded'::text, 'disabled'::text, 'errored'::text]))),
      CONSTRAINT pool_upstream_assignments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'paused'::text, 'refresh_due'::text, 'refreshing'::text, 'refresh_failed'::text, 'reauth_required'::text, 'deleted'::text, 'disabled'::text, 'errored'::text])))
      );

      CREATE TABLE public.pools (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      slug text NOT NULL,
      name text NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      created_by_user_id uuid,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      disabled_at timestamp with time zone,
      CONSTRAINT pools_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text, 'archived'::text])))
      );

      CREATE TABLE public.recovery_codes (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      user_id uuid NOT NULL,
      totp_setting_id uuid NOT NULL,
      code_hash bytea NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      used_at timestamp with time zone,
      CONSTRAINT recovery_codes_status_check CHECK ((status = ANY (ARRAY['active'::text, 'used'::text, 'revoked'::text])))
      );

      CREATE TABLE public.sessions (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      user_id uuid NOT NULL,
      session_token_hash bytea NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      expires_at timestamp with time zone NOT NULL,
      last_seen_at timestamp with time zone,
      ip_address inet,
      user_agent text,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      revoked_at timestamp with time zone,
      CONSTRAINT sessions_status_check CHECK ((status = ANY (ARRAY['active'::text, 'revoked'::text, 'expired'::text])))
      );

      CREATE TABLE public.totp_settings (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      user_id uuid NOT NULL,
      secret_ciphertext bytea NOT NULL,
      secret_key_version text NOT NULL,
      recovery_generation integer DEFAULT 1 NOT NULL,
      status text DEFAULT 'pending'::text NOT NULL,
      enrolled_at timestamp with time zone,
      verified_at timestamp with time zone,
      disabled_at timestamp with time zone,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      CONSTRAINT totp_settings_recovery_generation_check CHECK ((recovery_generation > 0)),
      CONSTRAINT totp_settings_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'disabled'::text])))
      );

      CREATE TABLE public.upstream_identities (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      chatgpt_account_id text,
      account_label text NOT NULL,
      onboarding_method text NOT NULL,
      status text DEFAULT 'pending'::text NOT NULL,
      plan_family text,
      plan_label text,
      auth_fresh_at timestamp with time zone,
      auth_verified_at timestamp with time zone,
      headers_profile_version integer DEFAULT 1 NOT NULL,
      last_successful_refresh_at timestamp with time zone,
      last_successful_sync_at timestamp with time zone,
      disabled_at timestamp with time zone,
      created_by_user_id uuid,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT upstream_identities_onboarding_method_check CHECK ((onboarding_method = ANY (ARRAY['browser'::text, 'device'::text, 'import'::text, 'invite'::text]))),
      CONSTRAINT upstream_identities_plan_family_check CHECK (((plan_family IS NULL) OR (plan_family ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'::text))),
      CONSTRAINT upstream_identities_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'paused'::text, 'refresh_due'::text, 'refreshing'::text, 'refresh_failed'::text, 'reauth_required'::text, 'deleted'::text, 'disabled'::text, 'errored'::text])))
      );

      CREATE TABLE public.users (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      email text NOT NULL,
      display_name text,
      password_hash text NOT NULL,
      status text DEFAULT 'active'::text NOT NULL,
      last_login_at timestamp with time zone,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      deleted_at timestamp with time zone,
      password_change_required boolean DEFAULT false NOT NULL,
      CONSTRAINT users_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text])))
      );
      """)
    end
  end

  def down do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      DROP TABLE IF EXISTS public.api_key_policy_bindings CASCADE;
      DROP TABLE IF EXISTS public.api_keys CASCADE;
      DROP TABLE IF EXISTS public.invite_redemptions CASCADE;
      DROP TABLE IF EXISTS public.invites CASCADE;
      DROP TABLE IF EXISTS public.pool_upstream_assignments CASCADE;
      DROP TABLE IF EXISTS public.encrypted_secrets CASCADE;
      DROP TABLE IF EXISTS public.upstream_identities CASCADE;
      DROP TABLE IF EXISTS public.pool_routing_settings CASCADE;
      DROP TABLE IF EXISTS public.pools CASCADE;
      DROP TABLE IF EXISTS public.platform_bootstrap_state CASCADE;
      DROP TABLE IF EXISTS public.recovery_codes CASCADE;
      DROP TABLE IF EXISTS public.totp_settings CASCADE;
      DROP TABLE IF EXISTS public.sessions CASCADE;
      DROP TABLE IF EXISTS public.memberships CASCADE;
      DROP TABLE IF EXISTS public.users CASCADE;
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
