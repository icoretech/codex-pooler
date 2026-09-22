defmodule CodexPooler.Accounting.APIKeyPolicyReservationSerializationTest do
  # Two reservations for one key race on separate PostgreSQL sessions. Tasks that
  # share one sandbox connection cannot prove this: an advisory lock is
  # re-entrant within a session, so there the only serializer is the checkout of
  # the shared connection, never the per-key mutex under test.
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query
  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Accounting.RequestLifecycle.Reservation
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000

  setup do
    # Register ownership before any committed fixture exists; supervised actors
    # stop before this callback removes the committed rows.
    {:ok, ownership} = Agent.start(fn -> [] end)

    on_exit(fn ->
      fixtures = Agent.get(ownership, & &1)

      unboxed(fn ->
        Enum.each(fixtures, fn fixture ->
          CodexPooler.PoolerFixtures.delete_committed_pools!([fixture.pool.id])

          Repo.delete_all(from i in CodexPooler.Upstreams.Schemas.UpstreamIdentity, where: i.id == ^fixture.identity.id)
          Repo.delete_all(from p in CodexPooler.Catalog.PricingSnapshot, where: p.id == ^fixture.pricing.id)

          refute Repo.get(CodexPooler.Pools.Pool, fixture.pool.id)
          refute Repo.get(CodexPooler.Upstreams.Schemas.UpstreamIdentity, fixture.identity.id)
          refute Repo.get(CodexPooler.Catalog.PricingSnapshot, fixture.pricing.id)
        end)
      end)

      Agent.stop(ownership)
    end)

    %{ownership: ownership, supervisor: start_supervised!(Task.Supervisor)}
  end

  test "request limits serialize so two over-limit reservations cannot both succeed", context do
    fixture = fixture(context, %{max_requests_per_minute: 1, max_tokens_per_day: 1_000, max_tokens_per_week: 10_000})

    {winner, loser} = race(context, fixture, fixture.model.exposed_model_id)

    assert {:ok, _reserved} = winner
    assert {:error, %{code: :api_key_policy_limit_exceeded} = error} = loser
    assert error.message =~ "max_requests_per_minute"
    assert unboxed(fn -> recorded_reservations(fixture) end) == 1
  end

  test "token reservations near the limit cannot oversubscribe with tiny caps", context do
    fixture = fixture(context, %{max_requests_per_minute: 60, max_tokens_per_day: 512, max_tokens_per_week: 10_000})

    {winner, loser} = race(context, fixture, fixture.model.exposed_model_id)

    assert {:ok, _reserved} = winner
    assert {:error, %{code: :api_key_policy_limit_exceeded} = error} = loser
    assert error.message =~ "max_tokens_per_day"

    unboxed(fn ->
      assert recorded_reservations(fixture) == 1

      %{daily: usage} = LedgerEntries.window_usages(fixture.api_key.id, daily: DateTime.add(DateTime.utc_now(), -1, :day))
      assert usage.effective_total_tokens == 512
    end)
  end

  test "model policy reservations serialize through the same lock-time policy row", context do
    fixture = fixture(context, %{max_requests_per_minute: 60, max_tokens_per_day: 10_000, max_tokens_per_week: 10_000})
    insert_model_policy!(fixture, fixture.model.exposed_model_id, %{max_requests_per_minute: 60, max_tokens_per_day: 512, max_tokens_per_week: 10_000})

    # The binding is matched case-insensitively, so both callers lock the same row.
    {winner, loser} = race(context, fixture, String.upcase(fixture.model.exposed_model_id))

    assert {:ok, _reserved} = winner
    assert {:error, %{code: :api_key_policy_limit_exceeded} = error} = loser
    assert error.message =~ "max_tokens_per_day"
    assert unboxed(fn -> recorded_reservations(fixture) end) == 1
  end

  test "a model binding and the default binding of one key share the key-wide mutex", context do
    fixture = fixture(context, %{max_requests_per_minute: 1, max_tokens_per_day: 10_000, max_tokens_per_week: 10_000})
    insert_model_policy!(fixture, fixture.model.exposed_model_id, %{max_requests_per_minute: 1, max_tokens_per_day: 10_000, max_tokens_per_week: 10_000})
    other_model = unboxed(fn -> CodexPooler.PoolerFixtures.model_fixture(fixture.pool, %{exposed_model_id: "gpt-accounting-other"}) end)

    # Each caller locks a different binding row, so nothing but the advisory
    # mutex orders them; window limits still sum usage over the whole key.
    {winner, loser} = race(context, fixture, {fixture.model, fixture.model.exposed_model_id}, {other_model, other_model.exposed_model_id})

    assert {:ok, _reserved} = winner
    assert {:error, %{code: :api_key_policy_limit_exceeded} = error} = loser
    assert error.message =~ "max_requests_per_minute"
    assert unboxed(fn -> recorded_reservations(fixture) end) == 1
  end

  # Admission time is the dispatching node's clock while every enforcement
  # window reads the database clock under the mutex. A predecessor admitted by
  # a node whose clock runs ahead of the database is dated after the waiter's
  # window end, and must still count against it (206-25): with the holder 500 ms
  # ahead both reservations used to succeed on every limit.
  for {label, policy, message} <- [
        {"request", %{max_requests_per_minute: 1, max_tokens_per_day: 1_000, max_tokens_per_week: 10_000}, "max_requests_per_minute"},
        {"daily token", %{max_requests_per_minute: 60, max_tokens_per_day: 512, max_tokens_per_week: 10_000}, "max_tokens_per_day"},
        {"weekly token", %{max_requests_per_minute: 60, max_tokens_per_day: 10_000, max_tokens_per_week: 512}, "max_tokens_per_week"}
      ] do
    @policy policy
    @message message

    test "a predecessor dated ahead of the database clock still counts against the #{label} limit", context do
      fixture = fixture(context, @policy)
      holder_now = DateTime.add(DateTime.utc_now(), 500, :millisecond)

      {winner, loser} = race(context, fixture, {fixture.model, fixture.model.exposed_model_id, %{now: holder_now}}, {fixture.model, fixture.model.exposed_model_id, %{}})

      assert {:ok, _reserved} = winner
      assert {:error, %{code: :api_key_policy_limit_exceeded} = error} = loser
      assert error.message =~ @message
      assert unboxed(fn -> recorded_reservations(fixture) end) == 1
    end
  end

  # The holder parks inside its reservation transaction after the advisory mutex
  # and the key's reader lock; the waiter must then be observed waiting on that
  # advisory lock, on its own backend, before the holder is released.
  defp race(context, fixture, requested_model) when is_binary(requested_model),
    do: race(context, fixture, {fixture.model, requested_model}, {fixture.model, requested_model})

  defp race(context, fixture, {holder_model, holder_requested}, {waiter_model, waiter_requested}),
    do: race(context, fixture, {holder_model, holder_requested, %{}}, {waiter_model, waiter_requested, %{}})

  defp race(context, fixture, {holder_model, holder_requested, holder_opts}, {waiter_model, waiter_requested, waiter_opts}) do
    parent = self()
    release = make_ref()

    holder_task =
      actor(context, fn ->
        send(parent, {:holder_backend, backend_pid()})
        Process.put({Reservation, :runtime_authorization_barrier}, {parent, release, {:reserve, :after}})
        reserve(fixture, holder_model, holder_requested, holder_opts)
      end)

    assert_receive {:runtime_authorization_barrier, ^release, :reserve, :after, holder}, @detection_budget
    assert_receive {:holder_backend, holder_backend}, @detection_budget

    waiter_task =
      actor(context, fn ->
        send(parent, {:waiter_backend, backend_pid()})
        reserve(fixture, waiter_model, waiter_requested, waiter_opts)
      end)

    assert_receive {:waiter_backend, waiter_backend}, @detection_budget
    refute waiter_backend == holder_backend
    assert unboxed(fn -> await_blocker(waiter_task, waiter_backend, holder_backend) end) == [[holder_backend, "advisory", false]]

    send(holder, {:runtime_authorization_release, release})
    winner = Task.await(holder_task, @detection_budget)
    loser = Task.await(waiter_task, @detection_budget)

    {winner, loser}
  end

  defp fixture(context, default_policy) do
    unboxed(fn ->
      {:ok, fixture} =
        Repo.transaction(fn ->
          fixture = accounting_setup()
          update_default_policy!(fixture.api_key, default_policy)
          Agent.update(context.ownership, &[fixture | &1])
          fixture
        end)

      fixture
    end)
  end

  defp insert_model_policy!(fixture, model_identifier, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    unboxed(fn ->
      Repo.insert!(
        struct!(
          APIKeyPolicyBinding,
          Map.merge(attrs, %{api_key_id: fixture.api_key.id, binding_scope: "model", model_identifier: model_identifier, status: "active", created_at: now, updated_at: now})
        )
      )
    end)
  end

  defp reserve(fixture, model, requested_model, opts),
    do: Accounting.reserve(fixture.auth, model, %{"model" => requested_model, "max_output_tokens" => 1}, Map.put(opts, :correlation_id, Ecto.UUID.generate()))

  defp recorded_reservations(fixture) do
    Repo.aggregate(
      from(e in LedgerEntry, where: e.api_key_id == ^fixture.api_key.id and e.entry_kind == "reservation" and e.amount_status == "recorded"),
      :count
    )
  end

  defp backend_pid do
    [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
    pid
  end

  defp actor(context, fun), do: Task.Supervisor.async_nolink(context.supervisor, fn -> unboxed(fun) end)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp await_blocker(waiter_task, waiter, holder), do: await_blocker(waiter_task, waiter, holder, System.monotonic_time(:millisecond) + @detection_budget)

  # A waiter that finishes while the holder is still parked was never
  # serialized by it, so that fails at once instead of at the deadline.
  defp await_blocker(waiter_task, waiter, holder, deadline) do
    rows =
      Repo.query!(
        """
        SELECT blocker, locks.locktype, locks.granted
        FROM unnest(pg_blocking_pids($1)) AS blocker
        JOIN pg_locks AS locks ON locks.pid = $1 AND NOT locks.granted
        WHERE blocker = $2
        """,
        [waiter, holder]
      ).rows

    cond do
      rows != [] -> rows
      not Process.alive?(waiter_task.pid) -> flunk("the waiter completed while the holder still held the key's reservation mutex")
      System.monotonic_time(:millisecond) < deadline -> await_blocker(waiter_task, waiter, holder, deadline)
      true -> flunk("the waiter was never observed blocked on the holder's advisory lock")
    end
  end
end
