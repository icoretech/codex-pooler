defmodule CodexPooler.Gateway.Persistence.HttpOwnerLeaseLockingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures, only: [reset_bootstrap_state_fixture!: 0]
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, SessionContinuity}
  alias Ecto.Adapters.SQL.Sandbox

  test "renewal blocked on the session row checks expiry after obtaining its locks" do
    {session, opts} =
      Sandbox.unboxed_run(Repo, fn ->
        reset_bootstrap_state_fixture!()
        %{pool: pool, api_key: api_key} = active_api_key_fixture()

        opts =
          RequestOptions.build(
            %{session_header: Ecto.UUID.generate(), bridge_owner_lease_ttl_seconds: 1},
            "/backend-api/codex/responses",
            %{}
          )

        {:ok, session} =
          SessionContinuity.start_codex_session(%{pool: pool, api_key: api_key}, opts)

        {session, opts}
      end)

    parent = self()

    blocker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from s in CodexSession, where: s.id == ^session.id, lock: "FOR UPDATE")
            send(parent, :row_locked)

            receive do
              :unlock -> :ok
            end
          end)
        end)
      end)

    assert_receive :row_locked

    renewal =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:renewal_backend, pid})
          SessionContinuity.renew_owner_token(session, session.owner_lease_token, opts)
        end)
      end)

    try do
      assert_receive {:renewal_backend, backend}
      await_blocked(backend, 100)

      remaining =
        max(DateTime.diff(session.owner_lease_expires_at, DateTime.utc_now(), :millisecond), 0)

      Process.sleep(remaining + 100)
      send(blocker.pid, :unlock)
      Task.await(blocker)
      assert {:error, :owner_unavailable} = Task.await(renewal)

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.reload!(session) == session

        assert Repo.get_by!(BridgeOwnerLease, codex_session_id: session.id).expires_at ==
                 session.owner_lease_expires_at
      end)
    after
      send(blocker.pid, :unlock)
      Task.shutdown(blocker, :brutal_kill)
      Task.shutdown(renewal, :brutal_kill)
      Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end)
    end
  end

  defp await_blocked(_backend, 0), do: flunk("renewal never waited on the session row lock")

  defp await_blocked(backend, retries) do
    blocked? =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[blocked?]]} =
          Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

        blocked?
      end)

    unless blocked? do
      Process.sleep(10)
      await_blocked(backend, retries - 1)
    end
  end
end
