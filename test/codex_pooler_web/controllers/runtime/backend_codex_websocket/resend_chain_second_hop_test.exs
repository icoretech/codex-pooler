defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ResendChainSecondHopTest do
  # The second hop of a resend chain: a turn the provider failed, its resend
  # cut before any output reached the client, then the next resend.
  #
  # Owner forwarding on: the owner's client-retry preflight admits the first
  # resend as the failed request's successor and, when its client leaves before
  # any output, suspends it into a replay the next resend redeems. When that
  # suspension fails (the arm's transaction cannot run), the cut resend is
  # settled `failed client_disconnected` with no replay entitlement: a
  # pre-visible disconnect exactly like the one forwarding off chains onto
  # (findings#206 rows 206-519 and 206-525). The next resend must be served
  # once, as that cut resend's successor, and never dispatched twice.
  #
  # One node, native websocket `/backend-api/codex/responses`, the Pool's model
  # forced to Full and to Lite, FakeUpstream. Real sockets for every request;
  # the owner's replay suspender is replaced by one that fails, which is the
  # only fault injected. Turn metadata and frame shapes are the released
  # client's; text and identifiers synthetic.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket forwarded #{mode}: the resend after a cut resend whose replay suspension failed is served once as its successor", ctx do
      measured = run_forwarded_failed_suspension(ctx.serving_mode)
      CodexPooler.TestDiagnostics.puts(fn -> "second hop forwarded #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.suspension_attempts >= 1
      assert measured.cut_resend == {"failed", "client_disconnected", nil, :no_entitlement}
      assert measured.next_resend == {"response.completed", nil}
      assert measured.requests == [{"failed", "server_error"}, {"failed", "client_disconnected"}, {"succeeded", nil}]
      assert measured.links == [{0, 1}, {1, 2}]
      assert measured.generations == [[0], [0], [0]]
      assert measured.recorded_settlements == [1, 1, 1]
      assert measured.upstream_requests == 3
      assert measured.duplicate_after_success == {"error", "duplicate_turn"}
      assert measured.upstream_requests_after_duplicate == 3
    end
  end

  defp run_forwarded_failed_suspension(mode) do
    put_owner_forwarding!(true)
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (response.failed server_error) followed by the released client's resend cut before output; every reply frame synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: failure_frames()),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            respond: FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic pre-visible loss")
          ),
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: completed_frames("resp_second_hop_served"))
        ])
      )

    setup = gateway_setup(upstream)
    put_serving_mode!(setup, mode)
    port = start_public_endpoint!()
    thread = "ws-second-hop-#{System.unique_integer([:positive])}"
    frame = setup |> released_frame(thread, Ecto.UUID.generate(), native_text_input("synthetic failed turn")) |> CodexPooler.JSON.encode!()

    # Socket 1: the provider fails the turn; the client drops the socket.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, failure} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => "response.failed"} = failure
    Mint.HTTP.close(conn)
    assert await_rows!(setup, 1) == [{"failed", "server_error"}]

    # Socket 2: the resend reaches the provider, which holds it; the owner's
    # replay suspension is made to fail, and the client leaves before output.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @detection_timeout_ms
    cut_request = Repo.one!(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress"))
    codex_session_id = Repo.one!(from(t in CodexTurn, where: t.request_id == ^cut_request.id, select: t.codex_session_id))
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(codex_session_id)
    fail_replay_suspension!(owner_pid)
    Mint.HTTP.close(conn)
    await_settled!(cut_request.id)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    suspension_attempts = count_suspension_attempts(cut_request.id, 0)

    # Socket 3: the next reconnect's resend.
    next = resend!(port, setup, thread, frame)
    rows = await_rows!(setup, 3)
    requests = pool_requests(setup)
    upstream_requests = FakeUpstream.count(upstream)

    # One more identical resend after the turn was served stays a duplicate.
    duplicate = resend!(port, setup, thread, frame)

    %{
      suspension_attempts: suspension_attempts,
      cut_resend: cut_resend_shape(cut_request.id),
      next_resend: {next["type"], get_in(next, ["error", "code"])},
      requests: rows,
      links: links(requests),
      generations: Enum.map(requests, &generations/1),
      recorded_settlements: Enum.map(requests, &recorded_settlements/1),
      upstream_requests: upstream_requests,
      duplicate_after_success: {duplicate["type"], get_in(duplicate, ["error", "code"])},
      upstream_requests_after_duplicate: FakeUpstream.count(upstream)
    }
  end

  # Every arm of the replay the owner attempts for the cut resend fails, as the
  # arm does when its transaction cannot check out a connection.
  defp fail_replay_suspension!(owner_pid) do
    test_pid = self()

    arm = fn input ->
      send(test_pid, {:replay_suspension_attempt, input.request_id})
      {:error, :database_unavailable}
    end

    :sys.replace_state(owner_pid, fn owner_state -> %{owner_state | callbacks: %{owner_state.callbacks | replay_suspender: arm}} end)
    :ok
  end

  defp count_suspension_attempts(request_id, count) do
    receive do
      {:replay_suspension_attempt, ^request_id} -> count_suspension_attempts(request_id, count + 1)
    after
      0 -> count
    end
  end

  defp cut_resend_shape(request_id) do
    request = Repo.get!(Request, request_id)
    turn = Repo.get_by!(CodexTurn, request_id: request_id)
    entitlement = if Repo.get_by(RequestReplayEntitlement, request_id: request_id), do: :entitlement, else: :no_entitlement
    {request.status, request.last_error_code, turn.first_visible_output_at, entitlement}
  end

  # Each link as {predecessor index, successor index} in admission order.
  defp links(requests) do
    index = requests |> Enum.with_index() |> Map.new(fn {request, i} -> {request.id, i} end)
    ids = Map.keys(index)

    from(link in RequestClientRetryLink, where: link.predecessor_request_id in ^ids or link.successor_request_id in ^ids, select: {link.predecessor_request_id, link.successor_request_id})
    |> Repo.all()
    |> Enum.map(fn {predecessor, successor} -> {Map.get(index, predecessor, :foreign), Map.get(index, successor, :foreign)} end)
    |> Enum.sort()
  end

  defp generations(%Request{id: id}), do: Repo.all(from(a in Attempt, where: a.request_id == ^id, order_by: [asc: a.attempt_number], select: a.replay_generation))

  defp recorded_settlements(%Request{id: id}),
    do: Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^id and l.entry_kind == "settlement" and l.amount_status == "recorded"), :count)

  defp resend!(port, setup, thread, frame) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, terminal} = receive_until_terminal(conn, websocket, ref)
    Mint.HTTP.close(conn)
    terminal
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_until_terminal(conn, websocket, ref)
    end
  end

  defp pool_requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))

  defp await_settled!(request_id) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_settled!(request_id, deadline)
  end

  defp await_settled!(request_id, deadline) do
    case Repo.get!(Request, request_id) do
      %Request{status: status} when status not in ["accepted", "in_progress"] ->
        :ok

      _live ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("the cut resend never settled"), else: Process.sleep(5) && await_settled!(request_id, deadline)
    end
  end

  defp await_rows!(setup, count) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_rows!(setup, count, deadline)
  end

  defp await_rows!(setup, count, deadline) do
    rows = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at], select: {r.status, r.last_error_code}))

    if (length(rows) < count or Enum.any?(rows, &match?({status, _code} when status in ["accepted", "in_progress"], &1))) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_rows!(setup, count, deadline)
    else
      rows
    end
  end

  # The released client's turn frame (`request_kind` turn).
  defp released_frame(setup, thread, turn_id, input) do
    metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id}

    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true,
      "generate" => true,
      "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", turn_metadata(thread, turn_id, "turn"))
    }
  end

  defp turn_metadata(thread, turn_id, kind), do: CodexPooler.JSON.encode!(%{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id, "request_kind" => kind})

  defp failure_frames do
    response_id = "resp_second_hop_failed"

    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.failed", "response" => %{"id" => response_id, "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}})
    ])
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ])
  end

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    :ok
  end

  defp put_owner_forwarding!(forwarding?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding?)
  end
end
