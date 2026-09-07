defmodule CodexPooler.Dev.NativeCompletionDrainTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import CodexPoolerWeb.Runtime.AnchoredOwnerDrainSupport
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Dev.NativeCompletionDrain
  alias CodexPooler.Dev.NativePreAttemptDrain
  alias CodexPooler.Dev.NativePreAttemptDrain.Plug, as: DrainPlug
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @moduletag capture_log: true

  for release_action <- [:release, :timeout, :disarm] do
    @release_action release_action
    test "real scoped caller suspension resumes through #{@release_action}" do
      {setup, _upstream, state, release_ref} = fixture(completed_responses: [])
      on_exit(fn -> NativePreAttemptDrain.disarm() end)

      parent = self()

      state =
        if @release_action == :release do
          Map.put(state, :response_task_start_options,
            before_local_completion_handoff: fn ->
              send(parent, {:completion_handoff_waiting, self()})

              receive do
                :release_completion_handoff -> :ok
              after
                15_000 -> exit(:completion_handoff_timeout)
              end
            end
          )
        else
          state
        end

      {:ok, state} =
        CodexResponsesSocket.handle_in(
          {CodexPooler.JSON.encode!(payload(setup, metadata())), [opcode: :text]},
          state
        )

      assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid,
                      ^release_ref},
                     15_000

      state = receive_until(state, "response.output_text.delta")
      owner = state.websocket_owner_pid
      [caller] = MapSet.to_list(state.tasks)
      request_id = :sys.get_state(owner).active_turn.cleanup_witness.request_id
      caller_monitor = Process.monitor(caller)
      assert control(setup, "capture-visible").status == 200
      http_task = Task.async(fn -> control(setup, "hold-caller").status end)
      assert Task.await(http_task) == 200
      assert Process.info(caller, :status) == {:status, :suspended}
      assert NativePreAttemptDrain.status().caller_held
      assert control(setup, "begin-drain").status == 200
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      {terminal, state} = receive_until(state, {:event, "response.completed"})
      assert terminal["response"]["status"] == "completed"
      assert_receive {:websocket_owner_frame, _, _, ^caller, :complete} = complete, 15_000
      {:ok, state} = CodexResponsesSocket.handle_info(complete, state)

      assert %{
               caller_held: true,
               owner_alive: true,
               owner_terminal: true,
               durable_completed: false
             } = NativePreAttemptDrain.status()

      monitor = Process.monitor(owner)

      case @release_action do
        :release -> assert control(setup, "release-caller").status == 200
        :timeout -> send(Process.whereis(NativeCompletionDrain), :release_timeout)
        :disarm -> assert control(setup, "disarm").status == 200
      end

      if @release_action == :release,
        do: assert_receive({:completion_handoff_waiting, ^caller}, 15_000)

      state = receive_until(state, :complete)

      if @release_action == :release do
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 15_000

        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, {:shutdown, :owner_drained}},
                       15_000

        assert %{durable_completed: true, drained: true} = NativePreAttemptDrain.status()
      else
        assert Process.info(caller, :status) != {:status, :suspended}
      end

      assert Repo.get!(Request, request_id).status == "succeeded"
      assert Repo.get_by!(Attempt, request_id: request_id).status == "succeeded"
      assert Repo.get_by!(CodexTurn, request_id: request_id).status == "succeeded"
      reservation = Repo.get_by!(LedgerEntry, request_id: request_id, entry_kind: "reservation")
      release = Repo.get_by!(LedgerEntry, request_id: request_id, entry_kind: "release")
      assert Decimal.equal?(reservation.estimated_cost_micros, release.estimated_cost_micros)
      assert Repo.get_by!(LedgerEntry, request_id: request_id, entry_kind: "settlement")

      assert :ok = CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp control(setup, route) do
    conn(:post, "/#{route}", "{}")
    |> put_req_header("authorization", setup.authorization)
    |> DrainPlug.call([])
  end
end
