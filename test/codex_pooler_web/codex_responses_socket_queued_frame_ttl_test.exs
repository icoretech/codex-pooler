defmodule CodexPoolerWeb.CodexResponsesSocketQueuedFrameTtlTest do
  @moduledoc """
  Findings #169: a prepared websocket frame that waits in the socket's response
  queue outlives its capability's reclaim timeout, and the re-seal at dequeue
  then fails as though the frame's signature were wrong. The queue has no bound
  shorter than that timeout and an in-flight turn routinely exceeds it — turns
  of 70 to 125 s were measured on this installation.

  The scenario starts where the request starts, a raw text frame arriving at
  `handle_in/2`, and drives the capability's timeout by delivering the exact
  message an OTP receive timeout delivers, so the real 30 s bound is exercised
  without waiting it out. The only stand-in is the external surface: the
  session's owner lives on an instance that is not connected, so the owner
  reservation fails through the real forwarder.

  The classification findings #168 established has to survive this: a frame
  whose digest still verifies but whose capability is genuinely gone stays a
  retryable `503 owner_unavailable`, and a broken digest stays a logged 500.
  """

  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountingTestSupport
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  # Failure-detection budget for a response task result under N=4.
  @detection_timeout_ms 15_000

  # Absence of a process exit; the exit itself is immediate when it happens.
  @absence_budget_ms 100

  setup do
    setup = accounting_setup()
    auth = %{pool: setup.pool, api_key: setup.api_key}

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "ttl-#{System.unique_integer([:positive])}",
               owner_instance_id: "ttl-absent-instance@127.0.0.1"
             })

    {:ok,
     auth: auth, session: Repo.get!(CodexSession, session.id), model: setup.model.exposed_model_id}
  end

  test "a queued frame survives its capability's reclaim timeout and re-seals at dequeue", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in(
               {final_compaction_frame(model), [opcode: :text]},
               queueing_socket_state(auth, session, active_turn)
             )

    assert [queued] = :queue.to_list(queued_state.queued_response_payloads)
    capability_server = queued.provenance.capability.server

    # Exactly what the 30 s process timeout does when it elapses behind an
    # in-flight turn. Before parking, the capability stopped here.
    monitor = Process.monitor(capability_server)
    send(capability_server, :timeout)
    refute_receive {:DOWN, ^monitor, :process, ^capability_server, _reason}, @absence_budget_ms

    {dequeued_state, log} =
      with_log(fn ->
        assert {:ok, dequeued_state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, active_turn, :ok},
                   queued_state
                 )

        dequeued_state
      end)

    # The dequeue re-seal consumed the capability it was waiting on, which is
    # the discriminating outcome: a capability the timeout had reclaimed answers
    # `:invalid` instead, and that is what used to refuse the turn.
    assert {:error, :consumed} = WebsocketCodec.validate_prepared_frame(queued)
    refute log =~ "prepared websocket frame reseal failed"
    refute log =~ "provenance"

    # The turn then reaches the owner, which is absent in this harness, so the
    # answer is the owner's own retryable vocabulary rather than a provenance
    # failure.
    assert :queue.is_empty(dequeued_state.queued_response_payloads)
    assert [retry_task] = MapSet.to_list(dequeued_state.tasks)
    refute retry_task == active_turn
    assert_receive {:codex_response_done, ^retry_task, result}, @detection_timeout_ms

    assert {:push, {:text, frame}, _final_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, retry_task, result},
               dequeued_state
             )

    decoded = CodexPooler.JSON.decode!(frame)
    assert decoded["status"] == 503
    assert decoded["error"]["code"] == "owner_unavailable"
  end

  test "a capability that is genuinely gone still answers a retryable 503", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in(
               {final_compaction_frame(model), [opcode: :text]},
               queueing_socket_state(auth, session, active_turn)
             )

    assert [queued] = :queue.to_list(queued_state.queued_response_payloads)

    # Parking refreshes a timer; it does not keep a capability alive through the
    # loss of the process that holds it. The digest still verifies, so this is a
    # lifecycle event and stays retryable (findings #168).
    assert :ok = GenServer.stop(queued.provenance.capability.server)
    assert WebsocketCodec.valid_prepared_frame?(queued)

    {dequeued_state, log} = with_log(fn -> drain_active_turn(queued_state, active_turn) end)

    assert log =~ "prepared websocket frame reseal failed"
    assert log =~ "stage=deferred_runtime_options"
    refute log =~ model

    assert %{"status" => 503, "error" => %{"code" => "owner_unavailable"}} =
             settle_retry_task(dequeued_state)
  end

  test "a stopped capability on a frame whose digest no longer verifies answers 500", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in(
               {final_compaction_frame(model), [opcode: :text]},
               queueing_socket_state(auth, session, active_turn)
             )

    assert [queued] = :queue.to_list(queued_state.queued_response_payloads)
    assert :ok = GenServer.stop(queued.provenance.capability.server)

    # The payload is element three of the signed basis, so a post-seal write to
    # it is a genuine invariant breach rather than a late frame.
    poisoned = %{queued | payload: Map.put(queued.payload, "temperature", 0.5)}
    refute WebsocketCodec.valid_prepared_frame?(poisoned)

    queued_state =
      Map.put(queued_state, :queued_response_payloads, :queue.from_list([poisoned]))

    {dequeued_state, log} = with_log(fn -> drain_active_turn(queued_state, active_turn) end)

    assert log =~ "prepared websocket frame reseal failed"
    refute log =~ model

    assert %{"status" => 500, "error" => %{"code" => "server_error"}} =
             settle_retry_task(dequeued_state)
  end

  defp drain_active_turn(queued_state, active_turn) do
    assert {:ok, dequeued_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, active_turn, :ok},
               queued_state
             )

    dequeued_state
  end

  defp settle_retry_task(dequeued_state) do
    assert [retry_task] = MapSet.to_list(dequeued_state.tasks)
    assert_receive {:codex_response_done, ^retry_task, result}, @detection_timeout_ms

    assert {:push, {:text, frame}, _final_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, retry_task, result},
               dequeued_state
             )

    CodexPooler.JSON.decode!(frame)
  end

  defp queueing_socket_state(auth, session, active_turn) do
    %{
      auth: auth,
      opts: RequestOptions.for_websocket(%{request_id: "queued-frame-ttl"}),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 2,
        correlation_id: "corr-queued-frame-ttl",
        active_turn_reconnect?: false
      },
      websocket_owner_active_turn_reconnect?: false,
      tasks: MapSet.new([active_turn]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: nil,
      public_response_stream_id: nil,
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

  defp final_compaction_frame(model) do
    metadata = %{
      "turn_id" => "ttl-turn-#{System.unique_integer([:positive])}",
      "request_kind" => "turn",
      "window_id" => "ttl-window",
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

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end
end
