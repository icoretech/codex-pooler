defmodule CodexPoolerWeb.V1.ResponsesServingModeFlipAnchorTest do
  # `/v1/responses` admits `previous_response_id` only on a tool-output
  # continuation, and the provider resolves it only on the upstream websocket
  # connection that produced the response: an anchored `/v1` turn reaches a
  # context only bridged onto its session's connection or on the public
  # websocket (findings#232 rows 232-275 and 232-277; an anchored HTTP turn is
  # answered before dispatch). Neither is refused for the dialect of the
  # context. Lite sends its tool manifest and instructions message only on a
  # request that opens a context (row 232-184), so after the Pool flips the
  # model from Full to Lite the first anchored continuation would reach the
  # provider with no tools and no base instructions, and an SDK does not retry
  # `previous_response_not_found`. The dialect recorded on the anchor's alias
  # makes that continuation carry the prefix (row 232-270).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      await_public_websocket_upgrade: 2,
      gateway_setup: 1,
      mint_websocket_new!: 4,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [model_serving_scope: 0, set_model_serving_mode!: 3, set_model_serving_mode!: 4]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @tools [%{"type" => "function", "name" => "sample_lookup", "parameters" => %{"type" => "object", "properties" => %{}, "required" => []}}]
  @instructions "synthetic base instructions"
  @frame_timeout 5_000

  @tag :serving_mode_flip_anchor
  test "a bridged HTTP SSE continuation anchored on a response served under Full carries the Lite prefix after a flip", %{conn: conn} do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    on_exit(&stop_local_owner_sessions/0)

    upstream =
      start_upstream(
        # Both bridged turns ride upstream websocket connection 1.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          websocket_turn(completed_frames("resp_v1_bridge_flip_open"), forbidden: ["previous_response_id"]),
          websocket_turn(completed_frames("resp_v1_bridge_flip_call"), equals: %{"previous_response_id" => "resp_v1_bridge_flip_open"})
        ])
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "full")
    session = "v1-bridge-flip-#{System.unique_integer([:positive])}"

    first = post_v1_stream(conn, setup, session, %{"input" => "anchor"})
    assert first.status == 200
    assert first.resp_body =~ "resp_v1_bridge_flip_open"

    _revision = set_model_serving_mode!(scope, setup, "lite", revision)

    second = post_v1_stream(conn, setup, session, %{"previous_response_id" => "resp_v1_bridge_flip_open", "input" => [tool_output("call_v1_bridge")]})
    assert second.status == 200
    assert second.resp_body =~ "resp_v1_bridge_flip_call"

    assert [open_request, continuation_request] = FakeUpstream.requests(upstream)
    assert open_request.websocket_connection_id == continuation_request.websocket_connection_id
    assert_lite_prefix!(continuation_request.json, "call_v1_bridge")
    assert_request_modes!(setup, ["full", "lite"])
    assert Enum.all?(Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id)), &(&1.transport == "http_sse"))
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :serving_mode_flip_anchor
  test "a public websocket continuation anchored on a response served under Full carries the Lite prefix after a flip" do
    upstream =
      start_upstream(
        # Both turns ride upstream websocket connection 1.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          websocket_turn(completed_frames("resp_v1_ws_flip_open"), forbidden: ["previous_response_id"]),
          websocket_turn(completed_frames("resp_v1_ws_flip_call"), equals: %{"previous_response_id" => "resp_v1_ws_flip_open"})
        ])
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "full")
    assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_v1_websocket_connect!(port, setup, "v1-ws-flip-#{System.unique_integer([:positive])}")

    try do
      {conn, websocket} = send_response_create!(conn, websocket, ref, setup, %{"input" => "anchor"})
      {conn, websocket, first_frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_v1_ws_flip_open"}} = CodexPooler.JSON.decode!(first_frame)
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @frame_timeout

      _revision = set_model_serving_mode!(scope, setup, "lite", revision)

      {conn, websocket} =
        send_response_create!(conn, websocket, ref, setup, %{"previous_response_id" => "resp_v1_ws_flip_open", "input" => [tool_output("call_v1_ws")]})

      {conn, _websocket, second_frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_v1_ws_flip_call"}} = CodexPooler.JSON.decode!(second_frame)
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @frame_timeout

      assert [open_request, continuation_request] = FakeUpstream.requests(upstream)
      assert open_request.websocket_connection_id == continuation_request.websocket_connection_id
      assert_lite_prefix!(continuation_request.json, "call_v1_ws")
      assert_request_modes!(setup, ["full", "lite"])
      assert :ok = FakeUpstream.verify!(upstream)
      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  defp assert_lite_prefix!(upstream_json, call_id) do
    assert upstream_json["previous_response_id"]

    assert [
             %{"type" => "additional_tools", "role" => "developer", "tools" => [%{"name" => "sample_lookup"}]},
             %{"type" => "message", "role" => "developer"},
             %{"type" => "function_call_output", "call_id" => ^call_id}
           ] = upstream_json["input"]

    refute Map.has_key?(upstream_json, "tools")
    refute Map.has_key?(upstream_json, "instructions")
  end

  defp assert_request_modes!(setup, modes) do
    requests = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))
    assert Enum.map(requests, & &1.status) == Enum.map(modes, fn _mode -> "succeeded" end)
    assert Enum.map(requests, & &1.request_metadata["routing"]["model_serving_mode"]) == modes
  end

  defp tool_output(call_id), do: %{"type" => "function_call_output", "call_id" => call_id, "output" => "sample output"}

  defp turn_body(setup, attrs), do: Map.merge(%{"model" => setup.model.exposed_model_id, "instructions" => @instructions, "tools" => @tools}, attrs)

  defp post_v1_stream(conn, setup, session, attrs) do
    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("x-session-id", session)
    |> post("/v1/responses", turn_body(setup, Map.put(attrs, "stream", true)))
  end

  defp send_response_create!(conn, websocket, ref, setup, attrs) do
    payload = turn_body(setup, Map.merge(%{"type" => "response.create", "stream" => false, "generate" => true}, attrs))
    public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
  end

  defp public_v1_websocket_connect!(port, setup, turn_state) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = [{"authorization", setup.authorization}, {"x-codex-turn-state", turn_state}, {"openai-beta", "responses_websockets=2026-02-06"}]
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref}
  end

  defp websocket_turn(respond, json_expectations) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: 1,
      json: expectations(json_expectations),
      respond: respond
    )
  end

  defp expectations(json_expectations), do: Keyword.put_new(json_expectations, :valid, true)

  defp completed_event(response_id) do
    %{
      "type" => "response.completed",
      "response" => %{
        "id" => response_id,
        "status" => "completed",
        "output" => [],
        "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
      }
    }
  end

  defp completed_frames(response_id), do: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(completed_event(response_id))])

  # Bridged turns start owner sessions that would otherwise outlive the test.
  defp stop_local_owner_sessions do
    _logs =
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn codex_session_id ->
          try do
            with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
              _result = GenServer.stop(owner_pid, :shutdown, 1_000)
            end
          catch
            :exit, _reason -> :ok
          end
        end)
      end)

    :ok
  end
end
