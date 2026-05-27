defmodule CodexPooler.SchemaContractTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}
  alias CodexPooler.Accounting.{DailyRollup, LedgerEntry}
  alias CodexPooler.Catalog.{Model, PricingSnapshot}
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, RoutingCircuitState}
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota

  @expected_tables ~w(
    account_quota_windows api_key_policy_bindings api_keys attempts audit_events bridge_owner_leases
    bridge_session_aliases codex_files codex_sessions codex_turns daily_rollups
    encrypted_secrets gateway_idempotency_keys instance_settings invite_acceptances invites ledger_entries memberships
    models platform_bootstrap_state pricing_snapshots recovery_codes requests routing_circuit_states
    sessions sync_runs pools pool_routing_settings pool_upstream_assignments totp_settings
    upstream_identities users
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
    DailyRollup,
    LedgerEntry,
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
    CodexPooler.Pools.Pool,
    CodexPooler.Pools.RoutingSettings,
    Quota.AccountQuotaWindow,
    CodexPooler.Upstreams.Schemas.EncryptedSecret,
    CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment,
    CodexPooler.Upstreams.Schemas.UpstreamIdentity
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
          "memberships_single_instance_owner_active_uq",
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
          "daily_rollups_pool_uq",
          "codex_sessions_pool_session_key_uq",
          "codex_turns_session_sequence_uq",
          "invite_acceptances_invite_id_uq"
        ] do
      assert Map.has_key?(indexes, name)
    end

    assert indexes["users_email_active_uq"] =~ "lower(email)"
    assert indexes["users_email_active_uq"] =~ "WHERE (deleted_at IS NULL)"
    assert indexes["api_key_policy_model_active_uq"] =~ "lower(model_identifier)"
    assert indexes["ledger_entries_settlement_request_uq"] =~ "entry_kind = 'settlement'"
    assert indexes["account_quota_windows_evidence_identity_uq"] =~ "quota_scope"
    assert indexes["requests_api_key_admitted_idx"] =~ "api_key_id"
    assert indexes["requests_api_key_admitted_idx"] =~ "admitted_at DESC"
    assert indexes["requests_api_key_admitted_idx"] =~ "id DESC"

    assert indexes["account_quota_windows_evidence_identity_uq"] =~
             "COALESCE(lower(model), ''::text)"

    assert indexes["account_quota_windows_evidence_identity_uq"] =~ "raw_metered_feature"
  end

  test "preserves check constraints for statuses, endpoints, transports, and quota windows" do
    constraints = constraint_definitions()

    assert constraints["api_keys_status_check"] =~ "'paused'"
    refute constraints["api_keys_status_check"] =~ "'disabled'"

    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/models'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/responses'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/responses/compact'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/images/generations'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/images/edits'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/thread/goal/get'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/thread/goal/set'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/thread/goal/clear'"

    assert constraints["requests_endpoint_check"] =~
             "'/backend-api/codex/analytics-events/events'"

    assert constraints["requests_endpoint_check"] =~
             "'/backend-api/codex/memories/trace_summarize'"

    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/alpha/search'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/realtime/calls'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/safety/arc'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/codex/agent-identities/jwks'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/wham/agent-identities/jwks'"
    refute constraints["requests_endpoint_check"] =~ "'/backend-api/codex/not-added'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/transcribe'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/files'"
    assert constraints["requests_endpoint_check"] =~ "'/backend-api/files/uploaded'"
    assert constraints["requests_endpoint_check"] =~ "'/api/codex/usage'"
    assert constraints["requests_endpoint_check"] =~ "'/v1/models'"
    assert constraints["requests_endpoint_check"] =~ "'/v1/usage'"
    assert constraints["requests_endpoint_check"] =~ "'/v1/files'"
    assert constraints["requests_endpoint_check"] =~ "'/v1/files/content'"
    assert constraints["requests_endpoint_check"] =~ "'/v1/files/delete'"

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
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'minimal'"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'high'"
    assert constraints["api_keys_enforced_reasoning_effort_check"] =~ "'xhigh'"
    assert constraints["api_keys_enforced_service_tier_check"] =~ "'auto'"
    assert constraints["api_keys_enforced_service_tier_check"] =~ "'priority'"
    assert constraints["api_keys_enforced_service_tier_check"] =~ "'ultrafast'"

    assert constraints["api_key_policy_bindings_max_tokens_per_week_check"] =~
             "max_tokens_per_week > 0"

    assert constraints["instance_settings_singleton_true_check"] =~ "singleton = true"
  end

  test "preserves JSONB, decimal-compatible money/rate fields, and integer token counters" do
    assert column_type("pool_routing_settings", "metadata") == "jsonb"
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

    assert column_type("pricing_snapshots", "input_token_micros") == "numeric(30,9)"
    assert column_type("pricing_snapshots", "request_base_micros") == "numeric(30,9)"
    assert column_type("ledger_entries", "estimated_cost_micros") == "numeric(30,9)"
    assert column_type("daily_rollups", "settled_cost_micros") == "numeric(30,9)"
    assert column_type("account_quota_windows", "used_percent") == "numeric(6,3)"

    assert column_type("ledger_entries", "input_tokens") == "bigint"
    assert column_type("ledger_entries", "total_tokens") == "bigint"
    assert column_type("daily_rollups", "output_tokens") == "bigint"
    assert column_type("api_key_policy_bindings", "max_tokens_per_day") == "bigint"
    assert column_type("api_key_policy_bindings", "max_tokens_per_week") == "bigint"
    assert column_type("codex_files", "byte_size") == "bigint"
    assert column_type("instance_settings", "lock_version") == "integer"

    assert column_type("api_keys", "enforced_model_identifier") == "text"
    assert column_type("api_keys", "enforced_reasoning_effort") == "text"
    assert column_type("api_keys", "enforced_service_tier") == "text"

    assert column_type("instance_settings", "updated_by_user_id") == "uuid"
    assert column_type("instance_settings", "inserted_at") == "timestamp without time zone"
    assert column_type("instance_settings", "updated_at") == "timestamp without time zone"
  end

  test "preserves final foreign key actions including cascades and set-null behavior" do
    assert fk_action("sessions_user_id_fkey") == {"c", "a"}
    assert fk_action("api_keys_pool_id_fkey") == {"c", "a"}
    assert fk_action("attempts_pool_upstream_assignment_id_fkey") == {"c", "a"}
    assert fk_action("attempts_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("codex_sessions_pool_upstream_assignment_id_fkey") == {"c", "a"}
    assert fk_action("ledger_entries_pool_upstream_assignment_id_fkey") == {"n", "a"}
    assert fk_action("ledger_entries_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("codex_turns_final_attempt_id_request_id_fkey") == {"a", "a"}
    assert fk_action("codex_files_request_id_fkey") == {"n", "a"}
    assert fk_action("codex_files_pool_upstream_assignment_id_fkey") == {"n", "a"}
    assert fk_action("codex_files_upstream_identity_id_fkey") == {"n", "a"}
    assert fk_action("bridge_session_aliases_codex_session_id_fkey") == {"c", "a"}
    assert fk_action("bridge_owner_leases_pool_upstream_assignment_id_fkey") == {"n", "a"}
    assert fk_action("instance_settings_updated_by_user_id_fkey") == {"n", "a"}
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

    assert APIKeyPolicyBinding.__schema__(:type, :max_tokens_per_day) ==
             :integer

    assert APIKeyPolicyBinding.__schema__(:type, :max_tokens_per_week) ==
             :integer

    assert APIKey.__schema__(:type, :enforced_model_identifier) == :string
    assert APIKey.__schema__(:type, :enforced_reasoning_effort) == :string
    assert APIKey.__schema__(:type, :enforced_service_tier) == :string

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
