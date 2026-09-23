defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.RemoteOwnerAttemptExecutorTest do
  # A remote-owner websocket turn runs on two nodes: the proxy node holds the
  # client socket and the response task that reserves, dispatches and settles
  # the attempt, and the owner node holds the upstream connection. The
  # attempt's `owner_instance_id`, `owner_instance_boot_id`, `owner_process_id`
  # and `owner_execution_id` name that response task, one executor identity
  # that dead-execution and absent-instance recovery ask about as a unit; the
  # owner node is recorded in `request_metadata.websocket_owner_forwarding`.
  # Stamping the owner node there would pair it with a proxy-local process and
  # execution id, which no node can answer for (findings#206 row 206-360).
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestLifecycle.DeadExecutionRecovery
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Platform.ExecutionIdentity
  alias CodexPooler.Platform.InstancePresence
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

  test "a remote-owner turn's attempt names the proxy executor that recovery can answer for" do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
    use_fresh_rollout_drain!()
    release_ref = make_ref()
    response_id = "resp_remote_attempt_executor_#{System.unique_integer([:positive])}"

    terminal =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed"}
      })

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(
          terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    session_header = "remote-attempt-executor-#{System.unique_integer([:positive])}"
    {_session, _owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)

    {:ok, state} =
      owner_socket(auth, "ws-remote-attempt-executor", "remote-attempt-executor",
        session_header: session_header,
        session_header_source: "x-session-id"
      )

    try do
      payload = websocket_payload(setup, "remote attempt executor")
      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

      # The owner node holds the upstream turn before its terminal: the attempt
      # is open and its executor is still running.
      assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid, ^release_ref}, 15_000
      assert [task_pid] = MapSet.to_list(state.tasks)

      {request, attempt} = open_attempt!(setup.pool.id)
      local = InstancePresence.local_identity()

      assert %{
               "enabled" => true,
               "owner_instance_id" => owner_instance_id,
               "proxy_instance_id" => proxy_instance_id
             } = request.request_metadata["websocket_owner_forwarding"]

      assert owner_instance_id == Atom.to_string(remote_node)
      assert proxy_instance_id == Atom.to_string(node())

      # The executor identity is the proxy node's response task, as a unit.
      assert attempt.owner_instance_id == Atom.to_string(node())
      assert attempt.owner_instance_boot_id == local.boot_id
      assert attempt.owner_process_id == List.to_string(:erlang.pid_to_list(task_pid))
      assert is_binary(attempt.owner_execution_id)

      # Recovery reads that identity exactly: the running task is alive, so a
      # dead-execution pass that already considers the attempt old enough
      # leaves it open.
      assert ExecutionIdentity.status(attempt) == :alive

      assert {:ok, %{dead_execution_attempts_recovered: 0}} =
               DeadExecutionRecovery.recover(DateTime.add(DateTime.utc_now(), 3_600, :second), minimum_age_seconds: 0)

      assert %Attempt{status: "in_progress"} = Repo.get!(Attempt, attempt.id)

      send(barrier_pid, {:fake_upstream_release_websocket, release_ref})
      assert_receive {:fake_upstream_websocket_barrier, :before_close, close_pid, ^release_ref}, 15_000
      send(close_pid, {:fake_upstream_release_websocket, release_ref})
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp open_attempt!(pool_id) do
    assert [{%Request{} = request, %Attempt{} = attempt}] =
             Repo.all(
               from attempt in Attempt,
                 join: request in Request,
                 on: request.id == attempt.request_id,
                 where: request.pool_id == ^pool_id and attempt.status == "in_progress",
                 select: {request, attempt}
             )

    {request, attempt}
  end

  defp use_fresh_rollout_drain! do
    previous_config = Application.get_env(:codex_pooler, RolloutDrain)
    previous_status_config = Application.get_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

    activity_registry = :"attempt-executor-activity-#{System.unique_integer([:positive])}"
    drain_name = :"attempt-executor-drain-#{System.unique_integer([:positive])}"
    stream_registry = :"attempt-executor-streams-#{System.unique_integer([:positive])}"
    start_supervised!({ActivityRegistry, name: activity_registry})
    start_supervised!({CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistry, name: stream_registry})
    start_supervised!({RolloutDrain, name: drain_name, activity_registry: activity_registry, stream_registry: stream_registry})

    Application.put_env(:codex_pooler, RolloutDrain, server_name: drain_name)
    Application.delete_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

    on_exit(fn ->
      case previous_config do
        nil -> Application.delete_env(:codex_pooler, RolloutDrain)
        config -> Application.put_env(:codex_pooler, RolloutDrain, config)
      end

      case previous_status_config do
        nil -> Application.delete_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)
        config -> Application.put_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus, config)
      end
    end)
  end
end
