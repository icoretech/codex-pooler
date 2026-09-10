defmodule CodexPooler.Gateway.Persistence.TurnCompletionLockOrderTest do
  @moduledoc """
  Real-PostgreSQL proof that completing a turn acquires the session row before
  the turn row, matching every session-first path (owner binding, replay,
  interruption). Production deadlocked between a completion that updated the
  turn first and a session-first path locking the turn by session and request.
  """

  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @pause_context {__MODULE__, :pause_context}

  @tag timeout: 60_000
  test "turn completion locks the session before the turn so session-first paths cannot deadlock" do
    fixture = unboxed_completion_fixture()
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end) end)

    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :repo, :query],
      &__MODULE__.pause_after_turn_update/4,
      %{parent: parent, ref: ref}
    )

    try do
      completion =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Process.put(@pause_context, {parent, ref})
            send(parent, {:completion_ready, ref, backend_pid!()})

            receive do
              {:completion_run, ^ref} -> :ok
            after
              10_000 -> raise "completion start timed out"
            end

            safely(fn ->
              SessionContinuity.complete_codex_turn(
                {:ok, %{request: fixture.request, attempt: fixture.attempt}},
                "succeeded",
                nil,
                fixture.attempt,
                nil
              )
            end)
          end)
        end)

      assert_receive {:completion_ready, ^ref, completion_backend}, 10_000
      send(completion.pid, {:completion_run, ref})

      # The completion now holds whatever it locked before writing the turn row.
      assert_receive {:completion_paused, ^ref}, 15_000

      session_first =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:session_first_ready, ref, backend_pid!()})

            safely(fn ->
              Repo.transaction(fn ->
                _session =
                  Repo.one!(
                    from session in CodexSession,
                      where: session.id == ^fixture.session_id,
                      lock: "FOR UPDATE"
                  )

                _turn =
                  Repo.one!(
                    from turn in CodexTurn,
                      where:
                        turn.codex_session_id == ^fixture.session_id and
                          turn.request_id == ^fixture.request.id,
                      lock: "FOR UPDATE"
                  )

                :locked
              end)
            end)
          end)
        end)

      assert_receive {:session_first_ready, ^ref, session_first_backend}, 10_000
      blocked_relation = await_block!(session_first_backend, completion_backend)

      send(completion.pid, {:completion_release, ref})

      assert {:ok, {:ok, %{request: _request}}} = Task.await(completion, 15_000)
      assert {:ok, {:ok, :locked}} = Task.await(session_first, 15_000)

      # The session-first path waited on the session, never on the turn: the
      # completion had already taken the session row before touching the turn.
      assert blocked_relation == "codex_sessions"
    after
      :telemetry.detach(handler_id)
    end

    turn =
      Sandbox.unboxed_run(Repo, fn -> Repo.get_by!(CodexTurn, request_id: fixture.request.id) end)

    assert turn.status == "succeeded"
    assert turn.final_attempt_id == fixture.attempt.id
  end

  @doc false
  def pause_after_turn_update(_event, _measurements, %{query: query}, %{parent: parent, ref: ref}) do
    with {^parent, ^ref} <- Process.get(@pause_context),
         true <- String.starts_with?(query, ~s(UPDATE "codex_turns")) do
      Process.delete(@pause_context)
      send(parent, {:completion_paused, ref})

      receive do
        {:completion_release, ^ref} -> :ok
      after
        15_000 -> :ok
      end
    else
      _other -> :ok
    end
  end

  defp await_block!(waiter_backend, blocker_backend, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    observation =
      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(
          Repo,
          "SELECT query FROM pg_stat_activity WHERE pid = $1 AND $2 = ANY(pg_blocking_pids(pid))",
          [waiter_backend, blocker_backend]
        ).rows
      end)

    case observation do
      [[query] | _rest] ->
        case Regex.run(~r/FROM "(\w+)"/, query) do
          [_match, relation] -> relation
          nil -> flunk("blocked statement did not name a relation")
        end

      [] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("session-first transaction never blocked on the completion")
        else
          Process.sleep(50)
          await_block!(waiter_backend, blocker_backend, deadline)
        end
    end
  end

  defp unboxed_completion_fixture do
    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture()
      pool = pool_fixture(%{created_by_user_id: owner.id})
      %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
      auth = %{pool: pool, api_key: api_key}
      %{assignment: assignment} = upstream_assignment_fixture(pool)

      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 accepted_turn_state:
                   "turn-completion-lock-order-#{System.unique_integer([:positive, :monotonic])}",
                 owner_instance_id: "node-a"
               })

      request =
        request_fixture(auth, %{
          status: "in_progress",
          completed_at: nil,
          transport: "websocket",
          usage_status: "usage_pending"
        })

      assert {:ok, %CodexTurn{}} =
               SessionContinuity.start_codex_turn(
                 session,
                 request,
                 RequestOptions.for_websocket(%{})
               )

      attempt =
        attempt_fixture(request, assignment, %{
          status: "in_progress",
          completed_at: nil,
          transport: "websocket"
        })

      %{session_id: session.id, request: request, attempt: attempt}
    end)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp safely(operation) do
    {:ok, operation.()}
  rescue
    exception -> {:error, exception.__struct__, Exception.message(exception)}
  end
end
