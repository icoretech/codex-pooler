defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetConfirmationProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetConfirmationProjection
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetOperationProjection
  alias CodexPoolerWeb.DateTimeDisplay

  test "monthly quota is the challenged window, never the five-hour window" do
    now = ~U[2026-07-14 03:30:00.000000Z]

    monthly = %AccountQuotaWindow{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "primary",
      window_minutes: 43_200,
      source: "codex_usage_api",
      source_precision: "observed",
      used_percent: Decimal.new("100"),
      observed_at: now,
      last_sync_at: now,
      reset_at: DateTime.add(now, 20, :day),
      freshness_state: "fresh",
      metadata: %{}
    }

    # A usable five-hour window beside the exhausted monthly one would read `:usable` if it were challenged.
    primary = %{monthly | window_minutes: 300, used_percent: Decimal.new("10")}

    result =
      SavedResetConfirmationProjection.project(
        %{"phase" => "consumed_pending_probe", "included_window_descriptors" => [%{"window_kind" => "primary", "window_minutes" => 43_200}], "consumed_at" => DateTime.to_iso8601(now)},
        [monthly, primary],
        [monthly, primary],
        now
      )

    assert result.challenged_evidence_state == :exhausted
  end

  @now ~U[2026-10-05 12:00:00Z]
  @consumed_at DateTime.add(@now, -4, :minute)

  test "retained_old_cycle_new_report uses the candidate clock without accepting its cycle" do
    for {kind, minutes, key} <- [{"secondary", 10_080, :weekly}, {"primary", 43_200, :primary_30d}] do
      retained = candidate_window(kind, minutes)
      confirmation = project(retained)
      readiness = QuotaProjection.readiness([retained], @now)

      assert confirmation.challenged_evidence_state == :candidate_progressing
      refute readiness.routing_ready_now?

      operation =
        SavedResetOperationProjection.project(%{
          redemption: redemption(),
          confirmation: confirmation,
          serving_readiness: readiness,
          snapshot_at: @now,
          datetime_preferences: DateTimeDisplay.preferences_for_user(nil)
        })

      assert operation.verification == :candidate
      assert operation.serving_readiness == readiness

      rows = QuotaProjection.quota_limit_rows([retained], DateTimeDisplay.preferences_for_user(nil), @now, [retained], redemption())
      row = Enum.find(rows, &(&1.key == key))
      assert row.percent_label == "0%"
      assert row.reset_at == retained.reset_at
      assert row.evidence_state == :fresh
      assert row.saved_reset_context.label == "Last verified quota"
      assert row.saved_reset_context.candidate_label == "New quota report awaiting verification"
      assert row.saved_reset_context.role == :last_verified
      assert row.saved_reset_context.candidate_role == :unconfirmed_report
      assert hd(row.observations).pending_measurement.role == :unconfirmed_report
      assert hd(row.observations).saved_reset_context == row.saved_reset_context
      assert hd(row.observations).freshness == "fresh"
      assert Enum.all?(Enum.reject(rows, &(&1.key == key)), &(Map.get(&1, :saved_reset_context) == nil))
    end
  end

  test "candidate_display_refuses_bad_evidence without fabricating readiness" do
    base = %{candidate_window("secondary", 10_080) | observed_at: DateTime.add(@now, -2, :minute)}

    mutate_candidate = fn window, key, value ->
      put_in(window.metadata["__quota_confirmed_candidate_v1"][key], value)
    end

    invalid = [
      {:pre_consume, candidate_window("secondary", 10_080, DateTime.add(@consumed_at, -1, :second))},
      {:future, candidate_window("secondary", 10_080, DateTime.add(@now, 1, :second))},
      {:stale, candidate_window("secondary", 10_080, DateTime.add(@now, -16, :minute))},
      {:malformed_candidate, put_in(base.metadata["__quota_confirmed_candidate_v1"], [])},
      {:malformed_status, put_in(base.metadata["__quota_candidate_provider_status_v1"], [])},
      {:version, mutate_candidate.(base, "version", 2)},
      {:percent, mutate_candidate.(base, "used_percent", "invalid")},
      {:expired_reset, mutate_candidate.(base, "reset_at", DateTime.to_iso8601(@now))},
      {:unsafe_provider, put_in(base.metadata["__quota_candidate_provider_status_v1"]["allowed"], false)},
      {:status_clock, put_in(base.metadata["__quota_candidate_provider_status_v1"]["observed_at"], DateTime.to_iso8601(@now))},
      {:unknown_source, %{base | source: "private-source-sentinel"}},
      {:unknown_precision, %{base | source_precision: "unknown"}},
      {:model, %{base | quota_key: "model", quota_scope: "model", model: "sample-model"}},
      {:five_hour, %{base | window_kind: "primary", window_minutes: 300}},
      {:additional, %{base | quota_key: "additional", quota_scope: "feature"}},
      {:wrong_family, %{base | quota_family: "other"}},
      {:missing_clock, %{base | observed_at: nil}},
      {:future_canonical, %{base | observed_at: DateTime.add(@now, 1, :second)}}
    ]

    for {scenario, retained} <- invalid do
      confirmation = project(retained)
      refute confirmation.challenged_evidence_state == :candidate_progressing, inspect(scenario)
      refute QuotaProjection.readiness([retained], @now).routing_ready_now?, inspect(scenario)
      assert retained.used_percent == Decimal.new(100)
      rows = QuotaProjection.quota_limit_rows([retained], DateTimeDisplay.preferences_for_user(nil), @now, [retained], redemption())
      assert Enum.all?(rows, &(get_in(&1, [:saved_reset_context, :candidate?]) != true)), inspect(scenario)
    end
  end

  test "retained quota context requires a post-consume lifecycle and stays separate from generic pending measurements" do
    retained = candidate_window("secondary", 10_080)
    preferences = DateTimeDisplay.preferences_for_user(nil)

    for lifecycle <- [%{}, %{redemption() | "phase" => "confirmed_by_quota"}, %{redemption() | "consumed_at" => "invalid"}] do
      rows = QuotaProjection.quota_limit_rows([retained], preferences, @now, [retained], lifecycle)
      assert Enum.all?(rows, &(Map.get(&1, :saved_reset_context) == nil))
    end

    preconsume = candidate_window("secondary", 10_080, DateTime.add(@consumed_at, -1, :second))
    row = QuotaProjection.quota_limit_rows([preconsume], preferences, @now, [preconsume], redemption()) |> Enum.find(&(&1.key == :weekly))
    assert row.saved_reset_context.label == "Last verified quota"
    refute row.saved_reset_context.candidate?
    assert row.saved_reset_context.candidate_label == nil
  end

  test "a fresh measure remains generic when the receipt covers another descriptor or has passed its confirmation window" do
    weekly = candidate_window("secondary", 10_080)
    monthly = candidate_window("primary", 43_200)
    preferences = DateTimeDisplay.preferences_for_user(nil)

    for {window, other_kind, other_minutes} <- [{weekly, "primary", 43_200}, {monthly, "secondary", 10_080}] do
      for receipt <- [
            Map.put(redemption(), "included_window_descriptors", [%{"window_kind" => other_kind, "window_minutes" => other_minutes}]),
            Map.put(redemption(), "consumed_at", DateTime.to_iso8601(DateTime.add(@now, -1, :day)))
          ] do
        [row] = QuotaProjection.quota_limit_rows([window], preferences, @now, [window], receipt) |> Enum.filter(&(&1.percent != nil))
        assert row.pending_quota_measurement.reported == "68%"
        refute Map.has_key?(row, :saved_reset_context)
        assert SavedResetConfirmationProjection.project(receipt, [window], [window], @now).challenged_evidence_state == :absent
      end
    end
  end

  test "the current receipt challenges only its bound window across raw and effective source selection" do
    monthly = %{candidate_window("primary", 43_200) | metadata: %{}, observed_at: @consumed_at}
    weekly = %{candidate_window("secondary", 10_080) | metadata: %{}, used_percent: Decimal.new(30), observed_at: @now}
    windows = [monthly, weekly]
    project = fn receipt -> SavedResetConfirmationProjection.project(receipt, windows, windows, @now).challenged_evidence_state end

    assert project.(Map.put(redemption(), "included_window_descriptors", [%{"window_kind" => "primary", "window_minutes" => 43_200}])) == :exhausted
    assert project.(Map.put(redemption(), "included_window_descriptors", [%{"window_kind" => "secondary", "window_minutes" => 10_080}])) == :usable
    assert project.(Map.delete(redemption(), "included_window_descriptors")) == :absent
    assert project.(Map.put(redemption(), "phase", "expired")) == :absent
  end

  defp project(window), do: SavedResetConfirmationProjection.project(redemption(), [window], [window], @now)

  defp redemption do
    %{"phase" => "consumed_pending_probe", "included_window_descriptors" => [%{"window_kind" => "secondary", "window_minutes" => 10_080}, %{"window_kind" => "primary", "window_minutes" => 43_200}], "consumed_at" => DateTime.to_iso8601(@consumed_at), "result" => %{"applied" => true, "code" => "reset"}}
  end

  defp candidate_window(kind, minutes, candidate_at \\ DateTime.add(@now, -2, :minute)) do
    observed_at = DateTime.add(@now, -6, :minute)
    reset_at = DateTime.add(@now, 6, :day)

    attrs = %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: kind,
      window_minutes: minutes,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      reset_at: reset_at,
      merge_precedence: 60,
      used_percent: Decimal.new(100),
      metadata: %{}
    }

    evidence = struct!(Evidence, %{attrs | used_percent: Decimal.new(32), observed_at: candidate_at, last_sync_at: candidate_at, metadata: %{"rate_limit_allowed" => true, "rate_limit_reached" => false}})
    struct!(AccountQuotaWindow, %{attrs | metadata: EvidenceStore.put_candidate(%{}, evidence)})
  end
end
