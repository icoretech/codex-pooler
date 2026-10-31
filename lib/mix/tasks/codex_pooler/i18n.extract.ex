defmodule Mix.Tasks.CodexPooler.I18n.Extract do
  use Mix.Task

  @shortdoc "Extracts and merges Gettext catalogs, then validates translations"

  @moduledoc """
  Extracts messages and merges local catalogs, then runs the offline catalog
  gate. New or fuzzy Chinese entries make the final check fail until translated
  and reviewed. This command uses no network or translation service.

      mix codex_pooler.i18n.extract
      mix codex_pooler.i18n.extract --no-fuzzy

  Merge options are forwarded to `mix gettext.extract --merge`. Do not use
  `--check-up-to-date` here; the read-only CI entry point is `mix quality.i18n`.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [fuzzy: :boolean, fuzzy_threshold: :float, on_obsolete: :string, store_previous_message_on_fuzzy_match: :boolean])
    if rest != [] or invalid != [], do: Mix.raise("usage: mix codex_pooler.i18n.extract [--no-fuzzy] [--fuzzy-threshold FLOAT] [--on-obsolete delete|mark_as_obsolete] [--store-previous-message-on-fuzzy-match]")

    Mix.Task.reenable("gettext.extract")
    Mix.Task.run("gettext.extract", ["--merge" | OptionParser.to_argv(opts)])
    Mix.Task.reenable("codex_pooler.i18n.check")
    Mix.Task.run("codex_pooler.i18n.check", [])
  end
end
