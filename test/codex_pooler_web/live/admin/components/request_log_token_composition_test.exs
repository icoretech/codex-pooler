defmodule CodexPoolerWeb.Admin.RequestLogTokenCompositionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Usage

  test "segments partition the recorded total and reasoning stays within output" do
    document = render_tokens(%{input_tokens: 80, cached_input_tokens: 40, output_tokens: 20, reasoning_tokens: 15, total_tokens: 100})

    assert_segment(document, "cached-token-bar", 40)
    assert_segment(document, "uncached-token-bar", 40)
    assert_segment(document, "output-token-bar", 20)
    assert text(document, "[data-role='token-totals']") == "100"
    assert text(document, "[data-role='cache-rate']") =~ "50% of input"

    assert LazyHTML.query(document, "[data-role='token-bar'][role='img']") |> LazyHTML.attribute("aria-label") ==
             ["100 total tokens — Cached input: 40; Uncached input: 40; Output: 20. Output includes reasoning tokens."]
  end

  test "zero cache is measured, and fully cached input still leaves output separate" do
    uncached = render_tokens(%{input_tokens: 80, cached_input_tokens: 0, output_tokens: 20, total_tokens: 100})
    assert_segment(uncached, "cached-token-bar", 0)
    assert_segment(uncached, "uncached-token-bar", 80)
    assert text(uncached, "[data-role='cache-rate']") =~ "0% of input"

    cached = render_tokens(%{input_tokens: 80, cached_input_tokens: 80, output_tokens: 20, total_tokens: 100})
    assert_segment(cached, "cached-token-bar", 80)
    assert_segment(cached, "uncached-token-bar", 0)
    assert_segment(cached, "output-token-bar", 20)
    assert text(cached, "[data-role='cache-rate']") =~ "100% of input"
  end

  test "zero input gives an output-only bar without inventing a cache rate" do
    document = render_tokens(%{input_tokens: 0, cached_input_tokens: 0, output_tokens: 20, total_tokens: 20})
    assert_segment(document, "output-token-bar", 20)
    assert text(document, "[data-role='cached-tokens']") == "0 cached"
    assert Enum.empty?(LazyHTML.query(document, "[data-role='cache-rate']"))
  end

  test "unknown and contradictory counts retain recorded totals without a fabricated composition" do
    for overrides <- [
          %{cached_input_tokens: nil},
          %{input_tokens: nil},
          %{output_tokens: nil},
          %{cached_input_tokens: 81},
          %{cached_input_tokens: -1},
          %{output_tokens: 25},
          %{input_tokens: -1}
        ] do
      document = render_tokens(Map.merge(%{input_tokens: 80, cached_input_tokens: 40, output_tokens: 20, total_tokens: 100}, overrides))
      assert Enum.empty?(LazyHTML.query(document, "[data-role='token-bar']"))
      assert text(document, "[data-role='token-breakdown-unavailable']") == "breakdown n/a"
      assert text(document, "[data-role='token-totals']") == "100"
    end

    unknown_cache = render_tokens(%{input_tokens: 80, cached_input_tokens: nil, output_tokens: 20, total_tokens: 100})
    assert text(unknown_cache, "[data-role='cached-tokens']") == "cache n/a"
    assert Enum.empty?(LazyHTML.query(unknown_cache, "[data-role='cache-rate']"))

    inconsistent_cache = render_tokens(%{input_tokens: 80, cached_input_tokens: 81, output_tokens: 20, total_tokens: 100})
    assert text(inconsistent_cache, "[data-role='cached-tokens']") == "81 cached"
    assert Enum.empty?(LazyHTML.query(inconsistent_cache, "[data-role='cache-rate']"))
  end

  test "unknown or zero total does not look like a completed progress bar" do
    for counts <- [nil, %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0}] do
      document = render_tokens(counts)
      assert Enum.empty?(LazyHTML.query(document, "[data-role='token-bar']"))
      assert text(document, "[data-role='usage-placeholder']") == "—"
    end
  end

  defp render_tokens(counts) do
    counts = if counts, do: Map.merge(%{reasoning_tokens: nil, cached_input_cost_usd: nil}, counts)

    render_component(&Usage.request_log_token_lines/1, request_log: %{id: "sample-request", token_counts: counts, cost: %{status: "unpriced"}}, prefix: "request-log")
    |> LazyHTML.from_fragment()
  end

  defp assert_segment(document, role, count) do
    segment = LazyHTML.query(document, "[data-role='#{role}']")
    assert LazyHTML.attribute(segment, "data-token-count") == [Integer.to_string(count)]
    assert LazyHTML.attribute(segment, "style") == ["flex-grow: #{count}"]
  end

  defp text(document, selector), do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
end
