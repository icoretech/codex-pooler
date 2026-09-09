defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservationsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @now ~U[2026-09-07 12:00:00Z]

  test "retains every entry with selected first and remaining entries in chronological order" do
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

      expected = [selected_index | Enum.reject(0..(count - 1), &(&1 == selected_index))]

      assert length(row.observations) == count
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
    assert [selected, latest] = row.observations
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

    assert Enum.any?(
             row.observations,
             &(List.keyfind(&1.details, "Reported slot", 0) == {"Reported slot", "primary"})
           )

    assert Enum.any?(row.observations, &(&1.reset_at == "Not reported"))
    assert Enum.any?(row.observations, & &1.elapsed?)
    assert Enum.count(row.observations, & &1.selected?) == 1
  end

  test "keeps pending provider confirmation facts on the retained observation and never borrows stale history" do
    retained_observed_at = DateTime.add(@now, -2, :minute)
    candidate_observed_at = DateTime.add(@now, -1, :minute)
    reset_at = DateTime.add(@now, 6, :day)

    selected =
      %{
        window("codex_usage_api", retained_observed_at, "100")
        | reset_at: reset_at,
          metadata: %{
            "__quota_confirmed_candidate_v1" => %{
              "version" => 1,
              "used_percent" => "32",
              "reset_at" => DateTime.to_iso8601(reset_at),
              "observed_at" => DateTime.to_iso8601(candidate_observed_at),
              "count" => 1
            },
            "__quota_candidate_provider_status_v1" => %{
              "version" => 1,
              "allowed" => true,
              "limit_reached" => false,
              "observed_at" => DateTime.to_iso8601(candidate_observed_at)
            }
          }
      }

    stale_runtime = window("codex_rate_limit_event", DateTime.add(@now, -1, :hour), "32")
    stale_headers = window("codex_response_headers", DateTime.add(@now, -2, :hour), "31")

    rows =
      QuotaProjection.quota_limit_rows(
        [selected],
        DateTimeDisplay.preferences_for_user(nil),
        @now,
        nil,
        [selected, stale_runtime, stale_headers]
      )

    weekly = Enum.find(rows, &(&1.key == :weekly))
    [selected_observation, runtime_observation, header_observation] = weekly.observations

    assert selected_observation.measurement_pending?
    assert selected_observation.permission_facts == %{allowed: true, limit_reached: false}
    assert selected_observation.remaining == "0%"
    assert selected_observation.pending_measurement.remaining == "68%"
    refute runtime_observation.measurement_pending?
    refute header_observation.measurement_pending?
    assert runtime_observation.remaining == "68%"
    assert header_observation.remaining == "69%"

    nonzero_selected = %{selected | used_percent: Decimal.new("95")}

    [nonzero_weekly] =
      QuotaProjection.quota_limit_rows(
        [nonzero_selected],
        DateTimeDisplay.preferences_for_user(nil),
        @now,
        nil,
        [nonzero_selected]
      )
      |> Enum.filter(&(&1.key == :weekly))

    assert nonzero_weekly.percent_label == "5%"

    assert {"Retained measurement", "5% remaining"} in hd(nonzero_weekly.observations).details
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
