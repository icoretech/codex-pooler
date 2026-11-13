defmodule CodexPoolerWeb.Runtime.SessionBudgetTerminalTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, strict_native_request: 2, collect_native_turn_frames!: 1, assert_single_native_turn_terminal!: 2]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo

  @moduletag capture_log: true

  for mode <- ["full", "lite"], route <- ["/backend-api/codex/responses", "/v1/responses"], stream? <- [false, true] do
    test "#{mode} #{route} stream=#{stream?} keeps a session budget refusal health neutral", %{conn: conn} do
      assert_http_budget!(conn, unquote(mode), unquote(route), unquote(stream?))
    end
  end

  for mode <- ["full", "lite"], kind <- ["error", "response.failed"] do
    test "#{mode} SSE #{kind} does not demote a healthy account", %{conn: conn} do
      assert_sse_budget!(conn, unquote(mode), unquote(kind))
    end
  end

  for mode <- ["full", "lite"], owner? <- [false, true], kind <- ["wrapped400", "error", "response.failed"] do
    test "#{mode} websocket owner=#{owner?} #{kind} preserves terminal session budget health" do
      assert_websocket_budget!(unquote(mode), unquote(owner?), unquote(kind))
    end
  end

  for mode <- ["full", "lite"], owner? <- [false, true], kind <- ["incomplete", "type-only"] do
    test "#{mode} websocket owner=#{owner?} #{kind} does not gain session budget authority" do
      assert_websocket_budget!(unquote(mode), unquote(owner?), unquote(kind), false)
    end
  end

  for mode <- ["full", "lite"], kind <- ["error", "response.failed", "wrapped500", "incomplete", "type-only"] do
    test "#{mode} public SSE bridge #{kind} uses original budget authority", %{conn: conn} do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
      upstream = start_upstream(FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(budget_event(unquote(kind)))]))
      setup = gateway_setup(upstream)
      set_model_serving_mode!(model_serving_scope(), setup, unquote(mode))
      response = conn |> auth(setup) |> put_req_header("session-id", Ecto.UUID.generate()) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "stream" => true})
      assert response.status == 200
      assert FakeUpstream.http_request_count(upstream) == 0
      assert FakeUpstream.count(upstream) == 1
      assert_settled_budget!(setup, "budget_reached", unquote(kind) in ["error", "response.failed"])
    end
  end

  defp assert_http_budget!(conn, mode, route, stream?) do
    upstream = start_upstream(FakeUpstream.json_response(%{"error" => %{"type" => "invalid_request_error", "code" => "budget_reached", "message" => "synthetic budget detail"}}, 400))
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    conn = conn |> auth(setup) |> post(route, %{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic input"), "stream" => stream?})
    assert %{"error" => error} = json_response(conn, 400)
    if route == "/backend-api/codex/responses", do: assert(error["code"] == "budget_reached")
    refute conn.resp_body =~ "synthetic budget detail"
    assert FakeUpstream.count(upstream) == 1
    assert_settled_budget!(setup, "upstream_status")
  end

  defp assert_sse_budget!(conn, mode, kind) do
    upstream = start_upstream(FakeUpstream.sse_stream([budget_event(kind)], done: false))
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    conn = conn |> auth(setup) |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic input"), "stream" => true})
    assert conn.status == 200
    assert conn.resp_body =~ "budget_reached"
    assert FakeUpstream.count(upstream) == 1
    assert_settled_budget!(setup)
  end

  defp assert_websocket_budget!(mode, owner?, kind, neutral? \\ true) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, owner?)
    upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(budget_event(kind))]))]))
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    {:ok, auth} = CodexPooler.Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = CodexPoolerWeb.CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: Ecto.UUID.generate(), accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}})
    socket_state_key = make_ref()
    Process.put(socket_state_key, state)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic input"), "stream" => true, "generate" => true})
      assert {:ok, turn_state} = CodexPoolerWeb.CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      Process.put(socket_state_key, turn_state)
      {turn_state, frames} = collect_native_turn_frames!(turn_state)
      Process.put(socket_state_key, turn_state)
      event = if kind == "wrapped400", do: "error", else: "response.failed"
      terminal = assert_single_native_turn_terminal!(frames, event)
      assert get_in(terminal, ["response", "error", "code"]) == "budget_reached" or get_in(terminal, ["error", "code"]) == "budget_reached"
      assert :ok = FakeUpstream.verify!(upstream)
      assert_settled_budget!(setup, "budget_reached", neutral?)
    after
      CodexPoolerWeb.CodexResponsesSocket.terminate(:closed, Process.delete(socket_state_key))
    end
  end

  defp budget_event("wrapped500"), do: Map.put(budget_event("error"), "status", 500)
  defp budget_event("incomplete"), do: %{"type" => "response.incomplete", "response" => %{"status" => "incomplete", "error" => %{"code" => "budget_reached", "message" => "Synthetic nonbudget terminal."}}}
  defp budget_event("type-only"), do: %{"type" => "error", "error" => %{"type" => "budget_reached", "message" => "Synthetic type-only terminal."}}
  defp budget_event("response.failed"), do: %{"type" => "response.failed", "response" => %{"status" => "failed", "error" => %{"code" => "budget_reached", "message" => "Synthetic session budget."}}}
  defp budget_event(kind), do: %{"type" => "error", "error" => %{"code" => "budget_reached", "message" => "Synthetic session budget."}} |> then(&if kind == "wrapped400", do: Map.put(&1, "status", 400), else: &1)

  defp assert_settled_budget!(setup, code \\ "budget_reached", neutral? \\ true) do
    assert [%Request{id: id, status: "failed", last_error_code: ^code}] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [%Attempt{response_metadata: metadata}] = Repo.all(from(a in Attempt, where: a.request_id == ^id))
    assert metadata["session_budget_terminal"] == true == (neutral? and code == "budget_reached")
    assert [%Attempt{status: "failed"}] = Repo.all(from(a in Attempt, where: a.request_id == ^id))
    assert Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id)) == not neutral?
    assert Repo.exists?(from(c in RoutingCircuitState, where: c.pool_id == ^setup.pool.id)) == not neutral?
  end
end
