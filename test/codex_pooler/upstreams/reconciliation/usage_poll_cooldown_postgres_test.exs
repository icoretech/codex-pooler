defmodule CodexPooler.Upstreams.Reconciliation.UsagePollCooldownPostgresTest do
  use CodexPooler.DataCase, async: false

  import Ecto.Query

  alias CodexPooler.PoolerFixtures
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  @await_ms 15_000

  # The whole point of putting the pause in committed state is that the replica
  # that was not told about it still honors it. A sandboxed transaction cannot
  # show that, so these run on real independent sessions.

  test "a pause committed on one session is the pause every other session reads, and the longest one wins" do
    fixture = committed_identity!()
    on_exit(fn -> cleanup!(fixture) end)

    origin = UsagePollCooldown.origin_key("https://usage.example.test/backend-api/codex/usage")
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    long = DateTime.add(as_of, 7_200, :second)
    short = DateTime.add(as_of, 60, :second)

    results =
      [long, short]
      |> Enum.map(fn deadline ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            UsagePollCooldown.record(fixture.identity_id, 1, origin, 429, deadline, as_of)
          end)
        end)
      end)
      |> Task.await_many(@await_ms)

    # Both writers committed; the row lock serialized them in some order.
    assert Enum.all?(results, &match?({:ok, %DateTime{}}, &1)), inspect(results)

    # A third session - the replica that never saw either response - reads the
    # longer pause, whichever order the two writers landed in.
    assert Sandbox.unboxed_run(Repo, fn ->
             UsagePollCooldown.admit_current(fixture.identity_id, 1, origin, as_of)
           end) == {:deferred, long}

    # A later successful read writes nothing, so it cannot clear the pause.
    assert Sandbox.unboxed_run(Repo, fn ->
             UsagePollCooldown.admit_current(
               fixture.identity_id,
               1,
               origin,
               DateTime.add(as_of, 120, :second)
             )
           end) == {:deferred, long}
  end

  test "a credential replaced between the response and the write leaves the new credential unpaused" do
    fixture = committed_identity!()
    on_exit(fn -> cleanup!(fixture) end)

    origin = UsagePollCooldown.origin_key("https://usage.example.test/backend-api/codex/usage")
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    not_before = DateTime.add(as_of, 3_600, :second)

    # The throttled response was for epoch 1. Another session replaces the
    # credential before the write lands.
    Sandbox.unboxed_run(Repo, fn ->
      identity = Repo.get!(UpstreamIdentity, fixture.identity_id)

      identity
      |> Ecto.Changeset.change(metadata: Map.put(identity.metadata || %{}, "credential_epoch", 2))
      |> Repo.update!()
    end)

    assert Sandbox.unboxed_run(Repo, fn ->
             UsagePollCooldown.record(fixture.identity_id, 1, origin, 429, not_before, as_of)
           end) == {:error, :stale_credential_epoch}

    # The credential we now hold was never throttled, so it reads freely.
    assert Sandbox.unboxed_run(Repo, fn ->
             UsagePollCooldown.admit_current(fixture.identity_id, 2, origin, as_of)
           end) == :ok
  end

  # findings#259: the operator's clear takes the same identity row lock as
  # record/6, so the two serialize. Whatever committed before the clear is
  # removed with it; whatever commits after it applies as it would on an account
  # that was never paused - a shorter pause included, because nothing is left to
  # merge it with. Without a clear, a shorter one never shortens a longer one.

  test "a pause committed while a clear waits on the identity row is removed with it" do
    fixture = committed_identity!()
    on_exit(fn -> cleanup!(fixture) end)

    origin = UsagePollCooldown.origin_key("https://usage.example.test/backend-api/codex/usage")
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    short = DateTime.add(as_of, 600, :second)
    long = DateTime.add(as_of, 3 * 86_400, :second)

    assert {:ok, ^short} = unboxed(fn -> UsagePollCooldown.record(fixture.identity_id, 1, origin, 429, short, as_of) end)

    {:ok, clear} =
      unboxed(fn ->
        Repo.transaction(fn ->
          holder = lock_row!(fixture.identity_id)
          clear = start_blocked(fixture.identity_id, holder, fn -> UsagePollCooldown.clear(fixture.identity_id, as_of) end)

          # The provider asks for three days while the operator's clear waits.
          assert {:ok, ^long} = UsagePollCooldown.record(fixture.identity_id, 1, origin, 503, long, as_of)
          clear
        end)
      end)

    assert {:ok, {%UpstreamIdentity{}, [%{not_before: ^long, status_code: 503}]}} = Task.await(clear, @await_ms)
    assert unboxed(fn -> UsagePollCooldown.admit_current(fixture.identity_id, 1, origin, as_of) end) == :ok
  end

  test "a shorter pause recorded after a clear applies in full, and a longer one after it applies too" do
    fixture = committed_identity!()
    on_exit(fn -> cleanup!(fixture) end)

    origin = UsagePollCooldown.origin_key("https://usage.example.test/backend-api/codex/usage")
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    week = DateTime.add(as_of, 7 * 86_400, :second)
    hour = DateTime.add(as_of, 3_600, :second)
    days = DateTime.add(as_of, 3 * 86_400, :second)

    assert {:ok, ^week} = unboxed(fn -> UsagePollCooldown.record(fixture.identity_id, 1, origin, 429, week, as_of) end)

    # Control: without a clear, the shorter instruction leaves the week alone.
    assert {:ok, ^week} = unboxed(fn -> UsagePollCooldown.record(fixture.identity_id, 1, origin, 429, hour, as_of) end)
    assert unboxed(fn -> UsagePollCooldown.admit_current(fixture.identity_id, 1, origin, as_of) end) == {:deferred, week}

    {:ok, record} =
      unboxed(fn ->
        Repo.transaction(fn ->
          holder = lock_row!(fixture.identity_id)

          record =
            start_blocked(fixture.identity_id, holder, fn ->
              UsagePollCooldown.record(fixture.identity_id, 1, origin, 429, hour, as_of)
            end)

          # The operator's clear commits first; the provider's hour lands after it.
          assert {:ok, {_identity, [%{not_before: ^week}]}} = UsagePollCooldown.clear(fixture.identity_id, as_of)
          record
        end)
      end)

    assert {:ok, ^hour} = Task.await(record, @await_ms)
    assert unboxed(fn -> UsagePollCooldown.admit_current(fixture.identity_id, 1, origin, as_of) end) == {:deferred, hour}

    # A longer instruction after that is honoured normally.
    assert {:ok, ^days} = unboxed(fn -> UsagePollCooldown.record(fixture.identity_id, 1, origin, 503, days, as_of) end)
    assert unboxed(fn -> UsagePollCooldown.admit_current(fixture.identity_id, 1, origin, as_of) end) == {:deferred, days}
  end

  defp lock_row!(identity_id) do
    Repo.query!("SELECT id FROM upstream_identities WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(identity_id)])
    %{rows: [[holder_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    holder_pid
  end

  # Starts `fun` on its own backend and returns once PostgreSQL reports that
  # backend blocked by the holder, so what the holder does next is ordered
  # before `fun` can take the row.
  defp start_blocked(identity_id, holder_pid, fun) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[waiter_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {ref, waiter_pid})
          fun.()
        end)
      end)

    assert_receive {^ref, waiter_pid}, @await_ms
    await_blocked!(waiter_pid, holder_pid, identity_id, System.monotonic_time(:millisecond) + @await_ms)
    task
  end

  defp await_blocked!(waiter_pid, holder_pid, identity_id, deadline) do
    # Asked on the holder's own backend, which the caller's transaction owns.
    %{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [waiter_pid])

    cond do
      holder_pid in blockers ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{waiter_pid} never waited on #{holder_pid} for identity #{identity_id}")

      true ->
        await_blocked!(waiter_pid, holder_pid, identity_id, deadline)
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp committed_identity! do
    Sandbox.unboxed_run(Repo, fn ->
      pool = PoolerFixtures.pool_fixture()

      %{identity: identity} =
        PoolerFixtures.active_upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct_cooldown_pg_#{System.unique_integer([:positive])}"
        })

      %{identity_id: identity.id, pool_id: pool.id}
    end)
  end

  defp cleanup!(%{identity_id: identity_id, pool_id: pool_id}) do
    Sandbox.unboxed_run(Repo, fn ->
      PoolerFixtures.delete_committed_pools!([pool_id])
      Repo.delete_all(from(identity in UpstreamIdentity, where: identity.id == ^identity_id))
    end)
  end
end
