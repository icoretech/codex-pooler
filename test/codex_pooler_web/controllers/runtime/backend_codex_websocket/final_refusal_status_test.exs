defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.FinalRefusalStatusTest do
  # A provider refusal of a native websocket turn with a final 4xx other than
  # 400 (404, 409, 413, 422, ...) reached the released Codex 0.156.0 client as
  # the canonical `response.failed`, which it retries: four websocket resends
  # the Pooler refused `409 duplicate_turn`, then the HTTPS fallback and five
  # more HTTP retries, six provider requests for a refusal that cannot succeed
  # (findings#254 row 254-71). The wrapped error event of any status other than
  # 400 is no better: the client maps it to a retryable unexpected status. So
  # the refusal goes out as the wrapped 400 the client reads as a final invalid
  # request, with the Pooler-authored error naming the provider status.
  #
  # A 403 stays retryable when the Pooler marks the account unhealthy for it
  # (a code outside the health-neutral set demotes the assignment, and the
  # client's HTTPS fallback is then routed to another assignment first); a
  # health-neutral 403, which demotes nothing, would only reach the same
  # account again and is final like the others. 401 and 408 are unchanged.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [assert_single_native_turn_terminal!: 2, collect_native_turn_frames!: 1, stop_registered_websocket_owner_sessions: 0, strict_native_request: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @provider_sentinel "private-ws-final-refusal-sentinel"
  @prompt_sentinel "private-ws-final-refusal-prompt"

  for topology <- [:direct, :local_owner], status <- [404, 409, 413, 422] do
    @tag topology: topology, provider_status: status
    test "native websocket #{topology} codeless provider #{status} reaches the client as the final wrapped 400", %{topology: topology, provider_status: status} do
      if topology == :local_owner, do: enable_owner_forwarding!()

      {frames, request, attempt} = native_refusal_turn!("ws-final-refusal-#{topology}-#{status}", status, provider_error(nil, nil))

      assert assert_single_native_turn_terminal!(frames, "error") == %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request",
                 "param" => nil,
                 "message" => "upstream rejected the request (invalid_request); upstream status #{status}"
               }
             }

      refute CodexPooler.JSON.encode!(frames) =~ @provider_sentinel
      # Settlement and the attempt's rejection fields still read the canonical
      # frame with the provider's own status.
      assert request.status == "failed"
      assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
      refute inspect(attempt) =~ @provider_sentinel
    end
  end

  test "native websocket coded provider 404 keeps its code and param, without the input index" do
    {frames, _request, _attempt} = native_refusal_turn!("ws-final-refusal-coded-404", 404, provider_error("model_not_found", "input[2].content"))

    assert assert_single_native_turn_terminal!(frames, "error") == %{
             "type" => "error",
             "status" => 400,
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "model_not_found",
               "param" => "input[].content",
               "message" => "upstream rejected parameter input[].content (model_not_found); upstream status 404"
             }
           }
  end

  test "native websocket health-neutral provider 403 is final: it demotes nothing, so a retry reaches the same account" do
    {frames, _request, _attempt} = native_refusal_turn!("ws-final-refusal-neutral-403", 403, provider_error(nil, nil))

    assert %{"type" => "error", "status" => 400, "error" => %{"code" => "invalid_request", "message" => "upstream rejected the request (invalid_request); upstream status 403"}} =
             assert_single_native_turn_terminal!(frames, "error")

    assert Repo.all(from(demotion in BridgeDemotion, select: demotion.reason_code)) == []
  end

  test "native websocket provider 403 whose code demotes the account stays retryable" do
    {frames, _request, _attempt} = native_refusal_turn!("ws-final-refusal-demoting-403", 403, provider_error("account_deactivated", nil))

    terminal = assert_single_native_turn_terminal!(frames, "response.failed")
    assert %{"status" => 403, "response" => %{"status" => "failed", "error" => %{"code" => "account_deactivated"}}} = terminal
    assert Repo.all(from(demotion in BridgeDemotion, select: demotion.reason_code)) == ["account_deactivated"]
  end

  for status <- [401, 408] do
    @tag provider_status: status
    test "native websocket provider #{status} keeps the canonical response.failed", %{provider_status: status} do
      {frames, _request, _attempt} = native_refusal_turn!("ws-final-refusal-kept-#{status}", status, provider_error(nil, nil))

      assert %{"status" => ^status, "response" => %{"status" => "failed"}} = assert_single_native_turn_terminal!(frames, "response.failed")
    end
  end

  # A code the released client classifies from `response.failed` keeps that
  # frame whatever the status.
  test "native websocket provider 404 naming a classified code keeps the response.failed" do
    {frames, _request, _attempt} = native_refusal_turn!("ws-final-refusal-classified-404", 404, provider_error("invalid_prompt", nil))

    assert %{"status" => 404, "response" => %{"error" => %{"code" => "invalid_prompt"}}} = assert_single_native_turn_terminal!(frames, "response.failed")
  end

  defp native_refusal_turn!(request_id, status, provider_error) do
    frame = CodexPooler.JSON.encode!(%{"type" => "error", "status" => status, "error" => provider_error})
    upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_text_frames([frame]))]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: request_id, accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}})

    try do
      payload =
        CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true, "generate" => true})

      assert {:ok, turn_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      {turn_state, frames} = collect_native_turn_frames!(turn_state)
      assert :ok = FakeUpstream.verify!(upstream)
      assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
      assert :ok = CodexResponsesSocket.terminate(:closed, turn_state)
      {frames, request, attempt}
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp provider_error(code, param) do
    %{"type" => "invalid_request_error", "code" => code, "message" => "Refused '#{@provider_sentinel}'.", "param" => param}
  end

  defp enable_owner_forwarding! do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    on_exit(&stop_registered_websocket_owner_sessions/0)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
  end
end
