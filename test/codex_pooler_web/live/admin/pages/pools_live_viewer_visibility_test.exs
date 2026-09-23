defmodule CodexPoolerWeb.Admin.PoolsLiveViewerVisibilityTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Alerts
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.PoolsReadModel

  setup :register_and_log_in_user

  # The Pools page read its list and the viewer's permissions at mount only, so
  # an owner demoted while it was open kept the owner controls and the cards of
  # Pools it no longer sees until a reload (findings#206 row 206-325). The role
  # change reaches the page through its notification center's operator
  # invalidation, and the page re-reads its structure once.
  test "an owner demoted to admin while the Pools page is open loses the owner controls and the Pools it is not assigned", %{scope: scope} do
    [kept, hidden] = for label <- ["kept", "hidden"], do: pool!(scope, label)
    %{user: second_owner, conn: second_conn} = operator_conn!(scope, "instance_owner")
    view = open_pools_page!(second_conn)

    assert has_element?(view, "#pools-page-create-action")
    assert has_element?(view, "#pool-row-#{hidden.id}")
    assert has_element?(view, "#edit-pool-#{kept.id}")
    assert has_element?(view, "#delete-pool-#{kept.id}")

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin", "pool_ids" => [kept.id]})

    assert structural_reloads(view) == 1
    html = await_pool_traffic(view)

    refute has_element?(view, "#pools-page-create-action")
    refute has_element?(view, "#pool-row-#{hidden.id}")
    refute html =~ hidden.slug
    assert has_element?(view, "#pool-row-#{kept.id}")
    assert has_element?(view, "#models-pool-#{kept.id}")
    refute has_element?(view, "[id^='edit-pool-']")
    refute has_element?(view, "[id^='delete-pool-']")
    assert subscribed_pool_ids(view) == MapSet.new([kept.id])

    render_click(view, "open_create_pool", %{})
    assert has_element?(view, "#flash-error", "Pool management is not available for this session")
    refute assigns(view).creating_pool
  end

  # The role is the only change: the demoted owner is assigned every Pool, so
  # the Pools it sees stay the same while the owner controls must go.
  test "an owner demoted to an admin of every Pool loses the owner controls", %{scope: scope} do
    pools = for label <- ["all-first", "all-second"], do: pool!(scope, label)
    %{user: second_owner, conn: second_conn} = operator_conn!(scope, "instance_owner")
    view = open_pools_page!(second_conn)
    assert has_element?(view, "#pools-page-create-action")

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin", "pool_ids" => Enum.map(pools, & &1.id)})

    assert structural_reloads(view) == 1
    _ = await_pool_traffic(view)

    refute has_element?(view, "#pools-page-create-action")
    refute has_element?(view, "[id^='edit-pool-']")
    for pool <- pools, do: assert(has_element?(view, "#models-pool-#{pool.id}"))
  end

  # The other direction: an admin granted a Pool sees its card without a
  # reload, and when the grant is revoked the card and the model editor the
  # admin had open on it both go.
  test "an admin assigned a Pool while the Pools page is open sees its card, and loses it and its open model editor on revocation", %{scope: scope} do
    [first, granted] = for label <- ["first", "granted"], do: pool!(scope, label)
    %{user: admin, conn: admin_conn} = operator_conn!(scope, "instance_admin", [first])
    view = open_pools_page!(admin_conn)

    refute has_element?(view, "#pool-row-#{granted.id}")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [first.id, granted.id]})

    assert structural_reloads(view) == 1
    _ = await_pool_traffic(view)
    assert has_element?(view, "#pool-row-#{granted.id}")
    assert subscribed_pool_ids(view) == MapSet.new([first.id, granted.id])

    view |> element("#models-pool-#{granted.id}") |> render_click()
    _ = render_async(view, 2_000)
    assert %{pool_editor_mode: :models, editing_pool: %{id: granted_id}} = assigns(view)
    assert granted_id == granted.id
    assert has_element?(view, "#pool-model-serving-panel")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [first.id]})

    assert structural_reloads(view) == 1
    html = await_pool_traffic(view)

    assert %{pool_editor_mode: nil, editing_pool: nil} = assigns(view)
    refute has_element?(view, "#pool-model-serving-panel")
    refute has_element?(view, "#pool-row-#{granted.id}")
    refute html =~ granted.slug
    assert has_element?(view, "#flash-info", "Your Pool access changed")
    assert subscribed_pool_ids(view) == MapSet.new([first.id])
  end

  # A lifecycle event waits behind an open dialog, but a Pool the viewer can
  # no longer see must not: the admin keeps the model editor of a Pool still
  # assigned and loses the revoked Pool's card at once.
  test "an admin whose other Pool is revoked while a model editor is open keeps the editor and loses the revoked Pool's card", %{scope: scope} do
    [edited, revoked] = for label <- ["editor-kept", "editor-revoked"], do: pool!(scope, label)
    %{user: admin, conn: admin_conn} = operator_conn!(scope, "instance_admin", [edited, revoked])
    view = open_pools_page!(admin_conn)

    view |> element("#models-pool-#{edited.id}") |> render_click()
    _ = render_async(view, 2_000)
    assert %{pool_editor_mode: :models, editing_pool: %{id: edited_id}} = assigns(view)
    assert edited_id == edited.id

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [edited.id]})

    assert structural_reloads(view) == 1
    html = await_pool_traffic(view)

    assert %{pool_editor_mode: :models, editing_pool: %{id: ^edited_id}} = assigns(view)
    assert has_element?(view, "#pool-model-serving-panel")
    refute has_element?(view, "#flash-info")
    refute has_element?(view, "#pool-row-#{revoked.id}")
    refute html =~ revoked.slug
    assert has_element?(view, "#pool-row-#{edited.id}")
  end

  # An owner editing a Pool through the permalink editor is demoted: the
  # editor closes, its URL parameters go, and the page follows the new role.
  test "an owner demoted while the Pool editor is open loses the editor", %{scope: scope} do
    pool = pool!(scope, "edited")
    %{user: second_owner, conn: second_conn} = operator_conn!(scope, "instance_owner")
    {:ok, view, _html} = live(second_conn, ~p"/admin/pools?edit_pool_id=#{pool.id}&step=details")
    _ = await_pool_traffic(view)
    trace_structural_reloads!(view)
    assert has_element?(view, "#pool-edit-form")

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin", "pool_ids" => [pool.id]})

    assert structural_reloads(view) == 1
    _ = await_pool_traffic(view)

    patched = assert_patch(view)
    refute patched =~ "edit_pool_id"
    refute has_element?(view, "#pool-edit-form")
    assert %{pool_editor_mode: nil, editing_pool: nil} = assigns(view)
    assert has_element?(view, "#flash-info", "Your Pool access changed")
    refute has_element?(view, "#pools-page-create-action")
    assert has_element?(view, "#models-pool-#{pool.id}")
  end

  # Only a change of what the viewer sees reloads the page: an incident on a
  # visible Pool reloads the notification center alone, an edit that keeps the
  # role and the assignments sends nothing, and another operator's change
  # reaches only that operator's pages.
  test "an incident, an edit that keeps the role and assignments, and another operator's change do not reload the Pools page", %{conn: owner_conn, scope: scope} do
    [assigned, other] = for label <- ["quiet-assigned", "quiet-other"], do: pool!(scope, label)
    %{user: admin, conn: admin_conn} = operator_conn!(scope, "instance_admin", [assigned])
    %{user: other_admin} = operator_conn!(scope, "instance_admin", [assigned])
    admin_view = open_pools_page!(admin_conn)
    owner_view = open_pools_page!(owner_conn)

    incident_id = record_bell_incident!(assigned).id

    assert Enum.map([admin_view, owner_view], &structural_reloads/1) == [0, 0]
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = assigns(admin_view).alert_notification_center

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"display_name" => "Renamed #{unique_suffix()}"})
    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"role" => "instance_admin", "pool_ids" => [assigned.id]})
    assert {:ok, _other} = Accounts.update_operator(scope, other_admin, %{"pool_ids" => [assigned.id, other.id]})

    assert Enum.map([admin_view, owner_view], &structural_reloads/1) == [0, 0]
    refute has_element?(admin_view, "#pool-row-#{other.id}")
  end

  defp pool!(scope, label) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "visibility-#{label}-#{unique_suffix()}", name: "Visibility #{label}"})
    pool
  end

  defp operator_conn!(owner_scope, role, pools \\ []) do
    %{user: operator} = operator_fixture(owner_scope, %{"email" => unique_user_email(), "role" => role, "password_change_required" => "false"})
    Enum.each(pools, &operator_pool_assignment_fixture(operator, &1, created_by_user_id: owner_scope.user.id))
    assert {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => valid_user_password()})
    %{user: operator, conn: build_conn() |> log_in_user(operator, token)}
  end

  defp open_pools_page!(conn) do
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    trace_structural_reloads!(view)
    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp subscribed_pool_ids(view), do: assigns(view).subscribed_pool_ids

  defp record_bell_incident!(pool) do
    rule = alert_rule_fixture(pool, %{display_name: "Visibility #{unique_suffix()}"})

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: "alert:pools-visibility:#{unique_suffix()}",
               scope_type: "pool",
               rule_kind: "pool_no_usable_assignments",
               severity: "critical",
               pool_id: pool.id,
               matched_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
               targets: [%{rule_id: rule.id, pool_id: pool.id}]
             })

    incident
  end

  # Counts the page's structural reloads: each is one
  # `PoolsReadModel.load_structural/2` call in the page process. The trace
  # session is private to this test.
  defp trace_structural_reloads!(view) do
    session = :trace.session_create(:"#{__MODULE__}.#{unique_suffix()}", self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)
    _ = :trace.function(session, {PoolsReadModel, :load_structural, 2}, true, [:global])
    1 = :trace.process(session, view.pid, true, [:call])
    Process.put({__MODULE__, :reload_trace, view.pid}, session)
    :ok
  end

  # The reloads since the last count. The invalidation was sent by this process
  # (in-process PubSub), so the first `:sys.get_state/1` is ordered after it;
  # the hook hands a visibility change to the page as a message to itself,
  # queued behind that first call, so the second one is ordered after the
  # page's reload.
  defp structural_reloads(view) do
    session = Process.get({__MODULE__, :reload_trace, view.pid})
    _state = :sys.get_state(view.pid)
    _state = :sys.get_state(view.pid)
    delivered = :trace.delivered(session, view.pid)
    assert_receive {:trace_delivered, _tracee, ^delivered}, 15_000
    count_reloads(view.pid, 0)
  end

  defp count_reloads(pid, count) do
    receive do
      {:trace, ^pid, :call, {PoolsReadModel, :load_structural, [_scope, _filters]}} -> count_reloads(pid, count + 1)
    after
      0 -> count
    end
  end

  # The page loads Pool traffic in a task behind a shared per-operator gate;
  # wait for it (and a coalesced re-run) so no task outlives the test.
  defp await_pool_traffic(view) do
    html = render_async(view, 2_000)
    assigns = assigns(view)

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
    assigns = assigns(view)
    timer_ref = Map.get(assigns, :pool_traffic_cooldown_timer)
    cooldown_token = Map.get(assigns, :pool_traffic_cooldown_token)

    if is_reference(timer_ref) and is_reference(cooldown_token) do
      CodexPooler.Repo.query!(
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
