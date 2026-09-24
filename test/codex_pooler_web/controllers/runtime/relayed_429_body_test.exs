defmodule CodexPoolerWeb.Runtime.Relayed429BodyTest do
  # A provider `429` on the last eligible candidate that the Pooler does not
  # answer with its terminal usage limit (the reset or a sibling's return is
  # not known, or the refusal is a plain throttle) is relayed on the native
  # routes. A streaming request used to get it with an EMPTY body, because
  # the drained rejection body was not passed through, and the released Codex
  # client then showed "exceeded retry limit, last status: 429" whatever the
  # provider said (findings#206 row 206-589); an explicit Full request got a
  # `server_error` body. The native answer now carries, in Full and Lite,
  # streaming or not, the tokens the client classifies a `429` by
  # (`codex-api/src/api_bridge.rs`: `error.type` `usage_limit_reached` is
  # `UsageLimitReached`, any other `429` `RetryLimit`) and the provider's
  # integer reset, with the Pooler's message: the provider's message and plan
  # never travel, as in the terminal usage-limit answer (row 206-531).
  #
  # One BEAM node, FakeUpstream, native HTTP SSE and native HTTP JSON; Full
  # and Lite. Owner forwarding on and off: an HTTP turn never goes through a
  # websocket owner, so both arms must answer the same.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @lite_header "x-openai-internal-codex-responses-lite"
  @provider_message "synthetic provider usage limit text"

  # {arm, provider error, the error the client receives}
  @arms [
    {:resetless_usage_limit, %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team"}, %{"type" => "usage_limit_reached", "code" => "upstream_rate_limited", "message" => "upstream usage limit reached"}},
    {:plain_throttle, %{"code" => "rate_limit_exceeded", "message" => @provider_message}, %{"type" => "rate_limit_error", "code" => "rate_limit_exceeded", "message" => "upstream rate limited the request"}}
  ]

  for mode <- ["full", "lite"], forwarding <- [:forwarded, :direct], stream? <- [true, false], {arm, error, answered} <- @arms do
    @mode mode
    @forwarding forwarding
    @stream stream?
    @arm arm
    @error error
    @answered answered

    test "#{arm} #{mode} #{forwarding} stream=#{stream?}: the relayed 429 carries the provider's body", %{conn: conn} do
      put_owner_forwarding!(@forwarding)
      upstream = start_upstream({:json_headers, 429, %{"error" => @error}, []})
      pool = pool!(upstream, @mode)

      conn = post_native(conn, pool, @stream)

      CodexPooler.TestDiagnostics.puts(fn -> "206-589 wire #{@arm} #{@mode} #{@forwarding} stream=#{@stream}: #{conn.status} #{inspect(get_resp_header(conn, "content-type"))} #{conn.resp_body}" end)

      assert conn.status == 429
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert CodexPooler.JSON.decode!(conn.resp_body) == %{"error" => @answered}
      refute conn.resp_body =~ @provider_message
      assert FakeUpstream.count(upstream) == 1
      assert [%Request{response_status_code: 429, last_error_code: "upstream_rate_limited"}] = Repo.all(from(r in Request, where: r.pool_id == ^pool.pool.id))
    end
  end

  test "a usage limit with a reset but a sibling whose return is unknown relays the provider's body on HTTP SSE", %{conn: conn} do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600
    error = %{"type" => "usage_limit_reached", "message" => @provider_message, "resets_at" => resets_at}
    refusing = start_upstream({:json_headers, 429, %{"error" => error}, [{"x-codex-rate-limit-reached-type", "rate_limit_reached"}]})
    sibling = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(refusing, compact?: true)
    other = gateway_upstream(setup.pool, sibling, "upstream-token-unknown-sibling", compact?: true)
    prime_resetless_routing_quota!(other.identity)
    setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, other.assignment])}

    conn = post_native(conn, Map.put(setup, :mode, "full"), true)

    assert conn.status == 429

    assert CodexPooler.JSON.decode!(conn.resp_body) == %{
             "error" => %{"type" => "usage_limit_reached", "code" => "upstream_rate_limited", "message" => "upstream usage limit reached", "resets_at" => resets_at}
           }

    refute conn.resp_body =~ @provider_message
    assert FakeUpstream.count(sibling) == 0
  end

  # The relayed answer's retry advice follows the house rule (findings#206
  # row 206-597): `Retry-After` in seconds when the provider named a reset,
  # plus `x-should-retry: false` once the wait exceeds 60 s; none without a
  # reset, so a plain throttle keeps the SDKs' own backoff. The relay is the
  # answer when the Pool's terminal advice is withheld: a sibling whose return
  # is not known.
  for mode <- ["full", "lite"],
      stream? <- [true, false],
      {label, fields, retry_after, should_retry} <- [
        {"reset in an hour", %{"resets_in_seconds" => 3_600}, "3600", ["false"]},
        {"reset within a minute", %{"resets_in_seconds" => 30}, "30", []},
        {"no reset", %{}, nil, []}
      ] do
    @mode mode
    @stream stream?
    @fields fields
    @retry_after retry_after
    @should_retry should_retry

    test "#{mode} stream=#{stream?} #{label}: the relayed usage limit carries the retry advice", %{conn: conn} do
      error = Map.merge(%{"type" => "usage_limit_reached", "message" => @provider_message}, @fields)
      pool = unknown_sibling_pool!({:json_headers, 429, %{"error" => error}, []}, @mode)

      conn = post_native(conn, pool, @stream)

      assert conn.status == 429
      assert %{"error" => %{"type" => "usage_limit_reached", "message" => "upstream usage limit reached"}} = CodexPooler.JSON.decode!(conn.resp_body)
      assert get_resp_header(conn, "retry-after") == List.wrap(@retry_after)
      assert get_resp_header(conn, "x-should-retry") == @should_retry
    end
  end

  # Pin: the provider's own `Retry-After` is not relayed, so the answer
  # carries exactly one, the advice.
  test "a provider's own Retry-After is replaced, not duplicated, when the reset is known", %{conn: conn} do
    error = %{"type" => "usage_limit_reached", "message" => @provider_message, "resets_in_seconds" => 120}
    pool = unknown_sibling_pool!({:json_headers, 429, %{"error" => error}, [{"retry-after", "7"}]}, "lite")

    conn = post_native(conn, pool, true)

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["120"]
    assert get_resp_header(conn, "x-should-retry") == ["false"]
  end

  defp unknown_sibling_pool!(refusal, mode) do
    refusing = start_upstream(refusal)
    sibling = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(refusing, compact?: true)
    other = gateway_upstream(setup.pool, sibling, "upstream-token-unknown-sibling-advice", compact?: true)
    prime_resetless_routing_quota!(other.identity)
    setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, other.assignment])}
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    Map.put(setup, :mode, mode)
  end

  defp pool!(upstream, mode) do
    setup = gateway_setup(upstream, compact?: true)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    Map.put(setup, :mode, mode)
  end

  defp post_native(conn, pool, stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> then(&if pool.mode == "lite", do: put_req_header(&1, @lite_header, "true"), else: &1)
    |> post(
      @turn_endpoint,
      CodexPooler.JSON.encode!(%{
        "model" => pool.model.exposed_model_id,
        "instructions" => "synthetic instructions",
        "input" => native_text_input("synthetic relayed throttle prompt"),
        "tools" => [],
        "store" => false,
        "stream" => stream?
      })
    )
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
