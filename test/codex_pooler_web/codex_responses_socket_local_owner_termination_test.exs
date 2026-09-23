defmodule CodexPoolerWeb.CodexResponsesSocketLocalOwnerTerminationTest do
  @moduledoc """
  A client that disconnects right as a local owner turn completes leaves the
  response task's activity token and result unprocessed in the socket
  mailbox. The activity registry never tracks a local owner task, so socket
  termination has to learn the token from that mailbox and acknowledge the
  task; otherwise the task stays parked on the acknowledgement and the owner
  drain runs to its timer before reaping it.
  """

  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Platform.{ExecutionIdentity, ExecutionRegistry}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  # Failure-detection budget for process shutdown under N=4.
  @detection_timeout_ms 15_000
  # The socket drain budgets, shortened through the transport option so a
  # regression fails in seconds instead of the production owner drain. The
  # green path ends on the task's exit and must finish well inside this bound.
  @drain_budget_ms 5_000

  setup do
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    {:ok, auth: %{pool: pool, api_key: api_key}}
  end

  test "socket termination acknowledges a local owner task whose completion is still unprocessed",
       %{auth: auth} do
    registry = start_supervised!({ActivityRegistry, name: nil})
    {request, attempt} = receipt_fixture(auth)

    {:ok, task} =
      ResponseTask.start(
        self(),
        :local_owner,
        fn _task_pid -> {:socket_response_result, :owner_completion_pending, :ok} end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry
      )

    task_monitor = Process.monitor(task)

    # The task reports its activity token and result, then parks on the
    # delivery acknowledgement. Re-queue both in their original order: that
    # is the WebSock mailbox when the client disconnect reaches terminate/2
    # before either message was handled.
    assert_receive {:websocket_response_activity, ^task, token}
    assert_receive {:codex_response_done, ^task, result}
    assert {:socket_response_result, :owner_completion_pending, :ok} = result
    send(self(), {:websocket_response_activity, task, token})
    send(self(), {:codex_response_done, task, result})

    state =
      auth
      |> local_owner_state(task, registry)
      |> put_delivery_receipt_context(task, request, attempt)

    started_at_ms = System.monotonic_time(:millisecond)

    {:ok, logs} =
      with_info_log(fn -> CodexResponsesSocket.terminate(:remote, state) end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    # A drain that ran to its timer reaps the parked task with the post-drain
    # shutdown exit; the acknowledgement lets it finish normally.
    assert_receive {:DOWN, ^task_monitor, :process, ^task, task_exit_reason},
                   @detection_timeout_ms

    assert task_exit_reason == :normal
    assert elapsed_ms < @drain_budget_ms
    assert ActivityRegistry.activities(name: registry) == []

    # One receipt for the attempt: the terminal was pushed, but the socket
    # closed before it handled the turn's completion.
    assert length(Regex.scan(~r/websocket downstream terminal pushed/, logs)) == 1

    assert %{
             "outcome" => "aborted",
             "terminal_class" => "response.completed",
             "frames_after_visible" => 2,
             "transport" => "websocket"
           } = Repo.get!(Attempt, attempt.id).response_metadata["downstream_delivery"]
  end

  for ordering <- [:both_after, :split_across_wait] do
    @tag completion_ordering: ordering
    test "socket termination acknowledges completion #{ordering}",
         %{auth: auth, completion_ordering: ordering} do
      assert_late_completion(auth, ordering)
    end
  end

  # The socket pushed and accepted the turn's `response.completed` before the
  # client left, but the task's own completion reached the socket only during
  # the terminate drain (its settlement was slow, as during a database outage).
  # The terminal was delivered and the result is `:ok`, so the task must be
  # acknowledged `:completed` and retire its execution as `completed`; a local
  # owner task is never tracked by the activity registry, so the socket's own
  # state is the authority for it (findings#217, row 217-60: the outage lane saw
  # a `process_down` proof for a normally delivered turn).
  test "a delivered local owner turn whose completion arrives during the terminate drain retires as completed", %{auth: auth} do
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)
    registry = start_supervised!({ActivityRegistry, name: nil})
    parent = self()

    socket =
      spawn(fn ->
        receive do
          {:terminate, state} ->
            {:ok, logs} =
              ExUnit.CaptureLog.with_log([level: :info], fn ->
                CodexResponsesSocket.terminate({:error, :closed}, state)
              end)

            send(parent, {:socket_terminated, logs})
        end
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)

    {:ok, task} =
      ResponseTask.start(
        socket,
        :local_owner,
        fn _task_pid ->
          send(parent, {:execution, ExecutionIdentity.local()})
          {:socket_response_result, :owner_completion_pending, :ok}
        end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry,
        before_local_completion_handoff: fn ->
          send(parent, {:completion_held, self()})

          receive do
            :release_completion -> :ok
          end
        end
      )

    on_exit(fn -> Process.exit(task, :kill) end)
    monitor = Process.monitor(task)
    assert_receive {:execution, execution}, @detection_timeout_ms
    assert_receive {:completion_held, ^task}, @detection_timeout_ms

    {request, attempt} = receipt_fixture(auth)

    state =
      local_owner_state(auth, task, registry)
      |> put_delivery_receipt_context(task, request, attempt)
      |> Map.put(:response_task_terminals_accepted, MapSet.new([task]))
      |> Map.put(:response_task_completed_terminals, MapSet.new([task]))

    owner =
      start_supervised!({WebsocketOwnerSession, codex_session_id: state.codex_session.id, owner_lease_token: state.websocket_owner_lease_token, owner_instance_id: state.codex_session.owner_instance_id})

    assert {:ok, downstream} = WebsocketOwnerSession.attach_downstream(owner, %{pid: socket, correlation_id: "late-delivered-completion"})

    send(socket, {:terminate, %{state | websocket_owner_downstream: downstream}})
    await_post_cleanup_wait(socket, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    send(task, :release_completion)

    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, @detection_timeout_ms
    assert_receive {:socket_terminated, logs}, @detection_timeout_ms

    assert [proof] = Enum.filter(ExecutionRegistry.pending(10_000), &(&1.owner_execution_id == execution.owner_execution_id))
    assert proof.end_kind == "completed"

    assert [[receipt]] = Regex.scan(~r/websocket downstream terminal pushed [^\n]*/, logs)
    assert receipt =~ "outcome=delivered terminal_class=response.completed"
    assert Repo.get!(Attempt, attempt.id).response_metadata["downstream_delivery"]["outcome"] == "delivered"
    Logger.configure(level: previous_level)
  end

  # The owner relayed the turn's `response.completed` and the socket pushed and
  # accepted it, but the local owner task was still inside its run callback
  # (settling) when the client left, so termination acknowledged it `:aborted`
  # (findings#225 row 225-105 keeps that acknowledgement: the socket never saw
  # the task's result). The delivery receipt describes what the client
  # received, and the client received the completed terminal: it used to say
  # `aborted` (findings#225 row 225-130).
  test "a local owner task still running at termination after its completed terminal was pushed gets a delivered receipt", %{auth: auth} do
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)
    registry = start_supervised!({ActivityRegistry, name: nil})
    parent = self()

    socket =
      spawn(fn ->
        receive do
          {:terminate, state} ->
            {:ok, logs} =
              ExUnit.CaptureLog.with_log([level: :info], fn ->
                CodexResponsesSocket.terminate({:error, :closed}, state)
              end)

            send(parent, {:socket_terminated, logs})
        end
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)

    {:ok, task} =
      ResponseTask.start(
        socket,
        :local_owner,
        fn _task_pid ->
          send(parent, {:settling, self()})

          receive do
            :release_settlement -> {:socket_response_result, :owner_completion_pending, :ok}
          end
        end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry
      )

    on_exit(fn -> Process.exit(task, :kill) end)
    monitor = Process.monitor(task)
    assert_receive {:settling, ^task}, @detection_timeout_ms

    {request, attempt} = receipt_fixture(auth)

    state =
      local_owner_state(auth, task, registry)
      |> put_delivery_receipt_context(task, request, attempt)
      |> Map.put(:response_task_terminals_accepted, MapSet.new([task]))
      |> Map.put(:response_task_completed_terminals, MapSet.new([task]))

    owner =
      start_supervised!({WebsocketOwnerSession, codex_session_id: state.codex_session.id, owner_lease_token: state.websocket_owner_lease_token, owner_instance_id: state.codex_session.owner_instance_id})

    assert {:ok, downstream} = WebsocketOwnerSession.attach_downstream(owner, %{pid: socket, correlation_id: "settling-after-pushed-completion"})

    send(socket, {:terminate, %{state | websocket_owner_downstream: downstream}})
    await_post_cleanup_wait(socket, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    send(task, :release_settlement)

    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, @detection_timeout_ms
    assert_receive {:socket_terminated, logs}, @detection_timeout_ms

    receipts = Regex.scan(~r/websocket downstream terminal pushed [^\n]*/, logs)
    assert length(receipts) == 1, "expected one delivery receipt, got #{length(receipts)}"
    assert [[receipt]] = receipts
    assert receipt =~ "outcome=delivered terminal_class=response.completed"
    assert Repo.get!(Attempt, attempt.id).response_metadata["downstream_delivery"]["outcome"] == "delivered"
    Logger.configure(level: previous_level)
  end

  # A tracked (proxy) task still running when the client leaves: until it hands
  # its completion off, its registry recipient is its cancellation watcher,
  # which ignores a delivery acknowledgement outside the owner-drained flow, so
  # termination must not record a receipt for that no-op acknowledgement. The
  # task is acknowledged once, by the drain, with its real outcome, and gets
  # one receipt (findings#225, row 225-100: production logged `aborted` then
  # `delivered` for one request).
  test "a tracked task still running at termination gets one delivery receipt from the drain", %{auth: auth} do
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)
    registry = start_supervised!({ActivityRegistry, name: nil})
    parent = self()

    socket =
      spawn(fn ->
        receive do
          {:terminate, state} ->
            {:ok, logs} =
              ExUnit.CaptureLog.with_log([level: :info], fn ->
                CodexResponsesSocket.terminate({:error, :closed}, state)
              end)

            send(parent, {:socket_terminated, logs})
        end
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)

    {:ok, task} =
      ResponseTask.start(
        socket,
        :proxy,
        fn _coordinator ->
          send(parent, {:execution, ExecutionIdentity.local()})
          :ok
        end,
        fn _task_pid, _reason -> :ok end,
        activity_registry: registry,
        before_completion_handoff: fn _token, _watcher ->
          send(parent, {:completion_held, self()})

          receive do
            :release_completion -> :ok
          end
        end
      )

    on_exit(fn -> Process.exit(task, :kill) end)
    monitor = Process.monitor(task)
    assert_receive {:execution, execution}, @detection_timeout_ms
    assert_receive {:completion_held, ^task}, @detection_timeout_ms

    {request, attempt} = receipt_fixture(auth)

    state =
      local_owner_state(auth, task, registry)
      |> put_delivery_receipt_context(task, request, attempt)
      |> Map.put(:response_task_terminals_accepted, MapSet.new([task]))
      |> Map.put(:response_task_completed_terminals, MapSet.new([task]))

    owner =
      start_supervised!({WebsocketOwnerSession, codex_session_id: state.codex_session.id, owner_lease_token: state.websocket_owner_lease_token, owner_instance_id: state.codex_session.owner_instance_id})

    assert {:ok, downstream} = WebsocketOwnerSession.attach_downstream(owner, %{pid: socket, correlation_id: "tracked-running-at-close"})

    send(socket, {:terminate, %{state | websocket_owner_downstream: downstream}})
    await_post_cleanup_wait(socket, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    send(task, :release_completion)

    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, @detection_timeout_ms
    assert_receive {:socket_terminated, logs}, @detection_timeout_ms

    receipts = Regex.scan(~r/websocket downstream terminal pushed [^\n]*/, logs)
    assert length(receipts) == 1, "expected one delivery receipt, got #{length(receipts)}"
    assert [[receipt]] = receipts
    assert receipt =~ "outcome=delivered terminal_class=response.completed"

    assert [proof] = Enum.filter(ExecutionRegistry.pending(10_000), &(&1.owner_execution_id == execution.owner_execution_id))
    assert proof.end_kind == "completed"
    Logger.configure(level: previous_level)
  end

  defp assert_late_completion(auth, ordering) do
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)
    registry = start_supervised!({ActivityRegistry, name: nil})
    parent = self()

    socket =
      spawn(fn ->
        receive do
          {:terminate, state} ->
            {:ok, logs} =
              ExUnit.CaptureLog.with_log([level: :info], fn ->
                CodexResponsesSocket.terminate(:remote, state)
              end)

            send(parent, {:socket_terminated, logs})
        end
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)

    {:ok, task} = start_held_completion(socket, registry, parent, ordering)

    on_exit(fn -> Process.exit(task, :kill) end)
    monitor = Process.monitor(task)
    assert_receive {:completion_held, ^task}, @detection_timeout_ms

    {request, attempt} = receipt_fixture(auth)

    state =
      local_owner_state(auth, task, registry)
      |> put_delivery_receipt_context(task, request, attempt)

    owner =
      start_supervised!({WebsocketOwnerSession, codex_session_id: state.codex_session.id, owner_lease_token: state.websocket_owner_lease_token, owner_instance_id: state.codex_session.owner_instance_id})

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: socket,
               correlation_id: "late-local-completion"
             })

    state = %{state | websocket_owner_downstream: downstream}
    send(socket, {:terminate, state})
    await_post_cleanup_wait(socket, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    send(task, :release_completion)

    assert_receive {:DOWN, ^monitor, :process, ^task, reason}, @detection_timeout_ms
    assert reason == :normal
    assert_receive {:socket_terminated, logs}, @detection_timeout_ms
    assert length(Regex.scan(~r/websocket downstream terminal pushed/, logs)) == 1
    assert ActivityRegistry.activities(name: registry) == []
    Logger.configure(level: previous_level)
  end

  defp start_held_completion(socket, registry, parent, :both_after) do
    ResponseTask.start(
      socket,
      :local_owner,
      fn _task_pid -> {:socket_response_result, :owner_completion_pending, :ok} end,
      fn _task_pid, _reason -> :ok end,
      activity_registry: registry,
      before_local_completion_handoff: fn ->
        send(parent, {:completion_held, self()})

        receive do
          :release_completion -> :ok
        end
      end
    )
  end

  defp start_held_completion(socket, _registry, parent, :split_across_wait) do
    # Pin the legal scheduler cut between ResponseTask's consecutive activity
    # and done sends. The other case exercises the real ResponseTask producer.
    task =
      spawn(fn ->
        token = make_ref()
        send(socket, {:websocket_response_activity, self(), token})
        send(parent, {:completion_held, self()})

        receive do
          :release_completion -> :ok
        end

        send(
          socket,
          {:codex_response_done, self(), {:socket_response_result, :owner_completion_pending, :ok}}
        )

        receive do
          {:websocket_response_delivery_ack, ^token, _outcome} -> :ok
        end
      end)

    {:ok, task}
  end

  defp await_post_cleanup_wait(socket, deadline) do
    case Process.info(socket, :current_function) do
      {:current_function, {CodexResponsesSocket, :do_await_response_tasks, 5}} ->
        :ok

      other ->
        assert System.monotonic_time(:millisecond) < deadline,
               "socket did not reach the post-cleanup wait: #{inspect(other)}"

        receive do
        after
          1 -> await_post_cleanup_wait(socket, deadline)
        end
    end
  end

  defp local_owner_state(auth, task, registry) do
    local_node_string = Atom.to_string(node())

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "local-owner-termination-#{System.unique_integer([:positive])}",
               owner_instance_id: local_node_string
             })

    %{
      auth: nil,
      opts:
        RequestOptions.for_websocket(%{
          websocket_owner_response_task_drain_ms: @drain_budget_ms,
          websocket_response_task_drain_ms: @drain_budget_ms
        }),
      codex_session: session,
      websocket_owner_lease_token: session.owner_lease_token,
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 1,
        correlation_id: "corr-local-owner-termination",
        active_turn_reconnect?: false
      },
      upstream_websocket_session: nil,
      request_response_work_started?: true,
      tasks: MapSet.new([task]),
      task_monitors: %{task => Process.monitor(task)},
      queued_response_payloads: :queue.new(),
      response_task_activity_registry: registry
    }
  end

  defp put_delivery_receipt_context(state, task, request, attempt) do
    state
    |> Map.put(:direct_cleanup_receipts, %{
      task => %{
        session_id: state.codex_session.id,
        request_id: request.id,
        attempt_id: attempt.id,
        correlation_id: request.correlation_id,
        api_key_id: request.api_key_id
      }
    })
    |> Map.put(:downstream_delivery_evidence, %{
      task => %{
        frames: 2,
        terminal_class: "response.completed",
        pushed_at: DateTime.utc_now(),
        skipped?: false
      }
    })
  end

  defp receipt_fixture(%{pool: pool, api_key: api_key}) do
    %{assignment: assignment} = active_upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        transport: "websocket",
        request_metadata: %{"codex_session_id" => Ecto.UUID.generate()}
      })

    attempt =
      attempt_fixture(request, assignment, %{
        transport: "websocket",
        response_metadata: %{"upstream_websocket_connection" => %{"generation" => 1}}
      })

    {request, attempt}
  end

  defp with_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.with_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end
end
