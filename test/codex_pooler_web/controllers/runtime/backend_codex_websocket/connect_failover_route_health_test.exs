defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ConnectFailoverRouteHealthTest do
  # A websocket connect-phase failure fails over to the next route candidate
  # through the empty-body retry clause of the failed-websocket finalization
  # (findings#208). The failed candidate's route health is recorded there as on
  # the last candidate and on HTTP: a probe it claimed on a half-open circuit
  # resolves as a failed probe instead of staying counted in flight until the
  # staleness self-heal, and a closed circuit counts the failure (findings#325
  # row 325-4). The refusal is real (a kernel-refused loopback port) and the
  # next candidate serves the turn, on the direct path and through an owner
  # session. An upstream close after the payload was written no longer fails
  # over (row 325-6, `committed_close_settles_test.exs`).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [owner_socket: 3, pool_attempts: 1, receive_owner_socket_push: 1, request_logs: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @shapes [{:refused_connect, :half_open}, {:refused_connect, :closed}]

  for mode <- ["full", "lite"], {shape, circuit} <- @shapes do
    @mode mode
    @shape shape
    @circuit circuit
    @tag :websocket_connect_failover
    test "#{mode}: #{shape} on a #{circuit} first candidate fails over and records the failure on that candidate" do
      {setup, served_by, refused_circuit} = failing_then_served!(@shape, @mode, @circuit, "direct")
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert :ok =
               execute_websocket_response(
                 auth,
                 turn_payload(setup, "direct #{@mode} #{@shape} #{@circuit}"),
                 %{request_id: "ws-connect-failover-#{@mode}-#{@shape}-#{@circuit}", connect_timeout_ms: 2_000},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_received {:websocket_frame, frame}
      assert CodexPooler.JSON.decode!(frame)["id"] == "resp_connect_failover_direct"
      assert_failed_over!(setup, served_by, refused_circuit, @mode, @shape, @circuit)
    end
  end

  for mode <- ["full", "lite"], {shape, circuit} <- @shapes do
    @mode mode
    @shape shape
    @circuit circuit
    @tag :websocket_connect_failover
    test "#{mode}: owner-forwarded #{shape} on a #{circuit} first candidate fails over and records the failure on that candidate" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

      {setup, served_by, refused_circuit} = failing_then_served!(@shape, @mode, @circuit, "owner")
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      turn_state = "owner-connect-failover-#{@mode}-#{@shape}-#{@circuit}"
      {:ok, state} = owner_socket(auth, "ws-#{turn_state}", turn_state)

      try do
        assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
        assert {:ok, state} = CodexResponsesSocket.handle_in({turn_payload(setup, "owner #{@mode} #{@shape} #{@circuit}"), [opcode: :text]}, state)
        assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
        assert CodexPooler.JSON.decode!(frame)["id"] == "resp_connect_failover_owner"
        assert {:ok, _state} = receive_socket_done(state)
        assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
        assert [request] = request_logs(setup.pool.id)
        assert request.request_metadata["websocket_owner_forwarding"]["owner_instance_id"] == Atom.to_string(node())
        assert_failed_over!(setup, served_by, refused_circuit, @mode, @shape, @circuit)
      after
        CodexResponsesSocket.terminate(:closed, state)
      end
    end
  end

  # The preferred candidate fails with nothing received; the second one is
  # healthy and carries the ordering demotion that keeps the first preferred.
  defp failing_then_served!(shape, mode, circuit, marker) do
    # Strict: the healthy candidate serves the turn on its first connection,
    # once.
    served =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "id" => "resp_connect_failover_#{marker}",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              })
            ])
          )
        ])
      )

    # Keep the healthy listener bound before reserving the refused endpoint.
    # `reserve_closed_port!/0` closes its probe socket; allocating the healthy
    # listener afterwards leaves a TOCTOU window in which the OS can reuse the
    # supposedly refused port and bypass the connect-failover arm.
    failing = failing_upstream(shape)
    assert URI.parse(FakeUpstream.url(served)).port != URI.parse(failing.url).port

    {setup, second} = websocket_failover_candidates!(failing, served, mode)
    refused_circuit = if circuit == :half_open, do: half_open_websocket_circuit!(setup, setup.assignment)
    {setup, {second, served}, refused_circuit}
  end

  # A kernel-refused loopback port: the connect fails before anything is sent.
  defp failing_upstream(:refused_connect), do: %FakeUpstream{url: "http://127.0.0.1:#{reserve_closed_port!()}"}

  defp expected_transport_failure(:refused_connect), do: %{"phase" => "connect", "reason" => "econnrefused", "upstream_committed" => false}

  defp assert_failed_over!(setup, {second, served}, refused_circuit, mode, shape, circuit) do
    assert [request] = Repo.all(from(r in CodexPooler.Accounting.Request, where: r.pool_id == ^setup.pool.id))
    assert {request.status, request.last_error_code} == {"succeeded", nil}
    assert request.request_metadata["routing"]["model_serving_mode"] == mode

    assert [first_attempt, second_attempt] = pool_attempts(setup.pool.id)
    assert {first_attempt.pool_upstream_assignment_id, first_attempt.status} == {setup.assignment.id, "retryable_failed"}

    assert Map.take(first_attempt.response_metadata["transport_failure"], ~w(phase reason upstream_committed)) == expected_transport_failure(shape)
    assert {second_attempt.pool_upstream_assignment_id, second_attempt.status} == {second.assignment.id, "succeeded"}
    assert :ok = FakeUpstream.verify!(served)

    case circuit do
      # The probe this turn claimed resolved as a failed probe: the circuit
      # opens again with no probe left in flight.
      :half_open ->
        assert %RoutingCircuitState{status: "open", reason_code: "upstream_stream_error", failure_count: 2, metadata: %{"probe_in_flight_count" => 0}} =
                 Repo.get!(RoutingCircuitState, refused_circuit.id)

      # The failure is counted toward the threshold.
      :closed ->
        assert route_circuit_failures(setup.assignment.id) == [{"upstream_stream_error", 1}]
    end

    # The route failure demotes the refused assignment as well; the candidate
    # that served the turn keeps only the ordering demotion the setup gave it.
    assert Repo.exists?(from(d in BridgeDemotion, where: d.pool_upstream_assignment_id == ^setup.assignment.id and d.reason_code == "upstream_stream_error"))
    assert route_circuit_failures(second.assignment.id) == []
  end

  defp turn_payload(setup, marker) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("connect failover #{marker}"),
      "stream" => true,
      "generate" => true
    })
  end
end
