defmodule CodexPoolerWeb.Admin.PoolsLiveRestoreTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Alerts
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{OperatorPoolAssignment, Pool}
  alias CodexPooler.Repo

  # Failure-detection budget for a notification center on another page to show
  # the restored Pool's incident; a green run returns as soon as it does.
  @detection_timeout_ms 15_000

  setup :register_and_log_in_user

  # An owner could disable or archive a Pool from the product but never bring
  # it back: the editor refuses an inactive Pool and nothing called
  # `Pools.change_pool_status/3` (findings#206 row 206-318). A disabled Pool's
  # card now offers Reactivate; editing waits until the Pool is active again.
  test "an owner reactivates a disabled Pool from its card menu, audited, and open notification centers show its incidents again", %{conn: conn, scope: scope} do
    pool = pool!(scope, "disabled")
    active_pool = pool!(scope, "still-active")
    incident_id = record_bell_incident!(pool).id
    assert {:ok, _disabled} = Pools.change_pool_status(scope, pool, "disabled")

    {:ok, jobs_view, _html} = live(conn, ~p"/admin/jobs")
    assert %{badge_count: 0} = notification_center(jobs_view)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-row-#{pool.id}-status", "disabled")
    assert has_element?(view, "#reactivate-pool-#{pool.id}", "Reactivate")
    assert has_element?(view, "#edit-pool-#{pool.id}[disabled][title='Reactivate the Pool before editing']")
    refute has_element?(view, "#reactivate-pool-#{active_pool.id}")
    refute has_element?(view, "#edit-pool-#{active_pool.id}[disabled]")

    view |> element("#reactivate-pool-#{pool.id}") |> render_click()

    assert %Pool{status: "active", disabled_at: nil} = Repo.get!(Pool, pool.id)
    assert has_element?(view, "#flash-info", "Pool reactivated")
    assert has_element?(view, "#pool-row-#{pool.id}-status", "active")
    refute has_element?(view, "#reactivate-pool-#{pool.id}")
    refute has_element?(view, "#edit-pool-#{pool.id}[disabled]")

    assert [%AuditEvent{actor_user_id: actor_id, details: details}] = reactivation_audit_events(pool)
    assert actor_id == scope.user.id
    assert %{"previous_status" => "disabled", "status" => "active"} = details

    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = await_notification_center!(jobs_view, &(&1.badge_count == 1))

    view |> element("#edit-pool-#{pool.id}") |> render_click()
    assert has_element?(view, "#pool-edit-form")
    _ = await_pool_traffic(view)
  end

  # Archiving revoked the admins' assignments and restoring must not bring them
  # back (pools AGENTS.md); the archived Pool keeps its slug-confirmed delete.
  test "an owner restores an archived Pool without restoring its admins' assignments, and an archived Pool keeps its delete action", %{conn: conn, scope: scope} do
    pool = pool!(scope, "archived")
    %{user: admin} = operator_fixture(scope, %{"email" => unique_user_email(), "role" => "instance_admin", "password_change_required" => "false"})
    assignment = operator_pool_assignment_fixture(admin, pool, created_by_user_id: scope.user.id)
    assert {:ok, _archived} = Pools.change_pool_status(scope, pool, "archived")
    assert %OperatorPoolAssignment{status: "revoked"} = Repo.get!(OperatorPoolAssignment, assignment.id)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    assert has_element?(view, "#reactivate-pool-#{pool.id}")
    refute has_element?(view, "#delete-pool-#{pool.id}[disabled]")
    assert has_element?(view, "#edit-pool-#{pool.id}[disabled]")

    view |> element("#reactivate-pool-#{pool.id}") |> render_click()

    assert %Pool{status: "active"} = Repo.get!(Pool, pool.id)
    assert %OperatorPoolAssignment{status: "revoked"} = Repo.get!(OperatorPoolAssignment, assignment.id)
    assert has_element?(view, "#delete-pool-#{pool.id}[disabled]")
    refute has_element?(view, "#reactivate-pool-#{pool.id}")
    assert [%AuditEvent{details: %{"previous_status" => "archived", "status" => "active"}}] = reactivation_audit_events(pool)
    _ = await_pool_traffic(view)
  end

  # Two owners' pages, or a page that has not yet re-rendered, can both offer
  # Reactivate. The one that arrives second finds the Pool active and changes
  # and audits nothing.
  test "a Pool another owner already reactivated is not reactivated again from a stale card", %{conn: conn, scope: scope} do
    pool = pool!(scope, "raced")
    assert {:ok, disabled} = Pools.change_pool_status(scope, pool, "disabled")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    assert has_element?(view, "#reactivate-pool-#{pool.id}")

    assert {:ok, _active} = Pools.change_pool_status(scope, disabled, "active")
    assert [_first] = reactivation_audit_events(pool)

    render_click(view, "reactivate_pool", %{"id" => pool.id})

    assert has_element?(view, "#flash-error", "Pool is already active")
    assert [_first] = reactivation_audit_events(pool)
    refute has_element?(view, "#reactivate-pool-#{pool.id}")
    _ = await_pool_traffic(view)
  end

  # Restoring a Pool is owner-only: an assigned admin never sees an inactive
  # Pool and a forged event changes nothing.
  test "an assigned admin gets no Reactivate action and a forged one leaves the Pool disabled", %{scope: scope} do
    pool = pool!(scope, "admin-forged")
    assigned_active = pool!(scope, "admin-active")
    admin_conn = admin_conn!(scope, [pool, assigned_active])
    assert {:ok, _disabled} = Pools.change_pool_status(scope, pool, "disabled")

    {:ok, view, html} = live(admin_conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    refute html =~ pool.slug
    refute has_element?(view, "#pool-row-#{pool.id}")
    refute has_element?(view, "[id^='reactivate-pool-']")
    assert has_element?(view, "#pool-row-#{assigned_active.id}")

    render_click(view, "reactivate_pool", %{"id" => pool.id})

    assert has_element?(view, "#flash-error")
    assert %Pool{status: "disabled"} = Repo.get!(Pool, pool.id)
    assert [%AuditEvent{details: %{"status" => "disabled"}}] = status_audit_events(pool)
    _ = await_pool_traffic(view)
  end

  # An owner demoted to admin while their Pools page is open loses the
  # disabled Pool's card and its Reactivate action (the page follows the role,
  # findings#206 row 206-325); a Reactivate the page sent before it re-read is
  # refused and the Pool stays disabled.
  test "an owner demoted while the Pools page is open cannot reactivate from it", %{scope: scope} do
    pool = pool!(scope, "demoted")
    assert {:ok, _disabled} = Pools.change_pool_status(scope, pool, "disabled")
    %{user: second_owner, conn: second_conn} = owner_conn!(scope)

    {:ok, view, _html} = live(second_conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    assert has_element?(view, "#reactivate-pool-#{pool.id}")

    assert {:ok, _demoted} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin", "pool_ids" => []})

    # The role change reaches the page as an invalidation this process sent,
    # and the page re-reads behind a message to itself: two fences.
    _ = :sys.get_state(view.pid)
    _ = :sys.get_state(view.pid)
    _ = await_pool_traffic(view)
    refute has_element?(view, "#pool-row-#{pool.id}")
    refute has_element?(view, "#reactivate-pool-#{pool.id}")

    render_click(view, "reactivate_pool", %{"id" => pool.id})

    assert has_element?(view, "#flash-error")
    assert %Pool{status: "disabled"} = Repo.get!(Pool, pool.id)
    assert [%AuditEvent{details: %{"status" => "disabled"}}] = status_audit_events(pool)
    _ = await_pool_traffic(view)
  end

  defp pool!(scope, label) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "restore-#{label}-#{unique_suffix()}", name: "Restore #{label}"})
    pool
  end

  defp status_audit_events(pool) do
    Repo.all(from event in AuditEvent, where: event.action == "pool.status_update" and event.target_id == ^pool.id, order_by: [asc: event.occurred_at, asc: event.id])
  end

  defp reactivation_audit_events(pool), do: Enum.filter(status_audit_events(pool), &(&1.details["status"] == "active"))

  defp record_bell_incident!(pool) do
    rule = alert_rule_fixture(pool, %{display_name: "Restore #{unique_suffix()}"})

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: "alert:pools-restore:#{unique_suffix()}",
               scope_type: "pool",
               rule_kind: "pool_no_usable_assignments",
               severity: "critical",
               pool_id: pool.id,
               matched_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
               targets: [%{rule_id: rule.id, pool_id: pool.id}]
             })

    incident
  end

  defp admin_conn!(owner_scope, pools) do
    %{user: admin} = operator_fixture(owner_scope, %{"email" => unique_user_email(), "role" => "instance_admin", "password_change_required" => "false"})
    Enum.each(pools, &operator_pool_assignment_fixture(admin, &1, created_by_user_id: owner_scope.user.id))
    log_in!(admin)
  end

  defp owner_conn!(owner_scope) do
    %{user: owner} = operator_fixture(owner_scope, %{"email" => unique_user_email(), "role" => "instance_owner", "password_change_required" => "false"})
    %{user: owner, conn: log_in!(owner)}
  end

  defp log_in!(user) do
    assert {:ok, %{token: token}} = Accounts.login_user(%{"email" => user.email, "password" => valid_user_password()})
    build_conn() |> log_in_user(user, token)
  end

  defp notification_center(view), do: :sys.get_state(view.pid).socket.assigns.alert_notification_center

  defp await_notification_center!(view, predicate) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_notification_center(view, predicate, deadline)
  end

  defp await_notification_center(view, predicate, deadline) do
    center = notification_center(view)

    cond do
      predicate.(center) ->
        center

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the notification center was not refreshed: #{inspect(Map.take(center, [:badge_count]))}")

      true ->
        receive do
        after
          10 -> await_notification_center(view, predicate, deadline)
        end
    end
  end

  # The page loads Pool traffic in a task behind a shared per-operator gate;
  # wait for it (and a coalesced re-run) so no task outlives the test.
  defp await_pool_traffic(view) do
    html = render_async(view, 2_000)
    assigns = :sys.get_state(view.pid).socket.assigns

    cond do
      assigns.pool_traffic_running? ->
        await_pool_traffic(view)

      assigns.pool_traffic_rerun? ->
        expire_pool_traffic_cooldown(view)
        await_pool_traffic(view)

      true ->
        html
    end
  end

  defp expire_pool_traffic_cooldown(view) do
    assigns = :sys.get_state(view.pid).socket.assigns
    timer_ref = Map.get(assigns, :pool_traffic_cooldown_timer)
    cooldown_token = Map.get(assigns, :pool_traffic_cooldown_token)

    if is_reference(timer_ref) and is_reference(cooldown_token) do
      Repo.query!(
        """
        UPDATE admin_pool_traffic_gates
        SET cooldown_until = statement_timestamp(), updated_at = statement_timestamp()
        WHERE operator_id = $1::text::uuid
          AND owner_token IS NULL
        """,
        [assigns.current_scope.user.id]
      )

      Process.cancel_timer(timer_ref, async: false, info: false)
      send(view.pid, {:pool_traffic_cooldown_elapsed, cooldown_token})
      _ = :sys.get_state(view.pid)
    end

    :ok
  end

  defp unique_suffix, do: System.unique_integer([:positive])
end
