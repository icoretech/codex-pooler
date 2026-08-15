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
    :histogram_state,
    :settled_cost_micros
  ]

  test "merge_traffic/4 touches only traffic fields, ignores vanished pools, and sums the strip over every scoped pool" do
    visible_id = Ecto.UUID.generate()
    untouched_id = Ecto.UUID.generate()
    hidden_id = Ecto.UUID.generate()
    vanished_id = Ecto.UUID.generate()

    visible_row = structural_row(visible_id, "Visible")
    untouched_row = structural_row(untouched_id, "Untouched")

    summary_by_pool_id = %{
      visible_id => summary(request_count: 3, total_tokens: 300, latency_ms: 3_000, settled: 42),
      hidden_id => summary(request_count: 2, total_tokens: 100, latency_ms: 1_000, settled: 7),
      vanished_id => summary(request_count: 100, total_tokens: 9_999, latency_ms: 1, settled: 1)
    }

    histogram_by_pool_id = %{
      visible_id => histogram(request_count: 3, total_tokens: 300)
    }

    metrics = PoolsReadModel.empty_metrics()

    {merged_rows, merged_metrics} =
      PoolsReadModel.merge_traffic(
        [visible_row, untouched_row],
        metrics,
        %{
          summary_by_pool_id: summary_by_pool_id,
          histogram_by_pool_id: histogram_by_pool_id
        },
        [visible_id, untouched_id, hidden_id]
      )

    [merged_visible, merged_untouched] = merged_rows

    assert merged_visible.request_count == 3
    assert merged_visible.total_tokens == 300
    assert merged_visible.settled_cost_micros == 42
    assert merged_visible.histogram_state == :ready
    assert Map.drop(merged_visible, @traffic_fields) == Map.drop(visible_row, @traffic_fields)
    assert merged_untouched == untouched_row

    # Strip totals cover scope-visible pools even when filters hide their rows,
    # and drop pools that vanished between task start and completion.
    assert merged_metrics.request_count == 5
    assert merged_metrics.tokens_per_second == 100.0

    assert Map.drop(merged_metrics, [:request_count, :tokens_per_second]) ==
             Map.drop(metrics, [:request_count, :tokens_per_second])
  end

  @tag :selective_pool_histograms
  test "merge_traffic/4 distinguishes unobserved histograms from loaded zero traffic" do
    # Given
    eligible_id = Ecto.UUID.generate()
    inactive_id = Ecto.UUID.generate()
    hidden_id = Ecto.UUID.generate()
    eligible_row = structural_row(eligible_id, "Eligible")
    inactive_row = structural_row(inactive_id, "Inactive")

    traffic = %{
      summary_by_pool_id: %{
        eligible_id => summary(request_count: 0, total_tokens: 0, latency_ms: 0, settled: 0),
        inactive_id => summary(request_count: 2, total_tokens: 20, latency_ms: 200, settled: 2),
        hidden_id => summary(request_count: 3, total_tokens: 30, latency_ms: 300, settled: 3)
      },
      histogram_by_pool_id: %{
        eligible_id => %{token_histogram: [], request_histogram: []}
      }
    }

    # When
    {[merged_eligible, merged_inactive], merged_metrics} =
      PoolsReadModel.merge_traffic(
        [eligible_row, inactive_row],
        PoolsReadModel.empty_metrics(),
        traffic,
        [eligible_id, inactive_id, hidden_id]
      )

    # Then
    assert merged_eligible.histogram_state == :ready
    assert merged_eligible.token_histogram == []
    assert merged_eligible.request_histogram == []
    assert merged_inactive.histogram_state == :unobserved
    assert merged_inactive.token_histogram == []
    assert merged_inactive.request_histogram == []
    assert merged_metrics.request_count == 5
    assert merged_metrics.tokens_per_second == 100.0
  end

  test "reconcile_histogram_states/3 keeps eligible data and prunes inactive payloads" do
    eligible_id = Ecto.UUID.generate()
    inactive_id = Ecto.UUID.generate()

    ready_row =
      eligible_id
      |> structural_row("Eligible")
      |> Map.merge(%{
        histogram_state: :ready,
        token_histogram: [%{bucket: "now", value: 10}],
        request_histogram: [%{bucket: "now", value: 1}]
      })

    inactive_row =
      inactive_id
      |> structural_row("Inactive")
      |> Map.merge(%{
        histogram_state: :ready,
        token_histogram: [%{bucket: "now", value: 20}],
        request_histogram: [%{bucket: "now", value: 2}]
      })

    [eligible, inactive] =
      PoolsReadModel.reconcile_histogram_states(
        [ready_row, inactive_row],
        MapSet.new([eligible_id]),
        :loading
      )

    assert eligible == ready_row
    assert inactive.histogram_state == :unobserved
    assert inactive.token_histogram == []
    assert inactive.request_histogram == []
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
      histogram_state: :unobserved,
      settled_cost_micros: 0,
      traffic_window: "24h",
      traffic_window_label: "24h",
      routing_strategy: "bridge_ring",
      compat_flags: %{
        v1_compatibility_enabled: true,
        request_compression_enabled: false,
        allow_image_generation: true
      }
    }
  end

  defp summary(opts) do
    %{
      request_count: opts[:request_count],
      tokens_per_second: 100.0,
      total_tokens: opts[:total_tokens],
      latency_ms: opts[:latency_ms],
      token_usage: empty_token_usage(),
      settled_cost_micros: opts[:settled]
    }
  end

  defp histogram(opts) do
    %{
      token_histogram: [%{bucket: "00", total_tokens: opts[:total_tokens]}],
      request_histogram: [%{bucket: "00", requests: opts[:request_count]}]
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
