defmodule Mix.Tasks.Dev.Seed do
  @moduledoc """
  Seeds local development data.

  ## Usage

      mix dev.seed
      mix dev.seed compact
      mix dev.seed full
      mix dev.seed perf

   `compact` creates a small operator baseline. `full` recreates deterministic
   fake data for exercising admin UI states. `perf` recreates an isolated local
   gateway performance dataset and writes private bootstrap files under `tmp/`.
  """

  use Mix.Task

  alias CodexPooler.Dev.Seeds

  @shortdoc "Seed idempotent local development data"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [] -> seed_compact()
      ["compact"] -> seed_compact()
      ["full"] -> seed_full()
      ["perf"] -> seed_perf()
      _args -> Mix.raise("usage: mix dev.seed [compact|full|perf]")
    end
  end

  defp seed_compact do
    result = Seeds.compact()

    Mix.shell().info(
      "seeded compact dev operators owner=#{result.owner.email} operators=#{length(result.operators)} password=#{result.password}"
    )
  end

  defp seed_full do
    result = Seeds.full()

    Mix.shell().info(
      "seeded full dev data owner=#{result.owner.email} operators=#{length(result.operators)} pools=#{length(result.pools)} api_keys=#{length(result.api_keys)} upstreams=#{length(result.upstream_identities)} password=#{result.password}"
    )
  end

  defp seed_perf do
    result = Seeds.perf()

    Mix.shell().info(
      "seeded perf dev data pool=#{result.pool.slug} api_key_prefix=#{result.api_key.key_prefix} upstreams=#{length(result.upstream_identities)} bootstrap=#{result.bootstrap_dir}"
    )
  end
end
