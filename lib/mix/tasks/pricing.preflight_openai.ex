defmodule Mix.Tasks.Pricing.PreflightOpenai do
  use Mix.Task

  alias CodexPooler.Catalog.OpenAIPricingPreflight

  @shortdoc "Validate OpenAI pricing JSON compatibility without database writes"

  @moduledoc """
  Validates a candidate `openai-json-pricing` document without starting the
  application or touching the database.

  The task is fail-closed: it exits non-zero when a candidate contains a price
  bucket or source field that the current importer would silently discard.

  ## Usage

      mix pricing.preflight_openai PATH
      mix pricing.preflight_openai --path PATH
      mix pricing.preflight_openai -p PATH
  """

  @impl Mix.Task
  def run(args) do
    path = parse_path!(args)
    result = OpenAIPricingPreflight.validate_file(path)
    Mix.shell().info(CodexPooler.JSON.encode!(result, pretty: true))

    unless result.compatible? do
      Mix.raise("pricing preflight failed for #{path}")
    end
  end

  defp parse_path!(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [path: :string], aliases: [p: :path])

    case {invalid, Keyword.get(opts, :path) || List.first(rest)} do
      {[], path} when is_binary(path) -> path
      _ -> Mix.raise("usage: mix pricing.preflight_openai --path PATH")
    end
  end
end
