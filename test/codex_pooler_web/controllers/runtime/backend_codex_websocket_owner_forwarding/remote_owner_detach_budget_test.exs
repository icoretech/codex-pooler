defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.RemoteOwnerDetachBudgetTest do
  @moduledoc """
  A remote owner's detach of a pre-visible downstream arms the turn's replay in
  a database transaction on the owner node. The caller must wait for it as
  long as a local detach does (the owner's own call budget): an arm that
  outlasted the old one-second remote budget left the closing socket reading
  `owner_forward_timeout`, and its owner-lost recovery interrupted the turn
  `owner_unavailable` under the arm: the arm failed and the client's resend
  had no replay to redeem (findings#206 row 206-212).
  """

  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

  @handoff_detection_timeout_ms 15_000
  # Longer than the one-second budget remote detaches used to have, and far
  # shorter than the owner's own call budget; the arm itself is injected at
  # the owner's replay suspender, the boundary that runs the database arm.
  @slow_arm_ms 1_200

  defmodule TimedRemoteNodeClient do
    @moduledoc false
    # Runs every remote owner call through the production erpc client against
    # the local node, so the caller's timeout is enforced exactly as it is
    # between two nodes (`{:erpc, :timeout}` once it expires).
    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.ERPCNodeClient
    alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

    @impl true
    defdelegate connected_app_nodes, to: ReplayRemoteNodeClient

    @impl true
    defdelegate app_node?(node), to: ReplayRemoteNodeClient

    @impl true
    def call_owner(remote_node, module, function, args, timeout) do
      send(:persistent_term.get({ReplayRemoteNodeClient, :state}).notify, {:timed_remote_owner_call, remote_node, function, timeout})
      ERPCNodeClient.call_owner(node(), module, function, args, timeout)
    end
  end

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  test "the closing socket waits out a remote owner's slow replay arm, so its resend redeems the replay" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: the first send is held pre-visibly until the
        # owner has armed the replay, then its connection closes without a
        # terminal; the replay is the only other send.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}],
            respond:
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: release_ref,
                code: 1001,
                reason: "synthetic slow remote arm disconnect"
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_slow_remote_arm_complete",
                    "status" => "completed",
                    "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
                  }
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = Ecto.UUID.generate()
    {:ok, state} = owner_socket(auth, "ws-slow-remote-arm", turn_state)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@slow-remote-arm.example"
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

    node_client_options = [node_client: TimedRemoteNodeClient]
    remote_state = state |> remote_owner_state(remote_node, node_client_options) |> Map.put(:codex_session, session)
    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [%{"type" => "function_call_output", "call_id" => "call_slow_remote_arm", "output" => "synthetic slow remote arm output"}],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "slow-remote-arm-turn", "request_kind" => "turn"})
          }
        }
      )

    assert {:ok, remote_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, remote_state)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @handoff_detection_timeout_ms
    assert %{active_turn: %{descriptor: %{replay_generation: 0}}} = :sys.get_state(owner_pid)

    :sys.replace_state(owner_pid, fn owner_state ->
      arm = owner_state.callbacks.replay_suspender

      slow_arm = fn input ->
        Process.sleep(@slow_arm_ms)
        arm.(input)
      end

      %{owner_state | callbacks: %{owner_state.callbacks | replay_suspender: slow_arm}}
    end)

    # The socket holds the owner's cleanup witness for its turn, which is what
    # lets its owner-lost recovery interrupt that turn.
    assert_receive {:websocket_owner_cleanup_witness, _correlation, _epoch, _task, _witness} = witness_message, @handoff_detection_timeout_ms
    assert {:ok, remote_state} = CodexResponsesSocket.handle_info(witness_message, remote_state)

    # The closing socket's ordinary owner detach, as its deferred cleanup runs it.
    assert :ok = Adapter.cleanup_owner_session(remote_state, :closed)

    assert %{active_turn: nil, suspended_replay: %{provisional_status: :armed}} = :sys.get_state(owner_pid)

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:ok, remote_state} = receive_socket_done(remote_state)

    assert [%Request{status: "in_progress", last_error_code: nil} = request] = request_logs(setup.pool.id)
    assert [%Attempt{replay_generation: 0, status: "retryable_failed"}] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert %RequestReplayEntitlement{status: "armed", closed_at: nil} = Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    # The remote detach had the owner's own call budget, not the one-second
    # downstream send budget.
    assert_receive {:timed_remote_owner_call, ^remote_node, :remote_cancel_downstream, detach_timeout_ms}
    assert detach_timeout_ms == WebsocketOwnerContract.default_owner_call_timeout_ms()

    {:ok, replay_state} = owner_socket(auth, "ws-slow-remote-arm-retry", turn_state, websocket_owner_forwarder_opts: node_client_options)
    assert {:ok, replay_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, replay_state)
    assert {:push, {:text, replay_frame}, replay_state} = receive_owner_socket_push(replay_state)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(replay_frame)
    assert {:ok, replay_state} = receive_owner_socket_complete(replay_state)
    assert {:ok, replay_state} = receive_socket_done(replay_state)

    assert [%Attempt{replay_generation: 0}, %Attempt{replay_generation: 1, status: "succeeded"}] =
             Repo.all(from(a in Attempt, where: a.request_id == ^request.id, order_by: [asc: a.attempt_number]))

    assert %RequestReplayEntitlement{status: "consumed"} = Repo.get_by!(RequestReplayEntitlement, request_id: request.id)
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, replay_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
  end
end
