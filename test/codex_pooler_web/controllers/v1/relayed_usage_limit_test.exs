defmodule CodexPoolerWeb.V1.RelayedUsageLimitTest do
  # A provider usage-limit `429` that reaches `/v1` because it came from the
  # last eligible candidate (nothing left to fail over to) is the same state
  # the Pooler answers on its own when routing finds every candidate
  # exhausted (findings#206 row 206-508), seen one request earlier. It gets
  # the same terminal answer (row 206-531):
  #
  # - `429`, `error.type` `usage_limit_reached`, the Pooler's code
  #   `quota_exhausted` and message, `resets_at` (epoch seconds) and
  #   `resets_in_seconds` from the provider's own reset;
  # - `Retry-After`, plus `x-should-retry: false` once the wait exceeds 60 s,
  #   so openai-python and openai-node stop instead of resending twice;
  # - no provider message, `plan_type` or other body field.
  #
  # A `429` whose reset is not known (a plain throttle, a usage limit without a
  # reset still ahead) keeps the redacted `rate_limit_error` the SDKs retry.
  #
  # One BEAM node, one assignment, FakeUpstream; `/v1/responses` and
  # `/v1/chat/completions`, JSON and SSE; Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @message "upstream quota is exhausted until its reset time"
  @provider_message "synthetic provider usage limit text"
  @reset_seconds 3_600
  @near_reset_seconds 30
  @routes [{"/v1/responses", false}, {"/v1/responses", true}, {"/v1/chat/completions", false}, {"/v1/chat/completions", true}]

  for mode <- ["full", "lite"], {route, stream?} <- @routes do
    @mode mode
    @route route
    @stream stream?

    test "#{route} stream=#{stream?} #{mode}: a relayed provider usage-limit 429 answers usage_limit_reached with the provider's reset", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
      pool = single_candidate_pool!(@mode, provider_usage_limit_429(%{"resets_at" => resets_at, "resets_in_seconds" => @reset_seconds}))

      conn = post_v1(conn, pool, @route, @stream)

      error = assert_usage_limit!(conn, @reset_seconds)
      assert error["resets_at"] == resets_at
      assert get_resp_header(conn, "x-should-retry") == ["false"]
      assert FakeUpstream.count(pool.upstream) == 1
      assert_recorded!(pool, 429)
    end
  end

  test "a reset within a minute sends Retry-After without x-should-retry", %{conn: conn} do
    pool = single_candidate_pool!("lite", provider_usage_limit_429(%{"resets_in_seconds" => @near_reset_seconds}))

    conn = post_v1(conn, pool, "/v1/responses", false)

    assert_usage_limit!(conn, @near_reset_seconds)
    assert get_resp_header(conn, "x-should-retry") == []
  end

  for {label, mode_fun} <- [
        {"a plain provider throttle", :generic_throttle},
        {"a usage limit whose reset is already past", :past_reset},
        {"a usage limit that names no reset", :resetless}
      ] do
    @mode_fun mode_fun

    test "#{label} keeps the redacted rate_limit_error", %{conn: conn} do
      pool = single_candidate_pool!("lite", upstream_mode(@mode_fun))

      conn = post_v1(conn, pool, "/v1/responses", false)

      assert conn.status == 429
      assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
      assert %{"message" => "upstream request failed", "type" => "rate_limit_error"} = error
      refute Map.has_key?(error, "resets_at")
      assert get_resp_header(conn, "retry-after") == []
      assert get_resp_header(conn, "x-should-retry") == []
    end
  end

  # The native route used to relay this refusal's provider body, and a
  # streaming request (the released client's HTTP transport) an empty body,
  # which the client cannot read as a usage limit.
  for stream? <- [true, false] do
    @stream stream?

    test "native stream=#{stream?}: the relayed provider usage-limit 429 answers the same terminal usage limit", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @reset_seconds
      pool = single_candidate_pool!("lite", provider_usage_limit_429(%{"resets_at" => resets_at, "resets_in_seconds" => @reset_seconds}))

      conn =
        conn
        |> put_req_header("authorization", pool.authorization)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-openai-internal-codex-responses-lite", "true")
        |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => native_text_input("synthetic relayed usage limit prompt"), "stream" => @stream}))

      error = assert_usage_limit!(conn, @reset_seconds)
      assert error["resets_at"] == resets_at
      assert get_resp_header(conn, "x-should-retry") == ["false"]
      assert_recorded!(pool, 429)
    end
  end

  test "the compatibility matrix names the answer measured here" do
    fixture = CodexPooler.CompatibilityMatrix.fixture!(:exhausted_pool_usage_limit)

    assert fixture.v1_message == @message
    assert fixture.relayed_provider_usage_limit == %{when: :last_candidate_provider_429, reset: ["resets_at", "resets_in_seconds"], answer: :terminal, without_reset: %{v1_type: "rate_limit_error"}, recorded: %{status: 429, code: "upstream_rate_limited"}}
  end

  defp upstream_mode(:generic_throttle), do: FakeUpstream.generic_429()
  defp upstream_mode(:past_reset), do: provider_usage_limit_429(%{"resets_at" => DateTime.to_unix(DateTime.utc_now()) - 60})
  defp upstream_mode(:resetless), do: provider_usage_limit_429(%{})

  # The provider's answer for an exhausted account (the released client's own
  # fixture shape) with the workspace marker header a member account carries.
  defp provider_usage_limit_429(reset_fields, extra_headers \\ []) do
    error = Map.merge(%{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team"}, reset_fields)
    {:json_headers, 429, %{"error" => error}, [{"x-codex-rate-limit-reached-type", "workspace_member_usage_limit_reached"} | extra_headers]}
  end

  defp single_candidate_pool!(mode, upstream_mode) do
    upstream = start_upstream(upstream_mode)
    setup = gateway_setup(upstream, compact?: true)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    Map.merge(setup, %{mode: mode, upstream: upstream})
  end

  defp post_v1(conn, pool, "/v1/responses", stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/responses", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => "synthetic relayed usage limit prompt", "stream" => stream?}))
  end

  defp post_v1(conn, pool, "/v1/chat/completions", stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/chat/completions",
      CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic relayed usage limit prompt"}], "stream" => stream?})
    )
  end

  defp assert_usage_limit!(conn, expected_seconds) do
    CodexPooler.TestDiagnostics.puts(fn -> "206-531 wire: #{conn.status} #{inspect(Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry", "content-type"] end))} #{conn.resp_body}" end)

    assert conn.status == 429
    assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
    assert %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => @message, "resets_at" => resets_at, "resets_in_seconds" => seconds} = error
    assert is_integer(resets_at) and is_integer(seconds)
    assert seconds in (expected_seconds - 5)..expected_seconds
    assert Map.keys(error) |> Enum.sort() == ["code", "message", "param", "resets_at", "resets_in_seconds", "type"]
    refute conn.resp_body =~ @provider_message
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]
    error
  end

  # The row and its one attempt keep the provider's refusal.
  defp assert_recorded!(pool, status) do
    assert [%Request{} = row] = Repo.all(from(request in Request, where: request.pool_id == ^pool.pool.id))
    assert {row.status, row.response_status_code, row.last_error_code} == {"failed", status, "upstream_rate_limited"}
    assert [%Attempt{} = attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^row.id))
    assert {attempt.status, attempt.upstream_status_code} == {"failed", status}
  end
end
