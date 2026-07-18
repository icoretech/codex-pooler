defmodule CodexPooler.Accounting.ObservatoryPresentationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.Usage.Observatory.Presentation

  test "keeps ratio trends bucket-based across window halves" do
    projection = Presentation.build(window(), %{}, buckets(), [], [])

    assert projection.trends == %{
             success_rate: %{current: 25.0, previous: 100.0, delta: -75.0},
             cache_rate: %{current: 50.0, previous: 20.0, delta: 30.0}
           }
  end

  test "keeps ratio trend deltas nil and finite when a half-window has no traffic" do
    projection = Presentation.build(window(), %{}, [bucket(2, 1, 1, 10, 0, 10)], [], [])

    assert projection.trends.success_rate.delta == nil
    assert projection.trends.cache_rate.delta == nil
    refute inspect(projection) =~ ~r/(NaN|Infinity)/
  end

  defp window do
    %{
      key: "1h",
      started_at: ~U[2026-07-17 11:00:00Z],
      ended_at: ~U[2026-07-17 11:04:00Z],
      bucket_seconds: 60,
      bucket_count: 4
    }
  end

  defp buckets do
    [
      bucket(0, 4, 4, 100, 20, 100),
      bucket(1, 0, 0, 0, 0, 0),
      bucket(2, 2, 1, 40, 20, 40),
      bucket(3, 2, 0, 40, 20, 40)
    ]
  end

  defp bucket(index, requests, succeeded, input, cached, total) do
    %{
      bucket_index: index,
      request_count: requests,
      succeeded: succeeded,
      input_tokens: input,
      cached_input_tokens: cached,
      total_tokens: total
    }
  end
end
