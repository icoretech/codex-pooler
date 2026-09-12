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

  The routing strategy is leased like `--request-compression` is in
  `mix dev.openai_v1_fixture`: the exact prior `pool_routing_settings` row,
  `updated_at` included, is restored by the final release.
  """

  use Mix.Task

  alias CodexPooler.Dev.RoutingStrategyFixture

  @requirements ["app.config"]
  @shortdoc "Manage the reversible local routing strategy fixture"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- parse_args(args),
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
             allow_isolated_dev_database: :boolean
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
      "[--assignments N], release, or status"
  end

  defp normalize_acquire_options(options) do
    options
    |> Keyword.take([
      :upstream_base_url,
      :routing_strategy,
      :assignments,
      :allow_isolated_dev_database
    ])
    |> maybe_allow_isolated_dev_database()
  end

  defp normalize_release_options(options) do
    options
    |> Keyword.take([:allow_isolated_dev_database])
    |> maybe_allow_isolated_dev_database()
  end

  defp maybe_allow_isolated_dev_database(options) do
    if Keyword.get(options, :allow_isolated_dev_database, false) do
      Keyword.put(options, :allow_isolated_dev_database, true)
    else
      Keyword.delete(options, :allow_isolated_dev_database)
    end
  end

  defp maybe_start_application(:status), do: :ok

  defp maybe_start_application(_action) do
    Mix.Task.run("app.start")
    :ok
  end

  defp run_action(:acquire, options), do: RoutingStrategyFixture.acquire(options)
  defp run_action(:release, options), do: RoutingStrategyFixture.release(options)
  defp run_action(:status, options), do: RoutingStrategyFixture.status(options)
end
