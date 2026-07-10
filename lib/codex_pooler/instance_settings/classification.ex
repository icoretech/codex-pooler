defmodule CodexPooler.InstanceSettings.Classification do
  @moduledoc """
  Static classification contract for the planned DB-backed instance settings boundary.

  This module is intentionally data-only. It documents the source-of-truth
  buckets for settings migration work without reading from the database,
  application environment, or process environment.
  """

  @type bucket :: atom()
  @type setting :: %{
          required(:key) => atom(),
          required(:bucket) => bucket(),
          required(:group) => atom(),
          required(:label) => String.t(),
          required(:env_names) => [String.t()],
          required(:storage) => atom(),
          required(:reloadability) => atom(),
          required(:notes) => String.t(),
          optional(:sensitive?) => boolean(),
          optional(:metadata) => [String.t()]
        }

  @buckets [
    :env_only_boot,
    :db_runtime_live,
    :db_runtime_cached,
    :db_requires_restart,
    :secret_env_only,
    :secret_encrypted_db,
    :secret_hmac_db
  ]

  @bucket_notes %{
    env_only_boot:
      "Boot, release, topology, or crypto-root values that must remain process environment or release config.",
    db_runtime_live:
      "DB-backed settings that runtime consumers can read per request or per operation without cache coordination.",
    db_runtime_cached:
      "DB-backed settings that should flow through the instance settings cache and PubSub invalidation.",
    db_requires_restart:
      "Reserved for future DB-recorded settings that are operator-visible but cannot take effect until restart.",
    secret_env_only: "Secret release/runtime values that are intentionally not DB-managed.",
    secret_encrypted_db:
      "DB-backed write-only secrets that must be recoverable by the application at use time.",
    secret_hmac_db:
      "DB-backed write-only secrets that must be verified but never recovered after save."
  }
  @codex_env_prefix "CODEX" <> "_POOLER_"
  @smtp_env_prefix "SMTP" <> "_"

  @settings [
    %{
      key: :database_url,
      bucket: :env_only_boot,
      group: :database,
      label: "Database URL",
      env_names: ["DATABASE_URL"],
      storage: :environment,
      reloadability: :boot,
      notes:
        "Ecto repository boot connection string; unavailable before the DB-backed settings row can exist.",
      sensitive?: true
    },
    %{
      key: :ecto_ipv6,
      bucket: :env_only_boot,
      group: :database,
      label: "Ecto IPv6 socket option",
      env_names: ["ECTO_IPV6"],
      storage: :environment,
      reloadability: :boot,
      notes: "Repository socket option chosen during release boot."
    },
    %{
      key: :pool_size,
      bucket: :env_only_boot,
      group: :database,
      label: "Ecto pool size",
      env_names: ["POOL_SIZE"],
      storage: :environment,
      reloadability: :boot,
      notes: "Database connection pool topology is fixed when the Repo starts."
    },
    %{
      key: :secret_key_base,
      bucket: :env_only_boot,
      group: :phoenix_endpoint,
      label: "Phoenix secret key base",
      env_names: ["SECRET_KEY_BASE"],
      storage: :environment,
      reloadability: :boot,
      notes: "Phoenix endpoint signing/encryption root required before serving traffic.",
      sensitive?: true
    },
    %{
      key: :phx_server,
      bucket: :env_only_boot,
      group: :phoenix_endpoint,
      label: "Phoenix server switch",
      env_names: ["PHX_SERVER"],
      storage: :environment,
      reloadability: :boot,
      notes: "Controls whether the release starts the HTTP server."
    },
    %{
      key: :port,
      bucket: :env_only_boot,
      group: :phoenix_endpoint,
      label: "HTTP port",
      env_names: ["PORT"],
      storage: :environment,
      reloadability: :boot,
      notes: "Bandit/Phoenix listener port is bound during endpoint startup."
    },
    %{
      key: :phx_host,
      bucket: :env_only_boot,
      group: :phoenix_endpoint,
      label: "Public Phoenix host",
      env_names: ["PHX_HOST"],
      storage: :environment,
      reloadability: :boot,
      notes: "Endpoint URL host and default boot-time URL composition remain release config."
    },
    %{
      key: :dns_cluster_query,
      bucket: :env_only_boot,
      group: :release_clustering,
      label: "DNS cluster query",
      env_names: ["DNS_CLUSTER_QUERY"],
      storage: :environment,
      reloadability: :boot,
      notes: "DNSCluster child specification is built during application supervision startup."
    },
    %{
      key: :oban_mode,
      bucket: :env_only_boot,
      group: :oban,
      label: "Oban release role",
      env_names: ["OBAN_MODE"],
      storage: :environment,
      reloadability: :boot,
      notes: "Selects web, worker, scheduler, or all role before Oban starts."
    },
    %{
      key: :oban_jobs_queue_limit,
      bucket: :env_only_boot,
      group: :oban,
      label: "Oban jobs queue limit",
      env_names: ["OBAN_JOBS_QUEUE_LIMIT"],
      storage: :environment,
      reloadability: :boot,
      notes: "Queue concurrency is part of the Oban child configuration."
    },
    %{
      key: :totp_encryption_key,
      bucket: :env_only_boot,
      group: :crypto_roots,
      label: "TOTP encryption key",
      env_names: [@codex_env_prefix <> "TOTP_ENCRYPTION_KEY"],
      storage: :environment,
      reloadability: :boot,
      notes: "Existing TOTP secret encryption root; not moved into DB-managed settings.",
      sensitive?: true
    },
    %{
      key: :totp_key_version,
      bucket: :env_only_boot,
      group: :crypto_roots,
      label: "TOTP key version",
      env_names: [@codex_env_prefix <> "TOTP_KEY_VERSION"],
      storage: :environment,
      reloadability: :boot,
      notes: "Version metadata for the env-only TOTP encryption root."
    },
    %{
      key: :upstream_secret_key,
      bucket: :env_only_boot,
      group: :crypto_roots,
      label: "Upstream secret key",
      env_names: [@codex_env_prefix <> "UPSTREAM_SECRET_KEY"],
      storage: :environment,
      reloadability: :boot,
      notes:
        "Existing upstream secret root; later DB-managed app secrets reuse this root instead of adding another one.",
      sensitive?: true
    },
    %{
      key: :upstream_secret_key_version,
      bucket: :env_only_boot,
      group: :crypto_roots,
      label: "Upstream secret key version",
      env_names: [@codex_env_prefix <> "UPSTREAM_SECRET_KEY_VERSION"],
      storage: :environment,
      reloadability: :boot,
      notes: "Version metadata for the env-only upstream secret root."
    },
    %{
      key: :release_distribution,
      bucket: :env_only_boot,
      group: :release_clustering,
      label: "BEAM distribution mode",
      env_names: ["RELEASE_DISTRIBUTION"],
      storage: :environment,
      reloadability: :boot,
      notes: "Release clustering topology is decided before the VM joins a cluster."
    },
    %{
      key: :release_node,
      bucket: :env_only_boot,
      group: :release_clustering,
      label: "BEAM node name",
      env_names: ["RELEASE_NODE"],
      storage: :environment,
      reloadability: :boot,
      notes: "Node identity must be stable before distribution starts."
    },
    %{
      key: :erl_aflags,
      bucket: :env_only_boot,
      group: :release_clustering,
      label: "Erlang VM flags",
      env_names: ["ERL_AFLAGS"],
      storage: :environment,
      reloadability: :boot,
      notes: "VM distribution and runtime flags are outside application DB control."
    },
    %{
      key: :release_cookie,
      bucket: :secret_env_only,
      group: :release_clustering,
      label: "BEAM distribution cookie",
      env_names: ["RELEASE_COOKIE"],
      storage: :environment,
      reloadability: :boot,
      notes:
        "Cluster authentication secret consumed by the release/VM, not by the instance settings system.",
      sensitive?: true
    },
    %{
      key: :file_lifecycle,
      bucket: :db_runtime_live,
      group: :files,
      label: "File upload and metadata lifecycle",
      env_names: [
        @codex_env_prefix <> "FILE_MAX_SIZE_BYTES",
        @codex_env_prefix <> "UPLOAD_TTL_SECONDS",
        @codex_env_prefix <> "ABANDONED_UPLOAD_CLEANUP_INTERVAL_SECONDS"
      ],
      storage: :database,
      reloadability: :live,
      notes:
        "Backend file size, TTL, and cleanup cadence should be managed as typed file settings."
    },
    %{
      key: :transcription_upload_max,
      bucket: :db_runtime_live,
      group: :transcription,
      label: "Transcription upload limit",
      env_names: [@codex_env_prefix <> "MAX_TRANSCRIPTION_UPLOAD_BYTES"],
      storage: :database,
      reloadability: :live,
      notes:
        "Multipart audio upload limit should apply to new transcription requests without restart."
    },
    %{
      key: :gateway_debug,
      bucket: :db_runtime_live,
      group: :gateway,
      label: "Gateway debug metadata",
      env_names: [@codex_env_prefix <> "GATEWAY_DEBUG"],
      storage: :database,
      reloadability: :live,
      notes: "Safe metadata-only debug flag can be evaluated per request."
    },
    %{
      key: :sse_keepalive_interval,
      bucket: :db_runtime_live,
      group: :gateway,
      label: "SSE keepalive interval",
      env_names: [@codex_env_prefix <> "SSE_KEEPALIVE_INTERVAL_MS"],
      storage: :database,
      reloadability: :live,
      notes: "New streams can pick up heartbeat interval changes."
    },
    %{
      key: :websocket_idle_timeout,
      bucket: :db_runtime_live,
      group: :gateway,
      label: "Websocket idle timeout",
      env_names: [@codex_env_prefix <> "WEBSOCKET_IDLE_TIMEOUT_MS"],
      storage: :database,
      reloadability: :live,
      notes: "New downstream websocket upgrades can use the bounded idle timeout."
    },
    %{
      key: :upstream_timeouts,
      bucket: :db_runtime_live,
      group: :gateway,
      label: "Upstream HTTP timeouts",
      env_names: [
        @codex_env_prefix <> "UPSTREAM_CONNECT_TIMEOUT_MS",
        @codex_env_prefix <> "UPSTREAM_POOL_TIMEOUT_MS",
        @codex_env_prefix <> "UPSTREAM_RECEIVE_TIMEOUT_MS"
      ],
      storage: :database,
      reloadability: :live,
      notes: "Timeout options are attached to each new upstream request."
    },
    %{
      key: :model_context_window_overrides,
      bucket: :db_runtime_live,
      group: :gateway,
      label: "Model context window overrides",
      env_names: [@codex_env_prefix <> "MODEL_CONTEXT_WINDOW_OVERRIDES"],
      storage: :database,
      reloadability: :live,
      notes: "Model metadata reads can use a typed map from the current settings snapshot."
    },
    %{
      key: :decompression_limits,
      bucket: :db_runtime_live,
      group: :ingress,
      label: "Runtime decompression and body limits",
      env_names: [
        @codex_env_prefix <> "DECOMPRESSION_ALGORITHMS",
        @codex_env_prefix <> "MAX_COMPRESSED_BODY_BYTES",
        @codex_env_prefix <> "MAX_DECOMPRESSED_BODY_BYTES",
        @codex_env_prefix <> "MAX_DECOMPRESSION_RATIO",
        @codex_env_prefix <> "DECOMPRESSION_TIMEOUT_MS"
      ],
      storage: :database,
      reloadability: :live,
      notes: "Runtime ingress plugs can evaluate these limits for each new request body."
    },
    %{
      key: :expired_alias_ttl,
      bucket: :db_runtime_live,
      group: :gateway,
      label: "Expired durable alias TTL",
      env_names: [@codex_env_prefix <> "EXPIRED_ALIAS_TTL_SECONDS"],
      storage: :database,
      reloadability: :live,
      notes: "Alias cleanup and new continuity decisions can use the latest settings snapshot."
    },
    %{
      key: :operator_login_base_url,
      bucket: :db_runtime_live,
      group: :operator_email,
      label: "Operator login base URL",
      env_names: [@codex_env_prefix <> "OPERATOR_LOGIN_BASE_URL"],
      storage: :database,
      reloadability: :live,
      notes: "Operator email generation should read this at send time."
    },
    %{
      key: :firewall_allowlist,
      bucket: :db_runtime_cached,
      group: :ingress,
      label: "Runtime firewall allowlist",
      env_names: [@codex_env_prefix <> "FIREWALL_ALLOWLIST"],
      storage: :database,
      reloadability: :cached,
      notes:
        "CIDR/exact IP allowlist is security-sensitive runtime policy and should flow through cached settings."
    },
    %{
      key: :trusted_proxies,
      bucket: :db_runtime_cached,
      group: :ingress,
      label: "Trusted proxy allowlist",
      env_names: [@codex_env_prefix <> "TRUSTED_PROXIES"],
      storage: :database,
      reloadability: :cached,
      notes: "Controls whether forwarded client headers are trusted."
    },
    %{
      key: :bridge_owner_lease,
      bucket: :db_runtime_cached,
      group: :gateway,
      label: "Bridge owner lease timing",
      env_names: [
        @codex_env_prefix <> "BRIDGE_OWNER_LEASE_TTL_SECONDS",
        @codex_env_prefix <> "BRIDGE_OWNER_LEASE_RENEWAL_SECONDS"
      ],
      storage: :database,
      reloadability: :cached,
      notes:
        "New or renewed durable bridge leases use cached settings; existing timestamps are not rewritten."
    },
    %{
      key: :circuit_thresholds,
      bucket: :db_runtime_cached,
      group: :gateway,
      label: "Circuit breaker thresholds",
      env_names: [
        @codex_env_prefix <> "CIRCUIT_FAILURE_THRESHOLD",
        @codex_env_prefix <> "CIRCUIT_OPEN_SECONDS",
        @codex_env_prefix <> "CIRCUIT_HALF_OPEN_PROBE_LIMIT",
        @codex_env_prefix <> "CIRCUIT_SUCCESS_THRESHOLD"
      ],
      storage: :database,
      reloadability: :cached,
      notes:
        "New circuit decisions use updated thresholds without deleting existing circuit rows."
    },
    %{
      key: :bulkheads,
      bucket: :db_runtime_cached,
      group: :gateway,
      label: "Route-class bulkheads",
      env_names: [
        "CODEX_POOLER_BULKHEAD_<ROUTE_CLASS>_MAX_CONCURRENCY",
        "CODEX_POOLER_BULKHEAD_<ROUTE_CLASS>_QUEUE_LIMIT",
        "CODEX_POOLER_BULKHEAD_<ROUTE_CLASS>_QUEUE_TIMEOUT_MS"
      ],
      storage: :database,
      reloadability: :cached,
      notes:
        "Known route classes stay typed; updates affect future admission decisions, not in-flight leases."
    },
    %{
      key: :mcp_service_enabled,
      bucket: :db_runtime_cached,
      group: :mcp,
      label: "MCP service enabled",
      env_names: [],
      storage: :database,
      reloadability: :cached,
      notes:
        "Global metadata-only MCP service gate defaults disabled and flows through cached instance settings/PubSub invalidation."
    },
    %{
      key: :openai_pricing_url,
      bucket: :db_runtime_cached,
      group: :catalog,
      label: "OpenAI pricing catalog URL",
      env_names: [],
      storage: :database,
      reloadability: :cached,
      notes:
        "Hourly pricing import jobs resolve this URL from cached instance settings when each job performs."
    },
    %{
      key: :development_account_reconciliation_pause,
      bucket: :db_runtime_cached,
      group: :development,
      label: "Development account reconciliation pause",
      env_names: [],
      storage: :database,
      reloadability: :cached,
      notes:
        "Development-only guard for local fake accounts; hidden and ignored outside the dev-feature gate."
    },
    %{
      key: :smtp_delivery,
      bucket: :db_runtime_cached,
      group: :smtp,
      label: "SMTP non-secret delivery settings",
      env_names: [
        @smtp_env_prefix <> "HOST",
        @smtp_env_prefix <> "PORT",
        @smtp_env_prefix <> "USERNAME",
        @smtp_env_prefix <> "FROM",
        @smtp_env_prefix <> "SSL",
        @smtp_env_prefix <> "TLS",
        @smtp_env_prefix <> "RETRIES"
      ],
      storage: :database,
      reloadability: :cached,
      notes:
        "Delivery-time config should reload through cached instance settings; the sender address remains email composition metadata."
    },
    %{
      key: :smtp_password,
      bucket: :secret_encrypted_db,
      group: :smtp,
      label: "SMTP password",
      env_names: [@smtp_env_prefix <> "PASSWORD"],
      storage: :encrypted_database_secret,
      reloadability: :cached,
      notes:
        "Cleartext is needed only at mail send/test time, so the DB stores ciphertext and metadata, never raw rendered values.",
      sensitive?: true,
      metadata: ["ciphertext", "key_version"]
    },
    %{
      key: :metrics_bearer_token,
      bucket: :secret_hmac_db,
      group: :metrics,
      label: "Metrics bearer token",
      env_names: [@codex_env_prefix <> "METRICS_BEARER_TOKEN"],
      storage: :hmac_database_secret,
      reloadability: :cached,
      notes:
        "Only bearer-token comparison is required; persist keyed HMAC digest, safe fingerprint, and key version.",
      sensitive?: true,
      metadata: ["hmac_digest", "fingerprint", "key_version"]
    }
  ]

  @candidate_keys Enum.map(@settings, & &1.key)
  @classified_keys @candidate_keys
  @out_of_scope_notes [
    "API/client examples such as CODEX_POOLER_API_KEY are runtime credentials or documentation placeholders, not instance settings candidates.",
    "Deployment image and host-port variables such as CODEX_POOLER_IMAGE, CODEX_POOLER_IMAGE_TAG, and CODEX_POOLER_HTTP_PORT are wrapper/deployment inputs, not application instance settings.",
    "Development and test Postgres variables such as POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB, POSTGRES_TEST_DB, and MIX_TEST_PARTITION are local/test harness inputs.",
    "Browser CSP live helper sources, invite public origin, quota freshness/skew, Codex client version, upstream websocket keepalive, and file bridge retry knobs remain out of the current migration plan unless a later task explicitly promotes them."
  ]

  @spec buckets() :: [bucket()]
  def buckets, do: @buckets

  @spec bucket_notes() :: %{bucket() => String.t()}
  def bucket_notes, do: @bucket_notes

  @spec settings() :: [setting()]
  def settings, do: @settings

  @spec candidate_keys() :: [atom()]
  def candidate_keys, do: @candidate_keys

  @spec classified_keys() :: [atom()]
  def classified_keys, do: @classified_keys

  @spec out_of_scope_notes() :: [String.t()]
  def out_of_scope_notes, do: @out_of_scope_notes

  @spec settings_by_bucket() :: %{bucket() => [setting()]}
  def settings_by_bucket do
    empty_buckets = Map.new(@buckets, &{&1, []})

    @settings
    |> Enum.group_by(& &1.bucket)
    |> then(&Map.merge(empty_buckets, &1))
  end

  @spec settings_for(bucket()) :: [setting()]
  def settings_for(bucket) when bucket in @buckets do
    settings_by_bucket()
    |> Map.fetch!(bucket)
  end

  @spec fetch!(atom()) :: setting()
  def fetch!(key) when is_atom(key) do
    Enum.find(@settings, &(&1.key == key)) || raise KeyError, key: key, term: __MODULE__
  end

  @spec bucket_for!(atom()) :: bucket()
  def bucket_for!(key), do: fetch!(key).bucket

  @spec unclassified_candidates([atom()]) :: [atom()]
  def unclassified_candidates(candidates \\ @candidate_keys) when is_list(candidates) do
    Enum.reject(candidates, &(&1 in @classified_keys))
  end

  @spec validate_candidate_coverage([atom()]) :: :ok | {:error, [atom()]}
  def validate_candidate_coverage(candidates \\ @candidate_keys) when is_list(candidates) do
    case unclassified_candidates(candidates) do
      [] -> :ok
      missing -> {:error, missing}
    end
  end
end
