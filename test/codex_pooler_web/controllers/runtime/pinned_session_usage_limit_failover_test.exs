defmodule CodexPoolerWeb.Runtime.PinnedSessionUsageLimitFailoverTest do
  # A native HTTP SSE turn of a client session that earlier turns bound to one
  # account (the released client's `session-id`), when that account refuses
  # with a provider usage-limit `429` before any output while another account
  # of the Pool is eligible for the same model: the turn moves to the eligible
  # account, as it does for an unsessioned request (findings#206 rows 206-508
  # pin, 206-529).
  #
  # One BEAM node, two assignments, FakeUpstream, deterministic rotation; Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"

  for stream? <- [true, false] do
    @stream stream?

    test "stream=#{stream?}: the session's account refusing with a usage limit moves the turn to the eligible sibling", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 3 * 86_400
      success = if @stream, do: stream_success_sse(), else: FakeUpstream.json_response(%{"id" => "resp_pinned_ok", "object" => "response", "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}})

      first_upstream = start_upstream(FakeUpstream.strict_sequence([success, weekly_usage_limit_429(resets_at)]))
      second_upstream = start_upstream(success)
      setup = gateway_setup(first_upstream)
      second = gateway_upstream(setup.pool, second_upstream, "upstream-token-sibling", compact?: false)
      # The first turn binds the session to the first account: the sibling has
      # no quota evidence, so no route, until the second turn.
      use_deterministic_rotation!(setup.pool, 2)
      model = put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
      setup = %{setup | model: model}
      _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
      session_header = "pinned-session-#{System.unique_integer([:positive])}"

      first = post_turn(conn, setup, session_header, @stream, deterministic_rotation_seed(2, 0))
      assert first.status == 200
      assert %CodexSession{pool_upstream_assignment_id: pinned} = Repo.get_by(CodexSession, session_key: session_header)
      assert pinned == setup.assignment.id
      prime_routing_quota!(second.identity)

      second_conn = post_turn(build_conn(), setup, session_header, @stream, deterministic_rotation_seed(2, 0) <> "-second")

      rows = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))
      [_first_row, row] = rows
      attempts = Repo.all(from(a in Attempt, where: a.request_id == ^row.id, order_by: [asc: a.attempt_number]))

      measured = %{
        status: second_conn.status,
        posts: {model_posts(first_upstream), model_posts(second_upstream)},
        attempts: Enum.map(attempts, &{&1.status, &1.upstream_status_code, &1.pool_upstream_assignment_id == setup.assignment.id}),
        routing: Map.take(row.request_metadata["routing"] || %{}, ["candidate_count", "session_pin_mode", "session_pin_reason", "codex_session_pin_mode", "codex_session_pin_reason"])
      }

      CodexPooler.TestDiagnostics.puts(fn -> "206-P128d pinned failover stream=#{@stream}: #{inspect(measured)} body=#{String.slice(second_conn.resp_body, 0, 300)}" end)

      assert measured.status == 200
      assert measured.posts == {2, 1}
      assert [{"retryable_failed", 429, true}, {"succeeded", 200, false}] = measured.attempts
    end
  end

  # A Team account at its weekly limit: the provider's usage-limit body and the
  # exhausted weekly window on the refusal.
  defp weekly_usage_limit_429(resets_at) do
    headers = [
      {"x-codex-secondary-used-percent", "100"},
      {"x-codex-secondary-window-minutes", "10080"},
      {"x-codex-secondary-reset-at", Integer.to_string(resets_at)},
      {"x-codex-rate-limit-reached-type", "rate_limit_reached"}
    ]

    {:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at}}, headers}
  end

  defp model_posts(upstream), do: Enum.count(FakeUpstream.requests(upstream), &(&1.path == @turn_endpoint))

  defp post_turn(conn, setup, session_header, stream?, request_id) do
    conn
    |> put_req_header("authorization", setup.authorization)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("session-id", session_header)
    |> put_req_header("x-openai-internal-codex-responses-lite", "true")
    |> put_req_header("x-request-id", request_id)
    |> post(@turn_endpoint, CodexPooler.JSON.encode!(%{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic pinned session prompt"), "stream" => stream?}))
  end
end
