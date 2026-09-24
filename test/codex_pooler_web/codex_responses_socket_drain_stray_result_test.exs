defmodule CodexPoolerWeb.CodexResponsesSocketDrainStrayResultTest do
  @moduledoc """
  The post-cleanup drain of a terminating socket (`do_await_response_tasks/5`)
  takes a task's `{:codex_response_done, pid, result}` only from a task it
  awaits, as its pre-cleanup sibling does. It used to take that message from
  any pid: a socket process that also ran another socket's turn (the
  same-process two-socket tests) consumed the other socket's result, that
  socket never acknowledged its task, and the task stayed parked until the
  15 s owner drain reaped it (findings#206 row 206-437). A socket process in
  production only receives its own tasks' results, and every one of those is
  still awaited here, so the guard changes nothing there.

  Topology: one VM, a local owner, owner forwarding on (the socket state names
  its owner downstream); no provider.
  """

  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPoolerWeb.CodexResponsesSocket

  @detection_timeout_ms 15_000
  @drain_budget_ms 5_000

  setup do
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    {:ok, auth: %{pool: pool, api_key: api_key}}
  end

  test "the post-cleanup drain leaves a result from a task it does not await in the mailbox", %{auth: auth} do
    registry = start_supervised!({ActivityRegistry, name: nil})
    parent = self()

    socket =
      spawn(fn ->
        receive do
          {:terminate, state} ->
            :ok = CodexResponsesSocket.terminate({:error, :closed}, state)
            {:messages, messages} = Process.info(self(), :messages)
            send(parent, {:socket_terminated, messages})
        end
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)

    # The socket's own task: still running when the socket terminates, it
    # exits once released and never reports a result.
    task =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    monitor = Process.monitor(task)
    state = local_owner_state(auth, task, registry)

    owner =
      start_supervised!({WebsocketOwnerSession, codex_session_id: state.codex_session.id, owner_lease_token: state.websocket_owner_lease_token, owner_instance_id: state.codex_session.owner_instance_id})

    assert {:ok, downstream} = WebsocketOwnerSession.attach_downstream(owner, %{pid: socket, correlation_id: "drain-stray-result"})

    send(socket, {:terminate, %{state | websocket_owner_downstream: downstream}})
    await_post_cleanup_wait(socket, System.monotonic_time(:millisecond) + @detection_timeout_ms)

    # Another task's result reaches the draining socket before its own task
    # ends; the drain must leave it where it is.
    stray = spawn(fn -> :ok end)
    stray_result = {:codex_response_done, stray, :ok}
    send(socket, stray_result)
    send(task, :release)

    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, @detection_timeout_ms
    assert_receive {:socket_terminated, messages}, @detection_timeout_ms
    assert stray_result in messages
  end

  defp await_post_cleanup_wait(socket, deadline) do
    case Process.info(socket, :current_function) do
      {:current_function, {CodexResponsesSocket, :do_await_response_tasks, 5}} ->
        :ok

      other ->
        assert System.monotonic_time(:millisecond) < deadline, "socket did not reach the post-cleanup wait: #{inspect(other)}"

        receive do
        after
          1 -> await_post_cleanup_wait(socket, deadline)
        end
    end
  end

  defp local_owner_state(auth, task, registry) do
    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "drain-stray-result-#{System.unique_integer([:positive])}",
               owner_instance_id: Atom.to_string(node())
             })

    %{
      auth: nil,
      opts: RequestOptions.for_websocket(%{websocket_owner_response_task_drain_ms: @drain_budget_ms, websocket_response_task_drain_ms: @drain_budget_ms}),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_downstream: %{pid: self(), epoch: 1, correlation_id: "corr-drain-stray-result", active_turn_reconnect?: false},
      upstream_websocket_session: nil,
      request_response_work_started?: true,
      tasks: MapSet.new([task]),
      task_monitors: %{task => Process.monitor(task)},
      queued_response_payloads: :queue.new(),
      response_task_activity_registry: registry
    }
  end
end
