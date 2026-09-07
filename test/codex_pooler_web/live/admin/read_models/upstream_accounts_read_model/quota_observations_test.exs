defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservationsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow
  alias CodexPoolerWeb.DateTimeDisplay

  @now ~U[2026-09-07 01:12:35Z]
  @old_reset ~U[2026-09-13 20:49:16Z]
  @new_reset ~U[2026-09-14 00:57:27Z]

  test "future reset disagreement survives stale-header deduplication without changing routing" do
    old =
      window(
        source: "codex_response_headers",
        used_percent: Decimal.new(98),
        observed_at: ~U[2026-09-07 00:51:13Z],
        reset_at: @old_reset
      )

    fresh = window()

    for raw <- [[old, fresh], [fresh, old]] do
      assert [^fresh] = WindowSelector.logical_windows(raw, @now)
      row = weekly(raw)
      assert row.label == "Account Weekly"
      assert row.percent == nil
      assert row.percent_label == "sources differ"
      assert row.selected_percent_label == "94%"
      assert row.selected_source == "codex_usage_api"
      assert row.reset_display_state == :absent
      assert [header, usage] = row.observations
      assert header.used == "98%"
      assert header.remaining == "2%"
      assert header.freshness == "stale"
      assert header.observed_at == "2026-09-07T00:51:13Z"
      assert header.reset_at == "2026-09-13T20:49:16Z"
      refute header.elapsed
      assert usage.used == "6%"
      assert usage.remaining == "94%"
      assert usage.freshness == "fresh"
      assert [^fresh] = WindowSelector.logical_windows(raw, @now)

      html = render_component(&QuotaLimitRow.quota_limit_row/1, id: "test-weekly", limit: row)
      assert html =~ "Sources disagree; remaining quota is uncertain"
      assert html =~ "codex_response_headers"
      assert html =~ "98% used / 2% remaining"
      assert html =~ "2026-09-13T20:49:16Z"
      assert html =~ "data-freshness=\"stale\""
      assert html =~ "<details open"
    end
  end

  test "actual elapsed reset does not conflict with a fresh new window" do
    ended =
      window(
        source: "codex_response_headers",
        used_percent: Decimal.new(100),
        observed_at: DateTime.add(@now, -3600),
        reset_at: DateTime.add(@now, -1)
      )

    row = weekly([ended, window()])
    refute row.source_disagreement
    assert row.percent_label == "94%"
    assert Enum.any?(row.observations, & &1.elapsed)
  end

  test "future observations cannot influence a historical view" do
    future =
      window(
        source: "codex_response_headers",
        used_percent: Decimal.new(99),
        observed_at: DateTime.add(@now, 1)
      )

    row = weekly([window(), future])
    refute row.source_disagreement
    assert length(row.observations) == 1
  end

  test "ordinary agreeing sources and equivalent decimals keep a normal meter" do
    header = window(source: "codex_response_headers", used_percent: Decimal.new("6.0"))
    row = weekly([window(), header])
    refute row.source_disagreement
    assert row.percent_label == "94%"
    assert length(row.observations) == 2
  end

  test "ordinary chronological usage growth preserves the selected meter" do
    older =
      window(
        source: "codex_response_headers",
        used_percent: Decimal.new(5),
        observed_at: DateTime.add(@now, -300)
      )

    for raw <- [[older, window()], [window(), older]] do
      row = weekly(raw)
      refute row.source_disagreement
      assert row.percent_label == row.selected_percent_label
      assert row.percent_label == "94%"
      assert length(row.observations) == 2
    end
  end

  test "chronological usage decrease stays uncertain while both windows remain open" do
    older =
      window(
        source: "codex_response_headers",
        used_percent: Decimal.new(6),
        observed_at: DateTime.add(@now, -300)
      )

    newer = window(used_percent: Decimal.new(5))

    for raw <- [[older, newer], [newer, older]] do
      row = weekly(raw)
      assert row.source_disagreement
      assert row.percent_label == "sources differ"
      refute row.reset_disagreement
    end
  end

  test "reset presentation tolerates up to one minute of timestamp drift" do
    for seconds <- [1, 60] do
      header =
        window(source: "codex_response_headers", reset_at: DateTime.add(@new_reset, seconds))

      row = weekly([window(), header])
      refute row.reset_disagreement
      refute row.source_disagreement
      assert row.reset_at != nil
      assert length(row.observations) == 2
    end

    header = window(source: "codex_response_headers", reset_at: DateTime.add(@new_reset, 61))
    assert weekly([window(), header]).reset_disagreement

    missing = window(source: "codex_response_headers", reset_at: nil)
    row = weekly([window(), missing])
    refute row.reset_disagreement
    assert Enum.any?(row.observations, &(&1.reset_at == "not reported"))
  end

  test "missing, unknown, zero and exhausted remain distinct" do
    assert weekly([]).percent_label == "not reported"
    assert weekly([window(used_percent: nil)]).percent_label == "not reported"
    zero = weekly([window(used_percent: Decimal.new(0))])
    assert zero.percent_label == "100%"
    assert hd(zero.observations).used == "0%"
    exhausted = weekly([window(used_percent: Decimal.new(100))])
    assert exhausted.percent_label == "0%"

    stale =
      weekly([window(used_percent: Decimal.new(100), observed_at: DateTime.add(@now, -901))])

    assert stale.meter_state == :historical_exhausted
    assert hd(stale.observations).freshness == "stale"
    refute stale.source_disagreement
  end

  test "reset disagreement alone remains visible and missing reset is explicit" do
    header = window(source: "codex_response_headers", reset_at: @old_reset)
    reset_only = weekly([window(), header])
    assert reset_only.reset_disagreement
    refute reset_only.source_disagreement
    assert reset_only.percent_label == "94%"
    row = weekly([window(reset_at: nil)])
    assert hd(row.observations).reset_at == "not reported"
  end

  test "equal observation times with different usage stay uncertain, including all stale reports" do
    header = window(source: "codex_response_headers", used_percent: Decimal.new(100))
    assert header.observed_at == window().observed_at
    assert weekly([window(), header]).source_disagreement
    old = DateTime.add(@now, -901)
    row = weekly([window(observed_at: old), %{header | observed_at: old}])
    assert row.source_disagreement
    assert Enum.all?(row.observations, &(&1.freshness == "stale"))
  end

  test "legacy weekly primary reports still share one account evidence group" do
    legacy =
      window(source: "codex_response_headers", window_kind: "primary", reset_at: @old_reset)

    assert weekly([window(), legacy]).reset_disagreement
  end

  test "usage parser retains normal_model_slug as metadata and separate additional scopes" do
    payload = %{
      "rate_limit" => %{"primary_window" => usage_window(6)},
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-Reserve",
          "metered_feature" => "base_model_inference",
          "normal_model_slug" => "gpt-5.6-luna",
          "rate_limit" => %{"primary_window" => usage_window(0)}
        },
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_spark",
          "rate_limit" => %{"primary_window" => usage_window(0)}
        }
      ]
    }

    {:ok, result} = Evidence.CodexParsers.parse_codex_usage_result(payload, @now)
    reserve = Enum.find(result.windows, &(&1.raw_metered_feature == "base_model_inference"))
    assert reserve.metadata["normal_model_slug"] == "gpt-5.6-luna"

    {:ok, original} =
      Evidence.CodexParsers.parse_codex_usage_result(
        update_in(
          payload["additional_rate_limits"],
          &Enum.map(&1, fn limit -> Map.delete(limit, "normal_model_slug") end)
        ),
        @now
      )

    assert Enum.map(result.windows, &Evidence.logical_window_key/1) ==
             Enum.map(original.windows, &Evidence.logical_window_key/1)

    raw = Enum.map(result.windows, &struct(AccountQuotaWindow, Map.from_struct(&1)))
    rows = project(raw)
    assert Enum.find(rows, &(&1.key == :weekly)).label == "Account Weekly"
    reserve_row = Enum.find(rows, &String.contains?(&1.label, "Reserve"))
    assert reserve_row.percent_label == "100%"
    assert hd(reserve_row.observations).descriptor =~ "gpt-5.6-luna"
    spark_row = Enum.find(rows, &String.contains?(&1.label, "Spark"))
    assert spark_row.percent_label == "100%"
    refute spark_row.source_disagreement
  end

  defp usage_window(used),
    do: %{
      "used_percent" => used,
      "limit_window_seconds" => 604_800,
      "reset_after_seconds" => DateTime.diff(@new_reset, @now),
      "reset_at" => DateTime.to_unix(@new_reset)
    }

  defp weekly(raw), do: Enum.find(project(raw), &(&1.key == :weekly))

  defp project(raw) do
    QuotaProjection.quota_limit_rows(
      WindowSelector.logical_windows(raw, @now),
      DateTimeDisplay.preferences_for_user(nil),
      @now,
      nil,
      raw
    )
  end

  defp window(attrs \\ []) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          observed_at: ~U[2026-09-07 01:12:00Z],
          last_sync_at: ~U[2026-09-07 01:12:00Z],
          reset_at: @new_reset,
          used_percent: Decimal.new(6),
          merge_precedence: 60,
          metadata: %{}
        ],
        attrs
      )
    )
  end
end
