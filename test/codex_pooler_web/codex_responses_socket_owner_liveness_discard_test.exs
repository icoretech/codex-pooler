defmodule CodexPoolerWeb.CodexResponsesSocketOwnerLivenessDiscardTest do
  @moduledoc """
  Findings #183: the two loose ends left by findings#175.

  1. `handle_public_owner_response_done/2` is the fifth site that drops the
     response queue on an abort-shaped path, and it was the only one that still
     answered nothing. It closes, so the client learns the *connection* ended —
     but a socket that multiplexes turns by `stream_id` gives the client no way
     to tell which of its submitted turns died, and a per-stream state machine
     is left holding promises no frame ever resolves. The close stays; the
     per-turn answers ride out ahead of it, exactly as
     `flush_discarded_submissions/1` already arranges for every other stop.

  2. `start_queued_response/2` keeps its raw-binary clause, and this is the
     invariant test findings#175's scope note asked for: everything that enters
     `:queued_response_payloads` through the real submission path is a
     `%PreparedWebsocketFrame{}`. If a future writer queues raw bytes, those
     entries silently go unanswered on every discard — the exact defect #175
     removed for prepared frames — and this fails instead.

  Both start where a request starts, a real text frame at `handle_in/2`, and
  abort through a real socket message. The only stand-in is the external
  surface: an owner that lives on an instance that is not connected.
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

  # A process exit that has already been decided; it is immediate when it happens.
  @reclaim_budget_ms 1_000

  @first_stream_id "liveness-discard-first"
  @second_stream_id "liveness-discard-second"
  @active_stream_id "liveness-discard-active-turn"

  setup do
    setup = accounting_setup()
    auth = %{pool: setup.pool, api_key: setup.api_key}

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "liveness-#{System.unique_integer([:positive])}",
               owner_instance_id: "liveness-absent-instance@127.0.0.1"
             })

    {:ok,
     auth: auth, session: Repo.get!(CodexSession, session.id), model: setup.model.exposed_model_id}
  end

  test "an owner-liveness close answers every queued turn it discards", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    owner = idle_process()
    on_exit(fn -> send(owner, :stop) end)

    state = liveness_socket_state(auth, session, active_turn, owner)

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

    # The real fifth drop site: the task running the open public turn settles
    # with an owner-liveness error, so the socket closes instead of finishing
    # the turn.
    assert {:stop, :normal, close_detail, frames, closed_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, active_turn,
                {:response_task_result, {:error, :owner_drained}, false}},
               queued_state
             )

    # The close the site already decided on is unchanged.
    assert close_detail == {1001, "websocket owner is draining"}

    # The discriminating outcome. Before the fix this was a four-tuple: the
    # connection ended and neither submitted turn was ever named.
    assert [{:text, first_payload}, {:text, second_payload}] = frames

    first_terminal = CodexPooler.JSON.decode!(first_payload)
    second_terminal = CodexPooler.JSON.decode!(second_payload)

    # Each answer is addressed to the stream its own client opened, never to the
    # turn that happened to be active when the discard ran.
    assert first_terminal["stream_id"] == @first_stream_id
    assert second_terminal["stream_id"] == @second_stream_id
    refute first_terminal["stream_id"] == @active_stream_id
    refute second_terminal["stream_id"] == @active_stream_id

    for terminal <- [first_terminal, second_terminal] do
      assert terminal["type"] == "error"
      assert terminal["status"] == 503
      assert terminal["error"]["code"] == "owner_drained"
      # findings#184: a lifecycle 503 is a retryable server-side class.
      assert terminal["error"]["type"] == "server_error"
    end

    # Metadata only: no prompt, no frame body, no raw identifiers.
    for payload <- [first_payload, second_payload] do
      refute payload =~ "synthetic"
      refute payload =~ session.owner_lease_token
    end

    assert :queue.is_empty(closed_state.queued_response_payloads)
    assert closed_state.public_response_task_pid == nil

    # findings#172's release still happens, alongside the answer rather than
    # instead of it.
    for {monitor, capability} <- Enum.zip(monitors, capabilities) do
      assert_receive {:DOWN, ^monitor, :process, ^capability, :normal}, @reclaim_budget_ms
    end
  end

  test "an owner-liveness close with nothing queued still closes without extra frames", %{
    auth: auth,
    session: session
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    owner = idle_process()
    on_exit(fn -> send(owner, :stop) end)

    state = liveness_socket_state(auth, session, active_turn, owner)

    # The active turn is never answered here: the owner relays that turn's own
    # terminal, and the socket must not fabricate a second one.
    assert {:stop, :normal, {1011, "websocket owner crashed"}, closed_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, active_turn,
                {:response_task_result, {:error, :owner_crashed}, true}},
               state
             )

    assert closed_state.public_response_task_pid == nil
  end

  test "only prepared frames enter the response queue through the submission path", %{
    auth: auth,
    session: session,
    model: model
  } do
    active_turn = idle_process()
    on_exit(fn -> send(active_turn, :stop) end)

    owner = idle_process()
    on_exit(fn -> send(owner, :stop) end)

    state = liveness_socket_state(auth, session, active_turn, owner)

    queued_state =
      Enum.reduce(1..3, state, fn index, acc ->
        assert {:ok, next} =
                 CodexResponsesSocket.handle_in(
                   {turn_frame(model, "liveness-invariant-#{index}"), [opcode: :text]},
                   acc
                 )

        next
      end)

    entries = :queue.to_list(queued_state.queued_response_payloads)
    assert length(entries) == 3

    # The invariant: `queue_prepared_response/2` is the only writer, so nothing
    # but a prepared frame can be waiting here. A raw entry would be dropped
    # unanswered by `discard_queued_responses/2` — it has no turn identity to
    # address — which is the silence findings#175 removed.
    for entry <- entries do
      assert %PreparedWebsocketFrame{variant: :public_response_create} = entry
      assert is_pid(entry.provenance.capability.server)
      assert Process.alive?(entry.provenance.capability.server)
    end

    assert Enum.map(entries, & &1.request_options.extra.socket_public_stream_id) == [
             "liveness-invariant-1",
             "liveness-invariant-2",
             "liveness-invariant-3"
           ]

    # Clean up the parked capabilities the submissions created.
    assert {:push, _frames, _aborted} =
             CodexResponsesSocket.handle_info(
               {:DOWN, queued_state.websocket_owner_monitor, :process, owner, :shutdown},
               queued_state
             )
  end

  defp liveness_socket_state(auth, session, active_turn, owner) do
    %{
      auth: auth,
      opts:
        RequestOptions.for_websocket(%{
          request_id: "owner-liveness-discard",
          public_openai_responses_stream: true
        }),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_pid: owner,
      websocket_owner_monitor: Process.monitor(owner),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 2,
        correlation_id: "corr-owner-liveness-discard",
        active_turn_reconnect?: false
      },
      websocket_owner_active_turn_reconnect?: false,
      tasks: MapSet.new([active_turn]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: active_turn,
      public_response_stream_id: @active_stream_id,
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
