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

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.AbandonedSubmissions
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

    # The switch lives in the application env and is read by the response
    # task that sends the submission.
    def arm(owner_pid, function \\ :remote_submit_request_v1) when is_pid(owner_pid) do
      put_config(:armed_function, function)
      put_config(:armed_owner, owner_pid)
    end

    def disarm, do: put_config(:armed_owner, nil)

    # Emulates an owner node still running the previous release, which has no
    # `remote_abandon_turn_v1/2`, the way erpc reports a missing function.
    def emulate_old_release, do: put_config(:old_release?, true)

    def reset, do: Application.delete_env(:codex_pooler, __MODULE__)

    defp put_config(key, value), do: Application.put_env(:codex_pooler, __MODULE__, Map.put(config(), key, value))
    defp config, do: Application.get_env(:codex_pooler, __MODULE__, %{armed_owner: nil, armed_function: nil, old_release?: false})

    @impl true
    defdelegate connected_app_nodes, to: ReplayRemoteNodeClient

    @impl true
    defdelegate app_node?(node), to: ReplayRemoteNodeClient

    @impl true
    def call_owner(remote_node, module, function, args, timeout) do
      notify = :persistent_term.get({ReplayRemoteNodeClient, :state}).notify

      armed_function = config().armed_function

      budget =
        case {function, config().armed_owner} do
          {^armed_function, owner_pid} when is_pid(owner_pid) ->
            disarm()
            :ok = :sys.suspend(owner_pid)
            send(notify, {:short_turn_owner_suspended, owner_pid})
            @turn_budget_ms

          _other ->
            timeout
        end

      send(notify, {:short_turn_remote_call, remote_node, function, budget})
      if function == :remote_cancel_downstream_v1, do: send(notify, {:short_turn_remote_cancel_reason, remote_node, List.last(args)})

      result =
        if function == :remote_abandon_turn_v1 and config().old_release?,
          do: {:error, {:exception, :undef, [{module, function, args, []}]}},
          else: ERPCNodeClient.call_owner(node(), module, function, args, budget)

      send(notify, {:short_turn_remote_result, remote_node, function, result})
      result
    end
  end

  defmodule LateSubmissionNodeClient do
    @moduledoc false
    # Every remote owner call runs through the production erpc client against
    # the local node. Once armed, the next turn submission reaches the owner
    # only when the test says so: the proxy gets its budget's timeout at once,
    # and the owner-node process carrying the submission is held before its
    # owner call, as one still recovering the owner would be. The abandon the
    # forwarder then sends reaches the owner first.
    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.ERPCNodeClient
    alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

    def arm, do: Application.put_env(:codex_pooler, __MODULE__, :armed)

    # An owner node without `remote_abandon_turn_v1/2`, as erpc reports it.
    def emulate_old_release, do: Application.put_env(:codex_pooler, Module.concat(__MODULE__, OldRelease), true)

    def reset do
      Application.delete_env(:codex_pooler, __MODULE__)
      Application.delete_env(:codex_pooler, Module.concat(__MODULE__, OldRelease))
    end

    @impl true
    defdelegate connected_app_nodes, to: ReplayRemoteNodeClient

    @impl true
    defdelegate app_node?(node), to: ReplayRemoteNodeClient

    @impl true
    def call_owner(remote_node, module, :remote_submit_request_v1 = function, args, timeout) do
      notify = :persistent_term.get({ReplayRemoteNodeClient, :state}).notify

      if Application.get_env(:codex_pooler, __MODULE__) == :armed do
        Application.delete_env(:codex_pooler, __MODULE__)

        late =
          spawn(fn ->
            receive do
              :reach_owner -> send(notify, {:late_submission_result, ERPCNodeClient.call_owner(node(), module, function, args, timeout)})
            end
          end)

        send(notify, {:late_submission_held, late})
        {:error, :owner_forward_timeout}
      else
        forward(notify, remote_node, module, function, args, timeout)
      end
    end

    def call_owner(remote_node, module, :remote_abandon_turn_v1 = function, args, timeout) do
      notify = :persistent_term.get({ReplayRemoteNodeClient, :state}).notify

      if Application.get_env(:codex_pooler, Module.concat(__MODULE__, OldRelease)) do
        result = {:error, {:exception, :undef, [{module, function, args, []}]}}
        send(notify, {:late_client_result, remote_node, function, result})
        result
      else
        forward(notify, remote_node, module, function, args, timeout)
      end
    end

    def call_owner(remote_node, module, function, args, timeout),
      do: forward(:persistent_term.get({ReplayRemoteNodeClient, :state}).notify, remote_node, module, function, args, timeout)

    defp forward(notify, remote_node, module, function, args, timeout) do
      result = ERPCNodeClient.call_owner(node(), module, function, args, timeout)
      if function == :remote_cancel_downstream_v1, do: send(notify, {:late_client_cancel_reason, remote_node, List.last(args)})
      send(notify, {:late_client_result, remote_node, function, result})
      result
    end
  end

  defmodule OwnerGoneNodeClient do
    @moduledoc false
    # Every remote owner call runs through the production erpc client against
    # the local node. Once armed with an owner, the next turn submission finds
    # that owner gone: it is stopped before the submission and its abandon
    # reach the node, the proxy gets its budget's timeout at once, and the
    # owner-node process carrying the submission is held until the test
    # releases it, as one still starting or recovering the owner would be.
    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.ERPCNodeClient
    alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

    def arm(owner_pid) when is_pid(owner_pid), do: Application.put_env(:codex_pooler, __MODULE__, owner_pid)
    def reset, do: Application.delete_env(:codex_pooler, __MODULE__)

    @impl true
    defdelegate connected_app_nodes, to: ReplayRemoteNodeClient

    @impl true
    defdelegate app_node?(node), to: ReplayRemoteNodeClient

    @impl true
    def call_owner(remote_node, module, :remote_submit_request_v1 = function, args, timeout) do
      notify = :persistent_term.get({ReplayRemoteNodeClient, :state}).notify

      case Application.get_env(:codex_pooler, __MODULE__) do
        owner_pid when is_pid(owner_pid) ->
          reset()
          monitor = Process.monitor(owner_pid)
          Process.exit(owner_pid, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^owner_pid, _reason} -> :ok
          end

          late =
            spawn(fn ->
              receive do
                :reach_owner -> send(notify, {:owner_gone_late_result, ERPCNodeClient.call_owner(node(), module, function, args, timeout)})
              end
            end)

          send(notify, {:owner_gone_late_held, late})
          {:error, :owner_forward_timeout}

        _unarmed ->
          forward(notify, remote_node, module, function, args, timeout)
      end
    end

    def call_owner(remote_node, module, function, args, timeout),
      do: forward(:persistent_term.get({ReplayRemoteNodeClient, :state}).notify, remote_node, module, function, args, timeout)

    defp forward(notify, remote_node, module, function, args, timeout) do
      result = ERPCNodeClient.call_owner(node(), module, function, args, timeout)
      send(notify, {:owner_gone_client_result, remote_node, function, result})
      result
    end
  end

  defmodule OwnerDiesUnderAbandonNodeClient do
    @moduledoc false
    # Every remote owner call runs through the production erpc client against
    # the local node. Once armed with an owner, the next turn submission gets
    # its budget's timeout at once, and the owner-node process carrying it is
    # held before its owner call. The owner is held too, inside a state
    # replacement that waits for the forwarder's abandon to reach its mailbox,
    # reports it, and never returns: the test kills the owner there, with the
    # abandon's call in flight.
    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.ERPCNodeClient
    alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

    def arm(owner_pid) when is_pid(owner_pid), do: Application.put_env(:codex_pooler, __MODULE__, owner_pid)
    def reset, do: Application.delete_env(:codex_pooler, __MODULE__)

    @impl true
    defdelegate connected_app_nodes, to: ReplayRemoteNodeClient

    @impl true
    defdelegate app_node?(node), to: ReplayRemoteNodeClient

    @impl true
    def call_owner(remote_node, module, :remote_submit_request_v1 = function, args, timeout) do
      notify = :persistent_term.get({ReplayRemoteNodeClient, :state}).notify

      case Application.get_env(:codex_pooler, __MODULE__) do
        owner_pid when is_pid(owner_pid) ->
          reset()
          hold_owner_until_abandon(owner_pid, notify)

          late =
            spawn(fn ->
              receive do
                :reach_owner -> send(notify, {:dying_owner_late_result, ERPCNodeClient.call_owner(node(), module, function, args, timeout)})
              end
            end)

          send(notify, {:dying_owner_late_held, late})
          {:error, :owner_forward_timeout}

        _unarmed ->
          forward(notify, remote_node, module, function, args, timeout)
      end
    end

    def call_owner(remote_node, module, function, args, timeout),
      do: forward(:persistent_term.get({ReplayRemoteNodeClient, :state}).notify, remote_node, module, function, args, timeout)

    defp forward(notify, remote_node, module, function, args, timeout) do
      result = ERPCNodeClient.call_owner(node(), module, function, args, timeout)
      send(notify, {:dying_owner_client_result, remote_node, function, result})
      result
    end

    # Returns once the owner runs the replacement, so the abandon sent after
    # the timeout below queues behind it.
    defp hold_owner_until_abandon(owner_pid, notify) do
      client = self()
      ref = make_ref()

      hold = fn owner_state ->
        send(client, {ref, :owner_held})

        receive do
          {:"$gen_call", _from, {:abandon_turn, _pid, _epoch, _correlation, _turn}} -> send(notify, {:dying_owner_abandon_in_mailbox, self()})
        end

        receive do
          :never -> owner_state
        end
      end

      spawn(fn -> :sys.replace_state(owner_pid, hold, :infinity) end)

      receive do
        {^ref, :owner_held} -> :ok
      end
    end
  end

  defmodule LookupPause do
    @moduledoc false
    # Holds one process at a boundary it already crosses, chosen by the
    # function on its stack: the owner lookup miss the abandon logs between its
    # two lookups (an `:logger` handler runs in the logging process). The test
    # is told which process waits and releases it; no timer decides the order.
    def arm(test_pid, codex_session_id, stack_function) do
      claimed = :atomics.new(1, [])
      Logger.put_module_level(CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Logger, :info)

      :ok =
        :logger.add_handler(__MODULE__, __MODULE__, %{
          level: :info,
          config: %{test_pid: test_pid, needle: "websocket owner lookup missed codex_session_id=#{codex_session_id}", stack_function: stack_function, claimed: claimed}
        })
    end

    def disarm do
      _result = :logger.remove_handler(__MODULE__)
      Logger.delete_module_level(CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Logger)
      :ok
    end

    def log(%{msg: {:string, chardata}}, %{config: config}) do
      with true <- self() != config.test_pid,
           true <- String.contains?(IO.chardata_to_string(chardata), config.needle),
           stack_function = config.stack_function,
           {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace),
           true <- Enum.any?(stack, &match?({_module, ^stack_function, _arity, _location}, &1)),
           :ok <- :atomics.compare_exchange(config.claimed, 1, 0, 1) do
        send(config.test_pid, {:lookup_paused, self()})

        # The bound only frees a held process when a failing test never
        # resumes it; the green path resumes it on a message.
        receive do
          :resume_lookup -> :ok
        after
          15_000 -> :ok
        end
      end

      :ok
    end

    def log(_event, _config), do: :ok
  end

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      ShortTurnBudgetNodeClient.reset()
      LateSubmissionNodeClient.reset()
      OwnerGoneNodeClient.reset()
      OwnerDiesUnderAbandonNodeClient.reset()
      LookupPause.disarm()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  # Nothing on the timeout path reads the serving mode; both modes run to show it.
  for mode <- ["full", "lite"] do
    test "a turn the remote owner takes after its forward budget is stopped without detaching the connected socket (#{mode})" do
      %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached, upstream: upstream} = remote_socket_after_first_turn(unquote(mode))
      assert_served_in_mode!(upstream, unquote(mode))
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
  end

  # The abandon can reach the owner before the submission it abandons, when
  # the owner-node process carrying the submission is still before its owner
  # call as the budget expires. The abandon then finds no turn to stop, and the
  # owner refuses that exact submission when it arrives instead of sending it
  # upstream for a client that already got its error (findings#206 row
  # 206-307). The next turn on the same socket is served.
  test "a timed-out turn submission that reaches the owner after its abandon is refused before dispatch" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached, upstream: upstream} = remote_socket_after_first_turn("full")
    state = remote_owner_state(state, remote_node, node_client: LateSubmissionNodeClient)
    upstream_requests = FakeUpstream.count(upstream)

    LateSubmissionNodeClient.arm()
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "late submission second"), [opcode: :text]}, state)
    assert_receive {:late_submission_held, late}, @detection_timeout_ms
    {pushes, late_task, state} = drive_until_done(state)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)
    assert_received {:late_client_result, ^remote_node, :remote_abandon_turn_v1, {:error, :stale_downstream}}

    send(late, :reach_owner)
    assert_receive {:late_submission_result, {:error, :stale_downstream}}, @detection_timeout_ms
    # Ordered behind the refused submission.
    assert %{downstream: ^attached, active_turn: nil, abandoned_submissions: []} = :sys.get_state(owner_pid)
    assert FakeUpstream.count(upstream) == upstream_requests
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^late_task, _payload}

    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "late submission third"), [opcode: :text]}, state)
    {pushes, _third_task, state} = drive_until_done(state)
    assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_turn_timeout"))
    refute Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["type"] == "error"))
    assert FakeUpstream.count(upstream) == upstream_requests + 1
    terminate_and_await_cleanup(state)
  end

  # During a rolling deploy the owner node can predate the call: the forwarder
  # then sends the per-call cancel every such release has, which stops exactly
  # the timed-out turn (and, as the detach did before, clears the downstream,
  # so the socket reconnects for its next turn). No detach follows it.
  test "an owner node without the turn abandon gets the per-call cancel after a turn forward timeout" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, auth: auth, turn_state: turn_state} = remote_socket_after_first_turn("full")
    ShortTurnBudgetNodeClient.emulate_old_release()
    {pushes, second_task, state} = time_out_second_turn(setup, state, owner_pid, remote_node)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)

    assert_received {:short_turn_remote_call, ^remote_node, :remote_abandon_turn_v1, 1_000}
    assert_received {:short_turn_remote_cancel_reason, ^remote_node, :owner_drained}
    assert_received {:short_turn_remote_result, ^remote_node, :remote_cancel_downstream_v1, :ok}
    refute_received {:short_turn_remote_cancel_reason, ^remote_node, :client_disconnected}
    assert %{downstream: nil, active_turn: second_turn} = :sys.get_state(owner_pid)
    await_turn_settled(owner_pid, second_turn)
    assert %{downstream: nil, active_turn: nil} = :sys.get_state(owner_pid)
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^second_task, _payload}

    # Only while an owner node predates the abandon (findings#206 row
    # 206-337, a decision): the cancel cleared the socket's downstream, so its
    # next turn is refused `409 stale_owner`, which the released client answers
    # by reconnecting, and the reconnected socket is served.
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote turn timeout third"), [opcode: :text]}, state)
    {pushes, _third_task, state} = drive_until_done(state)
    assert [%{"type" => "error", "status" => 409, "error" => %{"code" => "stale_owner"}}] = Enum.map(pushes, &CodexPooler.JSON.decode!/1)
    terminate_and_await_cleanup(state)

    {:ok, reconnected} = owner_socket(auth, "ws-remote-turn-timeout-reconnect", turn_state, websocket_owner_forwarder_opts: [node_client: ShortTurnBudgetNodeClient])
    assert {:ok, reconnected} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote turn timeout after reconnect"), [opcode: :text]}, reconnected)
    {pushes, _task, reconnected} = drive_until_done(reconnected)
    assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_turn_timeout"))
    refute Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["type"] == "error"))
    terminate_and_await_cleanup(reconnected)
  end

  # The released client's turns can be replayed, and one that timed out before
  # its first output is still pre-visible when the owner takes it. The
  # closing-socket detach an owner node without the abandon used to get armed
  # that turn's pre-visible replay for a client that was still connected: the
  # timed-out task's failure settlement then met a newer replay generation, the
  # task ended as a success with no error frame, its delivery never completed,
  # and the request stayed in progress behind the armed replay (findings#206
  # row 206-315; first seen on the client-retry submission, the same for every
  # submission version). The per-call cancel stops the turn without a replay.
  for submit_function <- [:remote_submit_request_v1, :remote_submit_request_v5] do
    test "an owner node without the turn abandon stops a released-client turn after its forward timeout and the client gets the error (#{submit_function})" do
      %{state: state, owner_pid: owner_pid, remote_node: remote_node, frame: frame} = released_client_socket(unquote(submit_function))
      ShortTurnBudgetNodeClient.emulate_old_release()
      {pushes, task, _state} = time_out_turn(frame, state, owner_pid, remote_node, unquote(submit_function))
      assert [error_frame] = pushes
      assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)

      assert_received {:short_turn_remote_cancel_reason, ^remote_node, :owner_drained}
      assert_received {:short_turn_remote_result, ^remote_node, :remote_cancel_downstream_v1, :ok}
      refute_received {:short_turn_remote_cancel_reason, ^remote_node, :client_disconnected}
      assert %{downstream: nil, active_turn: turn} = :sys.get_state(owner_pid)
      await_turn_settled(owner_pid, turn)
      assert %{active_turn: nil, suspended_replay: nil} = :sys.get_state(owner_pid)
      refute_received {:websocket_owner_frame, _correlation, _epoch, ^task, _payload}
      assert_timed_out_request_failed_without_replay!()
    end
  end

  # With the abandon (current owners) a released-client turn that times out is
  # stopped the same way, and the socket keeps its downstream.
  test "a released-client turn the remote owner takes after its forward budget is stopped without a replay" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached, frame: frame} = released_client_socket(:remote_submit_request_v1)
    {pushes, task, state} = time_out_turn(frame, state, owner_pid, remote_node, :remote_submit_request_v1)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)

    assert_received {:short_turn_remote_result, ^remote_node, :remote_abandon_turn_v1, :ok}
    refute_received {:short_turn_remote_call, ^remote_node, :remote_cancel_downstream_v1, _budget}
    assert %{downstream: ^attached, active_turn: turn} = :sys.get_state(owner_pid)
    await_turn_settled(owner_pid, turn)
    assert %{downstream: ^attached, active_turn: nil, suspended_replay: nil} = :sys.get_state(owner_pid)
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^task, _payload}
    assert_timed_out_request_failed_without_replay!()

    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "released turn timeout next"), [opcode: :text]}, state)
    {pushes, _next_task, state} = drive_until_done(state)
    refute Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["type"] == "error"))
    terminate_and_await_cleanup(state)
  end

  # The other direction of the old-release fallback: when the per-call cancel
  # finds no turn, the submission has not reached the owner yet, and the detach
  # that follows clears the downstream, so the late submission is refused
  # before dispatch, as it was when the detach was the only call.
  test "an owner node without the turn abandon refuses a timed-out submission that arrives after the cancel" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, upstream: upstream} = remote_socket_after_first_turn("full")
    state = remote_owner_state(state, remote_node, node_client: LateSubmissionNodeClient)
    upstream_requests = FakeUpstream.count(upstream)

    LateSubmissionNodeClient.emulate_old_release()
    LateSubmissionNodeClient.arm()
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "late old-release second"), [opcode: :text]}, state)
    assert_receive {:late_submission_held, late}, @detection_timeout_ms
    {pushes, late_task, _state} = drive_until_done(state)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)
    assert_received {:late_client_cancel_reason, ^remote_node, :owner_drained}
    assert_received {:late_client_result, ^remote_node, :remote_cancel_downstream_v1, {:error, :stale_downstream}}
    assert_received {:late_client_cancel_reason, ^remote_node, :client_disconnected}
    assert_received {:late_client_result, ^remote_node, :remote_cancel_downstream_v1, :ok}

    send(late, :reach_owner)
    assert_receive {:late_submission_result, {:error, :stale_downstream}}, @detection_timeout_ms
    assert %{downstream: nil, active_turn: nil} = :sys.get_state(owner_pid)
    assert FakeUpstream.count(upstream) == upstream_requests
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^late_task, _payload}
  end

  # The abandon can also find no owner registered at all (findings#206 row
  # 206-316): the owner is gone when the budget expires and the owner-node
  # process carrying the submission starts or recovers one only afterwards.
  # The abandon leaves a node-level record of the per-call downstream, and the
  # submission that recovers the owner reads it and is refused before
  # dispatch, and the record is consumed.
  test "a timed-out turn submission that recovers its owner after an abandon found none is refused before dispatch" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, upstream: upstream} = remote_socket_after_first_turn("full")
    state = remote_owner_state(state, remote_node, node_client: OwnerGoneNodeClient)
    upstream_requests = FakeUpstream.count(upstream)

    OwnerGoneNodeClient.arm(owner_pid)
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "owner gone second"), [opcode: :text]}, state)
    assert_receive {:owner_gone_late_held, late}, @detection_timeout_ms
    {pushes, late_task, state} = drive_until_done(state)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)
    assert_received {:owner_gone_client_result, ^remote_node, :remote_abandon_turn_v1, {:error, :owner_unavailable}}
    assert AbandonedSubmissions.recorded?(abandoned_key(state, late_task))

    # The late submission runs on the node the session names as its owner.
    session = own_session_locally!(state.codex_session)
    send(late, :reach_owner)
    assert_receive {:owner_gone_late_result, {:error, :stale_downstream}}, @detection_timeout_ms
    assert FakeUpstream.count(upstream) == upstream_requests
    refute AbandonedSubmissions.recorded?(abandoned_key(state, late_task))
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^late_task, _payload}

    # The record is per turn: the recovered owner took the downstream, and a
    # later submission from the same socket, a new response task, is not
    # refused by it.
    assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(session.id)
    assert %{active_turn: nil} = :sys.get_state(recovered_owner)
    refute AbandonedSubmissions.consume(abandoned_key(state, self()))
    terminate_and_await_cleanup(state)
  end

  # The other direction: an abandon that reaches a registered owner leaves no
  # node-level record, the owner keeps what it needs itself (row 206-307).
  test "an abandon that reaches a registered owner leaves no node-level record" do
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node} = remote_socket_after_first_turn("full")
    {_pushes, second_task, state} = time_out_second_turn(setup, state, owner_pid, remote_node)
    assert_received {:short_turn_remote_result, ^remote_node, :remote_abandon_turn_v1, :ok}
    refute AbandonedSubmissions.recorded?(abandoned_key(state, second_task))
    terminate_and_await_cleanup(state)
  end

  # The client-retry submission (owner request v5): the released client resends
  # a turn whose opening request the provider failed, and the owner's
  # client-retry preflight admits the resend as the failed request's one
  # successor. Its forward budget can expire like any turn's, and the owner
  # still takes the queued turn (findings#206 row 206-306).
  for mode <- ["full", "lite"] do
    test "a client-retry turn the remote owner takes after its forward budget is stopped without detaching the connected socket (#{mode})" do
      %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached, frame: frame, upstream: upstream} = remote_socket_after_failed_turn(unquote(mode))
      assert_served_in_mode!(upstream, unquote(mode))
      {pushes, retry_task, state} = time_out_turn(frame, state, owner_pid, remote_node, :remote_submit_request_v5)
      assert [error_frame] = pushes
      assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)

      assert %{downstream: ^attached, active_turn: retry_turn} = :sys.get_state(owner_pid)
      await_turn_settled(owner_pid, retry_turn)
      assert %{downstream: ^attached, active_turn: nil} = :sys.get_state(owner_pid)
      refute_received {:websocket_owner_frame, _correlation, _epoch, ^retry_task, _payload}

      assert_received {:short_turn_remote_result, ^remote_node, :remote_submit_request_v5, {:error, :owner_forward_timeout}}
      assert_received {:short_turn_remote_result, ^remote_node, :remote_abandon_turn_v1, :ok}
      refute_received {:short_turn_remote_call, ^remote_node, :remote_cancel_downstream_v1, _budget}

      assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote retry timeout next"), [opcode: :text]}, state)
      {pushes, _next_task, state} = drive_until_done(state)
      assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_turn_timeout"))
      refute Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["type"] == "error"))

      assert {:monitors, monitors} = Process.info(owner_pid, :monitors)
      assert {:process, attached.pid} in monitors
      terminate_and_await_cleanup(state)
      assert %{downstream: nil} = :sys.get_state(owner_pid)
    end
  end

  # No timeout involved (findings#206 row 206-315, the other half): a socket
  # that closes while a remote client-retry turn has shown nothing yet arms
  # that turn's pre-visible replay, the task's settlement there ends without
  # an error frame because no client is left to read one, and the released
  # client's resend on a new socket redeems the replay: one terminal, one
  # provider request more, one settled request.
  test "an ordinary close during a remote client-retry turn arms its replay and the resend is served once" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.websocket_terminal_failure("server_error"),
          FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic held client-retry turn"),
          FakeUpstream.json_response(%{"id" => "resp_remote_retry_close", "object" => "response", "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}})
        ])
      )

    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, auth: auth, turn_state: turn_state} = remote_socket(upstream, "full")
    thread = "ws-remote-retry-close-#{System.unique_integer([:positive])}"
    frame = released_client_frame(setup, thread, Ecto.UUID.generate(), "remote retry close")
    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    {pushes, _first_task, state} = drive_until_done(state)
    assert Enum.any?(pushes, &match?(%{"type" => "response.failed"}, CodexPooler.JSON.decode!(&1)))

    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @detection_timeout_ms
    assert_received {:short_turn_remote_call, ^remote_node, :remote_submit_request_v5, _budget}
    [retry_task] = MapSet.to_list(state.tasks)
    monitor = Process.monitor(retry_task)

    terminate_and_await_cleanup(state)
    assert_receive {:DOWN, ^monitor, :process, ^retry_task, _reason}, @detection_timeout_ms
    assert %{downstream: nil, active_turn: nil, suspended_replay: %{provisional_status: :armed}} = :sys.get_state(owner_pid)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert [%RequestReplayEntitlement{status: "armed", request_id: retry_request_id}] = Repo.all(RequestReplayEntitlement)

    {:ok, resend_state} = owner_socket(auth, "ws-remote-turn-timeout-resend", turn_state, websocket_owner_forwarder_opts: [node_client: ShortTurnBudgetNodeClient])
    assert {:ok, resend_state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, resend_state)
    {pushes, _resend_task, resend_state} = drive_until_done(resend_state)
    assert Enum.count(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_retry_close")) == 1
    refute Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["type"] == "error"))
    assert_received {:short_turn_remote_call, ^remote_node, :remote_submit_request_v4, _budget}

    assert %Request{status: "succeeded"} = Repo.get!(Request, retry_request_id)
    assert [{0, "retryable_failed"}, {1, "succeeded"}] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^retry_request_id, order_by: [asc: attempt.attempt_number], select: {attempt.replay_generation, attempt.status}))
    assert [%RequestReplayEntitlement{status: "consumed"}] = Repo.all(RequestReplayEntitlement)
    assert FakeUpstream.count(upstream) == 3
    assert :ok = FakeUpstream.verify!(upstream)
    terminate_and_await_cleanup(resend_state)
  end

  # The same close after the client saw output (findings#206 row 206-336): the
  # turn is past replay, so the early pre-visible call arms nothing and the
  # socket's ordinary detach stops the remote turn. It settles once as the
  # client's disconnect, and what the provider sends after the cut reaches no
  # one and is not billed again.
  test "an ordinary close after visible output during a remote client-retry turn stops it once without a replay" do
    release_ref = make_ref()
    created = %{"type" => "response.created", "response" => %{"id" => "resp_remote_retry_visible", "status" => "in_progress", "output" => []}}
    delta = %{"type" => "response.output_text.delta", "item_id" => "msg_remote_retry_visible", "output_index" => 0, "content_index" => 0, "delta" => "synthetic partial"}
    completed = %{"type" => "response.completed", "response" => %{"id" => "resp_remote_retry_visible", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}}}

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.websocket_terminal_failure("server_error"),
          FakeUpstream.barrier_websocket_frames(Enum.map([created, delta, completed], &CodexPooler.JSON.encode!/1), notify: self(), release_ref: release_ref)
        ])
      )

    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node} = remote_socket(upstream, "full")
    thread = "ws-remote-retry-visible-close-#{System.unique_integer([:positive])}"
    frame = released_client_frame(setup, thread, Ecto.UUID.generate(), "remote retry visible close")
    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    {pushes, _first_task, state} = drive_until_done(state)
    assert Enum.any?(pushes, &match?(%{"type" => "response.failed"}, CodexPooler.JSON.decode!(&1)))

    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)

    for ordinal <- [0, 1] do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @detection_timeout_ms
      assert :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^release_ref}, @detection_timeout_ms
    assert_received {:short_turn_remote_call, ^remote_node, :remote_submit_request_v5, _budget}
    {pushes, state} = deliver_frames(state, 3)
    assert Enum.map(pushes, &CodexPooler.JSON.decode!(&1)["type"]) == ["codex.response.metadata", "response.created", "response.output_text.delta"]
    [retry_task] = MapSet.to_list(state.tasks)
    monitor = Process.monitor(retry_task)
    assert [%Request{id: retry_request_id}] = Repo.all(from(request in Request, where: request.status == "in_progress"))

    terminate_and_await_cleanup(state)
    assert_receive {:DOWN, ^monitor, :process, ^retry_task, _reason}, @detection_timeout_ms
    %{active_turn: turn} = :sys.get_state(owner_pid)
    await_turn_settled(owner_pid, turn)
    assert %{downstream: nil, active_turn: nil, suspended_replay: nil} = :sys.get_state(owner_pid)

    # The provider's terminal after the cut: nothing more reaches the socket,
    # the provider sees no further request, and the request keeps the one
    # settlement of the disconnect.
    assert :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
    assert %{active_turn: nil} = :sys.get_state(owner_pid)
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^retry_task, _payload}
    assert %Request{status: "failed", response_status_code: 499, last_error_code: "client_disconnected"} = Repo.get!(Request, retry_request_id)
    assert [{0, "failed"}] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^retry_request_id, order_by: [asc: attempt.attempt_number], select: {attempt.replay_generation, attempt.status}))
    assert Repo.aggregate(RequestReplayEntitlement, :count) == 0
    assert FakeUpstream.count(upstream) == 2
    assert pool_ledger_entries(setup.pool.id) |> Enum.filter(&(&1.request_id == retry_request_id)) |> Enum.map(& &1.entry_kind) |> Enum.frequencies() == %{"reservation" => 1, "settlement" => 1, "release" => 1}
  end

  # The owner holding the timed-out submission dies while the abandon waits in
  # its mailbox (findings#206 row 206-336, the owner-crashed branch of row
  # 206-316): the abandon's call exits, it leaves the node-level record and
  # finds no owner on its second lookup, and the submission that recovers the
  # owner afterwards is refused before dispatch.
  test "an abandon whose owner dies under it leaves the record the recovering submission is refused by" do
    %{state: state, setup: setup, owner_pid: owner_pid, remote_node: remote_node, upstream: upstream} = remote_socket_after_first_turn("full")
    state = remote_owner_state(state, remote_node, node_client: OwnerDiesUnderAbandonNodeClient)
    upstream_requests = FakeUpstream.count(upstream)
    session = own_session_locally!(state.codex_session)

    OwnerDiesUnderAbandonNodeClient.arm(owner_pid)
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "dying owner second"), [opcode: :text]}, state)
    assert_receive {:dying_owner_late_held, late}, @detection_timeout_ms
    # The abandon's call reached the held owner; the owner dies under it.
    assert_receive {:dying_owner_abandon_in_mailbox, ^owner_pid}, @detection_timeout_ms
    monitor = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :killed}, @detection_timeout_ms

    {pushes, late_task, state} = drive_until_done(state)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)
    assert_received {:dying_owner_client_result, ^remote_node, :remote_abandon_turn_v1, {:error, :owner_unavailable}}
    assert AbandonedSubmissions.recorded?(abandoned_key(state, late_task))

    send(late, :reach_owner)
    assert_receive {:dying_owner_late_result, {:error, :stale_downstream}}, @detection_timeout_ms
    assert FakeUpstream.count(upstream) == upstream_requests
    refute AbandonedSubmissions.recorded?(abandoned_key(state, late_task))
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^late_task, _payload}
    assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(session.id)
    assert %{active_turn: nil} = :sys.get_state(recovered_owner)
    assert_timed_out_request_failed_once!(setup.pool.id)
    terminate_and_await_cleanup(state)
  end

  # The submission registers the owner between the abandon's two lookups
  # (findings#206 row 206-336): the abandon's first lookup finds none, the
  # submission recovers the owner, reads no record yet and sends the turn, and
  # the abandon's second lookup, after it wrote the record, finds that owner
  # and stops exactly that turn before it shows anything. The provider saw the
  # request; its output reaches no one and the request keeps the one
  # settlement of the forward timeout.
  test "a submission that registers its owner between the abandon's two lookups has its turn stopped by the second" do
    release_ref = make_ref()
    completed = %{"type" => "response.completed", "response" => %{"id" => "resp_between_lookups", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}}}

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_remote_turn_timeout", "object" => "response", "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}}),
          FakeUpstream.barrier_websocket_frames([CodexPooler.JSON.encode!(completed)], notify: self(), release_ref: release_ref)
        ])
      )

    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node} = remote_socket(upstream, "full")
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote turn timeout first"), [opcode: :text]}, state)
    {_pushes, _first_task, state} = drive_until_done(state)
    state = remote_owner_state(state, remote_node, node_client: OwnerGoneNodeClient)
    session = own_session_locally!(state.codex_session)

    LookupPause.arm(self(), session.id, :remote_abandon_turn_v1)
    OwnerGoneNodeClient.arm(owner_pid)
    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "between lookups second"), [opcode: :text]}, state)
    assert_receive {:owner_gone_late_held, late}, @detection_timeout_ms
    assert_receive {:lookup_paused, abandon}, @detection_timeout_ms

    # The abandon found no owner and waits before its record; the submission
    # recovers the owner and its turn reaches the provider.
    send(late, :reach_owner)
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^release_ref}, @detection_timeout_ms
    assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(session.id)
    assert %{active_turn: %{task_pid: late_turn_task}} = :sys.get_state(recovered_owner)

    send(abandon, :resume_lookup)
    {pushes, late_task, state} = drive_until_done(state)
    assert [error_frame] = pushes
    assert %{"type" => "error"} = CodexPooler.JSON.decode!(error_frame)
    assert_received {:owner_gone_client_result, ^remote_node, :remote_abandon_turn_v1, :ok}

    turn_monitor = Process.monitor(late_turn_task)
    assert_receive {:DOWN, ^turn_monitor, :process, ^late_turn_task, _reason}, @detection_timeout_ms
    assert_receive {:owner_gone_late_result, late_result}, @detection_timeout_ms
    refute match?({:ok, _}, late_result)
    assert %{active_turn: nil} = :sys.get_state(recovered_owner)
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
    assert %{active_turn: nil} = :sys.get_state(recovered_owner)
    refute_received {:websocket_owner_frame, _correlation, _epoch, ^late_task, _payload}
    assert FakeUpstream.count(upstream) == 2
    assert_timed_out_request_failed_once!(setup.pool.id)
    # The abandon wrote its record before it found the owner; nothing reads
    # it any more (the turn is stopped) and it expires on its own.
    assert AbandonedSubmissions.consume(abandoned_key(state, late_task))
    terminate_and_await_cleanup(state)
  end

  # The one timed-out request: failed as the forward timeout the client was
  # sent, reserved, settled and released once (the stopped turn adds nothing).
  defp assert_timed_out_request_failed_once!(pool_id) do
    assert [%Request{id: request_id, status: "failed", response_status_code: 504}] = Repo.all(from(request in Request, where: request.last_error_code == "owner_forward_timeout"))
    assert pool_ledger_entries(pool_id) |> Enum.filter(&(&1.request_id == request_id)) |> Enum.map(& &1.entry_kind) |> Enum.frequencies() == %{"reservation" => 1, "settlement" => 1, "release" => 1}
  end

  defp deliver_frames(state, count, pushes \\ [])
  defp deliver_frames(state, count, pushes) when length(pushes) >= count, do: {pushes, state}

  defp deliver_frames(state, count, pushes) do
    receive do
      message
      when is_tuple(message) and
             elem(message, 0) in [:websocket_owner_frame, :websocket_owner_cleanup_witness, :websocket_owner_output_commit_probe, :websocket_response_activity] ->
        {pushes, state} = apply_socket_message(message, state, pushes)
        deliver_frames(state, count, pushes)
    after
      @detection_timeout_ms -> flunk("expected #{count} frames pushed, saw #{length(pushes)}")
    end
  end

  defp abandoned_key(state, task), do: AbandonedSubmissions.key(state.codex_session.id, Map.put(state.websocket_owner_downstream, :owner_turn_id, task))

  defp own_session_locally!(session) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    local = Atom.to_string(node())
    active_owner_lease(session.id) |> Ecto.Changeset.change(owner_instance_id: local, updated_at: now) |> Repo.update!()
    session |> Ecto.Changeset.change(owner_instance_id: local, updated_at: now) |> Repo.update!()
  end

  # A socket whose next frame is a released-client turn that times out: a
  # fresh turn after a completed one (owner request v1), or the resend of a
  # turn the provider failed (owner request v5, the client-retry submission).
  defp released_client_socket(:remote_submit_request_v5), do: remote_socket_after_failed_turn("full")

  defp released_client_socket(:remote_submit_request_v1) do
    %{setup: setup} = context = remote_socket_after_first_turn("full")
    thread = "ws-remote-released-timeout-#{System.unique_integer([:positive])}"
    Map.put(context, :frame, released_client_frame(setup, thread, Ecto.UUID.generate(), "remote released turn timeout"))
  end

  # The timed-out request settled as the forward timeout the client was sent,
  # and no replay was armed for it.
  defp assert_timed_out_request_failed_without_replay! do
    assert [%Request{status: "failed", response_status_code: 504}] = Repo.all(from(request in Request, where: request.last_error_code == "owner_forward_timeout"))
    assert Repo.aggregate(RequestReplayEntitlement, :count) == 0
  end

  defp remote_socket_after_failed_turn(mode) do
    upstream =
      start_upstream(
        # The opening request fails at the provider; every later request completes.
        FakeUpstream.repeat_last([
          FakeUpstream.websocket_terminal_failure("server_error"),
          FakeUpstream.json_response(%{
            "id" => "resp_remote_turn_timeout",
            "object" => "response",
            "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}
          })
        ])
      )

    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node} = remote_socket(upstream, mode)
    thread = "ws-remote-retry-timeout-#{System.unique_integer([:positive])}"
    frame = released_client_frame(setup, thread, Ecto.UUID.generate(), "remote retry timeout")

    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    {pushes, _first_task, state} = drive_until_done(state)
    assert Enum.any?(pushes, &match?(%{"type" => "response.failed"}, CodexPooler.JSON.decode!(&1)))
    attached = :sys.get_state(owner_pid).downstream
    assert %{pid: socket_pid} = attached
    assert socket_pid == self()
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached, frame: frame, upstream: upstream}
  end

  # Lite marks every request it sends upstream with the released client's Lite
  # header key in `client_metadata`; Full sends none.
  defp assert_served_in_mode!(upstream, mode) do
    assert [_first | _rest] = requests = FakeUpstream.requests(upstream)

    for %{json: json} <- requests do
      assert Map.has_key?(json["client_metadata"] || %{}, "ws_request_header_x_openai_internal_codex_responses_lite") == (mode == "lite")
    end
  end

  # A `response.create` shaped like the released client's opening request of a
  # turn: its turn metadata names the thread and the turn, so its resend is
  # matched to it. Identifiers and text are synthetic.
  defp released_client_frame(setup, thread, turn_id, text) do
    metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id}

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input(text),
      "stream" => true,
      "generate" => true,
      "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", CodexPooler.JSON.encode!(Map.put(metadata, "request_kind", "turn")))
    })
  end

  defp remote_socket_after_first_turn(mode) do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_remote_turn_timeout",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}
        })
      )

    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, auth: auth, turn_state: turn_state} = remote_socket(upstream, mode)

    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote turn timeout first"), [opcode: :text]}, state)
    {pushes, _first_task, state} = drive_until_done(state)
    assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_turn_timeout"))
    attached = :sys.get_state(owner_pid).downstream
    assert %{pid: socket_pid} = attached
    assert socket_pid == self()
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, attached: attached, upstream: upstream, auth: auth, turn_state: turn_state}
  end

  # A socket whose owner is recorded on another node: every owner call goes
  # through the node client to the local node. The model serves in `mode`.
  defp remote_socket(upstream, mode) do
    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = Ecto.UUID.generate()
    {:ok, state} = owner_socket(auth, "ws-remote-turn-timeout", turn_state)
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
    %{setup: setup, state: state, owner_pid: owner_pid, remote_node: remote_node, auth: auth, turn_state: turn_state}
  end

  # The owner stalls past the second turn's forward budget. Both the
  # submission and whatever the forwarder sends after the timeout wait in its
  # mailbox, in that order, before it runs again.
  defp time_out_second_turn(setup, state, owner_pid, remote_node) do
    time_out_turn(websocket_payload(setup, "remote turn timeout second"), state, owner_pid, remote_node, :remote_submit_request_v1)
  end

  defp time_out_turn(frame, state, owner_pid, remote_node, submit_function) do
    ShortTurnBudgetNodeClient.arm(owner_pid, submit_function)
    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:short_turn_owner_suspended, ^owner_pid}, @detection_timeout_ms

    try do
      assert_receive {:short_turn_remote_call, ^remote_node, ^submit_function, 200}, @detection_timeout_ms
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
