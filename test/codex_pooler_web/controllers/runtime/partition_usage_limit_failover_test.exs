defmodule CodexPoolerWeb.Runtime.PartitionUsageLimitFailoverTest do
  # Accounts of different plans can advertise the same model with different
  # source shapes, so native routes split them into canonical partitions and
  # route a turn over the selected partition only. When the selected
  # partition's last routable account refuses with a provider usage limit
  # before any output while a held-back account can serve the model, the turn
  # moves to the held-back partition once, as the next request's quota-aware
  # partition selection would, instead of answering a terminal usage limit
  # (findings#206 row 206-586). It used to fail with the refusing account's
  # usage limit while the other partition served the next request.
  #
  # When no held-back account can serve now, the terminal answer's advice
  # counts the held-back partition too (row 206-545).
  #
  # Partition T (older anchor): the refusing account and an exhausted sibling.
  # Partition P: one account with a behavioral source drift. The tie on
  # routable members (one each) goes to the larger partition, T.
  #
  # One BEAM node, three assignments, FakeUpstream; native HTTP SSE and JSON,
  # native websocket; `/v1` for contrast (translated surfaces route over every
  # partition); Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @message "upstream quota is exhausted until its reset time"

  for stream? <- [true, false] do
    @stream stream?

    test "native stream=#{stream?}: the turn moves to the held-back partition, and the next turn is served there too", _context do
      pool = split_pool!(:routable)

      first = post_native(pool, "partition-first", @stream)
      second = post_native(pool, "partition-second", @stream)

      [first_row, second_row] = rows!(pool)
      diagnostics(pool, [first, second])

      assert first.status == 200
      assert attempts!(first_row, pool) == [{"retryable_failed", 429, :refusing}, {"succeeded", 200, :other_partition}]
      assert first_row.status == "succeeded"
      assert %{"partition_count" => 2, "filtered_count" => 1, "routable_selection" => false} = first_row.request_metadata["canonical_partition"]

      assert second.status == 200
      assert attempts!(second_row, pool) == [{"succeeded", 200, :other_partition}]
      assert {model_posts(pool.refusing_upstream), model_posts(pool.exhausted_upstream), model_posts(pool.other_upstream)} == {1, 0, 2}
    end
  end

  test "native websocket: the refused first frame moves the turn to the held-back partition", _context do
    put_owner_forwarding!(false)
    pool = split_pool!(:routable, :websocket)
    {_server, port} = start_public_endpoint_with_server!()

    terminal = native_websocket_turn!(port, pool)

    CodexPooler.TestDiagnostics.puts(fn -> "P128d partition websocket terminal: " <> CodexPooler.JSON.encode!(terminal) end)

    assert %{"type" => "response.completed"} = terminal
    assert [row] = settled_rows!(pool)
    assert attempts!(row, pool) == [{"retryable_failed", 200, :refusing}, {"succeeded", 200, :other_partition}]
    assert FakeUpstream.websocket_connection_count(pool.exhausted_upstream) == 0
  end

  test "the hop happens once: a held-back account refusing too ends the turn on the terminal usage limit", _context do
    # The held-back account's refusal records no exhausted window, so only the
    # spent fallback keeps the turn from hopping again.
    resets_at = DateTime.to_unix(DateTime.utc_now()) + 1_800
    pool = split_pool!(:routable, :http, other_mode: {:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at}}, []})

    conn = post_native(pool, "partition-once", true)

    assert [row] = rows!(pool)
    diagnostics(pool, [conn])
    assert conn.status == 429
    assert attempts!(row, pool) == [{"retryable_failed", 429, :refusing}, {"failed", 429, :other_partition}]
    assert %{"error" => %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => @message}} = CodexPooler.JSON.decode!(conn.resp_body)
  end

  test "every partition exhausted: the terminal usage limit advises the held-back partition's earlier reset", _context do
    pool = split_pool!({:exhausted, 1_800})

    conn = post_native(pool, "partition-exhausted", true)

    assert [row] = rows!(pool)
    diagnostics(pool, [conn])
    assert conn.status == 429
    assert attempts!(row, pool) == [{"failed", 429, :refusing}]
    assert %{"error" => %{"type" => "usage_limit_reached", "resets_in_seconds" => seconds}} = CodexPooler.JSON.decode!(conn.resp_body)
    assert seconds in 1_795..1_800
    assert model_posts(pool.other_upstream) == 0
  end

  test "a held-back account behind an open circuit takes no hop and keeps the relayed, retryable refusal", _context do
    pool = split_pool!(:routable)
    open_circuit!(pool, pool.other.assignment)

    conn = post_native(pool, "partition-circuit", true)

    assert [row] = rows!(pool)
    diagnostics(pool, [conn])
    assert conn.status == 429
    assert attempts!(row, pool) == [{"failed", 429, :refusing}]
    refute conn.resp_body =~ @message
    assert model_posts(pool.other_upstream) == 0
  end

  test "/v1 routes over every partition, so the refusal already moves on within its plan", _context do
    pool = split_pool!(:routable)

    conn =
      build_conn()
      |> put_req_header("authorization", pool.setup.authorization)
      |> put_req_header("content-type", "application/json")
      |> post("/v1/responses", CodexPooler.JSON.encode!(%{"model" => pool.setup.model.exposed_model_id, "input" => "synthetic partition prompt", "stream" => false}))

    assert [row] = rows!(pool)
    diagnostics(pool, [conn])
    assert conn.status == 200
    assert List.last(attempts!(row, pool)) == {"succeeded", 200, :other_partition}
    assert row.request_metadata["canonical_partition"] == nil
  end

  defp split_pool!(other_quota, transport \\ :http, opts \\ []) do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + 3 * 86_400

    {refusing_mode, success_mode} =
      case transport do
        :http -> {weekly_usage_limit_429(resets_at), stream_success_sse()}
        :websocket -> {FakeUpstream.websocket_text_frames([usage_limit_frame(resets_at)]), FakeUpstream.websocket_text_frames([completed_frame()])}
      end

    refusing_upstream = start_upstream(refusing_mode)
    exhausted_upstream = start_upstream(success_mode)
    other_upstream = start_upstream(Keyword.get(opts, :other_mode, success_mode))

    setup = gateway_setup(refusing_upstream, quota?: false)
    anchor = setup.assignment.created_at
    exhausted = setup.pool |> gateway_upstream(exhausted_upstream, "upstream-token-partition-sibling", compact?: false) |> shift_created_at!(anchor, 1)
    other = setup.pool |> gateway_upstream(other_upstream, "upstream-token-other-partition", compact?: false) |> shift_created_at!(anchor, 2)

    prime_routing_quota!(setup.identity)
    prime_exhausted_routing_quota!(exhausted.identity, %{reset_at: reset_in(7_200)})

    case other_quota do
      :routable -> prime_routing_quota!(other.identity)
      {:exhausted, seconds} -> prime_exhausted_routing_quota!(other.identity, %{reset_at: reset_in(seconds)})
    end

    model =
      setup.model
      |> put_model_source_assignments!([setup.assignment, exhausted.assignment, other.assignment])
      |> put_behavioral_drift!(other.assignment)

    %{
      setup: %{setup | model: model},
      refusing: %{assignment: setup.assignment},
      exhausted: exhausted,
      other: other,
      refusing_upstream: refusing_upstream,
      exhausted_upstream: exhausted_upstream,
      other_upstream: other_upstream
    }
  end

  defp reset_in(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp weekly_usage_limit_429(resets_at) do
    headers = [
      {"x-codex-secondary-used-percent", "100"},
      {"x-codex-secondary-window-minutes", "10080"},
      {"x-codex-secondary-reset-at", Integer.to_string(resets_at)},
      {"x-codex-rate-limit-reached-type", "rate_limit_reached"}
    ]

    {:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at}}, headers}
  end

  defp usage_limit_frame(resets_at) do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 429,
      "error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at},
      "headers" => %{"x-codex-secondary-used-percent" => "100", "x-codex-secondary-window-minutes" => "10080", "x-codex-secondary-reset-at" => Integer.to_string(resets_at)}
    })
  end

  defp completed_frame do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => "resp_partition_fallback", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
    })
  end

  defp shift_created_at!(upstream, anchor, seconds) do
    assignment = upstream.assignment |> Ecto.Changeset.change(created_at: DateTime.add(anchor, seconds, :second)) |> Repo.update!()
    %{upstream | assignment: assignment}
  end

  defp put_behavioral_drift!(model, assignment) do
    sources = Map.fetch!(model.metadata, "source_assignment_models")
    sources = Map.update!(sources, assignment.id, &Map.put(&1, "context_window", 111_111))
    model |> Ecto.Changeset.change(metadata: Map.put(model.metadata, "source_assignment_models", sources)) |> Repo.update!()
  end

  defp open_circuit!(pool, assignment) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- ["proxy_http", "proxy_stream", "proxy_websocket"] do
      %RoutingCircuitState{
        pool_id: pool.setup.pool.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        model_identifier: pool.setup.model.exposed_model_id,
        route_class: route_class,
        status: "open",
        reason_code: "upstream_5xx",
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

  defp model_posts(upstream), do: Enum.count(FakeUpstream.requests(upstream), &(&1.path == @turn_endpoint))

  defp rows!(pool), do: Repo.all(from(r in Request, where: r.pool_id == ^pool.setup.pool.id, order_by: [asc: r.admitted_at]))

  defp attempts!(row, pool) do
    from(a in Attempt, where: a.request_id == ^row.id, order_by: [asc: a.attempt_number])
    |> Repo.all()
    |> Enum.map(&{&1.status, &1.upstream_status_code, label(&1.pool_upstream_assignment_id, pool)})
  end

  defp label(id, pool) do
    cond do
      id == pool.refusing.assignment.id -> :refusing
      id == pool.exhausted.assignment.id -> :exhausted
      id == pool.other.assignment.id -> :other_partition
    end
  end

  defp diagnostics(pool, conns) do
    CodexPooler.TestDiagnostics.puts(fn ->
      measured =
        Enum.zip(conns, rows!(pool))
        |> Enum.map(fn {conn, row} -> %{status: conn.status, retry_after: get_resp_header(conn, "retry-after"), body: String.slice(conn.resp_body, 0, 200), attempts: attempts!(row, pool), partition: row.request_metadata["canonical_partition"]} end)

      "P128d partition arm: " <> inspect(measured, limit: :infinity)
    end)
  end

  defp post_native(pool, session, stream?) do
    build_conn()
    |> put_req_header("authorization", pool.setup.authorization)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("session-id", session)
    |> put_req_header("x-openai-internal-codex-responses-lite", "true")
    |> post(@turn_endpoint, CodexPooler.JSON.encode!(%{"model" => pool.setup.model.exposed_model_id, "input" => native_text_input("synthetic partition prompt"), "stream" => stream?}))
  end

  defp native_websocket_turn!(port, pool) do
    thread_id = Ecto.UUID.generate()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", pool.setup.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"},
      {"x-openai-internal-codex-responses-lite", "true"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => pool.setup.model.exposed_model_id,
        "instructions" => "synthetic instructions",
        "input" => native_text_input("synthetic partition prompt"),
        "tools" => [],
        "tool_choice" => "auto",
        "parallel_tool_calls" => true,
        "store" => false,
        "stream" => true,
        "client_metadata" => %{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "#{thread_id}-turn"}
      })

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

  defp settled_rows!(pool) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> rows!(pool) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        rows != [] and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end
end
