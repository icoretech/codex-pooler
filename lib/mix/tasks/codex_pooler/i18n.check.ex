defmodule Mix.Tasks.CodexPooler.I18n.Check do
  use Mix.Task

  alias CodexPoolerWeb.I18n.Catalog

  @shortdoc "Validates shipped translations and Gettext source boundaries"

  @moduledoc """
  Validates local POT/PO completeness, locale headers, plural forms, fuzzy flags,
  placeholders, source msgids and Gettext ownership boundaries. No application,
  database or network connection is started.

      mix codex_pooler.i18n.check
      mix codex_pooler.i18n.check --root PATH

  This command does not extract messages. `mix quality.i18n` first runs
  `gettext.extract --check-up-to-date`, then this catalog gate and the scanner's
  read-only non-regression check.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [root: :string])
    if rest != [] or invalid != [], do: Mix.raise("usage: mix codex_pooler.i18n.check [--root PATH]")

    Mix.Task.run("compile")

    case Catalog.check(opts) do
      :ok ->
        Mix.shell().info("i18n catalogs and source boundaries are valid")

      {:error, errors} ->
        Enum.each(errors, &Mix.shell().error(Catalog.format_issue(&1)))
        Mix.raise("i18n check failed with #{length(errors)} issue(s)")
    end
  end
end
