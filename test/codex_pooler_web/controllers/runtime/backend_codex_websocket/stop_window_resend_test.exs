defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.StopWindowResendTest do
  # With owner forwarding off, a closing socket stops the direct task that was
  # generating its turn, then interrupts the task's request with its own reason
  # (`client_disconnected`). The kill ends the task's execution, the production
  # publisher proves that end about 100 ms later, and the interrupt is a
  # transaction of its own: a resend claimed between the proof and the
  # interrupt finds the request still in progress with its executor proven
  # dead, and its claim recovers the request as a dead execution's predecessor
  # (`FailedPredecessorResend.resolve_execution/3`). The socket used to record
  # the task's delivery receipt only after its interrupt, so nothing of what
  # the client had been shown was durable inside that window (findings#270 row
  # 270-364). It now commits the receipt between the grant of the stop and the
  # kill, and these arms pin that receipt inside the window.
  #
  # Whether the dead-execution admission refuses a resend after output the
  # client keeps is decided by findings#270 row 270-375; until then the arms
  # pin today's outcome: the resend is served as the dead execution's one
  # successor, after a completed item as before any output.
  #
  # The cleanup is held right after its interrupt's `begin`, the first
  # transaction it begins once the task is dead
  # (`CodexPoolerWeb.Runtime.CleanupProofRace.hold_interrupt_after_stop!/2`),
  # with committed rows so the resend's claim, on a new connection, reads what
  # the cleanup committed before it. One node, owner forwarding off, native
  # websocket `/backend-api/codex/responses`, the Pool's model forced to Full
  # and to Lite, FakeUpstream holding the stream at a frame barrier. Frame and
  # metadata shapes are the released client's; text and identifiers synthetic.
  # The released client's HTTPS fallback is not judged here: inside this window
  # the native HTTP chain walk steps over a predecessor still in progress and
  # serves the fallback as a new request, whatever the receipt or the proof.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [await_socket_connection_state!: 2, model_serving_scope: 0, set_model_serving_mode!: 3, strict_native_request: 2]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.ExecutionProofSupport
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Platform.{ExecutionTerminalProof, ExecutionTerminalProofs}
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture
  alias CodexPoolerWeb.Runtime.CleanupProofRace
  alias CodexPoolerWeb.Runtime.MailboxPrefixRaceSupport
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag capture_log: true
  @timeout_ms 15_000
  # provenance: observed findings#232 row 232-231 (the released client's Lite websocket frame carries the marker in client_metadata, its HTTPS fallback a header)
  @websocket_lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    @tag slow: "physically closes a socket and holds its cleanup after the executor terminal proof"
    test "#{mode}: the resend identical to a turn cut after a completed item, claimed between the stopped task's proven end and its cleanup's interrupt, finds the receipt and is served as the dead execution's one successor", ctx do
      window = cut_and_hold!(ctx.serving_mode, :item_done)
      resend = resend!(window, window.payload)
      :ok = release!(window)

      assert window.request_status == "in_progress"
      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 1} = window.receipt
      assert %{"type" => "response.completed"} = resend
      :ok = await_all_settled!(window.setup.pool.id)
      assert [%Request{id: request_id, status: "failed", response_status_code: 499, last_error_code: "dead_execution_recovered"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(window.setup.pool.id)
      assert request_id == window.request_id
      assert [%RequestClientRetryLink{successor_request_id: ^successor_id}] = Repo.all(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^request_id))
      assert_one_settlement_each!([successor_id])
      assert FakeUpstream.count(window.upstream) == 2
    end
  end

  for mode <- ["full", "lite"], historical_runs <- [0, 22] do
    @tag serving_mode: mode, historical_runs: historical_runs
    @tag slow: "physically closes a socket and verifies mailbox refusal and recovery inside its held cleanup"
    test("#{mode}: a proven stopped execution admits retained reasoning and mailbox once after #{historical_runs} historical runs", ctx, do: assert_dead_mailbox_recovery!(ctx.serving_mode, ctx.historical_runs))
  end

  defp assert_dead_mailbox_recovery!(mode, historical_runs) do
    peer = if historical_runs > 0, do: MailboxPrefixRaceSupport.start_http_peer!()
    peer_port = if peer, do: MailboxPrefixRaceSupport.start_peer_listener!(peer)
    window = cut_and_hold!(mode, :mailbox, historical_runs)
    winner_window = if peer_port, do: %{window | port: peer_port}, else: window
    candidate = Map.update!(window.payload, "input", &(&1 ++ [reasoning_item(), mailbox_item()]))

    try do
      assert window.request_status == "in_progress"
      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 1} = window.receipt

      changed = update_in(candidate["input"], &List.update_at(&1, length(window.payload["input"]), fn item -> Map.put(item, "encrypted_content", "synthetic changed reasoning") end))
      assert %{"type" => "error", "status" => 409} = resend!(window, changed)
      assert FakeUpstream.count(window.upstream) == 1
      winner = Task.async(fn -> resend!(winner_window, candidate) end)
      assert_receive {:fake_upstream_frame_barrier, 0, handler, gate}, @timeout_ms
      assert gate == window.successor_gate

      try do
        # Each socket owns its Mint mailbox. Long-history recovery runs on a
        # second BEAM node; hold its admitted successor while the original
        # node tries the same continuation against their shared database.
        assert %{"type" => "error", "status" => 409} = resend!(window, candidate)
        assert :ok = FakeUpstream.release_remaining_frames(window.upstream, gate)
        assert %{"type" => "response.completed"} = Task.await(winner, @timeout_ms)
      after
        if Process.alive?(handler), do: FakeUpstream.release_remaining_frames(window.upstream, gate)
        if Process.alive?(winner.pid), do: Task.shutdown(winner, :brutal_kill)
      end

      :ok = await_all_settled!(window.setup.pool.id)
      assert [%Request{id: original_id, last_error_code: "dead_execution_recovered"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(window.setup.pool.id)
      assert original_id == window.request_id
      if peer, do: assert(Repo.get_by!(Attempt, request_id: successor_id).owner_instance_id == Atom.to_string(peer))
      assert [%RequestClientRetryLink{successor_request_id: ^successor_id}] = Repo.all(from link in RequestClientRetryLink, where: link.predecessor_request_id == ^original_id)
      assert_one_settlement_each!([original_id, successor_id])
      assert FakeUpstream.count(window.upstream) == 2
    after
      :ok = release!(window)
    end
  end

  # A turn whose client was shown nothing before the cut (its input carries the
  # compaction item the released client sends after a compaction; the provider
  # holds its answer) is resent identically, and inside the window its
  # recovered request is the resend's predecessor as before.
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    @tag slow: "physically closes a socket and holds its cleanup after the executor terminal proof"
    test "#{mode}: the websocket resend of a turn cut before any output is served as the dead execution's one successor when it is claimed inside that window", ctx do
      window = cut_and_hold!(ctx.serving_mode, :previsible)
      resend = resend!(window, window.payload)
      :ok = release!(window)

      assert window.request_status == "in_progress"
      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "none", "frames_after_visible" => 0} = window.receipt
      assert %{"type" => "response.completed"} = resend
      :ok = await_all_settled!(window.setup.pool.id)
      assert [%Request{id: request_id, status: "failed", response_status_code: 499, last_error_code: "dead_execution_recovered"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(window.setup.pool.id)
      assert request_id == window.request_id
      assert [%RequestClientRetryLink{successor_request_id: ^successor_id}] = Repo.all(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^request_id))
      assert FakeUpstream.count(window.upstream) == 2
    end
  end

  # Cuts the turn, holds its cleanup at the interrupt once the task is dead,
  # and proves the task's end: what a resend claimed now reads.
  defp cut_and_hold!(mode, cut, historical_runs \\ 0) do
    release_ref = make_ref()
    successor_gate = if cut == :mailbox, do: make_ref()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_native_request(1, first_response(cut, release_ref)),
          successor_request(successor_gate)
        ])
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    payload = native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id, mode, cut) |> append_historical_mail(historical_runs)
    turn_state = Ecto.UUID.generate()
    port = start_public_endpoint!()

    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
    upstream_handler = await_cut!(cut, upstream, release_ref, conn, websocket, ref)

    assert [%Request{id: request_id}] = pool_requests(setup.pool.id)
    [task] = MapSet.to_list(await_socket_connection_state!(socket, &(MapSet.size(Map.get(&1, :tasks, MapSet.new())) > 0)).tasks)
    hold = CleanupProofRace.hold_interrupt_after_stop!(socket, task)
    _closed = Mint.HTTP.close(conn)
    cleanup = CleanupProofRace.await_interrupt_held!(hold)

    attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request_id))
    :ok = prove!(attempt)
    assert ExecutionTerminalProofs.terminal?(attempt)

    %{
      setup: setup,
      upstream: upstream,
      upstream_handler: upstream_handler,
      release_ref: release_ref,
      successor_gate: successor_gate,
      port: port,
      turn_state: turn_state,
      payload: payload,
      socket: socket,
      hold: hold,
      cleanup: cleanup,
      request_id: request_id,
      request_status: Repo.get!(Request, request_id).status,
      receipt: Repo.get!(Attempt, attempt.id).response_metadata["downstream_delivery"]
    }
  end

  defp release!(window) do
    :ok = CleanupProofRace.release_interrupt(window.hold, window.cleanup)
    :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(window.socket)
    release_upstream(window)
    await_settled!(window.request_id)
  end

  # The provider holds its answer at a frame barrier: after the completed item
  # (the terminal held), or before any frame.
  defp first_response(:item_done, release_ref), do: FakeUpstream.barrier_websocket_frames(item_done_frames("resp_stop_window_original"), notify: self(), release_ref: release_ref)
  defp first_response(:mailbox, release_ref), do: FakeUpstream.barrier_websocket_frames(reasoning_frames(), notify: self(), release_ref: release_ref)
  defp first_response(:previsible, release_ref), do: FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic stop window loss")

  defp await_cut!(cut, upstream, release_ref, conn, websocket, ref) when cut in [:item_done, :mailbox] do
    for ordinal <- 0..2 do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @timeout_ms
      :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    # The barrier notification is read before any socket frame: the socket
    # helpers consume every message they do not recognise.
    assert_receive {:fake_upstream_frame_barrier, 3, handler, ^release_ref}, @timeout_ms
    :ok = receive_until!(conn, websocket, ref, "response.output_item.done")
    {:frames, handler}
  end

  defp await_cut!(:previsible, _upstream, release_ref, _conn, _websocket, _ref) do
    assert_receive {:fake_upstream_websocket_barrier, :before_close, handler, ^release_ref}, @timeout_ms
    {:close, handler}
  end

  defp release_upstream(%{upstream_handler: {:frames, _handler}, upstream: upstream, release_ref: release_ref}),
    do: :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)

  defp release_upstream(%{upstream_handler: {:close, handler}, release_ref: release_ref}) do
    send(handler, {:fake_upstream_release_websocket, release_ref})
    :ok
  end

  # The production publisher, which `config/test.exs` disables, proves the
  # stopped task's end as it does about 100 ms after the kill. It keeps
  # running, and every proof committed during the test is removed at exit.
  defp prove!(attempt) do
    proofs_before = Repo.all(from(proof in ExecutionTerminalProof, select: proof.execution_id))
    UnboxedFixture.register_unboxed_cleanup!(fn -> Repo.delete_all(from(proof in ExecutionTerminalProof, where: proof.execution_id not in ^proofs_before)) end)
    publisher = ExecutionProofSupport.start_publisher!(name: :stop_window_resend_publisher, interval_ms: 60_000)
    ExecutionProofSupport.await_terminal!(attempt, publisher)
  end

  defp successor_request(nil),
    do: FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: FakeUpstream.websocket_text_frames(item_done_frames("resp_stop_window_successor")))

  defp successor_request(gate),
    do: FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: FakeUpstream.barrier_websocket_frames(item_done_frames("resp_stop_window_successor"), notify: self(), release_ref: gate))

  defp resend!(window, payload) do
    {conn, websocket, ref} = public_websocket_connect!(window.port, window.setup, window.turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
    {conn, frame} = receive_terminal!(conn, websocket, ref)
    _closed = Mint.HTTP.close(conn)
    frame
  end

  defp completed_item(response_id),
    do: %{"id" => "msg_" <> response_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "completed answer", "annotations" => []}]}

  defp item_done_frames(response_id) do
    item = completed_item(response_id)

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{item | "status" => "in_progress", "content" => []}},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp reasoning_item, do: %{"id" => "rs_stop_window", "type" => "reasoning", "summary" => [], "encrypted_content" => "synthetic stopped reasoning"}

  defp mailbox_item,
    do: %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic task update"}]}

  defp reasoning_frames do
    item = reasoning_item()

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => "resp_stop_window_mailbox", "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => "resp_stop_window_mailbox", "status" => "completed", "output" => [item]}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp native_turn_payload(thread_id, model, mode, cut) do
    turn_id = "stop-window-#{cut}"

    metadata = %{
      "session_id" => thread_id,
      "thread_id" => thread_id,
      "turn_id" => turn_id,
      "x-codex-window-id" => thread_id <> ":0",
      "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => turn_id, "request_kind" => "turn", "agent_name" => "/root"}),
      "x-codex-ws-stream-request-start-ms" => 100
    }

    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => if(mode == "lite", do: Map.put(metadata, @websocket_lite_marker, "true"), else: metadata),
      "input" => turn_input(cut)
    }
  end

  defp turn_input(:item_done), do: native_text_input("synthetic stop window turn")

  defp turn_input(:mailbox),
    do: native_text_input("synthetic stopped mailbox turn") ++ [%{"type" => "function_call", "call_id" => "call_stop_window", "name" => "synthetic_tool", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => "call_stop_window", "output" => "synthetic tool result"}]

  defp turn_input(:previsible), do: [%{"type" => "compaction", "encrypted_content" => "synthetic-stop-window-compaction"}]

  defp append_historical_mail(payload, 0), do: payload

  defp append_historical_mail(payload, count) do
    historical = Enum.flat_map(1..count, fn number -> [Map.put(reasoning_item(), "id", "rs_historical_#{number}"), mailbox_item()] end)
    Map.update!(payload, "input", &(&1 ++ historical))
  end

  defp receive_until!(conn, websocket, ref, type) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    if CodexPooler.JSON.decode!(text)["type"] == type, do: :ok, else: receive_until!(conn, websocket, ref, type)
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frame = CodexPooler.JSON.decode!(text)

    if frame["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, frame},
      else: receive_terminal!(conn, websocket, ref)
  end

  defp assert_one_settlement_each!(request_ids) do
    for id <- request_ids do
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^id and l.amount_status == "recorded", select: l.entry_kind)) |> Enum.frequencies() ==
               %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  defp await_all_settled!(pool_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout_ms

    cond do
      Enum.all?(pool_requests(pool_id), &(&1.status not in ["accepted", "in_progress"])) -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("the pool's requests never settled")
      true -> Process.sleep(20) && await_all_settled!(pool_id, deadline)
    end
  end

  defp await_settled!(request_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout_ms

    cond do
      Repo.get!(Request, request_id).status != "in_progress" -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("the cut request never settled")
      true -> Process.sleep(20) && await_settled!(request_id, deadline)
    end
  end
end
