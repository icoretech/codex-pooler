defmodule CodexPooler.Gateway.Persistence.SessionAliasConcurrencyTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures, only: [reset_bootstrap_state_fixture!: 0]
  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture
  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "bootstrap continuity registration and turn-state attach do not deadlock" do
    fixture = committed_fixture!()

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
  end

  # Registered, never scoped. `run_concurrently/1` drives the body through linked tasks, so a
  # Postgrex error inside one of them kills the untrapped test process and a `try/after` never
  # runs; an ExUnit timeout kill loses it the same way. The pool is the whole committed graph
  # -- api key, codex session, owner lease and alias rows all cascade from it -- and nothing
  # here needs an owner, so the fixture no longer completes the `platform_bootstrap_state`
  # singleton for a shared `owner@example.com`. Keying the cleanup on the slug and registering
  # it before the commit also covers a fixture that fails partway through.
  # `api_key_fixture/2` also commits an instance owner of its own when the instance has none,
  # and that user is outside the pool's cascade, so the reset below removes it: deleting only
  # the pool would leave a `users` row behind and break the suites that assert absolute user
  # counts.
  defp committed_fixture! do
    slug = "alias-concurrency-#{System.unique_integer([:positive, :monotonic])}"
    register_unboxed_cleanup!(fn -> delete_committed_fixture!(slug) end)

    run_unboxed(fn ->
      pool = pool_fixture(%{slug: slug})
      %{api_key: api_key} = active_api_key_fixture(pool, %{})
      auth = %{pool: pool, api_key: api_key}
      assert {:ok, session} = Gateway.start_codex_session(auth, request_options(slug))
      %{auth: auth, pool: pool, session: session, turn_state: slug}
    end)
  end

  defp delete_committed_fixture!(slug) do
    Repo.delete_all(from pool in Pool, where: pool.slug == ^slug)
    reset_bootstrap_state_fixture!()
    :ok
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
