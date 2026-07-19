defmodule CodexPoolerWeb.Admin.PoolsReadModel do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Admin.Stats
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.PoolForm

  @empty_token_usage %{
    cached_input_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    total_tokens: 0
  }

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
  @type compat_flags :: %{
          required(:v1_compatibility_enabled) => boolean(),
          required(:request_compression_enabled) => boolean(),
          required(:allow_image_generation) => boolean()
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
          required(:token_histogram) => [map()],
          required(:request_histogram) => [map()],
          required(:settled_cost_micros) => non_neg_integer(),
          required(:traffic_window) => String.t(),
          required(:traffic_window_label) => String.t(),
          required(:routing_strategy) => String.t(),
          required(:compat_flags) => compat_flags()
        }
  @type usage_by_pool_id :: %{optional(Ecto.UUID.t()) => Stats.pool_usage_metrics()}
  @type traffic_result :: %{
          required(:traffic_window) => String.t(),
          required(:usage_by_pool_id) => usage_by_pool_id()
        }
  @type page_state :: %{
          required(:pools) => [pool_row()],
          required(:pool_metrics) => metrics(),
          required(:traffic_pool_ids) => [Ecto.UUID.t()],
          required(:can_manage_pools?) => boolean(),
          required(:upstream_identity_options) => [option()],
          required(:api_key_options) => [option()],
          required(:data_load_warnings) => [data_load_warning()]
        }

  @spec empty_metrics() :: metrics()
  def empty_metrics, do: pool_metrics([])

  @spec load_structural(term(), map()) :: page_state()
  def load_structural(scope, filters) do
    traffic_window = PoolForm.normalize_traffic_window(Map.get(filters, "traffic_window", "24h"))
    pool_rows = structural_pool_rows(scope, traffic_window)
    visible_pool_rows = filter_pool_rows(pool_rows, filters)
    can_manage_pools? = Pools.can_manage_pools?(scope)

    {upstream_identity_options, upstream_warnings} =
      PoolForm.load_upstream_identity_options(scope, can_manage_pools?)

    {api_key_options, api_key_warnings} = PoolForm.load_api_key_options(scope, can_manage_pools?)

    %{
      pools: visible_pool_rows,
      pool_metrics: pool_metrics(pool_rows, traffic_window),
      traffic_pool_ids: Enum.map(pool_rows, & &1.pool.id),
      can_manage_pools?: can_manage_pools?,
      upstream_identity_options: upstream_identity_options,
      api_key_options: api_key_options,
      data_load_warnings: upstream_warnings ++ api_key_warnings
    }
  end

  # The expensive multi-aggregate read. Callers must run this off the LiveView
  # process (start_async) so pending clicks never queue behind it.
  @spec traffic_metrics([Ecto.UUID.t()], String.t()) :: traffic_result()
  def traffic_metrics(pool_ids, traffic_window) do
    traffic_window = PoolForm.normalize_traffic_window(traffic_window)

    %{
      traffic_window: traffic_window,
      usage_by_pool_id:
        Stats.pool_usage_metrics_by_pool_ids(pool_ids, traffic_window: traffic_window)
    }
  end

  # Merges by pool id and touches only traffic fields, so pools that vanished
  # mid-flight are ignored and dialog/form assigns are never rebuilt.
  @spec merge_traffic([pool_row()], metrics(), usage_by_pool_id(), [Ecto.UUID.t()]) ::
          {[pool_row()], metrics()}
  def merge_traffic(pool_rows, pool_metrics, usage_by_pool_id, traffic_pool_ids) do
    merged_rows =
      Enum.map(pool_rows, fn pool_row ->
        case Map.fetch(usage_by_pool_id, pool_row.pool.id) do
          {:ok, usage} -> put_row_usage(pool_row, usage)
          :error -> pool_row
        end
      end)

    usages =
      traffic_pool_ids
      |> Enum.map(&Map.get(usage_by_pool_id, &1))
      |> Enum.reject(&is_nil/1)

    total_tokens = usages |> Enum.map(& &1.total_tokens) |> Enum.sum()
    latency_ms = usages |> Enum.map(& &1.latency_ms) |> Enum.sum()

    merged_metrics = %{
      pool_metrics
      | request_count: usages |> Enum.map(& &1.request_count) |> Enum.sum(),
        tokens_per_second: pool_tokens_per_second(total_tokens, latency_ms)
    }

    {merged_rows, merged_metrics}
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

  @spec format_settled_cost_micros(non_neg_integer() | nil) :: String.t()
  def format_settled_cost_micros(nil), do: Format.money_precise_from_micros(0)

  def format_settled_cost_micros(micros) when is_integer(micros) do
    Format.money_precise_from_micros(micros)
  end

  defp structural_pool_rows(scope, traffic_window) do
    pools =
      case Pools.list_pools_for_management(scope) do
        {:ok, pools} -> pools
        {:error, _reason} -> []
      end

    pool_ids = Enum.map(pools, & &1.id)
    api_key_counts = Access.count_api_keys_by_pool_ids(pool_ids)
    upstream_counts = UpstreamAssignments.count_pool_assignments_by_pool_ids(pool_ids)
    routing_settings = PoolRouting.routing_settings_by_pool_ids(pool_ids)
    traffic_window_label = PoolForm.traffic_window_short_label(traffic_window)

    Enum.map(pools, fn pool ->
      settings = Map.get(routing_settings, pool.id)

      %{
        pool: pool,
        api_key_count: Map.get(api_key_counts, pool.id, 0),
        upstream_count: Map.get(upstream_counts, pool.id, 0),
        request_count: 0,
        tokens_per_second: nil,
        total_tokens: 0,
        latency_ms: 0,
        token_usage: @empty_token_usage,
        token_histogram: [],
        request_histogram: [],
        settled_cost_micros: 0,
        traffic_window: traffic_window,
        traffic_window_label: traffic_window_label,
        routing_strategy: settings.routing_strategy,
        compat_flags: %{
          v1_compatibility_enabled: settings.v1_compatibility_enabled,
          request_compression_enabled: settings.request_compression_enabled,
          allow_image_generation: settings.allow_image_generation
        }
      }
    end)
  end

  defp put_row_usage(pool_row, usage) do
    %{
      pool_row
      | request_count: usage.request_count,
        tokens_per_second: usage.tokens_per_second,
        total_tokens: usage.total_tokens,
        latency_ms: usage.latency_ms,
        token_usage: usage.token_usage,
        token_histogram: usage.token_histogram,
        request_histogram: usage.request_histogram,
        settled_cost_micros: usage.settled_cost_micros
    }
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
