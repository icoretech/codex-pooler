defmodule CodexPoolerWeb.CodexResponsesSocketErrorFrameReceiptTest do
  # The receipt of a turn whose task never registered a delivery activity (a
  # local owner turn) is recorded with the gateway result; when that result is
  # the socket's own error frame, Bandit writes the frame only after the
  # callback that pushes it returned. The receipt used to be recorded in that
  # callback, so a failure of that very write was never seen and the receipt
  # said `delivered error` for an error the client never got (findings#232 row
  # 232-263). It is now recorded at the next callback or at termination, after
  # the write. The test process plays the connection process: it runs the
  # callbacks and reports the write's failure as ThousandIsland does, with a
  # `[:thousand_island, :connection, :send_error]` event in that process.
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures,
    only: [active_api_key_fixture: 0, active_upstream_assignment_fixture: 1, request_fixture: 2, attempt_fixture: 3]

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketDownstreamWriteWatch

  @send_error [:thousand_island, :connection, :send_error]
  @delta ~s({"type":"response.output_text.delta","delta":"synthetic delta"})
  @error %{status: 502, code: :upstream_failed, message: "safe failure", param: nil}

  setup do
    :ok = WebsocketDownstreamWriteWatch.watch()
    task_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(task_pid, :stop) end)
    {request, attempt, session_id} = receipt_fixture()
    %{task_pid: task_pid, attempt: attempt, state: socket_state(task_pid, request, attempt, session_id)}
  end

  test "a failed write of the socket's own error frame records what was written before it", %{task_pid: task_pid, attempt: attempt, state: state} do
    state = push_delta!(state, task_pid)
    {:push, {:text, _error_frame}, state} = CodexResponsesSocket.handle_info({:codex_response_done, task_pid, {:error, @error}}, state)
    # Bandit's write of the error frame fails.
    send_error(:timeout)

    assert {:ok, _state} = next_callback(state)

    assert %{"outcome" => "aborted", "terminal_class" => "none", "frames_after_visible" => 1, "highest_frame_class" => "delta", "write_failure" => "timeout", "pushed_at" => nil} =
             receipt(attempt)
  end

  test "a written error frame records a delivered error terminal at the next callback", %{task_pid: task_pid, attempt: attempt, state: state} do
    state = push_delta!(state, task_pid)
    {:push, {:text, _error_frame}, state} = CodexResponsesSocket.handle_info({:codex_response_done, task_pid, {:error, @error}}, state)

    assert {:ok, _state} = next_callback(state)

    assert %{"outcome" => "delivered", "terminal_class" => "error", "frames_after_visible" => 1, "highest_frame_class" => "terminal"} = receipt = receipt(attempt)
    refute Map.has_key?(receipt, "write_failure")

    # The socket sent itself a message so that a next callback comes even on
    # an otherwise idle connection; handling it records nothing twice.
    assert_received {CodexResponsesSocket, :error_frame_written} = message
    assert {:ok, _state} = CodexResponsesSocket.handle_info(message, state)
    assert Repo.get!(Attempt, attempt.id).response_metadata["downstream_delivery"] == receipt
  end

  test "a socket that terminates after a failed write of its error frame records what was written before it", %{task_pid: task_pid, attempt: attempt, state: state} do
    state = push_delta!(state, task_pid)
    {:push, {:text, _error_frame}, state} = CodexResponsesSocket.handle_info({:codex_response_done, task_pid, {:error, @error}}, state)
    send_error(:closed)

    assert :ok = CodexResponsesSocket.terminate(:normal, state)

    assert %{"outcome" => "aborted", "terminal_class" => "none", "frames_after_visible" => 1, "write_failure" => "closed"} = receipt(attempt)
  end

  # The chunk is pushed by one callback and written by Bandit before the next.
  defp push_delta!(state, task_pid) do
    {:push, {:text, @delta}, state} = CodexResponsesSocket.handle_info({:codex_response_chunk, task_pid, @delta}, state)
    state
  end

  # Whatever the socket handles next.
  defp next_callback(state), do: CodexResponsesSocket.handle_info(:synthetic_unrelated_message, state)

  defp send_error(reason), do: :telemetry.execute(@send_error, %{data: "synthetic frame bytes", error: reason, monotonic_time: 0}, %{})

  defp receipt(%Attempt{id: id}), do: Repo.get!(Attempt, id).response_metadata["downstream_delivery"]

  defp socket_state(task_pid, request, attempt, session_id) do
    %{
      opts: RequestOptions.for_websocket(%{}),
      codex_session: %{id: session_id},
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      response_task_results_ready: MapSet.new(),
      response_task_terminals_accepted: MapSet.new(),
      native_turn_output_task_pids: MapSet.new(),
      direct_cleanup_receipts: %{
        task_pid => %{
          session_id: session_id,
          request_id: request.id,
          attempt_id: attempt.id,
          correlation_id: request.correlation_id,
          api_key_id: request.api_key_id
        }
      }
    }
  end

  defp receipt_fixture do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = active_upstream_assignment_fixture(pool)
    session_id = Ecto.UUID.generate()
    request = request_fixture(%{pool: pool, api_key: api_key}, %{transport: "websocket", request_metadata: %{"codex_session_id" => session_id}})
    attempt = attempt_fixture(request, assignment, %{transport: "websocket", response_metadata: %{}})
    {request, attempt, session_id}
  end
end
