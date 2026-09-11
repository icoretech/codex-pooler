import Config

dev_postgres_user = System.get_env("CODEX_POOLER_DEV_POSTGRES_USER", "postgres")
dev_postgres_password = System.get_env("CODEX_POOLER_DEV_POSTGRES_PASSWORD", "postgres")
dev_postgres_host = System.get_env("CODEX_POOLER_DEV_POSTGRES_HOST", "localhost")

dev_postgres_port =
  System.get_env("CODEX_POOLER_DEV_POSTGRES_PORT") || System.get_env("POSTGRES_PORT", "5433")

dev_postgres_database = System.get_env("CODEX_POOLER_DEV_POSTGRES_DB", "codex_pooler_dev")

config :codex_pooler, CodexPooler.Repo,
  username: dev_postgres_user,
  password: dev_postgres_password,
  hostname: dev_postgres_host,
  port: String.to_integer(dev_postgres_port),
  database: dev_postgres_database,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  parameters: [application_name: "codex_pooler_dev"]

config :codex_pooler, CodexPoolerWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "/OP6Z9AB1UYS3L9QWFWa27eO7gll5Q5YnddKcApl1FiAV82QXJUMJkpQTB6ZLkvI",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:codex_pooler, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:codex_pooler, ~w(--watch)]}
  ]

config :codex_pooler, CodexPoolerWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      # Gettext translations
      ~r"priv/gettext/.*\.po$"E,
      # Router, Controllers, LiveViews and LiveComponents
      ~r"lib/codex_pooler_web/router\.ex$"E,
      ~r"lib/codex_pooler_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :codex_pooler, dev_routes: true
config :codex_pooler, dev_features_build_enabled: true
config :codex_pooler, dev_features_enabled: true
config :codex_pooler, dev_seeds_enabled: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false
