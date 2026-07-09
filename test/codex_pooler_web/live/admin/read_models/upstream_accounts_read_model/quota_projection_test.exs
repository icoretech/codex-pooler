defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjectionTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  test "account quota rows prefer measured evidence over zero-capacity usage outliers" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(observed_at, 5, :hour),
        observed_at: DateTime.add(observed_at, 60, :second)
      )

    measured =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(observed_at, 2, :hour),
        observed_at: observed_at
      )

    primary =
      [outlier, measured]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
      |> Enum.find(&(&1.key == :primary_5h))

    assert Decimal.equal?(primary.percent, Decimal.new("94"))
    assert primary.percent_value == 94
    assert primary.percent_label == "94%"
  end

  test "account quota rows still show not reported when only zero-capacity evidence exists" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(observed_at, 5, :hour),
        observed_at: observed_at
      )

    primary =
      [outlier]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
      |> Enum.find(&(&1.key == :primary_5h))

    assert primary.percent == nil
    assert primary.percent_value == 0
    assert primary.percent_label == "not reported"
  end

  @tag :quota_spark_projection
  test "provider-observed zero-use Spark limits remain visible" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      [
        spark_window("primary", 300, observed_at),
        spark_window("secondary", 10_080, observed_at)
      ]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

    assert primary = Enum.find(rows, &(&1.key == "model-codex_spark-primary-300"))
    assert primary.label == "GPT-5.3-Codex-Spark 5h"
    assert Decimal.equal?(primary.percent, Decimal.new("100"))
    assert primary.percent_value == 100
    assert primary.percent_label == "100%"
    assert String.starts_with?(primary.reset_label, "in ")

    assert secondary = Enum.find(rows, &(&1.key == "model-codex_spark-secondary-10080"))
    assert secondary.label == "GPT-5.3-Codex-Spark Weekly"
    assert Decimal.equal?(secondary.percent, Decimal.new("100"))
    assert secondary.percent_value == 100
    assert secondary.percent_label == "100%"
    assert String.starts_with?(secondary.reset_label, "in ")
  end

  @tag :quota_spark_projection
  test "resetless inferred zero-use model evidence stays hidden" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      [
        spark_window("primary", 300, observed_at,
          reset_at: nil,
          source_precision: "inferred"
        )
      ]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

    refute Enum.any?(rows, &(&1.key == "model-codex_spark-primary-300"))
  end

  defp account_window(attrs) do
    observed_at = Keyword.fetch!(attrs, :observed_at)

    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "primary",
          window_minutes: 300,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          merge_precedence: 60,
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end

  defp spark_window(window_kind, window_minutes, observed_at, attrs \\ []) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "codex_spark",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          display_label: "GPT-5.3-Codex-Spark",
          limit_name: "GPT-5.3-Codex-Spark",
          metered_feature: "codex_bengalfox",
          window_kind: window_kind,
          window_minutes: window_minutes,
          active_limit: nil,
          credits: nil,
          used_percent: Decimal.new("0"),
          reset_at: DateTime.add(observed_at, window_minutes, :minute),
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          merge_precedence: 60,
          observed_at: observed_at,
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end
end
