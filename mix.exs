defmodule CodexPooler.MixProject do
  use Mix.Project

  def project do
    [
      app: :codex_pooler,
      # x-release-please-start-version
      version: "0.4.3",
      # x-release-please-end
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: Six, minimum_coverage: 85.0, threshold: 85],
      aliases: aliases(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {CodexPooler.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coverage: :test,
        precommit: :test,
        six: :test,
        "six.detail": :test,
        "six.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:dev), do: ["lib", "dev_support"]
  defp elixirc_paths(:test), do: ["lib", "dev_support", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:argon2_elixir, "== 4.1.3"},
      {:phoenix, "== 1.8.8"},
      {:phoenix_ecto, "== 4.7.0"},
      {:ecto_sql, "== 3.14.0"},
      {:postgrex, "== 0.22.2"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_reload, "== 1.6.2", only: :dev},
      {:phoenix_live_view, "== 1.2.3"},
      {:lazy_html, "== 0.1.11", only: :test},
      {:oban, "== 2.23.0"},
      {:phoenix_live_dashboard, "== 0.8.7", only: :dev},
      {:esbuild, "== 0.10.0", runtime: Mix.env() == :dev},
      {:tailwind, "== 0.5.1", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "== 1.26.1"},
      {:gen_smtp, "== 1.3.0"},
      {:req, "== 0.6.2"},
      {:finch, "== 0.23.0"},
      {:mint, "== 1.9.0"},
      {:mint_web_socket, "== 1.0.5"},
      {:telemetry_metrics, "== 1.1.0"},
      {:telemetry_metrics_prometheus_core, "== 1.2.1"},
      {:telemetry_poller, "== 1.3.0"},
      {:zoneinfo, "== 0.1.9"},
      {:credo, "== 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "== 1.4.7", only: [:dev, :test], runtime: false},
      {:sobelow, "== 0.14.1", only: [:dev, :test], runtime: false},
      {:six, "== 0.3.1", only: :test},
      {:gettext, "== 1.0.2"},
      {:jason, "== 1.4.5"},
      {:dns_cluster, "== 0.2.0"},
      {:websock, "== 0.5.3"},
      {:websock_adapter, "== 0.5.9"},
      {:bandit, "== 1.12.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": [
        "ecto.create",
        "ecto.migrate",
        "pricing.import_openai"
      ],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["codex_pooler.test"],
      "assets.setup": [
        "cmd npm ci --prefix assets",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["compile", "tailwind codex_pooler", "esbuild codex_pooler"],
      "assets.deploy": [
        "tailwind codex_pooler --minify",
        "esbuild codex_pooler --minify",
        "phx.digest"
      ],
      "quality.credo": ["credo --strict"],
      "quality.dialyzer": ["dialyzer"],
      "quality.security": ["sobelow --exit --threshold medium --skip"],
      quality: ["quality.credo", "quality.dialyzer", "quality.security"],
      coverage: ["test --cover"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
