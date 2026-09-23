defmodule CodexPoolerWeb.V1.ResponsesPreviousResponseConnectionTest do
  # The provider resolves `previous_response_id` only on the upstream websocket
  # connection that produced the response: over HTTP it refuses the parameter
  # (`400 {"detail":"Unsupported parameter: previous_response_id"}`) and on any
  # other websocket connection, a fresh one included, it answers a codeless
  # `400 invalid_request_error` "Invalid `previous_response_id`." (findings#232
  # rows 232-275 and 232-277, live probes 2026-09-23). A public `/v1/responses`
  # request anchored on a response therefore reaches the earlier context only
  # when it is bridged onto its session's upstream websocket and that
  # connection produced the anchor. Every other anchored request is answered
  # before any provider call with the OpenAI `previous_response_not_found`
  # error whose message names the requirement, so SDK fallbacks resend the
  # complete input instead of failing on an opaque upstream error.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OpenAICompatibility.Error, as: OpenAICompatibilityError
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @anchor "resp_v1_anchor_opener"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    on_exit(&stop_local_owner_sessions/0)
    :ok
  end

  describe "an anchored /v1/responses request that cannot reach its producing connection" do
    test "is answered before dispatch when it is not streaming", %{conn: conn} do
      upstream = start_upstream(completed_sse("resp_v1_unexpected"))
      setup = gateway_setup(upstream)

      response = post_v1(conn, setup, anchored_body(setup, %{"stream" => false}), session: session_id("json"))

      assert_refused_before_dispatch!(response, upstream, setup)
    end

    # Without a session header the anchor's alias can still name the session
    # whose connection produced it, so the request is bridged; a session it
    # opens itself has a fresh connection, which the owner refuses before the
    # response.create.
    test "is refused before its response.create when a streaming request sends no session header", %{conn: conn} do
      upstream = start_upstream(completed_frames("resp_v1_unexpected"))
      setup = gateway_setup(upstream)

      response = post_v1(conn, setup, anchored_body(setup, %{"stream" => true}), session: nil)

      assert_refused_on_fresh_connection!(response, upstream, setup)
    end

    test "is answered before dispatch when websocket owner forwarding is off", %{conn: conn} do
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
      upstream = start_upstream(completed_sse("resp_v1_unexpected"))
      setup = gateway_setup(upstream)

      response = post_v1(conn, setup, anchored_body(setup, %{"stream" => true}), session: session_id("forwarding-off"))

      assert_refused_before_dispatch!(response, upstream, setup)
    end

    test "is refused before its response.create when the bridged connection is fresh", %{conn: conn} do
      upstream = start_upstream(completed_frames("resp_v1_unexpected"))
      setup = gateway_setup(upstream)

      response = post_v1(conn, setup, anchored_body(setup, %{"stream" => true}), session: session_id("fresh"))

      assert_refused_on_fresh_connection!(response, upstream, setup)
    end

    test "answers the same error when the reused bridged connection did not produce the anchor", %{conn: conn} do
      upstream =
        start_upstream(
          # provenance: live probe 2026-09-23 (the provider's refusal of an anchor its connection did not produce)
          FakeUpstream.strict_sequence([
            websocket_turn(completed_frames("resp_v1_other_opener"), forbidden: ["previous_response_id"]),
            websocket_turn(invalid_previous_response_id_frames(), equals: %{"previous_response_id" => @anchor})
          ])
        )

      setup = gateway_setup(upstream)
      session = session_id("reused-other")

      opener = post_v1(conn, setup, turn_body(setup, %{"input" => "anchor", "stream" => true}), session: session)
      assert opener.status == 200
      assert opener.resp_body =~ "resp_v1_other_opener"

      response = post_v1(conn, setup, anchored_body(setup, %{"stream" => true}), session: session)

      assert json_response(response, 400) == %{"error" => expected_error()}
      assert [open_request, anchored_request] = FakeUpstream.requests(upstream)
      assert open_request.websocket_connection_id == anchored_request.websocket_connection_id
      assert :ok = FakeUpstream.verify!(upstream)

      assert [_opener_row, %Request{status: "failed", last_error_code: "upstream_status"} = request] = pool_requests(setup)
      assert [%Attempt{upstream_status_code: 400} = attempt] = attempts(request)
      assert attempt.response_metadata["rejection_message_class"] == "invalid_previous_response_id"
      refute inspect(attempt.response_metadata) =~ "Invalid"
    end
  end

  test "an anchored /v1/responses request bridged onto the connection that produced the anchor is served", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          websocket_turn(completed_frames(@anchor), forbidden: ["previous_response_id"]),
          websocket_turn(completed_frames("resp_v1_anchored_served"), equals: %{"previous_response_id" => @anchor})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id("producing")

    opener = post_v1(conn, setup, turn_body(setup, %{"input" => "anchor", "stream" => true}), session: session)
    assert opener.status == 200

    response = post_v1(conn, setup, anchored_body(setup, %{"stream" => true}), session: session)

    assert response.status == 200
    assert response.resp_body =~ "resp_v1_anchored_served"
    assert [open_request, anchored_request] = FakeUpstream.requests(upstream)
    assert open_request.websocket_connection_id == anchored_request.websocket_connection_id
    assert :ok = FakeUpstream.verify!(upstream)
    assert Enum.map(pool_requests(setup), & &1.status) == ["succeeded", "succeeded"]
  end

  defp assert_refused_on_fresh_connection!(response, upstream, setup) do
    assert json_response(response, 400) == %{"error" => expected_error()}
    # The owner opened its connection, but nothing was sent on it.
    assert FakeUpstream.requests(upstream) == []
    assert FakeUpstream.http_request_count(upstream) == 0

    assert [%Request{status: "failed", last_error_code: "upstream_status", transport: "http_sse"} = request] = pool_requests(setup)
    assert [%Attempt{} = attempt] = attempts(request)
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.response_metadata["rejection_message_class"] == "invalid_previous_response_id"
    assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
  end

  defp assert_refused_before_dispatch!(response, upstream, setup) do
    assert json_response(response, 400) == %{"error" => expected_error()}
    assert FakeUpstream.requests(upstream) == []
    assert FakeUpstream.websocket_connection_count(upstream) == 0

    assert [%Request{status: "failed", last_error_code: "previous_response_not_found"} = request] = pool_requests(setup)
    assert [%Attempt{} = attempt] = attempts(request)
    refute Map.has_key?(attempt.response_metadata, "upstream_transport")
    refute Map.has_key?(attempt.response_metadata, "upstream_websocket_connection")
    # Settled once, and no route-health evidence against the assignment.
    assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^request.id and entry.entry_kind == "settlement"), :count) == 1
    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  defp expected_error do
    reason = OpenAICompatibilityError.previous_response_not_found()

    %{
      "type" => "invalid_request_error",
      "code" => "previous_response_not_found",
      "param" => "previous_response_id",
      "message" => reason.message
    }
  end

  defp anchored_body(setup, attrs) do
    turn_body(setup, Map.merge(%{"previous_response_id" => @anchor, "input" => [%{"type" => "function_call_output", "call_id" => "call_v1_anchor", "output" => "sample output"}]}, attrs))
  end

  defp turn_body(setup, attrs), do: Map.merge(%{"model" => setup.model.exposed_model_id}, attrs)

  defp post_v1(conn, setup, body, session: session) do
    conn = conn |> recycle() |> auth(setup)
    conn = if session, do: put_req_header(conn, "x-session-id", session), else: conn
    post(conn, "/v1/responses", body)
  end

  defp session_id(label), do: "v1-anchor-#{label}-#{System.unique_integer([:positive])}"

  defp pool_requests(setup) do
    Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))
  end

  defp attempts(request), do: Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

  defp websocket_turn(respond, json_expectations) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: 1,
      json: Keyword.put_new(json_expectations, :valid, true),
      respond: respond
    )
  end

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

  defp completed_sse(response_id), do: FakeUpstream.sse_stream([{"response.completed", completed_event(response_id)}])

  defp completed_frames(response_id), do: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(completed_event(response_id))])

  defp invalid_previous_response_id_frames do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "error",
        "status" => 400,
        "error" => %{"type" => "invalid_request_error", "message" => "Invalid `previous_response_id`."}
      })
    ])
  end

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
