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

  describe "assignment_routing_ready?/1" do
    test "accepts active, healthy, eligible assignment structs and maps only" do
      assert UpstreamRoutingReadiness.assignment_routing_ready?(healthy_assignment())

      assert UpstreamRoutingReadiness.assignment_routing_ready?(%{
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

      assert UpstreamRoutingReadiness.assignment_routing_ready?(%{
               "status" => "active",
               "health_status" => "active",
               "eligibility_status" => "eligible"
             })

      refute UpstreamRoutingReadiness.assignment_routing_ready?(%{
               status: "disabled",
               health_status: "active",
               eligibility_status: "eligible"
             })

      refute UpstreamRoutingReadiness.assignment_routing_ready?(%{
               status: "active",
               health_status: "degraded",
               eligibility_status: "eligible"
             })

      refute UpstreamRoutingReadiness.assignment_routing_ready?(%{
               status: "active",
               health_status: "active",
               eligibility_status: "ineligible"
             })

      refute UpstreamRoutingReadiness.assignment_routing_ready?(%{status: "active"})
      refute UpstreamRoutingReadiness.assignment_routing_ready?(nil)
    end
  end

  describe "with_circuit_visibility/2" do
    test "overlays blocked and recovering circuit evidence onto ready verdicts without changing base fields" do
      quota_readiness = fresh_quota_readiness()

      ready =
        UpstreamRoutingReadiness.from_inputs(
          identity("active"),
          healthy_assignment(),
          quota_readiness
        )

      ready_refreshing =
        UpstreamRoutingReadiness.from_inputs(
          identity("refreshing"),
          healthy_assignment(),
          quota_readiness
        )

      expected_by_circuit_state = %{
        :blocked => %{
          state: "circuit_protection_active",
          label: "Circuit protection active",
          tone: :error,
          reason:
            "One or more model and route lanes are blocked; unaffected routes may remain available.",
          reason_code: "circuit_routes_blocked",
          recovery_action:
            "Wait for circuit protection to clear before relying on affected routes."
        },
        :recovering => %{
          state: "circuit_recovering",
          label: "Circuit recovery in progress",
          tone: :warning,
          reason:
            "One or more model and route lanes are recovering; unaffected routes may remain available.",
          reason_code: "circuit_recovering",
          recovery_action:
            "Wait for circuit recovery to complete before relying on affected routes."
        }
      }

      for base_readiness <- [ready, ready_refreshing],
          circuit_state <- [:blocked, :recovering] do
        result =
          UpstreamRoutingReadiness.with_circuit_visibility(
            base_readiness,
            circuit_summary(circuit_state)
          )

        assert Map.take(result, Map.keys(expected_by_circuit_state[circuit_state])) ==
                 expected_by_circuit_state[circuit_state]

        assert result.routing_ready_now?

        assert Map.drop(result, Map.keys(expected_by_circuit_state[circuit_state])) ==
                 Map.drop(base_readiness, Map.keys(expected_by_circuit_state[circuit_state]))
      end
    end

    test "preserves false lifecycle, assignment, and quota verdicts despite circuit evidence" do
      fresh_quota = fresh_quota_readiness()
      blocked_quota = UpstreamQuotaReadiness.from_windows([], @as_of)

      base_readinesses = [
        UpstreamRoutingReadiness.from_inputs(
          identity("disabled"),
          healthy_assignment(),
          fresh_quota
        ),
        UpstreamRoutingReadiness.from_inputs(identity("active"), nil, fresh_quota),
        UpstreamRoutingReadiness.from_inputs(
          identity("active"),
          healthy_assignment(),
          blocked_quota
        )
      ]

      for base_readiness <- base_readinesses,
          circuit_state <- [:blocked, :recovering] do
        assert UpstreamRoutingReadiness.with_circuit_visibility(
                 base_readiness,
                 circuit_summary(circuit_state)
               ) === base_readiness
      end
    end

    test "returns the exact base verdict for clear circuit evidence" do
      base_readiness =
        UpstreamRoutingReadiness.from_inputs(
          identity("active"),
          [healthy_assignment()],
          fresh_quota_readiness()
        )

      assert UpstreamRoutingReadiness.with_circuit_visibility(
               base_readiness,
               circuit_summary(:closed)
             ) === base_readiness
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

  defp circuit_summary(state) do
    %{
      state: state,
      ready?: state != :blocked,
      tone: if(state == :blocked, do: :error, else: :warning),
      label: "Circuit fixture",
      detail: "Circuit fixture detail",
      blocked_lane_count: if(state == :blocked, do: 1, else: 0),
      recovering_lane_count: if(state == :recovering, do: 1, else: 0),
      affected_lane_count: if(state == :closed, do: 0, else: 1),
      blocked_reasons: [],
      representative: nil
    }
  end
end
