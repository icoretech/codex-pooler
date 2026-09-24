defmodule CodexPoolerWeb.Runtime.ExhaustedPoolUsageLimitTest do
  # When every candidate of a Pool is excluded because its quota is exhausted
  # and the Pooler holds each candidate's reset, the answer is the provider's
  # own terminal shape for an exhausted account, with the earliest reset
  # (findings#206 row 206-508):
  #
  # - `429`, `error.type` `usage_limit_reached`, `resets_at` (epoch seconds)
  #   and `resets_in_seconds`, the fields the provider sends and the released
  #   client reads (`codex-rs/codex-api/src/api_bridge.rs` maps a `429` whose
  #   `error.type` is `usage_limit_reached` to `UsageLimitReached`, which ends
  #   the turn: `core/src/session/turn.rs`; its message names the reset);
  # - `Retry-After` (HTTP header, and the websocket error's `headers`), plus
  #   `x-should-retry: false` on HTTP once the wait exceeds 60 s, so openai-node
  #   and openai-python do not resend a request no wait under a minute admits;
  # - on `/v1`, the Pooler's own message instead of "upstream request failed".
  #
  # The error keeps its code `quota_exhausted` (saved-reset auto-redeem and the
  # request log read it), and the refused row records the `429` it answered.
  #
  # Unchanged: a reset the Pooler does not know (`quota_evidence_unavailable`,
  # a resetless or stale exclusion next to an exhausted one) stays the
  # retryable `503`, and so does a Pool where a candidate was taken out by an
  # open circuit rather than by quota: that circuit probes again within
  # `circuit_open_seconds` (60 s by default), so no reset bounds the wait.
  #
  # A Pool of two accounts can pass through both states in turn: the first
  # account's circuit opens after three quota `429`s while its sibling is
  # exhausted (still `503`), then the next usage poll marks the first account
  # exhausted too, with a known reset (now `429`). One test replays both.
  #
  # One BEAM node, FakeUpstream (never dispatched to), native HTTP SSE, native
  # websocket (owner forwarding on and off), `/v1/responses` (JSON and SSE),
  # `/v1/chat/completions` (JSON and SSE); Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @lite_header "x-openai-internal-codex-responses-lite"
  @message "upstream quota is exhausted until its reset time"
  @near_reset_seconds 30
  @early_reset_seconds 900
  @late_reset_seconds 1_800

  for mode <- ["full", "lite"] do
    @mode mode

    test "http sse #{mode}: an all-exhausted Pool answers 429 usage_limit_reached with the earliest reset", %{conn: conn} do
      pool = exhausted_pool!(@mode, [@early_reset_seconds, @late_reset_seconds])

      conn = post_native(conn, pool)

      # The exact answer, replayed to the released client by the P123 probe.
      CodexPooler.TestDiagnostics.puts(fn ->
        "206-508 wire http #{@mode}: " <>
          CodexPooler.JSON.encode!(%{status: conn.status, headers: Map.new(Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry", "content-type"] end)), body: conn.resp_body})
      end)

      assert_usage_limit!(conn, pool, @early_reset_seconds)
      assert get_resp_header(conn, "x-should-retry") == ["false"]
      assert_recorded_refusal!(pool, 429)
    end

    for forwarding <- [:forwarded, :direct] do
      @forwarding forwarding

      test "websocket #{forwarding} #{mode}: an all-exhausted Pool answers the wrapped 429 usage_limit_reached", _context do
        put_owner_forwarding!(@forwarding)
        pool = exhausted_pool!(@mode, [@late_reset_seconds, @early_reset_seconds])
        {_server, port} = start_public_endpoint_with_server!()

        terminal = send_websocket_turn!(port, pool)

        assert %{"type" => "error", "status" => 429, "error" => error, "headers" => headers} = terminal
        assert_usage_limit_error!(error, pool, @early_reset_seconds, @message)
        assert headers == %{"retry-after" => Integer.to_string(error["resets_in_seconds"])}
        assert_recorded_refusal!(pool, 429)
      end
    end

    for {route, stream?} <- [{"/v1/responses", false}, {"/v1/responses", true}, {"/v1/chat/completions", false}, {"/v1/chat/completions", true}] do
      @route route
      @stream stream?

      test "#{route} stream=#{stream?} #{mode}: an all-exhausted Pool answers 429 with the Pooler's message and the reset", %{conn: conn} do
        pool = exhausted_pool!(@mode, [@early_reset_seconds, @late_reset_seconds])

        conn = post_v1(conn, pool, @route, @stream)

        assert_usage_limit!(conn, pool, @early_reset_seconds)
        assert get_resp_header(conn, "x-should-retry") == ["false"]
        assert_recorded_refusal!(pool, 429)
      end
    end
  end

  test "http sse: a reset within a minute sends Retry-After without x-should-retry", %{conn: conn} do
    pool = exhausted_pool!("full", [@near_reset_seconds, @late_reset_seconds])

    conn = post_native(conn, pool)

    assert_usage_limit!(conn, pool, @near_reset_seconds)
    assert get_resp_header(conn, "x-should-retry") == []
  end

  test "http sse: a candidate whose reset is unknown keeps the retryable 503", %{conn: conn} do
    pool = two_candidate_pool!("full")
    prime_exhausted_routing_quota!(pool.first.identity, %{reset_at: reset_in(@early_reset_seconds)})
    prime_resetless_routing_quota!(pool.second.identity)

    conn = post_native(conn, pool)

    assert_retryable_503!(conn, pool, "quota_exhausted")
  end

  test "http sse: quota_evidence_unavailable keeps the retryable 503", %{conn: conn} do
    pool = two_candidate_pool!("full")
    prime_resetless_routing_quota!(pool.first.identity)
    prime_resetless_routing_quota!(pool.second.identity)

    conn = post_native(conn, pool)

    assert_retryable_503!(conn, pool, "quota_evidence_unavailable")
  end

  test "a circuit opened by quota 429s keeps the 503, then both accounts exhausted answer 429", %{conn: conn} do
    pool = two_candidate_pool!("lite")
    # First account: dispatched, refused three times, circuit open for 60 s; its quota
    # evidence still read usable (97%) until the next usage poll.
    prime_routing_quota!(pool.first.identity)
    circuits = open_quota_circuit!(pool, pool.first.assignment)
    # Second account: exhausted since earlier, reset known.
    prime_exhausted_routing_quota!(pool.second.identity, %{reset_at: reset_in(@early_reset_seconds)})

    first = post_native(conn, pool)
    # The open circuit bounds the wait: it probes again within a minute (row 206-532).
    assert_retryable_503!(first, pool, "quota_exhausted", :circuit_probe)

    # The usage poll marks the first account exhausted with its own later reset, and the
    # circuit's probe time passes: every candidate is quota-excluded.
    prime_exhausted_routing_quota!(pool.first.identity, %{reset_at: reset_in(@late_reset_seconds)})
    let_circuits_probe!(circuits)

    second = post_native(build_conn(), pool)
    assert_usage_limit!(second, pool, @early_reset_seconds)

    assert Enum.map(settled_rows!(pool, 2), &{&1.status, &1.last_error_code, &1.response_status_code}) == [
             {"rejected", "quota_exhausted", 503},
             {"rejected", "quota_exhausted", 429}
           ]
  end

  # An account refused at workspace level whose refusal refreshed only its
  # weekly header row (96%, resetting the next day), while its 5-hour row, not
  # exhausted, resets about an hour later, next to an exhausted sibling. The
  # Pool's hint is its earliest return: the sibling's reset (findings#206 row
  # 206-508), or the denied account's earliest fresh reset rather than the
  # marked row's, which stays the denial's deadline (row 206-522).
  for {label, sibling_reset, expected} <- [{"the exhausted sibling resets first", 2_700, 2_700}, {"the denied account's 5-hour window resets first", 10_800, 3_600}] do
    @sibling_reset sibling_reset
    @expected expected

    test "#{label}: a weekly-only denial row next to an exhausted sibling answers the Pool's earliest return", %{conn: conn} do
      pool = two_candidate_pool!("lite")
      prime_routing_quota!(pool.first.identity, %{used_percent: Decimal.new("97"), reset_at: reset_in(3_600)})
      deny_on_weekly_row_only!(pool.first.identity, reset_in(30 * 3_600))
      prime_exhausted_routing_quota!(pool.second.identity, %{reset_at: reset_in(@sibling_reset)})

      conn = post_native(conn, pool)

      assert_usage_limit!(conn, pool, @expected)
      assert_recorded_refusal!(pool, 429)
    end
  end

  test "an open circuit next to an account-denied candidate keeps the retryable 503", %{conn: conn} do
    pool = two_candidate_pool!("full")
    prime_routing_quota!(pool.first.identity)
    _circuits = open_quota_circuit!(pool, pool.first.assignment)
    prime_routing_quota!(pool.second.identity, %{used_percent: Decimal.new("97"), reset_at: reset_in(3_600)})
    deny_on_weekly_row_only!(pool.second.identity, reset_in(30 * 3_600))

    conn = post_native(conn, pool)

    assert_retryable_503!(conn, pool, "quota_exhausted", :circuit_probe)
  end

  test "a 5-hour block known from usage: the exhausted primary, not the marked weekly row, sets the hint", %{conn: conn} do
    pool = two_candidate_pool!("full")
    deny_on_weekly_row_only!(pool.first.identity, reset_in(30 * 3_600))
    prime_exhausted_routing_quota!(pool.first.identity, %{source: "codex_usage_api", reset_at: reset_in(3_600)})
    prime_exhausted_routing_quota!(pool.second.identity, %{reset_at: reset_in(10_800)})

    conn = post_native(conn, pool)

    assert_usage_limit!(conn, pool, 3_600)
  end

  test "http sse: one exhausted candidate next to an eligible one routes to the eligible one", %{conn: conn} do
    pool = two_candidate_pool!("full")
    prime_exhausted_routing_quota!(pool.first.identity, %{reset_at: reset_in(@early_reset_seconds)})
    prime_routing_quota!(pool.second.identity)
    [exhausted_upstream, eligible_upstream] = pool.upstreams
    FakeUpstream.set_mode(eligible_upstream, stream_success_sse())

    conn = post_native(conn, pool)

    assert conn.status == 200
    assert get_resp_header(conn, "retry-after") == []
    assert {FakeUpstream.count(exhausted_upstream), model_posts(eligible_upstream)} == {0, 1}
    assert [row] = settled_rows!(pool, 1)
    assert {row.status, row.response_status_code} == {"succeeded", 200}
  end

  # Today's behaviour, pinned for the lead's question on 206-508: a provider
  # `429` usage limit answered before any output, on the first of two
  # candidates, moves the same request to the other eligible candidate; the
  # client sees the second candidate's answer, never the provider's `429`.
  for {label, stream?} <- [{"http sse", true}, {"http json", false}] do
    @stream stream?
    @label label

    test "#{label}: a provider usage-limit 429 before output fails over to the other eligible candidate", %{conn: conn} do
      {setup, refusing_upstream, serving_upstream} = stream_retry_setup(provider_usage_limit_429(), if(@stream, do: stream_success_sse(), else: FakeUpstream.json_response(%{"id" => "resp_failover_json", "object" => "response", "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}})))

      conn =
        conn
        |> put_req_header("authorization", setup.authorization)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
        |> post(@turn_endpoint, CodexPooler.JSON.encode!(%{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic failover prompt"), "stream" => @stream}))

      rows = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      attempts = Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      measured = %{
        status: conn.status,
        upstream_posts: {model_posts(refusing_upstream), model_posts(serving_upstream)},
        rows: Enum.map(rows, &{&1.status, &1.response_status_code}),
        attempts: Enum.map(attempts, &{&1.status, &1.upstream_status_code})
      }

      CodexPooler.TestDiagnostics.puts(fn -> "206-508 provider 429 failover #{@label}: #{inspect(measured)}" end)

      assert measured == %{
               status: 200,
               upstream_posts: {1, 1},
               rows: [{"succeeded", 200}],
               attempts: [{"retryable_failed", 429}, {"succeeded", 200}]
             }
    end
  end

  test "the compatibility matrix names the answer measured here" do
    fixture = CodexPooler.CompatibilityMatrix.fixture!(:exhausted_pool_usage_limit)

    assert fixture.terminal == %{status: 429, type: "usage_limit_reached", code: "quota_exhausted", fields: ["resets_at", "resets_in_seconds"], retry_after: :earliest_reset_seconds, x_should_retry_false_above_seconds: 60}
    assert fixture.retryable == %{status: 503, codes: ["quota_evidence_unavailable", "quota_exhausted"], when: [:reset_unknown, :circuit_excluded_candidate]}
    assert fixture.v1_message == @message
    assert fixture.recorded_status == :answered_status
  end

  defp exhausted_pool!(mode, [first_reset, second_reset]) do
    pool = two_candidate_pool!(mode)
    prime_exhausted_routing_quota!(pool.first.identity, %{reset_at: reset_in(first_reset)})
    prime_exhausted_routing_quota!(pool.second.identity, %{reset_at: reset_in(second_reset)})
    pool
  end

  defp two_candidate_pool!(mode) do
    first_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    second_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(first_upstream, quota?: false, compact?: true)
    second = gateway_upstream(setup.pool, second_upstream, "upstream-token-exhausted-second", compact?: true)
    model = put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
    setup = %{setup | model: model}
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

    Map.merge(setup, %{
      mode: mode,
      first: %{identity: setup.identity, assignment: setup.assignment},
      second: second,
      upstreams: [first_upstream, second_upstream]
    })
  end

  defp reset_in(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp open_quota_circuit!(pool, assignment) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- ["proxy_http", "proxy_stream"] do
      %RoutingCircuitState{
        pool_id: pool.pool.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        model_identifier: pool.model.exposed_model_id,
        route_class: route_class,
        status: "open",
        reason_code: "upstream_rate_limited",
        failure_count: 3,
        success_count: 0,
        opened_at: now,
        last_failure_at: now,
        next_probe_at: DateTime.add(now, 60, :second),
        metadata: %{"probe_in_flight_count" => 0},
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()
    end
  end

  defp let_circuits_probe!(circuits) do
    due = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
    Enum.each(circuits, &(&1 |> Ecto.Changeset.change(next_probe_at: due) |> Repo.update!()))
  end

  # The provider's answer for an exhausted account (the rust-v0.156.1 client's
  # own fixture shape, `core/tests/suite/client_websockets.rs`) with the
  # workspace marker of a credits-depleted member account.
  defp provider_usage_limit_429 do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600

    {:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "The usage limit has been reached", "resets_at" => resets_at, "resets_in_seconds" => 3_600}}, [{"x-codex-rate-limit-reached-type", "workspace_member_credits_depleted"}]}
  end

  # The real header path, as a provider 429 carrying only the weekly row
  # records it (findings#206 row 206-522).
  defp deny_on_weekly_row_only!(identity, weekly_reset_at) do
    headers = [
      {"x-codex-secondary-used-percent", "96"},
      {"x-codex-secondary-window-minutes", "10080"},
      {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(weekly_reset_at))},
      {"x-codex-rate-limit-reached-type", "workspace_member_credits_depleted"}
    ]

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, [window]} = QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers, now)
    assert window.metadata["rate_limit_reached_type"] == "workspace_member_credits_depleted"
  end

  defp model_posts(upstream), do: Enum.count(FakeUpstream.requests(upstream), &(&1.path == @turn_endpoint))

  defp post_native(conn, pool) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> maybe_lite(pool)
    |> post(@turn_endpoint, CodexPooler.JSON.encode!(native_body(pool)))
  end

  defp post_v1(conn, pool, "/v1/responses", stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/responses", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => "synthetic exhausted pool prompt", "stream" => stream?}))
  end

  defp post_v1(conn, pool, "/v1/chat/completions", stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/chat/completions",
      CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic exhausted pool prompt"}], "stream" => stream?})
    )
  end

  defp maybe_lite(conn, %{mode: "lite"}), do: put_req_header(conn, @lite_header, "true")
  defp maybe_lite(conn, _pool), do: conn

  defp native_body(pool) do
    %{
      "model" => pool.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic exhausted pool prompt"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true
    }
  end

  defp assert_usage_limit!(conn, pool, expected_seconds) do
    assert conn.status == 429
    assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
    assert_usage_limit_error!(error, pool, expected_seconds, @message)
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(error["resets_in_seconds"])]
  end

  defp assert_usage_limit_error!(error, pool, expected_seconds, message) do
    assert %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => ^message, "resets_at" => resets_at, "resets_in_seconds" => seconds} = error
    assert is_integer(resets_at) and is_integer(seconds)
    assert seconds in (expected_seconds - 5)..expected_seconds
    assert abs(resets_at - DateTime.to_unix(DateTime.utc_now()) - expected_seconds) <= 5
    refute Map.has_key?(error, "plan_type")
    assert Enum.all?(pool.upstreams, &(FakeUpstream.count(&1) == 0))
  end

  defp assert_retryable_503!(conn, pool, code, retry_after \\ :none) do
    assert conn.status == 503
    assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
    assert error["code"] == code
    assert error["type"] == "server_error"
    refute Map.has_key?(error, "resets_at")
    assert_circuit_retry_after!(get_resp_header(conn, "retry-after"), retry_after)
    assert get_resp_header(conn, "x-should-retry") == []
    assert Enum.all?(pool.upstreams, &(FakeUpstream.count(&1) == 0))
  end

  # A candidate taken out by an open circuit bounds the wait by that circuit's
  # next probe, at most a minute (findings#206 row 206-532).
  defp assert_circuit_retry_after!(header, :none), do: assert(header == [])
  defp assert_circuit_retry_after!([seconds], :circuit_probe), do: assert(String.to_integer(seconds) in 1..60)

  defp assert_recorded_refusal!(pool, status) do
    assert [row] = settled_rows!(pool, 1)
    assert {row.status, row.last_error_code, row.response_status_code} == {"rejected", "quota_exhausted", status}
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^row.id), :count) == 0
  end

  # One request on its own connection, as the released client sends a turn.
  defp send_websocket_turn!(port, pool) do
    thread_id = Ecto.UUID.generate()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers =
      [
        {"authorization", pool.authorization},
        {"session-id", thread_id},
        {"thread-id", thread_id},
        {"x-client-request-id", thread_id},
        {"x-codex-window-id", "#{thread_id}:0"}
      ] ++ if(pool.mode == "lite", do: [{@lite_header, "true"}], else: [])

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    frame =
      pool
      |> native_body()
      |> Map.put("type", "response.create")
      |> Map.put("client_metadata", %{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "#{thread_id}-turn"})
      |> CodexPooler.JSON.encode!()

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      receive_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] ->
        CodexPooler.TestDiagnostics.puts(fn -> "206-508 wire websocket: " <> text end)
        terminal

      _progress ->
        receive_terminal!(conn, websocket, ref)
    end
  end

  # The socket writes the terminal before its task settles the row; poll the
  # rows within a detection budget.
  defp settled_rows!(pool, count) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> Repo.all(from(request in Request, where: request.pool_id == ^pool.pool.id, order_by: [asc: request.admitted_at])) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
