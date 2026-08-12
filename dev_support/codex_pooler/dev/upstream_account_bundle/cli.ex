defmodule CodexPooler.Dev.UpstreamAccountBundle.CLI do
  @moduledoc false

  @spec parse_export_args([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_export_args(args) when is_list(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [out: :string, pool: :string])

    with :ok <- reject_parser_remainders(positional, invalid),
         :ok <- reject_duplicate_options(args, out: :string, pool: :string),
         {:ok, out_path} <- required_option(options, :out, "--out is required"),
         {:ok, pool_slug} <- required_option(options, :pool, "--pool is required") do
      {:ok, %{out_path: out_path, pool_slug: pool_slug}}
    end
  end

  @spec parse_import_args([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_import_args(args) when is_list(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [pool: :string, owner_email: :string, dry_run: :boolean]
      )

    with :ok <- reject_parser_remainders([], invalid),
         :ok <-
           reject_duplicate_options(args,
             pool: :string,
             owner_email: :string,
             dry_run: :boolean
           ),
         {:ok, path} <- required_positional(positional),
         {:ok, pool_slug} <- required_option(options, :pool, "--pool is required") do
      {:ok,
       %{
         path: path,
         pool_slug: pool_slug,
         owner_email: Keyword.get(options, :owner_email),
         dry_run?: Keyword.get(options, :dry_run, false)
       }}
    end
  end

  @spec require_dev_environment() :: :ok | {:error, String.t()}
  def require_dev_environment do
    if Mix.env() == :dev,
      do: :ok,
      else: {:error, "upstream account bundle tasks run only with MIX_ENV=dev"}
  end

  defp reject_parser_remainders([], []), do: :ok

  defp reject_parser_remainders(_positional, _invalid),
    do: {:error, "invalid bundle task arguments"}

  defp reject_duplicate_options(args, option_types) do
    if Enum.any?(option_types, fn {key, type} -> option_count(args, key, type) > 1 end),
      do: {:error, "duplicate or contradictory bundle task option"},
      else: :ok
  end

  defp option_count(args, key, type) do
    option = "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))
    negative = "--no-" <> String.trim_leading(option, "--")

    Enum.count(args, fn argument ->
      argument == option or String.starts_with?(argument, option <> "=") or
        (type == :boolean and
           (argument == negative or String.starts_with?(argument, negative <> "=")))
    end)
  end

  defp required_option(options, key, message) do
    case Keyword.get(options, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, message}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, message}
    end
  end

  defp required_positional([path]) when is_binary(path) and byte_size(path) > 0, do: {:ok, path}
  defp required_positional(_paths), do: {:error, "import requires exactly one bundle path"}
end
