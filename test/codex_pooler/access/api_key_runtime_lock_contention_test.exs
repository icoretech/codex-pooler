defmodule CodexPooler.Access.APIKeyRuntimeLockContentionTest do
  @moduledoc """
  Real-PostgreSQL contract for the `api_keys` reader lock (`FOR SHARE`) taken
  by read-only runtime transactions. Same-key readers hold the row together,
  foreign-key checks never wait on them, and a status change waits for every
  reader still holding the row, so nothing is admitted against the
  pre-revocation epoch once the revocation commits.

  Fixtures are committed through unboxed connections, so every participant runs
  on its own PostgreSQL backend. A wait that must not happen surfaces as a
  bounded `lock_timeout` instead of a hang.
  """

  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Accounts.Scope
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :api_key_runtime_lock_contention
  @moduletag timeout: 60_000

  # A statement that waits on another backend's row lock fails with
  # `lock_not_available` after this bound, so a regression to the writer lock
  # fails the case instead of hanging it.
  @no_wait_lock_timeout_ms 1_000
  @detection_budget_ms 15_000
  @participants {__MODULE__, :participants}

  setup do
    fixture = unboxed_api_key_fixture()
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end) end)
    %{fixture: fixture}
  end

  test "same-key runtime readers hold the api_keys row at the same time", %{fixture: fixture} do
    try do
      holder = hold_reader_lock!(fixture)

      {backend, result} =
        run_without_lock_wait(fn ->
          Access.authorize_api_key_runtime_turn_for_read(fixture.api_key.id, 0)
        end)

      assert backend != holder.backend
      assert {:ok, %{api_key: %APIKey{id: api_key_id}, runtime_revocation_epoch: 0}} = result
      assert api_key_id == fixture.api_key.id
      assert backend_state(holder.backend) == "idle in transaction"
      assert release!(holder) == {:ok, :released}
    after
      shutdown_participants()
    end
  end

  test "a foreign-key child insert does not wait on runtime readers", %{fixture: fixture} do
    try do
      holder = hold_reader_lock!(fixture)

      {backend, session} = run_without_lock_wait(fn -> insert_dashboard_session!(fixture) end)

      assert backend != holder.backend
      assert %APIKeyDashboardSession{api_key_id: api_key_id} = session
      assert api_key_id == fixture.api_key.id
      assert backend_state(holder.backend) == "idle in transaction"
      assert release!(holder) == {:ok, :released}
    after
      shutdown_participants()
    end
  end

  test "a runtime reader does not wait on a reservation holding the key-wide mutex", %{
    fixture: fixture
  } do
    try do
      holder = hold_reservation_lock!(fixture)

      {backend, locked} =
        run_without_lock_wait(fn -> Access.lock_api_key_for_read(fixture.api_key.id) end)

      assert backend != holder.backend
      assert %APIKey{id: api_key_id, status: "active"} = locked
      assert api_key_id == fixture.api_key.id
      assert release!(holder) == {:ok, :released}
    after
      shutdown_participants()
    end
  end

  test "a foreign-key child insert does not wait on a reservation", %{fixture: fixture} do
    try do
      holder = hold_reservation_lock!(fixture)

      {backend, session} = run_without_lock_wait(fn -> insert_dashboard_session!(fixture) end)

      assert backend != holder.backend
      assert %APIKeyDashboardSession{api_key_id: api_key_id} = session
      assert api_key_id == fixture.api_key.id
      assert release!(holder) == {:ok, :released}
    after
      shutdown_participants()
    end
  end

  test "a second same-key reservation waits for the key-wide mutex", %{fixture: fixture} do
    try do
      holder = hold_reservation_lock!(fixture)

      assert :lock_not_available =
               expect_lock_wait(fn ->
                 Access.authorize_api_key_runtime_turn(fixture.api_key.id, 0)
               end)

      assert release!(holder) == {:ok, :released}

      # The mutex is released with the holder's transaction, so the next
      # reservation of the same key authorizes without waiting.
      {_backend, result} =
        run_without_lock_wait(fn ->
          Access.authorize_api_key_runtime_turn(fixture.api_key.id, 0)
        end)

      assert {:ok, %{runtime_revocation_epoch: 0}} = result
    after
      shutdown_participants()
    end
  end

  test "a revocation waits for a reservation still holding the key", %{fixture: fixture} do
    try do
      holder = hold_reservation_lock!(fixture)
      revocation = start_revocation!(fixture)

      assert await_waiting_on!(revocation.backend, holder.backend) == "api_keys"
      assert %APIKey{status: "active", runtime_revocation_epoch: 0} = committed_api_key(fixture)
      assert release!(holder) == {:ok, :released}

      assert {:ok, %APIKey{status: "revoked", runtime_revocation_epoch: 1}} =
               Task.await(revocation.task, @detection_budget_ms)
    after
      shutdown_participants()
    end
  end

  test "a revocation waits for every reader holding the row and later authorizations are rejected",
       %{fixture: fixture} do
    try do
      first = hold_reader_lock!(fixture)
      revocation = start_revocation!(fixture)

      assert await_waiting_on!(revocation.backend, first.backend) == "api_keys"

      # A reader arriving while the revocation waits does not queue behind it. It
      # still observes the pre-revocation epoch because the revocation has not
      # committed, and the revocation then waits for this reader as well.
      late = hold_reader_lock!(fixture)
      assert release!(first) == {:ok, :released}
      assert await_waiting_on!(revocation.backend, late.backend) == "api_keys"
      assert %APIKey{status: "active", runtime_revocation_epoch: 0} = committed_api_key(fixture)

      assert release!(late) == {:ok, :released}

      assert {:ok, %APIKey{status: "revoked", runtime_revocation_epoch: 1}} =
               Task.await(revocation.task, @detection_budget_ms)

      # Every authorization that starts after the commit observes the new epoch,
      # whichever lock mode it takes.
      for authorize <- [
            &Access.authorize_api_key_runtime_turn_for_read/2,
            &Access.authorize_api_key_runtime_turn/2
          ] do
        {_backend, result} = run_without_lock_wait(fn -> authorize.(fixture.api_key.id, 0) end)
        assert {:error, %{code: :api_key_revoked, disabling_epoch: 1}} = result
      end
    after
      shutdown_participants()
    end
  end

  defp hold_reservation_lock!(fixture) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> reservation_holder(parent, ref, fixture.api_key.id) end)
      end)

    track_participant(%{task: task, ref: ref})
    assert_receive {:reservation_started, ^ref, backend}, @detection_budget_ms

    receive do
      {:reservation_holding, ^ref, authorization} ->
        assert {:ok, %{runtime_revocation_epoch: 0}} = authorization
        %{task: task, ref: ref, backend: backend}
    after
      @detection_budget_ms -> flunk("the reservation holder did not report its locks")
    end
  end

  defp reservation_holder(parent, ref, api_key_id) do
    Repo.transaction(fn ->
      set_no_wait_lock_timeout!()
      send(parent, {:reservation_started, ref, backend_pid!()})

      send(
        parent,
        {:reservation_holding, ref, Access.authorize_api_key_runtime_turn(api_key_id, 0)}
      )

      receive do
        {:release_participant, ^ref} -> :released
      after
        @detection_budget_ms -> raise "the reservation holder was not released"
      end
    end)
  end

  defp expect_lock_wait(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        set_no_wait_lock_timeout!()
        fun.()
        flunk("the statement did not wait for the key-wide reservation mutex")
      end)
    end)
  rescue
    error in Postgrex.Error ->
      if lock_not_available?(error), do: :lock_not_available, else: reraise(error, __STACKTRACE__)
  end

  defp hold_reader_lock!(fixture) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> reader_holder(parent, ref, fixture.api_key.id) end)
      end)

    track_participant(%{task: task, ref: ref})
    assert_receive {:reader_started, ^ref, backend}, @detection_budget_ms

    receive do
      {:reader_holding, ^ref, locked} ->
        assert %APIKey{status: "active", runtime_revocation_epoch: 0} = locked
        %{task: task, ref: ref, backend: backend}

      {:reader_waited, ^ref} ->
        flunk("an api_keys reader waited on another transaction's row lock")
    after
      @detection_budget_ms -> flunk("the api_keys reader did not report its lock")
    end
  end

  defp reader_holder(parent, ref, api_key_id) do
    Repo.transaction(fn ->
      set_no_wait_lock_timeout!()
      send(parent, {:reader_started, ref, backend_pid!()})
      send(parent, {:reader_holding, ref, Access.lock_api_key_for_read(api_key_id)})

      receive do
        {:release_participant, ^ref} -> :released
      after
        @detection_budget_ms -> raise "the api_keys reader holder was not released"
      end
    end)
  rescue
    error in Postgrex.Error ->
      if lock_not_available?(error) do
        send(parent, {:reader_waited, ref})
        {:error, :lock_not_available}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp start_revocation!(fixture) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, {:revocation_started, ref, backend_pid!()})
          Access.revoke_api_key(fixture.scope, fixture.api_key.id)
        end)
      end)

    track_participant(%{task: task, ref: ref})
    assert_receive {:revocation_started, ^ref, backend}, @detection_budget_ms
    %{task: task, ref: ref, backend: backend}
  end

  defp release!(%{task: task, ref: ref}) do
    send(task.pid, {:release_participant, ref})
    Task.await(task, @detection_budget_ms)
  end

  defp run_without_lock_wait(fun) do
    Sandbox.unboxed_run(Repo, fn -> bounded_transaction(fun) end)
  end

  defp bounded_transaction(fun) do
    {:ok, observed} =
      Repo.transaction(fn ->
        set_no_wait_lock_timeout!()
        {backend_pid!(), fun.()}
      end)

    observed
  rescue
    error in Postgrex.Error ->
      if lock_not_available?(error),
        do: flunk("the statement waited on a runtime reader's api_keys row lock"),
        else: reraise(error, __STACKTRACE__)
  end

  defp insert_dashboard_session!(fixture) do
    token_digest = :crypto.hash(:sha256, "lock-contention-#{System.unique_integer([:positive])}")

    %APIKeyDashboardSession{api_key_id: fixture.api_key.id}
    |> APIKeyDashboardSession.changeset(%{
      token_hash: token_digest,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    })
    |> Repo.insert!()
  end

  defp await_waiting_on!(waiter, blocker) do
    await_waiting_on!(waiter, blocker, System.monotonic_time(:millisecond) + @detection_budget_ms)
  end

  defp await_waiting_on!(waiter, blocker, deadline) do
    rows =
      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(
          Repo,
          """
          SELECT query FROM pg_stat_activity
          WHERE pid = $1 AND wait_event_type = 'Lock' AND $2 = ANY(pg_blocking_pids(pid))
          """,
          [waiter, blocker]
        ).rows
      end)

    case rows do
      [[query]] ->
        blocked_relation!(query)

      [] ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("backend #{waiter} was not observed waiting on backend #{blocker}"),
          else: await_waiting_on!(waiter, blocker, deadline)
    end
  end

  defp blocked_relation!(query) do
    case Regex.run(~r/FROM "(\w+)"/, query) do
      [_match, relation] -> relation
      nil -> flunk("the blocked statement did not name a relation")
    end
  end

  defp backend_state(backend) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[state]]} =
        SQL.query!(Repo, "SELECT state FROM pg_stat_activity WHERE pid = $1", [backend])

      state
    end)
  end

  defp committed_api_key(fixture) do
    Sandbox.unboxed_run(Repo, fn -> Repo.get!(APIKey, fixture.api_key.id) end)
  end

  defp set_no_wait_lock_timeout! do
    SQL.query!(Repo, "SET LOCAL lock_timeout = '#{@no_wait_lock_timeout_ms}ms'", [])
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp lock_not_available?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_not_available?(%Postgrex.Error{}), do: false

  defp track_participant(participant),
    do: Process.put(@participants, [participant | Process.get(@participants, [])])

  defp shutdown_participants do
    for %{task: task, ref: ref} <- Process.delete(@participants) || [] do
      send(task.pid, {:release_participant, ref})
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end

    :ok
  end

  defp unboxed_api_key_fixture do
    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      pool = pool_fixture(%{created_by_user_id: owner.id})

      %{api_key: api_key} =
        active_api_key_fixture(pool, %{
          created_by_user_id: owner.id,
          display_name: "Lock contention key"
        })

      %{scope: Scope.for_user(owner, ["instance_owner"]), api_key: api_key}
    end)
  end
end
