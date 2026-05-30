defmodule CodexPoolerWeb.Admin.UpstreamQuotaReadinessTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPoolerWeb.Admin.UpstreamQuotaReadiness

  @as_of ~U[2026-05-30 12:00:00Z]
  @future_reset ~U[2026-05-30 12:15:00Z]
  @weekly_reset ~U[2026-06-06 12:00:00Z]
  @expected_keys MapSet.new([
                   :state,
                   :label,
                   :tone,
                   :border_class,
                   :routing_ready_now?,
                   :reason_codes,
                   :primary_window,
                   :weekly_window
                 ])

  describe "from_windows/2" do
    test "maps precise account quota eligibility to ready" do
      primary = account_primary_window()

      assert %{
               state: "ready",
               label: "Quota ready",
               tone: :success,
               border_class: "border-l-success",
               routing_ready_now?: true,
               reason_codes: [],
               primary_window: ^primary,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_windows([primary], @as_of)

      assert_exact_keys(projection)
    end

    test "maps weekly-only probe eligibility to warning readiness that can still route" do
      weekly = account_weekly_window()

      assert %{
               state: "weekly_only_probe",
               label: "Weekly quota probe",
               tone: :warning,
               border_class: "border-l-warning",
               routing_ready_now?: true,
               reason_codes: ["quota_account_primary_unknown"],
               primary_window: nil,
               weekly_window: ^weekly
             } = projection = UpstreamQuotaReadiness.from_windows([weekly], @as_of)

      assert_exact_keys(projection)
    end

    test "maps exhausted account primary evidence to exhausted" do
      primary = account_primary_window(used_percent: Decimal.new("100"))

      assert %{
               state: "exhausted",
               label: "Quota exhausted",
               tone: :error,
               border_class: "border-l-error",
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "exhausted"],
               primary_window: ^primary,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_windows([primary], @as_of)

      assert_exact_keys(projection)
    end

    test "maps stale selected account evidence to stale" do
      primary = account_primary_window(freshness_state: "stale")

      assert %{
               state: "stale",
               label: "Quota refresh needed",
               tone: :warning,
               border_class: "border-l-warning",
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "not_fresh"],
               primary_window: ^primary,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_windows([primary], @as_of)

      assert_exact_keys(projection)
    end

    test "maps missing account-level windows to missing evidence" do
      projection = UpstreamQuotaReadiness.from_windows([], @as_of)

      assert %{
               state: "missing_evidence",
               label: "Quota missing",
               tone: :warning,
               border_class: "border-l-warning",
               routing_ready_now?: false,
               reason_codes: ["quota_evidence_missing"],
               primary_window: nil,
               weekly_window: nil
             } = projection

      assert_exact_keys(projection)
    end

    test "maps account reset-missing evidence to missing evidence" do
      primary = account_primary_window(reset_at: nil)

      assert %{
               state: "missing_evidence",
               label: "Quota missing",
               tone: :warning,
               border_class: "border-l-warning",
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "reset_missing"],
               primary_window: ^primary,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_windows([primary], @as_of)

      assert_exact_keys(projection)
    end

    test "maps unclassified account-level blockers to blocked" do
      primary = account_primary_window()

      auxiliary_blocker =
        account_primary_window(
          window_minutes: 60,
          quota_family: "auxiliary",
          freshness_state: "stale"
        )

      assert %{
               state: "blocked",
               label: "Quota blocked",
               tone: :warning,
               border_class: "border-l-warning",
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "not_fresh"],
               primary_window: ^primary,
               weekly_window: nil
             } =
               projection =
               UpstreamQuotaReadiness.from_windows([primary, auxiliary_blocker], @as_of)

      assert_exact_keys(projection)
    end

    test "ignores model-scoped and upstream-model-scoped windows for top-level readiness" do
      primary = account_primary_window()

      projection =
        UpstreamQuotaReadiness.from_windows(
          [
            primary,
            model_window(used_percent: Decimal.new("100")),
            upstream_model_window(used_percent: Decimal.new("100"))
          ],
          @as_of
        )

      assert %{
               state: "ready",
               reason_codes: [],
               primary_window: ^primary,
               weekly_window: nil
             } = projection

      assert_exact_keys(projection)
    end

    test "reports missing evidence when only non-account windows are present" do
      projection =
        UpstreamQuotaReadiness.from_windows(
          [
            model_window(),
            upstream_model_window()
          ],
          @as_of
        )

      assert %{
               state: "missing_evidence",
               label: "Quota missing",
               routing_ready_now?: false,
               reason_codes: ["quota_evidence_missing"],
               primary_window: nil,
               weekly_window: nil
             } = projection

      assert_exact_keys(projection)
    end

    test "weekly exhaustion wins after eligibility blocks" do
      primary = account_primary_window()
      weekly = account_weekly_window(used_percent: Decimal.new("100"))

      assert %{
               state: "exhausted",
               label: "Quota exhausted",
               tone: :error,
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "exhausted"],
               primary_window: ^primary,
               weekly_window: ^weekly
             } = projection = UpstreamQuotaReadiness.from_windows([primary, weekly], @as_of)

      assert_exact_keys(projection)
    end

    test "weekly-only exhaustion uses the runtime weekly exhaustion exclusion" do
      weekly = account_weekly_window(used_percent: Decimal.new("100"))

      assert %{
               state: "exhausted",
               label: "Quota exhausted",
               tone: :error,
               routing_ready_now?: false,
               reason_codes: ["quota_weekly_exhausted", "exhausted"],
               primary_window: nil,
               weekly_window: ^weekly
             } = projection = UpstreamQuotaReadiness.from_windows([weekly], @as_of)

      assert_exact_keys(projection)
    end
  end

  defp assert_exact_keys(projection) do
    assert MapSet.new(Map.keys(projection)) == @expected_keys
  end

  defp account_primary_window(attrs \\ []) do
    window(
      Keyword.merge(
        [
          quota_key: "account",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new("12"),
          reset_at: @future_reset,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh",
          observed_at: @as_of,
          last_sync_at: @as_of
        ],
        attrs
      )
    )
  end

  defp account_weekly_window(attrs \\ []) do
    window(
      Keyword.merge(
        [
          quota_key: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("12"),
          reset_at: @weekly_reset,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh",
          observed_at: @as_of,
          last_sync_at: @as_of
        ],
        attrs
      )
    )
  end

  defp model_window(attrs \\ []) do
    window(
      Keyword.merge(
        [
          quota_key: "sample_model",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new("12"),
          reset_at: @future_reset,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "sample-model",
          upstream_model: "sample-upstream-model",
          freshness_state: "fresh",
          observed_at: @as_of,
          last_sync_at: @as_of
        ],
        attrs
      )
    )
  end

  defp upstream_model_window(attrs \\ []) do
    window(
      Keyword.merge(
        [
          quota_key: "sample_upstream_model",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new("12"),
          reset_at: @future_reset,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "upstream_model",
          quota_family: "codex_model",
          upstream_model: "sample-upstream-model",
          freshness_state: "fresh",
          observed_at: @as_of,
          last_sync_at: @as_of
        ],
        attrs
      )
    )
  end

  defp window(attrs), do: struct!(AccountQuotaWindow, attrs)
end
