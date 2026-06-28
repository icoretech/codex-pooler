import Config

if System.get_env("PHX_SERVER") in ~w(true 1) do
  config :codex_pooler, CodexPoolerWeb.Endpoint, server: true
end

websocket_drain_timeout_ms =
  CodexPooler.Gateway.Transports.Websocket.RolloutDrain.configured_timeout_ms()

endpoint_shutdown_timeout_ms = websocket_drain_timeout_ms + 5_000

config :codex_pooler, CodexPoolerWeb.Endpoint,
  http: [
    port: String.to_integer(System.get_env("PORT", "4000")),
    thousand_island_options: [shutdown_timeout: endpoint_shutdown_timeout_ms]
  ]

config :codex_pooler,
       :websocket_owner_forwarding_enabled,
       CodexPooler.Gateway.OperationalSettings.parse_websocket_owner_forwarding_env!()

config :codex_pooler, CodexPoolerWeb.Operations.HealthController,
  drain_marker_path: System.get_env("CODEX_POOLER_DRAIN_MARKER_PATH")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :codex_pooler, CodexPooler.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  oban_mode = System.get_env("OBAN_MODE", "web")

  oban_plugins = [
    {Oban.Plugins.Cron, crontab: CodexPooler.Jobs.Schedule.oban_crontab()},
    Oban.Plugins.Lifeline,
    {Oban.Plugins.Pruner, max_age: 24 * 60 * 60}
  ]

  oban_queues = [jobs: String.to_integer(System.get_env("OBAN_JOBS_QUEUE_LIMIT", "8"))]

  oban_shutdown_grace_period =
    String.to_integer(System.get_env("OBAN_SHUTDOWN_GRACE_PERIOD_MS", "55000"))

  base_oban_runtime_config = [
    repo: CodexPooler.Repo,
    shutdown_grace_period: oban_shutdown_grace_period
  ]

  oban_runtime_config =
    case oban_mode do
      "worker" ->
        Keyword.merge(base_oban_runtime_config, queues: oban_queues, plugins: false)

      "scheduler" ->
        Keyword.merge(base_oban_runtime_config, queues: false, plugins: oban_plugins)

      "all" ->
        Keyword.merge(base_oban_runtime_config, queues: oban_queues, plugins: oban_plugins)

      _web_or_unknown ->
        Keyword.merge(base_oban_runtime_config, queues: false, plugins: false)
    end

  config :codex_pooler, Oban, oban_runtime_config

  config :codex_pooler, CodexPooler.Accounts,
    totp_encryption_key: System.get_env("CODEX_POOLER_TOTP_ENCRYPTION_KEY"),
    totp_key_version: System.get_env("CODEX_POOLER_TOTP_KEY_VERSION", "v1")

  upstream_secret_key = System.get_env("CODEX_POOLER_UPSTREAM_SECRET_KEY")
  CodexPooler.Upstreams.Secrets.validate_upstream_secret_key!(upstream_secret_key)

  config :codex_pooler, CodexPooler.Upstreams,
    upstream_secret_key: upstream_secret_key,
    upstream_secret_key_version: System.get_env("CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION", "v1")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :codex_pooler, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :codex_pooler, CodexPoolerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      port: String.to_integer(System.get_env("PORT", "4000")),
      ip: {0, 0, 0, 0},
      thousand_island_options: [shutdown_timeout: endpoint_shutdown_timeout_ms]
    ],
    secret_key_base: secret_key_base

  config :codex_pooler, CodexPooler.Mailer, []
end
