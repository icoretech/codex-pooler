defmodule CodexPoolerWeb.Runtime.RequestPolicyTerminalTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, strict_native_request: 2, collect_native_turn_frames!: 1, assert_single_native_turn_terminal!: 2]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @moduletag capture_log: true
  @codes ~w(inference_hook_denied content_policy_violation invalid_access_program unsupported_access_program access_program_not_enabled)

  for mode <- ["full", "lite"], code <- @codes, type <- ["error", "response.failed"] do
    test "#{mode} SSE #{type} #{code} settles without account demotion", %{conn: conn} do
      code = unquote(code)
      upstream = start_upstream(FakeUpstream.sse_stream([event(unquote(type), code)], done: false))
      setup = gateway_setup(upstream)
      set_model_serving_mode!(model_serving_scope(), setup, unquote(mode))
      conn = conn |> auth(setup) |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic input"), "stream" => true})
      assert conn.status == 200
      assert conn.resp_body =~ code
      assert FakeUpstream.count(upstream) == 1
      assert_neutral!(setup, code)
    end
  end

  for mode <- ["full", "lite"], code <- @codes, type <- ["error", "response.failed"] do
    test "#{mode} public SSE owner bridge #{type} #{code} keeps raw policy authority", %{conn: conn} do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
      code = unquote(code)
      upstream = start_upstream(FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(event(unquote(type), code))]))
      setup = gateway_setup(upstream)
      set_model_serving_mode!(model_serving_scope(), setup, unquote(mode))
      conn = conn |> auth(setup) |> put_req_header("session-id", Ecto.UUID.generate()) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic input", "stream" => true})
      assert conn.status == 200
      assert FakeUpstream.http_request_count(upstream) == 0
      assert FakeUpstream.count(upstream) == 1
      assert_neutral!(setup, code)
    end
  end

  for mode <- ["full", "lite"], code <- @codes, owner? <- [false, true] do
    test "#{mode} websocket owner=#{owner?} #{code} preserves request-local refusal health" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(owner?))
      code = unquote(code)
      upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(event("response.failed", code))]))]))
      setup = gateway_setup(upstream)
      set_model_serving_mode!(model_serving_scope(), setup, unquote(mode))
      {:ok, cleanup} = Agent.start(fn -> nil end)

      on_exit(fn ->
        terminate_socket!(cleanup)
        Agent.stop(cleanup)
      end)

      {:ok, auth} = CodexPooler.Access.authenticate_authorization_header(setup.authorization)
      {:ok, state} = CodexPoolerWeb.CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: Ecto.UUID.generate(), accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}})
      Agent.update(cleanup, fn _state -> state end)

      try do
        payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic input"), "stream" => true, "generate" => true})
        assert {:ok, turn_state} = CodexPoolerWeb.CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
        Agent.update(cleanup, fn _state -> turn_state end)
        {turn_state, frames} = collect_native_turn_frames!(turn_state)
        Agent.update(cleanup, fn _state -> turn_state end)
        terminal = assert_single_native_turn_terminal!(frames, "response.failed")
        assert get_in(terminal, ["response", "error", "code"]) == code
        assert :ok = FakeUpstream.verify!(upstream)
        assert_neutral!(setup, code)
      after
        terminate_socket!(cleanup)
      end
    end
  end

  defp terminate_socket!(cleanup) do
    case Agent.get_and_update(cleanup, &{&1, nil}) do
      nil -> :ok
      state -> WebsocketCleanupFence.terminate_and_await!(:closed, state)
    end
  end

  defp event("response.failed", code), do: %{"type" => "response.failed", "response" => %{"status" => "failed", "error" => %{"code" => code, "message" => "Synthetic request refusal."}}}
  defp event(type, code), do: %{"type" => type, "error" => %{"code" => code, "message" => "Synthetic request refusal."}}

  defp assert_neutral!(setup, code) do
    assert [%Request{id: id, status: "failed", last_error_code: ^code}] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [%Attempt{status: "failed", response_metadata: metadata}] = Repo.all(from(a in Attempt, where: a.request_id == ^id))
    assert metadata["request_policy_terminal"] == true
    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
    refute Repo.exists?(from(c in RoutingCircuitState, where: c.pool_id == ^setup.pool.id))
  end
end
