defmodule Mix.Tasks.CodexPooler.I18n.Scan do
  use Mix.Task

  alias CodexPoolerWeb.I18n.Scanner

  @shortdoc "Reports hardcoded browser text and checks per-file non-regression"

  @moduledoc """
  Reports candidate English UI strings without changing the tracked baseline.
  This is a heuristic inventory, not a substitute for reviewing each page.

      mix codex_pooler.i18n.scan
      mix codex_pooler.i18n.scan --details
      mix codex_pooler.i18n.scan --check
      mix codex_pooler.i18n.scan --write-baseline

  `--check` fails if any file's count exceeds its committed count (new files
  start at zero). `--write-baseline` is the only write operation and must be
  explicitly requested after reviewing the per-file report. It cannot be
  combined with `--check`.

  Options: `--root PATH`, `--allowlist PATH`, `--baseline PATH`, `--details`.
  Relative allowlist and baseline paths are resolved below `--root`. The default
  paths are `priv/i18n/scan_allowlist.txt` and
  `priv/i18n/hardcoded_baseline.json`.
  """

  @impl Mix.Task
  def run(args) do
    opts = parse_options!(args)

    root = opts |> Keyword.get(:root, ".") |> Path.expand()
    allowlist = Path.expand(Keyword.get(opts, :allowlist, "priv/i18n/scan_allowlist.txt"), root)
    baseline = Path.expand(Keyword.get(opts, :baseline, "priv/i18n/hardcoded_baseline.json"), root)
    Mix.Task.run("compile")

    case Scanner.scan(root: root, allowlist_path: allowlist) do
      {:ok, report} ->
        print_report(report, opts)
        run_baseline_mode(report, baseline, opts)

      {:error, errors} ->
        Enum.each(errors, fn error -> Mix.shell().error(error) end)
        Mix.raise("i18n scan failed")
    end
  end

  defp parse_options!(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [root: :string, allowlist: :string, baseline: :string, details: :boolean, check: :boolean, write_baseline: :boolean])
    if rest != [] or invalid != [], do: Mix.raise("usage: mix codex_pooler.i18n.scan [--details] [--check | --write-baseline] [--root PATH] [--allowlist PATH] [--baseline PATH]")
    if Keyword.get(opts, :check, false) and Keyword.get(opts, :write_baseline, false), do: Mix.raise("--check cannot be combined with --write-baseline")
    opts
  end

  defp print_report(report, opts) do
    report.counts |> Enum.sort() |> Enum.each(fn {file, count} -> Mix.shell().info("#{count}\t#{file}") end)
    Mix.shell().info("#{report.total} hardcoded candidates in #{map_size(report.counts)} source files")
    if opts[:details], do: Enum.each(report.candidates, &Mix.shell().info("#{&1.file}:#{&1.line}: [#{&1.kind}] #{&1.text}"))
  end

  defp run_baseline_mode(report, path, opts) do
    if opts[:check], do: check_baseline!(report, path)
    if opts[:write_baseline], do: write_baseline!(report, path)
  end

  defp check_baseline!(report, path) do
    case File.read(path) do
      {:ok, contents} ->
        validate_baseline!(report, path, contents)

      {:error, reason} ->
        Mix.raise("cannot read scanner baseline #{path}: #{:file.format_error(reason)}; use --write-baseline only after reviewing the report")
    end
  end

  defp validate_baseline!(report, path, contents) do
    with {:ok, baseline} <- CodexPooler.JSON.decode(contents),
         :ok <- Scanner.check_baseline(report, baseline) do
      Mix.shell().info("i18n scanner baseline has no per-file regressions")
    else
      {:error, errors} when is_list(errors) ->
        Enum.each(errors, fn error -> Mix.shell().error(error) end)
        Mix.raise("i18n scanner baseline regressed")

      {:error, reason} ->
        Mix.raise("invalid scanner baseline #{path}: #{inspect(reason)}")
    end
  end

  defp write_baseline!(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, CodexPooler.JSON.encode!(Scanner.baseline(report), pretty: true) <> "\n")
    Mix.shell().info("Wrote reviewed scanner baseline #{path}")
  end
end
