defmodule CodexPoolerWeb.CodexResponsesSocketPreparedFrameProvenanceTest do
  @moduledoc """
  Findings #168: the socket seals a prepared websocket frame, then writes
  `native_compaction_reservation` into its request options to remember that the
  owner refused the compaction reservation and it should be retried once the
  active turn drains. The owner-forwarded active-turn-reconnect route
  dispatches that frame without unwinding the deferral, so the write has to be
  invisible to the frame's own signature; while the field was part of the
  signed basis the frame stopped verifying and the client was told
  `400 invalid_request / prepared websocket frame provenance is invalid` for a
  server bookkeeping fault, with no log line at any of the three emit sites.

  The scenario starts where the request starts — a raw text frame arriving at
  `handle_in/2` — and asserts on the frame pushed back to the client. The only
  stand-ins are the external surfaces: the session's owner lives on an instance
  that is not connected, which is what makes the reservation fail with
  `owner_unavailable` through the real forwarder.
  """

  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountingTestSupport
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  # Failure-detection budget for a response task result under N=4.
  @detection_timeout_ms 15_000

  setup do
    setup = accounting_setup()
    auth = %{pool: setup.pool, api_key: setup.api_key}

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "provenance-#{System.unique_integer([:positive])}",
               owner_instance_id: "provenance-absent-instance@127.0.0.1"
             })

    {:ok,
     auth: auth, session: Repo.get!(CodexSession, session.id), model: setup.model.exposed_model_id}
  end

  test "a deferred compaction reservation on the reconnect route answers owner_unavailable, not a client 400",
       %{auth: auth, session: session, model: model} do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    state = reconnect_socket_state(auth, session, active_turn)

    assert {:push, {:text, frame}, settled_state} =
             CodexResponsesSocket.handle_in(
               {final_compaction_frame(model), [opcode: :text]},
               state
             )

    decoded = CodexPooler.JSON.decode!(frame)

    # The honest answer for "the owner could not admit the reservation and this
    # route cannot queue the frame": the retryable owner vocabulary that
    # `start_deferred_or_tracked_response/2`'s own failure branch already
    # returns. Before the fix this was `400 invalid_request` with
    # "prepared websocket frame provenance is invalid".
    assert decoded["status"] == 503
    assert decoded["error"]["code"] == "owner_unavailable"
    refute decoded["error"]["message"] =~ "provenance"

    # The frame is refused before any response work starts.
    assert settled_state.tasks == MapSet.new([active_turn])
    assert :queue.is_empty(settled_state.queued_response_payloads)
  end

  test "the queue route unwinds the deferral, re-seals, and reports the owner failure once", %{
    auth: auth,
    session: session,
    model: model
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
    assert {:ok, dequeued_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, active_turn, :ok},
               queued_state
             )

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
    model: model
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

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end
end
