defmodule CodexPooler.Gateway.Routing.QuotaRefresh.ExecutorTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, prime_stale_routing_quota!: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.Executor
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "refresh failures stay best-effort and return the structured quota error" do
    upstream = start_upstream(FakeUpstream.json_response(%{}))
    setup = gateway_setup(upstream, quota?: false)
    prime_stale_routing_quota!(setup.identity)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    bad_assignment = %{setup.assignment | id: "not-a-uuid"}
    payload = %{"model" => setup.model.exposed_model_id, "input" => "stale quota"}

    request_options =
      RequestOptions.build(
        %{upstream_endpoint: "/backend-api/codex/responses"},
        "/backend-api/codex/responses",
        payload
      )

    filter_input =
      CandidateEligibility.FilterInput.new(%{
        auth: auth,
        model: setup.model,
        endpoint: "/backend-api/codex/responses",
        payload: payload,
        request_options: request_options,
        candidates: [{bad_assignment, setup.identity}]
      })

    assert {:refreshable_quota, plan} =
             CandidateEligibility.filter_quota_eligible_candidates(filter_input)

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  code: "quota_evidence_unavailable",
                  quota_refresh_attempted: true
                }} = Executor.refresh_stale_candidates(plan)
      end)

    assert log =~ "quota refresh skipped"
    assert log =~ "assignment_id=not-a-uuid"
    refute log =~ setup.raw_key
  end

  test "refresh replaces quota rows and timestamp together instead of reusing the old instant" do
    upstream = start_upstream(FakeUpstream.json_response(%{}))
    setup = gateway_setup(upstream, quota?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "refresh quota snapshot"}

    request_options =
      RequestOptions.build(
        %{upstream_endpoint: "/backend-api/codex/responses"},
        "/backend-api/codex/responses",
        payload
      )

    candidate = {setup.assignment, setup.identity}

    filter_input =
      CandidateEligibility.FilterInput.new(%{
        auth: auth,
        model: setup.model,
        endpoint: "/backend-api/codex/responses",
        payload: payload,
        request_options: request_options,
        candidates: [candidate]
      })

    old_snapshot_at = ~U[2026-07-25 12:00:00.000000Z]

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [candidate],
        circuit_snapshots: %{setup.assignment.id => true}
      })
      |> RouteState.put_quota_window_snapshot(%{setup.identity.id => []}, old_snapshot_at)

    refresh_plan = %{
      filter_input: filter_input,
      route_state: route_state,
      candidate_exclusions: [],
      refreshable_candidates: []
    }

    assert {:ok, [^candidate], _decision, refreshed_route_state} =
             Executor.refresh_stale_candidates(refresh_plan)

    assert %DateTime{} = refreshed_route_state.quota_snapshot_at
    assert DateTime.compare(refreshed_route_state.quota_snapshot_at, old_snapshot_at) == :gt

    assert refreshed_route_state.quota_window_snapshots ==
             QuotaWindows.list_quota_windows_by_identity_ids(
               [setup.identity.id],
               refreshed_route_state.quota_snapshot_at
             )

    assert refreshed_route_state.visible_model == route_state.visible_model
    assert refreshed_route_state.circuit_snapshots == route_state.circuit_snapshots
  end
end
