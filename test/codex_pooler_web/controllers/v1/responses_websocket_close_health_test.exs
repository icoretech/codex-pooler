defmodule CodexPoolerWeb.V1.ResponsesWebsocketCloseHealthTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, CodexSession, RoutingCircuitState}
  alias CodexPooler.Repo

  @moduletag capture_log: true

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  for mode <- ["full", "lite"], half_open <- [false, true] do
    test "#{mode} half_open=#{half_open}: bridged peer Close1009 settles once and releases route admission", %{conn: conn} do
      assert_bridge_close_health!(conn, unquote(mode), unquote(half_open))
    end
  end

  defp assert_bridge_close_health!(conn, mode, half_open) do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.websocket_close(code: 1009)),
          strict_native_request(2, completed_response_frames("resp_after_bridge_size_close", [], 3, 1))
        ])
      )

    other = start_upstream(completed_response_frames("resp_unexpected_other", [], 3, 1))
    {setup, _second} = websocket_failover_candidates!(upstream, other, mode)

    on_exit(fn ->
      Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id, select: s.id))
      |> Enum.each(&stop_websocket_owner_session/1)
    end)

    circuit =
      if half_open do
        setup
        |> half_open_websocket_circuit!(setup.assignment)
        |> Ecto.Changeset.change(route_class: "proxy_stream")
        |> Repo.update!()
      end

    response = post_stream(conn, setup)
    assert response.status == 200
    assert response.resp_body =~ "event: error"
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert {request.status, request.last_error_code, request.retry_count} == {"failed", "upstream_stream_error", 0}
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert {attempt.status, attempt.transport, attempt.network_error_code} == {"failed", "websocket", "upstream_stream_error"}
    assert %{"phase" => "upstream_close", "termination_source" => "peer_close_frame", "peer_close_code" => 1009, "upstream_committed" => true} = attempt.response_metadata["transport_failure"]
    assert [settlement] = Repo.all(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement"))
    assert settlement.attempt_id == attempt.id
    assert {request.usage_status, attempt.usage_status, settlement.usage_status} == {"usage_unknown", "usage_unknown", "usage_unknown"}
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(other) == 0
    assert FakeUpstream.http_request_count(upstream) == 0

    if half_open do
      assert %RoutingCircuitState{status: "half_open", failure_count: 1, metadata: %{"probe_in_flight_count" => 0}} = Repo.get!(RoutingCircuitState, circuit.id)
    else
      assert route_circuit_failures(setup.assignment.id) == []
    end

    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_upstream_assignment_id == ^setup.assignment.id))

    CodexPooler.TestDiagnostics.puts(fn ->
      CodexPooler.JSON.encode!(%{scenario: "bridged_http_peer_close1009", mode: mode, half_open: half_open, topology: "one_node_owner", request_status: request.status, request_code: request.last_error_code, usage_status: settlement.usage_status, attempt_count: 1, settlement_count: 1, upstream_committed: attempt.response_metadata["transport_failure"]["upstream_committed"], primary_requests: FakeUpstream.count(upstream), other_requests: FakeUpstream.count(other), circuit_failures: Enum.map(route_circuit_failures(setup.assignment.id), fn {reason, count} -> %{reason: reason, count: count} end), probe_in_flight: if(circuit, do: Repo.get!(RoutingCircuitState, circuit.id).metadata["probe_in_flight_count"]), demotion_count: Repo.aggregate(from(d in BridgeDemotion, where: d.pool_upstream_assignment_id == ^setup.assignment.id), :count)})
    end)

    response = post_stream(conn, setup)
    assert response.status == 200
    assert response.resp_body =~ "event: response.completed"
    assert FakeUpstream.http_request_count(upstream) == 0
    assert :ok = FakeUpstream.verify!(upstream)
    assert FakeUpstream.count(other) == 0
  end

  defp post_stream(conn, setup) do
    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("x-session-id", Ecto.UUID.generate())
    |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic close health", "stream" => true})
  end
end
