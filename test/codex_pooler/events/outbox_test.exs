defmodule CodexPooler.Events.OutboxTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Events
  alias CodexPooler.Events.Outbox
  alias CodexPooler.Events.OutboxDispatcher
  alias CodexPooler.Events.OutboxEntry
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.UnboxedFixture
  import ExUnit.CaptureLog

  @detection_timeout 15_000

  setup do
    pool_id = Ecto.UUID.generate()

    register_unboxed_cleanup!(fn ->
      Repo.delete_all(from entry in OutboxEntry, where: fragment("?::jsonb->>'pool_id' = ?", entry.payload, ^pool_id))
    end)

    :ok = Events.subscribe_pool(pool_id)
    supervisor = start_supervised!({Task.Supervisor, []})
    %{pool_id: pool_id, task_supervisor: supervisor}
  end

  test "a committed envelope retains its identity and relays only after an independent drain", %{pool_id: pool_id} do
    event = queue_event(pool_id)
    entry = run_unboxed(fn -> Repo.get!(OutboxEntry, event.id) end)
    payload = CodexPooler.JSON.decode!(entry.payload)
    assert payload["origin_id"] == "transaction:" <> event.id
    refute Map.has_key?(payload, "origin_node")
    assert payload["payload"] == event.payload
    refute_received {Events, ^event}

    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain() end)
    assert_receive {Events, ^event}, @detection_timeout
    assert run_unboxed(fn -> Repo.get(OutboxEntry, event.id) end) == nil
    assert {:ok, 0} = run_unboxed(fn -> Outbox.drain() end)
    refute_received {Events, ^event}
  end

  test "outer rollback removes both nested invalidations", %{pool_id: pool_id} do
    assert {:error, :cancelled} =
             run_unboxed(fn ->
               Repo.transaction(fn ->
                 {:ok, {:ok, _event}} = Repo.transaction(fn -> Events.broadcast_request_logs(pool_id, "request_finalized") end)
                 {:ok, _event} = Events.broadcast_usage_after_commit(pool_id, "usage_updated")
                 Repo.rollback(:cancelled)
               end)
             end)

    assert {:ok, 0} = run_unboxed(fn -> Outbox.drain() end)
    assert run_unboxed(fn -> Repo.aggregate(OutboxEntry, :count) end) == 0
  end

  test "invalid metadata is rejected without poisoning the transaction or persisting arbitrary fields", %{pool_id: pool_id} do
    invalid = [
      {"request_finalized", %{prompt: "private-sentinel"}},
      {"private-sentinel", %{}},
      {"request_finalized", %{request_id: "private-sentinel"}},
      {"request_finalized", %{status: "private-sentinel"}},
      {"request_finalized", %{usage_status: "private-sentinel"}},
      {"request_finalized", %{sample: String.duplicate("x", 8_000)}}
    ]

    log =
      capture_log(fn ->
        run_unboxed(fn ->
          Repo.transaction(fn ->
            for {reason, payload} <- invalid do
              assert {:error, :postgres_event_relay_failed} = Events.broadcast_request_logs(pool_id, reason, payload)
              assert %{rows: [[1]]} = Repo.query!("SELECT 1")
            end

            assert {:error, :postgres_event_relay_failed} = Events.broadcast_request_logs("private-sentinel", "request_finalized")
            assert {:ok, _event} = Events.broadcast_request_logs(pool_id, "request_finalized")
          end)
        end)
      end)

    assert log =~ "pool event postgres relay failed"
    refute log =~ "private-sentinel"
    assert run_unboxed(fn -> Repo.aggregate(OutboxEntry, :count) end) == 1
    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain() end)
  end

  test "a drain cannot borrow an authoritative transaction", %{pool_id: pool_id} do
    assert {:ok, :checked} =
             run_unboxed(fn ->
               Repo.transaction(fn ->
                 assert {:ok, _event} = Events.broadcast_request_logs(pool_id, "request_reserved")
                 assert {:error, :event_outbox_requires_independent_transaction} = Outbox.drain()
                 :checked
               end)
             end)

    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain() end)
  end

  test "batch limit leaves later entries for another drain", %{pool_id: pool_id} do
    events = for _index <- 1..3, do: queue_event(pool_id)
    assert {:ok, 2} = run_unboxed(fn -> Outbox.drain(batch_size: 2) end)
    assert run_unboxed(fn -> Repo.aggregate(OutboxEntry, :count) end) == 1
    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain(batch_size: 2) end)

    for event <- events do
      assert_receive {Events, ^event}, @detection_timeout
    end
  end

  test "another dispatcher skips a row locked by a failed worker and can retry it", %{pool_id: pool_id, task_supervisor: supervisor} do
    locked = queue_event(pool_id)
    available = queue_event(pool_id)
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from entry in OutboxEntry, where: entry.id == ^locked.id, lock: "FOR UPDATE")
            send(parent, :row_locked)

            receive do
              :release -> Repo.rollback(:cancelled)
            after
              @detection_timeout -> Repo.rollback(:release_timeout)
            end
          end)
        end)
      end)

    assert_receive :row_locked, @detection_timeout
    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain() end)
    assert_receive {Events, ^available}, @detection_timeout
    send(holder.pid, :release)
    assert Task.await(holder, @detection_timeout) == {:error, :cancelled}
    assert run_unboxed(fn -> Repo.one!(from entry in OutboxEntry, where: entry.id == ^locked.id, lock: "FOR UPDATE").id end) == locked.id
    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain() end)
    assert_receive {Events, ^locked}, @detection_timeout
  end

  test "a dispatcher killed after NOTIFY but before commit leaves the event retryable", %{pool_id: pool_id, task_supervisor: supervisor} do
    event = queue_event(pool_id)
    token = make_ref()
    handler = {__MODULE__, token}
    parent = self()
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.hold_notify/4, {parent, token})

    worker =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.put(:outbox_notify_barrier, token)
        Sandbox.unboxed_run(Repo, fn -> Outbox.drain() end)
      end)

    assert_receive {:notify_held, ^token}, @detection_timeout
    refute_received {Events, ^event}
    monitor = Process.monitor(worker.pid)

    assert Task.shutdown(worker, :brutal_kill) == nil
    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, @detection_timeout
    assert run_unboxed(fn -> Repo.one!(from entry in OutboxEntry, where: entry.id == ^event.id, lock: "FOR UPDATE").id end) == event.id
    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain() end)
    assert_receive {Events, ^event}, @detection_timeout

    # PostgreSQL delivers notifications in commit order. Wait for a later
    # event on the same channel before checking for a duplicate.
    marker = queue_event(pool_id)
    assert {:ok, 1} = run_unboxed(fn -> Outbox.drain() end)
    assert_receive {Events, ^marker}, @detection_timeout
    refute_received {Events, ^event}
  end

  test "an owned dispatcher drains committed events and stops cleanly", %{pool_id: pool_id, sandbox_owner: owner, sandbox_settings_cache: cache} do
    event = queue_event(pool_id)
    CodexPooler.DataCase.stop_sandbox(owner, cache)
    dispatcher_owner = Sandbox.start_owner!(Repo, sandbox: false, shared: true)
    on_exit(fn -> Sandbox.stop_owner(dispatcher_owner) end)

    dispatcher = start_supervised!({OutboxDispatcher, enabled: true, name: nil})
    monitor = Process.monitor(dispatcher)
    assert_receive {Events, ^event}, @detection_timeout
    assert Repo.get(OutboxEntry, event.id) == nil
    stop_supervised!(OutboxDispatcher)
    assert_receive {:DOWN, ^monitor, :process, ^dispatcher, :shutdown}, @detection_timeout
  end

  @tag slow: "observes the production dispatcher's one-second automatic database-error retry"
  test "the same dispatcher automatically retries a real database error and publishes only its committed attempt", %{pool_id: pool_id, sandbox_owner: owner, sandbox_settings_cache: cache} do
    event = queue_event(pool_id)
    payload = run_unboxed(fn -> Repo.get!(OutboxEntry, event.id).payload end)
    reader = start_supervised!({Postgrex, Keyword.take(Repo.config(), [:hostname, :port, :database, :username, :password, :ssl])})
    CodexPooler.DataCase.stop_sandbox(owner, cache)
    dispatcher_owner = Sandbox.start_owner!(Repo, sandbox: false, shared: true)
    on_exit(fn -> Sandbox.stop_owner(dispatcher_owner) end)

    token = make_ref()
    handler = {__MODULE__, token}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.fail_then_hold_retry/4, {self(), token, payload})

    log =
      capture_log(fn ->
        dispatcher = start_supervised!({OutboxDispatcher, enabled: true, name: nil})
        monitor = Process.monitor(dispatcher)
        assert_receive {:outbox_database_error, ^dispatcher, :division_by_zero}, @detection_timeout
        # The production one-second retry runs automatically. Its second NOTIFY
        # is held before commit so the first rollback can be observed without
        # racing the worker's transient failure counter or querying its connection.
        assert_receive {:outbox_retry_held, ^dispatcher, ^token}, @detection_timeout
        assert Postgrex.query!(reader, "SELECT count(*) FROM accounting_event_outbox WHERE id = $1", [Ecto.UUID.dump!(event.id)]).rows == [[1]]
        refute_received {Events, ^event}
        refute_received {:DOWN, ^monitor, :process, ^dispatcher, _reason}

        send(dispatcher, {:release_retry, token})
        assert_receive {Events, ^event}, @detection_timeout
        assert :sys.get_state(dispatcher).failures == 0
        assert Postgrex.query!(reader, "SELECT count(*) FROM accounting_event_outbox WHERE id = $1", [Ecto.UUID.dump!(event.id)]).rows == [[0]]
        stop_supervised!(OutboxDispatcher)
        assert_receive {:DOWN, ^monitor, :process, ^dispatcher, :shutdown}, @detection_timeout
        refute_received {Events, ^event}
      end)

    assert log =~ "accounting event outbox dispatch failed; retrying"
    refute log =~ "division by zero"
  end

  defp queue_event(pool_id) do
    {:ok, {:ok, event}} =
      run_unboxed(fn ->
        Repo.transaction(fn -> Events.broadcast_request_logs(pool_id, "request_finalized", %{request_id: Ecto.UUID.generate(), status: "failed"}) end)
      end)

    event
  end

  @doc false
  def hold_notify(_name, _measurements, metadata, {parent, token}) do
    if Process.get(:outbox_notify_barrier) == token and String.contains?(metadata.query, "SELECT pg_notify") do
      send(parent, {:notify_held, token})

      receive do
        :release -> :ok
      after
        @detection_timeout -> raise "outbox notification barrier was not released"
      end
    end
  end

  @doc false
  def fail_then_hold_retry(_name, _measurements, metadata, {parent, token, payload}) do
    if String.contains?(metadata.query, "SELECT pg_notify") and metadata.params == [Events.postgres_channel(), [payload]] do
      attempt = Process.get({__MODULE__, token}, 0) + 1
      Process.put({__MODULE__, token}, attempt)
      fail_or_hold_retry(attempt, parent, token)
    end
  end

  defp fail_or_hold_retry(1, parent, _token) do
    {:error, %Postgrex.Error{postgres: %{code: code}}} = Repo.query("SELECT 1 / 0", [], log: false)
    send(parent, {:outbox_database_error, self(), code})
  end

  defp fail_or_hold_retry(2, parent, token) do
    send(parent, {:outbox_retry_held, self(), token})

    receive do
      {:release_retry, ^token} -> :ok
    after
      @detection_timeout -> raise "outbox automatic retry barrier was not released"
    end
  end

  defp fail_or_hold_retry(_attempt, _parent, _token), do: :ok
end
