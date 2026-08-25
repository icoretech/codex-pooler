defmodule CodexPooler.Accounting.UsageResponsesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @as_of ~U[2026-08-25 00:00:00Z]

  test "additional Codex rate limits preserve fresh and unknown Spark-compatible windows" do
    fresh = additional_window("codex_spark", "fresh", @as_of)
    unknown = additional_window("other_feature", "unknown", @as_of)

    assert [
             %{
               quota_key: "codex_spark",
               limit_name: "Codex Spark",
               display_label: "Codex Spark",
               metered_feature: "spark_meter",
               rate_limit: %{primary_window: %{used_percent: 25}, secondary_window: nil}
             },
             %{
               quota_key: "other_feature",
               limit_name: "Other feature",
               display_label: "Other feature",
               metered_feature: "other_meter",
               rate_limit: %{primary_window: %{used_percent: 60}, secondary_window: nil}
             }
           ] = UsageResponses.additional_codex_rate_limits([fresh, unknown], @as_of)

    account = account_window(@as_of)

    assert {%{used_percent: 12}, nil} =
             UsageResponses.account_usage_windows([account], @as_of)
  end

  @tag :additional_limit_stale_policy
  test "additional Codex rate limits omit dynamically stale rows while preserving fresh and unknown rows" do
    fresh = additional_window("codex_spark", "fresh", @as_of)
    unknown = additional_window("other_feature", "unknown", @as_of)

    stale =
      additional_window(
        "stale_feature",
        "fresh",
        DateTime.add(@as_of, -901, :second)
      )

    assert [
             %{quota_key: "codex_spark", rate_limit: %{primary_window: %{used_percent: 25}}},
             %{quota_key: "other_feature", rate_limit: %{primary_window: %{used_percent: 60}}}
           ] = UsageResponses.additional_codex_rate_limits([fresh, unknown, stale], @as_of)
  end

  test "additional Codex rate limits retain one legacy entry for generic evidence" do
    generic =
      additional_window("shared_feature", "fresh", @as_of,
        metered_feature: nil,
        raw_metered_feature: nil,
        raw_limit_id: nil
      )

    assert [
             %{
               quota_key: "shared_feature",
               metered_feature: nil,
               rate_limit: %{primary_window: %{used_percent: 25}, secondary_window: nil}
             }
           ] = UsageResponses.additional_codex_rate_limits([generic], @as_of)
  end

  @tag :additional_limit_meter_identity
  test "additional Codex rate limits preserve deterministic entries per canonical meter" do
    image_primary =
      additional_window("shared_feature", "fresh", @as_of,
        metered_feature: "image_generation",
        raw_metered_feature: " image_generation ",
        used_percent: "25"
      )

    image_secondary =
      additional_window("shared_feature", "fresh", @as_of,
        window_kind: "secondary",
        window_minutes: 10_080,
        metered_feature: "image_generation",
        raw_metered_feature: " image_generation ",
        used_percent: "40"
      )

    research_primary =
      additional_window("shared_feature", "fresh", @as_of,
        metered_feature: "deep_research",
        raw_metered_feature: "deep_research",
        used_percent: "70"
      )

    research_secondary =
      additional_window("shared_feature", "fresh", @as_of,
        window_kind: "secondary",
        window_minutes: 10_080,
        metered_feature: "deep_research",
        raw_metered_feature: "deep_research",
        used_percent: "80"
      )

    generic =
      additional_window("shared_feature", "fresh", @as_of,
        metered_feature: nil,
        raw_metered_feature: "   ",
        raw_limit_id: nil,
        used_percent: "99"
      )

    assert [
             %{
               quota_key: "shared_feature",
               metered_feature: "deep_research",
               rate_limit: %{
                 primary_window: %{used_percent: 70},
                 secondary_window: %{used_percent: 80}
               }
             },
             %{
               quota_key: "shared_feature",
               metered_feature: "image_generation",
               rate_limit: %{
                 primary_window: %{used_percent: 25},
                 secondary_window: %{used_percent: 40}
               }
             }
           ] =
             UsageResponses.additional_codex_rate_limits(
               [research_secondary, generic, image_primary, research_primary, image_secondary],
               @as_of
             )
  end

  @tag :additional_limit_meter_identity
  test "additional Codex rate limits fall back to the canonical raw limit id" do
    fallback =
      additional_window("fallback_feature", "fresh", @as_of,
        metered_feature: nil,
        raw_metered_feature: "   ",
        raw_limit_id: " fallback-meter "
      )

    assert [
             %{
               quota_key: "fallback_feature",
               metered_feature: "fallback-meter",
               rate_limit: %{primary_window: %{used_percent: 25}, secondary_window: nil}
             }
           ] = UsageResponses.additional_codex_rate_limits([fallback], @as_of)
  end

  defp additional_window(quota_key, freshness_state, observed_at, overrides \\ []) do
    %AccountQuotaWindow{
      quota_key: quota_key,
      window_kind: Keyword.get(overrides, :window_kind, "primary"),
      window_minutes: Keyword.get(overrides, :window_minutes, 300),
      used_percent:
        Decimal.new(
          Keyword.get(
            overrides,
            :used_percent,
            if(quota_key == "other_feature", do: "60", else: "25")
          )
        ),
      reset_at:
        if(quota_key == "other_feature", do: nil, else: DateTime.add(@as_of, 300, :second)),
      display_label: if(quota_key == "codex_spark", do: "Codex Spark", else: "Other feature"),
      limit_name: if(quota_key == "codex_spark", do: "Codex Spark", else: "Other feature"),
      metered_feature:
        Keyword.get(
          overrides,
          :metered_feature,
          if(quota_key == "codex_spark", do: "spark_meter", else: "other_meter")
        ),
      raw_metered_feature: Keyword.get(overrides, :raw_metered_feature),
      raw_limit_id: Keyword.get(overrides, :raw_limit_id),
      source: "test",
      freshness_state: freshness_state,
      observed_at: observed_at
    }
  end

  defp account_window(observed_at) do
    %AccountQuotaWindow{
      quota_key: "account",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("12"),
      reset_at: DateTime.add(@as_of, 300, :second),
      source: "test",
      freshness_state: "fresh",
      observed_at: observed_at
    }
  end
end
