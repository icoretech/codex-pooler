defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeUsageLimitTest do
  # A streaming `/v1/responses` turn bridged onto the upstream websocket that
  # meets a provider usage limit before any output (the wrapped `429` frame)
  # reaches the same decision as the HTTP path for the same refusal
  # (findings#206 rows 206-531, 206-545, 206-582): it moves to another eligible
  # candidate, and on the last candidate it answers the terminal HTTP `429`
  # `usage_limit_reached` with the Pool's advice, `Retry-After` and
  # `x-should-retry: false`. It used to answer HTTP 200 with an SSE `error`
  # "stream interrupted before terminal response event" and never moved on.
  #
  # One BEAM node, owner forwarding on, FakeUpstream websocket, the Pool's
  # default mode, which serves this fixture's model Full (Auto, from a catalog
  # source whose `use_responses_lite` is false).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @message "upstream quota is exhausted until its reset time"
  @provider_message "synthetic provider usage limit text"
  @reset_seconds 3_600

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  test "the last candidate's usage-limit frame answers the terminal 429 with the provider's reset", %{conn: conn} do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    upstream = start_upstream(FakeUpstream.websocket_text_frames([usage_limit_frame(resets_at)]))
    setup = gateway_setup(upstream)

    conn = post_bridged(conn, setup)

    CodexPooler.TestDiagnostics.puts(fn -> "206-582 wire bridge: #{conn.status} #{inspect(Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry", "content-type"] end))}" end)

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    assert conn.status == 429
    assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
    assert %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => @message, "resets_at" => ^resets_at, "resets_in_seconds" => seconds} = error
    assert seconds in (@reset_seconds - 5)..@reset_seconds
    refute conn.resp_body =~ @provider_message
    refute Map.has_key?(error, "plan_type")
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]
    assert get_resp_header(conn, "x-should-retry") == ["false"]

    assert [%Request{status: "failed", response_status_code: 429} = request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [%Attempt{status: "failed", upstream_status_code: 429, transport: "websocket"}] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
  end

  test "the accepted nested usage-limit schema remains an HTTP 429 through the owner bridge", %{conn: conn} do
    error = %{"type" => "usage_limit_reached", "code" => "usage_limit_reached", "resets_at" => DateTime.to_unix(DateTime.utc_now()) + @reset_seconds, "resets_in_seconds" => @reset_seconds}
    frame = CodexPooler.JSON.encode!(%{"type" => "response.failed", "response" => %{"status" => "failed", "error" => error}})
    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    setup = gateway_setup(upstream)
    response = post_bridged(conn, setup)
    assert response.status == 429
    refute response.resp_body =~ "stream interrupted"
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
  end

  for nested <- [:absent, :empty, :malformed, :valid] do
    test "a pre-output 429 preserves safe retry advice with #{nested} nested headers", %{conn: conn} do
      assert_provider_retry_after!(conn, unquote(nested))
    end
  end

  test "a statusless quota terminal keeps outer retry advice through the existing bridge", %{conn: conn} do
    assert_provider_retry_after!(conn, :malformed, :statusless)
  end

  test "an exhausted sibling that resets sooner sets the advice", %{conn: conn} do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    refusing_upstream = start_upstream(FakeUpstream.websocket_text_frames([usage_limit_frame(resets_at)]))
    sibling_upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame()]))
    setup = gateway_setup(refusing_upstream)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-sibling", compact?: false)
    prime_exhausted_routing_quota!(sibling.identity, %{reset_at: DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)})
    setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])}

    conn = post_bridged(conn, setup)

    assert conn.status == 429
    assert %{"error" => %{"type" => "usage_limit_reached", "resets_in_seconds" => seconds}} = CodexPooler.JSON.decode!(conn.resp_body)
    assert seconds in 895..900
    assert FakeUpstream.websocket_connection_count(sibling_upstream) == 0
  end

  test "an eligible sibling serves the turn after the refusal", %{conn: conn} do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
    refusing_upstream = start_upstream(FakeUpstream.websocket_text_frames([usage_limit_frame(resets_at)]))
    sibling_upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame()]))
    setup = gateway_setup(refusing_upstream)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-sibling", compact?: false)
    prime_routing_quota!(sibling.identity)
    use_deterministic_rotation!(setup.pool, 2)
    setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])}

    session = "bridge-failover-#{System.unique_integer([:positive])}"
    assert_refusing_candidate_first!(setup, sibling, session)

    conn = post_session(conn, setup, session, %{"input" => "synthetic first turn"}, "first-request")

    CodexPooler.TestDiagnostics.puts(fn -> "206-582 wire failover: #{conn.status} refusing_connections=#{FakeUpstream.websocket_connection_count(refusing_upstream)} sibling_dispatches=#{FakeUpstream.websocket_connection_count(sibling_upstream) + FakeUpstream.http_request_count(sibling_upstream)}" end)

    assert conn.status == 200
    assert conn.resp_body =~ "response.completed"
    refute conn.resp_body =~ "stream interrupted"
    assert FakeUpstream.websocket_connection_count(refusing_upstream) == 1
    assert FakeUpstream.websocket_connection_count(sibling_upstream) + FakeUpstream.http_request_count(sibling_upstream) == 1

    assert [%Request{status: "succeeded"} = request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [%Attempt{status: "retryable_failed", upstream_status_code: 429}, %Attempt{status: "succeeded"}] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id, order_by: [asc: a.attempt_number]))
  end

  # After the failover the session's owner rides the sibling's upstream
  # connection under the same lease (findings#206 row 206-585). The session's
  # next turn, anchored on the sibling's response, stays on that account and
  # that connection: the anchor resolves where it was produced, the request
  # carries the owner binding, and the refusing account sees no second request.
  test "the turn after a bridged failover keeps continuity on the sibling's connection", %{conn: conn} do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds

    refusing_upstream = start_upstream(FakeUpstream.strict_sequence([bridge_turn(1, FakeUpstream.websocket_text_frames([usage_limit_frame(resets_at)]))]))

    sibling_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          bridge_turn(1, FakeUpstream.websocket_text_frames([completed_frame("resp_sibling_first")])),
          bridge_turn(1, FakeUpstream.websocket_text_frames([completed_frame("resp_sibling_second")]), %{"previous_response_id" => "resp_sibling_first"})
        ])
      )

    setup = gateway_setup(refusing_upstream)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-sibling", compact?: false)
    prime_routing_quota!(sibling.identity)
    use_deterministic_rotation!(setup.pool, 2)
    setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])}
    session = "bridge-failover-continuity-#{System.unique_integer([:positive])}"

    assert_refusing_candidate_first!(setup, sibling, session)

    first = post_session(conn, setup, session, %{"input" => "synthetic first turn"}, "first-request")
    assert first.status == 200
    assert first.resp_body =~ "resp_sibling_first"

    second = post_session(build_conn(), setup, session, %{"input" => [%{"type" => "function_call_output", "call_id" => "call_synthetic_continuity", "output" => "synthetic tool output"}], "previous_response_id" => "resp_sibling_first"}, "second-request")

    CodexPooler.TestDiagnostics.puts(fn -> "206-585 second turn: #{second.status} refusing_connections=#{FakeUpstream.websocket_connection_count(refusing_upstream)} sibling_connections=#{FakeUpstream.websocket_connection_count(sibling_upstream)}" end)

    assert second.status == 200
    assert second.resp_body =~ "resp_sibling_second"

    assert [first_row, second_row] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))
    assert first_row.status == "succeeded" and second_row.status == "succeeded"
    assert [%Attempt{status: "succeeded", transport: "websocket"} = second_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^second_row.id))
    assert second_attempt.pool_upstream_assignment_id == sibling.assignment.id
    assert %{"reused" => true, "reconnected" => false} = second_attempt.response_metadata["upstream_websocket_connection"]
    assert %{"enabled" => true} = second_row.request_metadata["websocket_owner_forwarding"]

    assert %CodexPooler.Gateway.Persistence.CodexSession{pool_upstream_assignment_id: pinned} = Repo.get_by(CodexPooler.Gateway.Persistence.CodexSession, session_key: session)
    assert pinned == sibling.assignment.id

    assert {FakeUpstream.websocket_connection_count(refusing_upstream), FakeUpstream.http_request_count(refusing_upstream)} == {1, 0}
    assert {FakeUpstream.websocket_connection_count(sibling_upstream), FakeUpstream.http_request_count(sibling_upstream)} == {1, 0}
    assert :ok = FakeUpstream.verify!(refusing_upstream)
    assert :ok = FakeUpstream.verify!(sibling_upstream)
  end

  # Prepare the real session once, then orient the two fixture rows around its
  # automatic seed. No request-id override or random session retry controls order.
  defp assert_refusing_candidate_first!(setup, sibling, session_header) do
    {:ok, auth} = CodexPooler.Access.authenticate_authorization_header(setup.authorization)
    endpoint = "/backend-api/codex/responses"
    payload = %{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic first turn"), "stream" => true}
    options = RequestOptions.build(%{api_key_policy: auth.api_key, session_header: session_header, session_header_source: "x-session-id"}, endpoint, payload)
    assert {:ok, prepared} = PreDispatch.prepare(auth, endpoint, payload, options, setup.model)
    session = prepared.request_options.continuity.codex_session
    assert is_binary(session.id)
    assert is_nil(session.pool_upstream_assignment_id)

    plan = session_plan(auth, setup, prepared)
    assert length(plan.candidates) == 2

    if plan.selected_assignment_id != setup.assignment.id do
      earlier = DateTime.utc_now() |> DateTime.add(-10, :second)
      setup.assignment |> Ecto.Changeset.change(created_at: DateTime.add(earlier, 1, :second)) |> Repo.update!()
      sibling.assignment |> Ecto.Changeset.change(created_at: earlier) |> Repo.update!()
    end

    assert {:ok, prepared} = PreDispatch.prepare(auth, endpoint, payload, options, setup.model)
    assert prepared.request_options.continuity.codex_session.id == session.id
    plan = session_plan(auth, setup, prepared)
    assert plan.affinity.kind == "codex_session"
    assert plan.affinity.seed == session.id
    assert Enum.map(plan.candidates, fn {assignment, _identity} -> assignment.id end) == [setup.assignment.id, sibling.assignment.id]
    CodexPooler.TestDiagnostics.puts("automatic session seed: candidates=2 order=refusing,sibling affinity=codex_session assigned=false")
  end

  defp session_plan(auth, setup, prepared) do
    BridgeRing.plan_route(%{
      auth: auth,
      model: setup.model,
      candidates: prepared.candidates,
      route_plan_input: RoutePlanInput.from_request_opts(prepared.request_options),
      request_options: prepared.request_options,
      route_state: prepared.route_state
    })
  end

  defp bridge_turn(connection_ordinal, respond, equals \\ %{}) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: connection_ordinal,
      json: [valid: true, equals: Map.merge(%{"type" => "response.create"}, equals)],
      respond: respond
    )
  end

  defp post_session(conn, setup, session, body, request_id) do
    conn
    |> auth(setup)
    |> put_req_header("x-session-id", session)
    |> put_req_header("x-request-id", request_id)
    |> post("/v1/responses", Map.merge(%{"model" => setup.model.exposed_model_id, "stream" => true}, body))
  end

  defp assert_provider_retry_after!(conn, nested, shape \\ :wrapped) do
    error = %{"type" => "usage_limit_reached", "message" => @provider_message}

    error =
      case nested do
        :absent -> error
        :empty -> Map.put(error, "headers", %{})
        :malformed -> Map.put(error, "headers", %{"retry-after" => "later", "authorization" => "synthetic-nested-secret"})
        :valid -> Map.put(error, "headers", %{"retry-after" => "7", "authorization" => "synthetic-nested-secret"})
      end

    frame = %{"type" => "error", "status" => 429, "error" => error, "headers" => %{"Retry-After" => "30", "set-cookie" => "synthetic-outer-secret"}}
    frame = if shape == :statusless, do: frame |> Map.delete("status") |> Map.put("type", "response.failed") |> Map.put("response", %{"status" => "failed", "error" => error}), else: frame
    frame = CodexPooler.JSON.encode!(frame)
    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    setup = gateway_setup(upstream)
    response = post_bridged(conn, setup)

    assert response.status == 429
    assert get_resp_header(response, "retry-after") == [if(nested == :valid, do: "7", else: "30")]
    assert get_resp_header(response, "set-cookie") == []
    assert %{"error" => %{"type" => "rate_limit_error", "code" => "upstream_rate_limited"} = projected} = CodexPooler.JSON.decode!(response.resp_body)
    refute Map.has_key?(projected, "headers")
    refute response.resp_body =~ @provider_message
    refute response.resp_body =~ "synthetic-nested-secret"
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    assert [%Request{status: "failed", response_status_code: 429}] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
  end

  defp usage_limit_frame(resets_at) do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 429,
      "error" => %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team", "resets_at" => resets_at, "resets_in_seconds" => @reset_seconds},
      "headers" => %{"x-codex-rate-limit-reached-type" => "rate_limit_reached", "retry-after" => "17"}
    })
  end

  defp completed_frame(id \\ "resp_bridge_usage_limit_failover") do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
    })
  end

  defp post_bridged(conn, setup, request_id \\ nil) do
    conn =
      conn
      |> auth(setup)
      |> put_req_header("x-session-id", "bridge-usage-limit-#{System.unique_integer([:positive])}")

    conn = if request_id, do: put_req_header(conn, "x-request-id", request_id), else: conn

    post(conn, "/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic bridged usage limit prompt", "stream" => true})
  end
end
