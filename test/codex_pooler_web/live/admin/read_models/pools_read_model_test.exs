defmodule CodexPoolerWeb.Admin.PoolsReadModelTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Pools.Pool
  alias CodexPoolerWeb.Admin.PoolsReadModel

  @traffic_fields [
    :request_count,
    :tokens_per_second,
    :total_tokens,
    :latency_ms,
    :token_usage,
    :token_histogram,
    :request_histogram,
    :settled_cost_micros
  ]

  test "merge_traffic/4 touches only traffic fields, ignores vanished pools, and sums the strip over every scoped pool" do
    visible_id = Ecto.UUID.generate()
    untouched_id = Ecto.UUID.generate()
    hidden_id = Ecto.UUID.generate()
    vanished_id = Ecto.UUID.generate()

    visible_row = structural_row(visible_id, "Visible")
    untouched_row = structural_row(untouched_id, "Untouched")

    usage_by_pool_id = %{
      visible_id => usage(request_count: 3, total_tokens: 300, latency_ms: 3_000, settled: 42),
      hidden_id => usage(request_count: 2, total_tokens: 100, latency_ms: 1_000, settled: 7),
      vanished_id => usage(request_count: 100, total_tokens: 9_999, latency_ms: 1, settled: 1)
    }

    metrics = PoolsReadModel.empty_metrics()

    {merged_rows, merged_metrics} =
      PoolsReadModel.merge_traffic(
        [visible_row, untouched_row],
        metrics,
        usage_by_pool_id,
        [visible_id, untouched_id, hidden_id]
      )

    [merged_visible, merged_untouched] = merged_rows

    assert merged_visible.request_count == 3
    assert merged_visible.total_tokens == 300
    assert merged_visible.settled_cost_micros == 42
    assert Map.drop(merged_visible, @traffic_fields) == Map.drop(visible_row, @traffic_fields)
    assert merged_untouched == untouched_row

    # Strip totals cover scope-visible pools even when filters hide their rows,
    # and drop pools that vanished between task start and completion.
    assert merged_metrics.request_count == 5
    assert merged_metrics.tokens_per_second == 100.0

    assert Map.drop(merged_metrics, [:request_count, :tokens_per_second]) ==
             Map.drop(metrics, [:request_count, :tokens_per_second])
  end

  defp structural_row(pool_id, name) do
    %{
      pool: %Pool{id: pool_id, name: name, slug: String.downcase(name), status: "active"},
      api_key_count: 4,
      upstream_count: 2,
      request_count: 0,
      tokens_per_second: nil,
      total_tokens: 0,
      latency_ms: 0,
      token_usage: empty_token_usage(),
      token_histogram: [],
      request_histogram: [],
      settled_cost_micros: 0,
      traffic_window: "24h",
      traffic_window_label: "24h",
      routing_strategy: "bridge_ring",
      compat_flags: %{
        v1_compatibility_enabled: true,
        request_compression_enabled: false,
        upstream_websocket_bridge_enabled: false
      }
    }
  end

  defp usage(opts) do
    %{
      request_count: opts[:request_count],
      tokens_per_second: 100.0,
      total_tokens: opts[:total_tokens],
      latency_ms: opts[:latency_ms],
      token_usage: empty_token_usage(),
      token_histogram: [%{bucket: "00", total_tokens: opts[:total_tokens]}],
      request_histogram: [%{bucket: "00", requests: opts[:request_count]}],
      settled_cost_micros: opts[:settled]
    }
  end

  defp empty_token_usage do
    %{
      cached_input_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0
    }
  end
end
