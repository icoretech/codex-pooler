import Config

config :argon2_elixir, t_cost: 1, m_cost: 8

test_postgres_user =
  System.get_env("CODEX_POOLER_TEST_POSTGRES_USER") || System.get_env("POSTGRES_USER", "postgres")

test_postgres_password = System.get_env("CODEX_POOLER_TEST_POSTGRES_PASSWORD", "postgres")

test_postgres_host =
  System.get_env("CODEX_POOLER_TEST_POSTGRES_HOST") ||
    System.get_env("POSTGRES_HOST", "localhost")

test_postgres_port =
  System.get_env("CODEX_POOLER_TEST_POSTGRES_PORT") || System.get_env("POSTGRES_PORT", "5433")

test_postgres_database =
  System.get_env("CODEX_POOLER_TEST_POSTGRES_DB") ||
    System.get_env("POSTGRES_TEST_DB", "codex_pooler_test")

# Only positive integer ids activate partitioning. Missing, blank, malformed,
# zero, and negative values fail safe to the serial test configuration.
test_partition =
  case Integer.parse(System.get_env("MIX_TEST_PARTITION") || "") do
    {partition, ""} when partition > 0 -> Integer.to_string(partition)
    _invalid -> nil
  end

test_run_namespace =
  if test_partition do
    case System.get_env("CODEX_POOLER_TEST_RUN_NAMESPACE") do
      nil ->
        nil

      namespace when byte_size(namespace) == 16 ->
        if Regex.match?(~r/\A[0-9a-f]{16}\z/, namespace) do
          namespace
        else
          raise "CODEX_POOLER_TEST_RUN_NAMESPACE must be exactly 16 lowercase hex characters"
        end

      _invalid ->
        raise "CODEX_POOLER_TEST_RUN_NAMESPACE must be exactly 16 lowercase hex characters"
    end
  end

test_database =
  if test_partition && test_run_namespace do
    base_fingerprint =
      :sha256
      |> :crypto.hash(test_postgres_database)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "codex_pooler_test_#{base_fingerprint}_#{test_run_namespace}_p#{test_partition}"
  else
    "#{test_postgres_database}#{test_partition}"
  end

test_repo_pool_size =
  if test_partition do
    8
  else
    System.schedulers_online() * 2
  end

# The MIX_TEST_PARTITION environment variable can be used
# to fan out isolated test databases in CI.
config :codex_pooler, CodexPooler.Repo,
  username: test_postgres_user,
  password: test_postgres_password,
  hostname: test_postgres_host,
  port: String.to_integer(test_postgres_port),
  database: test_database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: test_repo_pool_size

config :codex_pooler, Oban,
  notifier: if(test_partition, do: Oban.Notifiers.PG, else: Oban.Notifiers.Postgres),
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
