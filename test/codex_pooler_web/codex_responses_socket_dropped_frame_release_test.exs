defmodule CodexPoolerWeb.CodexResponsesSocketDroppedFrameReleaseTest do
  @moduledoc """
  Findings #172: parking a queued prepared frame's capability (findings#169)
  suppresses the only bound that ever reclaimed a capability whose frame was
  never dispatched. Parking is never released, so a frame the socket *discards*
  instead of dispatching leaves its capability alive until the socket exits.

  `abort_public_turn/2` is the unbounded one. `public_turn_aborted?` is cleared
  again by `finish_public_turn/1`, so one socket can abort, recover and abort
  again for its whole life, and every abort drops whatever was queued.

  The scenario starts where the request starts, a raw text frame arriving at
  `handle_in/2`, and aborts through a real socket message: the owner process
  behind this socket goes down while a public turn is open. The only stand-in is
  the external surface — the session's owner lives on an instance that is not
  connected.

  The classification findings#168 established has to survive: a capability that
  is gone but whose digest still verifies is a retryable `503 owner_unavailable`,
  not a provenance breach. Releasing at the drop has to look exactly like the
  reclaim timer firing, which is what `codex_responses_socket_queued_frame_ttl_test`
  already drives end to end.
  """

  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  # A process exit that has already been decided; it is immediate when it happens.
  @reclaim_budget_ms 1_000

  setup do
    setup = accounting_setup()
    auth = %{pool: setup.pool, api_key: setup.api_key}

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "drop-#{System.unique_integer([:positive])}",
               owner_instance_id: "drop-absent-instance@127.0.0.1"
             })

    {:ok,
     auth: auth, session: Repo.get!(CodexSession, session.id), model: setup.model.exposed_model_id}
  end

  test "aborting a public turn releases the capability of the queued frame it drops", %{
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
               {turn_frame(model), [opcode: :text]},
               aborting_socket_state(auth, session, active_turn, owner)
             )

    assert [queued] = :queue.to_list(queued_state.queued_response_payloads)
    capability_server = queued.provenance.capability.server
    monitor = Process.monitor(capability_server)

    # The real abort: the owner this socket forwards to goes away while a public
    # turn is open. The socket survives it and keeps serving.
    assert {:ok, aborted_state} =
             CodexResponsesSocket.handle_info(
               {:DOWN, queued_state.websocket_owner_monitor, :process, owner, :shutdown},
               queued_state
             )

    assert aborted_state.public_turn_aborted?
    assert :queue.is_empty(aborted_state.queued_response_payloads)

    # The discriminating outcome. Before the fix the capability of the dropped
    # frame stayed parked and alive for the rest of the socket's life.
    assert_receive {:DOWN, ^monitor, :process, ^capability_server, :normal}, @reclaim_budget_ms

    # findings#168: gone-but-verifying is a lifecycle event, not a breach, so a
    # released capability has to be indistinguishable from a reclaimed one.
    assert WebsocketCodec.valid_prepared_frame?(queued)
    assert {:error, :invalid} = WebsocketCodec.validate_prepared_frame(queued)
  end

  test "clearing a pending owner handoff releases the capability of the frame it drops", %{
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
               {turn_frame(model), [opcode: :text]},
               aborting_socket_state(auth, session, active_turn, owner)
             )

    assert [prepared] = :queue.to_list(queued_state.queued_response_payloads)

    # The handoff parks a frame exactly as the queue does, and this is a real
    # parked frame. The record around it is assembled here because the
    # replacement-handoff preflight that builds it cannot be reached with an
    # owner that is not connected.
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

    capability_server = prepared.provenance.capability.server
    monitor = Process.monitor(capability_server)

    assert {:ok, cleared_state} =
             CodexResponsesSocket.handle_info(
               {:DOWN, handoff_state.websocket_owner_monitor, :process, owner, :shutdown},
               handoff_state
             )

    refute cleared_state.websocket_owner_pending_handoff
    assert_receive {:DOWN, ^monitor, :process, ^capability_server, :normal}, @reclaim_budget_ms
  end

  defp aborting_socket_state(auth, session, active_turn, owner) do
    %{
      auth: auth,
      opts:
        RequestOptions.for_websocket(%{
          request_id: "dropped-frame-release",
          public_openai_responses_stream: true
        }),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_pid: owner,
      websocket_owner_monitor: Process.monitor(owner),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 2,
        correlation_id: "corr-dropped-frame-release",
        active_turn_reconnect?: false
      },
      websocket_owner_active_turn_reconnect?: false,
      tasks: MapSet.new([active_turn]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: active_turn,
      public_response_stream_id: "stream-dropped-frame-release",
      public_response_start_error_ref: nil,
      public_responses_websocket_state: nil,
      public_turn_task_done?: false,
      public_turn_owner_complete?: false,
      public_turn_aborted?: false,
      public_turn_output_committed?: false,
      native_turn_output_task_pids: MapSet.new(),
      firewall_revoked?: false
    }
  end

  defp turn_frame(model) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
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
