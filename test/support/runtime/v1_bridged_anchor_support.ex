defmodule CodexPoolerWeb.Runtime.V1BridgedAnchorSupport do
  @moduledoc """
  Runs a public `/v1/responses` request anchored on `previous_response_id` on
  the only path the provider serves it: bridged onto its session's upstream
  websocket, on the connection that produced the anchor.

  The provider refuses `previous_response_id` over HTTP and answers
  `Invalid previous_response_id` on any other websocket connection
  (findings#232 rows 232-275 and 232-277), and Codex Pooler answers such a
  request before dispatch. A test that certifies what an anchored `/v1` turn
  sends upstream therefore opens a streaming turn on a session first, with
  websocket owner forwarding on, and sends its anchored turn on the same
  session, so both ride upstream websocket connection 1. The opener's response
  id is the anchor the test's own body names.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Plug.Conn

  alias CodexPooler.FakeUpstream

  @endpoint CodexPoolerWeb.Endpoint
  @opener_input "bridged anchor opener"

  @doc "Turns websocket owner forwarding on for the test; `gateway_setup/2` stops the owners its Pool starts."
  @spec enable_bridge!() :: :ok
  def enable_bridge! do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  @doc """
  The upstream scenario of one bridged anchored turn: the opener completes with
  `anchor` as its response id, then the anchored turn, which must carry that
  anchor, is answered with `continuation`, both on connection 1.
  """
  @spec upstream_mode(String.t(), FakeUpstream.mode()) :: FakeUpstream.mode()
  def upstream_mode(anchor, continuation) when is_binary(anchor) do
    FakeUpstream.strict_sequence([
      websocket_turn(completed_frames(%{"id" => anchor}), forbidden: ["previous_response_id"]),
      websocket_turn(continuation, equals: %{"previous_response_id" => anchor})
    ])
  end

  @doc "A completed websocket turn for a response map such as the HTTP fixtures' JSON responses."
  @spec completed_frames(map()) :: FakeUpstream.mode()
  def completed_frames(%{} = response) do
    response = Map.merge(%{"object" => "response", "status" => "completed", "output" => []}, response)
    FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => response})])
  end

  @doc """
  Posts the opener and then `body` (streaming, anchored on
  `body["previous_response_id"]`) on one fresh session, and returns the
  anchored turn's response.
  """
  @spec post_anchored(Plug.Conn.t(), map(), map()) :: Plug.Conn.t()
  def post_anchored(conn, setup, %{"previous_response_id" => anchor} = body) when is_binary(anchor) do
    session = "v1-bridged-anchor-#{System.unique_integer([:positive])}"

    opener =
      conn
      |> recycle()
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-session-id", session)
      |> post("/v1/responses", %{"model" => body["model"], "input" => @opener_input, "stream" => true})

    assert opener.status == 200, "the bridged opener failed with #{opener.status}"

    conn
    |> recycle()
    |> put_req_header("authorization", setup.authorization)
    |> put_req_header("x-session-id", session)
    |> post("/v1/responses", Map.put(body, "stream", true))
  end

  @doc "The anchored turn's upstream frame, after asserting both turns rode one connection."
  @spec anchored_request!(FakeUpstream.t()) :: map()
  def anchored_request!(upstream) do
    assert [opener, anchored] = FakeUpstream.requests(upstream)
    assert opener.method == "WEBSOCKET" and anchored.method == "WEBSOCKET"
    assert opener.websocket_connection_id == anchored.websocket_connection_id
    assert :ok = FakeUpstream.verify!(upstream)
    anchored
  end

  @doc "Asserts the anchored turn's public stream completed with `response_id`."
  @spec assert_completed!(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def assert_completed!(response, response_id) do
    assert response.status == 200, "expected the bridged anchored turn to stream, got #{response.status}: #{response.resp_body}"
    assert response.resp_body =~ "event: response.completed"
    assert response.resp_body =~ ~s("id":"#{response_id}")
    response
  end

  defp websocket_turn(respond, json_expectations) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: 1,
      json: Keyword.put_new(json_expectations, :valid, true),
      respond: respond
    )
  end
end
