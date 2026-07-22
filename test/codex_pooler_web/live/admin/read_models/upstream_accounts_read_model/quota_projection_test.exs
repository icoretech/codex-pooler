defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjectionTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  import CodexPooler.PoolerFixtures

  describe "identity observability projection" do
    test "newer success supersedes an older sibling failure" do
      now = ~U[2026-07-13 12:00:00Z]

      projection =
        identity_observability(
          now,
          [
            reconciliation_assignment("00000000-0000-0000-0000-000000000001", "failed", -600,
              code: "quota_refresh_failed",
              message: "safe fixture failure"
            ),
            reconciliation_assignment("00000000-0000-0000-0000-000000000002", "succeeded", -60)
          ]
        )

      assert projection.reconciliation.status == "succeeded"
      assert projection.reconciliation.code == nil
      assert projection.reconciliation.message == nil
      assert projection.reconciliation.finished_at == DateTime.add(now, -60, :second)
      assert projection.reconciliation.attempt_age == "1m ago"
    end

    test "newer failure supersedes an older sibling success and exposes only allowlisted text" do
      now = ~U[2026-07-13 12:00:00Z]
      raw_provider_body = "raw-provider-body-should-never-project"
      raw_exception = "** (RuntimeError) secret-bearing-exception"

      projection =
        identity_observability(
          now,
          [
            reconciliation_assignment("00000000-0000-0000-0000-000000000001", "succeeded", -600),
            reconciliation_assignment("00000000-0000-0000-0000-000000000002", "failed", -60,
              code: "quota_refresh_failed",
              message: raw_provider_body,
              details: %{"exception" => raw_exception}
            )
          ]
        )

      assert projection.reconciliation.status == "failed"
      assert projection.reconciliation.code == "quota_refresh_failed"
      assert projection.reconciliation.message == "quota refresh failed"
      refute inspect(projection) =~ raw_provider_body
      refute inspect(projection) =~ raw_exception
    end

    test "partial terminal result projects the first allowlisted failed step" do
      now = ~U[2026-07-13 12:00:00Z]

      projection =
        identity_observability(
          now,
          [
            reconciliation_assignment("00000000-0000-0000-0000-000000000001", "partial", -90,
              steps: [
                %{"status" => "succeeded", "code" => "health_refreshed", "message" => "ok"},
                %{
                  "status" => "failed",
                  "code" => "catalog_sync_failed",
                  "message" => "provider-specific failure"
                }
              ]
            )
          ]
        )

      assert projection.reconciliation.status == "partial"
      assert projection.reconciliation.code == "catalog_sync_failed"
      assert projection.reconciliation.message == "catalog sync failed"
    end

    test "deleted, malformed, unknown, and future terminal summaries cannot win" do
      now = ~U[2026-07-13 12:00:00Z]

      projection =
        identity_observability(
          now,
          [
            reconciliation_assignment("00000000-0000-0000-0000-000000000001", "failed", -120,
              code: "quota_refresh_unavailable"
            ),
            reconciliation_assignment("00000000-0000-0000-0000-000000000002", "succeeded", 60),
            reconciliation_assignment("00000000-0000-0000-0000-000000000003", "refreshing", -10),
            reconciliation_assignment("00000000-0000-0000-0000-000000000004", "failed", -5,
              finished_at: "malformed"
            ),
            reconciliation_assignment("00000000-0000-0000-0000-000000000005", "succeeded", -1,
              assignment_status: "deleted"
            )
          ]
        )

      assert projection.reconciliation.status == "failed"
      assert projection.reconciliation.code == "quota_refresh_unavailable"
      assert projection.reconciliation.finished_at == DateTime.add(now, -120, :second)
    end

    test "equal timestamps use assignment id descending as the deterministic winner" do
      now = ~U[2026-07-13 12:00:00Z]

      projection =
        identity_observability(
          now,
          [
            reconciliation_assignment("00000000-0000-0000-0000-000000000001", "failed", -60,
              code: "quota_refresh_failed"
            ),
            reconciliation_assignment("00000000-0000-0000-0000-000000000002", "succeeded", -60)
          ]
        )

      assert projection.reconciliation.status == "succeeded"
    end

    test "keeps attempt, successful refresh, evidence age, and credential expiry distinct" do
      now = ~U[2026-07-13 12:00:00Z]
      identity = active_upstream_identity_fixture()
      future_expiry = DateTime.add(now, 3_600, :second)
      past_expiry = DateTime.add(now, -3_600, :second)
      reconciliation = reconciliation_assignment(Ecto.UUID.generate(), "succeeded", -120)

      assignment =
        Map.put(reconciliation, :last_successful_refresh_at, DateTime.add(now, -300, :second))

      deleted_assignment =
        Ecto.UUID.generate()
        |> reconciliation_assignment("succeeded", -30, assignment_status: "deleted")
        |> Map.put(:last_successful_refresh_at, DateTime.add(now, -30, :second))

      windows = [account_window(observed_at: DateTime.add(now, -900, :second))]

      future =
        identity
        |> Map.put(:metadata, %{"access_token_expires_at" => DateTime.to_iso8601(future_expiry)})
        |> UpstreamAccountsReadModel.identity_observability(
          [assignment, deleted_assignment],
          windows,
          now
        )

      assert future.reconciliation.attempt_age == "2m ago"
      assert future.last_successful_quota_refresh_at == DateTime.add(now, -300, :second)
      assert future.last_successful_quota_refresh_age == "5m ago"
      assert future.quota_evidence_at == DateTime.add(now, -900, :second)
      assert future.quota_evidence_age == "15m ago"
      assert future.credential_expiry.state == "known_future"
      assert future.credential_expiry.expires_at == future_expiry
      assert future.credential_expiry.age == "in 1h"

      past =
        identity
        |> Map.put(:metadata, %{"access_token_expires_at" => DateTime.to_iso8601(past_expiry)})
        |> UpstreamAccountsReadModel.identity_observability([], [], now)

      assert past.credential_expiry.state == "known_past"
      assert past.credential_expiry.age == "1h ago"

      for metadata <- [%{}, %{"access_token_expires_at" => "malformed"}] do
        unavailable =
          identity
          |> Map.put(:metadata, metadata)
          |> UpstreamAccountsReadModel.identity_observability([], [], now)

        assert unavailable.credential_expiry == %{state: "unavailable", expires_at: nil, age: nil}
      end
    end
  end

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

  test "persisted terminal priming states override derived ready and weekly-only presentation" do
    for status <- ~w(failed blocked) do
      assignment = %{metadata: %{"quota_priming" => %{"status" => status}}}

      assert QuotaProjection.put_current_quota_priming(assignment, %{state: "ready"}).quota_priming_status ==
               status

      assert QuotaProjection.put_current_quota_priming(assignment, %{state: "weekly_only_probe"}).quota_priming_status ==
               status
    end
  end

  test "later persisted successful priming overrides an earlier terminal state" do
    assignment = %{metadata: %{"quota_priming" => %{"status" => "known"}}}

    projected = QuotaProjection.put_current_quota_priming(assignment, %{state: "ready"})

    assert projected.quota_priming_status == "known"
    assert projected.quota_priming_label == "Quota known"
  end

  test "missing or malformed priming metadata safely adopts healthy weekly-only presentation" do
    for assignment <- [
          %{},
          %{metadata: %{}},
          %{metadata: %{"quota_priming" => %{}}},
          %{metadata: %{"quota_priming" => "malformed"}}
        ] do
      projected =
        QuotaProjection.put_current_quota_priming(assignment, %{state: "weekly_only_probe"})

      assert projected.quota_priming_status == "weekly_only_probe"
      assert projected.quota_priming_label == "Weekly-only probe"
    end
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

  @tag :quota_reversible_provider_shape
  test "weekly-only projection removes 5h timers and restored provider evidence adds one per family" do
    identity = active_upstream_identity_fixture()
    restored_at = DateTime.utc_now() |> DateTime.truncate(:second)
    weekly_at = DateTime.add(restored_at, -60, :second)
    initial_at = DateTime.add(weekly_at, -3_600, :second)

    assert {:ok, _initial} =
             QuotaWindows.upsert_quota_windows(
               identity,
               provider_shape_window_attrs(initial_at, :full)
             )

    initial_rows = projected_rows(identity)
    assert_one_account_and_spark_window(initial_rows, "5h")
    assert_one_account_and_spark_window(initial_rows, "Weekly")

    assert {:ok, _weekly} =
             QuotaWindows.upsert_quota_windows(
               identity,
               provider_shape_window_attrs(weekly_at, :weekly_only)
             )

    weekly_rows = projected_rows(identity)
    assert account_5h_row(weekly_rows).percent == nil
    assert account_5h_row(weekly_rows).reset_label == nil
    refute Enum.any?(weekly_rows, &(&1.label == "GPT-5.3-Codex-Spark 5h"))
    assert_one_account_and_spark_window(weekly_rows, "Weekly")

    assert {:ok, _restored} =
             QuotaWindows.upsert_quota_windows(
               identity,
               provider_shape_window_attrs(restored_at, :primary_only, used_percent: "13")
             )

    restored_rows = projected_rows(identity)
    assert_one_account_and_spark_window(restored_rows, "5h")
    assert_one_account_and_spark_window(restored_rows, "Weekly")
    assert account_5h_row(restored_rows).reset_label != nil
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
  test "floating Spark weekly evidence projects starts-on-use semantics without an absolute reset" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      [
        spark_window("secondary", 10_080, observed_at,
          metadata: %{"reset_state" => "floating", "reset_after_seconds" => 604_800}
        )
      ]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

    assert weekly = Enum.find(rows, &(&1.key == "model-codex_spark-secondary-10080"))
    assert weekly.reset_semantics == :floating
    assert weekly.reset_label == "starts on use"
    assert weekly.reset_title == "provider reports a rolling seven-day window until use starts"
  end

  @tag :quota_spark_projection
  test "anchored Spark weekly evidence keeps the countdown and absolute reset title" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      [spark_window("secondary", 10_080, observed_at, metadata: %{"reset_state" => "anchored"})]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

    assert weekly = Enum.find(rows, &(&1.key == "model-codex_spark-secondary-10080"))
    assert weekly.reset_semantics == :anchored
    assert String.starts_with?(weekly.reset_label, "in ")
    assert String.starts_with?(weekly.reset_title, "resets ")
  end

  @tag :quota_spark_projection
  test "unknown Spark weekly reset state remains unreported" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      [spark_window("secondary", 10_080, observed_at, metadata: %{"reset_state" => "unknown"})]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))

    assert weekly = Enum.find(rows, &(&1.key == "model-codex_spark-secondary-10080"))
    assert weekly.reset_semantics == :unknown
    assert weekly.reset_label == nil
    assert weekly.reset_title == nil
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

  defp identity_observability(now, assignments) do
    active_upstream_identity_fixture()
    |> UpstreamAccountsReadModel.identity_observability(assignments, [], now)
  end

  defp reconciliation_assignment(id, status, offset_seconds, opts \\ []) do
    finished_at =
      Keyword.get(
        opts,
        :finished_at,
        DateTime.add(~U[2026-07-13 12:00:00Z], offset_seconds, :second)
      )

    steps =
      Keyword.get_lazy(opts, :steps, fn ->
        case Keyword.get(opts, :code) do
          nil ->
            []

          code ->
            [
              %{
                "status" => "failed",
                "code" => code,
                "message" => Keyword.get(opts, :message, "safe fixture message"),
                "details" => Keyword.get(opts, :details, %{})
              }
            ]
        end
      end)

    %{
      id: id,
      status: Keyword.get(opts, :assignment_status, "active"),
      last_successful_refresh_at: nil,
      metadata: %{
        "last_reconciliation" => %{
          "status" => status,
          "finished_at" => timestamp_value(finished_at),
          "steps" => steps
        }
      }
    }
  end

  defp timestamp_value(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp_value(value), do: value

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

  defp projected_rows(identity) do
    identity
    |> QuotaWindows.list_quota_windows()
    |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
  end

  defp account_5h_row(rows), do: Enum.find(rows, &(&1.key == :primary_5h))

  defp assert_one_account_and_spark_window(rows, label_suffix) do
    account_key = if label_suffix == "5h", do: :primary_5h, else: :weekly
    assert Enum.count(rows, &(&1.key == account_key and not is_nil(&1.percent))) == 1
    assert Enum.count(rows, &(&1.label == "GPT-5.3-Codex-Spark #{label_suffix}")) == 1
  end

  defp provider_shape_window_attrs(observed_at, shape, opts \\ []) do
    used_percent = Decimal.new(Keyword.get(opts, :used_percent, "12"))

    primary = [
      provider_shape_window("account", "primary", 300, observed_at, used_percent),
      provider_shape_window("codex_spark", "primary", 300, observed_at, used_percent)
    ]

    weekly = [
      provider_shape_window("account", "secondary", 10_080, observed_at, used_percent),
      provider_shape_window("codex_spark", "secondary", 10_080, observed_at, used_percent)
    ]

    case shape do
      :full -> primary ++ weekly
      :primary_only -> primary
      :weekly_only -> weekly
    end
  end

  defp provider_shape_window(quota_key, window_kind, window_minutes, observed_at, used_percent) do
    scope_attrs =
      if quota_key == "account" do
        %{quota_scope: "account", quota_family: "account"}
      else
        %{
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          display_label: "GPT-5.3-Codex-Spark",
          limit_name: "GPT-5.3-Codex-Spark",
          metered_feature: "codex_bengalfox"
        }
      end

    Map.merge(scope_attrs, %{
      quota_key: quota_key,
      window_kind: window_kind,
      window_minutes: window_minutes,
      used_percent: used_percent,
      reset_at: DateTime.add(observed_at, window_minutes, :minute),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      metadata: %{"limit_window_seconds" => window_minutes * 60}
    })
  end
end
