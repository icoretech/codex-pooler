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
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.ResponseTask
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

  defp local_owner_state(auth, task, registry) do
    local_node_string = Atom.to_string(node())

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state:
                 "local-owner-termination-#{System.unique_integer([:positive])}",
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
