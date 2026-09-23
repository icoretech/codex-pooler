defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.RemoteSubmitRequestTimeoutTest do
  @moduledoc """
  A native turn reaches a remote owner through
  `WebsocketOwnerForwarder.submit_request/5` under the full-turn budget. When
  that budget expires, the client is told the turn failed, but the owner-node
  process that carries the submission outlives the abandoned erpc reply: the
  owner still takes the queued turn. The forwarder then has to stop that turn,
  or its output would reach a client that already received the turn's error.
  It used to do so with the best-effort detach a closing socket sends, which
  the owner applied behind the queued turn: the turn stopped, but the still
  connected socket also lost its downstream at the owner, and every later turn
  on it was refused `409 stale_owner` until the client reconnected (findings#206
  row 206-299, the turn-submission variant of row 206-276).
  """

  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

  @detection_timeout_ms 15_000

  defmodule ShortTurnBudgetNodeClient do
    @moduledoc false
    # Every remote owner call runs through the production erpc client against
    # the local node, so an expired budget is `{:erpc, :timeout}` exactly as
    # between two nodes. Once armed with an owner, the next turn submission
    # suspends that owner right before it is sent (after the turn's pre-attempt
    # admission, which is an owner call too) and gets a short budget; the owner
    # is held suspended past it, so its length decides nothing but test time.
    # Every other call keeps the budget the forwarder chose.
    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.ERPCNodeClient
    alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

    @turn_budget_ms 200

    # Application env, not `:persistent_term`: erasing a persistent term waits
    # for a global literal collection, which holds the calling response task
    # while the owner is suspended.
    def arm(owner_pid) when is_pid(owner_pid), do: put_config(:armed_owner, owner_pid)
    def disarm, do: put_config(:armed_owner, nil)

    # Emulates an owner node still running the previous release, which has no
    # `remote_abandon_turn_v1/2`, the way erpc reports a missing function.
    def emulate_old_release, do: put_config(:old_release?, true)

    def reset, do: Application.delete_env(:codex_pooler, __MODULE__)

    defp put_config(key, value), do: Application.put_env(:codex_pooler, __MODULE__, Map.put(config(), key, value))
    defp config, do: Application.get_env(:codex_pooler, __MODULE__, %{armed_owner: nil, old_release?: false})

    @impl true
    defdelegate connected_app_nodes, to: ReplayRemoteNodeClient

    @impl true
    defdelegate app_node?(node), to: ReplayRemoteNodeClient

    @impl true
    def call_owner(remote_node, module, function, args, timeout) do
      notify = :persistent_term.get({ReplayRemoteNodeClient, :state}).notify

      budget =
        case {function, config().armed_owner} do
          {:remote_submit_request_v1, owner_pid} when is_pid(owner_pid) ->
            disarm()
            :ok = :sys.suspend(owner_pid)
            send(notify, {:short_turn_owner_suspended, owner_pid})
            @turn_budget_ms

          _other ->
            timeout
        end

      send(notify, {:short_turn_remote_call, remote_node, function, budget})

      result =
        if function == :remote_abandon_turn_v1 and config().old_release?,
          do: {:error, {:exception, :undef, [{module, function, args, []}]}},
          else: ERPCNodeClient.call_owner(node(), module, function, args, budget)

      send(notify, {:short_turn_remote_result, remote_node, function, result})
      result
    end
  end

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      ShortTurnBudgetNodeClient.reset()
      cleanup_local_owner_sessions()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  test "a turn the remote owner takes after its forward budget is stopped without detaching the connected socket" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached} = remote_socket_after_first_turn()
    {pushes, second_task, state} = time_out_second_turn(setup, state, owner_pid, remote_node)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)

    # Ordered behind every call the stalled owner had queued: the socket that
    # is still connected keeps its downstream, and the timed-out turn is
    # stopped rather than left to stream to a client that got its error.
    assert %{downstream: ^attached, active_turn: second_turn} = :sys.get_state(owner_pid)
    await_turn_settled(owner_pid, second_turn)
    assert %{downstream: ^attached, active_turn: nil} = :sys.get_state(owner_pid)
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^second_task, _payload}

    # The owner took the queued turn first and then stopped exactly that turn.
    assert_received {:short_turn_remote_result, ^remote_node, :remote_submit_request_v1, {:error, :owner_forward_timeout}}
    assert_received {:short_turn_remote_result, ^remote_node, :remote_abandon_turn_v1, :ok}
    refute_received {:short_turn_remote_call, ^remote_node, :remote_cancel_downstream_v1, _budget}

    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote turn timeout third"), [opcode: :text]}, state)
    {pushes, _third_task, state} = drive_until_done(state)
    assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_turn_timeout"))
    refute Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["type"] == "error"))

    # The other direction: the kept downstream is still watched, and a socket
    # that really goes away is detached.
    assert {:monitors, monitors} = Process.info(owner_pid, :monitors)
    assert {:process, attached.pid} in monitors
    terminate_and_await_cleanup(state)
    assert %{downstream: nil} = :sys.get_state(owner_pid)
  end

  # During a rolling deploy the owner node can predate the call: the forwarder
  # then sends the detach it always sent, which still stops the turn (and, as
  # before, leaves the socket to reconnect).
  test "an owner node without the turn abandon still gets the detach after a turn forward timeout" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node} = remote_socket_after_first_turn()
    ShortTurnBudgetNodeClient.emulate_old_release()
    {pushes, second_task, _state} = time_out_second_turn(setup, state, owner_pid, remote_node)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)

    assert_received {:short_turn_remote_call, ^remote_node, :remote_abandon_turn_v1, 1_000}
    assert_received {:short_turn_remote_result, ^remote_node, :remote_cancel_downstream_v1, :ok}
    assert %{downstream: nil, active_turn: second_turn} = :sys.get_state(owner_pid)
    await_turn_settled(owner_pid, second_turn)
    assert %{downstream: nil, active_turn: nil} = :sys.get_state(owner_pid)
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^second_task, _payload}
  end

  defp remote_socket_after_first_turn do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_remote_turn_timeout",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-remote-turn-timeout", Ecto.UUID.generate())
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-turn-timeout.example"
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
    state = state |> remote_owner_state(remote_node, node_client: ShortTurnBudgetNodeClient) |> Map.put(:codex_session, session)

    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote turn timeout first"), [opcode: :text]}, state)
    {pushes, _first_task, state} = drive_until_done(state)
    assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_turn_timeout"))
    attached = :sys.get_state(owner_pid).downstream
    assert %{pid: socket_pid} = attached
    assert socket_pid == self()
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached}
  end

  # The owner stalls past the second turn's forward budget. Both the
  # submission and whatever the forwarder sends after the timeout wait in its
  # mailbox, in that order, before it runs again.
  defp time_out_second_turn(setup, state, owner_pid, remote_node) do
    ShortTurnBudgetNodeClient.arm(owner_pid)
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote turn timeout second"), [opcode: :text]}, state)
    assert_receive {:short_turn_owner_suspended, ^owner_pid}, @detection_timeout_ms

    try do
      assert_receive {:short_turn_remote_call, ^remote_node, :remote_submit_request_v1, 200}, @detection_timeout_ms
      await_queued_messages(owner_pid, 2)
    after
      :ok = :sys.resume(owner_pid)
    end

    drive_until_done(state)
  end

  # Waits until `count` messages wait in the suspended owner's mailbox: the
  # submission, sent before its budget expired, and the call the forwarder
  # sends once it did. The owner is suspended, so its queue only grows; the
  # erpc processes that carry the calls are the producers being waited on.
  # (`:messages` is not used: on this runtime it reads empty for this owner
  # while `:message_queue_len` counts the queued calls.)
  defp await_queued_messages(owner_pid, count) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_queued_messages(owner_pid, count, deadline)
  end

  defp await_queued_messages(owner_pid, count, deadline) do
    {:message_queue_len, queued} = Process.info(owner_pid, :message_queue_len)

    cond do
      queued >= count ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{count} messages queued at the suspended owner, saw #{queued}")

      true ->
        Process.sleep(5)
        await_queued_messages(owner_pid, count, deadline)
    end
  end

  defp await_turn_settled(_owner_pid, nil), do: :ok

  defp await_turn_settled(owner_pid, %{task_pid: task_pid}) do
    monitor = Process.monitor(task_pid)
    assert_receive {:DOWN, ^monitor, :process, ^task_pid, _reason}, @detection_timeout_ms
    # The owner handles the task's own exit before this later call.
    _state = :sys.get_state(owner_pid)
    :ok
  end

  defp terminate_and_await_cleanup(state) do
    parent = self()
    id = make_ref()

    :telemetry.attach(
      id,
      [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
      fn _, _, metadata, _ ->
        if metadata.caller == parent, do: send(parent, {:cleanup_finished, id})
      end,
      nil
    )

    try do
      assert :ok = CodexResponsesSocket.terminate(:closed, state)
      assert_receive {:cleanup_finished, ^id}, @detection_timeout_ms
    after
      :telemetry.detach(id)
    end
  end

  # Feeds the socket the messages a WebSock loop would, collecting pushed
  # text frames, until the response task's result and its scheduled delivery
  # completion have been handled. Returns the response task too.
  defp drive_until_done(state, pushes \\ []) do
    receive do
      {:codex_response_done, pid, _result} = message ->
        {pushes, state} = apply_socket_message(message, state, pushes)
        {pushes, state} = finish_delivery(state, pushes, pid)
        {pushes, pid, state}

      message
      when is_tuple(message) and
             elem(message, 0) in [
               :websocket_owner_frame,
               :websocket_owner_cleanup_witness,
               :websocket_owner_output_commit_probe,
               :websocket_response_activity,
               :direct_request_cleanup
             ] ->
        {pushes, state} = apply_socket_message(message, state, pushes)
        drive_until_done(state, pushes)
    after
      @detection_timeout_ms -> flunk("expected the websocket response task to finish")
    end
  end

  defp finish_delivery(state, pushes, pid) do
    receive do
      {:websocket_response_delivery_complete, ^pid, _token} = message -> apply_socket_message(message, state, pushes)
    after
      @detection_timeout_ms -> flunk("expected the scheduled delivery completion")
    end
  end

  defp apply_socket_message(message, state, pushes) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:ok, state} -> {pushes, state}
      {:push, {:text, frame}, state} -> {pushes ++ [frame], state}
      other -> flunk("the socket stopped: #{inspect(elem(other, 0))}")
    end
  end
end
