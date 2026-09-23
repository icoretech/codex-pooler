defmodule Mix.Tasks.Dev.RoutingStrategyFixture do
  @moduledoc """
  Acquires, releases, or inspects the reversible local routing strategy fixture.

  The fixture provisions one synthetic Pool whose shape makes a routing strategy
  observable: four or more active assignments (ring size stays at the product
  default of 3, so the ring truncates) whose succeeded-attempt times and quota
  remaining percents are deliberately differentiated. Without that
  differentiation `least_recent_success` and `quota_first` both score every
  assignment 0 and degenerate into the default rendezvous ordering.

      MIX_ENV=dev mix dev.routing_strategy_fixture acquire --routing-strategy quota_first
      MIX_ENV=dev mix dev.routing_strategy_fixture acquire --routing-strategy least_recent_success --assignments 5
      MIX_ENV=dev mix dev.routing_strategy_fixture status
      MIX_ENV=dev mix dev.routing_strategy_fixture release
      MIX_ENV=dev mix dev.routing_strategy_fixture acquire --target-database codex_pooler_replica --upstream-base-url http://fake-upstream:4058

  `--target-database NAME` targets an explicitly named local database reached
  over loopback (a kind port-forward is fine) instead of `codex_pooler_dev`.

  The routing strategy is leased like `--request-compression` is in
  `mix dev.openai_v1_fixture`: the exact prior `pool_routing_settings` row,
  `updated_at` included, is restored by the final release.
  """

  use Mix.Task

  alias CodexPooler.Dev.QaBackgroundWorkers
  alias CodexPooler.Dev.RoutingStrategyFixture

  @private_receipt_env "CODEX_POOLER_ROUTING_STRATEGY_FIXTURE_RECEIPT_PATH"
  @private_receipt_relative ~r/^tmp\/routing-strategy-fixture\/build-[^\/]+\/fixture\/setup\.json$/

  @requirements ["app.config"]
  @shortdoc "Manage the reversible local routing strategy fixture"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- parse_args(args),
         {:ok, options} <- fixture_options(options),
         :ok <- maybe_start_application(action),
         result <- run_action(action, options) do
      case result do
        {:ok, status} -> Mix.shell().info(CodexPooler.JSON.encode!(status))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [
             upstream_base_url: :string,
             routing_strategy: :string,
             assignments: :integer,
             allow_isolated_dev_database: :boolean,
             target_database: :string
           ],
           aliases: []
         ) do
      {options, ["acquire"], []} ->
        {:ok, :acquire, normalize_acquire_options(options)}

      {options, ["release"], []} ->
        {:ok, :release, normalize_release_options(options)}

      {options, ["status"], []} ->
        {:ok, :status, normalize_release_options(options)}

      _invalid ->
        {:error, usage()}
    end
  end

  defp usage do
    "use acquire [--upstream-base-url URL] [--routing-strategy #{Enum.join(RoutingStrategyFixture.routing_strategies(), "|")}] " <>
      "[--assignments N] [--target-database NAME], release [--target-database NAME], or status [--target-database NAME]"
  end

  defp normalize_acquire_options(options) do
    options
    |> Keyword.take([
      :upstream_base_url,
      :routing_strategy,
      :assignments,
      :allow_isolated_dev_database,
      :target_database
    ])
    |> maybe_allow_isolated_dev_database()
  end

  defp normalize_release_options(options) do
    options
    |> Keyword.take([:allow_isolated_dev_database, :target_database])
    |> maybe_allow_isolated_dev_database()
  end

  defp maybe_allow_isolated_dev_database(options) do
    if Keyword.get(options, :allow_isolated_dev_database, false) do
      Keyword.put(options, :allow_isolated_dev_database, true)
    else
      Keyword.delete(options, :allow_isolated_dev_database)
    end
  end

  defp fixture_options(options) do
    case private_receipt_path() do
      {:ok, nil} -> {:ok, options}
      {:ok, path} -> {:ok, Keyword.put(options, :receipt_path, path)}
      {:error, message} -> {:error, message}
    end
  end

  defp private_receipt_path do
    case System.get_env(@private_receipt_env) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        path = Path.expand(value, File.cwd!())

        with relative <- Path.relative_to(path, File.cwd!()),
             true <- Regex.match?(@private_receipt_relative, relative),
             :ok <- validate_private_receipt_path(path) do
          {:ok, path}
        else
          _invalid -> {:error, "routing strategy fixture private receipt path is invalid"}
        end
    end
  end

  defp validate_private_receipt_path(path) do
    root = Path.expand(Path.join(["tmp", "routing-strategy-fixture"]), File.cwd!())
    parent = Path.dirname(path)

    with :ok <- validate_directory_chain(File.cwd!(), parent),
         :ok <- validate_receipt_target(path),
         relative when is_binary(relative) <- Path.relative_to(parent, root),
         false <- relative == ".." or String.starts_with?(relative, "../") do
      :ok
    else
      _invalid -> {:error, :invalid_private_receipt_path}
    end
  end

  defp validate_directory_chain(base, target) do
    relative = Path.relative_to(target, base)

    if relative == ".." or String.starts_with?(relative, "../") do
      {:error, :invalid_private_receipt_path}
    else
      relative
      |> Path.split()
      |> Enum.scan(base, &Path.join(&2, &1))
      |> Enum.reduce_while(:ok, &validate_directory_component/2)
    end
  end

  defp validate_directory_component(component, :ok) do
    case File.lstat(component) do
      {:ok, %File.Stat{type: :directory}} -> {:cont, :ok}
      _invalid -> {:halt, {:error, :invalid_private_receipt_path}}
    end
  end

  defp validate_receipt_target(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _invalid -> {:error, :invalid_private_receipt_path}
    end
  end

  defp maybe_start_application(:status), do: :ok

  defp maybe_start_application(_action), do: QaBackgroundWorkers.start_application!()

  defp run_action(:acquire, options), do: RoutingStrategyFixture.acquire(options)
  defp run_action(:release, options), do: RoutingStrategyFixture.release(options)
  defp run_action(:status, options), do: RoutingStrategyFixture.status(options)
end
