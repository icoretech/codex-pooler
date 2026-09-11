defmodule CodexPoolerWeb.CodexResponsesSocketOwnerRecoveryDrainTest do
  @moduledoc """
  Findings #119 item 2: a client disconnect while a forwarded response task is
  parked in an owner recovery re-submit must not hold the socket for the
  post-cleanup owner drain budget. The socket's stale lease token makes its
  own detach a silent no-op once the replacement owner holds a new lease, so
  the drain has to end on a signal: the recovery notification (detach the
  replacement) and the task's own done report (acknowledge it).
  """

  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  # Failure-detection budget for process and socket shutdown under N=4.
  @detection_timeout_ms 15_000
  # The socket drain budgets, shortened through the transport option so a
  # regression fails in seconds instead of the production owner drain. The
  # green path ends on a signal and must finish well inside this bound.
  @drain_budget_ms 5_000

  setup do
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    {:ok, auth: %{pool: pool, api_key: api_key}}
  end

  test "socket termination detaches the replacement owner from an unprocessed recovery notification",
       %{auth: auth} do
    scenario = start_recovery_scenario(auth, "unprocessed", block_recovery_start?: false)

    # The recovery already re-submitted and parked on the replacement owner;
    # its notification sits unprocessed in the socket mailbox.
    assert_receive {:recovery_submit_started, _recovery_worker}, @detection_timeout_ms

    send(scenario.socket, {:terminate_socket, scenario.state})
    assert_receive {:socket_terminating, socket}, @detection_timeout_ms
    assert socket == scenario.socket

    assert_socket_drained_on_signal(scenario)
  end

  test "socket termination detaches a replacement owner it learns about while draining", %{
    auth: auth
  } do
    scenario = start_recovery_scenario(auth, "during-drain", block_recovery_start?: true)

    # The recovery is parked before the replacement owner exists, so the
    # socket's first detach finds no owner and the notification must arrive
    # while the drain is already waiting.
    assert_receive {:recovery_start_blocked, recovery_start_pid, release_ref},
                   @detection_timeout_ms

    send(scenario.socket, {:terminate_socket, scenario.state})
    assert_receive {:socket_terminating, socket}, @detection_timeout_ms
    assert socket == scenario.socket

    send(recovery_start_pid, {:release_recovery_start, release_ref})
    assert_receive {:recovery_submit_started, _recovery_worker}, @detection_timeout_ms

    assert_socket_drained_on_signal(scenario)
  end

  defp assert_socket_drained_on_signal(scenario) do
    %{socket: socket, task: task, task_monitor: task_monitor, session: session} = scenario

    assert_receive {:socket_terminated, ^socket, elapsed_ms}, @detection_timeout_ms

    # A drain that ran to its timer would have reaped the task with the
    # post-drain shutdown exit; the signal path lets it finish normally.
    assert_receive {:DOWN, ^task_monitor, :process, ^task, task_exit_reason}, 100
    assert task_exit_reason == :normal
    assert elapsed_ms < @drain_budget_ms

    assert {:ok, replacement_owner} = WebsocketOwnerSession.lookup(session.id)
    assert %{active_turn: nil, downstream: nil} = :sys.get_state(replacement_owner)
    assert ActivityRegistry.activities(name: scenario.registry) == []
  end

  defp start_recovery_scenario(auth, label, block_recovery_start?: block_recovery_start?) do
    local_node_string = Atom.to_string(node())
    parent = self()
    release_ref = make_ref()
    registry = start_supervised!({ActivityRegistry, name: nil})

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state:
                 "recovery-drain-#{label}-#{System.unique_integer([:positive])}",
               owner_instance_id: local_node_string
             })

    session = Repo.get!(CodexSession, session.id)
    on_exit(fn -> stop_local_owner_session(session.id) end)

    first_upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:first_submit_started, self(), release_ref})

        receive do
          {:release_first_submit, ^release_ref} -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
        :ok
      end
    }

    recovery_upstream = %{
      start: fn ->
        if block_recovery_start? do
          send(parent, {:recovery_start_blocked, self(), release_ref})

          receive do
            {:release_recovery_start, ^release_ref} -> :ok
          end
        end

        Agent.start_link(fn -> :ready end)
      end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:recovery_submit_started, self()})

        receive do
          :never_released -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
        :ok
      end
    }

    {:ok, first_owner} =
      WebsocketOwnerSession.start_owner(
        codex_session_id: session.id,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: local_node_string,
        upstream: first_upstream
      )

    socket = spawn(fn -> socket_loop(parent) end)

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(first_owner, %{
               pid: socket,
               correlation_id: "corr-recovery-drain-#{label}"
             })

    {:ok, task} =
      ResponseTask.start(
        socket,
        :proxy,
        fn task_pid ->
          WebsocketOwnerForwarder.submit_request(
            session,
            session.owner_lease_token,
            Map.put(stable_downstream, :owner_turn_id, task_pid),
            request("recovery-drain-#{label}"),
            upstream: recovery_upstream,
            local_node_string: local_node_string,
            request_id: "recovery-drain-#{label}"
          )
        end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry
      )

    task_monitor = Process.monitor(task)

    assert_receive {:first_submit_started, first_worker, ^release_ref}, @detection_timeout_ms

    first_owner_monitor = Process.monitor(first_owner)
    Process.exit(first_owner, :kill)
    assert_receive {:DOWN, ^first_owner_monitor, :process, ^first_owner, :killed}
    send(first_worker, {:release_first_submit, release_ref})

    state = %{
      auth: nil,
      opts:
        RequestOptions.for_websocket(%{
          websocket_owner_response_task_drain_ms: @drain_budget_ms,
          websocket_response_task_drain_ms: @drain_budget_ms
        }),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_downstream: stable_downstream,
      upstream_websocket_session: nil,
      request_response_work_started?: true,
      tasks: MapSet.new([task]),
      queued_response_payloads: :queue.new(),
      response_task_activity_registry: registry
    }

    %{
      socket: socket,
      task: task,
      task_monitor: task_monitor,
      session: session,
      registry: registry,
      state: state
    }
  end

  # Stands in for the WebSock process: it holds the mailbox the owner and the
  # task write to, and runs the real `terminate/2` on the prepared state.
  defp socket_loop(parent) do
    receive do
      {:terminate_socket, state} ->
        state = Map.put(state, :task_monitors, Map.new(state.tasks, &{&1, Process.monitor(&1)}))
        send(parent, {:socket_terminating, self()})
        started_at_ms = System.monotonic_time(:millisecond)
        :ok = CodexResponsesSocket.terminate(:remote, state)
        elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
        send(parent, {:socket_terminated, self(), elapsed_ms})
    end
  end

  defp request(payload) do
    %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: payload,
      timeouts: %{}
    }
  end

  # The replacement owner holds a lease the rolled-back sandbox no longer
  # knows about, so its shutdown logs a release failure; keep that out of the
  # suite output.
  defp stop_local_owner_session(codex_session_id) do
    _logs =
      capture_log(fn ->
        case WebsocketOwnerSession.lookup(codex_session_id) do
          {:ok, owner_pid} ->
            monitor = Process.monitor(owner_pid)

            try do
              GenServer.stop(owner_pid, :normal, @detection_timeout_ms)
            catch
              :exit, _reason -> :ok
            end

            receive do
              {:DOWN, ^monitor, :process, ^owner_pid, _reason} -> :ok
            after
              @detection_timeout_ms -> :ok
            end

          {:error, :owner_unavailable} ->
            :ok
        end
      end)

    :ok
  end
end
