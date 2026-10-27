defmodule CodexPooler.Alerts.EditorRevisionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertRule}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture
  alias Ecto.Adapters.SQL.Sandbox

  for kind <- [:rule, :channel] do
    test "#{kind} edits reject stale revisions without writes or audit events" do
      assert_stale_revision(unquote(kind))
    end

    test "#{kind} authorization precedes revision checks" do
      assert_revision_authorization(unquote(kind))
    end

    test "concurrent #{kind} edits check the revision after the earlier writer commits" do
      assert_locked_revision(unquote(kind))
    end

    test "#{kind} deletes reject stale revisions without writes or audit events" do
      assert_stale_delete_revision(unquote(kind))
    end

    test "#{kind} delete authorization precedes revision checks" do
      assert_delete_authorization(unquote(kind))
    end
  end

  defp assert_stale_revision(kind) do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner)
    entity = entity_fixture(kind, scope)
    assert {:ok, changed} = update(kind, scope, entity, %{state: "disabled"}, expected_updated_at: entity.updated_at)
    persisted = persisted(kind, entity.id)
    audit_count = Repo.aggregate(AuditEvent, :count)

    assert {:error, %{code: :stale_update}} = update(kind, scope, entity, %{display_name: "Stale edit", state: "active"}, expected_updated_at: entity.updated_at)
    assert persisted(kind, entity.id) == persisted
    assert Repo.aggregate(AuditEvent, :count) == audit_count

    assert {:ok, renamed} = update(kind, scope, changed, %{display_name: "Reviewed edit"}, expected_updated_at: changed.updated_at)
    assert renamed.display_name == "Reviewed edit"
    assert renamed.state == "disabled"
    assert renamed.disabled_at == changed.disabled_at

    assert {:ok, latest} = update(kind, scope, entity, %{display_name: "Unversioned edit"}, [])
    assert latest.display_name == "Unversioned edit"
    assert latest.state == "disabled"
  end

  defp assert_revision_authorization(kind) do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner)
    entity = entity_fixture(kind, scope)
    %{user: admin} = operator_fixture(scope, %{"role" => "instance_admin"})
    expected_code = if kind == :rule, do: :capability_denied, else: :channel_not_found

    assert {:error, %{code: ^expected_code}} = update(kind, Scope.for_user(admin), entity, %{state: "disabled"}, expected_updated_at: nil)
    assert persisted(kind, entity.id).state == "active"
  end

  defp assert_stale_delete_revision(kind) do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner)
    entity = entity_fixture(kind, scope)
    assert {:ok, changed} = update(kind, scope, entity, %{display_name: "Intervening update"}, [])
    persisted = persisted(kind, entity.id)
    audit_count = Repo.aggregate(AuditEvent, :count)

    assert {:error, %{code: :stale_update}} =
             delete(kind, scope, entity, expected_updated_at: entity.updated_at)

    assert persisted(kind, entity.id) == persisted
    assert Repo.aggregate(AuditEvent, :count) == audit_count

    assert {:ok, _deleted} = delete(kind, scope, changed, expected_updated_at: changed.updated_at)
    refute Repo.get(if(kind == :rule, do: AlertRule, else: AlertChannel), entity.id)
  end

  defp assert_delete_authorization(kind) do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner)
    entity = entity_fixture(kind, scope)
    %{user: admin} = operator_fixture(scope, %{"role" => "instance_admin"})
    expected_code = if kind == :rule, do: :capability_denied, else: :channel_not_found

    assert {:error, %{code: ^expected_code}} =
             delete(kind, Scope.for_user(admin), entity, expected_updated_at: nil)

    assert persisted(kind, entity.id)
  end

  defp assert_locked_revision(kind) do
    %{user: owner} = committed_bootstrap_owner_fixture!()
    scope = Scope.for_user(owner)
    UnboxedFixture.register_unboxed_cleanup!(fn -> Repo.delete_all(from channel in AlertChannel, where: channel.created_by_user_id == ^owner.id) end)
    entity = UnboxedFixture.run_unboxed(fn -> entity_fixture(kind, scope) end)
    supervisor = start_supervised!({Task.Supervisor, []})
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.hold_editor_query/4, nil)

    operation = fn name -> update(kind, scope, entity, %{display_name: name}, expected_updated_at: entity.updated_at) end
    first = start_actor(supervisor, fn -> operation.("Winning edit") end, true)
    assert_receive {:editor_backend, first_pid, first_backend}, 15_000
    assert first_pid == first.pid
    assert_receive {:editor_lock_held, ^first_pid}, 15_000
    second = start_actor(supervisor, fn -> operation.("Stale edit") end, false)
    assert_receive {:editor_backend, second_pid, second_backend}, 15_000
    assert second_pid == second.pid
    refute first_backend == second_backend
    assert_blocked(second_backend, first_backend, System.monotonic_time(:millisecond) + 15_000)
    send(first.pid, :release_editor_lock)

    assert {:ok, _updated} = finish_actor(first)
    assert {:error, %{code: :stale_update}} = finish_actor(second)
    assert UnboxedFixture.run_unboxed(fn -> persisted(kind, entity.id).display_name end) == "Winning edit"
  end

  defp start_actor(supervisor, operation, hold?) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn -> run_actor(parent, operation, hold?) end)
      end)

    %{task: task, pid: task.pid, monitor: Process.monitor(task.pid)}
  end

  defp run_actor(parent, operation, hold?) do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:editor_backend, self(), backend})
    if hold?, do: Process.put({__MODULE__, :hold_editor}, parent)
    operation.()
  end

  defp finish_actor(%{task: task, pid: pid, monitor: monitor}) do
    result = Task.await(task, 15_000)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
    result
  end

  def hold_editor_query(_event, _measurements, %{source: source, query: query}, _config) when source in ["alert_rules", "alert_channels"] do
    if String.contains?(query, "FOR UPDATE") do
      case Process.delete({__MODULE__, :hold_editor}) do
        nil ->
          :ok

        parent ->
          send(parent, {:editor_lock_held, self()})

          receive do
            :release_editor_lock -> :ok
          after
            15_000 -> raise "editor lock barrier was not released"
          end
      end
    end
  end

  def hold_editor_query(_event, _measurements, _metadata, _config), do: :ok

  defp assert_blocked(waiter, holder, deadline) do
    blocked? = UnboxedFixture.run_unboxed(fn -> Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [holder, waiter]).rows == [[true]] end)

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline, "editor did not wait on the other backend's row lock"

      receive do
      after
        10 -> :ok
      end

      assert_blocked(waiter, holder, deadline)
    end
  end

  defp entity_fixture(:rule, scope) do
    pool = pool_fixture(%{created_by_user_id: scope.user.id})
    alert_rule_fixture(pool, created_by_user_id: scope.user.id)
  end

  defp entity_fixture(:channel, scope), do: alert_channel_fixture(created_by_user_id: scope.user.id)
  defp persisted(:rule, id), do: Repo.get!(AlertRule, id)
  defp persisted(:channel, id), do: Repo.get!(AlertChannel, id)
  defp update(:rule, scope, entity, attrs, opts), do: Alerts.update_rule(scope, entity.id, attrs, opts)
  defp update(:channel, scope, entity, attrs, opts), do: Alerts.update_channel(scope, entity.id, attrs, opts)
  defp delete(:rule, scope, entity, opts), do: Alerts.delete_rule(scope, entity, opts)
  defp delete(:channel, scope, entity, opts), do: Alerts.delete_channel(scope, entity.id, opts)
end
