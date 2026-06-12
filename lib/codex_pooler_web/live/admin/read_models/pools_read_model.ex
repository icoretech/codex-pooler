defmodule CodexPoolerWeb.Admin.PoolsReadModel do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Admin.Stats
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.PoolForm

  @type data_load_warning :: map()
  @type option :: {String.t(), Ecto.UUID.t() | String.t()}
  @type metrics :: %{
          required(:total_count) => non_neg_integer(),
          required(:upstream_count) => non_neg_integer(),
          required(:api_key_count) => non_neg_integer(),
          required(:request_count_5h) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil
        }
  @type token_usage :: %{
          required(:cached_input_tokens) => non_neg_integer(),
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:reasoning_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer()
        }
  @type pool_row :: %{
          required(:pool) => Pool.t(),
          required(:api_key_count) => non_neg_integer(),
          required(:upstream_count) => non_neg_integer(),
          required(:request_count_5h) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil,
          required(:token_usage_5h) => token_usage(),
          required(:token_usage_weekly) => token_usage(),
          required(:token_histogram_24h) => [map()],
          required(:request_histogram_24h) => [map()],
          required(:estimated_cost_micros_24h) => non_neg_integer(),
          required(:routing_strategy) => String.t()
        }
  @type page_state :: %{
          required(:pools) => [pool_row()],
          required(:pool_metrics) => metrics(),
          required(:can_manage_pools?) => boolean(),
          required(:upstream_identity_options) => [option()],
          required(:api_key_options) => [option()],
          required(:data_load_warnings) => [data_load_warning()]
        }

  @spec empty_metrics() :: metrics()
  def empty_metrics, do: pool_metrics([])

  @spec load(term(), map()) :: page_state()
  def load(scope, filters) do
    pool_rows = pool_rows(scope)
    visible_pool_rows = filter_pool_rows(pool_rows, filters)
    can_manage_pools? = Pools.can_manage_pools?(scope)

    {upstream_identity_options, upstream_warnings} =
      PoolForm.load_upstream_identity_options(scope, can_manage_pools?)

    {api_key_options, api_key_warnings} = PoolForm.load_api_key_options(scope, can_manage_pools?)

    %{
      pools: visible_pool_rows,
      pool_metrics: pool_metrics(pool_rows, scope),
      can_manage_pools?: can_manage_pools?,
      upstream_identity_options: upstream_identity_options,
      api_key_options: api_key_options,
      data_load_warnings: upstream_warnings ++ api_key_warnings
    }
  end

  @spec format_metric_integer(integer() | nil) :: String.t()
  def format_metric_integer(nil), do: "0"
  def format_metric_integer(value) when is_integer(value), do: Integer.to_string(value)

  @spec format_metric_rate(number() | nil) :: String.t()
  def format_metric_rate(nil), do: "0"

  def format_metric_rate(value) when is_number(value),
    do: value |> round() |> Integer.to_string()

  @spec format_request_throughput(non_neg_integer() | nil, number() | nil) :: String.t()
  def format_request_throughput(request_count, tokens_per_second) do
    "#{format_metric_integer(request_count)} / #{format_metric_rate(tokens_per_second)}"
  end

  @spec format_estimated_cost_micros(non_neg_integer() | nil) :: String.t()
  def format_estimated_cost_micros(nil), do: "$0.00"

  def format_estimated_cost_micros(micros) when is_integer(micros) do
    micros
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> fixed_decimal_places(2)
    |> then(&"$#{&1}")
  end

  defp pool_rows(scope) do
    pools =
      case Pools.list_pools_for_management(scope) do
        {:ok, pools} -> pools
        {:error, _reason} -> []
      end

    pool_ids = Enum.map(pools, & &1.id)
    api_key_counts = Access.count_api_keys_by_pool_ids(pool_ids)
    upstream_counts = CodexPooler.Upstreams.count_pool_assignments_by_pool_ids(pool_ids)
    routing_settings = Pools.routing_settings_by_pool_ids(pool_ids)
    usage_metrics = Stats.pool_usage_metrics_by_pool_ids(pool_ids)

    Enum.map(pools, fn pool ->
      usage = Map.fetch!(usage_metrics, pool.id)

      %{
        pool: pool,
        api_key_count: Map.get(api_key_counts, pool.id, 0),
        upstream_count: Map.get(upstream_counts, pool.id, 0),
        request_count_5h: usage.request_count_5h,
        tokens_per_second: usage.tokens_per_second,
        token_usage_5h: usage.token_usage_5h,
        token_usage_weekly: usage.token_usage_weekly,
        token_histogram_24h: usage.token_histogram_24h,
        request_histogram_24h: usage.request_histogram_24h,
        estimated_cost_micros_24h: usage.estimated_cost_micros_24h,
        routing_strategy: Map.get(routing_settings, pool.id).routing_strategy
      }
    end)
  end

  defp filter_pool_rows(pool_rows, filters) do
    query = filters |> Map.get("query", "") |> String.downcase()
    status = Map.get(filters, "status", "all")

    Enum.filter(pool_rows, fn pool_row ->
      pool_matches_query?(pool_row, query) && pool_matches_status?(pool_row, status)
    end)
  end

  defp pool_matches_query?(_pool_row, ""), do: true

  defp pool_matches_query?(pool_row, query) do
    pool_row.pool.name
    |> searchable_pool_text(pool_row)
    |> String.contains?(query)
  end

  defp searchable_pool_text(name, pool_row) do
    [
      name,
      pool_row.pool.slug,
      pool_row.pool.status,
      AdminBadges.routing_strategy_label(pool_row.routing_strategy)
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp pool_matches_status?(_pool_row, "all"), do: true
  defp pool_matches_status?(pool_row, status), do: pool_row.pool.status == status

  defp pool_metrics(pool_rows) do
    %{
      total_count: length(pool_rows),
      upstream_count: Enum.sum(Enum.map(pool_rows, & &1.upstream_count)),
      api_key_count: Enum.sum(Enum.map(pool_rows, & &1.api_key_count)),
      request_count_5h: 0,
      tokens_per_second: nil
    }
  end

  defp pool_metrics(pool_rows, scope) do
    pool_rows
    |> pool_metrics()
    |> Map.merge(pool_usage_metrics(scope))
  end

  defp pool_usage_metrics(scope) do
    case Stats.build_dashboard(scope, %{"window" => "5h"}) do
      {:ok, %{kpis: %{requests: requests, tokens_per_second: tokens_per_second}}} ->
        %{
          request_count_5h: Map.get(requests, :value, 0),
          tokens_per_second: Map.get(tokens_per_second, :value)
        }

      {:error, _reason} ->
        %{request_count_5h: 0, tokens_per_second: nil}
    end
  end

  defp fixed_decimal_places(value, places) do
    case String.split(value, ".", parts: 2) do
      [whole] -> whole <> "." <> String.duplicate("0", places)
      [whole, fraction] -> whole <> "." <> String.pad_trailing(fraction, places, "0")
    end
  end
end
