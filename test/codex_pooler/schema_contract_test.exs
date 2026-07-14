defmodule CodexPooler.SchemaContractTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentReceipt,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Accounting.{DailyRollup, HourlyModelUsageRollup, LedgerEntry, RequestLogFact}
  alias CodexPooler.Catalog.{Model, PricingSnapshot}
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, RoutingCircuitState}
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Pools.{OperatorPoolAssignment, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.{OAuthFlow, UpstreamIdentity}

  @expected_tables ~w(
    account_quota_windows alert_channels alert_delivery_attempts alert_incident_receipts alert_incident_targets alert_incidents
    alert_rule_channels alert_rules api_key_policy_bindings api_keys attempts audit_events bridge_owner_leases
    bridge_session_aliases codex_files codex_sessions codex_turns daily_rollups hourly_model_usage_rollups
    encrypted_secrets gateway_idempotency_keys instance_settings invite_acceptances invites ledger_entries memberships
    models operator_pool_assignments platform_bootstrap_state pricing_snapshots recovery_codes request_log_facts requests routing_circuit_states
    sessions sync_runs pools pool_routing_settings pool_upstream_assignments totp_settings
    upstream_identities upstream_oauth_flows users
  )

  @schema_modules [
    CodexPooler.Accounts.PlatformBootstrapState,
    CodexPooler.Accounts.RecoveryCode,
    CodexPooler.Accounts.Session,
    CodexPooler.Accounts.TOTPSetting,
    CodexPooler.Accounts.User,
    APIKey,
    APIKeyPolicyBinding,
    CodexPooler.Access.Invite,
    CodexPooler.Access.InviteAcceptance,
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentReceipt,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel,
    DailyRollup,
    HourlyModelUsageRollup,
    LedgerEntry,
    RequestLogFact,
    CodexPooler.Audit.AuditEvent,
    Model,
    PricingSnapshot,
    CodexPooler.Catalog.SyncRun,
    CodexPooler.Files.FileRecord,
    CodexPooler.Accounting.Attempt,
    CodexPooler.Gateway.Persistence.BridgeOwnerLease,
    CodexPooler.Gateway.Persistence.BridgeSessionAlias,
    CodexPooler.Gateway.Persistence.CodexSession,
    CodexPooler.Gateway.Persistence.CodexTurn,
    CodexPooler.Gateway.Persistence.IdempotencyKey,
    Settings,
    CodexPooler.Accounting.Request,
    CodexPooler.Gateway.Persistence.RoutingCircuitState,
    CodexPooler.Pools.Membership,
    OperatorPoolAssignment,
    CodexPooler.Pools.Pool,
    RoutingSettings,
    Quota.AccountQuotaWindow,
    CodexPooler.Upstreams.Schemas.EncryptedSecret,
    OAuthFlow,
    CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment,
    UpstreamIdentity
  ]

  test "creates the final source table inventory with pgcrypto enabled" do
    tables =
      Repo.query!("""
      SELECT tablename
      FROM pg_tables
      WHERE schemaname = 'public'
      ORDER BY tablename ASC
      """).rows
      |> Enum.map(&List.first/1)

    assert Enum.sort(@expected_tables) -- tables == []

    assert [[1]] =
             Repo.query!("SELECT COUNT(*) FROM pg_extension WHERE extname = 'pgcrypto'").rows

    assert [["pending"]] = Repo.query!("SELECT status FROM platform_bootstrap_state").rows
  end

  test "preserves required unique, partial, and functional indexes" do
    indexes =
      Repo.query!("""
      SELECT indexname, indexdef
      FROM pg_indexes
      WHERE schemaname = 'public'
      """).rows
      |> Map.new(fn [name, definition] -> {name, definition} end)

    for name <- [
          "users_email_active_uq",
          "pools_slug_uq",
          "operator_pool_assignments_user_pool_active_uq",
          "api_key_policy_default_active_uq",
          "api_key_policy_model_active_uq",
          "encrypted_secrets_active_kind_uq",
          "account_quota_windows_evidence_identity_uq",
          "codex_files_file_id_uq",
          "bridge_session_aliases_active_key_uq",
          "bridge_owner_leases_active_session_uq",
          "gateway_idempotency_keys_active_key_uq",
          "routing_circuit_states_active_assignment_uq",
          "models_pool_exposed_uq",
          "ledger_entries_settlement_request_uq",
          "ledger_entries_api_key_recorded_occurred_idx",
          "request_log_facts_latest_upstream_identity_request_idx",
          "requests_admitted_id_idx",
          "daily_rollups_api_key_uq",
          "daily_rollups_pool_uq",
          "hourly_model_usage_rollups_bucket_pool_model_code_uq",
          "hourly_model_usage_rollups_pool_bucket_model_idx",
          "hourly_model_usage_rollups_model_bucket_pool_idx",
          "codex_sessions_pool_session_key_uq",
          "codex_turns_session_sequence_uq",
          "invite_acceptances_invite_id_uq",
          "alert_incidents_unresolved_dedupe_key_uq",
          "alert_incident_receipts_operator_incident_uq",
          "alert_incident_receipts_incident_id_idx",
          "alert_incident_receipts_operator_dismissed_idx",
          "alert_rule_channels_rule_channel_uq",
          "alert_incident_targets_incident_rule_pool_uq",
          "alert_delivery_attempts_incident_channel_attempt_uq",
          "alert_incident_targets_rule_pool_idx",
          "alert_delivery_attempts_retry_lookup_idx",
          "upstream_oauth_flows_state_token_hash_uq",
          "upstream_oauth_flows_pool_status_expires_idx",
          "upstream_oauth_flows_identity_status_expires_idx",
          "upstream_oauth_flows_requested_status_inserted_idx"
        ] do
      assert Map.has_key?(indexes, name)
    end

    refute Map.has_key?(indexes, "memberships_single_instance_owner_active_uq")

    assert indexes["users_email_active_uq"] =~ "lower(email)"
    assert indexes["users_email_active_uq"] =~ "WHERE (deleted_at IS NULL)"
    assert indexes["operator_pool_assignments_user_pool_active_uq"] =~ "(user_id, pool_id)"

    assert indexes["operator_pool_assignments_user_pool_active_uq"] =~
             "WHERE (status = 'active'::text)"

    assert indexes["api_key_policy_model_active_uq"] =~ "lower(model_identifier)"
    assert indexes["ledger_entries_settlement_request_uq"] =~ "entry_kind = 'settlement'"
    assert indexes["ledger_entries_api_key_recorded_occurred_idx"] =~ "api_key_id"
    assert indexes["ledger_entries_api_key_recorded_occurred_idx"] =~ "occurred_at DESC"

    assert indexes["ledger_entries_api_key_recorded_occurred_idx"] =~
             "WHERE (amount_status = 'recorded'::text)"

    assert indexes["request_log_facts_latest_upstream_identity_request_idx"] =~
             "(latest_upstream_identity_id, request_id)"

    assert indexes["request_log_facts_latest_upstream_identity_request_idx"] =~
             "WHERE (latest_upstream_identity_id IS NOT NULL)"

    assert indexes["daily_rollups_api_key_uq"] =~
             "(rollup_date, pool_id, api_key_id)"

    assert indexes["daily_rollups_api_key_uq"] =~
             "WHERE (dimension_kind = 'api_key'::text)"

    assert indexes["hourly_model_usage_rollups_bucket_pool_model_code_uq"] =~
             "(bucket_started_at, pool_id, model_code)"

    assert indexes["hourly_model_usage_rollups_pool_bucket_model_idx"] =~
             "(pool_id, bucket_started_at, model_code)"

    assert indexes["hourly_model_usage_rollups_model_bucket_pool_idx"] =~
             "(model_code, bucket_started_at, pool_id)"

    assert indexes["account_quota_windows_evidence_identity_uq"] =~ "quota_scope"
    assert indexes["requests_api_key_admitted_idx"] =~ "api_key_id"
    assert indexes["requests_api_key_admitted_idx"] =~ "admitted_at DESC"
    assert indexes["requests_api_key_admitted_idx"] =~ "id DESC"

    assert indexes["requests_admitted_id_idx"] =~ "(admitted_at DESC, id DESC)"

    assert indexes["account_quota_windows_evidence_identity_uq"] =~
             "COALESCE(lower(model), ''::text)"

    assert indexes["account_quota_windows_evidence_identity_uq"] =~ "raw_metered_feature"
    assert indexes["alert_incidents_unresolved_dedupe_key_uq"] =~ "dedupe_key"

    assert indexes["alert_incidents_unresolved_dedupe_key_uq"] =~
             "WHERE (state = ANY (ARRAY['open'::text, 'acknowledged'::text]))"

    assert indexes["alert_incident_receipts_operator_incident_uq"] =~
             "(operator_id, incident_id)"

    assert indexes["alert_delivery_attempts_retry_lookup_idx"] =~ "next_retry_at"

    assert indexes["alert_delivery_attempts_retry_lookup_idx"] =~
             "WHERE (status = ANY (ARRAY['pending'::text, 'retryable'::text]))"
  end

  test "preserves check constraints for statuses, endpoints, transports, and quota windows" do
    constraints = constraint_definitions()

    assert constraints["api_keys_status_check"] =~ "'paused'"
    refute constraints["api_keys_status_check"] =~ "'disabled'"
    assert constraints["operator_pool_assignments_status_check"] =~ "'active'"
    assert constraints["operator_pool_assignments_status_check"] =~ "'revoked'"
    refute constraints["operator_pool_assignments_status_check"] =~ "'disabled'"

    for endpoint <- [
          "/backend-api/codex/models",
          "/backend-api/codex/responses",
          "/backend-api/codex/responses/compact",
          "/backend-api/codex/images/generations",
          "/backend-api/codex/images/edits",
          "/backend-api/transcribe",
          "/backend-api/files",
          "/backend-api/files/uploaded",
          "/api/codex/usage",
          "/wham/usage",
          "/backend-api/wham/usage",
          "/v1/models",
          "/v1/responses",
          "/v1/usage",
          "/v1/files",
          "/v1/files/content",
          "/v1/files/delete"
        ] do
      assert constraints["requests_endpoint_check"] =~ "'#{endpoint}'"
    end

    for endpoint <- [
          "/backend-api/codex/thread/goal/get",
          "/backend-api/codex/thread/goal/set",
          "/backend-api/codex/thread/goal/clear",
          "/backend-api/codex/analytics-events/events",
          "/backend-api/codex/memories/trace_summarize",
          "/backend-api/codex/alpha/search",
          "/backend-api/codex/realtime/calls",
          "/backend-api/codex/safety/arc",
          "/backend-api/codex/agent-identities/jwks",
          "/backend-api/wham/agent-identities/jwks",
          "/api/codex/rate-limit-reset-credits/consume",
          "/wham/rate-limit-reset-credits/consume",
          "/backend-api/wham/rate-limit-reset-credits/consume",
          "/backend-api/codex/not-added"
        ] do
      refute constraints["requests_endpoint_check"] =~ "'#{endpoint}'"
    end

    assert constraints["requests_transport_check"] =~ "'http_compact_json'"
    assert constraints["requests_transport_check"] =~ "'websocket'"
    assert constraints["requests_transport_check"] =~ "'http_multipart'"
    assert constraints["attempts_transport_check"] =~ "'http_compact_json'"
    assert constraints["attempts_transport_check"] =~ "'websocket'"
    assert constraints["attempts_transport_check"] =~ "'http_multipart'"
    assert constraints["ledger_entries_transport_check"] =~ "'http_compact_json'"
    assert constraints["ledger_entries_transport_check"] =~ "'websocket'"
    assert constraints["ledger_entries_transport_check"] =~ "'http_multipart'"
    assert constraint_containing?(constraints, "window_minutes > 0")
    assert constraint_containing?(constraints, "btrim(quota_key)")
    assert constraints["api_keys_enforced_model_identifier_shape"] =~ "enforced_model_identifier"
    assert constraints["api_keys_enforced_model_identifier_shape"] =~ "btrim"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'none'"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'minimal'"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'high'"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'xhigh'"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'max'"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'ultra'"
    assert constraints["api_keys_maximum_reasoning_effort_check"] =~ "'none'"
    assert constraints["api_keys_maximum_reasoning_effort_check"] =~ "'ultra'"

    assert constraints["api_keys_reasoning_effort_policy_mutual_exclusion_check"] =~
             "maximum_reasoning_effort"

    assert constraints["api_keys_reasoning_effort_policy_mutual_exclusion_check"] =~
             "enforced_reasoning_effort"

    assert constraints["api_keys_enforced_service_tier_check"] =~ "'auto'"
    assert constraints["api_keys_enforced_service_tier_check"] =~ "'priority'"
    assert constraints["api_keys_enforced_service_tier_check"] =~ "'scale'"
    refute constraints["api_keys_enforced_service_tier_check"] =~ "'ultrafast'"

    assert constraints["api_key_policy_bindings_max_tokens_per_week_check"] =~
             "max_tokens_per_week > 0"

    assert constraints["instance_settings_singleton_true_check"] =~ "singleton = true"

    assert constraints["alert_rules_scope_type_check"] =~ "'pool'"
    assert constraints["alert_rules_scope_type_check"] =~ "'upstream_identity'"
    assert constraints["alert_rules_rule_kind_check"] =~ "'pool_no_usable_assignments'"
    assert constraints["alert_rules_rule_kind_check"] =~ "'upstream_auth_state'"

    assert constraints["alert_rules_rule_kind_check"] =~
             "'upstream_saved_reset_banked_first_seen'"

    assert constraints["alert_rules_severity_check"] =~ "'info'"
    assert constraints["alert_rules_severity_check"] =~ "'critical'"
    assert constraints["alert_rules_cooldown_minutes_check"] =~ "cooldown_minutes >= 5"
    assert constraints["alert_rules_cooldown_minutes_check"] =~ "cooldown_minutes <= 1440"
    assert constraints["alert_rules_state_check"] =~ "'active'"
    assert constraints["alert_rules_state_check"] =~ "'disabled'"
    assert constraints["alert_rules_target_state_check"] =~ "'missing_evidence'"
    assert constraints["alert_rules_window_selector_check"] =~ "'model_secondary'"
    assert constraints["alert_channels_channel_type_check"] =~ "'email'"
    assert constraints["alert_channels_channel_type_check"] =~ "'webhook'"
    assert constraints["alert_channels_state_check"] =~ "'active'"
    assert constraints["alert_incidents_scope_type_check"] =~ "'upstream_identity'"

    assert constraints["alert_incidents_rule_kind_check"] =~
             "'upstream_saved_reset_banked_first_seen'"

    assert constraints["alert_incidents_state_check"] =~ "'open'"
    assert constraints["alert_incidents_state_check"] =~ "'acknowledged'"
    assert constraints["alert_incidents_state_check"] =~ "'resolved'"
    assert constraints["alert_delivery_attempts_status_check"] =~ "'pending'"
    assert constraints["alert_delivery_attempts_status_check"] =~ "'discarded'"
    assert constraints["alert_delivery_attempts_max_attempts_check"] =~ "max_attempts = 5"
    assert constraints["upstream_oauth_flows_flow_kind_check"] =~ "'browser'"
    assert constraints["upstream_oauth_flows_flow_kind_check"] =~ "'device'"
    assert constraints["upstream_oauth_flows_purpose_check"] =~ "'link'"
    assert constraints["upstream_oauth_flows_purpose_check"] =~ "'relink'"
    assert constraints["upstream_oauth_flows_status_check"] =~ "'pending'"
    assert constraints["upstream_oauth_flows_status_check"] =~ "'completed'"
    assert constraints["upstream_oauth_flows_status_check"] =~ "'failed'"
    assert constraints["upstream_oauth_flows_status_check"] =~ "'cancelled'"
    assert constraints["upstream_oauth_flows_status_check"] =~ "'expired'"
    assert constraints["upstream_oauth_flows_metadata_shape_check"] =~ "jsonb_typeof(metadata)"
    assert constraints["upstream_oauth_flows_interval_seconds_check"] =~ "interval_seconds > 0"
    assert constraints["upstream_oauth_flows_state_hash_shape_check"] =~ "octet_length"

    assert constraints["hourly_model_usage_rollups_bucket_started_at_hour_check"] =~
             "date_trunc('hour'"

    assert constraints["hourly_model_usage_rollups_model_code_check"] =~ "btrim(model_code)"

    for column <- [
          "request_count",
          "success_count",
          "failure_count",
          "retry_count",
          "input_tokens",
          "cached_input_tokens",
          "output_tokens",
          "reasoning_tokens",
          "total_tokens",
          "estimated_cost_micros",
          "settled_cost_micros"
        ] do
      check = constraints["hourly_model_usage_rollups_#{column}_check"]

      assert check =~ column
      assert check =~ ">="
    end
  end

  test "preserves JSONB, decimal-compatible money/rate fields, and integer token counters" do
    assert column_type("pool_routing_settings", "metadata") == "jsonb"
    assert column_type("pool_routing_settings", "prompt_cache_affinity_enabled") == "boolean"
    assert column_type("pool_routing_settings", "request_compression_enabled") == "boolean"
    assert column_type("models", "metadata") == "jsonb"
    assert column_type("ledger_entries", "details") == "jsonb"
    assert column_type("account_quota_windows", "metadata") == "jsonb"
    assert column_type("codex_files", "metadata") == "jsonb"
    assert column_type("instance_settings", "gateway") == "jsonb"
    assert column_type("instance_settings", "ingress") == "jsonb"
    assert column_type("instance_settings", "files") == "jsonb"
    assert column_type("instance_settings", "transcription") == "jsonb"
    assert column_type("instance_settings", "operator") == "jsonb"
    assert column_type("instance_settings", "development") == "jsonb"
    assert column_type("instance_settings", "metrics") == "jsonb"
    assert column_type("instance_settings", "smtp") == "jsonb"
    assert column_type("instance_settings", "metadata") == "jsonb"
    assert column_type("bridge_session_aliases", "metadata") == "jsonb"
    assert column_type("bridge_owner_leases", "metadata") == "jsonb"
    assert column_type("gateway_idempotency_keys", "response_metadata") == "jsonb"
    assert column_type("routing_circuit_states", "metadata") == "jsonb"
    assert column_type("account_quota_windows", "source_precision") == "text"
    assert column_type("account_quota_windows", "quota_scope") == "text"
    assert column_type("account_quota_windows", "quota_family") == "text"
    assert column_type("account_quota_windows", "model") == "text"
    assert column_type("account_quota_windows", "upstream_model") == "text"
    assert column_type("account_quota_windows", "raw_limit_id") == "text"
    assert column_type("account_quota_windows", "raw_limit_name") == "text"
    assert column_type("account_quota_windows", "raw_metered_feature") == "text"
    assert column_type("account_quota_windows", "observed_at") == "timestamp with time zone"
    assert column_type("account_quota_windows", "merge_precedence") == "integer"
    assert column_type("codex_files", "finalize_status") == "text"
    assert column_type("codex_files", "pool_upstream_assignment_id") == "uuid"
    assert column_type("codex_files", "upstream_identity_id") == "uuid"
    assert column_type("upstream_identities", "account_email") == "text"
    assert column_type("upstream_oauth_flows", "state_token_hash") == "bytea"
    assert column_type("upstream_oauth_flows", "code_verifier_ciphertext") == "bytea"
    assert column_type("upstream_oauth_flows", "device_auth_id_ciphertext") == "bytea"
    assert column_type("upstream_oauth_flows", "metadata") == "jsonb"

    assert column_type("pricing_snapshots", "input_token_micros") == "numeric(30,9)"
    assert column_type("pricing_snapshots", "request_base_micros") == "numeric(30,9)"
    assert column_type("ledger_entries", "estimated_cost_micros") == "numeric(30,9)"
    assert column_type("daily_rollups", "settled_cost_micros") == "numeric(30,9)"
    assert column_type("hourly_model_usage_rollups", "estimated_cost_micros") == "numeric(30,9)"
    assert column_type("hourly_model_usage_rollups", "settled_cost_micros") == "numeric(30,9)"
    assert column_type("account_quota_windows", "used_percent") == "numeric(6,3)"

    assert column_type("ledger_entries", "input_tokens") == "bigint"
    assert column_type("ledger_entries", "total_tokens") == "bigint"
    assert column_type("hourly_model_usage_rollups", "request_count") == "bigint"
    assert column_type("hourly_model_usage_rollups", "total_tokens") == "bigint"
    assert column_type("request_log_facts", "latest_input_tokens") == "bigint"
    assert column_type("request_log_facts", "latest_settled_cost_micros") == "bigint"
    assert column_type("request_log_facts", "latest_cached_input_cost_micros") == "bigint"

    assert column_type("request_log_facts", "latest_settlement_occurred_at") ==
             "timestamp without time zone"

    assert column_type("daily_rollups", "output_tokens") == "bigint"

    assert column_type("hourly_model_usage_rollups", "bucket_started_at") ==
             "timestamp without time zone"

    assert column_type("hourly_model_usage_rollups", "pool_id") == "uuid"
    assert column_type("hourly_model_usage_rollups", "model_id") == "uuid"
    assert column_type("hourly_model_usage_rollups", "model_code") == "text"
    assert column_type("api_key_policy_bindings", "max_tokens_per_day") == "bigint"
    assert column_type("api_key_policy_bindings", "max_tokens_per_week") == "bigint"
    assert column_type("codex_files", "byte_size") == "bigint"
    assert column_type("instance_settings", "lock_version") == "integer"

    assert column_type("api_keys", "enforced_model_identifier") == "text"
    assert column_type("api_keys", "enforced_reasoning_effort") == "text"
    assert column_type("api_keys", "maximum_reasoning_effort") == "text"
    assert column_type("api_keys", "enforced_service_tier") == "text"

    assert column_type("instance_settings", "updated_by_user_id") == "uuid"
    assert column_type("instance_settings", "inserted_at") == "timestamp without time zone"
    assert column_type("instance_settings", "updated_at") == "timestamp without time zone"

    assert column_type("alert_rules", "metadata") == "jsonb"
    assert column_type("alert_rules", "threshold_used_percent") == "numeric(6,3)"
    assert column_type("alert_channels", "webhook_signing_secret_ciphertext") == "bytea"
    assert column_type("alert_channels", "webhook_signing_secret_aad") == "jsonb"
    assert column_type("alert_incidents", "safe_evidence_snapshot") == "jsonb"
    assert column_type("alert_incidents", "suppression_metadata") == "jsonb"
    assert column_type("alert_incident_targets", "metadata") == "jsonb"
    assert column_type("alert_delivery_attempts", "response_metadata") == "jsonb"
    assert column_type("alert_delivery_attempts", "failure_metadata") == "jsonb"
    assert column_type("alert_delivery_attempts", "retryable") == "boolean"
  end

  test "preserves final foreign key actions including cascades and set-null behavior" do
    assert fk_action("sessions_user_id_fkey") == {"c", "a"}
    assert fk_action("api_keys_pool_id_fkey") == {"c", "a"}
    assert fk_action("attempts_pool_upstream_assignment_id_fkey") == {"c", "a"}
    assert fk_action("attempts_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("codex_sessions_pool_upstream_assignment_id_fkey") == {"c", "a"}
    assert fk_action("ledger_entries_pool_upstream_assignment_id_fkey") == {"n", "a"}
    assert fk_action("ledger_entries_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("request_log_facts_request_id_fkey") == {"c", "a"}
    assert fk_action("request_log_facts_latest_attempt_id_fkey") == {"n", "a"}
    assert fk_action("request_log_facts_latest_pool_upstream_assignment_id_fkey") == {"n", "a"}
    assert fk_action("request_log_facts_latest_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("request_log_facts_latest_settlement_entry_id_fkey") == {"n", "a"}
    assert fk_action("hourly_model_usage_rollups_pool_id_fkey") == {"c", "a"}
    assert fk_action("codex_turns_final_attempt_id_request_id_fkey") == {"a", "a"}
    assert fk_action("codex_files_request_id_fkey") == {"n", "a"}
    assert fk_action("codex_files_pool_upstream_assignment_id_fkey") == {"n", "a"}
    assert fk_action("codex_files_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("bridge_session_aliases_codex_session_id_fkey") == {"c", "a"}
    assert fk_action("bridge_owner_leases_pool_upstream_assignment_id_fkey") == {"n", "a"}
    assert fk_action("operator_pool_assignments_user_id_fkey") == {"c", "a"}
    assert fk_action("operator_pool_assignments_pool_id_fkey") == {"c", "a"}
    assert fk_action("operator_pool_assignments_created_by_user_id_fkey") == {"a", "a"}
    assert fk_action("instance_settings_updated_by_user_id_fkey") == {"n", "a"}
    assert fk_action("alert_rules_pool_id_fkey") == {"c", "a"}
    assert fk_action("alert_rules_created_by_user_id_fkey") == {"n", "a"}
    assert fk_action("alert_channels_created_by_user_id_fkey") == {"n", "a"}
    assert fk_action("alert_rule_channels_alert_rule_id_fkey") == {"c", "a"}
    assert fk_action("alert_rule_channels_alert_channel_id_fkey") == {"c", "a"}
    assert fk_action("alert_incidents_pool_id_fkey") == {"c", "a"}
    assert fk_action("alert_incidents_upstream_identity_id_fkey") == {"c", "a"}
    assert fk_action("alert_incident_receipts_operator_id_fkey") == {"c", "a"}
    assert fk_action("alert_incident_receipts_incident_id_fkey") == {"c", "a"}
    assert fk_action("alert_incident_targets_incident_id_fkey") == {"c", "a"}
    assert fk_action("alert_incident_targets_rule_id_fkey") == {"c", "a"}
    assert fk_action("alert_incident_targets_pool_id_fkey") == {"c", "a"}
    assert fk_action("alert_delivery_attempts_incident_id_fkey") == {"c", "a"}
    assert fk_action("alert_delivery_attempts_channel_id_fkey") == {"c", "a"}
    assert fk_action("upstream_oauth_flows_pool_id_fkey") == {"c", "a"}
    assert fk_action("upstream_oauth_flows_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("upstream_oauth_flows_requested_by_user_id_fkey") == {"a", "a"}
    assert fk_action("upstream_oauth_flows_result_upstream_identity_id_fkey") == {"n", "a"}
  end

  test "alert storage tables preserve the metadata-only alerting contract" do
    rule_columns = table_columns("alert_rules")

    assert Map.take(rule_columns, [
             "id",
             "pool_id",
             "scope_type",
             "rule_kind",
             "severity",
             "cooldown_minutes",
             "state",
             "target_state",
             "window_selector",
             "threshold_used_percent",
             "metadata",
             "created_at",
             "updated_at"
           ]) == %{
             "id" => {"uuid", "NO"},
             "pool_id" => {"uuid", "NO"},
             "scope_type" => {"text", "NO"},
             "rule_kind" => {"text", "NO"},
             "severity" => {"text", "NO"},
             "cooldown_minutes" => {"integer", "NO"},
             "state" => {"text", "NO"},
             "target_state" => {"text", "YES"},
             "window_selector" => {"text", "YES"},
             "threshold_used_percent" => {"numeric", "YES"},
             "metadata" => {"jsonb", "NO"},
             "created_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"}
           }

    channel_columns = table_columns("alert_channels")

    assert Map.take(channel_columns, [
             "channel_type",
             "state",
             "email_to",
             "endpoint_scheme",
             "endpoint_host",
             "endpoint_path_prefix",
             "endpoint_fingerprint",
             "endpoint_url_ciphertext",
             "endpoint_url_nonce",
             "endpoint_url_aad",
             "endpoint_url_key_version",
             "webhook_signing_secret_ciphertext",
             "webhook_signing_secret_nonce",
             "webhook_signing_secret_aad",
             "webhook_signing_secret_key_version",
             "metadata"
           ]) == %{
             "channel_type" => {"text", "NO"},
             "state" => {"text", "NO"},
             "email_to" => {"text", "YES"},
             "endpoint_scheme" => {"text", "YES"},
             "endpoint_host" => {"text", "YES"},
             "endpoint_path_prefix" => {"text", "YES"},
             "endpoint_fingerprint" => {"text", "YES"},
             "endpoint_url_ciphertext" => {"bytea", "YES"},
             "endpoint_url_nonce" => {"bytea", "YES"},
             "endpoint_url_aad" => {"jsonb", "NO"},
             "endpoint_url_key_version" => {"text", "YES"},
             "webhook_signing_secret_ciphertext" => {"bytea", "YES"},
             "webhook_signing_secret_nonce" => {"bytea", "YES"},
             "webhook_signing_secret_aad" => {"jsonb", "NO"},
             "webhook_signing_secret_key_version" => {"text", "YES"},
             "metadata" => {"jsonb", "NO"}
           }

    refute Map.has_key?(channel_columns, "webhook_signing_secret")
    refute Map.has_key?(channel_columns, "webhook_secret")

    incident_columns = table_columns("alert_incidents")

    assert Map.take(incident_columns, [
             "dedupe_key",
             "scope_type",
             "rule_kind",
             "severity",
             "state",
             "pool_id",
             "upstream_identity_id",
             "occurrence_count",
             "first_seen_at",
             "last_seen_at",
             "resolved_at",
             "safe_evidence_snapshot"
           ]) == %{
             "dedupe_key" => {"text", "NO"},
             "scope_type" => {"text", "NO"},
             "rule_kind" => {"text", "NO"},
             "severity" => {"text", "NO"},
             "state" => {"text", "NO"},
             "pool_id" => {"uuid", "YES"},
             "upstream_identity_id" => {"uuid", "YES"},
             "occurrence_count" => {"integer", "NO"},
             "first_seen_at" => {"timestamp without time zone", "NO"},
             "last_seen_at" => {"timestamp without time zone", "NO"},
             "resolved_at" => {"timestamp without time zone", "YES"},
             "safe_evidence_snapshot" => {"jsonb", "NO"}
           }

    target_columns = table_columns("alert_incident_targets")

    assert Map.take(target_columns, [
             "incident_id",
             "rule_id",
             "pool_id",
             "first_matched_at",
             "last_matched_at",
             "resolved_at"
           ]) == %{
             "incident_id" => {"uuid", "NO"},
             "rule_id" => {"uuid", "NO"},
             "pool_id" => {"uuid", "NO"},
             "first_matched_at" => {"timestamp without time zone", "NO"},
             "last_matched_at" => {"timestamp without time zone", "NO"},
             "resolved_at" => {"timestamp without time zone", "YES"}
           }

    receipt_columns = table_columns("alert_incident_receipts")

    assert Map.take(receipt_columns, [
             "id",
             "operator_id",
             "incident_id",
             "read_at",
             "dismissed_at",
             "created_at",
             "updated_at"
           ]) == %{
             "id" => {"uuid", "NO"},
             "operator_id" => {"uuid", "NO"},
             "incident_id" => {"uuid", "NO"},
             "read_at" => {"timestamp without time zone", "YES"},
             "dismissed_at" => {"timestamp without time zone", "YES"},
             "created_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"}
           }

    attempt_columns = table_columns("alert_delivery_attempts")

    assert Map.take(attempt_columns, [
             "incident_id",
             "channel_id",
             "attempt_number",
             "max_attempts",
             "status",
             "scheduled_at",
             "next_retry_at",
             "response_status_code",
             "retryable",
             "response_metadata",
             "failure_metadata"
           ]) == %{
             "incident_id" => {"uuid", "NO"},
             "channel_id" => {"uuid", "NO"},
             "attempt_number" => {"integer", "NO"},
             "max_attempts" => {"integer", "NO"},
             "status" => {"text", "NO"},
             "scheduled_at" => {"timestamp without time zone", "NO"},
             "next_retry_at" => {"timestamp without time zone", "YES"},
             "response_status_code" => {"integer", "YES"},
             "retryable" => {"boolean", "NO"},
             "response_metadata" => {"jsonb", "NO"},
             "failure_metadata" => {"jsonb", "NO"}
           }

    assert AlertRule.__schema__(:source) == "alert_rules"
    assert AlertChannel.__schema__(:source) == "alert_channels"
    assert AlertRuleChannel.__schema__(:source) == "alert_rule_channels"
    assert AlertIncident.__schema__(:source) == "alert_incidents"
    assert AlertIncidentReceipt.__schema__(:source) == "alert_incident_receipts"
    assert AlertIncidentTarget.__schema__(:source) == "alert_incident_targets"
    assert AlertDeliveryAttempt.__schema__(:source) == "alert_delivery_attempts"

    assert AlertRule.__schema__(:type, :threshold_used_percent) == :decimal
    assert AlertChannel.__schema__(:type, :endpoint_url_ciphertext) == :binary
    assert AlertChannel.__schema__(:type, :webhook_signing_secret_ciphertext) == :binary
    assert AlertIncident.__schema__(:type, :safe_evidence_snapshot) == :map
    assert AlertIncidentReceipt.__schema__(:type, :read_at) == :utc_datetime_usec
    assert AlertIncidentReceipt.__schema__(:type, :dismissed_at) == :utc_datetime_usec
    assert AlertIncidentTarget.__schema__(:type, :last_matched_at) == :utc_datetime_usec
    assert AlertDeliveryAttempt.__schema__(:type, :max_attempts) == :integer
  end

  test "request log facts preserve the 1:1 metadata-only projection contract" do
    columns = table_columns("request_log_facts")

    assert Map.take(columns, [
             "request_id",
             "latest_attempt_id",
             "latest_attempt_number",
             "latest_attempt_status",
             "latest_attempt_retryable",
             "latest_upstream_status_code",
             "latest_pool_upstream_assignment_id",
             "latest_upstream_identity_id",
             "latest_network_error_code",
             "latest_latency_ms",
             "latest_settlement_entry_id",
             "latest_settlement_usage_status",
             "latest_settlement_pricing_status",
             "latest_input_tokens",
             "latest_cached_input_tokens",
             "latest_cache_write_tokens",
             "latest_output_tokens",
             "latest_reasoning_tokens",
             "latest_total_tokens",
             "latest_settled_cost_micros",
             "latest_cached_input_cost_micros",
             "latest_cached_input_token_micros",
             "latest_settlement_occurred_at",
             "latest_settlement_created_at",
             "inserted_at",
             "updated_at"
           ]) == %{
             "request_id" => {"uuid", "NO"},
             "latest_attempt_id" => {"uuid", "YES"},
             "latest_attempt_number" => {"integer", "YES"},
             "latest_attempt_status" => {"character varying", "YES"},
             "latest_attempt_retryable" => {"boolean", "YES"},
             "latest_upstream_status_code" => {"integer", "YES"},
             "latest_pool_upstream_assignment_id" => {"uuid", "YES"},
             "latest_upstream_identity_id" => {"uuid", "YES"},
             "latest_network_error_code" => {"character varying", "YES"},
             "latest_latency_ms" => {"integer", "YES"},
             "latest_settlement_entry_id" => {"uuid", "YES"},
             "latest_settlement_usage_status" => {"character varying", "YES"},
             "latest_settlement_pricing_status" => {"character varying", "YES"},
             "latest_input_tokens" => {"bigint", "YES"},
             "latest_cached_input_tokens" => {"bigint", "YES"},
             "latest_cache_write_tokens" => {"bigint", "YES"},
             "latest_output_tokens" => {"bigint", "YES"},
             "latest_reasoning_tokens" => {"bigint", "YES"},
             "latest_total_tokens" => {"bigint", "YES"},
             "latest_settled_cost_micros" => {"bigint", "YES"},
             "latest_cached_input_cost_micros" => {"bigint", "YES"},
             "latest_cached_input_token_micros" => {"bigint", "YES"},
             "latest_settlement_occurred_at" => {"timestamp without time zone", "YES"},
             "latest_settlement_created_at" => {"timestamp without time zone", "YES"},
             "inserted_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"}
           }

    assert Map.keys(columns) |> Enum.sort() ==
             [
               "inserted_at",
               "latest_attempt_id",
               "latest_attempt_number",
               "latest_attempt_retryable",
               "latest_attempt_status",
               "latest_cache_write_tokens",
               "latest_cached_input_cost_micros",
               "latest_cached_input_token_micros",
               "latest_cached_input_tokens",
               "latest_input_tokens",
               "latest_latency_ms",
               "latest_network_error_code",
               "latest_output_tokens",
               "latest_pool_upstream_assignment_id",
               "latest_reasoning_tokens",
               "latest_settled_cost_micros",
               "latest_settlement_created_at",
               "latest_settlement_entry_id",
               "latest_settlement_occurred_at",
               "latest_settlement_pricing_status",
               "latest_settlement_usage_status",
               "latest_total_tokens",
               "latest_upstream_identity_id",
               "latest_upstream_status_code",
               "request_id",
               "updated_at"
             ]

    assert RequestLogFact.__schema__(:source) == "request_log_facts"
    assert RequestLogFact.__schema__(:primary_key) == [:request_id]
    assert RequestLogFact.__schema__(:type, :request_id) == :binary_id
    assert RequestLogFact.__schema__(:type, :latest_attempt_id) == :binary_id
    assert RequestLogFact.__schema__(:type, :latest_input_tokens) == :integer
    assert RequestLogFact.__schema__(:type, :latest_settlement_pricing_status) == :string
    assert RequestLogFact.__schema__(:type, :latest_settlement_occurred_at) == :utc_datetime_usec

    forbidden_columns = ~w(
      pool_id api_key_id status model requested_model endpoint transport admitted_at completed_at
      request_metadata response_metadata details prompt request_body response_body authorization
      cookie websocket_frame idempotency_key
    )

    for column <- forbidden_columns do
      refute Map.has_key?(columns, column)
    end
  end

  test "hourly model usage rollups preserve the metadata-only storage contract" do
    columns = table_columns("hourly_model_usage_rollups")

    assert columns == %{
             "id" => {"uuid", "NO"},
             "bucket_started_at" => {"timestamp without time zone", "NO"},
             "pool_id" => {"uuid", "NO"},
             "model_id" => {"uuid", "YES"},
             "model_code" => {"text", "NO"},
             "request_count" => {"bigint", "NO"},
             "success_count" => {"bigint", "NO"},
             "failure_count" => {"bigint", "NO"},
             "retry_count" => {"bigint", "NO"},
             "input_tokens" => {"bigint", "NO"},
             "cached_input_tokens" => {"bigint", "NO"},
             "output_tokens" => {"bigint", "NO"},
             "reasoning_tokens" => {"bigint", "NO"},
             "total_tokens" => {"bigint", "NO"},
             "estimated_cost_micros" => {"numeric", "NO"},
             "settled_cost_micros" => {"numeric", "NO"},
             "created_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"}
           }

    assert HourlyModelUsageRollup.__schema__(:source) == "hourly_model_usage_rollups"
    assert HourlyModelUsageRollup.__schema__(:type, :bucket_started_at) == :utc_datetime_usec
    assert HourlyModelUsageRollup.__schema__(:type, :pool_id) == :binary_id
    assert HourlyModelUsageRollup.__schema__(:type, :model_id) == :binary_id
    assert HourlyModelUsageRollup.__schema__(:type, :model_code) == :string
    assert HourlyModelUsageRollup.__schema__(:type, :request_count) == :integer
    assert HourlyModelUsageRollup.__schema__(:type, :total_tokens) == :integer
    assert HourlyModelUsageRollup.__schema__(:type, :settled_cost_micros) == :decimal

    for forbidden <- ~w(
          prompt request_body response_body authorization cookie websocket_frame idempotency_key
          request_metadata response_metadata details
        ) do
      refute Map.has_key?(columns, forbidden)
    end
  end

  test "operator pool assignments preserve the scoped admin grant storage contract" do
    columns = table_columns("operator_pool_assignments")

    assert Map.take(columns, [
             "id",
             "user_id",
             "pool_id",
             "status",
             "created_by_user_id",
             "created_at",
             "updated_at",
             "revoked_at"
           ]) == %{
             "id" => {"uuid", "NO"},
             "user_id" => {"uuid", "NO"},
             "pool_id" => {"uuid", "NO"},
             "status" => {"text", "NO"},
             "created_by_user_id" => {"uuid", "YES"},
             "created_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"},
             "revoked_at" => {"timestamp without time zone", "YES"}
           }

    assert OperatorPoolAssignment.__schema__(:source) == "operator_pool_assignments"
    assert OperatorPoolAssignment.__schema__(:type, :user_id) == :binary_id
    assert OperatorPoolAssignment.__schema__(:type, :pool_id) == :binary_id
    assert OperatorPoolAssignment.__schema__(:type, :status) == :string
    assert OperatorPoolAssignment.__schema__(:type, :created_by_user_id) == :binary_id
    assert OperatorPoolAssignment.__schema__(:type, :created_at) == :utc_datetime_usec
    assert OperatorPoolAssignment.__schema__(:type, :updated_at) == :utc_datetime_usec
    assert OperatorPoolAssignment.__schema__(:type, :revoked_at) == :utc_datetime_usec
  end

  test "instance settings singleton table preserves the typed singleton contract" do
    columns = table_columns("instance_settings")

    assert Map.take(columns, [
             "singleton",
             "gateway",
             "ingress",
             "files",
             "transcription",
             "operator",
             "metrics",
             "smtp",
             "metadata",
             "lock_version",
             "updated_by_user_id",
             "inserted_at",
             "updated_at"
           ]) == %{
             "singleton" => {"boolean", "NO"},
             "gateway" => {"jsonb", "NO"},
             "ingress" => {"jsonb", "NO"},
             "files" => {"jsonb", "NO"},
             "transcription" => {"jsonb", "NO"},
             "operator" => {"jsonb", "NO"},
             "metrics" => {"jsonb", "NO"},
             "smtp" => {"jsonb", "NO"},
             "metadata" => {"jsonb", "NO"},
             "lock_version" => {"integer", "NO"},
             "updated_by_user_id" => {"uuid", "YES"},
             "inserted_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"}
           }

    assert Settings.__schema__(:source) == "instance_settings"
    assert Settings.__schema__(:primary_key) == [:singleton]
    assert Settings.__schema__(:type, :singleton) == :boolean
    assert Settings.__schema__(:type, :lock_version) == :integer
    assert Settings.__schema__(:type, :updated_by_user_id) == :binary_id
    assert Settings.__schema__(:type, :metadata) == :map
    assert Settings.__schema__(:type, :inserted_at) == :utc_datetime_usec
    assert Settings.__schema__(:type, :updated_at) == :utc_datetime_usec

    for embed <- [
          :gateway,
          :ingress,
          :files,
          :transcription,
          :operator,
          :development,
          :metrics,
          :smtp
        ] do
      assert %Ecto.Embedded{cardinality: :one} = Settings.__schema__(:embed, embed)
    end
  end

  test "pool routing settings expose feature flags as non-null boolean storage" do
    columns = table_columns("pool_routing_settings")

    assert columns["prompt_cache_affinity_enabled"] == {"boolean", "NO"}
    assert columns["request_compression_enabled"] == {"boolean", "NO"}

    assert [["true"]] =
             Repo.query!("""
             SELECT column_default
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'pool_routing_settings'
               AND column_name = 'prompt_cache_affinity_enabled'
             """).rows

    assert [["false"]] =
             Repo.query!("""
             SELECT column_default
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'pool_routing_settings'
               AND column_name = 'request_compression_enabled'
             """).rows
  end

  test "pool routing settings omit removed analytics forwarding storage" do
    columns = table_columns("pool_routing_settings")
    removed_column = "control_plane" <> "_analytics_forwarding_enabled"
    schema_field_names = Enum.map(RoutingSettings.__schema__(:fields), &Atom.to_string/1)

    refute Map.has_key?(columns, removed_column)
    refute removed_column in schema_field_names
  end

  test "codex files expose bridge metadata columns without upload table dependency" do
    columns = table_columns("codex_files")

    assert Map.take(columns, [
             "file_id",
             "pool_upstream_assignment_id",
             "upstream_identity_id",
             "finalize_status",
             "metadata"
           ]) == %{
             "file_id" => {"text", "NO"},
             "pool_upstream_assignment_id" => {"uuid", "YES"},
             "upstream_identity_id" => {"uuid", "YES"},
             "finalize_status" => {"text", "NO"},
             "metadata" => {"jsonb", "NO"}
           }

    for removed <- ["storage_key", "storage_path", "sha256", "upload_expires_at"] do
      refute Map.has_key?(columns, removed)
    end

    refute "codex_file_uploads" in public_tables()
    assert FileRecord.__schema__(:type, :pool_upstream_assignment_id) == :binary_id
    assert FileRecord.__schema__(:type, :upstream_identity_id) == :binary_id
    assert FileRecord.__schema__(:type, :finalize_status) == :string
    refute :storage_key in FileRecord.__schema__(:fields)
    refute :sha256 in FileRecord.__schema__(:fields)
    refute :upload_expires_at in FileRecord.__schema__(:fields)
  end

  test "Ecto schemas expose deliberate types for JSONB, decimals, and token counters" do
    assert Enum.sort(Enum.map(@schema_modules, & &1.__schema__(:source))) ==
             Enum.sort(@expected_tables)

    assert PricingSnapshot.__schema__(:type, :input_token_micros) == :decimal

    assert LedgerEntry.__schema__(:type, :estimated_cost_micros) ==
             :decimal

    assert DailyRollup.__schema__(:type, :settled_cost_micros) == :decimal
    assert Quota.AccountQuotaWindow.__schema__(:type, :used_percent) == :decimal

    assert Quota.AccountQuotaWindow.__schema__(:type, :observed_at) ==
             :utc_datetime_usec

    assert Quota.AccountQuotaWindow.__schema__(:type, :merge_precedence) ==
             :integer

    assert LedgerEntry.__schema__(:type, :input_tokens) == :integer
    assert DailyRollup.__schema__(:type, :total_tokens) == :integer
    assert HourlyModelUsageRollup.__schema__(:type, :total_tokens) == :integer

    assert APIKeyPolicyBinding.__schema__(:type, :max_tokens_per_day) ==
             :integer

    assert APIKeyPolicyBinding.__schema__(:type, :max_tokens_per_week) ==
             :integer

    assert APIKey.__schema__(:type, :enforced_model_identifier) == :string
    assert APIKey.__schema__(:type, :enforced_reasoning_effort) == :string
    assert APIKey.__schema__(:type, :maximum_reasoning_effort) == :string
    assert APIKey.__schema__(:type, :enforced_service_tier) == :string

    assert UpstreamIdentity.__schema__(:type, :account_email) == :string

    assert RoutingSettings.__schema__(:type, :prompt_cache_affinity_enabled) ==
             :boolean

    assert RoutingSettings.__schema__(:type, :request_compression_enabled) ==
             :boolean

    assert Model.__schema__(:type, :metadata) == :map
    assert FileRecord.__schema__(:type, :byte_size) == :integer
    assert BridgeSessionAlias.__schema__(:type, :alias_hash) == :binary
    assert RoutingCircuitState.__schema__(:type, :failure_count) == :integer
  end

  test "phoenix filter parameters keep instance setting secret fields redacted" do
    config_source = File.read!(Path.expand("../../config/config.exs", __DIR__))

    for key <- ["token", "password", "bearer_token", "bearer_token_action", "password_action"] do
      assert config_source =~ ~s("#{key}")
    end
  end

  test "quota evidence identity records are deterministic duplicates" do
    %{identity: identity} = upstream_assignment_fixture(pool_fixture())
    observed_at = ~U[2026-04-27 12:00:00Z]

    attrs = %{
      quota_key: "gpt-5.3-codex-spark",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("42.0"),
      source: "codex_response_headers",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "GPT-5.3-Codex-Spark",
      raw_limit_id: "codex-bengalfox",
      raw_limit_name: "gpt-5.3-codex-spark",
      raw_metered_feature: "codex-bengalfox",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      merge_precedence: 70,
      metadata: %{"header_limit_id" => "codex-bengalfox"}
    }

    assert {:ok, first} = QuotaWindows.record_evidence(identity, attrs)

    assert {:ok, second} =
             QuotaWindows.record_evidence(
               identity,
               %{attrs | model: "gpt-5.3-codex-spark", used_percent: Decimal.new("51.5")}
             )

    assert second.id == first.id
    assert Decimal.equal?(second.used_percent, Decimal.new("51.500"))

    assert [[1]] =
             Repo.query!(
               """
               SELECT COUNT(*)
               FROM account_quota_windows
               WHERE upstream_identity_id = $1::uuid
                 AND quota_family = 'codex_model'
                  AND quota_key = 'codex_spark'
                 AND window_kind = 'primary'
                 AND source = 'codex_response_headers'
               """,
               [Ecto.UUID.dump!(identity.id)]
             ).rows
  end

  defp constraint_definitions do
    Repo.query!("""
    SELECT conname, pg_get_constraintdef(oid)
    FROM pg_constraint
    WHERE connamespace = 'public'::regnamespace
    """).rows
    |> Map.new(fn [name, definition] -> {name, definition} end)
  end

  defp public_tables do
    Repo.query!("""
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
    ORDER BY tablename ASC
    """).rows
    |> Enum.map(&List.first/1)
  end

  defp table_columns(table_name) do
    Repo.query!(
      """
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = $1
      """,
      [table_name]
    ).rows
    |> Map.new(fn [name, type, nullable] -> {name, {type, nullable}} end)
  end

  defp constraint_containing?(constraints, text) do
    Enum.any?(constraints, fn {_name, definition} -> definition =~ text end)
  end

  defp column_type(table_name, column_name) do
    [[type]] =
      Repo.query!(
        """
        SELECT format_type(a.atttypid, a.atttypmod)
        FROM pg_attribute AS a
        JOIN pg_class AS c ON c.oid = a.attrelid
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = $1
          AND a.attname = $2
          AND a.attnum > 0
          AND NOT a.attisdropped
        """,
        [table_name, column_name]
      ).rows

    type
  end

  defp fk_action(constraint_name) do
    [[delete_action, update_action]] =
      Repo.query!(
        """
        SELECT confdeltype::text, confupdtype::text
        FROM pg_constraint
        WHERE connamespace = 'public'::regnamespace
          AND conname = $1
        """,
        [constraint_name]
      ).rows

    {delete_action, update_action}
  end
end
