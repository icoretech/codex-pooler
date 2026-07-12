defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjectionTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  import CodexPooler.PoolerFixtures

  @tag :quota_spark_projection
  test "legacy weekly-duration primary Spark rows fold into one persisted Spark Weekly row" do
    identity = active_upstream_identity_fixture()
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    weekly_reset_at = DateTime.add(observed_at, 6, :day)

    # legacy row shape written by pre-remap releases (or by a not-yet-upgraded
    # replica during a rolling update); no purge migration runs in this test
    legacy_attrs =
      spark_persisted_attrs("primary", 10_080,
        used_percent: Decimal.new("40"),
        reset_at: weekly_reset_at,
        source: "codex_response_headers",
        observed_at: DateTime.add(observed_at, -120, :second)
      )

    normalized_attrs =
      spark_persisted_attrs("secondary", 10_080,
        used_percent: Decimal.new("40"),
        reset_at: weekly_reset_at,
        source: "codex_usage_api",
        observed_at: observed_at
      )

    assert {:ok, [_first]} = QuotaWindows.upsert_quota_windows(identity, [legacy_attrs])
    assert {:ok, [_second]} = QuotaWindows.upsert_quota_windows(identity, [normalized_attrs])

    rows =
      identity
      |> QuotaWindows.list_quota_windows()
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

    spark_rows = Enum.filter(rows, &String.starts_with?(&1.label, "GPT-5.3-Codex-Spark"))

    assert [weekly_row] = spark_rows
    assert weekly_row.label == "GPT-5.3-Codex-Spark Weekly"
    assert weekly_row.key == "model-codex_spark-secondary-10080"
  end

  @tag :quota_spark_projection
  test "stale runtime 5h evidence renders no card or timer beside fresh weekly evidence" do
    identity = active_upstream_identity_fixture()
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    frozen_observed_at = DateTime.add(observed_at, -2 * 3600, :second)
    weekly_reset_at = DateTime.add(observed_at, 6, :day)

    # frozen runtime-sourced 5h rows: reconciliation never deletes these, so
    # only read-side superseded rejection can keep them off operator cards
    frozen_account_5h = %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("58"),
      reset_at: DateTime.add(frozen_observed_at, 10_800, :second),
      source: "codex_response_headers",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: frozen_observed_at,
      observed_at: frozen_observed_at
    }

    frozen_spark_5h =
      spark_persisted_attrs("primary", 300,
        used_percent: Decimal.new("58"),
        reset_at: DateTime.add(frozen_observed_at, 10_800, :second),
        source: "codex_response_headers",
        observed_at: frozen_observed_at
      )

    fresh_account_weekly = %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("1"),
      reset_at: weekly_reset_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at
    }

    fresh_spark_weekly =
      spark_persisted_attrs("secondary", 10_080,
        used_percent: Decimal.new("0"),
        reset_at: weekly_reset_at,
        source: "codex_usage_api",
        observed_at: observed_at
      )

    for attrs <- [frozen_account_5h, frozen_spark_5h, fresh_account_weekly, fresh_spark_weekly] do
      assert {:ok, [_row]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
    end

    rows =
      identity
      |> QuotaWindows.list_quota_windows()
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

    primary_5h = Enum.find(rows, &(&1.key == :primary_5h))
    assert primary_5h.percent == nil
    assert primary_5h.percent_label == "not reported"
    assert primary_5h.reset_label == nil

    weekly = Enum.find(rows, &(&1.key == :weekly))
    assert weekly.percent_label != "not reported"

    spark_rows = Enum.filter(rows, &String.starts_with?(&1.label, "GPT-5.3-Codex-Spark"))
    assert [spark_weekly] = spark_rows
    assert spark_weekly.label == "GPT-5.3-Codex-Spark Weekly"
  end

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

  @tag :quota_account_projection
  test "provider-observed zero-use account limits remain visible" do
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

    assert Decimal.equal?(primary.percent, Decimal.new("100"))
    assert primary.percent_value == 100
    assert primary.percent_label == "100%"
    assert String.starts_with?(primary.reset_label, "in ")
  end

  @tag :quota_account_projection
  test "provider-observed zero-use account limits remain visible across runtime sources" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for source <- ~w(codex_rate_limit_event codex_response_headers codex_rate_limit_error) do
      primary =
        [
          account_window(
            active_limit: 0,
            credits: 0,
            used_percent: Decimal.new("0"),
            reset_at: DateTime.add(observed_at, 5, :hour),
            source: source,
            observed_at: observed_at
          )
        ]
        |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
        |> Enum.find(&(&1.key == :primary_5h))

      assert Decimal.equal?(primary.percent, Decimal.new("100")), source
      assert primary.percent_value == 100, source
      assert primary.percent_label == "100%", source
      assert String.starts_with?(primary.reset_label, "in "), source
    end
  end

  @tag :quota_account_projection
  test "resetless inferred zero-use account evidence stays unreported" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: nil,
        source_precision: "inferred",
        observed_at: observed_at
      )

    primary =
      [row]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
      |> Enum.find(&(&1.key == :primary_5h))

    assert primary.percent == nil
    assert primary.percent_value == 0
    assert primary.percent_label == "not reported"
    assert primary.reset_label == nil
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
  test "provider-observed zero-use Spark limits remain visible across runtime sources" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for source <- ~w(codex_rate_limit_event codex_response_headers codex_rate_limit_error) do
      rows =
        [spark_window("primary", 300, observed_at, source: source)]
        |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

      assert primary = Enum.find(rows, &(&1.key == "model-codex_spark-primary-300"))
      assert Decimal.equal?(primary.percent, Decimal.new("100")), source
      assert primary.percent_value == 100, source
      assert primary.percent_label == "100%", source
      assert String.starts_with?(primary.reset_label, "in "), source
    end
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

  defp spark_persisted_attrs(window_kind, window_minutes, attrs) do
    observed_at = Keyword.fetch!(attrs, :observed_at)

    Map.merge(
      %{
        quota_key: "codex_spark",
        quota_scope: "model",
        quota_family: "codex_model",
        model: "gpt-5.3-codex-spark",
        display_label: "GPT-5.3-Codex-Spark",
        limit_name: "GPT-5.3-Codex-Spark",
        metered_feature: "codex_bengalfox",
        window_kind: window_kind,
        window_minutes: window_minutes,
        source_precision: "observed",
        freshness_state: "fresh",
        last_sync_at: observed_at
      },
      Map.new(attrs)
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
