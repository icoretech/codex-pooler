defmodule CodexPoolerWeb.CodexResponsesSocketPreparedFrameProvenanceTest do
  @moduledoc """
  Findings #168: the socket seals a prepared websocket frame, then writes
  `native_compaction_reservation` into its request options to remember that the
  owner granted no compaction admission and the reservation should be asked
  again once the active turn drains. The owner-forwarded active-turn-reconnect
  route dispatches that frame without the queue, so the write has to be
  invisible to the frame's own signature; while the field was part of the
  signed basis the frame stopped verifying and the client was told
  `400 invalid_request / prepared websocket frame provenance is invalid` for a
  server bookkeeping fault, with no log line at any of the three emit sites.

  Findings #206 row 206-339: that route then refused every deferral 503, while
  the same frame arriving with no task tracked runs as the ordinary turn. It
  now applies the dequeue's rule: a final turn whose owner answered without an
  admission is dispatched as the ordinary turn; an owner that could not be
  asked at all, and an incremental compaction, keep the retryable 503.

  Every scenario starts where the request starts, a raw text frame arriving at
  `handle_in/2`, with an authenticated API key and a model the Pool routes
  (row 206-340: a synthetic auth without `key_prefix`/`api_key_id`/`pool_id`
  and an unroutable model made every ordinary run crash or answer
  `400 invalid_model`). The absent-owner scenarios put the session's owner on an
  instance that is not connected, which is what makes the reservation fail
  with `owner_unavailable` through the real forwarder. The live-owner
  scenarios run a local owner whose turn was interrupted by the client and a
  reconnected socket whose prewarm task has not reported its result yet.
  """

  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [cleanup_local_owner_sessions: 0, owner_socket: 4, request_logs: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  # Failure-detection budget for a response task result under N=4.
  @detection_timeout_ms 15_000

  setup do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()

      case previous do
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    # Nothing in these scenarios may reach the provider except the live-owner
    # boundary's own sends, which never touch this upstream.
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, upstream: upstream, setup: setup, auth: auth, model: setup.model.exposed_model_id}
  end

  describe "an owner on an instance that is not connected" do
    setup %{auth: auth} do
      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 accepted_turn_state: "provenance-#{System.unique_integer([:positive])}",
                 owner_instance_id: "provenance-absent-instance@127.0.0.1"
               })

      {:ok, session: Repo.get!(CodexSession, session.id)}
    end

    test "a deferred compaction reservation on the reconnect route answers owner_unavailable, not a client 400",
         %{auth: auth, session: session, model: model, upstream: upstream} do
      active_turn = idle_process()
      on_exit(fn -> send(active_turn, :stop) end)

      state = reconnect_socket_state(auth, session, active_turn)

      {result, log} =
        with_info_log(fn ->
          CodexResponsesSocket.handle_in(
            {final_compaction_frame(model), [opcode: :text]},
            state
          )
        end)

      assert {:push, {:text, frame}, settled_state} = result
      decoded = CodexPooler.JSON.decode!(frame)

      # The honest answer for "the owner could not be asked and this route
      # cannot queue the frame": the retryable owner vocabulary that
      # `start_deferred_or_tracked_response/2`'s own failure branch already
      # returns. Before the fix this was `400 invalid_request` with
      # "prepared websocket frame provenance is invalid".
      assert decoded["status"] == 503
      assert decoded["error"]["code"] == "owner_unavailable"
      refute decoded["error"]["message"] =~ "provenance"

      # The frame is refused before any response work starts, at the deferral:
      # an owner that could not be asked is not asked again through the
      # ordinary preflight (row 206-339 keeps this half of the rule).
      assert settled_state.tasks == MapSet.new([active_turn])
      assert :queue.is_empty(settled_state.queued_response_payloads)
      assert log =~ "rejection_stage=native_compaction_deferral"
      assert FakeUpstream.count(upstream) == 0
    end

    test "the queue route unwinds the deferral, re-seals, and reports the owner failure once", %{
      auth: auth,
      session: session,
      model: model,
      upstream: upstream
    } do
      active_turn = idle_process()
      on_exit(fn -> send(active_turn, :stop) end)

      state =
        auth
        |> reconnect_socket_state(session, active_turn)
        |> Map.put(:websocket_owner_active_turn_reconnect?, false)
        |> put_in([:websocket_owner_downstream, :active_turn_reconnect?], false)

      # An owner-forwarded socket with a live turn queues the frame instead of
      # dispatching it, deferral and all.
      assert {:ok, queued_state} =
               CodexResponsesSocket.handle_in(
                 {final_compaction_frame(model), [opcode: :text]},
                 state
               )

      assert [%{request_options: %RequestOptions{native_compaction_reservation: %{phase: :final}}}] =
               :queue.to_list(queued_state.queued_response_payloads)

      # Draining the active turn dequeues it: the deferral is unwound, the frame
      # is re-sealed with the runtime options, and the owner is asked again.
      {dequeued_state, log} =
        with_info_log(fn ->
          assert {:ok, dequeued_state} =
                   CodexResponsesSocket.handle_info(
                     {:codex_response_done, active_turn, :ok},
                     queued_state
                   )

          dequeued_state
        end)

      # An owner that could not be asked at all is refused at the deferral, not
      # run as the ordinary turn: that run answers the same 503 with no row, so
      # only the stage tells the two apart (findings#206 row 206-342).
      assert log =~ "rejection_stage=native_compaction_deferral"
      assert :queue.is_empty(dequeued_state.queued_response_payloads)
      assert [retry_task] = MapSet.to_list(dequeued_state.tasks)
      refute retry_task == active_turn

      # The owner is still absent, so the retry reports the same retryable
      # vocabulary the reconnect route now returns.
      assert_receive {:codex_response_done, ^retry_task, result}, @detection_timeout_ms

      assert {:push, {:text, frame}, _final_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_done, retry_task, result},
                 dequeued_state
               )

      decoded = CodexPooler.JSON.decode!(frame)
      assert decoded["status"] == 503
      assert decoded["error"]["code"] == "owner_unavailable"
      assert FakeUpstream.count(upstream) == 0
    end

    # The capability is a GenServer with a hard 30 s TTL and no keepalive, so a
    # frame parked behind a long turn loses it before the dequeue re-seals. That
    # is a second, independent trigger for the same rejection (findings #168's
    # first adjacent finding) and it is not fixed here — but the re-seal failure
    # must not turn its retryable answer into an invariant-breach 5xx now that
    # the failure travels instead of being swallowed. Stopping the capability
    # process is exactly what the TTL does.
    test "a capability lost before the dequeue re-seal stays retryable and is no longer silent", %{
      auth: auth,
      session: session,
      model: model,
      upstream: upstream
    } do
      active_turn = idle_process()
      on_exit(fn -> send(active_turn, :stop) end)

      state =
        auth
        |> reconnect_socket_state(session, active_turn)
        |> Map.put(:websocket_owner_active_turn_reconnect?, false)
        |> put_in([:websocket_owner_downstream, :active_turn_reconnect?], false)

      assert {:ok, queued_state} =
               CodexResponsesSocket.handle_in(
                 {final_compaction_frame(model), [opcode: :text]},
                 state
               )

      assert [queued] = :queue.to_list(queued_state.queued_response_payloads)
      assert :ok = GenServer.stop(queued.provenance.capability.server)

      {dequeued_state, log} =
        with_log(fn ->
          assert {:ok, dequeued_state} =
                   CodexResponsesSocket.handle_info(
                     {:codex_response_done, active_turn, :ok},
                     queued_state
                   )

          dequeued_state
        end)

      # The swallowed re-seal failure left no trace at all before this change.
      assert log =~ "prepared websocket frame reseal failed"
      assert log =~ "stage=deferred_runtime_options"
      refute log =~ model

      assert [retry_task] = MapSet.to_list(dequeued_state.tasks)
      assert_receive {:codex_response_done, ^retry_task, result}, @detection_timeout_ms

      assert {:push, {:text, frame}, _final_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_done, retry_task, result},
                 dequeued_state
               )

      decoded = CodexPooler.JSON.decode!(frame)
      assert decoded["status"] == 503
      assert decoded["error"]["code"] == "owner_unavailable"
      assert FakeUpstream.count(upstream) == 0
    end
  end

  # Row 206-339, the production sequence behind findings#168: the user
  # interrupts a running turn in a compacted session, the client drops its
  # socket while the owner's turn is still open, and the next turn goes out on
  # a new socket that attaches to that owner as an active-turn reconnect. The
  # client prewarms the new socket, then sends the turn with its full history,
  # which carries the compaction item (phase `final`); the owner holds no
  # admission for it. Whether the prewarm's task has reported its result when
  # the turn arrives is a race: `task_reported` is the undeferred control,
  # `task_held` leaves the prewarm's result unprocessed so the reservation is
  # deferred. Both must get the answer the ordinary route gives a new turn at
  # an owner that still holds its predecessor, suspended for a resend
  # (interrupted before output) or cancelled (after output): `409 owner_busy`
  # from the owner's own preflight. The deferred frame used to be refused
  # `503 owner_unavailable` at the deferral instead.
  for mode <- ["full", "lite"], interrupt <- [:before_output, :after_output], prewarm <- [:task_reported, :task_held] do
    @tag serving_mode: mode
    @tag interrupt: interrupt
    @tag prewarm: prewarm
    test "#{mode} final turn on a reconnect after an interrupt #{interrupt} with the prewarm #{prewarm} gets the ordinary route's answer",
         %{setup: setup, auth: auth, model: model, upstream: upstream, serving_mode: mode, interrupt: interrupt, prewarm: prewarm} do
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
      {first_state, reconnect_state, owner_pid, predecessor} = interrupted_owner_reconnect!(auth, model, interrupt)
      state = prewarm!(reconnect_state, model, prewarm)
      owner_before = :sys.get_state(owner_pid)

      {result, log} =
        with_info_log(fn -> CodexResponsesSocket.handle_in({final_turn_frame(model, "provenance-live-turn-b"), [opcode: :text]}, state) end)

      assert {:push, {:text, frame}, refused_state} = result
      assert %{"status" => 409, "error" => %{"code" => "owner_busy"}} = CodexPooler.JSON.decode!(frame)
      assert log =~ "rejection_stage=replay_preflight"
      assert log =~ "public_code=owner_busy"
      refute log =~ "rejection_stage=native_compaction_deferral"

      # The owner's turn and handoff state are untouched, nothing was recorded
      # for the refused turn, and nothing reached the provider.
      owner_after = :sys.get_state(owner_pid)
      assert Map.take(owner_after, [:active_turn, :suspended_replay, :pending_handoff]) == Map.take(owner_before, [:active_turn, :suspended_replay, :pending_handoff])
      assert owner_after.pending_handoff == nil
      assert [%{} = _interrupted] = request_logs(setup.pool.id)
      assert FakeUpstream.count(upstream) == 0
      refute_received {:provenance_unexpected_send, _worker}

      refused_state = if prewarm == :task_held, do: settle_held_prewarm!(refused_state), else: refused_state
      release_interrupted_turn!(predecessor)
      CodexResponsesSocket.terminate(:closed, first_state)
      CodexResponsesSocket.terminate(:closed, refused_state)
    end
  end

  # The phase half of the rule on the same route: an incremental compaction
  # the owner granted no admission can never be confirmed, so it keeps the
  # retryable refusal whether or not it was deferred.
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "#{mode} incremental compaction deferred on a live-owner reconnect keeps the retryable 503",
         %{setup: setup, auth: auth, model: model, upstream: upstream, serving_mode: mode} do
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
      {first_state, reconnect_state, _owner_pid, predecessor} = interrupted_owner_reconnect!(auth, model, :before_output)
      state = prewarm!(reconnect_state, model, :task_held)

      {result, log} =
        with_info_log(fn -> CodexResponsesSocket.handle_in({incremental_compaction_frame(model), [opcode: :text]}, state) end)

      assert {:push, {:text, frame}, refused_state} = result
      assert %{"status" => 503, "error" => %{"code" => "owner_unavailable"}} = CodexPooler.JSON.decode!(frame)
      assert log =~ "rejection_stage=native_compaction_deferral"
      assert refused_state.websocket_owner_pending_handoff == nil
      assert [_interrupted] = request_logs(setup.pool.id)
      assert FakeUpstream.count(upstream) == 0
      refute_received {:provenance_unexpected_send, _worker}

      refused_state = settle_held_prewarm!(refused_state)
      release_interrupted_turn!(predecessor)
      CodexResponsesSocket.terminate(:closed, first_state)
      CodexResponsesSocket.terminate(:closed, refused_state)
    end
  end

  # Runs the interrupted turn on a first socket through a local owner, drops
  # that socket as the client does on an interrupt, and attaches a second one.
  # `:before_output` cuts the turn before anything reached the client, so the
  # owner suspends it into its replay entitlement; `:after_output` shows the
  # client one delta first, so the owner cancels it.
  defp interrupted_owner_reconnect!(auth, model, interrupt) when interrupt in [:before_output, :after_output] do
    boundary = interrupted_turn_upstream_boundary(self(), interrupt == :after_output)
    turn_state = "provenance-live-owner-#{System.unique_integer([:positive])}"
    {:ok, first_state} = owner_socket(auth, "provenance-live-a", turn_state, websocket_owner_forwarder_opts: [upstream: boundary])

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({final_turn_frame(model, "provenance-live-turn-a"), [opcode: :text]}, first_state)

    assert_receive {:provenance_predecessor_started, predecessor}, @detection_timeout_ms
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)

    first_state =
      if interrupt == :after_output do
        first_state = deliver_owner_frames!(first_state, ["response.created", "response.output_text.delta"])
        assert :ok = WebsocketOwnerSession.detach_downstream(owner_pid, first_state.websocket_owner_downstream)
        assert %{active_turn: %{descriptor: %{kind: :native}, canceled_result: _canceled}} = :sys.get_state(owner_pid)
        first_state
      else
        assert :suspended = WebsocketOwnerSession.detach_downstream(owner_pid, first_state.websocket_owner_downstream)
        first_state
      end

    {:ok, reconnect_state} = owner_socket(auth, "provenance-live-b", turn_state, websocket_owner_forwarder_opts: [upstream: boundary])
    assert reconnect_state.websocket_owner_active_turn_reconnect? == true
    assert reconnect_state.codex_session.id == first_state.codex_session.id

    {first_state, reconnect_state, owner_pid, predecessor}
  end

  # Ends the provider stream the interrupted turn is still holding, so the
  # first socket's task can settle when that socket terminates.
  defp release_interrupted_turn!(predecessor) do
    monitor = Process.monitor(predecessor)
    Process.exit(predecessor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^predecessor, _reason}, @detection_timeout_ms
  end

  # Hands the owner's frames to the first socket until the expected client
  # frames were pushed, as its WebSock loop would.
  defp deliver_owner_frames!(state, []), do: state

  defp deliver_owner_frames!(state, [type | rest] = expected) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:push, {:text, frame}, state} ->
            assert %{"type" => ^type} = CodexPooler.JSON.decode!(frame)
            deliver_owner_frames!(state, rest)

          {:ok, state} ->
            deliver_owner_frames!(state, expected)
        end

      {tag, _, _, _, _, _, _} = message when tag == :websocket_owner_output_commit_probe ->
        {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        deliver_owner_frames!(state, expected)

      {:websocket_response_activity, _, _} = message ->
        {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        deliver_owner_frames!(state, expected)
    after
      @detection_timeout_ms -> flunk("expected owner frame #{type}")
    end
  end

  # The released client's prewarm on the new socket stays local to it. Its
  # two frames are delivered; its result is processed (`task_reported`) or
  # left in the mailbox with the task still tracked (`task_held`).
  defp prewarm!(state, model, prewarm) do
    assert {:ok, state} = CodexResponsesSocket.handle_in({prewarm_frame(model), [opcode: :text]}, state)
    assert {:push, {:text, created}, state} = receive_socket_push(state)
    assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)
    assert {:push, {:text, completed}, state} = receive_socket_push(state)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed)

    case prewarm do
      :task_reported ->
        settle_held_prewarm!(state)

      :task_held ->
        assert [_prewarm_task] = MapSet.to_list(state.tasks)
        state
    end
  end

  # Processes the held prewarm task's activity token, result and delivery
  # completion in mailbox order, as the WebSock loop does. The interrupted
  # turn's task reports to the same test process, so only this task's
  # messages are taken.
  defp settle_held_prewarm!(state) do
    assert [task] = MapSet.to_list(state.tasks)
    state = settle_task!(state, task)
    assert MapSet.size(state.tasks) == 0
    state
  end

  defp settle_task!(state, task) do
    receive do
      {:websocket_response_activity, ^task, _token} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        settle_task!(state, task)

      {:codex_response_done, ^task, _result} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)

        receive do
          {:websocket_response_delivery_complete, ^task, _token} = delivered ->
            assert {:ok, state} = CodexResponsesSocket.handle_info(delivered, state)
            state
        after
          0 -> state
        end
    after
      @detection_timeout_ms -> flunk("expected the prewarm task's result")
    end
  end

  # The owner's upstream: the interrupted turn's send never returns (as a
  # provider stream that is still running), optionally after one visible
  # delta. No other turn may reach it.
  defp interrupted_turn_upstream_boundary(test_pid, visible?) do
    counter = :counters.new(1, [:atomics])

    %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, writer ->
        :ok = :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          # A provider stream that is slow to cancel: the owner's shutdown
          # does not stop it, so the cancelled turn stays open while the
          # client reconnects. The test kills it when it is done.
          Process.flag(:trap_exit, true)

          if visible? do
            for frame <- [%{"type" => "response.created", "response" => %{"id" => "resp_provenance_live_owner_a", "status" => "in_progress"}}, %{"type" => "response.output_text.delta", "delta" => "synthetic"}] do
              encoded = CodexPooler.JSON.encode!(frame)
              _result = writer.(encoded, TerminalDiscriminator.classify(encoded))
            end
          end

          send(test_pid, {:provenance_predecessor_started, self()})

          receive do
            :provenance_never -> :ok
          end
        else
          send(test_pid, {:provenance_unexpected_send, self()})
          :ok
        end
      end,
      invalidate: fn _upstream_pid -> :ok end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp reconnect_socket_state(auth, session, active_turn) do
    %{
      auth: auth,
      opts: RequestOptions.for_websocket(%{request_id: "provenance-deferral"}),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 2,
        correlation_id: "corr-provenance-deferral",
        active_turn_reconnect?: true
      },
      websocket_owner_active_turn_reconnect?: true,
      tasks: MapSet.new([active_turn]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: nil,
      public_response_stream_id: nil,
      public_responses_websocket_state: nil,
      public_turn_task_done?: false,
      public_turn_owner_complete?: false,
      public_turn_aborted?: false,
      public_turn_output_committed?: false,
      native_turn_output_task_pids: MapSet.new(),
      firewall_revoked?: false
    }
  end

  defp final_compaction_frame(model) do
    metadata = %{
      "turn_id" => "provenance-turn-#{System.unique_integer([:positive])}",
      "request_kind" => "turn",
      "window_id" => "provenance-window",
      "window_number" => 2,
      "context_window_id" => Ecto.UUID.generate()
    }

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model,
      "stream" => true,
      "input" => [
        %{"type" => "compaction", "encrypted_content" => "synthetic-compaction"},
        %{"role" => "user", "content" => "synthetic"}
      ],
      "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(metadata)}
    })
  end

  # A turn of a compacted session as the released client sends it on a new
  # socket: full history with the compaction item in place of what it
  # compacted, no anchor.
  defp final_turn_frame(model, turn_id) do
    native_frame(model, turn_id, "turn", [
      %{"type" => "compaction", "encrypted_content" => "synthetic-live-owner-compaction"},
      %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{turn_id}"}]}
    ])
  end

  defp prewarm_frame(model) do
    model
    |> native_frame("provenance-live-turn-b", "prewarm", [])
    |> CodexPooler.JSON.decode!()
    |> Map.put("generate", false)
    |> CodexPooler.JSON.encode!()
  end

  # An incremental compaction: anchored on the previous response, the
  # compaction trigger as its only input.
  defp incremental_compaction_frame(model) do
    model
    |> native_frame("provenance-live-turn-b", "compaction", [%{"type" => "compaction_trigger"}], %{
      "compaction" => %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "mid_turn", "strategy" => "memento"}
    })
    |> CodexPooler.JSON.decode!()
    |> Map.put("previous_response_id", "resp_provenance_live_owner_anchor")
    |> CodexPooler.JSON.encode!()
  end

  defp native_frame(model, turn_id, request_kind, input, extra_metadata \\ %{}) do
    metadata =
      Map.merge(
        %{
          "session_id" => "provenance-live-owner-thread",
          "thread_id" => "provenance-live-owner-thread",
          "turn_id" => turn_id,
          "request_kind" => request_kind,
          "window_id" => "provenance-live-owner-thread:1",
          "window_number" => 1,
          "context_window_id" => "00000000-0000-4000-8000-00000000b001"
        },
        extra_metadata
      )

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model,
      "input" => input,
      "stream" => true,
      "client_metadata" => %{"turn_id" => turn_id, "x-codex-turn-metadata" => CodexPooler.JSON.encode!(metadata)}
    })
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end
end
