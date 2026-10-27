defmodule CodexPoolerWeb.Admin.StatsAsyncPauseLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  for outcome <- [:success, :exit] do
    @tag outcome: outcome
    test "pause retains the dashboard when an automatic task completes with #{outcome}", %{conn: conn, scope: scope, outcome: outcome} do
      {:ok, pool} = Pools.create_pool(scope, %{name: "Pause sample", slug: "pause-sample"})
      %{api_key: key} = api_key_fixture(pool)
      request_fixture(%{pool: pool, api_key: key})
      {:ok, view, _} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}")
      render_async(view)
      before = view |> element("#stats-kpi-requests") |> render()
      request_fixture(%{pool: pool, api_key: key})

      with_barrier(view, fn barrier ->
        reload(view)
        assert_receive {^barrier, task}, 5_000
        render_hook(view, "set_live_updates", %{"paused" => true})
        send(task, {barrier, if(outcome == :exit, do: :exit, else: :release)})
        render_async(view)
        assert has_element?(view, "#stats-kpi-requests")
        assert view |> element("#stats-kpi-requests") |> render() == before
        refute state(view).dashboard_loading?
        assert state(view).live_updates_page_held?
      end)

      render_hook(view, "set_live_updates", %{"paused" => false})
      render_async(view)
      assert has_element?(view, "#stats-kpi-requests", "2")
      refute state(view).stats_dashboard_rerun?
      assert is_nil(state(view).stats_reload_timer)
    end
  end

  test "a queued automatic rebuild stays held when an explicit build finishes while paused", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{name: "Queued automatic sample", slug: "queued-automatic-sample"})
    %{api_key: key} = api_key_fixture(pool)
    request_fixture(%{pool: pool, api_key: key})
    {:ok, view, _} = live(conn, ~p"/admin/stats")
    render_async(view)
    assert has_element?(view, "#stats-kpi-requests", "1")

    with_barrier(view, fn barrier ->
      view
      |> element("#stats-filter-form")
      |> render_submit(%{"filters" => %{"pool_id" => pool.id, "window" => "24h"}})

      assert_receive {^barrier, explicit_task}, 5_000
      request_fixture(%{pool: pool, api_key: key})
      reload(view)
      render_hook(view, "set_live_updates", %{"paused" => true})
      assert state(view).stats_dashboard_rerun?

      send(explicit_task, {barrier, :release})
      render_async(view)
      assert state(view).live_updates_page_held?
      refute state(view).dashboard_loading?
    end)

    render_hook(view, "set_live_updates", %{"paused" => false})
    render_async(view)
    assert has_element?(view, "#stats-kpi-requests", "2")
    refute state(view).stats_dashboard_rerun?
  end

  test "a queued explicit filter retains priority over automatic reloads while paused", %{conn: conn, scope: scope} do
    {:ok, first} = Pools.create_pool(scope, %{name: "First sample", slug: "first-sample"})
    {:ok, second} = Pools.create_pool(scope, %{name: "Second sample", slug: "second-sample"})
    %{api_key: key} = api_key_fixture(second)
    request_fixture(%{pool: second, api_key: key})
    {:ok, view, _} = live(conn, ~p"/admin/stats?pool_id=#{first.id}")
    render_async(view)

    with_barrier(view, fn barrier ->
      reload(view)
      assert_receive {^barrier, old_task}, 5_000
      view |> element("#stats-filter-form") |> render_submit(%{"filters" => %{"pool_id" => second.id, "window" => "1h"}})
      reload(view)
      render_hook(view, "set_live_updates", %{"paused" => true})
      :atomics.put(Process.get(barrier), 1, 1)
      send(old_task, {barrier, :release})
      assert_receive {^barrier, explicit_task}, 5_000
      send(explicit_task, {barrier, :release})
      render_async(view)
      assert has_element?(view, "#stats-kpi-requests", "1")
      assert has_element?(view, "#stats-time-filter[value='1h']")
      assert state(view).live_updates_paused?
    end)
  end

  test "initial and permission refreshes load while the session is paused", %{scope: scope} do
    {:ok, first} = Pools.create_pool(scope, %{name: "Visible sample", slug: "visible-sample"})
    {:ok, second} = Pools.create_pool(scope, %{name: "Granted sample", slug: "granted-sample"})
    %{user: operator} = operator_fixture(scope, %{"role" => "instance_admin", "password_change_required" => "false"})
    operator_pool_assignment_fixture(operator, first, created_by_user_id: scope.user.id)
    {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => valid_user_password()})
    conn = build_conn() |> log_in_user(operator, token) |> put_connect_params(%{"live_updates_paused" => true})
    {:ok, view, _} = live(conn, ~p"/admin/stats")
    render_async(view)
    assert state(view).live_updates_paused?
    assert has_element?(view, "#stats-kpi-requests")
    refute has_element?(view, "[data-pool-id='#{second.id}']")
    {:ok, _} = Accounts.update_operator(scope, operator, %{"pool_ids" => [second.id]})
    state(view)
    state(view)
    render_async(view)
    assert has_element?(view, "[data-pool-id='#{second.id}']")
    refute has_element?(view, "[data-pool-id='#{first.id}']")
    assert state(view).live_updates_paused?
    refute state(view).dashboard_loading?
  end

  defp state(view), do: :sys.get_state(view.pid).socket.assigns

  defp reload(view) do
    send(view.pid, {Events, %{pool_id: hd(MapSet.to_list(state(view).subscribed_pool_ids)), topics: ["usage"]}})
    timer = state(view).stats_reload_timer
    if is_reference(timer), do: Process.cancel_timer(timer, async: false, info: false)
    send(view.pid, :reload_stats_dashboard)
    state(view)
  end

  defp with_barrier(view, fun) do
    barrier = make_ref()
    parent = self()
    handler = {__MODULE__, barrier}
    gate = :atomics.new(1, [])
    :atomics.put(gate, 1, 1)
    Process.put(barrier, gate)
    tasks = :ets.new(:held_queries, [:public])

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata[:repo] == Repo and metadata[:options][:reporting_projection] == :stats_request_status_buckets and view.pid in Process.get(:"$callers", []) and :atomics.compare_exchange(gate, 1, 1, 0) == :ok do
            :ets.insert(tasks, {self()})
            monitor = Process.monitor(parent)
            send(parent, {barrier, self()})

            receive do
              {^barrier, :release} ->
                :ok

              {^barrier, :exit} ->
                Process.unlink(view.pid)
                Process.exit(self(), :kill)

              {:DOWN, ^monitor, :process, ^parent, _} ->
                :ok
            end

            Process.demonitor(monitor, [:flush])
          end
        end,
        nil
      )

    try do
      fun.(barrier)
    after
      :telemetry.detach(handler)
      for {pid} <- :ets.tab2list(tasks), do: send(pid, {barrier, :release})
      :ets.delete(tasks)
      Process.delete(barrier)

      if Process.alive?(view.pid) do
        for {_name, {_ref, pid, _kind}} <- :sys.get_state(view.pid).socket.private.live_async, do: send(pid, {barrier, :release})
        render_async(view)
      end
    end
  end
end
