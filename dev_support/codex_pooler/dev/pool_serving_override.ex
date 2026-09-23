defmodule CodexPooler.Dev.PoolServingOverride do
  @moduledoc """
  Sets or clears one model's Full/Lite serving override on a named Pool.

  The write goes through the product path the operator Pools page uses:
  `Pools.model_serving_modes_snapshot/2` for the current revision, then
  `Pools.update_model_serving_modes/4` with the instance owner's scope, which
  records the operator audit event. `auto` clears the override so the catalog
  decides again. The result reports the previous mode, so the same task with
  `--mode <previous_mode>` reverses it.

  Runs against `codex_pooler_dev`, or an explicitly named local database with
  `target_database: NAME` (`CodexPooler.Dev.LocalTarget`).
  """

  alias CodexPooler.Dev.{LocalTarget, UpstreamAccountBundle}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingOverride, Pool}
  alias CodexPooler.Repo

  @database "codex_pooler_dev"
  @modes ["full", "lite", "auto"]

  @type options :: [
          pool_slug: String.t(),
          model: String.t(),
          mode: String.t(),
          target_database: String.t(),
          environment: atom(),
          allow_test_database: boolean(),
          repo_config: keyword()
        ]
  @type result :: %{
          required(:pool_slug) => String.t(),
          required(:model) => String.t(),
          required(:mode) => String.t(),
          required(:previous_mode) => String.t(),
          required(:changed) => boolean()
        }

  @spec modes() :: [String.t()]
  def modes, do: @modes

  @spec set(options()) :: {:ok, result()} | {:error, String.t()}
  def set(options) do
    with :ok <- validate_environment(options),
         {:ok, pool_slug} <- required(options, :pool_slug, "--pool is required"),
         {:ok, model} <- required(options, :model, "--model is required"),
         {:ok, mode} <- mode(options),
         {:ok, scope} <- UpstreamAccountBundle.resolve_owner_scope(nil),
         {:ok, pool} <- active_pool(pool_slug),
         {:ok, %{overrides: overrides, revision: revision}} <- Pools.model_serving_modes_snapshot(scope, pool),
         previous_mode = override_mode(overrides, model),
         {:ok, %{overrides: written, changed?: changed?}} <-
           Pools.update_model_serving_modes(scope, pool, [%{exposed_model_id: model, mode: mode}], revision),
         :ok <- verify_written(written, model, mode) do
      {:ok, %{pool_slug: pool.slug, model: model, mode: mode, previous_mode: previous_mode, changed: changed?}}
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @spec validate_environment(options()) :: :ok | {:error, String.t()}
  def validate_environment(options) do
    environment = Keyword.get(options, :environment, Mix.env())
    repo_config = Keyword.get(options, :repo_config, Repo.config())
    target_database = Keyword.get(options, :target_database)

    cond do
      environment == :dev and is_binary(target_database) -> LocalTarget.validate_target_database(target_database, repo_config)
      environment == :dev and Keyword.get(repo_config, :database) == @database -> :ok
      environment == :test and Keyword.get(options, :allow_test_database, false) -> :ok
      environment != :dev -> {:error, "pool serving override runs only with MIX_ENV=dev"}
      true -> {:error, "pool serving override requires database #{@database}"}
    end
  end

  defp required(options, key, message) do
    case Keyword.get(options, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, message}
    end
  end

  defp mode(options) do
    case Keyword.get(options, :mode) do
      mode when mode in @modes -> {:ok, mode}
      _other -> {:error, "--mode must be one of #{Enum.join(@modes, ", ")}"}
    end
  end

  defp active_pool(slug) do
    case Repo.get_by(Pool, slug: slug, status: "active") do
      %Pool{} = pool -> {:ok, pool}
      nil -> {:error, "active pool was not found"}
    end
  end

  defp override_mode(overrides, model) do
    case Enum.find(overrides, &(&1.exposed_model_id == model)) do
      %ModelServingOverride{mode: mode} -> mode
      nil -> "auto"
    end
  end

  defp verify_written(overrides, model, mode) do
    if override_mode(overrides, model) == mode,
      do: :ok,
      else: {:error, "serving override was not written as requested"}
  end
end
