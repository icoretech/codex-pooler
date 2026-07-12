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

    test "monthly account primary evidence routes as precise quota when fresh reset-bearing and not exhausted" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 43_200},
                 secondary: nil,
                 blocked_windows: []
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [monthly_account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "fresh monthly account primary evidence supersedes stale legacy 5h primary evidence" do
      stale_5h_observed_at =
        DateTime.add(
          @observed_at,
          -Evidence.freshness_ttl_seconds() - 1,
          :second
        )

      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 43_200},
                 blocked_windows: [],
                 routing_windows: [
                   %AccountQuotaWindow{window_kind: "primary", window_minutes: 43_200}
                 ]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(observed_at: stale_5h_observed_at),
                   monthly_account_primary_window()
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "monthly account primary exhaustion is rejected as exhausted instead of missing primary" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   reason_codes: ["exhausted"]
                 }
               ],
               selection: %{
                 primary: %AccountQuotaWindow{window_minutes: 43_200},
                 blocked_windows: [%AccountQuotaWindow{window_minutes: 43_200}]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [monthly_account_primary_window(used_percent: Decimal.new("100"))],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "monthly account primary routing blocks stale resetless and expired quota evidence" do
      stale_observed_at =
        DateTime.add(
          @observed_at,
          -Evidence.freshness_ttl_seconds() - 1,
          :second
        )

      scenarios = [
        {monthly_account_primary_window(reset_at: nil), ["reset_missing"]},
        {monthly_account_primary_window(observed_at: stale_observed_at), ["not_fresh"]},
        {monthly_account_primary_window(freshness_state: "stale"), ["not_fresh"]},
        {monthly_account_primary_window(reset_at: DateTime.add(@observed_at, -60, :second)),
         ["expired", "not_fresh"]}
      ]

      for {window, reason_codes} <- scenarios do
        assert %{
                 eligible?: false,
                 routing_state: :blocked,
                 exclusions: [
                   %{
                     code: "quota_window_unusable",
                     quota_key: "account",
                     window_kind: "primary",
                     reason_codes: ^reason_codes
                   }
                 ],
                 selection: %{primary: %AccountQuotaWindow{window_minutes: 43_200}}
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   [window],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 )
      end
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

    test "frozen 5h primary superseded by later-synced weekly evidence recovers as weekly-only probe" do
      frozen_observed_at = DateTime.add(@observed_at, -3_600, :second)

      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               exclusions: [],
               warnings: [%{code: "quota_account_primary_unknown"}],
               selection: %{
                 primary: nil,
                 secondary: %AccountQuotaWindow{window_kind: "secondary"},
                 routing_windows: [%AccountQuotaWindow{window_kind: "secondary"}]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(
                     observed_at: frozen_observed_at,
                     reset_at: DateTime.add(@observed_at, -900, :second)
                   ),
                   account_secondary_window(observed_at: @observed_at)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "stale 5h primary without a full freshness-TTL sync gap keeps routing blocked" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   window_kind: "primary",
                   reason_codes: ["not_fresh"]
                 }
               ]
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(
                     observed_at: DateTime.add(@observed_at, -1_200, :second)
                   ),
                   account_secondary_window(
                     observed_at: DateTime.add(@observed_at, -400, :second)
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "superseded 5h primary does not fabricate eligibility when weekly evidence is stale and imprecise" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_account_primary_missing",
                   message: "account primary quota evidence is required for routing"
                 }
               ],
               selection: %{primary: nil}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(
                     observed_at: DateTime.add(@observed_at, -4_000, :second)
                   ),
                   account_secondary_window(
                     observed_at: DateTime.add(@observed_at, -3_000, :second),
                     source_precision: "inferred"
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "legacy frozen weekly-duration primary rows are superseded by fresh weekly evidence" do
      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               exclusions: [],
               selection: %{
                 primary: nil,
                 secondary: %AccountQuotaWindow{window_kind: "secondary"},
                 routing_windows: [%AccountQuotaWindow{window_kind: "secondary"}]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_secondary_window(
                     window_kind: "primary",
                     source: "codex_response_headers",
                     observed_at: DateTime.add(@observed_at, -3_600, :second)
                   ),
                   account_secondary_window(observed_at: @observed_at)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "exhausted Spark weekly evidence blocks the weekly-only probe for Spark models" do
      assert %{
               eligible?: false,
               routing_state: :blocked
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_secondary_window(observed_at: @observed_at),
                   model_window(
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("100"),
                     reset_at: DateTime.add(@observed_at, 6, :day)
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "usable Spark weekly evidence keeps the weekly-only probe eligible for Spark models" do
      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               exclusions: []
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_secondary_window(observed_at: @observed_at),
                   model_window(
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("12"),
                     reset_at: DateTime.add(@observed_at, 6, :day)
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "evidence observed after as_of cannot supersede the primary selected at that instant" do
      # adversarial: strictly non-future — evidence one second past as_of is
      # already excluded, so both the sub-skew band (1..300s) and a two-hour
      # gap behave identically
      for future_offset_seconds <- [1, 60, 299, 2 * 3600] do
        assert %{
                 eligible?: true,
                 routing_state: :precise,
                 selection: %{
                   primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 300},
                   secondary: nil
                 }
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   [
                     account_primary_window(),
                     account_secondary_window(
                       observed_at: DateTime.add(@observed_at, future_offset_seconds, :second)
                     )
                   ],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 ),
               "future offset #{future_offset_seconds}s"
      end
    end

    test "fresh 5h primary beside fresh weekly evidence stays precise" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 300},
                 blocked_windows: []
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(),
                   account_secondary_window(observed_at: @observed_at)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
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

  defp monthly_account_primary_window(attrs \\ []) do
    account_primary_window(
      Keyword.merge(
        [
          window_minutes: 43_200,
          used_percent: Decimal.new("42.5"),
          reset_at: DateTime.add(@observed_at, 30, :day),
          source: "codex_usage_api"
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
