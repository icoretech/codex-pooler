defmodule Mix.Tasks.Dev.Seed do
  @moduledoc """
  Seeds local development data.

  ## Usage

      mix dev.seed
      mix dev.seed compact
      mix dev.seed full
      mix dev.seed docs_screenshots
      mix dev.seed perf
      mix dev.seed perf --upstream-base-url http://fake-upstream:4058
      mix dev.seed full --upstream-base-url http://fake-upstream:4058
      mix dev.seed real_traffic

   `compact` creates a small operator baseline. `full` recreates deterministic
   fake data for exercising admin UI states. `docs_screenshots` replaces visible
   labels with public-safe documentation fixtures. `perf` recreates an isolated
   local gateway performance dataset and writes private bootstrap files under
   `tmp/`.

   Synthetic identities of `full` and `perf` point at a fake that exists: the
   local perf fake `http://127.0.0.1:4058` by default, or the loopback or
   in-cluster origin given with `--upstream-base-url` (public hosts are
   refused). `real_traffic` creates the dedicated Pool `dev-real-traffic` that
   real identities are imported into (never next to synthetic sources) and
   writes its API key to a mode-0600 `tmp/dev-seed/real-traffic.env`.
  """

  use Mix.Task

  alias CodexPooler.Dev.{LocalTarget, QaBackgroundWorkers, Seeds}

  @requirements ["app.config"]
  @shortdoc "Seed idempotent local development data"

  @impl Mix.Task
  def run(args) do
    QaBackgroundWorkers.start_application!()
    {profile, options} = parse_args!(args)

    case profile do
      "compact" -> seed_compact()
      "full" -> seed_full(options)
      "docs_screenshots" -> seed_docs_screenshots()
      "perf" -> seed_perf(options)
      "real_traffic" -> seed_real_traffic()
    end
  end

  @usage "usage: mix dev.seed [compact|full|docs_screenshots|perf|real_traffic] [--upstream-base-url URL (full, perf)]"

  # Parsed and validated before any seed write, so a bad profile or a public
  # upstream host never touches the database.
  defp parse_args!(args) do
    case OptionParser.parse(args, strict: [upstream_base_url: :string]) do
      {[], [], []} -> {"compact", []}
      {[], [profile], []} when profile in ~w(compact full docs_screenshots perf real_traffic) -> {profile, []}
      {[upstream_base_url: url], [profile], []} when profile in ~w(full perf) -> {profile, [upstream_base_url: validated_url!(url)]}
      _invalid -> Mix.raise(@usage)
    end
  end

  defp validated_url!(url) do
    case LocalTarget.upstream_base_url(url, url) do
      {:ok, validated} -> validated
      {:error, message} -> Mix.raise(message)
    end
  end

  defp seed_compact do
    result = Seeds.compact()

    Mix.shell().info("seeded compact dev operators owner=#{result.owner.email} operators=#{length(result.operators)} password=#{result.password}")
  end

  defp seed_full(options) do
    result = Seeds.full(options)

    Mix.shell().info("seeded full dev data owner=#{result.owner.email} operators=#{length(result.operators)} pools=#{length(result.pools)} api_keys=#{length(result.api_keys)} upstreams=#{length(result.upstream_identities)} password=#{result.password}")
  end

  defp seed_docs_screenshots do
    result = Seeds.docs_screenshots()

    Mix.shell().info("seeded documentation screenshot data owner=#{result.owner.email} operators=#{length(result.operators)} pools=#{length(result.pools)} api_keys=#{length(result.api_keys)} upstreams=#{length(result.upstream_identities)} password=#{result.password}")
  end

  defp seed_perf(options) do
    result = Seeds.perf(options)

    Mix.shell().info("seeded perf dev data pool=#{result.pool.slug} api_key_prefix=#{result.api_key.key_prefix} upstreams=#{length(result.upstream_identities)} bootstrap=#{result.bootstrap_dir}")
  end

  defp seed_real_traffic do
    result = Seeds.real_traffic()

    Mix.shell().info("seeded real traffic pool pool=#{result.pool.slug} api_key_prefix=#{result.api_key.key_prefix} revoked_api_keys=#{result.revoked_api_keys} env=#{result.env_path}")
  end
end
