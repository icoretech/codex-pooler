defmodule CodexPooler.Admin.UpstreamQuotaReadinessTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Admin.UpstreamRoutingReadiness
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.{AccountAvailabilityStore, AccountQuotaWindow}
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot

  @as_of ~U[2026-05-30 12:00:00Z]
  @future_reset ~U[2026-05-30 12:15:00Z]
  @weekly_reset ~U[2026-06-06 12:00:00Z]
  @monthly_reset ~U[2026-06-29 12:00:00Z]
  @expected_keys MapSet.new([
                   :state,
                   :label,
                   :tone,
                   :routing_ready_now?,
                   :reason_codes,
                   :primary_window,
                   :primary_30d_window,
                   :weekly_window
                 ])

  describe "from_windows/2" do
    test "requires the trusted snapshot timestamp" do
      refute function_exported?(UpstreamQuotaReadiness, :from_windows, 1)
    end

    test "uses the supplied snapshot for freshness and reset expiry boundaries" do
      ttl = Evidence.freshness_ttl_seconds()

      fresh =
        account_primary_window(
          observed_at: DateTime.add(@as_of, -ttl + 1, :second),
          last_sync_at: DateTime.add(@as_of, -ttl + 1, :second)
        )

      ttl_equal =
        account_primary_window(
          observed_at: DateTime.add(@as_of, -ttl, :second),
          last_sync_at: DateTime.add(@as_of, -ttl, :second)
        )

      stale =
        account_primary_window(
          observed_at: DateTime.add(@as_of, -ttl - 1, :second),
          last_sync_at: DateTime.add(@as_of, -ttl - 1, :second)
        )

      reset_expired = account_primary_window(reset_at: @as_of)

      assert UpstreamQuotaReadiness.from_windows([fresh], @as_of).state == "ready"
      assert UpstreamQuotaReadiness.from_windows([ttl_equal], @as_of).state == "ready"
      assert UpstreamQuotaReadiness.from_windows([stale], @as_of).state == "stale"

      assert %{
               state: "stale",
               reason_codes: reason_codes
             } = UpstreamQuotaReadiness.from_windows([reset_expired], @as_of)

      assert "expired" in reason_codes
    end

    test "maps precise account quota eligibility to ready" do
      primary = account_primary_window()

      assert %{
               state: "ready",
               label: "Quota ready",
               tone: :success,
               routing_ready_now?: true,
               reason_codes: [],
               primary_window: ^primary,
               primary_30d_window: nil,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_windows([primary], @as_of)

      assert_exact_keys(projection)
    end

    test "maps fresh reset-bearing monthly account primary evidence to ready" do
      monthly = account_monthly_primary_window()

      assert %{
               state: "ready",
               label: "Quota ready",
               tone: :success,
               routing_ready_now?: true,
               reason_codes: [],
               primary_window: ^monthly,
               primary_30d_window: ^monthly,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_windows([monthly], @as_of)

      assert_exact_keys(projection)
    end

    test "maps weekly-only probe eligibility to warning readiness that can still route" do
      weekly = account_weekly_window()

      assert %{
               state: "weekly_only_probe",
               label: "Weekly quota probe",
               tone: :warning,
               routing_ready_now?: true,
               reason_codes: ["quota_account_primary_unknown"],
               primary_window: nil,
               primary_30d_window: nil,
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
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "exhausted"],
               primary_window: ^primary,
               primary_30d_window: nil,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_windows([primary], @as_of)

      assert_exact_keys(projection)
    end

    test "maps unusable monthly primary evidence to blocked states without false readiness" do
      exhausted = account_monthly_primary_window(used_percent: Decimal.new("100"))
      stale = account_monthly_primary_window(freshness_state: "stale")
      resetless = account_monthly_primary_window(reset_at: nil)

      assert %{
               state: "exhausted",
               label: "Quota exhausted",
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "exhausted"],
               primary_window: ^exhausted,
               primary_30d_window: ^exhausted
             } = UpstreamQuotaReadiness.from_windows([exhausted], @as_of)

      assert %{
               state: "stale",
               label: "Quota refresh needed",
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "not_fresh"],
               primary_window: ^stale,
               primary_30d_window: ^stale
             } = UpstreamQuotaReadiness.from_windows([stale], @as_of)

      assert %{
               state: "missing_evidence",
               label: "Quota missing",
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "reset_missing"],
               primary_window: ^resetless,
               primary_30d_window: ^resetless
             } = UpstreamQuotaReadiness.from_windows([resetless], @as_of)
    end

    test "maps stale selected account evidence to stale" do
      primary = account_primary_window(freshness_state: "stale")

      assert %{
               state: "stale",
               label: "Quota refresh needed",
               tone: :warning,
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "not_fresh"],
               primary_window: ^primary,
               primary_30d_window: nil,
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
               routing_ready_now?: false,
               reason_codes: ["quota_evidence_missing"],
               primary_window: nil,
               primary_30d_window: nil,
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
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "reset_missing"],
               primary_window: ^primary,
               primary_30d_window: nil,
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
               routing_ready_now?: false,
               reason_codes: ["quota_window_unusable", "not_fresh"],
               primary_window: ^primary,
               primary_30d_window: nil,
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
               primary_30d_window: nil,
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
               primary_30d_window: nil,
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
               primary_30d_window: nil,
               weekly_window: ^weekly
             } = projection = UpstreamQuotaReadiness.from_windows([primary, weekly], @as_of)

      assert_exact_keys(projection)
    end

    test "selects measured account primary evidence over a zero-capacity usage outlier" do
      outlier =
        account_primary_window(
          active_limit: 0,
          credits: 0,
          used_percent: Decimal.new("0"),
          reset_at: DateTime.add(@as_of, 5, :hour),
          observed_at: DateTime.add(@as_of, 60, :second)
        )

      measured =
        account_primary_window(
          active_limit: 0,
          credits: 0,
          used_percent: Decimal.new("6"),
          reset_at: DateTime.add(@as_of, 2, :hour)
        )

      assert %{
               state: "ready",
               routing_ready_now?: true,
               primary_window: ^measured
             } = UpstreamQuotaReadiness.from_windows([outlier, measured], @as_of)
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
               primary_30d_window: nil,
               weekly_window: ^weekly
             } = projection = UpstreamQuotaReadiness.from_windows([weekly], @as_of)

      assert_exact_keys(projection)
    end
  end

  describe "from_snapshot/1" do
    test "maps fresh provider availability without windows to warning readiness" do
      pool = pool_fixture()

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          identity_metadata: %{
            "credential_epoch" => 1,
            AccountAvailabilityStore.metadata_key() =>
              AccountAvailabilityStore.encode!(:available, @as_of, 1)
          }
        })

      snapshot = RoutingQuotaSnapshot.from_identity(identity, [], @as_of)

      assert %{
               state: "provider_available_no_windows",
               label: "Provider available",
               tone: :warning,
               routing_ready_now?: true,
               reason_codes: [],
               primary_window: nil,
               primary_30d_window: nil,
               weekly_window: nil
             } = projection = UpstreamQuotaReadiness.from_snapshot(snapshot)

      assert_exact_keys(projection)

      routing =
        UpstreamRoutingReadiness.from_inputs(
          identity,
          %{status: "active", health_status: "active", eligibility_status: "eligible"},
          projection
        )

      assert routing.state == "provider_available_no_windows"
      assert routing.label == "Provider available"
      assert routing.tone == :warning
      assert routing.routing_ready_now?
    end

    test "keeps blocked unknown expired and credential-mismatched snapshots fail closed" do
      for {state, observed_at, epoch, expected_state} <- [
            {:blocked, @as_of, 1, "blocked"},
            {:unknown, @as_of, 1, "missing_evidence"},
            {:available, DateTime.add(@as_of, -(Evidence.freshness_ttl_seconds() + 1), :second),
             1, "missing_evidence"},
            {:available, @as_of, 2, "missing_evidence"}
          ] do
        pool = pool_fixture()

        %{identity: identity} =
          upstream_assignment_fixture(pool, %{
            identity_metadata: %{
              "credential_epoch" => 1,
              AccountAvailabilityStore.metadata_key() =>
                AccountAvailabilityStore.encode!(state, observed_at, epoch)
            }
          })

        projection =
          identity
          |> RoutingQuotaSnapshot.from_identity([], @as_of)
          |> UpstreamQuotaReadiness.from_snapshot()

        assert projection.state == expected_state
        refute projection.routing_ready_now?
        assert_exact_keys(projection)
      end
    end

    test "account-only readiness ignores unrelated model exhaustion without hiding it from snapshot" do
      pool = pool_fixture()

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          identity_metadata: %{
            "credential_epoch" => 1,
            AccountAvailabilityStore.metadata_key() =>
              AccountAvailabilityStore.encode!(:available, @as_of, 1)
          }
        })

      model_blocker = model_window(used_percent: Decimal.new("100"))
      snapshot = RoutingQuotaSnapshot.from_identity(identity, [model_blocker], @as_of)
      projection = UpstreamQuotaReadiness.from_snapshot(snapshot)

      assert projection.state == "provider_available_no_windows"
      assert projection.routing_ready_now?
      assert snapshot.raw_windows == [model_blocker]
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

  defp account_monthly_primary_window(attrs \\ []) do
    account_primary_window(
      Keyword.merge(
        [
          window_minutes: 43_200,
          used_percent: Decimal.new("42.5"),
          reset_at: @monthly_reset
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
