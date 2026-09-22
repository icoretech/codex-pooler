defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.ReplayRefusalCodeTest do
  # The owner-forwarded replay preflight refuses a frame the owner cannot take.
  # When the runtime preflight matched no recorded turn (a fresh intent without
  # a predecessor lifecycle) the frame is a new turn meeting an owner that is
  # still running the previous one: it is not a duplicate, so the client gets
  # the owner's own refusal and no duplicate-turn count. A resend of the turn
  # the owner is running stays a `409 duplicate_turn` and is counted under its
  # own stage (findings#225).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag capture_log: true

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Runtime.DuplicateTurnTelemetry
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  test "a new turn meeting the busy owner gets the owner's refusal while a resend of the running turn stays a counted duplicate" do
    attach_duplicate_turn_counter!()
    release_ref = make_ref()
    upstream_boundary = terminal_blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "ws-owner-refusal-code"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-refusal-code-first", turn_state, websocket_owner_forwarder_opts: [upstream: upstream_boundary])

    first_payload = turn_payload(setup, "ws-owner-refusal-code-first", "first turn still running")

    assert {:ok, first_state} = CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    [response_task_pid] = MapSet.to_list(first_state.tasks)

    # The client lost the first socket and reconnects while the owner still runs
    # the first turn, as a released client does after an interrupt.
    {:ok, second_state} = owner_socket(auth, "ws-owner-refusal-code-second", turn_state)
    assert second_state.websocket_owner_active_turn_reconnect? == true

    try do
      new_turn = turn_payload(setup, "ws-owner-refusal-code-next", "a genuinely new turn")

      {new_result, new_log} =
        with_info_log(fn -> CodexResponsesSocket.handle_in({new_turn, [opcode: :text]}, second_state) end)

      assert {:push, {:text, new_error}, ^second_state} = new_result
      new_error = CodexPooler.JSON.decode!(new_error)
      assert new_error["status"] == 503
      assert new_error["error"]["code"] == "owner_unavailable"
      assert new_log =~ "rejection_stage=replay_preflight"
      assert new_log =~ "reason_code=owner_unavailable"
      refute new_log =~ "reconnect_disposition=identity_rejected"
      refute_received {:duplicate_turn_refused, _stage, _transport}

      {retry_result, retry_log} =
        with_info_log(fn -> CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, second_state) end)

      assert {:push, {:text, retry_error}, ^second_state} = retry_result
      retry_error = CodexPooler.JSON.decode!(retry_error)
      assert retry_error["status"] == 409
      assert retry_error["error"]["code"] == "duplicate_turn"
      assert retry_log =~ "reconnect_disposition=identity_rejected"
      assert_received {:duplicate_turn_refused, "owner_replay_preflight", "websocket"}
      refute_received {:duplicate_turn_refused, _stage, _transport}

      # Neither refusal reserved work: the running turn is the only request.
      assert length(request_logs(setup.pool.id)) == 1
    after
      {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
      Sandbox.allow(Repo, self(), owner_pid)
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})

      assert {:push, {:text, terminal_frame}, first_state} = receive_owner_socket_push(first_state)
      assert CodexPooler.JSON.decode!(terminal_frame)["type"] == "response.completed"
      assert {:ok, first_state} = receive_owner_socket_complete(first_state)
      first_state = receive_receiver_delivery_gap_result(response_task_pid, first_state)
      assert {:ok, first_state} = acknowledge_response_task_delivery_if_pending(first_state, response_task_pid)
      assert_response_task_stopped!(first_state, response_task_pid)
      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)
      assert :ok = CodexResponsesSocket.terminate(:closed, second_state)
      await_owner_cleanup!(first_state.codex_session.id)
    end
  end

  test "a new turn on a socket whose session was closed underneath it gets owner_unavailable, not a counted duplicate" do
    attach_duplicate_turn_counter!()
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-refusal-closed", "ws-owner-refusal-closed")
    session_id = state.codex_session.id

    try do
      # Another connection of the same key closed this session (an expired-lease
      # recreation or an interruption) while this socket stayed open and idle.
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      Repo.update_all(from(row in CodexSession, where: row.id == ^session_id), set: [status: "closed", closed_at: now])

      new_turn = turn_payload(setup, "ws-owner-refusal-closed-next", "a genuinely new turn")

      {result, log} = with_info_log(fn -> CodexResponsesSocket.handle_in({new_turn, [opcode: :text]}, state) end)

      assert {:push, {:text, error_frame}, _state} = result
      error_frame = CodexPooler.JSON.decode!(error_frame)
      assert error_frame["status"] == 503
      assert error_frame["error"]["code"] == "owner_unavailable"
      assert log =~ "stage=runtime_replay_preflight reason_code=session_not_reconnectable"
      refute log =~ "reconnect_disposition=identity_rejected"
      refute_received {:duplicate_turn_refused, _stage, _transport}
      assert request_logs(setup.pool.id) == []
      assert FakeUpstream.count(upstream) == 0
    after
      assert :ok = CodexResponsesSocket.terminate(:closed, state)
      await_owner_cleanup!(session_id)
    end
  end

  defp attach_duplicate_turn_counter! do
    test_pid = self()
    handler_id = "owner-replay-refusal-code-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        DuplicateTurnTelemetry.event(),
        fn _event, %{count: 1}, metadata, _config -> send(test_pid, {:duplicate_turn_refused, metadata.stage, metadata.transport}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp turn_payload(setup, turn_id, content) do
    websocket_payload(setup, content, %{
      "request_id" => turn_id,
      "client_metadata" => %{
        "turn_id" => turn_id,
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"turn_id" => turn_id, "request_kind" => "turn"})
      }
    })
  end

  defp terminal_blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false, closed?: false} end) end,
      send: fn upstream_pid, request, writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:blocking_owner_upstream_received, self(), release_ref})

        receive do
          {:blocking_owner_upstream_release, ^release_ref} ->
            frame =
              CodexPooler.JSON.encode!(%{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_owner_refusal_code",
                  "status" => "completed",
                  "output" => [],
                  "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
                }
              })

            decoded = CodexPooler.JSON.decode!(frame)

            cond do
              is_function(request.frame_observer, 2) -> request.frame_observer.(frame, decoded)
              is_function(request.frame_observer, 1) -> request.frame_observer.(frame)
              true -> :ok
            end

            writer.(frame, TerminalDiscriminator.classify(frame))
            :ok
        after
          5_000 -> exit(:blocking_owner_upstream_timeout)
        end
      end,
      close: fn upstream_pid ->
        Agent.update(upstream_pid, fn state -> %{state | closed?: true} end)
        Agent.stop(upstream_pid)
      end
    }
  end
end
