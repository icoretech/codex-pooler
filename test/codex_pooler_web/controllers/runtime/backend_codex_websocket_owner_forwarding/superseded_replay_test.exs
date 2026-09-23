defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.SupersededReplayTest do
  # A turn cut before any output arms a pre-visible replay at its owner; when
  # the session's next socket sends a different turn instead of the resend, the
  # client has moved on (a resumed process, a new message after an interrupt).
  # The released Codex 0.156.1 CLI resumed after a kill met `409 owner_busy`
  # six times in about 6.5 s for the replay's 30 s claim and finished the turn
  # and the rest of the process over HTTPS (findings#206 rows 206-343 and
  # 206-348). The turn is now served on its first send, the interrupted request
  # settles once, and nothing is charged twice.
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

  @detection_timeout_ms 15_000

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    on_exit(fn ->
      cleanup_local_owner_sessions()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  for forwarding? <- [true, false], mode <- ["full", "lite"] do
    @tag forwarding?: forwarding?, serving_mode: mode
    test "a newer socket's different turn after a pre-visible cut is served on its first send (owner forwarding #{if forwarding?, do: "on", else: "off"}, #{mode})",
         %{forwarding?: forwarding?, serving_mode: mode} do
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding?)
      release_ref = make_ref()
      created = %{"type" => "response.created", "response" => %{"id" => "resp_superseded_cut", "status" => "in_progress", "output" => []}}
      in_progress = %{"type" => "response.in_progress", "response" => %{"id" => "resp_superseded_cut", "status" => "in_progress", "output" => []}}

      upstream =
        start_upstream(
          # provenance: observed findings#206 row 206-343 (released Codex 0.156.1 resumed after a kill of the process whose turn the provider held before output)
          FakeUpstream.strict_sequence([
            strict_native_request(
              1,
              FakeUpstream.barrier_websocket_frames(
                [CodexPooler.JSON.encode!(created), CodexPooler.JSON.encode!(in_progress)],
                notify: self(),
                release_ref: release_ref
              )
            ),
            strict_native_request(2, FakeUpstream.websocket_text_frames([completed_frame("resp_superseding_turn")])),
            strict_native_request(2, FakeUpstream.websocket_text_frames([completed_frame("resp_later_turn")]))
          ])
        )

      setup = gateway_setup(upstream)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
      turn_state = Ecto.UUID.generate()
      thread_id = Ecto.UUID.generate()
      model = setup.model.exposed_model_id
      cut_payload = CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "superseded-turn", 100, [synthetic_user_item("interrupted question")]))

      next_payload =
        CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "superseding-turn", 900, [synthetic_user_item("interrupted question"), synthetic_user_item("next question")]))

      later_payload =
        CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "later-turn", 1_700, [synthetic_user_item("interrupted question"), synthetic_user_item("next question"), synthetic_user_item("later question")]))

      port = start_public_endpoint!()

      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, cut_payload)

      for ordinal <- [0, 1] do
        assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @detection_timeout_ms
        assert :ok = FakeUpstream.release_frame(upstream, release_ref)
      end

      assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^release_ref}, @detection_timeout_ms
      {conn, websocket, first} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, _websocket, second} = public_websocket_receive_text!(conn, websocket, ref)
      assert Enum.map([first, second], &CodexPooler.JSON.decode!(&1)["type"]) == ["response.created", "response.in_progress"]
      assert [%Request{id: cut_request_id, status: "in_progress"}] = request_logs(setup.pool.id)
      _result = Mint.HTTP.close(conn)

      # The next turn comes from a new process: seconds later, long after the
      # closing socket armed the replay (forwarding on) or settled its turn
      # (forwarding off); these waits stand for that gap.
      deadline_ms = System.monotonic_time(:millisecond) + @detection_timeout_ms

      if forwarding?,
        do: assert(await_entitlement_status(cut_request_id, deadline_ms) == "armed"),
        else: assert(await_request_settled(cut_request_id, deadline_ms) == "failed")

      {next_conn, next_websocket, next_ref} = public_websocket_connect!(port, setup, turn_state)
      {next_conn, next_websocket} = public_websocket_send_text!(next_conn, next_websocket, next_ref, next_payload)
      {next_conn, next_websocket, next_frames} = receive_frames_until_terminal!(next_conn, next_websocket, next_ref, [])

      assert {Enum.map(next_frames, & &1["type"]), get_in(List.last(next_frames), ["error", "code"])} == {["response.completed"], nil}

      # The same socket keeps serving the process's later turns.
      {next_conn, next_websocket} = public_websocket_send_text!(next_conn, next_websocket, next_ref, later_payload)
      {next_conn, next_websocket, later_frames} = receive_frames_until_terminal!(next_conn, next_websocket, next_ref, [])
      assert Enum.map(later_frames, & &1["type"]) == ["response.completed"]
      assert await_request_settled(cut_request_id, System.monotonic_time(:millisecond) + @detection_timeout_ms) == "failed"
      assert [%Request{id: ^cut_request_id} = cut, %Request{} = next, %Request{} = later] = request_logs(setup.pool.id)

      for request <- [next, later],
          do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) == "succeeded")

      cut = Repo.get!(Request, cut.id)

      expected_cut_code = if forwarding?, do: "websocket_replay_superseded", else: "client_disconnected"
      assert {cut.status, cut.response_status_code, cut.last_error_code, cut.usage_status} == {"failed", 499, expected_cut_code, "usage_unknown"}
      assert [%Attempt{replay_generation: 0}] = request_attempts(cut.id)
      assert [%Attempt{replay_generation: 0, status: "succeeded"}] = request_attempts(next.id)
      # Forwarding on settles through the entitlement close (like its expiry);
      # forwarding off interrupts the direct turn at the socket's cleanup.
      assert Repo.get_by!(CodexTurn, request_id: cut.id).status == if(forwarding?, do: "failed", else: "interrupted")

      if forwarding? do
        assert %RequestReplayEntitlement{status: "revoked", closed_at: %DateTime{}, replay_attempt_id: nil} =
                 Repo.get_by!(RequestReplayEntitlement, request_id: cut.id)
      else
        refute Repo.get_by(RequestReplayEntitlement, request_id: cut.id)
      end

      for request_id <- [cut.id, next.id, later.id] do
        assert ledger_kinds(request_id) == %{"reservation" => 1, "settlement" => 1, "release" => 1}
      end

      assert FakeUpstream.count(upstream) == 3

      if forwarding? do
        # The interrupted turn's own resend after the client moved on is
        # refused without a dispatch; it cannot buy that turn a second time.
        {next_conn, next_websocket} = public_websocket_send_text!(next_conn, next_websocket, next_ref, cut_payload)
        {next_conn, _next_websocket, resend_frames} = receive_frames_until_terminal!(next_conn, next_websocket, next_ref, [])
        assert %{"type" => "error", "status" => 409, "error" => %{"code" => "duplicate_turn"}} = List.last(resend_frames)
        assert FakeUpstream.count(upstream) == 3
        assert ledger_kinds(cut.id) == %{"reservation" => 1, "settlement" => 1, "release" => 1}
        _result = Mint.HTTP.close(next_conn)
      else
        _result = Mint.HTTP.close(next_conn)
      end

      _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  # The redeemed replay is the socket's reconnect turn; the socket used to keep
  # resolving its owner frames to that finished turn's task, so the next turn's
  # terminal was never accepted for its own task, that task stayed tracked, and
  # the turn after it queued behind it forever with no answer (reproduced at
  # `80ee3cac4`; the superseding turn above takes the same reconnect path).
  test "a socket that redeemed a pre-visible replay keeps serving the turns after it" do
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    release_ref = make_ref()
    created = %{"type" => "response.created", "response" => %{"id" => "resp_redeemed_cut", "status" => "in_progress", "output" => []}}
    in_progress = %{"type" => "response.in_progress", "response" => %{"id" => "resp_redeemed_cut", "status" => "in_progress", "output" => []}}

    upstream =
      start_upstream(
        # provenance: observed findings#232 row 232-161 (released Codex client resends a turn cut after response.created/in_progress on a new socket, then continues the session there)
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.barrier_websocket_frames([CodexPooler.JSON.encode!(created), CodexPooler.JSON.encode!(in_progress)], notify: self(), release_ref: release_ref)),
          strict_native_request(2, FakeUpstream.websocket_text_frames([completed_frame("resp_redeemed_replay")])),
          strict_native_request(2, FakeUpstream.websocket_text_frames([completed_frame("resp_after_replay_1")])),
          strict_native_request(2, FakeUpstream.websocket_text_frames([completed_frame("resp_after_replay_2")]))
        ])
      )

    setup = gateway_setup(upstream)
    turn_state = Ecto.UUID.generate()
    thread_id = Ecto.UUID.generate()
    model = setup.model.exposed_model_id
    cut_payload = CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "redeemed-turn", 100, [synthetic_user_item("first question")]))
    second = CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "after-replay-1", 900, [synthetic_user_item("first question"), synthetic_user_item("second question")]))

    third =
      CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "after-replay-2", 1_700, [synthetic_user_item("first question"), synthetic_user_item("second question"), synthetic_user_item("third question")]))

    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, cut_payload)

    for ordinal <- [0, 1] do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @detection_timeout_ms
      assert :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^release_ref}, @detection_timeout_ms
    {conn, websocket, _created} = public_websocket_receive_text!(conn, websocket, ref)
    {conn, _websocket, _in_progress} = public_websocket_receive_text!(conn, websocket, ref)
    assert [%Request{id: cut_request_id}] = request_logs(setup.pool.id)
    _result = Mint.HTTP.close(conn)
    assert await_entitlement_status(cut_request_id, System.monotonic_time(:millisecond) + @detection_timeout_ms) == "armed"

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    {conn, websocket, answers} =
      Enum.reduce([cut_payload, second, third], {conn, websocket, []}, fn payload, {conn, websocket, answers} ->
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, websocket, frames} = receive_frames_until_terminal!(conn, websocket, ref, [])
        {conn, websocket, answers ++ [Enum.map(frames, & &1["type"])]}
      end)

    assert answers == [["response.completed"], ["response.completed"], ["response.completed"]]
    assert [%Request{id: ^cut_request_id} | later] = request_logs(setup.pool.id)
    assert length(later) == 2

    for request <- [Repo.get!(Request, cut_request_id) | later] do
      assert await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) == "succeeded"
      assert ledger_kinds(request.id) == %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end

    assert FakeUpstream.count(upstream) == 4
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
    assert :ok = FakeUpstream.verify!(upstream)
    _result = Mint.HTTP.close(conn)
    _websocket = websocket
  end

  # The owner runs on another VM: the new socket's preflight and turn go
  # through the production e-RPC forwarder (a node client that applies the
  # call on this node), and the owner retires the replay it armed there.
  @tag :replay_topology
  test "a remote owner retires its armed pre-visible replay for the next socket's different turn" do
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings#206 row 206-343 (the provider holds the interrupted turn before any output)
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: release_ref,
                code: 1001,
                reason: "synthetic held turn"
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond: FakeUpstream.websocket_text_frames([completed_frame("resp_remote_superseding_turn")])
          )
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "full")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = Ecto.UUID.generate()
    {:ok, state} = owner_socket(auth, "ws-remote-superseded", turn_state)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-superseded.example"
    ReplayRemoteNodeClient.configure(remote_node, self())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      state.codex_session
      |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
      |> Repo.update!()

    active_owner_lease(session.id)
    |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
    |> Repo.update!()

    :sys.replace_state(owner_pid, fn owner_state -> %{owner_state | owner_instance_id: Atom.to_string(remote_node)} end)
    node_client_options = [node_client: ReplayRemoteNodeClient]
    remote_state = state |> remote_owner_state(remote_node, node_client_options) |> Map.put(:codex_session, session)
    thread_id = Ecto.UUID.generate()
    model = setup.model.exposed_model_id
    cut_payload = CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "remote-superseded-turn", 100, [synthetic_user_item("interrupted question")]))

    next_payload =
      CodexPooler.JSON.encode!(native_turn_payload(thread_id, model, "remote-superseding-turn", 900, [synthetic_user_item("interrupted question"), synthetic_user_item("next question")]))

    assert {:ok, remote_state} = CodexResponsesSocket.handle_in({cut_payload, [opcode: :text]}, remote_state)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @detection_timeout_ms
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v1}, @detection_timeout_ms

    assert Gateway.detach_websocket_owner_downstream(session, remote_state.websocket_owner_lease_token, remote_state.websocket_owner_downstream, remote_state.opts) in [
             :suspended,
             :ok
           ]

    assert %{active_turn: nil, suspended_replay: %{provisional_status: :armed}} = :sys.get_state(owner_pid)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:ok, remote_state} = receive_socket_done(remote_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
    assert [%Request{id: cut_request_id, status: "in_progress"}] = request_logs(setup.pool.id)
    flush_remote_owner_calls(remote_node)

    {:ok, next_state} = owner_socket(auth, "ws-remote-superseding", turn_state, websocket_owner_forwarder_opts: node_client_options)
    assert next_state.websocket_owner_downstream.epoch == 2
    assert {:ok, next_state} = CodexResponsesSocket.handle_in({next_payload, [opcode: :text]}, next_state)
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}, @detection_timeout_ms
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v1}, @detection_timeout_ms
    assert {:push, {:text, frame}, next_state} = receive_owner_socket_push(next_state)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(frame)
    assert {:ok, next_state} = receive_owner_socket_complete(next_state)
    assert {:ok, next_state} = receive_socket_done(next_state)

    assert [%Request{id: ^cut_request_id} = cut, %Request{} = next] = request_logs(setup.pool.id)
    assert await_request_settled(next.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) == "succeeded"
    cut = Repo.get!(Request, cut.id)
    assert {cut.status, cut.response_status_code, cut.last_error_code} == {"failed", 499, "websocket_replay_superseded"}
    assert %RequestReplayEntitlement{status: "revoked", closed_at: %DateTime{}} = Repo.get_by!(RequestReplayEntitlement, request_id: cut.id)

    for request_id <- [cut.id, next.id] do
      assert ledger_kinds(request_id) == %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end

    assert %{active_turn: nil, suspended_replay: nil, downstream_epoch: 2} = :sys.get_state(owner_pid)
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, next_state)
  end

  defp native_turn_payload(thread_id, model, turn_id, start_ms, input) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => turn_id,
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => turn_id, "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => start_ms
      },
      "input" => input
    }
  end

  defp synthetic_user_item(text),
    do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic " <> text}]}

  defp completed_frame(response_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{
        "id" => response_id,
        "status" => "completed",
        "output" => [],
        "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
      }
    })
  end

  defp receive_frames_until_terminal!(conn, websocket, ref, frames) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frames = frames ++ [CodexPooler.JSON.decode!(text)]

    if List.last(frames)["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, websocket, Enum.reject(frames, &(&1["type"] in ["response.created", "response.in_progress", "codex.response.metadata"]))},
      else: receive_frames_until_terminal!(conn, websocket, ref, frames)
  end

  defp await_entitlement_status(request_id, deadline_ms) do
    status =
      case Repo.get_by(RequestReplayEntitlement, request_id: request_id) do
        %RequestReplayEntitlement{status: status} -> status
        nil -> nil
      end

    if status != nil or System.monotonic_time(:millisecond) >= deadline_ms do
      status
    else
      Process.sleep(5)
      await_entitlement_status(request_id, deadline_ms)
    end
  end

  defp await_request_settled(request_id, deadline_ms) do
    case Repo.get!(Request, request_id) do
      %Request{status: "in_progress"} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          "in_progress"
        else
          Process.sleep(10)
          await_request_settled(request_id, deadline_ms)
        end

      %Request{status: status} ->
        status
    end
  end

  defp request_attempts(request_id), do: Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request_id, order_by: [asc: attempt.attempt_number]))

  defp ledger_kinds(request_id) do
    Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request_id, select: entry.entry_kind))
    |> Enum.frequencies()
  end

  defp flush_remote_owner_calls(remote_node) do
    receive do
      {:replay_remote_owner_call, ^remote_node, _function} -> flush_remote_owner_calls(remote_node)
    after
      0 -> :ok
    end
  end
end
