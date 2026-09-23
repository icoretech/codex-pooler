defmodule CodexPoolerWeb.Runtime.HalfOpenProbeClientErrorTest do
  # A half-open circuit admits a bounded number of probes and blocks every
  # other turn on that assignment until each probe resolves (or its lease runs
  # out after `circuit_open_seconds`). A client error proves the upstream
  # answered: the native websocket resolves such a probe neutrally, and the
  # HTTP non-429 4xx path must do the same instead of leaving the probe counted
  # in flight, which kept the only assignment unroutable for the rest of the
  # lease (findings#254 row 254-32).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [assert_single_native_turn_terminal!: 2, collect_native_turn_frames!: 1, strict_native_request: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @param "input[0].content"

  test "HTTP JSON: a validation 400 answering the probe releases it and the next turn is admitted", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => provider_error("invalid_value")}}),
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.json_response(completed_json()))
        ])
      )

    setup = gateway_setup(upstream)
    circuit = half_open_circuit!(setup, "proxy_http")

    probe = conn |> auth(setup) |> post("/backend-api/codex/responses", request_body(setup))
    assert json_response(probe, 400)["error"]["code"] == "invalid_value"

    # Sent right away, well inside the probe lease: a probe still counted in
    # flight would make this turn meet no routable candidate.
    next = build_conn() |> auth(setup) |> post("/backend-api/codex/responses", request_body(setup))
    assert {next.status, json_response(next, next.status)["id"]} == {200, "resp_half_open_after_client_error"}

    assert :ok = FakeUpstream.verify!(upstream)
    assert %{status: "closed"} = Repo.get!(RoutingCircuitState, circuit.id)
    assert Repo.aggregate(BridgeDemotion, :count) == 0
  end

  test "HTTP SSE: a validation 400 answering the probe releases it", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => provider_error("string_above_max_length")}})
        ])
      )

    setup = gateway_setup(upstream)
    circuit = half_open_circuit!(setup, "proxy_stream")

    probe = conn |> auth(setup) |> post("/backend-api/codex/responses", Map.put(request_body(setup), "stream", true))
    assert json_response(probe, 400)["error"]["code"] == "string_above_max_length"

    assert :ok = FakeUpstream.verify!(upstream)
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert %{status: "half_open", failure_count: 1, metadata: %{"probe_in_flight_count" => 0}} = Repo.get!(RoutingCircuitState, circuit.id)
    assert Repo.aggregate(BridgeDemotion, :count) == 0
  end

  test "HTTP JSON: a 403 answering the probe releases it without a circuit failure", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 403, %{"error" => %{"type" => "invalid_request_error", "code" => "synthetic_forbidden", "message" => "m"}}})
        ])
      )

    setup = gateway_setup(upstream)
    circuit = half_open_circuit!(setup, "proxy_http")

    probe = conn |> auth(setup) |> post("/backend-api/codex/responses", request_body(setup))
    # The native answer is the Pooler-authored 400 naming the 403 (findings#254
    # row 254-80); route health still reads the provider's 403.
    assert probe.status == 400
    assert json_response(probe, 400)["error"]["message"] == "upstream rejected the request (synthetic_forbidden); upstream status 403"

    assert :ok = FakeUpstream.verify!(upstream)
    assert %{status: "half_open", failure_count: 1, metadata: %{"probe_in_flight_count" => 0}} = Repo.get!(RoutingCircuitState, circuit.id)
  end

  # Control: the websocket already resolved the probe this way (254-20 made the
  # validation codes health-neutral), so this arm is green before and after.
  test "native websocket: a validation 400 answering the probe releases it" do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "error", "status" => 400, "error" => provider_error("invalid_value")})]))
        ])
      )

    setup = gateway_setup(upstream)
    circuit = half_open_circuit!(setup, "proxy_websocket")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{request_id: "ws-half-open-probe-client-error", accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}
      })

    try do
      payload = CodexPooler.JSON.encode!(Map.merge(request_body(setup), %{"type" => "response.create", "stream" => true, "generate" => true}))

      assert {:ok, turn_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      {turn_state, frames} = collect_native_turn_frames!(turn_state)
      assert_single_native_turn_terminal!(frames, "error")

      assert :ok = FakeUpstream.verify!(upstream)
      assert %{status: "half_open", failure_count: 1, metadata: %{"probe_in_flight_count" => 0}} = Repo.get!(RoutingCircuitState, circuit.id)
      assert :ok = CodexResponsesSocket.terminate(:closed, turn_state)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
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

  defp request_body(setup), do: %{"model" => setup.model.exposed_model_id, "input" => native_text_input("half-open probe")}

  defp provider_error(code), do: %{"type" => "invalid_request_error", "code" => code, "message" => "Invalid '#{@param}'.", "param" => @param}

  defp completed_json do
    %{"id" => "resp_half_open_after_client_error", "object" => "response", "usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}}
  end
end
