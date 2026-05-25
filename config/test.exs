import Config

config :argon2_elixir, t_cost: 1, m_cost: 8

# The MIX_TEST_PARTITION environment variable can be used
# to fan out isolated test databases in CI.
config :codex_pooler, CodexPooler.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5433")),
  database:
    "#{System.get_env("POSTGRES_TEST_DB", "codex_pooler_test")}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :codex_pooler, Oban,
  testing: :manual,
  queues: false,
  shutdown_grace_period: :timer.seconds(55),
  plugins: false

config :codex_pooler, CodexPoolerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0W/ugDYhzDkRIy8rN1FLggPbDBZ7R1yROeLZfr3kArhi78yT+0Cm/5fqIk5ES3dm",
  server: false

config :codex_pooler, CodexPooler.Mailer, adapter: Swoosh.Adapters.Test
config :codex_pooler, dev_features_build_enabled: true
config :codex_pooler, dev_features_enabled: false
config :codex_pooler, dev_seeds_enabled: true

config :swoosh, :api_client, false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true
