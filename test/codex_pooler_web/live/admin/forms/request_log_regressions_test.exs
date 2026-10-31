defmodule CodexPoolerWeb.Admin.RequestLogRegressionsTest do
  use ExUnit.Case, async: true
  alias CodexPoolerWeb.Admin.RequestLogFilterForm
  alias CodexPoolerWeb.Admin.RequestLogsDisplay
  alias CodexPoolerWeb.Admin.RequestLogsDisplay.Errors
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Metrics

  test "plural selection preserves compact tokens and grouped display counts" do
    Gettext.with_locale("en", fn ->
      assert RequestLogsDisplay.format_token_counts(%{total_tokens: 1}) == "1 token"
      assert RequestLogsDisplay.format_token_counts(%{total_tokens: 2_000}) == "2k tokens"
      assert RequestLogsDisplay.format_cached_token_breakdown(%{token_counts: %{cached_input_tokens: 2_000}}) == "2k cached"
      composition = Metrics.token_composition(%{input_tokens: 2_000, cached_input_tokens: 1_000, output_tokens: 1_000, total_tokens: 3_000})
      assert composition.title == "3,000 total tokens — Cached input: 1,000; Uncached input: 1,000; Output: 1,000. Output includes reasoning tokens."
    end)
  end

  test "quota labels preserve distinct failures and their reset advice" do
    errors = [%{code: "quota_exhausted", reset_at: ~U[2026-09-27 12:00:00Z]}, %{code: "stream_incomplete"}, %{code: "upstream_timeout"}, %{code: "quota_evidence_unavailable"}]
    assert Errors.format_errors(%{errors: errors}, %{timezone: "Etc/UTC", datetime_format: "short"}) == ["quota exhausted", "stream_incomplete", "upstream_timeout", "quota evidence unavailable", "resets 2026-09-27 12:00"]
  end

  test "positive cache never displays zero percent" do
    assert Metrics.cache_rate_label(%{input_tokens: 3000, cached_input_tokens: 1}) == "<0.1%"
    assert Metrics.cache_rate_label(%{input_tokens: 3000, cached_input_tokens: 0}) == "0%"
    assert Metrics.cache_rate_label(%{input_tokens: 3000, cached_input_tokens: 3000}) == "100%"
  end

  test "date filters explain skipped dates and unavailable timezones" do
    {_, _, [error]} = RequestLogFilterForm.parse_filters(%{"date_from" => "2011-12-30"}, nil, MapSet.new(), "Pacific/Apia")
    assert error.message =~ "does not exist"
    {_, _, [error]} = RequestLogFilterForm.parse_filters(%{"date_to" => "2026-09-27"}, nil, MapSet.new(), "Unknown/Zone")
    assert error.message =~ "timezone is unavailable"
  end
end
