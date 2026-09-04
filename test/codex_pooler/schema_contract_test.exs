defmodule CodexPooler.SchemaContractTest do
  use CodexPooler.DataCase, async: false

  alias Ecto.Migration.Runner

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

  alias CodexPooler.Accounting.{
    Attempt,
    DailyRollup,
    DailyRollupCoverage,
    HourlyModelUsageRollup,
    LedgerEntry,
    RequestLogFact,
    RequestReplayEntitlement
  }

  alias CodexPooler.Admin.PoolTrafficGate
  alias CodexPooler.Catalog.{Model, PricingSnapshot}
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexTurn, RoutingCircuitState}
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Pools.{OperatorPoolAssignment, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.{OAuthFlow, UpstreamIdentity}

  @expected_tables ~w(
    account_quota_windows admin_pool_traffic_gates alert_channels alert_delivery_attempts alert_incident_receipts alert_incident_targets alert_incidents
    alert_rule_channels alert_rules api_key_policy_bindings api_keys attempts audit_events bridge_owner_leases
    bridge_session_aliases codex_files codex_sessions codex_turns daily_rollup_coverages daily_rollups hourly_model_usage_rollups
    encrypted_secrets gateway_idempotency_keys instance_settings invite_acceptances invites ledger_entries memberships request_replay_entitlements
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
    PoolTrafficGate,
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
    DailyRollupCoverage,
    HourlyModelUsageRollup,
    LedgerEntry,
    RequestReplayEntitlement,
    RequestLogFact,
    CodexPooler.Audit.AuditEvent,
    Model,
    PricingSnapshot,
    CodexPooler.Catalog.SyncRun,
    CodexPooler.Files.FileRecord,
    Attempt,
    CodexPooler.Gateway.Persistence.BridgeOwnerLease,
    CodexPooler.Gateway.Persistence.BridgeSessionAlias,
    CodexPooler.Gateway.Persistence.CodexSession,
    CodexTurn,
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
  end

  @tag :shared_pool_traffic_gate
  test "stores the operator-scoped Pool traffic gate with fenced lease and cascade cleanup" do
    columns = table_columns("admin_pool_traffic_gates")

    assert columns == %{
             "operator_id" => {"uuid", "NO"},
             "owner_token" => {"uuid", "YES"},
             "lease_expires_at" => {"timestamp without time zone", "YES"},
             "cooldown_until" => {"timestamp without time zone", "NO"},
             "inserted_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"}
           }

    constraints = constraint_definitions()

    assert constraints["admin_pool_traffic_gates_owner_lease_pair_check"] =~
             "(owner_token IS NULL) = (lease_expires_at IS NULL)"

    assert fk_action("admin_pool_traffic_gates_operator_id_fkey") == {"c", "a"}
    assert PoolTrafficGate.__schema__(:primary_key) == [:operator_id]
    assert PoolTrafficGate.__schema__(:type, :owner_token) == :binary_id
    assert PoolTrafficGate.__schema__(:type, :lease_expires_at) == :utc_datetime_usec
    assert PoolTrafficGate.__schema__(:type, :cooldown_until) == :utc_datetime_usec
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
          "admin_pool_traffic_gates_pkey",
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
          "daily_rollup_coverages_pkey",
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

    assert indexes["daily_rollup_coverages_pkey"] =~ "(rollup_date)"

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

    assert constraints["daily_rollups_admitted_request_count_check"] ==
             "CHECK ((admitted_request_count >= 0))"

    assert constraints["daily_rollups_rounded_settled_cost_micros_check"] ==
             "CHECK ((rounded_settled_cost_micros >= (0)::numeric))"

    assert constraints["daily_rollup_coverages_contract_version_check"] ==
             "CHECK ((contract_version > 0))"

    assert constraints["daily_rollup_coverages_mutation_version_check"] ==
             "CHECK ((mutation_version >= 0))"

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
    refute constraints["api_keys_enforced_service_tier_check"] =~ "'fast'"
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

    route_class_values =
      ~r/'([^']+)'/
      |> Regex.scan(constraints["alert_rules_route_class_check"], capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assert route_class_values ==
             MapSet.new(AlertRule.route_class_rule_kinds() ++ RouteClass.all())

    assert AlertRule.route_classes() == RouteClass.all()
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
    assert column_type("daily_rollups", "rounded_settled_cost_micros") == "numeric(30,0)"
    assert column_type("hourly_model_usage_rollups", "estimated_cost_micros") == "numeric(30,9)"
    assert column_type("hourly_model_usage_rollups", "settled_cost_micros") == "numeric(30,9)"
    assert column_type("account_quota_windows", "used_percent") == "numeric(6,3)"

    assert column_type("ledger_entries", "input_tokens") == "bigint"
    assert column_type("ledger_entries", "total_tokens") == "bigint"
    assert column_type("daily_rollups", "admitted_request_count") == "bigint"
    assert column_type("hourly_model_usage_rollups", "request_count") == "bigint"
    assert column_type("hourly_model_usage_rollups", "total_tokens") == "bigint"
    assert column_type("request_log_facts", "latest_input_tokens") == "bigint"
    assert column_type("request_log_facts", "latest_settled_cost_micros") == "bigint"
    assert column_type("request_log_facts", "latest_estimated_cost_micros") == "bigint"
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
             "latest_estimated_cost_micros",
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
             "latest_estimated_cost_micros" => {"bigint", "YES"},
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
               "latest_estimated_cost_micros",
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

  test "daily Pool rollups and date coverage preserve exact usage storage" do
    daily_rollup_columns = table_columns("daily_rollups")

    assert daily_rollup_columns["admitted_request_count"] == {"bigint", "NO"}
    assert daily_rollup_columns["rounded_settled_cost_micros"] == {"numeric", "NO"}

    assert [["0"]] =
             Repo.query!("""
             SELECT column_default
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'daily_rollups'
               AND column_name = 'admitted_request_count'
             """).rows

    assert [["0"]] =
             Repo.query!("""
             SELECT column_default
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'daily_rollups'
               AND column_name = 'rounded_settled_cost_micros'
             """).rows

    assert table_columns("daily_rollup_coverages") == %{
             "rollup_date" => {"date", "NO"},
             "contract_version" => {"integer", "NO"},
             "completed_at" => {"timestamp without time zone", "YES"},
             "mutation_version" => {"bigint", "NO"},
             "created_at" => {"timestamp without time zone", "NO"},
             "updated_at" => {"timestamp without time zone", "NO"}
           }

    assert DailyRollupCoverage.__schema__(:source) == "daily_rollup_coverages"
    assert DailyRollupCoverage.__schema__(:primary_key) == [:rollup_date]
    assert DailyRollupCoverage.__schema__(:type, :rollup_date) == :date
    assert DailyRollupCoverage.__schema__(:type, :contract_version) == :integer
    assert DailyRollupCoverage.__schema__(:type, :completed_at) == :utc_datetime_usec
    assert DailyRollupCoverage.__schema__(:type, :mutation_version) == :integer

    assert trigger_names("requests") =~ "requests_track_pool_daily_rollup_mutation"
    assert trigger_names("ledger_entries") =~ "ledger_entries_track_pool_daily_rollup_mutation"
    assert trigger_names("daily_rollups") =~ "daily_rollups_track_pool_daily_rollup_mutation"

    assert trigger_names("daily_rollup_coverages") =~
             "daily_rollup_coverages_guard_contract"

    deferred_triggers =
      trigger_contracts([
        "requests_track_pool_daily_rollup_mutation",
        "ledger_entries_track_pool_daily_rollup_mutation",
        "daily_rollups_track_pool_daily_rollup_mutation"
      ])

    assert Enum.all?(deferred_triggers, fn {_name, constraint_oid, deferrable, initially_deferred} ->
             constraint_oid != 0 and deferrable and initially_deferred
           end)

    assert [
             {"daily_rollup_coverages_guard_contract", 0, false, false}
           ] = trigger_contracts(["daily_rollup_coverages_guard_contract"])

    assert function_search_paths([
             "guard_pool_daily_rollup_coverage_contract",
             "mark_pool_daily_rollup_dates_mutated",
             "track_daily_rollup_pool_mutation",
             "track_ledger_pool_daily_rollup_mutation",
             "track_request_pool_daily_rollup_mutation"
           ]) ==
             Map.new(
               [
                 "guard_pool_daily_rollup_coverage_contract",
                 "mark_pool_daily_rollup_dates_mutated",
                 "track_daily_rollup_pool_mutation",
                 "track_ledger_pool_daily_rollup_mutation",
                 "track_request_pool_daily_rollup_mutation"
               ],
               &{&1, ["search_path=pg_catalog, public"]}
             )
  end

  @tag :pool_usage_rollup_migration_round_trip
  test "Pool daily coverage fence migration upgrades legacy rows and downgrades fail closed" do
    completed_at = ~U[2026-08-14 00:17:00.000000Z]
    rollup_date = ~D[2026-08-13]

    run_pool_daily_coverage_migration!(:down)
    on_exit(&ensure_pool_daily_coverage_migration_up!/0)

    Repo.query!(
      """
      INSERT INTO daily_rollup_coverages (
        rollup_date, contract_version, completed_at, created_at, updated_at
      )
      VALUES ($1, 1, $2, $2, $2)
      """,
      [rollup_date, completed_at]
    )

    run_pool_daily_coverage_migration!(:up)

    assert [[2, nil, 0]] =
             Repo.query!(
               """
               SELECT contract_version, completed_at, mutation_version
               FROM daily_rollup_coverages
               WHERE rollup_date = $1
               """,
               [rollup_date]
             ).rows

    run_pool_daily_coverage_migration!(:down)

    assert [[0]] = Repo.query!("SELECT COUNT(*) FROM daily_rollup_coverages").rows
    refute Map.has_key?(table_columns("daily_rollup_coverages"), "mutation_version")

    assert table_columns("daily_rollup_coverages")["completed_at"] ==
             {"timestamp without time zone", "NO"}

    assert trigger_contracts([
             "requests_track_pool_daily_rollup_mutation",
             "ledger_entries_track_pool_daily_rollup_mutation",
             "daily_rollups_track_pool_daily_rollup_mutation",
             "daily_rollup_coverages_guard_contract"
           ]) == []

    assert function_search_paths([
             "guard_pool_daily_rollup_coverage_contract",
             "mark_pool_daily_rollup_dates_mutated",
             "track_daily_rollup_pool_mutation",
             "track_ledger_pool_daily_rollup_mutation",
             "track_request_pool_daily_rollup_mutation"
           ]) == %{}

    run_pool_daily_coverage_migration!(:up)
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

  @tag :replay_schema
  test "replay entitlement schema exposes only immutable metadata and strict lifecycle types" do
    columns = table_columns("request_replay_entitlements")

    assert Map.take(columns, [
             "request_id",
             "codex_turn_id",
             "eligible_attempt_id",
             "replay_attempt_id",
             "api_key_runtime_epoch",
             "model_identifier",
             "semantic_turn_digest",
             "replay_claim_digest",
             "provisional_binding_digest",
             "replay_generation",
             "owner_lease_digest",
             "owner_lease_key_version",
             "predecessor_epoch",
             "status",
             "armed_at",
             "expires_at",
             "consumed_at",
             "started_at",
             "last_liveness_at",
             "abandon_at",
             "terminal_at",
             "closed_at",
             "cleanup_checked_at"
           ]) == %{
             "request_id" => {"uuid", "NO"},
             "codex_turn_id" => {"uuid", "NO"},
             "eligible_attempt_id" => {"uuid", "NO"},
             "replay_attempt_id" => {"uuid", "YES"},
             "api_key_runtime_epoch" => {"bigint", "NO"},
             "model_identifier" => {"text", "NO"},
             "semantic_turn_digest" => {"bytea", "NO"},
             "replay_claim_digest" => {"bytea", "NO"},
             "provisional_binding_digest" => {"bytea", "YES"},
             "replay_generation" => {"integer", "NO"},
             "owner_lease_digest" => {"bytea", "NO"},
             "owner_lease_key_version" => {"text", "NO"},
             "predecessor_epoch" => {"bigint", "NO"},
             "status" => {"text", "NO"},
             "armed_at" => {"timestamp with time zone", "NO"},
             "expires_at" => {"timestamp with time zone", "NO"},
             "consumed_at" => {"timestamp with time zone", "YES"},
             "started_at" => {"timestamp with time zone", "YES"},
             "last_liveness_at" => {"timestamp with time zone", "YES"},
             "abandon_at" => {"timestamp with time zone", "YES"},
             "terminal_at" => {"timestamp with time zone", "YES"},
             "closed_at" => {"timestamp with time zone", "YES"},
             "cleanup_checked_at" => {"timestamp with time zone", "YES"}
           }

    assert RequestReplayEntitlement.statuses() == ~w(armed consumed expired revoked)
    assert RequestReplayEntitlement.__schema__(:type, :semantic_turn_digest) == :binary
    assert RequestReplayEntitlement.__schema__(:type, :armed_at) == :utc_datetime_usec
    assert RequestReplayEntitlement.__schema__(:type, :cleanup_checked_at) == :utc_datetime_usec
    assert Attempt.__schema__(:type, :replay_generation) == :integer

    assert CodexTurn.__schema__(
             :type,
             :semantic_turn_digest
           ) == :binary

    constraints = constraint_definitions()
    assert constraints["codex_turns_semantic_turn_digest_shape_check"] =~ "octet_length"
    assert constraints["attempts_replay_generation_check"] =~ "replay_generation >= 0"
    assert constraints["request_replay_entitlements_lifecycle_tuple_check"] =~ "consumed"

    for {name, expected_action} <- replay_foreign_key_actions() do
      assert fk_action(name) == expected_action
    end

    indexes = index_definitions()
    assert indexes["codex_turns_id_request_id_uq"] =~ "UNIQUE INDEX"
    assert indexes["codex_turns_active_semantic_turn_uq"] =~ "status = 'in_progress'"
    assert indexes["request_replay_entitlements_request_id_uq"] =~ "UNIQUE INDEX"

    assert indexes["request_replay_entitlements_cleanup_due_idx"] =~
             "cleanup_checked_at NULLS FIRST"

    assert indexes["request_replay_entitlements_cleanup_due_idx"] =~ "expires_at, abandon_at, id"
    assert indexes["request_replay_entitlements_cleanup_due_idx"] =~ "WHERE (closed_at IS NULL)"

    assert [["0"]] = column_default("attempts", "replay_generation")
    assert [["1"]] = column_default("request_replay_entitlements", "replay_generation")

    assert [["request_replay_db_now", "v"]] =
             Repo.query!("""
             SELECT proname, provolatile::text
             FROM pg_proc
             WHERE pronamespace = 'public'::regnamespace
               AND proname = 'request_replay_db_now'
             """).rows

    assert replay_function_contracts() == %{
             "enforce_request_replay_entitlement_update" =>
               {"v", "u", ["search_path=pg_catalog"]},
             "enforce_request_replay_request_storage" => {"v", "u", ["search_path=pg_catalog"]},
             "enforce_request_replay_turn_snapshot" => {"v", "u", ["search_path=pg_catalog"]},
             "request_replay_db_now" => {"v", "s", ["search_path=pg_catalog"]}
           }

    assert replay_trigger_names() == [
             "request_replay_codex_turns_snapshot_guard",
             "request_replay_entitlements_insert_guard",
             "request_replay_entitlements_update_guard",
             "request_replay_requests_storage_guard"
           ]
  end

  @tag :replay_schema
  test "replay entitlement changeset rejects malformed tuples before persistence" do
    now = ~U[2026-09-02 00:00:00.000000Z]

    attrs = %{
      request_id: Ecto.UUID.generate(),
      codex_turn_id: Ecto.UUID.generate(),
      eligible_attempt_id: Ecto.UUID.generate(),
      api_key_id: Ecto.UUID.generate(),
      api_key_runtime_epoch: 0,
      pool_id: Ecto.UUID.generate(),
      model_id: Ecto.UUID.generate(),
      model_identifier: "gpt-example",
      semantic_turn_digest: <<1::256>>,
      replay_claim_digest: <<2::256>>,
      replay_generation: 1,
      owner_lease_digest: <<3::256>>,
      owner_lease_key_version: "v1",
      predecessor_epoch: 1,
      status: "armed",
      armed_at: now,
      expires_at: DateTime.add(now, 30, :second)
    }

    assert RequestReplayEntitlement.changeset(%RequestReplayEntitlement{}, attrs).valid?

    malformed =
      RequestReplayEntitlement.changeset(%RequestReplayEntitlement{}, %{
        attrs
        | semantic_turn_digest: <<1>>,
          replay_generation: 0,
          status: "consumed"
      })

    refute malformed.valid?
    assert "must be exactly 32 bytes" in errors_on(malformed).semantic_turn_digest
    assert "must be equal to 1" in errors_on(malformed).replay_generation
    assert "has an invalid replay lifecycle tuple" in errors_on(malformed).status

    for {field, value, expected_error} <- [
          {:model_identifier, " \t\n", "can't be blank"},
          {:owner_lease_key_version, " \t\n", "can't be blank"},
          {:replay_claim_digest, <<1>>, "must be exactly 32 bytes"},
          {:owner_lease_digest, <<1>>, "must be exactly 32 bytes"},
          {:predecessor_epoch, 0, "must be greater than or equal to 1"}
        ] do
      invalid =
        RequestReplayEntitlement.changeset(
          %RequestReplayEntitlement{},
          Map.put(attrs, field, value)
        )

      refute invalid.valid?
      assert expected_error in Map.fetch!(errors_on(invalid), field)
    end

    consumed =
      Map.merge(attrs, %{
        status: "consumed",
        replay_attempt_id: Ecto.UUID.generate(),
        provisional_binding_digest: <<4::256>>,
        consumed_at: DateTime.add(now, 1, :second),
        abandon_at: DateTime.add(now, 10, :second)
      })

    assert RequestReplayEntitlement.changeset(%RequestReplayEntitlement{}, consumed).valid?

    invalid_started = Map.put(consumed, :started_at, DateTime.add(now, 2, :second))
    refute RequestReplayEntitlement.changeset(%RequestReplayEntitlement{}, invalid_started).valid?
  end

  @tag :replay_schema
  test "replay HMAC contracts use configured shared crypto and fail closed" do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams, [])

    on_exit(fn -> Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous) end)

    key = :binary.copy(<<7>>, 32)

    Application.put_env(
      :codex_pooler,
      CodexPooler.Upstreams,
      Keyword.merge(previous, upstream_secret_key: key, upstream_secret_key_version: "v-test")
    )

    owner_lease_uuid = "01234567-89ab-4cde-8fab-0123456789ab"
    raw_token = :binary.copy(<<9>>, 32)

    expected_owner =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        :erlang.term_to_binary(
          {"codex_pooler.owner_lease_digest", 1, "v-test", owner_lease_uuid},
          [:deterministic]
        )
      )

    assert Base.encode16(expected_owner, case: :lower) ==
             "87cbfe70696722f98f8d6302e5e7191c0f224ece33c651bf8e7d2f97bcf9600b"

    expected_provisional =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        :erlang.term_to_binary(
          {"codex_pooler.replay_provisional_binding", 1, "v-test", raw_token},
          [:deterministic]
        )
      )

    assert Base.encode16(expected_provisional, case: :lower) ==
             "9003e48808b3400d5037c3e100183901d4f44728e4795b158e0cecaf0c753549"

    assert {:ok, ^expected_owner} = RequestReplayEntitlement.owner_lease_digest(owner_lease_uuid)

    assert RequestReplayEntitlement.verify_owner_lease_digest(
             owner_lease_uuid,
             "v-test",
             expected_owner
           )

    assert {:ok, ^expected_provisional} =
             RequestReplayEntitlement.provisional_binding_digest(raw_token)

    assert RequestReplayEntitlement.verify_provisional_binding(
             raw_token,
             "v-test",
             expected_provisional
           )

    refute RequestReplayEntitlement.verify_owner_lease_digest(
             owner_lease_uuid,
             "v-other",
             expected_owner
           )

    refute RequestReplayEntitlement.verify_provisional_binding(
             raw_token,
             "v-other",
             expected_provisional
           )

    assert {:error, :invalid_owner_lease_uuid} =
             RequestReplayEntitlement.owner_lease_digest(String.upcase(owner_lease_uuid))

    assert {:error, :invalid_provisional_token} =
             RequestReplayEntitlement.provisional_binding_digest(<<1>>)

    Application.put_env(
      :codex_pooler,
      CodexPooler.Upstreams,
      Keyword.merge(previous,
        upstream_secret_key: "invalid",
        upstream_secret_key_version: "v-test"
      )
    )

    assert {:error, %{code: :app_secret_key_invalid}} =
             RequestReplayEntitlement.owner_lease_digest(owner_lease_uuid)

    refute RequestReplayEntitlement.verify_owner_lease_digest(
             owner_lease_uuid,
             "v-test",
             expected_owner
           )
  end

  @tag :replay_migration
  test "replay migration preserves derived claim identities while reversing its storage objects" do
    on_exit(&ensure_replay_migration_up!/0)

    prior_objects = replay_prior_object_snapshot()

    run_replay_migration!(:down)
    assert_replay_objects_down!()
    assert replay_prior_object_snapshot() == prior_objects

    legacy = legacy_attempt_fixture!()

    legacy_claims =
      Enum.map(["codex-turn:", "codex-request:"], &legacy_prefixed_request_fixture!/1)

    refute Map.has_key?(table_columns("attempts"), "replay_generation")

    run_replay_migration!(:up)
    assert_replay_objects_up!()
    assert replay_prior_object_snapshot() == prior_objects

    assert [[0]] =
             Repo.query!("SELECT replay_generation FROM attempts WHERE id = $1", [legacy.id]).rows

    assert Repo.query!(legacy.select_sql, [legacy.id]).rows == legacy.before_rows

    assert_claim_identities_preserved!(legacy_claims)

    run_replay_migration!(:down)
    assert_replay_objects_down!()
    assert replay_prior_object_snapshot() == prior_objects

    assert_claim_identities_preserved!(legacy_claims)

    second_legacy_claims =
      Enum.map(["codex-turn:", "codex-request:"], &legacy_prefixed_request_fixture!/1)

    run_replay_migration!(:up)
    assert_replay_objects_up!()
    assert replay_prior_object_snapshot() == prior_objects

    assert_claim_identities_preserved!(legacy_claims ++ second_legacy_claims)
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
    assert DailyRollup.__schema__(:type, :rounded_settled_cost_micros) == :decimal
    assert Quota.AccountQuotaWindow.__schema__(:type, :used_percent) == :decimal

    assert Quota.AccountQuotaWindow.__schema__(:type, :observed_at) ==
             :utc_datetime_usec

    assert Quota.AccountQuotaWindow.__schema__(:type, :merge_precedence) ==
             :integer

    assert LedgerEntry.__schema__(:type, :input_tokens) == :integer
    assert DailyRollup.__schema__(:type, :total_tokens) == :integer
    assert DailyRollup.__schema__(:type, :admitted_request_count) == :integer
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
    sensitive_keys = [
      "token",
      "password",
      "bearer_token",
      "bearer_token_action",
      "password_action"
    ]

    filtered =
      sensitive_keys
      |> Map.new(&{&1, "synthetic-secret"})
      |> Map.put("safe", "visible")
      |> Phoenix.Logger.filter_values()

    for key <- sensitive_keys do
      assert filtered[key] == "[FILTERED]"
    end

    assert filtered["safe"] == "visible"
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

  defp index_definitions do
    Repo.query!("""
    SELECT indexname, indexdef
    FROM pg_indexes
    WHERE schemaname = 'public'
    """).rows
    |> Map.new(fn [name, definition] -> {name, definition} end)
  end

  defp replay_foreign_key_actions do
    [
      {"request_replay_entitlements_request_id_fkey", {"c", "a"}},
      {"request_replay_entitlements_api_key_id_fkey", {"c", "a"}},
      {"request_replay_entitlements_codex_turn_request_fkey", {"a", "a"}},
      {"request_replay_entitlements_eligible_attempt_request_fkey", {"a", "a"}},
      {"request_replay_entitlements_replay_attempt_request_fkey", {"a", "a"}},
      {"request_replay_entitlements_pool_id_fkey", {"a", "a"}},
      {"request_replay_entitlements_model_id_fkey", {"a", "a"}}
    ]
  end

  defp replay_function_contracts do
    Repo.query!(
      """
      SELECT proname, provolatile::text, proparallel::text, proconfig
      FROM pg_proc
      WHERE pronamespace = 'public'::regnamespace
        AND proname = ANY($1::text[])
      ORDER BY proname
      """,
      [
        [
          "request_replay_db_now",
          "enforce_request_replay_entitlement_update",
          "enforce_request_replay_request_storage",
          "enforce_request_replay_turn_snapshot"
        ]
      ]
    ).rows
    |> Map.new(fn [name, volatility, parallel, config] ->
      {name, {volatility, parallel, config}}
    end)
  end

  defp replay_trigger_names do
    Repo.query!(
      """
      SELECT tgname
      FROM pg_trigger
      WHERE NOT tgisinternal
        AND tgname = ANY($1::text[])
      ORDER BY tgname
      """,
      [
        [
          "request_replay_entitlements_update_guard",
          "request_replay_entitlements_insert_guard",
          "request_replay_requests_storage_guard",
          "request_replay_codex_turns_snapshot_guard"
        ]
      ]
    ).rows
    |> Enum.map(&List.first/1)
  end

  defp replay_new_object_snapshot do
    %{
      columns: %{
        "attempts.replay_generation" => Map.get(table_columns("attempts"), "replay_generation"),
        "codex_turns.semantic_turn_digest" =>
          Map.get(table_columns("codex_turns"), "semantic_turn_digest")
      },
      table?: "request_replay_entitlements" in public_tables(),
      functions: replay_function_contracts(),
      triggers: replay_trigger_names(),
      constraints:
        constraint_definitions()
        |> Map.take(replay_constraint_names()),
      indexes:
        index_definitions()
        |> Map.take(replay_index_names())
    }
  end

  defp replay_constraint_names do
    ~w(
      attempts_replay_generation_check
      codex_turns_semantic_turn_digest_shape_check
      request_replay_entitlements_status_check
      request_replay_entitlements_model_identifier_present_check
      request_replay_entitlements_lease_key_version_present_check
      request_replay_entitlements_semantic_turn_digest_shape_check
      request_replay_entitlements_replay_claim_digest_shape_check
      request_replay_entitlements_provisional_digest_shape_check
      request_replay_entitlements_owner_lease_digest_shape_check
      request_replay_entitlements_api_key_runtime_epoch_check
      request_replay_entitlements_replay_generation_check
      request_replay_entitlements_predecessor_epoch_check
      request_replay_entitlements_expiry_check
      request_replay_entitlements_lifecycle_tuple_check
      request_replay_entitlements_request_id_fkey
      request_replay_entitlements_codex_turn_request_fkey
      request_replay_entitlements_eligible_attempt_request_fkey
      request_replay_entitlements_replay_attempt_request_fkey
      request_replay_entitlements_api_key_id_fkey
      request_replay_entitlements_pool_id_fkey
      request_replay_entitlements_model_id_fkey
    )
  end

  defp replay_index_names do
    ~w(
      codex_turns_id_request_id_uq
      codex_turns_active_semantic_turn_uq
      request_replay_entitlements_pkey
      request_replay_entitlements_request_id_uq
      request_replay_entitlements_cleanup_due_idx
    )
  end

  defp replay_prior_object_snapshot do
    constraint_definitions()
    |> Map.take(~w(
      attempts_status_check
      attempts_transport_check
      attempts_request_id_fkey
      codex_turns_status_check
      codex_turns_transport_kind_check
      codex_turns_request_id_fkey
    ))
    |> Map.put(
      :indexes,
      index_definitions()
      |> Map.take(~w(
        attempts_id_request_id_uq
        attempts_request_number_uq
        codex_turns_request_id_uq
        codex_turns_session_sequence_uq
      ))
    )
  end

  defp assert_replay_objects_down! do
    snapshot = replay_new_object_snapshot()
    refute snapshot.table?

    assert snapshot.columns == %{
             "attempts.replay_generation" => nil,
             "codex_turns.semantic_turn_digest" => nil
           }

    assert snapshot.functions == %{}
    assert snapshot.triggers == []
    assert snapshot.constraints == %{}
    assert snapshot.indexes == %{}
  end

  defp assert_replay_objects_up! do
    snapshot = replay_new_object_snapshot()
    assert snapshot.table?

    assert snapshot.columns == %{
             "attempts.replay_generation" => {"integer", "NO"},
             "codex_turns.semantic_turn_digest" => {"bytea", "YES"}
           }

    assert map_size(snapshot.functions) == 4
    assert length(snapshot.triggers) == 4
    assert Map.keys(snapshot.constraints) |> Enum.sort() == Enum.sort(replay_constraint_names())
    assert Map.keys(snapshot.indexes) |> Enum.sort() == Enum.sort(replay_index_names())
  end

  defp legacy_attempt_fixture! do
    %{pool: pool, api_key: api_key} = api_key_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress", completed_at: nil})

    [[id]] =
      Repo.query!(
        """
        INSERT INTO attempts (
          request_id, attempt_number, pool_upstream_assignment_id, upstream_identity_id,
          upstream_model_id, transport, status, retryable, usage_status, response_metadata
        ) VALUES ($1, 1, $2, $3, 'gpt-example', 'http_json', 'succeeded', false, 'usage_known', '{}'::jsonb)
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(request.id),
          Ecto.UUID.dump!(assignment.id),
          Ecto.UUID.dump!(identity.id)
        ]
      ).rows

    select_sql = """
    SELECT request_id, attempt_number, pool_upstream_assignment_id, upstream_identity_id,
           upstream_model_id, transport, status, retryable, usage_status, response_metadata
    FROM attempts WHERE id = $1
    """

    %{id: id, select_sql: select_sql, before_rows: Repo.query!(select_sql, [id]).rows}
  end

  defp legacy_prefixed_request_fixture!(prefix) do
    %{pool: pool, api_key: api_key} = api_key_fixture()
    correlation_id = prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    [[id]] =
      Repo.query!(
        """
        INSERT INTO requests (
          pool_id, api_key_id, requested_model, endpoint, transport, status,
          usage_status, correlation_id, request_metadata
        ) VALUES ($1, $2, 'gpt-example', '/backend-api/codex/responses', 'websocket',
          'accepted', 'usage_pending', $3, '{}'::jsonb)
        RETURNING id
        """,
        [Ecto.UUID.dump!(pool.id), Ecto.UUID.dump!(api_key.id), correlation_id]
      ).rows

    %{id: id, correlation_id: correlation_id}
  end

  defp assert_claim_identities_preserved!(claims) do
    Enum.each(claims, fn %{id: id, correlation_id: correlation_id} ->
      assert [[^correlation_id]] =
               Repo.query!("SELECT correlation_id FROM requests WHERE id = $1", [id]).rows
    end)
  end

  defp column_default(table_name, column_name) do
    Repo.query!(
      """
      SELECT column_default
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = $1
        AND column_name = $2
      """,
      [table_name, column_name]
    ).rows
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

  defp trigger_names(table_name) do
    Repo.query!(
      """
      SELECT tgname
      FROM pg_trigger
      WHERE tgrelid = ('public.' || $1)::regclass
        AND NOT tgisinternal
      ORDER BY tgname
      """,
      [table_name]
    ).rows
    |> Enum.map_join(" ", &List.first/1)
  end

  defp trigger_contracts(names) do
    Repo.query!(
      """
      SELECT tgname, tgconstraint, tgdeferrable, tginitdeferred
      FROM pg_trigger
      WHERE tgname = ANY($1::text[])
      ORDER BY tgname
      """,
      [names]
    ).rows
    |> Enum.map(fn [name, constraint_oid, deferrable, initially_deferred] ->
      {name, constraint_oid, deferrable, initially_deferred}
    end)
  end

  defp function_search_paths(names) do
    Repo.query!(
      """
      SELECT proname, proconfig
      FROM pg_proc
      WHERE pronamespace = 'public'::regnamespace
        AND proname = ANY($1::text[])
      ORDER BY proname
      """,
      [names]
    ).rows
    |> Map.new(fn [name, config] -> {name, config} end)
  end

  defp run_pool_daily_coverage_migration!(direction) do
    module = CodexPooler.Repo.Migrations.FencePoolDailyRollupCoverage

    unless Code.ensure_loaded?(module) do
      Code.require_file(
        "../../priv/repo/migrations/20260815010747_fence_pool_daily_rollup_coverage.exs",
        __DIR__
      )
    end

    Runner.run(
      Repo,
      Repo.config(),
      20_260_815_010_747,
      module,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  defp ensure_pool_daily_coverage_migration_up! do
    unless Map.has_key?(table_columns("daily_rollup_coverages"), "mutation_version") do
      run_pool_daily_coverage_migration!(:up)
    end
  end

  defp run_replay_migration!(direction) do
    module = CodexPooler.Repo.Migrations.AddRequestReplayEntitlements

    unless Code.ensure_loaded?(module) do
      Code.require_file(
        "../../priv/repo/migrations/20260902024410_add_request_replay_entitlements.exs",
        __DIR__
      )
    end

    Runner.run(
      Repo,
      Repo.config(),
      20_260_902_024_410,
      module,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  defp ensure_replay_migration_up! do
    unless "request_replay_entitlements" in public_tables() do
      run_replay_migration!(:up)
    end
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
