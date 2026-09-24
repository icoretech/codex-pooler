defmodule CodexPoolerWeb.Runtime.UsageLimitRecordTest do
  # The terminal usage-limit answer (findings#206 rows 206-508, 206-531) is
  # recorded as it was sent (row 206-553): the reset the client was told,
  # `resets_at` (epoch seconds) and `resets_in_seconds`, is kept on the
  # refused row and on the log line, so the advice does not have to be
  # re-derived from the exclusions under whatever rule is current later.
  #
  # - routed refusal (every candidate exhausted): the row's `gateway_denial`
  #   carries both, on native HTTP SSE, the native websocket and `/v1`;
  # - relayed provider `429` on the last candidate: the attempt's
  #   `response_metadata.usage_limit` carries both;
  # - log: HTTP `request_completed` and the websocket `websocket native turn
  #   failed` line carry both. The websocket line is `[info]`, like the HTTP
  #   line: the answer is the designed terminal refusal, not a failure;
  # - the request-log drawer's quota line shows the reset that was answered.
  #
  # One BEAM node, FakeUpstream, Full.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounting.RequestLogs.ErrorSummaries
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @turn_endpoint "/backend-api/codex/responses"
  @early 900
  @late 1_800

  # The lines under test are `info`, below the suite's configured level.
  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    CodexPoolerWeb.RequestLogger.attach()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test "native http sse: the routed answer's reset is on the row, the drawer summary and the request_completed line", %{conn: conn} do
    pool = exhausted_pool!()

    {conn, log} = with_log([level: :info], fn -> post_native(conn, pool) end)

    answered = answered!(conn)
    assert [row] = settled_rows!(pool, 1)
    assert Map.take(row.request_metadata["gateway_denial"], ["resets_at", "resets_in_seconds"]) == answered
    assert log =~ ~r/request_completed method=POST path=\/backend-api\/codex\/responses status=429 .*resets_at=#{answered["resets_at"]} resets_in_seconds=#{answered["resets_in_seconds"]}/

    summaries = ErrorSummaries.build(row, row.request_metadata, [])
    advised = answered["resets_at"] |> DateTime.from_unix!() |> DateTime.to_iso8601()
    denial = Enum.find(summaries, &(summary_field(&1, :kind) == "gateway_denial"))
    assert summary_field(denial, :advised_reset_at) == advised
    assert summary_field(denial, :advised_retry_seconds) == answered["resets_in_seconds"]
  end

  test "/v1/responses: the routed answer's reset is on the row and the request_completed line", %{conn: conn} do
    pool = exhausted_pool!()

    {conn, log} =
      with_log([level: :info], fn ->
        conn
        |> put_req_header("authorization", pool.authorization)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/responses", CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => "synthetic prompt"}))
      end)

    answered = answered!(conn)
    assert [row] = settled_rows!(pool, 1)
    assert Map.take(row.request_metadata["gateway_denial"], ["resets_at", "resets_in_seconds"]) == answered
    assert log =~ ~r/request_completed method=POST path=\/v1\/responses status=429 .*resets_at=#{answered["resets_at"]} resets_in_seconds=#{answered["resets_in_seconds"]}/
  end

  test "native websocket: the routed answer's reset is on the row and on the [info] turn-failed line" do
    pool = exhausted_pool!()
    {_server, port} = start_public_endpoint_with_server!()

    {terminal, log} =
      with_log([level: :info], fn ->
        terminal = send_websocket_turn!(port, pool)
        _rows = settled_rows!(pool, 1)
        terminal
      end)

    assert %{"status" => 429, "error" => error} = terminal
    answered = Map.take(error, ["resets_at", "resets_in_seconds"])
    assert map_size(answered) == 2
    assert [row] = settled_rows!(pool, 1)
    assert Map.take(row.request_metadata["gateway_denial"], ["resets_at", "resets_in_seconds"]) == answered

    assert log =~
             ~r/\[info\] websocket native turn failed .*error_code=quota_exhausted .*resets_at=#{answered["resets_at"]} resets_in_seconds=#{answered["resets_in_seconds"]}/

    refute log =~ ~r/\[warning\] websocket native turn failed/
  end

  for {label, path} <- [{"native", @turn_endpoint}, {"/v1", "/v1/responses"}] do
    @path path

    test "#{label}: a relayed provider usage-limit 429 records the reset it answered on the attempt and the log line", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600
      upstream = start_upstream(provider_usage_limit_429(resets_at))
      pool = gateway_setup(upstream, compact?: true)

      {conn, log} =
        with_log([level: :info], fn ->
          conn
          |> put_req_header("authorization", pool.authorization)
          |> put_req_header("content-type", "application/json")
          |> post(@path, CodexPooler.JSON.encode!(%{"model" => pool.model.exposed_model_id, "input" => native_text_input("synthetic prompt"), "stream" => false}))
        end)

      answered = answered!(conn)
      assert answered["resets_at"] == resets_at
      assert [row] = Repo.all(from(request in Request, where: request.pool_id == ^pool.pool.id))
      assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^row.id))
      assert attempt.response_metadata["usage_limit"] == answered
      assert log =~ ~r/request_completed method=POST path=#{Regex.escape(@path)} status=429 .*resets_at=#{resets_at} resets_in_seconds=#{answered["resets_in_seconds"]}/
    end
  end

  test "the retryable 503 records no reset and its line carries none", %{conn: conn} do
    pool = two_candidate_pool!()
    prime_resetless_routing_quota!(pool.first.identity)
    prime_resetless_routing_quota!(pool.second.identity)

    {conn, log} = with_log([level: :info], fn -> post_native(conn, pool) end)

    assert conn.status == 503
    assert [row] = settled_rows!(pool, 1)
    refute Map.has_key?(row.request_metadata["gateway_denial"], "resets_at")
    refute log =~ "resets_at="
  end

  defp summary_field(summary, key), do: Map.get(summary, key) || Map.get(summary, Atom.to_string(key))

  defp answered!(conn) do
    assert conn.status == 429
    assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
    answered = Map.take(error, ["resets_at", "resets_in_seconds"])
    assert %{"resets_at" => resets_at, "resets_in_seconds" => seconds} = answered
    assert is_integer(resets_at) and is_integer(seconds)
    answered
  end

  defp exhausted_pool! do
    pool = two_candidate_pool!()
    prime_exhausted_routing_quota!(pool.first.identity, %{reset_at: reset_in(@early)})
    prime_exhausted_routing_quota!(pool.second.identity, %{reset_at: reset_in(@late)})
    pool
  end

  defp two_candidate_pool! do
    first_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    second_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(first_upstream, quota?: false, compact?: true)
    second = gateway_upstream(setup.pool, second_upstream, "upstream-token-record-second", compact?: true)
    model = put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
    Map.merge(%{setup | model: model}, %{first: %{identity: setup.identity}, second: second})
  end

  defp reset_in(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp provider_usage_limit_429(resets_at) do
    {:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at}}, [{"x-codex-rate-limit-reached-type", "workspace_member_usage_limit_reached"}]}
  end

  defp post_native(conn, pool) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> post(@turn_endpoint, CodexPooler.JSON.encode!(native_body(pool)))
  end

  defp native_body(pool) do
    %{
      "model" => pool.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic prompt"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true
    }
  end

  defp send_websocket_turn!(port, pool) do
    thread_id = Ecto.UUID.generate()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", pool.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"}
    ]

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
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> terminal
      _progress -> receive_terminal!(conn, websocket, ref)
    end
  end

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
end
