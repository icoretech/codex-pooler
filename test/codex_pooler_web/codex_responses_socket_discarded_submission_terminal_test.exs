defmodule CodexPoolerWeb.CodexResponsesSocketDiscardedSubmissionTerminalTest do
  @moduledoc """
  Findings #175: `abort_public_turn/2` empties the response queue and cancels the
  active task, but it emitted nothing for the turns it threw away. Three of its
  call sites leave the socket open, so a client that submitted one of those turns
  had no response and no close event to associate with its discarded work — only
  a client-side timeout ever ended the wait.

  This is the client-visible half of the same discard findings#172 fixed on the
  server side. The capability release stays; the answer goes alongside it.

  Only prepared frames can be answered, and only prepared frames can be queued:
  `queue_prepared_response/2` is the only function that adds queue entries
  (findings#192). A frame carries the `stream_id` its client sent, so it gets a
  bounded owner error addressed to that stream. A submission the socket refuses
  at `handle_in/2` is answered there and leaves nothing in socket state, so the
  discard has nothing of it to answer, and the abort — which keeps the socket
  serving — does not become a close.

  Both scenarios start where a request starts — a real text frame at
  `handle_in/2` — and abort through a real socket message: the owner process
  behind this socket goes down while a public turn is open. The only stand-in is
  the external surface, an owner that lives on an instance that is not connected.
  """

  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  # Failure-detection budget for a process exit that has already been decided. It
  # is immediate when it happens, so a green run never waits on it; the headroom is
  # for a loaded partitioned run.
  @reclaim_budget_ms 15_000

  # The client picks these, and the socket never sees them again until it has to
  # answer the turn they belong to. A terminal carrying one could not have been
  # copied from the active turn's context.
  @first_stream_id "discarded-first"
  @second_stream_id "discarded-second"
  @active_stream_id "discarded-active-turn"
  @refused_marker "refused-never-queued"

  setup do
    setup = accounting_setup()
    auth = %{pool: setup.pool, api_key: setup.api_key}

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "discard-#{System.unique_integer([:positive])}",
               owner_instance_id: "discard-absent-instance@127.0.0.1"
             })

    {:ok,
     auth: auth, session: Repo.get!(CodexSession, session.id), model: setup.model.exposed_model_id}
  end

  test "aborting a public turn answers every prepared turn it discards, exactly once", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    owner = idle_process()
    on_exit(fn -> send(owner, :stop) end)

    state = aborting_socket_state(auth, session, active_turn, owner)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {turn_frame(model, @first_stream_id), [opcode: :text]},
               state
             )

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in(
               {turn_frame(model, @second_stream_id), [opcode: :text]},
               state
             )

    assert [first, second] = :queue.to_list(queued_state.queued_response_payloads)

    capabilities = Enum.map([first, second], & &1.provenance.capability.server)
    monitors = Enum.map(capabilities, &Process.monitor/1)

    # The real abort: the owner this socket forwards to goes away while a public
    # turn is open. The socket survives it and keeps serving.
    assert {:push, frames, aborted_state} =
             CodexResponsesSocket.handle_info(
               {:DOWN, queued_state.websocket_owner_monitor, :process, owner, :shutdown},
               queued_state
             )

    # The discriminating outcome. Before the fix this was `{:ok, state}`: both
    # submitted turns vanished and the client was told nothing.
    assert [{:text, first_payload}, {:text, second_payload}] = frames

    first_terminal = CodexPooler.JSON.decode!(first_payload)
    second_terminal = CodexPooler.JSON.decode!(second_payload)

    # Each answer is addressed to the stream its own client opened, not to the
    # turn that happened to be active when the discard ran.
    assert first_terminal["stream_id"] == @first_stream_id
    assert second_terminal["stream_id"] == @second_stream_id
    refute first_terminal["stream_id"] == @active_stream_id
    refute second_terminal["stream_id"] == @active_stream_id

    # findings#168's classification: a lifecycle loss the client should retry.
    for terminal <- [first_terminal, second_terminal] do
      assert terminal["type"] == "error"
      assert terminal["status"] == 503
      assert terminal["error"]["code"] == "owner_unavailable"
      assert terminal["error"]["message"] == "websocket owner is unavailable"
      # findings#184: an SDK branches on `type`, and `invalid_request_error` is
      # the terminal do-not-retry class. A lifecycle 503 is server class.
      assert terminal["error"]["type"] == "server_error"
    end

    # Metadata only: no prompt, no frame body, no raw identifiers.
    for payload <- [first_payload, second_payload] do
      refute payload =~ "synthetic"
      refute payload =~ session.owner_lease_token
    end

    assert aborted_state.public_turn_aborted?
    assert :queue.is_empty(aborted_state.queued_response_payloads)

    # Zero extra upstream sends: the discarded frames were never dispatched, so
    # the tracked task set is still only the turn that was already running.
    assert aborted_state.tasks == MapSet.new([active_turn])

    # The one-terminal rule: nothing is queued behind the answer, so a second
    # trip through the socket produces no further terminal for the same turns.
    assert {:ok, settled_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, self(), "{}"},
               aborted_state
             )

    assert settled_state.discarded_submission_terminals == []

    # findings#172's release still happens, alongside the answer rather than
    # instead of it.
    for {monitor, capability} <- Enum.zip(monitors, capabilities) do
      assert_receive {:DOWN, ^monitor, :process, ^capability, :normal}, @reclaim_budget_ms
    end
  end

  test "a refused submission leaves no socket state, so the discard answers only queued turns", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    owner = idle_process()
    on_exit(fn -> send(owner, :stop) end)

    state = aborting_socket_state(auth, session, active_turn, owner)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {turn_frame(model, @first_stream_id), [opcode: :text]},
               state
             )

    # The reachable form of bytes that never became an accounted turn: the socket
    # parses the frame, refuses it, and answers it on the spot, so nothing enters
    # the queue. That is why the queue needs no clause for anything but a prepared
    # frame (findings#192). The marker sits in the refused stream id, which the
    # refusal itself never echoes.
    assert {:push, {:text, refusal}, state} =
             CodexResponsesSocket.handle_in(
               {turn_frame(model, "#{@refused_marker}/not-a-stream-id"), [opcode: :text]},
               state
             )

    assert %{"status" => 400, "error" => %{"param" => "stream_id"}} =
             CodexPooler.JSON.decode!(refusal)

    refute refusal =~ @refused_marker

    # What the refusal proves, checked where it happens: no queue entry, no pending
    # discard answer, and no copy of the refused frame anywhere in socket state.
    # The queued turn's stream id is the positive control that the inspected state
    # reaches into queue entries at all.
    assert [%PreparedWebsocketFrame{}] = :queue.to_list(state.queued_response_payloads)
    assert Map.get(state, :discarded_submission_terminals, []) == []

    inspected_state = inspect(state, limit: :infinity, printable_limit: :infinity)
    assert inspected_state =~ @first_stream_id
    refute inspected_state =~ @refused_marker

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in(
               {turn_frame(model, @second_stream_id), [opcode: :text]},
               state
             )

    # Three submissions, two queue entries: the refused one never reached it.
    assert [%PreparedWebsocketFrame{}, %PreparedWebsocketFrame{}] =
             :queue.to_list(queued_state.queued_response_payloads)

    assert {:push, frames, aborted_state} =
             CodexResponsesSocket.handle_info(
               {:DOWN, queued_state.websocket_owner_monitor, :process, owner, :shutdown},
               queued_state
             )

    # One terminal per queued turn. The socket also stays open: the abort's drain
    # contract is not a submission's to override.
    assert [{:text, first_payload}, {:text, second_payload}] = frames

    assert Enum.map(frames, fn {:text, payload} ->
             CodexPooler.JSON.decode!(payload)["stream_id"]
           end) == [@first_stream_id, @second_stream_id]

    assert CodexPooler.JSON.decode!(first_payload)["error"]["code"] == "owner_unavailable"
    assert CodexPooler.JSON.decode!(second_payload)["error"]["code"] == "owner_unavailable"

    assert :queue.is_empty(aborted_state.queued_response_payloads)
    assert aborted_state.tasks == MapSet.new([active_turn])
  end

  test "clearing a pending owner handoff answers the frame it discards", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    owner = idle_process()
    on_exit(fn -> send(owner, :stop) end)

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in(
               {turn_frame(model, @first_stream_id), [opcode: :text]},
               aborting_socket_state(auth, session, active_turn, owner)
             )

    assert [prepared] = :queue.to_list(queued_state.queued_response_payloads)

    # A real parked frame. The record around it is assembled here because the
    # replacement-handoff preflight that builds it cannot be reached with an
    # owner that is not connected (same construction as the findings#172 test).
    handoff_state =
      queued_state
      |> Map.put(:queued_response_payloads, :queue.new())
      |> Map.put(:websocket_owner_pending_handoff, %{
        prepared: prepared,
        semantic_turn_key: prepared.semantic_turn_key,
        control_ref: make_ref(),
        owner_turn_id: nil,
        outcome_logged?: false
      })

    capability = prepared.provenance.capability.server
    monitor = Process.monitor(capability)

    # `fail_pending_owner_handoff/2` already pushed here; its neighbour
    # `clear_pending_owner_handoff/3` dropped the frame in silence.
    assert {:push, [{:text, payload}], cleared_state} =
             CodexResponsesSocket.handle_info(
               {:DOWN, handoff_state.websocket_owner_monitor, :process, owner, :shutdown},
               handoff_state
             )

    terminal = CodexPooler.JSON.decode!(payload)

    assert terminal["type"] == "error"
    assert terminal["stream_id"] == @first_stream_id
    assert terminal["error"]["code"] == "owner_drained"
    assert terminal["error"]["type"] == "server_error"
    refute payload =~ "synthetic"

    refute cleared_state.websocket_owner_pending_handoff
    assert_receive {:DOWN, ^monitor, :process, ^capability, :normal}, @reclaim_budget_ms
  end

  defp aborting_socket_state(auth, session, active_turn, owner) do
    %{
      auth: auth,
      opts:
        RequestOptions.for_websocket(%{
          request_id: "discarded-submission-terminal",
          public_openai_responses_stream: true
        }),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_pid: owner,
      websocket_owner_monitor: Process.monitor(owner),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 2,
        correlation_id: "corr-discarded-submission-terminal",
        active_turn_reconnect?: false
      },
      websocket_owner_active_turn_reconnect?: false,
      tasks: MapSet.new([active_turn]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: active_turn,
      public_response_stream_id: @active_stream_id,
      public_responses_websocket_state: nil,
      public_turn_task_done?: false,
      public_turn_owner_complete?: false,
      public_turn_aborted?: false,
      public_turn_output_committed?: false,
      native_turn_output_task_pids: MapSet.new(),
      firewall_revoked?: false
    }
  end

  defp turn_frame(model, stream_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "stream_id" => stream_id,
      "model" => model,
      "stream" => true,
      "input" => [%{"role" => "user", "content" => "synthetic"}]
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
