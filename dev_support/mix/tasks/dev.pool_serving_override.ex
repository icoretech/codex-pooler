defmodule Mix.Tasks.Dev.PoolServingOverride do
  @moduledoc """
  Sets or clears one model's Full/Lite serving override on a named Pool.

      MIX_ENV=dev mix dev.pool_serving_override --pool dev-perf-pool --model gpt-6-sol --mode full
      MIX_ENV=dev mix dev.pool_serving_override --pool dev-perf-pool --model gpt-6-sol --mode auto
      MIX_ENV=dev mix dev.pool_serving_override --pool dev-perf-pool --model gpt-6-sol --mode lite --target-database codex_pooler_replica

  The write goes through `Pools.update_model_serving_modes/4` with the instance
  owner's scope (audited like the operator Pools page). `auto` clears the
  override. The printed `previous_mode` reverses the change when passed back
  as `--mode`. `--target-database NAME` targets an explicitly named local
  database reached over loopback instead of `codex_pooler_dev`.
  """

  use Mix.Task

  alias CodexPooler.Dev.{PoolServingOverride, QaBackgroundWorkers}

  @requirements ["app.config"]
  @shortdoc "Set a Full/Lite/auto serving override for a model on a named Pool"

  @switches [pool: :string, model: :string, mode: :string, target_database: :string]

  @impl Mix.Task
  def run(args) do
    with {:ok, options} <- parse_args(args),
         :ok <- PoolServingOverride.validate_environment(options) do
      QaBackgroundWorkers.start_application!()

      case PoolServingOverride.set(options) do
        {:ok, result} -> Mix.shell().info(CodexPooler.JSON.encode!(result))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {options, [], []} ->
        if duplicate_option?(args),
          do: {:error, "duplicate pool serving override option"},
          else: {:ok, rename_pool(options)}

      _invalid ->
        {:error, "use --pool SLUG --model MODEL --mode #{Enum.join(PoolServingOverride.modes(), "|")} [--target-database NAME]"}
    end
  end

  defp rename_pool(options) do
    case Keyword.pop(options, :pool) do
      {nil, options} -> options
      {slug, options} -> Keyword.put(options, :pool_slug, slug)
    end
  end

  defp duplicate_option?(args) do
    Enum.any?(Keyword.keys(@switches), fn key ->
      flag = "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))
      Enum.count(args, &(&1 == flag or String.starts_with?(&1, flag <> "="))) > 1
    end)
  end
end
