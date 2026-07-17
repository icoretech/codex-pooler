import Config

config :codex_pooler, :scopes,
  user: [
    default: true,
    module: CodexPooler.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: CodexPooler.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :codex_pooler,
  ecto_repos: [CodexPooler.Repo],
  generators: [timestamp_type: :utc_datetime]

jobs_schedule = [
  %{
    key: :catalog_sync,
    id: "catalog-sync",
    title: "Catalog sync",
    description: "Model catalog refresh",
    icon: "hero-rectangle-stack",
    workers: [
      CodexPooler.Jobs.CatalogSyncWorker,
      CodexPooler.Jobs.CatalogSyncEnqueueWorker
    ],
    scheduled_worker: CodexPooler.Jobs.CatalogSyncEnqueueWorker,
    cadence: %{label: "Every 30 min", cron: "*/30 * * * *"}
  },
  %{
    key: :pricing_import,
    id: "pricing-import",
    title: "Pricing import",
    description: "Pricing data refresh",
    icon: "hero-currency-dollar",
    workers: [CodexPooler.Jobs.PricingImportWorker],
    scheduled_worker: CodexPooler.Jobs.PricingImportWorker,
    cadence: %{label: "Hourly", cron: "0 * * * *"}
  },
  %{
    key: :account_reconciliation,
    id: "account-reconciliation",
    title: "Account reconciliation",
    description: "Upstream account checks",
    icon: "hero-arrow-path-rounded-square",
    workers: [
      CodexPooler.Jobs.AccountReconciliationWorker,
      CodexPooler.Jobs.AccountReconciliationEnqueueWorker
    ],
    scheduled_worker: CodexPooler.Jobs.AccountReconciliationEnqueueWorker,
    cadence: %{label: "Every minute", cron: "* * * * *"}
  },
  %{
    key: :alert_evaluation,
    id: "alert-evaluation",
    title: "Alert evaluation",
    description: "Alert rule checks",
    icon: "hero-bell-alert",
    workers: [
      CodexPooler.Jobs.AlertEvaluationWorker,
      CodexPooler.Jobs.AlertEvaluationEnqueueWorker
    ],
    scheduled_worker: CodexPooler.Jobs.AlertEvaluationEnqueueWorker,
    cadence: %{label: "Every 5 min", cron: "*/5 * * * *"}
  },
  %{
    key: :token_refresh,
    id: "token-refresh",
    title: "Token refresh",
    description: "Access-token renewal",
    icon: "hero-key",
    workers: [
      CodexPooler.Jobs.TokenRefreshWorker,
      CodexPooler.Jobs.TokenRefreshEnqueueWorker
    ],
    scheduled_worker: CodexPooler.Jobs.TokenRefreshEnqueueWorker,
    cadence: %{label: "Every 15 min", cron: "*/15 * * * *"}
  },
  %{
    key: :daily_rollup_rebuild,
    id: "daily-rollup-rebuild",
    title: "Daily rollup rebuild",
    description: "Usage rollup rebuild",
    icon: "hero-chart-bar-square",
    workers: [
      CodexPooler.Jobs.DailyRollupRebuildWorker,
      CodexPooler.Jobs.DailyRollupRebuildEnqueueWorker
    ],
    scheduled_worker: CodexPooler.Jobs.DailyRollupRebuildEnqueueWorker,
    cadence: %{label: "Daily at 00:17 UTC", cron: "17 0 * * *"}
  },
  %{
    key: :runtime_cleanup,
    id: "runtime-cleanup",
    title: "Runtime cleanup",
    description: "Expired state cleanup",
    icon: "hero-sparkles",
    workers: [CodexPooler.Jobs.RuntimeStateCleanupWorker],
    scheduled_worker: CodexPooler.Jobs.RuntimeStateCleanupWorker,
    cadence: %{label: "Every 15 min", cron: "*/15 * * * *"}
  }
]

config :codex_pooler, CodexPooler.Jobs.Schedule, entries: jobs_schedule

jobs_crontab =
  Enum.flat_map(jobs_schedule, fn
    %{cadence: %{cron: cron}, scheduled_worker: worker} when is_binary(cron) -> [{cron, worker}]
    _entry -> []
  end)

config :codex_pooler, Oban,
  repo: CodexPooler.Repo,
  queues: [jobs: 8],
  shutdown_grace_period: :timer.seconds(55),
  plugins: [
    {Oban.Plugins.Cron, crontab: jobs_crontab},
    Oban.Plugins.Lifeline,
    {Oban.Plugins.Pruner, max_age: 24 * 60 * 60}
  ]

config :codex_pooler, CodexPooler.Accounts,
  session_ttl_seconds: 14 * 24 * 60 * 60,
  totp_encryption_key: Base.encode64(:crypto.hash(:sha256, "codex-pooler-local-totp-key")),
  totp_key_version: "v1"

config :codex_pooler, CodexPooler.Files,
  max_file_size_bytes: 25 * 1024 * 1024,
  # TTL applies to database metadata for upstream-backed files, not local payload storage.
  file_ttl_seconds: 24 * 60 * 60

config :codex_pooler, CodexPoolerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CodexPoolerWeb.ErrorHTML, json: CodexPoolerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CodexPooler.PubSub,
  live_view: [signing_salt: "EhHEBqJ3"]

config :codex_pooler, CodexPooler.Mailer, adapter: Swoosh.Adapters.Local

config :esbuild,
  version: "0.25.4",
  codex_pooler: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.3",
  codex_pooler: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :admin_surface,
    :loader,
    :error_code,
    :request_compression_reason,
    :request_compression_exception,
    :request_compression_route_class,
    :request_compression_transport
  ]

config :phoenix, :logger, false

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "access_token",
  "api_key",
  "auth_json",
  "authorization",
  "bearer_token",
  "bearer_token_action",
  "client_secret",
  "content",
  "cookie",
  "device_code",
  "encrypted_content",
  "file",
  "image",
  "input",
  "messages",
  "password",
  "password_action",
  "prompt",
  "refresh_token",
  "token"
]

config :mime, :types, %{
  "text/event-stream" => ["event-stream"]
}

import_config "#{config_env()}.exs"
