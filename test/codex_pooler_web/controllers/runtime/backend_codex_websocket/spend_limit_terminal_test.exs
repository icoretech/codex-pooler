defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.SpendLimitTerminalTest do
  # The latest released Codex client treats `credit_balance_exhausted`,
  # `organization_spend_limit_exceeded` and `project_spend_limit_exceeded` as a
  # final quota error, like `insufficient_quota` (findings#258 row 258-02). A
  # `response.incomplete` naming one of them is a failed turn, and like
  # `insufficient_quota` it demotes the assignment: the account cannot serve
  # until its spend or credit changes (findings#258 row 258-24). They used to
  # settle as an ordinary incomplete response.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [execute_websocket_response: 4]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo

  for code <- ~w(credit_balance_exhausted organization_spend_limit_exceeded project_spend_limit_exceeded insufficient_quota) do
    @tag spend_code: code
    test "native websocket response.incomplete #{code} fails the turn and demotes the assignment", %{spend_code: code} do
      upstream = start_upstream(incomplete_stream(code))
      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "spend-#{code}"})

      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic spend limit"),
          "stream" => true,
          "generate" => true
        })

      assert :ok = execute_websocket_response(auth, payload, %{request_id: "ws-spend-#{code}", codex_session: session}, fn frame -> send(self(), {:websocket_frame, frame}) end)
      assert_received {:websocket_frame, frame}
      assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(frame)

      assert_failed_and_demoted!(setup, code, "websocket", "proxy_websocket")
    end

    @tag spend_code: code
    test "native HTTP SSE response.incomplete #{code} fails the turn and demotes the assignment", %{conn: conn, spend_code: code} do
      upstream = start_upstream(incomplete_stream(code))
      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic spend limit"), "stream" => true})

      assert response.status == 200
      assert response.resp_body =~ "response.failed"

      assert_failed_and_demoted!(setup, code, "http_sse", "proxy_stream")
    end
  end

  defp incomplete_stream(code) do
    FakeUpstream.sse_stream(
      [
        {"response.incomplete",
         %{
           "type" => "response.incomplete",
           "response" => %{
             "id" => "resp_spend_#{code}",
             "status" => "incomplete",
             "incomplete_details" => %{"reason" => code},
             "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
           }
         }}
      ],
      done: false
    )
  end

  defp assert_failed_and_demoted!(setup, code, transport, route_class) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

    assert {request.status, request.transport, request.last_error_code} == {"failed", transport, code}
    assert get_in(request.request_metadata, ["routing", "demotion_reason"]) == code
    assert Repo.all(from(demotion in BridgeDemotion, select: {demotion.pool_upstream_assignment_id, demotion.reason_code})) == [{setup.assignment.id, code}]

    assert Repo.all(from(circuit in RoutingCircuitState, select: {circuit.route_class, circuit.reason_code, circuit.failure_count})) == [{route_class, code, 1}]
  end
end
