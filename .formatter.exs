[
  # The numeric sentinel disables practical line wrapping while preserving
  # indentation; Inspect.Algebra's :infinity mode flattens nested indentation.
  line_length: 1_000_000,
  heex_line_length: 1_000_000,
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test,dev_support}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    "priv/*/dev_fixtures/**/*.{ex,exs}"
  ]
]
