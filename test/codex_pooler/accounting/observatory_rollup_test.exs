defmodule CodexPooler.Accounting.Usage.Observatory.RollupTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.Usage.Observatory.Rollup

  defp grid_row(bucket_index, model_label, attrs) do
    Map.merge(
      %{
        bucket_index: bucket_index,
        model_label: model_label,
        request_count: 0,
        succeeded: 0,
        failed: 0,
        in_progress: 0,
        settlement_count: 0,
        unknown_usage_count: 0,
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        total_tokens: 0,
        settled_cost_micros: 0,
        settled_cost_count: 0,
        estimated_cost_micros: 0,
        estimated_cost_count: 0,
        unavailable_cost_count: 0
      },
      attrs
    )
  end

  test "folds the grid into additive summary, buckets, models, and model_buckets" do
    grid = [
      grid_row(0, "alpha", %{request_count: 3, total_tokens: 100, settled_cost_micros: 900}),
      grid_row(0, "beta", %{request_count: 1, total_tokens: 50, estimated_cost_micros: 40}),
      grid_row(1, "alpha", %{request_count: 2, total_tokens: 30, settled_cost_micros: 100})
    ]

    %{summary: summary, buckets: buckets, models: models, model_buckets: model_buckets} =
      Rollup.fold(grid)

    # summary sums the whole grid
    assert summary.request_count == 6
    assert summary.total_tokens == 180
    assert summary.settled_cost_micros == 1_000
    assert summary.estimated_cost_micros == 40

    # buckets group by bucket_index, sorted
    assert Enum.map(buckets, & &1.bucket_index) == [0, 1]
    assert Enum.map(buckets, & &1.request_count) == [4, 2]
    assert Enum.map(buckets, & &1.total_tokens) == [150, 30]

    # models group by label, desc tokens then desc requests then asc label
    assert Enum.map(models, & &1.label) == ["alpha", "beta"]
    assert hd(models).request_count == 5
    assert hd(models).total_tokens == 130
    assert hd(models).settled_cost_micros == 1_000

    # model_buckets keep the (bucket, model) grain, sorted
    assert model_buckets == [
             %{bucket_index: 0, model_label: "alpha", total_tokens: 100},
             %{bucket_index: 0, model_label: "beta", total_tokens: 50},
             %{bucket_index: 1, model_label: "alpha", total_tokens: 30}
           ]
  end

  test "models keeps only the top twelve by tokens, then requests, then label" do
    grid =
      for n <- 1..15 do
        grid_row(0, "model-#{String.pad_leading(Integer.to_string(n), 2, "0")}", %{
          request_count: 1,
          total_tokens: n
        })
      end

    %{models: models} = Rollup.fold(grid)

    assert length(models) == 12
    # highest token counts first (15, 14, ... 4)
    assert Enum.map(models, & &1.total_tokens) == Enum.to_list(15..4//-1)
  end

  test "coerces Decimal and nil grid metrics to integers" do
    grid = [
      grid_row(0, "alpha", %{
        request_count: Decimal.new(2),
        total_tokens: Decimal.new("41.6"),
        settled_cost_micros: nil
      })
    ]

    %{summary: summary} = Rollup.fold(grid)

    assert summary.request_count == 2
    # Decimal.round(0) is half-up
    assert summary.total_tokens == 42
    assert summary.settled_cost_micros == 0
  end

  test "an empty grid folds to zeroed summary and empty collections" do
    %{summary: summary, buckets: buckets, models: models, model_buckets: model_buckets} =
      Rollup.fold([])

    assert summary.request_count == 0
    assert summary.total_tokens == 0
    assert buckets == []
    assert models == []
    assert model_buckets == []
  end
end
