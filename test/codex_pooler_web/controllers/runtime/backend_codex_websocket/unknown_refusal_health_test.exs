defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.UnknownRefusalHealthTest do
  # A provider 4xx refusal with a code the Pooler does not know says nothing
  # against the account that answered it. The HTTP answer of the refusal
  # completes the route neutrally whatever the code (findings#254 row 254-32),
  # but the same refusal sent over the upstream websocket as its wrapped error
  # frame demoted the assignment and counted a `proxy_websocket` circuit
  # failure, because the websocket terminal demoted every code outside the
  # health-neutral list (row 254-81). Each test sends the same refusal over
  # native HTTP SSE and over the native websocket and reads route health after
  # each. A code the Pooler knows keeps its own classification.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [collect_native_turn_frames!: 1, strict_native_request: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @unknown_code "synthetic_refusal_code"
  @provider_sentinel "private-unknown-refusal-health-sentinel"
  @prompt_sentinel "private-unknown-refusal-health-prompt"

  for status <- [400, 403, 404, 408, 409, 413, 422] do
    @tag provider_status: status
    test "an unknown-code provider #{status} leaves route health alone over native HTTP SSE and the native websocket", %{conn: conn, provider_status: status} do
      http_request = http_refusal!(conn, status, provider_error(@unknown_code))
      assert http_request.last_error_code == "upstream_status"
      assert route_health(http_request) == untouched()

      ws_request = websocket_refusal!("unknown-refusal-#{status}", status, provider_error(@unknown_code))
      assert ws_request.last_error_code == @unknown_code
      assert route_health(ws_request) == untouched()
    end
  end

  for topology <- [:direct, :local_owner] do
    @tag topology: topology
    test "an unknown-code provider 404 leaves route health alone on the #{topology} native websocket", %{topology: topology} do
      if topology == :local_owner, do: enable_owner_forwarding!()

      request = websocket_refusal!("unknown-refusal-topology-#{topology}", 404, provider_error(@unknown_code))
      assert route_health(request) == untouched()
    end
  end

  # Controls: a known code outside the health-neutral list still demotes on
  # the websocket, and so does an unknown code on the statuses HTTP records as
  # route failures (401 credentials, 429 throttle).
  for {status, code} <- [{403, "unauthorized"}, {401, @unknown_code}, {429, @unknown_code}] do
    @tag provider_status: status, provider_code: code
    test "a provider #{status} #{code} still demotes the assignment on the native websocket", %{provider_status: status, provider_code: code} do
      request = websocket_refusal!("known-refusal-#{status}-#{code}", status, provider_error(code))
      health = route_health(request)

      assert health.demotions == [{code, "active"}]
      assert [{"proxy_websocket", ^code, 1}] = health.circuits
    end
  end

  defp http_refusal!(conn, status, provider_error) do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, status, %{"error" => provider_error}})
        ])
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true})

    assert response.status in 400..499
    refute response.resp_body =~ @provider_sentinel
    assert :ok = FakeUpstream.verify!(upstream)
    sole_request!(setup)
  end

  defp websocket_refusal!(request_id, status, provider_error) do
    frame = CodexPooler.JSON.encode!(%{"type" => "error", "status" => status, "error" => provider_error})
    upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_text_frames([frame]))]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: request_id, accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}})

    try do
      payload =
        CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true, "generate" => true})

      assert {:ok, turn_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      {turn_state, _frames} = collect_native_turn_frames!(turn_state)
      assert :ok = FakeUpstream.verify!(upstream)
      request = sole_request!(setup)
      assert request.status == "failed"
      assert :ok = CodexResponsesSocket.terminate(:closed, turn_state)
      request
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp provider_error(code) do
    %{"type" => "invalid_request_error", "code" => code, "message" => "Refused '#{@provider_sentinel}'.", "param" => nil}
  end

  defp untouched, do: %{demotion_reason: nil, demotions: [], circuits: []}

  # Every test builds its own Pool, so the rows read here are this refusal's.
  defp route_health(request) do
    %{
      demotion_reason: get_in(request.request_metadata, ["routing", "demotion_reason"]),
      demotions: Repo.all(from(demotion in BridgeDemotion, where: demotion.pool_id == ^request.pool_id, select: {demotion.reason_code, demotion.status})),
      circuits: Repo.all(from(circuit in RoutingCircuitState, where: circuit.pool_id == ^request.pool_id, select: {circuit.route_class, circuit.reason_code, circuit.failure_count}))
    }
  end

  defp sole_request!(setup) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    request
  end

  defp enable_owner_forwarding! do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
  end
end
