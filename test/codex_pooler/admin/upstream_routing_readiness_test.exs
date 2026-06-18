defmodule CodexPooler.Admin.UpstreamRoutingReadinessTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Admin.UpstreamRoutingReadiness
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @as_of ~U[2026-05-30 12:00:00Z]
  @future_reset ~U[2026-05-30 12:15:00Z]

  describe "from_inputs/3" do
    test "keeps active identities with fresh quota and healthy assignment routing-ready" do
      quota_readiness = fresh_quota_readiness()

      assert %{routing_ready_now?: true} = quota_readiness

      assert %{
               routing_ready_now?: true,
               label: "Routing ready",
               tone: :success,
               reason_code: "routing_ready",
               recovery_action: nil,
               quota_readiness: ^quota_readiness
             } =
               UpstreamRoutingReadiness.from_inputs(
                 identity("active"),
                 [healthy_assignment()],
                 quota_readiness
               )
    end

    test "blocks refresh_failed identities even when quota and assignment are otherwise ready" do
      quota_readiness = fresh_quota_readiness()

      assert %{
               routing_ready_now?: false,
               label: "Auth refresh failed",
               tone: :error,
               reason_code: "identity_refresh_failed",
               reason: reason,
               recovery_action: recovery_action,
               quota_readiness: ^quota_readiness
             } =
               UpstreamRoutingReadiness.from_inputs(
                 identity("refresh_failed"),
                 [healthy_assignment()],
                 quota_readiness
               )

      assert reason =~ "Token refresh failed"
      assert recovery_action =~ "Relink"
    end

    test "keeps refreshing identities model-routing-visible when quota and assignment are ready" do
      quota_readiness = fresh_quota_readiness()

      assert %{
               routing_ready_now?: true,
               label: "Routing while refreshing",
               tone: :warning,
               reason_code: "identity_refreshing_model_routable",
               quota_readiness: ^quota_readiness
             } =
               UpstreamRoutingReadiness.from_inputs(
                 identity("refreshing"),
                 healthy_assignment(),
                 quota_readiness
               )
    end

    test "blocks non-routable lifecycle statuses before quota readiness" do
      quota_readiness = fresh_quota_readiness()

      blocked_statuses = ~w(refresh_due reauth_required deleted disabled errored)

      for status <- blocked_statuses do
        assert %{
                 routing_ready_now?: false,
                 label: label,
                 reason_code: reason_code,
                 quota_readiness: ^quota_readiness
               } =
                 UpstreamRoutingReadiness.from_inputs(
                   identity(status),
                   [healthy_assignment()],
                   quota_readiness
                 )

        assert reason_code == "identity_#{status}"
        refute label == "Quota ready"
      end
    end

    test "blocks missing identity status and missing assignment input with sanitized reasons" do
      quota_readiness = fresh_quota_readiness()

      assert %{
               routing_ready_now?: false,
               label: "Identity unavailable",
               reason_code: "identity_unavailable",
               quota_readiness: ^quota_readiness
             } =
               UpstreamRoutingReadiness.from_inputs(nil, [healthy_assignment()], quota_readiness)

      assert %{
               routing_ready_now?: false,
               label: "Assignment unavailable",
               reason_code: "assignment_unavailable",
               quota_readiness: ^quota_readiness
             } = UpstreamRoutingReadiness.from_inputs(identity("active"), nil, quota_readiness)
    end

    test "requires a quota readiness projection" do
      assert_raise FunctionClauseError, fn ->
        UpstreamRoutingReadiness.from_inputs(
          identity("active"),
          [healthy_assignment()],
          invalid_quota_readiness()
        )
      end
    end

    test "keeps quota-only readiness blocked when lifecycle and assignment are ready" do
      quota_readiness = UpstreamQuotaReadiness.from_windows([], @as_of)

      assert %{
               routing_ready_now?: false,
               label: "Quota missing",
               tone: :warning,
               reason_code: "quota_missing_evidence",
               quota_readiness: ^quota_readiness
             } =
               UpstreamRoutingReadiness.from_inputs(
                 identity("active"),
                 [healthy_assignment()],
                 quota_readiness
               )
    end
  end

  defp fresh_quota_readiness do
    [account_primary_window()]
    |> UpstreamQuotaReadiness.from_windows(@as_of)
  end

  defp invalid_quota_readiness do
    nil
    |> :erlang.term_to_binary()
    |> :erlang.binary_to_term()
  end

  defp account_primary_window do
    struct!(AccountQuotaWindow,
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
    )
  end

  defp identity(status) do
    %UpstreamIdentity{status: status}
  end

  defp healthy_assignment do
    %PoolUpstreamAssignment{
      status: "active",
      health_status: "active",
      eligibility_status: "eligible"
    }
  end
end
