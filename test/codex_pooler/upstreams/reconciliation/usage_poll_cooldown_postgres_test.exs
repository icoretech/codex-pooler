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
