defmodule CodexPooler.Repo.Migrations.CreateAlertTables do
  use Ecto.Migration

  def change do
    create table(:alert_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :pool_id, references(:pools, type: :binary_id, on_delete: :delete_all), null: false
      add :scope_type, :text, null: false
      add :rule_kind, :text, null: false
      add :display_name, :text, null: false
      add :severity, :text, null: false
      add :cooldown_minutes, :integer, null: false, default: 30
      add :state, :text, null: false, default: "active"
      add :model, :text
      add :min_usable_assignments, :integer
      add :target_state, :text
      add :window_selector, :text
      add :threshold_used_percent, :numeric, precision: 6, scale: 3
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :disabled_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:alert_rules, :alert_rules_scope_type_check,
             check: "scope_type IN ('pool', 'upstream_identity')"
           )

    create constraint(:alert_rules, :alert_rules_rule_kind_check,
             check:
               "rule_kind IN ('pool_no_usable_assignments', 'pool_low_usable_assignments', 'pool_all_assignments_in_state', 'upstream_quota_threshold', 'upstream_auth_state')"
           )

    create constraint(:alert_rules, :alert_rules_severity_check,
             check: "severity IN ('info', 'warning', 'critical')"
           )

    create constraint(:alert_rules, :alert_rules_cooldown_minutes_check,
             check: "cooldown_minutes >= 5 AND cooldown_minutes <= 1440"
           )

    create constraint(:alert_rules, :alert_rules_state_check,
             check: "state IN ('active', 'disabled')"
           )

    create constraint(:alert_rules, :alert_rules_min_usable_assignments_check,
             check: "min_usable_assignments IS NULL OR min_usable_assignments > 0"
           )

    create constraint(:alert_rules, :alert_rules_target_state_check,
             check:
               "target_state IS NULL OR target_state IN ('missing_evidence', 'stale', 'weekly_only', 'exhausted', 'reauth_required', 'refresh_failed')"
           )

    create constraint(:alert_rules, :alert_rules_window_selector_check,
             check:
               "window_selector IS NULL OR window_selector IN ('account_primary', 'account_secondary', 'model_primary', 'model_secondary', 'any')"
           )

    create constraint(:alert_rules, :alert_rules_threshold_used_percent_check,
             check:
               "threshold_used_percent IS NULL OR (threshold_used_percent >= 0 AND threshold_used_percent <= 100)"
           )

    create constraint(:alert_rules, :alert_rules_metadata_shape_check,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create index(:alert_rules, [:pool_id, :state], name: :alert_rules_pool_state_idx)
    create index(:alert_rules, [:rule_kind, :state], name: :alert_rules_kind_state_idx)

    create table(:alert_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :channel_type, :text, null: false
      add :display_name, :text, null: false
      add :state, :text, null: false, default: "active"
      add :email_to, :text
      add :endpoint_scheme, :text
      add :endpoint_host, :text
      add :endpoint_path_prefix, :text
      add :endpoint_fingerprint, :text
      add :endpoint_url_ciphertext, :binary
      add :endpoint_url_nonce, :binary
      add :endpoint_url_aad, :map, null: false, default: %{}
      add :endpoint_url_key_version, :text
      add :webhook_signing_secret_ciphertext, :binary
      add :webhook_signing_secret_nonce, :binary
      add :webhook_signing_secret_aad, :map, null: false, default: %{}
      add :webhook_signing_secret_key_version, :text
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :disabled_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:alert_channels, :alert_channels_channel_type_check,
             check: "channel_type IN ('email', 'webhook')"
           )

    create constraint(:alert_channels, :alert_channels_state_check,
             check: "state IN ('active', 'disabled')"
           )

    create constraint(:alert_channels, :alert_channels_endpoint_scheme_check,
             check: "endpoint_scheme IS NULL OR endpoint_scheme IN ('http', 'https')"
           )

    create constraint(:alert_channels, :alert_channels_metadata_shape_check,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:alert_channels, :alert_channels_webhook_secret_aad_shape_check,
             check: "jsonb_typeof(webhook_signing_secret_aad) = 'object'"
           )

    create constraint(:alert_channels, :alert_channels_endpoint_url_aad_shape_check,
             check: "jsonb_typeof(endpoint_url_aad) = 'object'"
           )

    create index(:alert_channels, [:channel_type, :state], name: :alert_channels_type_state_idx)

    create table(:alert_rule_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :alert_rule_id, references(:alert_rules, type: :binary_id, on_delete: :delete_all),
        null: false

      add :alert_channel_id,
          references(:alert_channels, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:alert_rule_channels, [:alert_rule_id, :alert_channel_id],
             name: :alert_rule_channels_rule_channel_uq
           )

    create index(:alert_rule_channels, [:alert_channel_id],
             name: :alert_rule_channels_channel_id_idx
           )

    create table(:alert_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :dedupe_key, :text, null: false
      add :scope_type, :text, null: false
      add :rule_kind, :text, null: false
      add :severity, :text, null: false
      add :state, :text, null: false, default: "open"
      add :pool_id, references(:pools, type: :binary_id, on_delete: :delete_all)

      add :upstream_identity_id,
          references(:upstream_identities, type: :binary_id, on_delete: :delete_all)

      add :occurrence_count, :integer, null: false, default: 1
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :acknowledged_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
      add :safe_evidence_snapshot, :map, null: false, default: %{}
      add :suppression_metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:alert_incidents, :alert_incidents_scope_type_check,
             check: "scope_type IN ('pool', 'upstream_identity')"
           )

    create constraint(:alert_incidents, :alert_incidents_scope_target_check,
             check:
               "((scope_type = 'pool' AND pool_id IS NOT NULL AND upstream_identity_id IS NULL) OR (scope_type = 'upstream_identity' AND upstream_identity_id IS NOT NULL))"
           )

    create constraint(:alert_incidents, :alert_incidents_rule_kind_check,
             check:
               "rule_kind IN ('pool_no_usable_assignments', 'pool_low_usable_assignments', 'pool_all_assignments_in_state', 'upstream_quota_threshold', 'upstream_auth_state')"
           )

    create constraint(:alert_incidents, :alert_incidents_severity_check,
             check: "severity IN ('info', 'warning', 'critical')"
           )

    create constraint(:alert_incidents, :alert_incidents_state_check,
             check: "state IN ('open', 'acknowledged', 'resolved')"
           )

    create constraint(:alert_incidents, :alert_incidents_occurrence_count_check,
             check: "occurrence_count > 0"
           )

    create constraint(:alert_incidents, :alert_incidents_safe_evidence_snapshot_shape_check,
             check: "jsonb_typeof(safe_evidence_snapshot) = 'object'"
           )

    create constraint(:alert_incidents, :alert_incidents_suppression_metadata_shape_check,
             check: "jsonb_typeof(suppression_metadata) = 'object'"
           )

    create unique_index(:alert_incidents, [:dedupe_key],
             name: :alert_incidents_unresolved_dedupe_key_uq,
             where: "state IN ('open', 'acknowledged')"
           )

    create index(:alert_incidents, [:state, :last_seen_at], name: :alert_incidents_state_seen_idx)
    create index(:alert_incidents, [:pool_id, :state], name: :alert_incidents_pool_state_idx)

    create index(:alert_incidents, [:upstream_identity_id, :state],
             name: :alert_incidents_upstream_state_idx
           )

    create table(:alert_incident_targets, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :incident_id, references(:alert_incidents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :rule_id, references(:alert_rules, type: :binary_id, on_delete: :delete_all),
        null: false

      add :pool_id, references(:pools, type: :binary_id, on_delete: :delete_all), null: false
      add :first_matched_at, :utc_datetime_usec, null: false
      add :last_matched_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:alert_incident_targets, :alert_incident_targets_metadata_shape_check,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create unique_index(:alert_incident_targets, [:incident_id, :rule_id, :pool_id],
             name: :alert_incident_targets_incident_rule_pool_uq
           )

    create index(:alert_incident_targets, [:incident_id],
             name: :alert_incident_targets_incident_id_idx
           )

    create index(:alert_incident_targets, [:rule_id, :pool_id],
             name: :alert_incident_targets_rule_pool_idx
           )

    create index(:alert_incident_targets, [:pool_id, :last_matched_at],
             name: :alert_incident_targets_pool_last_matched_idx
           )

    create table(:alert_delivery_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :incident_id, references(:alert_incidents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :channel_id, references(:alert_channels, type: :binary_id, on_delete: :delete_all),
        null: false

      add :attempt_number, :integer, null: false
      add :max_attempts, :integer, null: false, default: 5
      add :status, :text, null: false, default: "pending"
      add :scheduled_at, :utc_datetime_usec, null: false
      add :attempted_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :next_retry_at, :utc_datetime_usec
      add :response_status_code, :integer
      add :retryable, :boolean, null: false, default: false
      add :failure_code, :text
      add :failure_message, :text
      add :response_metadata, :map, null: false, default: %{}
      add :failure_metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:alert_delivery_attempts, :alert_delivery_attempts_status_check,
             check: "status IN ('pending', 'sent', 'retryable', 'failed', 'discarded')"
           )

    create constraint(:alert_delivery_attempts, :alert_delivery_attempts_max_attempts_check,
             check: "max_attempts = 5"
           )

    create constraint(:alert_delivery_attempts, :alert_delivery_attempts_attempt_number_check,
             check: "attempt_number >= 1 AND attempt_number <= max_attempts"
           )

    create constraint(
             :alert_delivery_attempts,
             :alert_delivery_attempts_response_metadata_shape_check,
             check: "jsonb_typeof(response_metadata) = 'object'"
           )

    create constraint(
             :alert_delivery_attempts,
             :alert_delivery_attempts_failure_metadata_shape_check,
             check: "jsonb_typeof(failure_metadata) = 'object'"
           )

    create unique_index(:alert_delivery_attempts, [:incident_id, :channel_id, :attempt_number],
             name: :alert_delivery_attempts_incident_channel_attempt_uq
           )

    create index(:alert_delivery_attempts, [:status, :next_retry_at],
             name: :alert_delivery_attempts_retry_lookup_idx,
             where: "status IN ('pending', 'retryable')"
           )

    create index(:alert_delivery_attempts, [:incident_id, :status],
             name: :alert_delivery_attempts_incident_status_idx
           )

    create index(:alert_delivery_attempts, [:channel_id, :status],
             name: :alert_delivery_attempts_channel_status_idx
           )
  end
end
