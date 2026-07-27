defmodule CodexPooler.Quotas.ModelWeeklyResetSemanticsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.ModelWeeklyResetSemantics
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @reset_at ~U[2026-08-01 12:00:00.000000Z]

  describe "classify/1" do
    test "given atom and string target-scope maps, when anchored evidence is classified, then both scopes are anchored" do
      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{metadata: %{"reset_state" => "anchored"}})
             ) ==
               :anchored

      assert ModelWeeklyResetSemantics.classify(
               string_window(%{
                 "quota_scope" => "upstream_model",
                 "metadata" => %{"reset_state" => "anchored"}
               })
             ) == :anchored
    end

    test "given Evidence and AccountQuotaWindow values, when valid shared fields are classified, then struct provenance does not change semantics" do
      assert ModelWeeklyResetSemantics.classify(
               evidence(%{metadata: %{"reset_state" => "anchored"}})
             ) == :anchored

      assert ModelWeeklyResetSemantics.classify(
               account_quota_window(%{
                 quota_scope: "upstream_model",
                 metadata: %{"reset_state" => "floating"},
                 used_percent: Decimal.new("0.00")
               })
             ) == :floating
    end

    test "given valid recognized non-target windows, when semantics are classified, then account feature and nonweekly rows are not applicable" do
      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{quota_scope: "account", window_minutes: 10_080})
             ) == :not_applicable

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{quota_scope: "feature", window_minutes: 10_080})
             ) == :not_applicable

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{quota_scope: "model", window_minutes: 300})
             ) == :not_applicable

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{quota_scope: "upstream_model", window_minutes: 300})
             ) == :not_applicable
    end

    test "given malformed scope or duration fields, when applicability is decided, then classification is unknown before non-target handling" do
      for overrides <- [
            %{quota_scope: nil},
            %{quota_scope: :model},
            %{quota_scope: "unknown"},
            %{window_minutes: nil},
            %{window_minutes: "10080"},
            %{window_minutes: 10_080.0},
            %{window_minutes: 0},
            %{window_minutes: -1}
          ] do
        assert ModelWeeklyResetSemantics.classify(weekly_window(overrides)) == :unknown
      end
    end

    test "given signed and scaled zero values, when explicit floating evidence is classified, then numeric zero is floating" do
      for used_percent <- [Decimal.new("-0"), Decimal.new("0.00"), Decimal.new("0.000000")] do
        assert ModelWeeklyResetSemantics.classify(
                 weekly_window(%{
                   metadata: %{"reset_state" => "floating"},
                   used_percent: used_percent
                 })
               ) == :floating
      end
    end

    test "given finite in-range values, when anchored and legacy markerless evidence is classified, then positive and exhausted use remains anchored" do
      for used_percent <- [Decimal.new("0.5"), Decimal.new("99.999"), Decimal.new("100")] do
        assert ModelWeeklyResetSemantics.classify(weekly_window(%{used_percent: used_percent})) ==
                 :anchored
      end

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{
                 metadata: %{"reset_state" => "anchored"},
                 used_percent: Decimal.new("0")
               })
             ) == :anchored

      assert ModelWeeklyResetSemantics.classify(weekly_window(%{used_percent: Decimal.new("0")})) ==
               :unknown
    end

    test "given special or out-of-domain decimals, when semantics are classified, then every case is unknown without raising" do
      invalid_percents = [
        Decimal.new("NaN"),
        Decimal.new("Infinity"),
        Decimal.new("-Infinity"),
        Decimal.new("-0.001"),
        Decimal.new("100.001"),
        Decimal.new("1" <> String.duplicate("0", 1_000), max_digits: 1_001),
        0,
        "0"
      ]

      for used_percent <- invalid_percents do
        assert ModelWeeklyResetSemantics.classify(weekly_window(%{used_percent: used_percent})) ==
                 :unknown
      end
    end

    test "given exact reset-state metadata rules, when matching conflicting and malformed maps are classified, then only permitted shapes receive semantics" do
      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{metadata: %{reset_state: "floating"}})
             ) == :unknown

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{metadata: %{"reset_state" => "floating", reset_state: "floating"}})
             ) == :unknown

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{metadata: %{"reset_state" => "floating", reset_state: "anchored"}})
             ) == :unknown

      for metadata <- [
            %{"reset_state" => nil},
            %{"reset_state" => ""},
            %{"reset_state" => "relative"},
            %{"reset_state" => "unknown"},
            %{"reset_state" => :floating},
            nil,
            [],
            "metadata"
          ] do
        assert ModelWeeklyResetSemantics.classify(weekly_window(%{metadata: metadata})) ==
                 :unknown
      end
    end

    test "given resetless and incompatible explicit states, when classified, then they are unknown" do
      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{reset_at: nil, metadata: %{"reset_state" => "anchored"}})
             ) == :unknown

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{
                 reset_at: "2026-08-01T12:00:00Z",
                 metadata: %{"reset_state" => "floating"}
               })
             ) == :unknown

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{
                 metadata: %{"reset_state" => "floating"},
                 used_percent: Decimal.new("0.5")
               })
             ) == :unknown

      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{
                 metadata: %{"reset_state" => "floating"},
                 used_percent: Decimal.new("100")
               })
             ) == :unknown
    end

    test "given malformed required applicable fields, when they are classified, then they are unknown" do
      for overrides <- [
            %{reset_at: nil},
            %{reset_at: ~D[2026-08-01]},
            %{used_percent: nil},
            %{metadata: nil},
            %{metadata: 1}
          ] do
        assert ModelWeeklyResetSemantics.classify(weekly_window(overrides)) == :unknown
      end
    end

    test "given unrelated freshness and routing fields, when a valid anchored window is classified, then they do not influence semantics" do
      assert ModelWeeklyResetSemantics.classify(
               weekly_window(%{
                 active_limit: 0,
                 credits: 0,
                 freshness_state: "stale",
                 display_label: "unrelated label",
                 source: "unrelated source",
                 routing_usable: false,
                 unrelated_context: %{enabled: true, nested: %{"ready" => false}},
                 expires_at: ~U[2020-01-01 00:00:00.000000Z],
                 metadata: %{
                   "reset_state" => "anchored",
                   "enabled" => false,
                   "provider" => %{"nested" => true}
                 }
               })
             ) == :anchored
    end
  end

  describe "rank/1" do
    test "given every semantic atom, when ranked, then the shared ordering is exact" do
      assert ModelWeeklyResetSemantics.rank(:anchored) == 3
      assert ModelWeeklyResetSemantics.rank(:floating) == 2
      assert ModelWeeklyResetSemantics.rank(:unknown) == 1
      assert ModelWeeklyResetSemantics.rank(:not_applicable) == 0
    end
  end

  defp evidence(overrides) do
    struct!(Evidence, Map.merge(evidence_fields(), overrides))
  end

  defp account_quota_window(overrides) do
    struct!(AccountQuotaWindow, Map.merge(evidence_fields(), overrides))
  end

  defp weekly_window(overrides) do
    Map.merge(evidence_fields(), overrides)
  end

  defp string_window(overrides) do
    Map.merge(
      %{
        "quota_scope" => "model",
        "window_minutes" => 10_080,
        "reset_at" => @reset_at,
        "used_percent" => Decimal.new("12.5"),
        "metadata" => %{}
      },
      overrides
    )
  end

  defp evidence_fields do
    %{
      quota_key: "example_model",
      window_kind: "secondary",
      window_minutes: 10_080,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      freshness_state: "fresh",
      last_sync_at: @reset_at,
      observed_at: @reset_at,
      merge_precedence: 60,
      reset_at: @reset_at,
      used_percent: Decimal.new("12.5"),
      metadata: %{}
    }
  end
end
