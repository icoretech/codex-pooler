defmodule CodexPoolerWeb.Admin.RemainingAdminPagesViewerVisibilityTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Accounts
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @detection_timeout_ms 15_000

  setup :register_and_log_in_user

  # The upstream cockpit, Audit logs, Alerts, Invites, Incidents and Settings
  # kept what they had read after the viewer's role or Pool assignments
  # changed, and the owner-only navigation of a page that did not re-render
  # stayed with it (findings#206 row 206-410). The producer is the real
  # operator edit, which invalidates the viewer's notification center.

  test "audit logs drop a revoked Pool's events and close its open event", %{scope: scope} do
    [kept, revoked] = for label <- ["audit-kept", "audit-revoked"], do: pool!(scope, label)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/audit-logs")
    revoked_event = Enum.find(assigns(view).audit_logs.items, &(&1.pool_id == revoked.id))
    assert revoked_event
    render_click(view, "show_audit_event", %{"id" => revoked_event.id})
    assert assigns(view).selected_audit_event.id == revoked_event.id

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert event_pool_ids(view) == [kept.id]
    assert assigns(view).selected_audit_event == nil
    assert Enum.map(assigns(view).pools, & &1.id) == [kept.id]
  end

  test "audit logs drop the instance events of a demoted owner", %{scope: scope} do
    pool = pool!(scope, "audit-demoted")
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/audit-logs")
    assert nil in event_pool_ids(view)

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin", "pool_ids" => [pool.id]})

    settle!(view)
    assert event_pool_ids(view) == [pool.id]
    refute has_element?(view, "#admin-nav-jobs")
  end

  # The Pool filter on a revoked Pool stayed in the address bar while the page
  # answered it with a filter error (findings#206 row 206-431): the page
  # patches it away and keeps the other filters.
  test "audit logs patch a Pool filter on a revoked Pool out of the URL", %{scope: scope} do
    [kept, revoked] = for label <- ["audit-filter-kept", "audit-filter-revoked"], do: pool!(scope, label)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/audit-logs?#{%{"pool_id" => revoked.id, "outcome" => "success"}}")
    assert assigns(view).selected_pool.id == revoked.id
    assert event_pool_ids(view) == [revoked.id]

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert patched_query(view, "/admin/audit-logs") == %{"outcome" => "success"}
    settle!(view)
    assert assigns(view).current_params == %{"outcome" => "success"}
    assert assigns(view).filter_errors == []
    assert assigns(view).filter_values["outcome"] == "success"
    assert event_pool_ids(view) == [kept.id]
  end

  test "audit logs keep a Pool filter on a Pool the viewer still sees", %{scope: scope} do
    [kept, revoked] = for label <- ["audit-filter-stay", "audit-filter-gone"], do: pool!(scope, label)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/audit-logs?#{%{"pool_id" => kept.id}}")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert Enum.map(assigns(view).pools, & &1.id) == [kept.id]
    assert assigns(view).current_params == %{"pool_id" => kept.id}
    assert assigns(view).selected_pool.id == kept.id
    assert assigns(view).filter_errors == []
  end

  test "alerts drop a revoked Pool's rules and close the rule editor on it", %{scope: scope} do
    [kept, revoked] = for label <- ["alerts-kept", "alerts-revoked"], do: pool!(scope, label)
    kept_rule = alert_rule_fixture(kept, %{display_name: "Kept coverage"})
    revoked_rule = alert_rule_fixture(revoked, %{display_name: "Revoked coverage"})
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/alerts")
    render_click(view, "open_edit_rule", %{"id" => revoked_rule.id})
    assert assigns(view).editing_rule.id == revoked_rule.id

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).editing_rule == nil
    assert assigns(view).rule_form_mode == :create
    assert assigns(view).rule_form.params["pool_id"] == kept.id
    assert has_element?(view, "#flash-info", "Your Pool access changed")
    refute has_element?(view, "#alert-rule-row-#{revoked_rule.id}")
    assert has_element?(view, "#alert-rule-row-#{kept_rule.id}")
    assert Enum.map(assigns(view).manageable_pools, & &1.id) == [kept.id]
  end

  test "alerts keep the rule editor of a Pool the viewer still sees", %{scope: scope} do
    [kept, revoked] = for label <- ["alerts-editor-kept", "alerts-editor-revoked"], do: pool!(scope, label)
    kept_rule = alert_rule_fixture(kept, %{display_name: "Kept editor"})
    revoked_rule = alert_rule_fixture(revoked, %{display_name: "Revoked editor"})
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/alerts")
    render_click(view, "open_edit_rule", %{"id" => kept_rule.id})

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).editing_rule.id == kept_rule.id
    refute has_element?(view, "#flash-info")
    refute has_element?(view, "#alert-rule-row-#{revoked_rule.id}")
  end

  test "alerts move a new rule's form off a revoked Pool", %{scope: scope} do
    [kept, revoked] = for label <- ["alerts-form-kept", "alerts-form-revoked"], do: pool!(scope, label)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/alerts")
    render_change(view, "change_rule_form", %{"alert_rule" => %{"pool_id" => revoked.id, "display_name" => "Draft rule"}})
    assert assigns(view).rule_form.params["pool_id"] == revoked.id

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).rule_form_mode == :create
    assert assigns(view).rule_form.params["pool_id"] == kept.id
  end

  # The incident filter on a Pool or rule the viewer lost left the address
  # bar naming it while the page answered with a filter error and no incidents
  # (findings#206 row 206-416): the page patches the lost filters away and keeps
  # the rest.
  test "alerts patch an incident filter on a revoked Pool and its rule out of the URL", %{scope: scope} do
    [kept, revoked] = for label <- ["alerts-filter-kept", "alerts-filter-revoked"], do: pool!(scope, label)
    revoked_rule = alert_rule_fixture(revoked, %{display_name: "Revoked filter"})
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/alerts?#{%{"tab" => "incidents", "pool_id" => revoked.id, "rule_id" => revoked_rule.id, "severity" => "critical"}}")
    assert assigns(view).incident_filter_values["pool_id"] == revoked.id
    assert assigns(view).incident_filter_errors == []

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert patched_query(view, "/admin/alerts") == %{"tab" => "incidents", "severity" => "critical"}
    settle!(view)
    assert assigns(view).current_params == %{"tab" => "incidents", "severity" => "critical"}
    assert assigns(view).incident_filter_errors == []
    assert assigns(view).incident_filter_values["severity"] == "critical"
  end

  test "alerts keep an incident filter on a Pool the viewer still sees", %{scope: scope} do
    [kept, revoked] = for label <- ["alerts-filter-stay", "alerts-filter-gone"], do: pool!(scope, label)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/alerts?#{%{"tab" => "incidents", "pool_id" => kept.id}}")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).current_params == %{"tab" => "incidents", "pool_id" => kept.id}
    assert assigns(view).incident_filter_values["pool_id"] == kept.id
  end

  test "invites drop a revoked Pool's invites and close the revoke dialog on one", %{scope: scope} do
    [kept, revoked] = for label <- ["invites-kept", "invites-revoked"], do: pool!(scope, label)
    kept_invite = invite!(scope, kept)
    revoked_invite = invite!(scope, revoked)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/invites")
    render_click(view, "open_revoke_invite", %{"id" => revoked_invite.id})
    assert assigns(view).revoking_invite.id == revoked_invite.id

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).revoking_invite == nil
    assert has_element?(view, "#flash-info", "Your Pool access changed")
    refute has_element?(view, "#invite-row-#{revoked_invite.id}")
    assert has_element?(view, "#invite-row-#{kept_invite.id}")
    assert Enum.map(assigns(view).pools, & &1.id) == [kept.id]
  end

  test "invites close the create dialog on a revoked Pool", %{scope: scope} do
    [kept, revoked] = for label <- ["invites-create-kept", "invites-create-revoked"], do: pool!(scope, label)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/invites")
    render_click(view, "open_create_invite", %{})
    render_change(view, "validate_invite", %{"invite" => %{"pool_id" => revoked.id, "invited_email" => unique_user_email()}})
    assert assigns(view).creating_invite

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    refute assigns(view).creating_invite
    assert has_element?(view, "#flash-info", "Your Pool access changed")
  end

  # The Pool filter on a revoked Pool left the address bar naming it while the
  # page listed every visible invite (findings#206 row 206-416).
  test "invites patch a Pool filter on a revoked Pool out of the URL", %{scope: scope} do
    [kept, revoked] = for label <- ["invites-filter-kept", "invites-filter-revoked"], do: pool!(scope, label)
    kept_invite = invite!(scope, kept)
    revoked_invite = invite!(scope, revoked)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/invites?#{%{"pool_id" => revoked.id, "status" => "active"}}")
    assert has_element?(view, "#invite-row-#{revoked_invite.id}")
    refute has_element?(view, "#invite-row-#{kept_invite.id}")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert patched_query(view, "/admin/invites") == %{"status" => "active"}
    settle!(view)
    assert assigns(view).filter_values == %{"pool_id" => "", "status" => "active"}
    assert has_element?(view, "#invite-row-#{kept_invite.id}")
    refute has_element?(view, "#invite-row-#{revoked_invite.id}")
  end

  test "the upstream cockpit drops a revoked Pool's assignment of the account and closes what showed that Pool", %{scope: scope} do
    [kept, revoked] = for label <- ["cockpit-kept", "cockpit-revoked"], do: pool!(scope, label)
    %{identity: identity} = upstream_assignment_fixture(kept, %{account_label: "Shared cockpit account"})
    second_assignment!(identity, revoked)
    revoked_request = request!(revoked)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/upstreams/#{identity.id}")
    assert Enum.sort(assignment_pool_ids(view)) == Enum.sort([kept.id, revoked.id])
    render_click(view, "open_request_log", %{"request-id" => revoked_request.id})
    assert assigns(view).selected_request_log.id == revoked_request.id
    render_click(view, "open_oauth_relink", %{"id" => identity.id})
    assert assigns(view).oauth_relinking

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assignment_pool_ids(view) == [kept.id]
    assert assigns(view).subscribed_pool_ids == MapSet.new([kept.id])
    assert Enum.map(assigns(view).dialog_pool_options, &elem(&1, 1)) == [kept.id]
    assert assigns(view).selected_request_log == nil
    refute assigns(view).oauth_relinking
    assert has_element?(view, "#flash-info", "Your Pool access changed")
  end

  test "the upstream cockpit keeps an open dialog when the viewer only gains a Pool", %{scope: scope} do
    [first, granted] = for label <- ["cockpit-gain-first", "cockpit-gain-granted"], do: pool!(scope, label)
    %{identity: identity} = upstream_assignment_fixture(first, %{account_label: "Gaining cockpit account"})
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [first])

    view = open!(conn, ~p"/admin/upstreams/#{identity.id}")
    render_click(view, "open_oauth_relink", %{"id" => identity.id})

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [first.id, granted.id]})

    settle!(view)
    assert assigns(view).oauth_relinking
    assert Enum.map(assigns(view).dialog_pool_options, &elem(&1, 1)) == [first.id]
    refute has_element?(view, "#flash-info")
  end

  test "the upstream cockpit leaves for the account list when the account is no longer visible", %{scope: scope} do
    [kept, revoked] = for label <- ["cockpit-left-kept", "cockpit-left-revoked"], do: pool!(scope, label)
    %{identity: identity} = upstream_assignment_fixture(revoked, %{account_label: "Revoked cockpit account"})
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/upstreams/#{identity.id}")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    flash = assert_redirect(view, ~p"/admin/upstreams", @detection_timeout_ms)
    assert flash["info"] == "Your Pool access changed"
  end

  test "incidents drop the owner-only navigation of a demoted owner", %{scope: scope} do
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/incidents")
    assert has_element?(view, "#admin-nav-jobs")

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin"})

    settle!(view)
    refute has_element?(view, "#admin-nav-jobs")
    refute has_element?(view, "#admin-nav-system")
    refute has_element?(view, "#admin-nav-operators")
  end

  test "settings drop the owner-only navigation of a demoted owner and show it to a promoted admin", %{scope: scope} do
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/settings")
    assert has_element?(view, "#admin-nav-system")

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin"})
    settle!(view)
    refute has_element?(view, "#admin-nav-system")

    assert {:ok, _owner} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_owner"})
    settle!(view)
    assert has_element?(view, "#admin-nav-system")
  end

  test "operators show a demoted owner the owner-only notice without an error flash", %{scope: scope} do
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/operators")
    refute has_element?(view, "#operator-management-denied")

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin"})

    settle!(view)
    assert has_element?(view, "#operator-management-denied")
    refute has_element?(view, "#flash-error")
  end

  # The page's own patch: its path and decoded query, so the assertion does not
  # depend on how the query string orders its keys.
  defp patched_query(view, path) do
    patched = assert_patch(view)
    uri = URI.parse(patched)
    assert uri.path == path
    URI.decode_query(uri.query || "")
  end

  defp pool!(scope, label) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "p91-#{label}-#{unique_suffix()}", name: "P91 #{label}"})
    pool
  end

  defp request!(pool) do
    %{api_key: api_key} = active_api_key_fixture(pool)
    request_fixture(%{pool: pool, api_key: api_key})
  end

  defp invite!(scope, pool) do
    assert {:ok, %{invite: invite}} = Access.create_invite(scope, pool, %{"invited_email" => unique_user_email()})
    invite
  end

  defp second_assignment!(identity, pool) do
    now = DateTime.utc_now()

    Repo.insert!(%PoolUpstreamAssignment{
      pool_id: pool.id,
      upstream_identity_id: identity.id,
      assignment_label: "Second assignment",
      status: "active",
      health_status: "active",
      eligibility_status: "eligible",
      created_at: now,
      updated_at: now,
      metadata: %{}
    })
  end

  defp operator_conn!(owner_scope, role, pools \\ []) do
    %{user: operator} = operator_fixture(owner_scope, %{"email" => unique_user_email(), "role" => role, "password_change_required" => "false"})
    Enum.each(pools, &operator_pool_assignment_fixture(operator, &1, created_by_user_id: owner_scope.user.id))
    assert {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => valid_user_password()})
    %{user: operator, conn: build_conn() |> log_in_user(operator, token)}
  end

  defp open!(conn, path) do
    {:ok, view, _html} = live(conn, path)
    settle!(view)
    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp event_pool_ids(view), do: assigns(view).audit_logs.items |> Enum.map(& &1.pool_id) |> Enum.uniq()

  defp assignment_pool_ids(view), do: Enum.map(assigns(view).cockpit.assignments.items, & &1.pool_id)

  # The operator invalidation reaches the page's notification center, which
  # hands the change to the page as a message to itself: two fences order both
  # after the edit. Then any async reload the page started is awaited.
  defp settle!(view), do: settle!(view, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp settle!(view, deadline) do
    _ = :sys.get_state(view.pid)
    _ = :sys.get_state(view.pid)
    _ = render_async(view, 5_000)

    if Map.get(assigns(view), :cockpit_metrics_running?) == true do
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("the page did not finish loading")

      receive do
      after
        1 -> settle!(view, deadline)
      end
    end
  end

  defp unique_suffix, do: System.unique_integer([:positive])
end
