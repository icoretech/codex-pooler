defmodule CodexPoolerWeb.Admin.RequestLogTokenCompositionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPooler.Accounting.RequestLogs.SettlementPresentation
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Usage

  for {locale, spoken_rate} <- [{"en", "99.9% of input"}, {"zh_CN", "占输入的 99.9%"}] do
    test "#{locale} keeps the compact cache percentage and its accessible input denominator" do
      document =
        Gettext.with_locale(unquote(locale), fn ->
          render_tokens(%{input_tokens: 285_000, cached_input_tokens: 284_700, output_tokens: 600, total_tokens: 285_600})
        end)

      assert text(document, "[data-role='token-totals']") == "285.6k"
      assert text(document, "[data-role='cached-tokens']") =~ "284.7k"
      assert text(document, "[data-role='cache-rate'] > [aria-hidden='true']") == "· 99.9%"
      assert text(document, "[data-role='cache-rate'] > .sr-only") == unquote(spoken_rate)
      assert_segment(document, "cached-token-bar", 284_700)
    end
  end

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

  test "absent settlement shows unavailable usage without a composition bar" do
    assert_unavailable_usage(render_settlement(nil))
  end

  for usage_status <- ["usage_unknown", "usage_pending"] do
    test "#{usage_status} hides stored counters and cost instead of presenting measured usage" do
      settlement = %{
        usage_status: unquote(usage_status),
        input_tokens: 80,
        cached_input_tokens: 40,
        output_tokens: 20,
        total_tokens: 100,
        settled_cost_micros: Decimal.new(12_300),
        details: %{"pricing_status" => "priced", "settled_cost_micros" => "12300"}
      }

      assert_unavailable_usage(render_settlement(settlement))
    end
  end

  test "measured zero retains its recorded amount and priced zero cost without a composition bar" do
    document = render_settlement(zero_settlement())

    assert_zero_usage(document, "$0.00")
    assert text(document, "[data-role='cached-tokens']") == "0 cached"
  end

  test "measured zero remains visible when pricing is unavailable" do
    settlement = %{zero_settlement() | details: %{"pricing_status" => "unpriced_missing_model"}}
    document = render_settlement(settlement)

    assert_zero_usage(document, "cost n/a")
    assert text(document, "[data-role='cached-tokens']") == "0 cached"
  end

  test "nullable component counts do not hide a measured zero total or invent cached usage" do
    settlement = %{zero_settlement() | input_tokens: nil, cached_input_tokens: nil, output_tokens: nil}
    document = render_settlement(settlement)

    assert_zero_usage(document, "$0.00")
    assert text(document, "[data-role='cached-tokens']") == "cache n/a"
  end

  defp zero_settlement do
    %{
      usage_status: "usage_known",
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      settled_cost_micros: Decimal.new(0),
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "0"}
    }
  end

  defp render_settlement(settlement) do
    request_log = %{
      id: "sample-request",
      token_counts: SettlementPresentation.token_counts(settlement),
      cost: SettlementPresentation.cost(settlement)
    }

    tokens = render_component(&Usage.request_log_token_lines/1, request_log: request_log, prefix: "request-log")
    cost = render_component(&Usage.request_log_cost_lines/1, request_log: request_log, prefix: "request-log")
    LazyHTML.from_fragment(tokens <> cost)
  end

  defp assert_unavailable_usage(document) do
    assert text(document, "[data-role='usage-placeholder']") == "—"
    assert text(document, "[data-role='cost-placeholder']") == "—"
    assert Enum.empty?(LazyHTML.query(document, "[data-role='token-totals'], [data-role='cost'], [data-role='token-bar'], [data-role='cache-rate']"))
  end

  defp assert_zero_usage(document, expected_cost) do
    assert text(document, "[data-role='token-totals']") == "0"
    assert text(document, "[data-role='cost']") == expected_cost
    assert Enum.empty?(LazyHTML.query(document, "[data-role='usage-placeholder'], [data-role='cost-placeholder'], [data-role='token-bar'], [data-role='cache-rate']"))
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
