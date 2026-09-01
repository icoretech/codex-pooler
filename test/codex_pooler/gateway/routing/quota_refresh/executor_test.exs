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
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
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
      |> put_test_quota_snapshots(%{setup.identity.id => []}, old_snapshot_at)

    refresh_plan = %{
      filter_input: filter_input,
      route_state: route_state,
      candidate_exclusions: [],
      refreshable_candidates: []
    }

    assert {:ok, [^candidate], _decision, refreshed_route_state} =
             Executor.refresh_stale_candidates(refresh_plan)

    refreshed_at =
      RouteState.quota_snapshot_for_identity(refreshed_route_state, setup.identity).as_of

    assert %DateTime{} = refreshed_at
    assert DateTime.compare(refreshed_at, old_snapshot_at) == :gt

    assert refreshed_route_state.quota_snapshots ==
             QuotaWindows.load_routing_quota_snapshots(
               [setup.identity.id],
               refreshed_at
             )

    assert refreshed_route_state.visible_model == route_state.visible_model
    assert refreshed_route_state.circuit_snapshots == route_state.circuit_snapshots
    assert refreshed_route_state.saved_reset_auto_cohort == route_state.saved_reset_auto_cohort
  end

  test "stale provider availability refreshes once into a fresh windowless candidate" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "plan_type" => "plus",
          "rate_limit" => %{
            "allowed" => true,
            "limit_reached" => false,
            "primary_window" => nil,
            "secondary_window" => nil
          }
        })
      )

    setup = gateway_setup(upstream, quota?: false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_at = DateTime.add(now, -Evidence.freshness_ttl_seconds() - 1, :second)

    identity =
      setup.identity
      |> Ecto.Changeset.change(
        metadata:
          Map.put(
            setup.identity.metadata,
            AccountAvailabilityStore.metadata_key(),
            AccountAvailabilityStore.encode!(:available, stale_at, 1)
          )
      )
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "refresh availability"}

    request_options =
      RequestOptions.build(
        %{upstream_endpoint: "/backend-api/codex/responses"},
        "/backend-api/codex/responses",
        payload
      )

    candidate = {setup.assignment, identity}

    filter_input =
      CandidateEligibility.FilterInput.new(%{
        auth: auth,
        model: setup.model,
        endpoint: "/backend-api/codex/responses",
        payload: payload,
        request_options: request_options,
        candidates: [candidate]
      })

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [candidate],
        circuit_snapshots: %{setup.assignment.id => true}
      })
      |> RouteState.put_quota_snapshots(
        QuotaWindows.load_routing_quota_snapshots([identity.id], now)
      )

    assert {:refreshable_quota, refresh_plan} =
             CandidateEligibility.filter_quota_eligible_candidates(filter_input, route_state)

    assert refresh_plan.refreshable_candidates == [candidate]

    assert {:ok, [^candidate], decision, refreshed_route_state} =
             Executor.refresh_stale_candidates(refresh_plan)

    assert decision["routing_state"] == "windowless_provider_available"
    assert decision["windowless_provider_available_candidate_count"] == 1
    assert decision["refreshed_stale_quota"] == true

    refreshed_snapshot = RouteState.quota_snapshot_for_identity(refreshed_route_state, identity)
    assert refreshed_snapshot.raw_windows == []
    assert refreshed_snapshot.availability.state == :available
    assert DateTime.compare(refreshed_snapshot.availability.observed_at, stale_at) == :gt
  end

  defp put_test_quota_snapshots(route_state, windows_by_identity_id, as_of) do
    identities =
      Map.new(route_state.candidates, fn {_assignment, identity} -> {identity.id, identity} end)

    snapshots =
      Map.new(windows_by_identity_id, fn {identity_id, windows} ->
        {identity_id,
         RoutingQuotaSnapshot.from_identity(Map.fetch!(identities, identity_id), windows, as_of)}
      end)

    RouteState.put_quota_snapshots(route_state, snapshots)
  end
end
