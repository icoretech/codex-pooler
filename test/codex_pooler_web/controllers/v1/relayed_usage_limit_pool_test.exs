defmodule CodexPoolerWeb.V1.RelayedUsageLimitPoolTest do
  # A provider usage-limit `429` on the last eligible candidate answers the
  # Pool's terminal usage limit (findings#206 row 206-531), and the advice is
  # the Pool's, as routing gives it one request later (rows 206-508, 206-545):
  # the soonest reset among the refusing account's own and every other
  # candidate's, whether routing excluded that candidate before dispatch or it
  # refused earlier in the same request. When another candidate has no known
  # return (it failed for another reason and is still routable), the Pool is
  # not exhausted, so the answer stays the relayed, retryable one.
  #
  # One BEAM node, two assignments, FakeUpstream, deterministic rotation;
  # `/v1/responses` JSON and native HTTP SSE; Lite and Full.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @moduletag capture_log: true

  @message "upstream quota is exhausted until its reset time"
  @own_reset_seconds 3_600

  for {label, sibling_reset, expected} <- [{"an earlier sibling reset", 900, 900}, {"a later sibling reset", 7_200, @own_reset_seconds}], mode <- ["lite", "full"] do
    @sibling_reset sibling_reset
    @expected expected
    @mode mode

    test "/v1 #{mode}: a sibling excluded before dispatch with #{label} advises the Pool's soonest return", %{conn: conn} do
      pool = pool!(@mode, sibling: FakeUpstream.json_response(%{"output" => []}), refusing: own_usage_limit_429())
      prime_exhausted_routing_quota!(pool.sibling.identity, %{reset_at: reset_in(@sibling_reset)})

      conn = post_v1(conn, pool)

      assert_usage_limit!(conn, @expected)
      assert {FakeUpstream.count(pool.sibling_upstream), model_posts(pool.refusing_upstream)} == {0, 1}
    end
  end

  # A sibling the provider refused at workspace level is quota-eligible and
  # excluded by the denial filter; it advises its earliest fresh reset
  # (row 206-522).
  test "/v1: a workspace-denied sibling advises its earliest fresh reset", %{conn: conn} do
    pool = pool!("lite", sibling: FakeUpstream.json_response(%{"output" => []}), refusing: own_usage_limit_429())
    prime_routing_quota!(pool.sibling.identity, %{used_percent: Decimal.new("97"), reset_at: reset_in(900)})
    deny_on_weekly_row_only!(pool.sibling.identity, reset_in(30 * 3_600))

    conn = post_v1(conn, pool)

    assert_usage_limit!(conn, 900)
    assert FakeUpstream.count(pool.sibling_upstream) == 0
  end

  test "native http sse: a sibling excluded before dispatch with an earlier reset advises it", %{conn: conn} do
    pool = pool!("lite", sibling: FakeUpstream.json_response(%{"output" => []}), refusing: own_usage_limit_429())
    prime_exhausted_routing_quota!(pool.sibling.identity, %{reset_at: reset_in(900)})

    conn = post_native(conn, pool)

    assert_usage_limit!(conn, 900)
  end

  test "/v1: a sibling that refused earlier in the same request with an earlier reset advises it", %{conn: conn} do
    sibling_reset_at = DateTime.to_unix(DateTime.utc_now()) + 900
    pool = pool!("lite", sibling: sibling_usage_limit_429(sibling_reset_at), refusing: own_usage_limit_429(), rotation: :sibling_first)

    conn = post_v1(conn, pool)

    assert_usage_limit!(conn, 900)
    assert {model_posts(pool.sibling_upstream), model_posts(pool.refusing_upstream)} == {1, 1}
  end

  test "/v1: a sibling that failed earlier for another reason keeps the relayed, retryable answer", %{conn: conn} do
    pool = pool!("lite", sibling: FakeUpstream.generic_5xx(503), refusing: own_usage_limit_429(), rotation: :sibling_first)

    conn = post_v1(conn, pool)

    assert conn.status == 429
    assert %{"error" => %{"type" => "rate_limit_error", "message" => "upstream request failed"} = error} = CodexPooler.JSON.decode!(conn.resp_body)
    refute Map.has_key?(error, "resets_at")
    assert get_resp_header(conn, "retry-after") == []
    assert {model_posts(pool.sibling_upstream), model_posts(pool.refusing_upstream)} == {1, 1}
  end

  defp own_usage_limit_429 do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + @own_reset_seconds
    {:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at, "resets_in_seconds" => @own_reset_seconds}}, [{"x-codex-rate-limit-reached-type", "rate_limit_reached"}]}
  end

  # The sibling's own refusal carries its exhausted primary window, which the
  # attempt records as quota evidence before the request moves on.
  defp sibling_usage_limit_429(resets_at) do
    headers = [
      {"x-codex-primary-used-percent", "100"},
      {"x-codex-primary-window-minutes", "300"},
      {"x-codex-primary-reset-at", Integer.to_string(resets_at)},
      {"x-codex-rate-limit-reached-type", "rate_limit_reached"}
    ]

    {:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at}}, headers}
  end

  defp deny_on_weekly_row_only!(identity, weekly_reset_at) do
    headers = [
      {"x-codex-secondary-used-percent", "96"},
      {"x-codex-secondary-window-minutes", "10080"},
      {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(weekly_reset_at))},
      {"x-codex-rate-limit-reached-type", "workspace_member_credits_depleted"}
    ]

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers, DateTime.utc_now() |> DateTime.truncate(:microsecond))
  end

  defp pool!(mode, opts) do
    sibling_upstream = start_upstream(Keyword.fetch!(opts, :sibling))
    refusing_upstream = start_upstream(Keyword.fetch!(opts, :refusing))
    setup = gateway_setup(sibling_upstream, compact?: true)
    refusing = gateway_upstream(setup.pool, refusing_upstream, "upstream-token-refusing", compact?: true)
    prime_routing_quota!(refusing.identity)
    use_deterministic_rotation!(setup.pool, 2)
    model = put_model_source_assignments!(setup.model, [setup.assignment, refusing.assignment])
    setup = %{setup | model: model}
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

    Map.merge(setup, %{
      sibling: %{identity: setup.identity, assignment: setup.assignment},
      refusing: refusing,
      sibling_upstream: sibling_upstream,
      refusing_upstream: refusing_upstream,
      rotation: Keyword.get(opts, :rotation, :any)
    })
  end

  defp reset_in(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp model_posts(upstream), do: Enum.count(FakeUpstream.requests(upstream), &(&1.path == "/backend-api/codex/responses"))

  defp post_v1(conn, pool) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
    |> post("/v1/responses", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => "synthetic relayed pool prompt", "stream" => false}))
  end

  defp post_native(conn, pool) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-openai-internal-codex-responses-lite", "true")
    |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
    |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => native_text_input("synthetic relayed pool prompt"), "stream" => true}))
  end

  defp assert_usage_limit!(conn, expected_seconds) do
    CodexPooler.TestDiagnostics.puts(fn -> "206-545 wire: #{conn.status} #{inspect(Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry"] end))} #{conn.resp_body}" end)

    assert conn.status == 429
    assert %{"error" => %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => @message, "resets_at" => resets_at, "resets_in_seconds" => seconds}} = CodexPooler.JSON.decode!(conn.resp_body)
    assert seconds in (expected_seconds - 5)..expected_seconds
    assert abs(resets_at - DateTime.to_unix(DateTime.utc_now()) - expected_seconds) <= 5
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]
  end
end
