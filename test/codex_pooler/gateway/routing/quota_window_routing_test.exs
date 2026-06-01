defmodule CodexPooler.Gateway.Routing.QuotaWindowRoutingTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows

  @observed_at ~U[2026-05-22 12:00:00Z]

  describe "routing_quota_eligibility_from_windows/2" do
    test "ordinary models stay eligible when Spark quota evidence is absent" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{primary: %AccountQuotaWindow{}, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows([account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "ordinary models ignore unusable Spark quota evidence that is out of model scope" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), exhausted_spark_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "Spark model routing blocks when in-scope Spark quota evidence is unusable" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "sample-codex-spark",
                   reason_codes: ["exhausted"]
                 }
               ],
               selection: %{blocked_windows: [%AccountQuotaWindow{quota_key: "codex_spark"}]}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), exhausted_spark_window()],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "Spark model routing does not fail closed solely because no Spark-specific window exists" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{primary: %AccountQuotaWindow{}, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows([account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "account primary routing blocks resetless quota evidence" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   reason_codes: ["reset_missing"]
                 }
               ]
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(reset_at: nil, source_precision: "inferred")],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "account primary routing blocks exhausted quota evidence" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   reason_codes: ["exhausted"]
                 }
               ]
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(used_percent: Decimal.new("100"))],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "account primary routing blocks stale and unknown freshness quota evidence" do
      for freshness_state <- ["stale", "unknown"] do
        assert %{
                 eligible?: false,
                 routing_state: :blocked,
                 exclusions: [
                   %{
                     code: "quota_window_unusable",
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     freshness_state: ^freshness_state,
                     reason_codes: ["not_fresh"]
                   }
                 ]
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   [account_primary_window(freshness_state: freshness_state)],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 )
      end
    end

    test "model-scoped routing evidence for the wrong model stays out of scope" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_evidence_out_of_scope",
                   message: "recorded quota evidence does not match the requested model scope"
                 }
               ],
               selection: %{routing_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   model_window(
                     model: "sample-codex-other",
                     upstream_model: "sample-codex-other-upstream"
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "account secondary weekly exhaustion with positive credits routes as credit-backed probe" do
      assert %{
               eligible?: true,
               routing_state: :credit_backed_probe,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{},
                 secondary: %AccountQuotaWindow{credits: 42},
                 blocked_windows: [
                   %AccountQuotaWindow{window_kind: "secondary", used_percent: used_percent}
                 ]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(),
                   account_secondary_window(used_percent: Decimal.new("100"), credits: 42)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )

      assert Decimal.equal?(used_percent, Decimal.new("100"))
    end

    test "credit-backed probe requires fresh reset-bearing unexpired positive-credit exhaustion" do
      stale_observed_at =
        DateTime.add(
          @observed_at,
          -Evidence.freshness_ttl_seconds() - 1,
          :second
        )

      scenarios = [
        account_secondary_window(used_percent: Decimal.new("100"), credits: nil),
        account_secondary_window(used_percent: Decimal.new("100"), credits: 0),
        account_secondary_window(used_percent: Decimal.new("100"), credits: 42, reset_at: nil),
        account_secondary_window(
          used_percent: Decimal.new("100"),
          credits: 42,
          reset_at: DateTime.add(@observed_at, -60, :second)
        ),
        account_secondary_window(
          used_percent: Decimal.new("100"),
          credits: 42,
          observed_at: stale_observed_at
        ),
        account_secondary_window(
          used_percent: Decimal.new("100"),
          credits: 42,
          freshness_state: "stale"
        )
      ]

      for window <- scenarios do
        assert %{eligible?: false, routing_state: :blocked} =
                 Windows.routing_quota_eligibility_from_windows(
                   [account_primary_window(), window],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 )
      end
    end

    test "positive credits do not revive primary model upstream-model or additional exhaustion" do
      scenarios = [
        [account_primary_window(used_percent: Decimal.new("100"), credits: 42)],
        [
          account_primary_window(),
          model_window(used_percent: Decimal.new("100"), credits: 42)
        ],
        [
          account_primary_window(),
          upstream_model_window(used_percent: Decimal.new("100"), credits: 42)
        ],
        [
          account_primary_window(),
          additional_limit_window(used_percent: Decimal.new("100"), credits: 42)
        ]
      ]

      for windows <- scenarios do
        assert %{
                 eligible?: false,
                 routing_state: :blocked,
                 exclusions: [%{reason_codes: reason_codes} | _]
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   windows,
                   at: @observed_at,
                   model: "sample-codex-spark",
                   requested_model: "sample-codex-spark",
                   upstream_model: "sample-codex-spark-upstream"
                 )

        assert "exhausted" in reason_codes
      end
    end
  end

  defp account_primary_window(attrs \\ []) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new("12"),
          reset_at: DateTime.add(@observed_at, 900, :second),
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh",
          observed_at: @observed_at
        ],
        attrs
      )
    )
  end

  defp exhausted_spark_window do
    model_window(used_percent: Decimal.new("100"))
  end

  defp account_secondary_window(attrs) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("12"),
          reset_at: DateTime.add(@observed_at, 604_800, :second),
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh",
          observed_at: @observed_at
        ],
        attrs
      )
    )
  end

  defp upstream_model_window(attrs) do
    model_window(
      Keyword.merge(
        [
          quota_key: "provider_gpt_5_3_codex_spark",
          quota_scope: "upstream_model",
          upstream_model: "sample-codex-spark-upstream"
        ],
        attrs
      )
    )
  end

  defp additional_limit_window(attrs) do
    model_window(
      Keyword.merge(
        [
          quota_key: "codex_feature_limit",
          quota_scope: "feature",
          quota_family: "codex_feature",
          model: nil,
          upstream_model: nil
        ],
        attrs
      )
    )
  end

  defp model_window(attrs) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "codex_spark",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new("12"),
          reset_at: DateTime.add(@observed_at, 900, :second),
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "sample-codex-spark",
          upstream_model: "sample-codex-spark-upstream",
          freshness_state: "fresh",
          observed_at: @observed_at
        ],
        attrs
      )
    )
  end
end
