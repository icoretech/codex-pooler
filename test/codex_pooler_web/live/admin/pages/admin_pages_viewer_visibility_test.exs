defmodule CodexPoolerWeb.Admin.AdminPagesViewerVisibilityTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Pools

  @detection_timeout_ms 15_000

  setup :register_and_log_in_user

  # Only the Pools page followed a viewer's role and Pool assignments; every
  # other admin page kept what it had read until the operator navigated
  # (findings#206 row 206-329). Each page below now re-reads what it shows when
  # its notification center reports that the viewer's role or visible Pools
  # changed. The producer is the real operator edit, which invalidates the
  # viewer's notification center.

  test "request logs drop a revoked Pool's rows and close its open request", %{scope: scope} do
    [kept, revoked] = for label <- ["logs-kept", "logs-revoked"], do: pool!(scope, label)
    kept_request = request!(kept)
    revoked_request = request!(revoked)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/request-logs?selected_request_id=#{revoked_request.id}")
    assert has_element?(view, "#request-log-row-#{revoked_request.id}")
    assert has_element?(view, "#request-log-row-#{kept_request.id}")
    assert assigns(view).selected_request_log.id == revoked_request.id

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert_patch(view, ~p"/admin/request-logs")
    settle!(view)
    refute has_element?(view, "#request-log-row-#{revoked_request.id}")
    assert has_element?(view, "#request-log-row-#{kept_request.id}")
    assert assigns(view).selected_request_log == nil
    assert assigns(view).visible_pool_ids == [kept.id]
    assert assigns(view).subscribed_pool_ids == MapSet.new([kept.id])
  end

  # A Pool or upstream account filter the viewer lost stayed in the address bar
  # while the page answered it with a filter error (findings#206 row 206-431):
  # the page patches the lost filters away, keeps the others, and the open
  # request of the lost Pool still closes through its own patch.
  test "request logs patch a Pool and upstream account filter the viewer lost out of the URL", %{scope: scope} do
    [kept, revoked] = for label <- ["logs-filter-kept", "logs-filter-revoked"], do: pool!(scope, label)
    kept_request = request!(kept)
    revoked_request = request!(revoked)
    %{identity: revoked_identity} = upstream_assignment_fixture(revoked, %{account_label: "Revoked filter upstream"})
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    params = %{"pool_id" => revoked.id, "upstream_identity_id" => revoked_identity.id, "status" => "succeeded", "selected_request_id" => revoked_request.id}
    view = open!(conn, ~p"/admin/request-logs?#{params}")
    assert assigns(view).selected_pool.id == revoked.id
    assert assigns(view).request_log_filters[:upstream_identity_id] == revoked_identity.id
    assert assigns(view).filter_errors == []

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert patched_query(view, "/admin/request-logs") == %{"status" => "succeeded", "selected_request_id" => revoked_request.id}
    settle!(view)
    assert patched_query(view, "/admin/request-logs") == %{"status" => "succeeded"}
    settle!(view)
    assert assigns(view).current_params == %{"status" => "succeeded"}
    assert assigns(view).filter_errors == []
    assert assigns(view).selected_request_log == nil
    assert has_element?(view, "#request-log-row-#{kept_request.id}")
    refute has_element?(view, "#request-log-row-#{revoked_request.id}")
  end

  test "request logs keep a Pool and upstream account filter the viewer still sees", %{scope: scope} do
    [kept, revoked] = for label <- ["logs-filter-stay", "logs-filter-gone"], do: pool!(scope, label)
    %{identity: kept_identity} = upstream_assignment_fixture(kept, %{account_label: "Kept filter upstream"})
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    params = %{"pool_id" => kept.id, "upstream_identity_id" => kept_identity.id}
    view = open!(conn, ~p"/admin/request-logs?#{params}")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).visible_pool_ids == [kept.id]
    assert assigns(view).current_params == params
    assert assigns(view).selected_pool.id == kept.id
    assert assigns(view).request_log_filters[:upstream_identity_id] == kept_identity.id
    assert assigns(view).filter_errors == []
  end

  test "an owner demoted on the request logs loses the owner-only navigation", %{scope: scope} do
    pools = for label <- ["logs-nav-first", "logs-nav-second"], do: pool!(scope, label)
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/request-logs")
    assert has_element?(view, "#admin-nav-jobs")
    assert has_element?(view, "#admin-nav-system")

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin", "pool_ids" => Enum.map(pools, & &1.id)})

    settle!(view)
    refute has_element?(view, "#admin-nav-jobs")
    refute has_element?(view, "#admin-nav-system")
    refute has_element?(view, "#admin-nav-operators")
  end

  test "stats rebuild for a granted Pool", %{scope: scope} do
    [first, granted] = for label <- ["stats-first", "stats-granted"], do: pool!(scope, label)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [first])

    view = open!(conn, ~p"/admin/stats")
    refute has_element?(view, "[data-pool-id='#{granted.id}']")

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [first.id, granted.id]})

    settle!(view)
    assert has_element?(view, "[data-pool-id='#{granted.id}']")
    assert assigns(view).subscribed_pool_ids == MapSet.new([first.id, granted.id])
    assert assigns(view).dashboard != nil
  end

  test "API keys drop a revoked Pool's keys and close the key editor on it", %{scope: scope} do
    [kept, revoked] = for label <- ["keys-kept", "keys-revoked"], do: pool!(scope, label)
    %{api_key: kept_key} = active_api_key_fixture(kept)
    %{api_key: revoked_key} = active_api_key_fixture(revoked)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/api-keys")
    render_click(view, "edit_api_key", %{"id" => revoked_key.id})
    assert assigns(view).editing_api_key.id == revoked_key.id

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).editing_api_key == nil
    assert has_element?(view, "#flash-info", "Your Pool access changed")
    refute render(view) =~ revoked_key.key_prefix
    assert render(view) =~ kept_key.key_prefix
  end

  test "API keys keep the key editor of a Pool the viewer still sees", %{scope: scope} do
    [kept, revoked] = for label <- ["keys-editor-kept", "keys-editor-revoked"], do: pool!(scope, label)
    %{api_key: kept_key} = active_api_key_fixture(kept)
    %{api_key: revoked_key} = active_api_key_fixture(revoked)
    %{user: admin, conn: conn} = operator_conn!(scope, "instance_admin", [kept, revoked])

    view = open!(conn, ~p"/admin/api-keys")
    render_click(view, "edit_api_key", %{"id" => kept_key.id})

    assert {:ok, _admin} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})

    settle!(view)
    assert assigns(view).editing_api_key.id == kept_key.id
    refute has_element?(view, "#flash-info")
    refute render(view) =~ revoked_key.key_prefix
  end

  test "upstreams close the Pool editor of a demoted owner and drop the owner controls", %{scope: scope} do
    pool = pool!(scope, "upstreams-edited")
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/upstreams?edit_pool_id=#{pool.id}&step=details")
    assert %{id: edited_id} = assigns(view).editing_pool
    assert edited_id == pool.id
    assert assigns(view).can_manage_pools?

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin", "pool_ids" => [pool.id]})

    settle!(view)
    assert_patch(view)
    settle!(view)
    assert assigns(view).editing_pool == nil
    refute assigns(view).can_manage_pools?
    assert has_element?(view, "#flash-info", "Your Pool access changed")
  end

  test "operators close a demoted owner's dialog and show the owner-only notice", %{scope: scope} do
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/operators")
    render_click(view, "open_create_operator", %{})
    assert assigns(view).creating_operator

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin"})

    settle!(view)
    refute assigns(view).creating_operator
    assert has_element?(view, "#operator-management-denied")
    refute has_element?(view, "#operator-page-create-action")
  end

  test "jobs remount for a demoted owner and for a promoted admin", %{scope: scope} do
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")
    view = open!(conn, ~p"/admin/jobs")
    assert assigns(view).owner_authorized?

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin"})
    assert_redirect(view, ~p"/admin/jobs", @detection_timeout_ms)

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    refute assigns(view).owner_authorized?

    assert {:ok, _owner} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_owner"})
    assert_redirect(view, ~p"/admin/jobs", @detection_timeout_ms)
  end

  test "system remounts for a demoted owner, and keeps an owner's open forms when only a Pool changes", %{scope: scope} do
    pool = pool!(scope, "system-disabled")
    %{user: second_owner, conn: conn} = operator_conn!(scope, "instance_owner")

    view = open!(conn, ~p"/admin/system")
    assert assigns(view).owner_authorized?

    assert {:ok, _disabled} = Pools.change_pool_status(scope, pool, "disabled")
    settle!(view)
    refute_live_redirect(view)
    assert assigns(view).owner_authorized?

    assert {:ok, _admin} = Accounts.update_operator(scope, second_owner, %{"role" => "instance_admin"})
    assert_redirect(view, "/admin/system?tab=smtp", @detection_timeout_ms)
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
    {:ok, pool} = Pools.create_pool(scope, %{slug: "p86-#{label}-#{unique_suffix()}", name: "P86 #{label}"})
    pool
  end

  defp request!(pool) do
    %{api_key: api_key} = active_api_key_fixture(pool)
    request_fixture(%{pool: pool, api_key: api_key})
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

  # The operator invalidation reaches the page's notification center, which
  # hands the change to the page as a message to itself: two fences order both
  # after the edit. Then any async reload the page started is awaited.
  defp settle!(view), do: settle!(view, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp settle!(view, deadline) do
    _ = :sys.get_state(view.pid)
    _ = :sys.get_state(view.pid)
    _ = render_async(view, 5_000)
    assigns = assigns(view)

    if loading?(assigns) do
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("the page did not finish loading")

      receive do
      after
        1 -> settle!(view, deadline)
      end
    end
  end

  defp loading?(assigns) do
    Map.get(assigns, :request_logs_loading?) == true or Map.get(assigns, :request_logs_running?) == true or
      Map.get(assigns, :dashboard_loading?) == true or Map.get(assigns, :upstreams_reload_running?) == true
  end

  # A `push_navigate` reaches the test through the view's client proxy; fence
  # the proxy too before reading the mailbox.
  defp refute_live_redirect(%{proxy: {ref, topic, proxy_pid}} = view) do
    _ = :sys.get_state(view.pid)
    _ = :sys.get_state(proxy_pid)

    receive do
      {^ref, {:live_redirect, ^topic, %{to: to}}} -> flunk("unexpected live redirect to #{to}")
    after
      0 -> :ok
    end
  end

  defp unique_suffix, do: System.unique_integer([:positive])
end
