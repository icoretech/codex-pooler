defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.QueuedResendReplayBindingTest do
  # The released client (Codex `rust-v0.156.1`) drops its connection after a
  # retryable `response.failed`, opens a new one, sends a prewarm, waits for
  # its completion and sends the failed turn again at once. That resend can
  # reach the new socket while the prewarm's response task is still tracked,
  # so the socket queues it (findings#206 row 206-339, Drone 1525), and with
  # owner forwarding on its dequeue asks the owner's replay preflight whether
  # it may attach the replay binding. The preflight answers a fresh intent
  # that names the failed request as the resend's predecessor; the dequeue
  # attached the binding only to a fresh intent WITHOUT a predecessor, so the
  # resend ran unbound: served as the failed request's successor, but never
  # replay-active, and a cut before any output settled it
  # `client_disconnected` with no replay entitlement and the next resend met
  # `409 duplicate_turn`, where the unqueued resend is suspended into its
  # replay and redeemed by the next resend (findings#206 row 206-496). The
  # dequeue now binds every fresh intent the owner admits, predecessor
  # included, as the unqueued route does.
  #
  # With owner forwarding off there is no replay: the cut resend is settled
  # `failed client_disconnected`, a pre-visible disconnect chained onto the
  # failed request under its turn claim, and linked to it. The next resend
  # walks that chain, but the resend policy refused every chain node a
  # client-retry link names, the chain's own edge included, so it met
  # `409 duplicate_turn` and the released client ended in its retries and the
  # HTTPS fallback (findings#206 row 206-519). The next resend is now chained
  # onto the cut resend and served: one more request, one more dispatch.
  #
  # One node, native websocket `/backend-api/codex/responses`, owner forwarding
  # on and off, the Pool's serving mode forced to Full and to Lite,
  # FakeUpstream. Three sockets as the released client opens them: the turn
  # and its provider failure, the reconnect's prewarm and queued resend (its
  # callbacks driven by the test so the prewarm's task is still tracked when
  # the resend arrives), and the next reconnect's resend. Turn metadata and
  # frame shapes are the released client's; text and identifiers synthetic.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request, RequestClientRetryLink, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @detection_timeout_ms 10_000
  @socket_messages [
    :codex_response_chunk,
    :websocket_owner_frame,
    :websocket_owner_output_commit_probe,
    :websocket_owner_cleanup_witness,
    :websocket_response_activity,
    :codex_response_done,
    :websocket_response_delivery_complete,
    :direct_request_cleanup
  ]

  # `:opening`: the failed request opens its turn. `:anchored`: it is the
  # socket's second turn, sent as an anchored delta after the first turn
  # completed, and every resend is the anchor-free full history (findings#232
  # row 232-160), which the preflight still names the failed request's
  # successor.
  for forwarding <- [:forwarded, :direct], mode <- ["full", "lite"], resend <- [:queued, :unqueued], shape <- [:opening, :anchored] do
    @tag forwarding: forwarding, serving_mode: mode, resend: resend, shape: shape
    test "websocket #{forwarding} #{mode} #{shape}: a #{resend} resend of a provider-failed turn cut before output is redeemed by the next resend", ctx do
      measured = run(ctx.forwarding, ctx.serving_mode, ctx.resend, ctx.shape)
      CodexPooler.TestDiagnostics.puts(fn -> "queued resend #{ctx.forwarding} #{ctx.serving_mode} #{ctx.resend} #{ctx.shape}: #{inspect(measured)}" end)
      assert_expected!(ctx.forwarding, ctx.resend, ctx.shape, measured)
    end
  end

  # Forwarding on, the cut resend is suspended into its replay whether or not
  # it was queued, and the next resend redeems it: one request for both
  # resends, a failed attempt and its replay, linked to the failed request by
  # the owner preflight's retry link.
  defp assert_expected!(:forwarded, resend, shape, measured) do
    assert measured == %{
             queued?: resend == :queued,
             cut_resend: :armed,
             next_resend: {"response.completed", nil},
             requests: served_before(shape) ++ [{"failed", "server_error"}, {"succeeded", nil}],
             link: :retry_link,
             cut_successor: :none,
             resend_attempts: [{0, "retryable_failed"}, {1, "succeeded"}],
             upstream_requests: length(served_before(shape)) + 3
           }
  end

  # Forwarding off queues nothing here and has no owner replay: the cut
  # resend fails `client_disconnected` either way, and the next resend is its
  # own successor, chained onto the cut resend under the turn claim and linked
  # to it, and served by a dispatch of its own.
  defp assert_expected!(:direct, _resend, shape, measured) do
    assert measured == %{
             queued?: false,
             cut_resend: {:not_armed, "client_disconnected"},
             next_resend: {"response.completed", nil},
             requests: served_before(shape) ++ [{"failed", "server_error"}, {"failed", "client_disconnected"}, {"succeeded", nil}],
             link: :both,
             cut_successor: :both,
             resend_attempts: [{0, "failed"}],
             upstream_requests: length(served_before(shape)) + 3
           }
  end

  defp served_before(:opening), do: []
  defp served_before(:anchored), do: [{"succeeded", nil}]

  defp run(forwarding, mode, resend, shape) do
    put_owner_forwarding!(forwarding)
    release_ref = make_ref()
    history_a = native_text_input("synthetic first turn")
    user_b = native_text_input("synthetic failed turn")

    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (2026-09-09 response.failed server_error) and Codex client source core/src/client.rs prewarm_websocket (prewarm completes, then the request); the cut and every reply frame synthetic
        FakeUpstream.strict_sequence(
          first_turn_requests(shape) ++
            [
              FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: failure_frames()),
              FakeUpstream.expect_request(
                method: "WEBSOCKET",
                path: "/backend-api/codex/responses",
                respond: FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic pre-visible loss")
              ),
              FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: completed_frames("resp_p118_resend_served"))
            ]
        )
      )

    setup = gateway_setup(upstream)
    put_serving_mode!(setup, mode)
    port = start_public_endpoint!()
    thread = "ws-p118-queued-resend-#{System.unique_integer([:positive])}"
    turn_id = Ecto.UUID.generate()
    {sent, frame} = failing_turn_frames(setup, thread, turn_id, shape, history_a, user_b)

    # Socket 1: the failing turn (after the first turn, anchored to it) meets
    # the provider failure; the client drops the socket.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = maybe_first_turn!(conn, websocket, ref, setup, thread, shape, history_a)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, sent)
    {conn, _websocket, failure} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => "response.failed"} = failure
    Mint.HTTP.close(conn)
    assert await_rows!(setup, length(served_before(shape)) + 1) == served_before(shape) ++ [{"failed", "server_error"}]

    # Socket 2: the reconnect's prewarm, then the resend, cut before output.
    prewarm = frame |> CodexPooler.JSON.decode!() |> Map.put("generate", false) |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(thread, turn_id, "prewarm")) |> CodexPooler.JSON.encode!()
    {queued?, cut_request_id, upstream_pid} = cut_resend!(setup, thread, frame, prewarm, resend, release_ref)
    cut_resend = await_armed(cut_request_id, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

    # Socket 3: the next reconnect's resend.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, next} = receive_until_terminal(conn, websocket, ref)
    Mint.HTTP.close(conn)

    rows = await_rows!(setup, length(served_before(shape)) + if(forwarding == :direct, do: 3, else: 2))

    %{
      queued?: queued?,
      cut_resend: cut_resend,
      next_resend: {next["type"], get_in(next, ["error", "code"])},
      requests: rows,
      link: successor_link(setup),
      cut_successor: cut_successor_link(setup, cut_request_id),
      resend_attempts: Repo.all(from(a in Attempt, where: a.request_id == ^cut_request_id, order_by: [asc: a.attempt_number], select: {a.replay_generation, a.status})),
      upstream_requests: FakeUpstream.count(upstream)
    }
  end

  # The socket's callbacks are driven here, so the prewarm's task is still
  # tracked when the resend is handed to the socket.
  defp cut_resend!(setup, thread, frame, prewarm, resend, release_ref) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: thread, accepted_turn_state: thread, client_ip: "127.0.0.1"}})
    Process.put(:p118_socket_state, state)

    try do
      assert {:ok, state} = CodexResponsesSocket.handle_in({prewarm, [opcode: :text]}, state)
      assert {:push, {:text, created}, state} = receive_socket_push(state)
      assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)
      assert {:push, {:text, completed}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed)
      Process.put(:p118_socket_state, state)
      state = if resend == :unqueued, do: drain_tasks!(state), else: state
      assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
      queued? = not :queue.is_empty(Map.get(state, :queued_response_payloads, :queue.new()))
      Process.put(:p118_socket_state, state)
      {state, upstream_pid} = pump_until_barrier!(state, release_ref)
      Process.put(:p118_socket_state, state)
      cut_request_id = Repo.one!(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress", select: r.id))
      :ok = CodexResponsesSocket.terminate(:closed, Process.delete(:p118_socket_state))
      {queued?, cut_request_id, upstream_pid}
    after
      if state = Process.delete(:p118_socket_state), do: CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp drain_tasks!(state) do
    if MapSet.size(state.tasks) == 0 do
      state
    else
      receive do
        message when is_tuple(message) and elem(message, 0) in @socket_messages -> message |> handle_socket_message(state) |> drain_tasks!()
      after
        @detection_timeout_ms -> flunk("the prewarm's task never reported")
      end
    end
  end

  defp pump_until_barrier!(state, release_ref) do
    receive do
      {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref} -> {state, upstream_pid}
      message when is_tuple(message) and elem(message, 0) in @socket_messages -> pump_until_barrier!(handle_socket_message(message, state), release_ref)
    after
      @detection_timeout_ms -> flunk("the resend never reached the provider")
    end
  end

  defp handle_socket_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:push, {:text, _frame}, state} -> state
      {:ok, state} -> state
      {:stop, _reason, close_detail, _state} -> flunk("socket closed with #{inspect(close_detail)}")
    end
  end

  defp await_armed(request_id, deadline) do
    case {Repo.get_by(RequestReplayEntitlement, request_id: request_id), Repo.get!(Request, request_id)} do
      {%RequestReplayEntitlement{status: "armed"}, _request} ->
        :armed

      {_entitlement, %Request{status: status, last_error_code: code}} when status not in ["accepted", "in_progress"] ->
        {:not_armed, code}

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("the cut resend neither armed nor settled"), else: Process.sleep(5) && await_armed(request_id, deadline)
    end
  end

  # How the failed request's one successor was admitted: through the owner
  # preflight's client-retry link, or on its turn claim, which records the
  # predecessor on the resend (forwarding off records both).
  defp successor_link(setup) do
    rows = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))
    [failed, successor | _later] = Enum.drop_while(rows, &(&1.last_error_code != "server_error"))
    link_kind(failed, successor)
  end

  # How the request admitted after the cut resend, if any, was chained onto it.
  defp cut_successor_link(setup, cut_request_id) do
    rows = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))

    case Enum.drop_while(rows, &(&1.id != cut_request_id)) do
      [cut, successor | _later] -> link_kind(cut, successor)
      [_cut] -> :none
    end
  end

  defp link_kind(predecessor, successor) do
    retry_link? = Repo.exists?(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^predecessor.id and link.successor_request_id == ^successor.id))
    claim? = successor.request_metadata["client_resend"]["predecessor_request_id"] == predecessor.id

    case {retry_link?, claim?} do
      {true, false} -> :retry_link
      {false, true} -> :turn_claim
      {true, true} -> :both
      {false, false} -> :none
    end
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_until_terminal(conn, websocket, ref)
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

  defp first_turn_requests(:opening), do: []

  defp first_turn_requests(:anchored),
    do: [FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: completed_frames("resp_p118_first_turn", [assistant_item()]))]

  defp maybe_first_turn!(conn, websocket, _ref, _setup, _thread, :opening, _history_a), do: {conn, websocket}

  defp maybe_first_turn!(conn, websocket, ref, setup, thread, :anchored, history_a) do
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(released_frame(setup, thread, Ecto.UUID.generate(), history_a)))
    {conn, websocket, completed} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => "response.completed"} = completed
    {conn, websocket}
  end

  # The failing request as the socket sends it, and the resend the client
  # sends after every reconnect: the same frame for an opening request; for an
  # anchored one the anchor-free full history ending in the anchored request's
  # own items.
  defp failing_turn_frames(setup, thread, turn_id, :opening, _history_a, user_b) do
    frame = setup |> released_frame(thread, turn_id, user_b) |> CodexPooler.JSON.encode!()
    {frame, frame}
  end

  defp failing_turn_frames(setup, thread, turn_id, :anchored, history_a, user_b) do
    sent = setup |> released_frame(thread, turn_id, user_b) |> Map.put("previous_response_id", "resp_p118_first_turn") |> CodexPooler.JSON.encode!()
    resend = setup |> released_frame(thread, turn_id, history_a ++ [assistant_item()] ++ user_b) |> CodexPooler.JSON.encode!()
    {sent, resend}
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

  defp assistant_item, do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic first answer"}]}

  defp failure_frames do
    response_id = "resp_p118_resend_failed"

    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.failed", "response" => %{"id" => response_id, "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}})
    ])
  end

  defp completed_frames(response_id, output \\ []) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ])
  end

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    :ok
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
