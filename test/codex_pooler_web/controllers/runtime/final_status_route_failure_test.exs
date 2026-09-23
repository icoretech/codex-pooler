defmodule CodexPoolerWeb.Runtime.FinalStatusRouteFailureTest do
  # An HTTP 5xx or 429 on a candidate that may still fail over records a route
  # failure (circuit and demotion) before the next candidate is tried. The last
  # candidate, and the compact route that never fails over, used to finalize
  # the same answer with no circuit call at all: a half-open probe it answered
  # stayed counted in flight and blocked the assignment until its lease ran
  # out, and a single-assignment Pool never opened its circuit on HTTP however
  # many 5xx it received (findings#254 row 254-50).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, gateway_setup: 2, native_text_input: 1, start_upstream: 1, stream_retry_setup: 2]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo

  for {status, reason} <- [{500, "upstream_5xx"}, {503, "upstream_5xx"}, {429, "upstream_rate_limited"}] do
    @tag status: status, reason: reason
    test "HTTP JSON: a final #{status} answering the half-open probe reopens the circuit and releases the probe", %{conn: conn, status: status, reason: reason} do
      upstream = start_upstream(FakeUpstream.strict_sequence([expect_status(status)]))
      setup = gateway_setup(upstream)
      circuit = half_open_circuit!(setup, "proxy_http")

      response = conn |> auth(setup) |> post("/backend-api/codex/responses", request_body(setup))
      assert response.status == status

      assert :ok = FakeUpstream.verify!(upstream)
      assert %{status: "open", reason_code: ^reason, failure_count: 2, metadata: %{"probe_in_flight_count" => 0}} = Repo.get!(RoutingCircuitState, circuit.id)
    end
  end

  test "HTTP SSE: a final 500 answering the half-open probe reopens the circuit and releases the probe", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.strict_sequence([expect_status(500)]))
    setup = gateway_setup(upstream)
    circuit = half_open_circuit!(setup, "proxy_stream")

    response = conn |> auth(setup) |> post("/backend-api/codex/responses", Map.put(request_body(setup), "stream", true))
    assert response.status == 500

    assert :ok = FakeUpstream.verify!(upstream)
    assert %{status: "open", reason_code: "upstream_5xx", failure_count: 2, metadata: %{"probe_in_flight_count" => 0}} = Repo.get!(RoutingCircuitState, circuit.id)
  end

  test "single-assignment Pool: consecutive final HTTP 500s open the circuit and the next turn is refused before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.strict_sequence(List.duplicate(expect_status(500), 3)))
    setup = gateway_setup(upstream)

    for attempt <- 1..3 do
      response = build_conn() |> auth(setup) |> post("/backend-api/codex/responses", request_body(setup))
      assert response.status == 500, "attempt #{attempt}"
    end

    assert [%{status: "open", reason_code: "upstream_5xx", failure_count: 3}] = circuits(setup, "proxy_http")
    assert [{"upstream_5xx", "active"}] = demotions(setup)

    refused = conn |> auth(setup) |> post("/backend-api/codex/responses", request_body(setup))
    assert refused.status == 503
    # Only the three failures reached the upstream; the fourth turn met an open
    # circuit on the only assignment.
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "last candidate: a final 500 after a failover records the failure on both assignments" do
    {setup, first_upstream, second_upstream} = stream_retry_setup(FakeUpstream.strict_sequence([expect_status(500)]), FakeUpstream.strict_sequence([expect_status(500)]))

    response = build_conn() |> auth(setup) |> post("/backend-api/codex/responses", request_body(setup))
    assert response.status == 500

    assert :ok = FakeUpstream.verify!(first_upstream)
    assert :ok = FakeUpstream.verify!(second_upstream)

    failures =
      Repo.all(
        from(circuit in RoutingCircuitState,
          where: circuit.pool_id == ^setup.pool.id and circuit.route_class == "proxy_http",
          select: {circuit.pool_upstream_assignment_id, circuit.reason_code, circuit.failure_count}
        )
      )

    assert Enum.sort(failures) == Enum.sort([{setup.assignment.id, "upstream_5xx", 1}, {setup.fallback_assignment.id, "upstream_5xx", 1}])
  end

  test "compact route: a 500 records a proxy_compact circuit failure", %{conn: conn} do
    upstream =
      start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses/compact", respond: {:json_error, 500, provider_error()})]))

    setup = gateway_setup(upstream, compact?: true)

    response = conn |> auth(setup) |> post("/backend-api/codex/responses/compact", request_body(setup))
    assert response.status == 500

    assert :ok = FakeUpstream.verify!(upstream)
    assert [%{status: "closed", reason_code: "upstream_5xx", failure_count: 1}] = circuits(setup, "proxy_compact")
  end

  defp expect_status(status), do: FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, status, provider_error()})

  defp provider_error, do: %{"error" => %{"type" => "server_error", "code" => "server_error", "message" => "synthetic upstream failure"}}

  defp circuits(setup, route_class) do
    Repo.all(from(circuit in RoutingCircuitState, where: circuit.pool_id == ^setup.pool.id and circuit.route_class == ^route_class))
  end

  defp demotions(setup) do
    Repo.all(from(demotion in BridgeDemotion, where: demotion.pool_upstream_assignment_id == ^setup.assignment.id, select: {demotion.reason_code, demotion.status}))
  end

  defp half_open_circuit!(setup, route_class) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RoutingCircuitState{
      pool_id: setup.pool.id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.assignment.upstream_identity_id,
      model_identifier: setup.model.exposed_model_id,
      route_class: route_class,
      status: "half_open",
      reason_code: "test_probe",
      failure_count: 1,
      success_count: 0,
      opened_at: DateTime.add(now, -120, :second),
      half_opened_at: now,
      metadata: %{"probe_in_flight_count" => 0},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp request_body(setup), do: %{"model" => setup.model.exposed_model_id, "input" => native_text_input("final status route failure")}
end
