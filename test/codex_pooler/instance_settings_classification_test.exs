defmodule CodexPooler.InstanceSettingsClassificationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.InstanceSettings.Classification

  @expected_buckets [
    :env_only_boot,
    :db_runtime_live,
    :db_runtime_cached,
    :db_requires_restart,
    :secret_env_only,
    :secret_encrypted_db,
    :secret_hmac_db
  ]

  @plan_env_only_boot [
    "DATABASE_URL",
    "ECTO_IPV6",
    "POOL_SIZE",
    "SECRET_KEY_BASE",
    "PHX_SERVER",
    "PORT",
    "PHX_HOST",
    "DNS_CLUSTER_QUERY",
    "OBAN_MODE",
    "OBAN_JOBS_QUEUE_LIMIT",
    "CODEX_POOLER_TOTP_ENCRYPTION_KEY",
    "CODEX_POOLER_TOTP_KEY_VERSION",
    "CODEX_POOLER_UPSTREAM_SECRET_KEY",
    "CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION"
  ]

  @database_storage_types [:database, :encrypted_database_secret, :hmac_database_secret]
  @database_setting_keys [
    :file_lifecycle,
    :transcription_upload_max,
    :gateway_debug,
    :sse_keepalive_interval,
    :websocket_idle_timeout,
    :upstream_timeouts,
    :model_context_window_overrides,
    :decompression_limits,
    :expired_alias_ttl,
    :operator_login_base_url,
    :firewall_allowlist,
    :trusted_proxies,
    :bridge_owner_lease,
    :circuit_thresholds,
    :bulkheads,
    :smtp_delivery,
    :smtp_password,
    :metrics_bearer_token
  ]

  @former_database_env_names [
    "CODEX_POOLER_FILE_MAX_SIZE_BYTES",
    "CODEX_POOLER_UPLOAD_TTL_SECONDS",
    "CODEX_POOLER_ABANDONED_UPLOAD_CLEANUP_INTERVAL_SECONDS",
    "CODEX_POOLER_MAX_TRANSCRIPTION_UPLOAD_BYTES",
    "CODEX_POOLER_GATEWAY_DEBUG",
    "CODEX_POOLER_SSE_KEEPALIVE_INTERVAL_MS",
    "CODEX_POOLER_WEBSOCKET_IDLE_TIMEOUT_MS",
    "CODEX_POOLER_UPSTREAM_CONNECT_TIMEOUT_MS",
    "CODEX_POOLER_UPSTREAM_POOL_TIMEOUT_MS",
    "CODEX_POOLER_UPSTREAM_RECEIVE_TIMEOUT_MS",
    "CODEX_POOLER_MODEL_CONTEXT_WINDOW_OVERRIDES",
    "CODEX_POOLER_DECOMPRESSION_ALGORITHMS",
    "CODEX_POOLER_MAX_COMPRESSED_BODY_BYTES",
    "CODEX_POOLER_MAX_DECOMPRESSED_BODY_BYTES",
    "CODEX_POOLER_MAX_DECOMPRESSION_RATIO",
    "CODEX_POOLER_DECOMPRESSION_TIMEOUT_MS",
    "CODEX_POOLER_EXPIRED_ALIAS_TTL_SECONDS",
    "CODEX_POOLER_OPERATOR_LOGIN_BASE_URL",
    "CODEX_POOLER_FIREWALL_ALLOWLIST",
    "CODEX_POOLER_TRUSTED_PROXIES",
    "CODEX_POOLER_BRIDGE_OWNER_LEASE_TTL_SECONDS",
    "CODEX_POOLER_BRIDGE_OWNER_RENEWAL_SECONDS",
    "CODEX_POOLER_CIRCUIT_FAILURE_THRESHOLD",
    "CODEX_POOLER_CIRCUIT_OPEN_SECONDS",
    "CODEX_POOLER_CIRCUIT_HALF_OPEN_PROBE_LIMIT",
    "CODEX_POOLER_CIRCUIT_SUCCESS_THRESHOLD",
    "CODEX_POOLER_BULKHEAD_<ROUTE_CLASS>_MAX_CONCURRENCY",
    "CODEX_POOLER_BULKHEAD_<ROUTE_CLASS>_QUEUE_LIMIT",
    "CODEX_POOLER_BULKHEAD_<ROUTE_CLASS>_QUEUE_TIMEOUT_MS",
    "SMTP_HOST",
    "SMTP_PORT",
    "SMTP_USERNAME",
    "SMTP_FROM",
    "SMTP_SSL",
    "SMTP_TLS",
    "SMTP_RETRIES",
    "SMTP_PASSWORD",
    "CODEX_POOLER_METRICS_BEARER_TOKEN"
  ]

  test "defines the exact migration buckets" do
    assert Classification.buckets() == @expected_buckets

    assert Map.keys(Classification.settings_by_bucket()) |> Enum.sort() ==
             Enum.sort(@expected_buckets)
  end

  test "classifies all candidate settings and fails for synthetic unclassified candidates" do
    assert :ok = Classification.validate_candidate_coverage()
    assert Classification.candidate_keys() == Classification.classified_keys()

    assert {:error, [:synthetic_unclassified_candidate]} =
             Classification.validate_candidate_coverage(
               Classification.candidate_keys() ++ [:synthetic_unclassified_candidate]
             )
  end

  test "lists the plan-mandated env-only boot settings" do
    env_only_names =
      :env_only_boot
      |> Classification.settings_for()
      |> Enum.flat_map(& &1.env_names)

    for env_name <- @plan_env_only_boot do
      assert env_name in env_only_names
    end
  end

  test "classifies runtime live settings from the migration plan" do
    assert Classification.bucket_for!(:file_lifecycle) == :db_runtime_live
    assert Classification.bucket_for!(:transcription_upload_max) == :db_runtime_live
    assert Classification.bucket_for!(:gateway_debug) == :db_runtime_live
    assert Classification.bucket_for!(:sse_keepalive_interval) == :db_runtime_live
    assert Classification.bucket_for!(:upstream_timeouts) == :db_runtime_live
    assert Classification.bucket_for!(:model_context_window_overrides) == :db_runtime_live
    assert Classification.bucket_for!(:decompression_limits) == :db_runtime_live
    assert Classification.bucket_for!(:expired_alias_ttl) == :db_runtime_live
    assert Classification.bucket_for!(:operator_login_base_url) == :db_runtime_live
  end

  test "classifies runtime cached settings from the migration plan" do
    assert Classification.bucket_for!(:firewall_allowlist) == :db_runtime_cached
    assert Classification.bucket_for!(:trusted_proxies) == :db_runtime_cached
    assert Classification.bucket_for!(:bridge_owner_lease) == :db_runtime_cached
    assert Classification.bucket_for!(:circuit_thresholds) == :db_runtime_cached
    assert Classification.bucket_for!(:bulkheads) == :db_runtime_cached
    assert Classification.bucket_for!(:smtp_delivery) == :db_runtime_cached
    assert Classification.bucket_for!(:mcp_service_enabled) == :db_runtime_cached
  end

  test "classifies websocket owner idle timeout as cached non-secret DB state" do
    setting = Classification.fetch!(:websocket_owner_idle_timeout)

    assert setting.bucket == :db_runtime_cached
    assert setting.group == :gateway
    assert setting.env_names == []
    assert setting.storage == :database
    assert setting.reloadability == :cached
    refute Map.get(setting, :sensitive?, false)
  end

  test "classifies metrics bearer token as HMAC-only DB secret" do
    setting = Classification.fetch!(:metrics_bearer_token)

    assert setting.bucket == :secret_hmac_db
    assert setting.env_names == []
    assert setting.storage == :hmac_database_secret
    assert "hmac_digest" in setting.metadata
    assert "fingerprint" in setting.metadata
    assert "key_version" in setting.metadata
  end

  test "classifies SMTP password as encrypted DB secret with key version metadata" do
    setting = Classification.fetch!(:smtp_password)

    assert setting.bucket == :secret_encrypted_db
    assert setting.env_names == []
    assert setting.storage == :encrypted_database_secret
    assert "ciphertext" in setting.metadata
    assert "key_version" in setting.metadata
  end

  test "records out-of-scope local and example variables" do
    notes = Enum.join(Classification.out_of_scope_notes(), "\n")

    assert notes =~ "CODEX_POOLER_API_KEY"
    assert notes =~ "CODEX_POOLER_IMAGE"
    assert notes =~ "CODEX_POOLER_IMAGE_TAG"
    assert notes =~ "CODEX_POOLER_HTTP_PORT"
    assert notes =~ "POSTGRES_USER"
    assert notes =~ "POSTGRES_TEST_DB"
  end

  test "does not duplicate setting keys or env names inside classified candidates" do
    settings = Classification.settings()
    keys = Enum.map(settings, & &1.key)
    env_names = Enum.flat_map(settings, & &1.env_names)

    assert Enum.uniq(keys) == keys
    assert Enum.uniq(env_names) == env_names
  end

  test "classifies the global MCP service gate as cached non-secret DB state" do
    setting = Classification.fetch!(:mcp_service_enabled)

    assert setting.bucket == :db_runtime_cached
    assert setting.group == :mcp
    assert setting.env_names == []
    assert setting.storage == :database
    assert setting.reloadability == :cached
    refute Map.get(setting, :sensitive?, false)
  end

  test "advertises only real process environment inputs" do
    database_backed_settings =
      Enum.filter(Classification.settings(), &(&1.storage in @database_storage_types))

    formerly_environment_backed_settings =
      Enum.filter(database_backed_settings, &(&1.key in @database_setting_keys))

    assert Enum.map(formerly_environment_backed_settings, & &1.key) == @database_setting_keys
    assert length(formerly_environment_backed_settings) == 18
    assert Enum.all?(database_backed_settings, &(&1.env_names == []))

    advertised_env_names =
      Classification.settings()
      |> Enum.flat_map(& &1.env_names)

    assert length(@former_database_env_names) == 38

    for env_name <- @former_database_env_names do
      refute env_name in advertised_env_names
    end

    assert Classification.settings()
           |> Enum.filter(&(&1.storage == :environment))
           |> Enum.all?(&(&1.env_names != []))
  end

  test "rejects malformed and unknown storage classifications" do
    assert Classification.storage_types() == [
             :environment,
             :database,
             :encrypted_database_secret,
             :hmac_database_secret
           ]

    for setting <- Classification.settings() do
      assert :ok = Classification.validate_storage_classification(setting)
    end

    assert {:error, :unknown_storage} =
             Classification.validate_storage_classification(%{storage: :filesystem})

    assert {:error, :missing_storage} = Classification.validate_storage_classification(%{})

    assert {:error, :malformed_setting} =
             Classification.validate_storage_classification(:malformed)
  end
end
