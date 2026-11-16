defmodule CodexPoolerWeb.Runtime.UsageCapPoolAnswerTest do
  # An operator weekly usage cap (public issue #637) takes an account out of new
  # work once its weekly window reads the capped share used. The turn goes to an
  # uncapped sibling; a Pool whose every account is capped answers the same
  # terminal `429 usage_limit_reached` an exhausted Pool answers, with the
  # soonest weekly reset among the capped accounts, so the released client ends
  # the turn and names the time instead of retrying.
  #
  # One BEAM node, FakeUpstream, native HTTP SSE and native websocket (owner
  # forwarding on and off); Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @lite_header "x-openai-internal-codex-responses-lite"
  @early_reset_seconds 2 * 86_400
  @late_reset_seconds 3 * 86_400

  for mode <- ["full", "lite"] do
    @mode mode

    test "http sse #{mode}: a capped account is skipped for its uncapped sibling", %{conn: conn} do
      pool = two_candidate_pool!(@mode)
      prime_weekly!(pool.first.identity, "85", @early_reset_seconds)
      prime_weekly!(pool.second.identity, "85", @late_reset_seconds)
      cap!(pool.first.identity, 80)

      _conn = post_native(conn, pool)

      [first_upstream, second_upstream] = pool.upstreams
      assert FakeUpstream.count(first_upstream) == 0
      assert FakeUpstream.count(second_upstream) > 0
    end

    test "http sse #{mode}: an all-capped Pool answers 429 usage_limit_reached with the soonest weekly reset", %{conn: conn} do
      pool = capped_pool!(@mode)

      conn = post_native(conn, pool)

      assert conn.status == 429
      assert %{"error" => error} = CodexPooler.JSON.decode!(conn.resp_body)
      assert_usage_limit_error!(error, pool, @early_reset_seconds)
      assert get_resp_header(conn, "retry-after") == [Integer.to_string(error["resets_in_seconds"])]
      assert get_resp_header(conn, "x-should-retry") == ["false"]
      assert_recorded_refusal!(pool, 429)
    end

    for forwarding <- [:forwarded, :direct] do
      @forwarding forwarding

      test "websocket #{forwarding} #{mode}: an all-capped Pool answers the wrapped 429 usage_limit_reached", _context do
        put_owner_forwarding!(@forwarding)
        pool = capped_pool!(@mode)
        {_server, port} = start_public_endpoint_with_server!()

        terminal = send_websocket_turn!(port, pool)

        assert %{"type" => "error", "status" => 429, "error" => error, "headers" => headers} = terminal
        assert_usage_limit_error!(error, pool, @early_reset_seconds)
        assert headers == %{"retry-after" => Integer.to_string(error["resets_in_seconds"])}
        assert_recorded_refusal!(pool, 429)
      end
    end
  end

  defp capped_pool!(mode) do
    pool = two_candidate_pool!(mode)
    prime_weekly!(pool.first.identity, "90", @late_reset_seconds)
    prime_weekly!(pool.second.identity, "70", @early_reset_seconds)
    cap!(pool.first.identity, 80)
    cap!(pool.second.identity, 60)
    pool
  end

  defp two_candidate_pool!(mode) do
    first_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    second_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(first_upstream, quota?: false, compact?: true)
    second = gateway_upstream(setup.pool, second_upstream, "upstream-token-capped-second", compact?: true)
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

  defp prime_weekly!(identity, weekly_percent, weekly_reset_seconds) do
    reset_at = DateTime.utc_now() |> DateTime.add(weekly_reset_seconds, :second) |> DateTime.truncate(:second)

    assert {:ok, [_primary, _weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{used_percent: Decimal.new("5")}),
               weekly_quota_window_attrs(%{used_percent: Decimal.new(weekly_percent), reset_at: reset_at})
             ])
  end

  defp cap!(identity, percent), do: identity |> Repo.reload!() |> Ecto.Changeset.change(usage_cap_percent: percent) |> Repo.update!()

  defp post_native(conn, pool) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> maybe_lite(pool)
    |> post(@turn_endpoint, CodexPooler.JSON.encode!(native_body(pool)))
  end

  defp maybe_lite(conn, %{mode: "lite"}), do: put_req_header(conn, @lite_header, "true")
  defp maybe_lite(conn, _pool), do: conn

  defp native_body(pool) do
    %{
      "model" => pool.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic capped pool prompt"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true
    }
  end

  defp assert_usage_limit_error!(error, pool, expected_seconds) do
    assert %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "resets_at" => resets_at, "resets_in_seconds" => seconds} = error
    assert seconds in (expected_seconds - 5)..expected_seconds
    assert abs(resets_at - DateTime.to_unix(DateTime.utc_now()) - expected_seconds) <= 5
    assert Enum.all?(pool.upstreams, &(FakeUpstream.count(&1) == 0))
  end

  defp assert_recorded_refusal!(pool, status) do
    assert [row] = settled_rows!(pool, 1)
    assert {row.status, row.last_error_code, row.response_status_code} == {"rejected", "quota_exhausted", status}
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^row.id), :count) == 0
  end

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

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
