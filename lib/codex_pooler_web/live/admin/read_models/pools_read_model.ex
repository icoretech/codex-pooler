defmodule CodexPoolerWeb.Admin.PoolsReadModel do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Admin.Stats
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.PoolForm

  @type data_load_warning :: map()
  @type option :: {String.t(), Ecto.UUID.t() | String.t()}
  @type metrics :: %{
          required(:total_count) => non_neg_integer(),
          required(:upstream_count) => non_neg_integer(),
          required(:api_key_count) => non_neg_integer(),
          required(:request_count) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil,
          required(:traffic_window_label) => String.t()
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
          required(:request_count) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil,
          required(:total_tokens) => non_neg_integer(),
          required(:latency_ms) => non_neg_integer(),
          required(:token_usage) => token_usage(),
          required(:token_usage_weekly) => token_usage(),
          required(:token_histogram) => [map()],
          required(:request_histogram) => [map()],
          required(:estimated_cost_micros) => non_neg_integer(),
          required(:traffic_window) => String.t(),
          required(:traffic_window_label) => String.t(),
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
    traffic_window = PoolForm.normalize_traffic_window(Map.get(filters, "traffic_window", "24h"))
    pool_rows = pool_rows(scope, traffic_window)
    visible_pool_rows = filter_pool_rows(pool_rows, filters)
    can_manage_pools? = Pools.can_manage_pools?(scope)

    {upstream_identity_options, upstream_warnings} =
      PoolForm.load_upstream_identity_options(scope, can_manage_pools?)

    {api_key_options, api_key_warnings} = PoolForm.load_api_key_options(scope, can_manage_pools?)

    %{
      pools: visible_pool_rows,
      pool_metrics: pool_metrics(pool_rows, traffic_window),
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
  def format_estimated_cost_micros(nil), do: Format.money_from_micros(0)

  def format_estimated_cost_micros(micros) when is_integer(micros) do
    Format.money_from_micros(micros)
  end

  defp pool_rows(scope, traffic_window) do
    pools =
      case Pools.list_pools_for_management(scope) do
        {:ok, pools} -> pools
        {:error, _reason} -> []
      end

    pool_ids = Enum.map(pools, & &1.id)
    api_key_counts = Access.count_api_keys_by_pool_ids(pool_ids)
    upstream_counts = CodexPooler.Upstreams.count_pool_assignments_by_pool_ids(pool_ids)
    routing_settings = Pools.routing_settings_by_pool_ids(pool_ids)
    usage_metrics = Stats.pool_usage_metrics_by_pool_ids(pool_ids, traffic_window: traffic_window)
    traffic_window_label = PoolForm.traffic_window_short_label(traffic_window)

    Enum.map(pools, fn pool ->
      usage = Map.fetch!(usage_metrics, pool.id)

      %{
        pool: pool,
        api_key_count: Map.get(api_key_counts, pool.id, 0),
        upstream_count: Map.get(upstream_counts, pool.id, 0),
        request_count: usage.request_count,
        tokens_per_second: usage.tokens_per_second,
        total_tokens: usage.total_tokens,
        latency_ms: usage.latency_ms,
        token_usage: usage.token_usage,
        token_usage_weekly: usage.token_usage_weekly,
        token_histogram: usage.token_histogram,
        request_histogram: usage.request_histogram,
        estimated_cost_micros: usage.estimated_cost_micros,
        traffic_window: traffic_window,
        traffic_window_label: traffic_window_label,
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
    total_tokens = Enum.sum(Enum.map(pool_rows, & &1.total_tokens))
    latency_ms = Enum.sum(Enum.map(pool_rows, & &1.latency_ms))

    %{
      total_count: length(pool_rows),
      upstream_count: Enum.sum(Enum.map(pool_rows, & &1.upstream_count)),
      api_key_count: Enum.sum(Enum.map(pool_rows, & &1.api_key_count)),
      request_count: Enum.sum(Enum.map(pool_rows, & &1.request_count)),
      tokens_per_second: pool_tokens_per_second(total_tokens, latency_ms),
      traffic_window_label: "24h"
    }
  end

  defp pool_metrics(pool_rows, traffic_window) do
    Map.put(
      pool_metrics(pool_rows),
      :traffic_window_label,
      PoolForm.traffic_window_short_label(traffic_window)
    )
  end

  defp pool_tokens_per_second(total_tokens, latency_ms) when total_tokens > 0 and latency_ms > 0,
    do: Float.round(total_tokens / (latency_ms / 1000), 2)

  defp pool_tokens_per_second(_total_tokens, _latency_ms), do: nil
end
