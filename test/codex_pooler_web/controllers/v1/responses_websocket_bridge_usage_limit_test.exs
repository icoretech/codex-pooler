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
  # One BEAM node, owner forwarding on, FakeUpstream websocket, Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
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

    CodexPooler.TestDiagnostics.puts(fn -> "206-582 wire bridge: #{conn.status} #{inspect(Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry", "content-type"] end))} #{conn.resp_body}" end)

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
    # The rotation seed is the request id, not the fresh codex session's id.
    setup.pool |> CodexPooler.Pools.ensure_routing_settings() |> Ecto.Changeset.change(sticky_websocket_sessions: false) |> Repo.update!()
    setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])}

    conn = post_bridged(conn, setup, deterministic_rotation_seed(2, 0))

    CodexPooler.TestDiagnostics.puts(fn -> "206-582 wire failover: #{conn.status} #{String.slice(conn.resp_body, 0, 300)}" end)

    assert conn.status == 200
    assert conn.resp_body =~ "response.completed"
    refute conn.resp_body =~ "stream interrupted"
    assert FakeUpstream.websocket_connection_count(refusing_upstream) == 1
    assert FakeUpstream.websocket_connection_count(sibling_upstream) + FakeUpstream.http_request_count(sibling_upstream) == 1

    assert [%Request{status: "succeeded"} = request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [%Attempt{status: "retryable_failed", upstream_status_code: 429}, %Attempt{status: "succeeded"}] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id, order_by: [asc: a.attempt_number]))
  end

  defp usage_limit_frame(resets_at) do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 429,
      "error" => %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team", "resets_at" => resets_at, "resets_in_seconds" => @reset_seconds},
      "headers" => %{"x-codex-rate-limit-reached-type" => "rate_limit_reached"}
    })
  end

  defp completed_frame do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => "resp_bridge_usage_limit_failover", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
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
