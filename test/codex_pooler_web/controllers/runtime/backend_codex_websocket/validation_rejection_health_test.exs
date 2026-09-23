defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ValidationRejectionHealthTest do
  # A provider parameter-validation refusal is the client's error, not the
  # account's: the HTTP path answers the 400 and leaves route health alone,
  # and a native websocket turn refused with the same code must do the same.
  # `invalid_value`, `invalid_type` and `string_above_max_length` used to be
  # missing from the health-neutral codes, so the websocket terminal demoted
  # the assignment and recorded a circuit failure for a request no account
  # could have served (findings#254 row 254-20).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [assert_single_native_turn_terminal!: 2, collect_native_turn_frames!: 1, stop_registered_websocket_owner_sessions: 0, strict_native_request: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Runtime.Finalization.ValidationRejection
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @provider_sentinel "private-ws-validation-health-sentinel"
  @prompt_sentinel "private-ws-validation-health-prompt"
  @param "input[0].content"

  test "every relayable validation code is health-neutral" do
    for code <- ValidationRejection.relayable_codes() do
      assert ErrorCodes.health_neutral_error_code?(code), "#{code} would demote the route on a websocket terminal"
    end
  end

  for code <- ~w(invalid_value invalid_type string_above_max_length unsupported_value) do
    @tag validation_code: code
    test "native HTTP SSE 400 #{code} leaves route health untouched", %{conn: conn, validation_code: code} do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => provider_error(code)}})
          ])
        )

      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true})

      assert response.status == 400
      assert json_response(response, 400)["error"]["code"] == code

      {request, attempt} = sole_rows!(setup)
      assert request.status == "failed"
      assert attempt.transport == "http_sse"
      assert_route_health_untouched!(request)
    end

    for topology <- [:direct, :local_owner] do
      @tag validation_code: code, topology: topology
      test "native websocket #{topology} provider 400 #{code} leaves route health untouched", %{validation_code: code, topology: topology} do
        if topology == :local_owner, do: enable_owner_forwarding!()

        upstream =
          start_upstream(
            FakeUpstream.strict_sequence([
              strict_native_request(1, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "error", "status" => 400, "error" => provider_error(code)})]))
            ])
          )

        setup = gateway_setup(upstream)
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

        {:ok, state} =
          CodexResponsesSocket.init(%{
            auth: auth,
            opts: %{request_id: "ws-validation-health-#{code}-#{topology}", accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}
          })

        try do
          payload =
            CodexPooler.JSON.encode!(%{
              "type" => "response.create",
              "model" => setup.model.exposed_model_id,
              "input" => native_text_input(@prompt_sentinel),
              "stream" => true,
              "generate" => true
            })

          assert {:ok, turn_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          {turn_state, frames} = collect_native_turn_frames!(turn_state)
          terminal = assert_single_native_turn_terminal!(frames, "response.failed")
          assert terminal["response"]["error"]["code"] == code

          assert :ok = FakeUpstream.verify!(upstream)
          {request, attempt} = sole_rows!(setup)
          assert request.status == "failed"
          assert request.last_error_code == code
          assert attempt.transport == "websocket"

          # The native socket relays the refusal as its canonical
          # `response.failed`; the attempt still records the rejection fields the
          # HTTP path records for the same provider response (findings#254 row
          # 254-30).
          assert Map.take(attempt.response_metadata, ["rejection_error_code", "rejection_error_type", "rejection_error_param"]) == %{
                   "rejection_error_code" => code,
                   "rejection_error_type" => "invalid_request_error",
                   "rejection_error_param" => @param
                 }

          assert_route_health_untouched!(request)
          assert :ok = CodexResponsesSocket.terminate(:closed, turn_state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end
    end
  end

  defp provider_error(code) do
    %{"type" => "invalid_request_error", "code" => code, "message" => "Invalid '#{@param}': '#{@provider_sentinel}'.", "param" => @param}
  end

  defp assert_route_health_untouched!(request) do
    health = %{
      demotion_reason: get_in(request.request_metadata, ["routing", "demotion_reason"]),
      demotions: Repo.all(from(demotion in BridgeDemotion, select: {demotion.reason_code, demotion.status})),
      circuits: Repo.all(from(circuit in RoutingCircuitState, select: {circuit.route_class, circuit.reason_code, circuit.failure_count}))
    }

    assert health == %{demotion_reason: nil, demotions: [], circuits: []}
  end

  defp sole_rows!(setup) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    {request, attempt}
  end

  defp enable_owner_forwarding! do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    on_exit(&stop_registered_websocket_owner_sessions/0)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
  end
end
