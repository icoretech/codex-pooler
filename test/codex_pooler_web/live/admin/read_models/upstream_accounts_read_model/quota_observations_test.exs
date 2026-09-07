defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservationsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @now ~U[2026-09-07 12:00:00Z]

  test "caps observations at five while retaining the selected source in chronological order" do
    for count <- [4, 5, 8], selected_index <- [0, count - 1] do
      raw =
        for index <- 0..(count - 1),
            do:
              window(
                "source-#{index}",
                DateTime.add(@now, -index * 60, :second),
                Integer.to_string(index)
              )

      selected = Enum.at(raw, selected_index)

      rows =
        QuotaProjection.quota_limit_rows(
          [selected],
          DateTimeDisplay.preferences_for_user(nil),
          @now,
          nil,
          Enum.reverse(raw)
        )

      row = Enum.find(rows, &(&1.key == :weekly))

      expected =
        if count > 5 and selected_index >= 5,
          do: [0, 1, 2, 3, selected_index],
          else: Enum.to_list(0..(min(count, 5) - 1))

      assert length(row.observations) == min(count, 5)
      assert Enum.count(row.observations, & &1.selected?) == 1
      assert Enum.map(row.observations, & &1.used) == Enum.map(expected, &"#{&1}%")
    end
  end

  test "orders by observation time even when an older source is selected" do
    older = window("codex_response_headers", DateTime.add(@now, -60, :second), "90")
    newer = window("codex_usage_api", @now, "20")
    preferences = DateTimeDisplay.preferences_for_user(nil)
    rows = QuotaProjection.quota_limit_rows([older], preferences, @now, nil, [older, newer])
    row = Enum.find(rows, &(&1.key == :weekly))
    assert [latest, selected] = row.observations
    assert latest.source == "Usage API"
    refute latest.selected?
    assert selected.source == "Response headers"
    assert selected.selected?
    assert row.percent_label == "10%"
  end

  test "retains stale observations without changing selected value, countdown or visible meters" do
    selected = window("codex_usage_api", @now, "20")
    stale = window("codex_response_headers", DateTime.add(@now, -1, :day), "90")
    future = window("codex_rate_limit_event", DateTime.add(@now, 1, :second), "100")
    raw = [stale, future, selected]
    effective = WindowSelector.logical_windows(raw, @now)
    preferences = DateTimeDisplay.preferences_for_user(nil)
    baseline = QuotaProjection.quota_limit_rows(effective, preferences, @now, nil)
    actual = QuotaProjection.quota_limit_rows(effective, preferences, @now, nil, raw)

    assert Enum.map(actual, &Map.delete(&1, :observations)) ==
             Enum.map(baseline, &Map.delete(&1, :observations))

    row = Enum.find(actual, &(&1.key == :weekly))
    assert row.percent_label == "80%"
    assert [chosen, previous] = row.observations
    assert chosen.selected?
    assert chosen.source == "Usage API"
    assert chosen.remaining == "80%"
    refute previous.selected?
    assert previous.source == "Response headers"
    assert previous.freshness == "stale"
  end

  test "isolates same-label additional meters and never exposes their raw identity or unknown source" do
    first = additional("private-meter-a", "private-source-sentinel", "10")
    second = additional("private-meter-b", "codex_usage_api", "60")
    raw = [first, second]

    rows =
      QuotaProjection.quota_limit_rows(
        WindowSelector.logical_windows(raw, @now),
        DateTimeDisplay.preferences_for_user(nil),
        @now,
        nil,
        raw
      )

    additional_rows = Enum.filter(rows, &is_binary(&1.key))
    assert length(additional_rows) == 2
    assert Enum.all?(additional_rows, &(length(&1.observations) == 1))
    assert Enum.all?(additional_rows, &hd(&1.observations).selected?)
    refute inspect(rows) =~ "private-meter"
    refute inspect(rows) =~ "private-source-sentinel"
  end

  test "canonicalizes legacy weekly slots and reports missing and elapsed reset values" do
    chosen = window("codex_usage_api", @now, "20")

    legacy = %{
      window("codex_response_headers", DateTime.add(@now, -60, :second), "30")
      | window_kind: "primary",
        reset_at: nil
    }

    elapsed = %{
      window("codex_rate_limit_error", DateTime.add(@now, -120, :second), "100")
      | reset_at: DateTime.add(@now, -1, :second)
    }

    rows =
      QuotaProjection.quota_limit_rows(
        [chosen],
        DateTimeDisplay.preferences_for_user(nil),
        @now,
        nil,
        [chosen, legacy, elapsed]
      )

    row = Enum.find(rows, &(&1.key == :weekly))
    assert length(row.observations) == 3
    assert Enum.any?(row.observations, &(&1.reset_at == "Not reported"))
    assert Enum.any?(row.observations, & &1.elapsed?)
    assert Enum.count(row.observations, & &1.selected?) == 1
  end

  defp window(source, observed_at, used) do
    %AccountQuotaWindow{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      source: source,
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: observed_at,
      last_sync_at: observed_at,
      updated_at: observed_at,
      reset_at: DateTime.add(@now, 6, :day),
      used_percent: Decimal.new(used),
      metadata: %{},
      merge_precedence: 60
    }
  end

  defp additional(token, source, used) do
    %{
      window(source, @now, used)
      | quota_scope: "feature",
        quota_key: "shared_meter",
        raw_metered_feature: token,
        display_label: "Shared label"
    }
  end
end
