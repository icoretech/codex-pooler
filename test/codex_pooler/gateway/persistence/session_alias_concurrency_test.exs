defmodule CodexPooler.Gateway.Persistence.SessionAliasConcurrencyTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "bootstrap continuity registration and turn-state attach do not deadlock" do
    fixture = committed_fixture!()

    try do
      for iteration <- 1..100 do
        response_id = "resp_alias_deadlock_#{iteration}"

        results =
          run_concurrently([
            fn ->
              SessionContinuity.register_codex_session_continuity(
                fixture.session,
                %{"type" => "response.create"},
                %{"id" => response_id},
                request_options(fixture.turn_state)
                |> RequestOptions.put_continuity(response_id: response_id)
              )
            end,
            fn ->
              SessionContinuity.start_codex_session_from_turn_state(
                fixture.auth,
                request_options(fixture.turn_state)
              )
            end
          ])

        assert [{:ok, :ok}, {:ok, {:ok, %CodexSession{id: session_id}}}] = results
        assert session_id == fixture.session.id
      end
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)
      end)
    end
  end

  defp committed_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      %{user: owner} = bootstrap_owner_fixture()
      pool = pool_fixture(%{created_by_user_id: owner.id})
      %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
      auth = %{pool: pool, api_key: api_key}
      turn_state = "alias-concurrency-#{System.unique_integer([:positive, :monotonic])}"
      assert {:ok, session} = Gateway.start_codex_session(auth, request_options(turn_state))
      %{auth: auth, pool: pool, session: session, turn_state: turn_state}
    end)
  end

  defp run_concurrently(operations) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn -> run_concurrent_operation(parent, barrier, operation) end)
      end)

    ready_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:alias_concurrency_ready, ^barrier, task_pid}, 5_000
        task_pid
      end)

    assert MapSet.new(ready_pids) == MapSet.new(Enum.map(tasks, & &1.pid))
    Enum.each(tasks, &send(&1.pid, {:alias_concurrency_run, barrier}))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp run_concurrent_operation(parent, barrier, operation) do
    Sandbox.unboxed_run(Repo, fn ->
      send(parent, {:alias_concurrency_ready, barrier, self()})

      receive do
        {:alias_concurrency_run, ^barrier} -> {:ok, operation.()}
      after
        5_000 -> {:error, :barrier_timeout}
      end
    end)
  end

  defp request_options(turn_state) do
    RequestOptions.for_websocket(%{
      accepted_turn_state: turn_state,
      owner_instance_id: Atom.to_string(node())
    })
  end
end
