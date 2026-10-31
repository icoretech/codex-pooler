defmodule Mix.Tasks.CodexPooler.I18n.Tolgee do
  use Mix.Task

  alias CodexPooler.Dev.I18n.{TolgeeCatalogs, TolgeeClient}

  @shortdoc "Previews or synchronizes Gettext catalogs with Tolgee"
  @moduledoc """
  Development-only translation synchronization. Requires explicit TOLGEE_URL,
  TOLGEE_PROJECT_ID and TOLGEE_API_KEY environment variables for network calls.
  The application and database are never started.

      mix codex_pooler.i18n.tolgee push
      mix codex_pooler.i18n.tolgee push --apply
      mix codex_pooler.i18n.tolgee check
      mix codex_pooler.i18n.tolgee pull
      mix codex_pooler.i18n.tolgee pull --output-dir /tmp/translation-candidate
      mix codex_pooler.i18n.tolgee pull --apply

  Push previews locally by default. Applying imports English source text and
  Chinese drafts with KEEP; it never removes keys or marks translations reviewed.
  Pull reads only reviewed Chinese translations, validates all three merged
  catalogs before writing, and preserves local PO metadata and unreviewed baseline.
  Output directories must be new; their layout is relative to priv/gettext.
  Check requires every source key and Chinese translation to survive the remote
  PO roundtrip; it reports valid Chinese differences without overwriting them.
  --root selects a Gettext catalog directory (default priv/gettext).
  HTTP is refused except loopback with explicit --allow-loopback.
  """

  @impl Mix.Task
  def run(args) do
    {action, opts} = parse!(args)
    Mix.Task.run("compile")
    bundles = TolgeeCatalogs.load!(Keyword.get(opts, :root, "priv/gettext"))

    if action == "push" and opts[:apply] != true do
      report(%{action: "push_preview", domains: length(bundles), source_entries: Enum.sum(Enum.map(bundles, &length(TolgeeCatalogs.active(&1.template))))})
    else
      config = TolgeeClient.configuration!(System.get_env(), opts[:allow_loopback] || false)
      {:ok, _} = Application.ensure_all_started(:req)
      execute(action, opts, config, bundles)
    end
  rescue
    error in [ArgumentError, File.Error] -> Mix.raise(Exception.message(error))
  end

  defp parse!([action | arguments]) when action in ["push", "pull", "check"] do
    {opts, rest, invalid} = OptionParser.parse(arguments, strict: [root: :string, apply: :boolean, output_dir: :string, allow_loopback: :boolean])
    option_names = arguments |> Enum.filter(&String.starts_with?(&1, "--")) |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd() |> String.replace_prefix("--no-", "--")))
    duplicates = length(option_names) != length(Enum.uniq(option_names))
    if rest != [] or invalid != [] or duplicates or forbidden?(action, opts), do: usage!()
    {action, opts}
  end

  defp parse!(_), do: usage!()

  defp forbidden?(action, opts) do
    (opts[:apply] == true and opts[:output_dir] != nil) or (action != "pull" and opts[:output_dir] != nil) or (action == "check" and opts[:apply] == true)
  end

  @spec usage!() :: no_return()
  defp usage!, do: Mix.raise("usage: mix codex_pooler.i18n.tolgee push|pull|check [--root DIR] [--allow-loopback] [--apply | --output-dir NEW_DIR]")

  defp execute("push", _opts, config, bundles) do
    :ok = TolgeeClient.push!(config, bundles)
    report(%{action: "push", domains: length(bundles), imported: true})
  end

  defp execute("check", _opts, config, bundles) do
    Enum.each(bundles, fn bundle ->
      english = TolgeeClient.export!(config, bundle.domain, "en", :all)
      chinese = TolgeeClient.export!(config, bundle.domain, "zh-CN", :all)
      report(Map.merge(TolgeeCatalogs.verify!(bundle, english, chinese), %{action: "check", domain: bundle.domain}))
    end)
  end

  defp execute("pull", opts, config, bundles) do
    candidates =
      Enum.map(bundles, fn bundle ->
        remote = TolgeeClient.export!(config, bundle.domain, "zh-CN", :reviewed)
        {catalog, counts} = TolgeeCatalogs.merge!(bundle, remote)
        {{bundle, catalog}, Map.merge(counts, %{action: "pull", domain: bundle.domain})}
      end)

    catalogs = Enum.map(candidates, &elem(&1, 0))

    cond do
      opts[:output_dir] -> TolgeeCatalogs.write_candidates!(catalogs, opts[:output_dir])
      opts[:apply] -> TolgeeCatalogs.apply!(catalogs)
      true -> :ok
    end

    Enum.each(candidates, fn {_candidate, counts} -> report(counts) end)
    report(%{written: !!(opts[:apply] || opts[:output_dir])})
  end

  defp report(counts), do: counts |> Jason.encode!() |> Mix.shell().info()
end
