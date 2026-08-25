defmodule CodexPooler.Accounting.UsageResponsesMeterIdentityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @as_of ~U[2026-08-25 00:00:00Z]

  test "additional Codex rate limits preserve deterministic entries per canonical meter" do
    image_primary =
      additional_window("shared_feature",
        metered_feature: "image_generation",
        raw_metered_feature: " image_generation ",
        used_percent: "25"
      )

    image_secondary =
      additional_window("shared_feature",
        window_kind: "secondary",
        window_minutes: 10_080,
        metered_feature: "image_generation",
        raw_metered_feature: " image_generation ",
        used_percent: "40"
      )

    research_primary =
      additional_window("shared_feature",
        metered_feature: "deep_research",
        raw_metered_feature: "deep_research",
        used_percent: "70"
      )

    research_secondary =
      additional_window("shared_feature",
        window_kind: "secondary",
        window_minutes: 10_080,
        metered_feature: "deep_research",
        raw_metered_feature: "deep_research",
        used_percent: "80"
      )

    generic =
      additional_window("shared_feature",
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

  test "additional Codex rate limits fall back to the canonical raw limit id" do
    fallback =
      additional_window("fallback_feature",
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

  defp additional_window(quota_key, overrides) do
    %AccountQuotaWindow{
      quota_key: quota_key,
      window_kind: Keyword.get(overrides, :window_kind, "primary"),
      window_minutes: Keyword.get(overrides, :window_minutes, 300),
      used_percent: Decimal.new(Keyword.get(overrides, :used_percent, "25")),
      reset_at: DateTime.add(@as_of, 300, :second),
      display_label: "Other feature",
      limit_name: "Other feature",
      metered_feature: Keyword.get(overrides, :metered_feature),
      raw_metered_feature: Keyword.get(overrides, :raw_metered_feature),
      raw_limit_id: Keyword.get(overrides, :raw_limit_id),
      source: "test",
      freshness_state: "fresh",
      observed_at: @as_of
    }
  end
end
