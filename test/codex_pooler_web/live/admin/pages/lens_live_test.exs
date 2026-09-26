defmodule CodexPoolerWeb.Admin.LensLiveTest do
  use CodexPoolerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures
  import CodexPooler.AccountsFixtures
  alias CodexPooler.Accounts
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "browser buttons select window, model and evidence despite their native empty value", %{conn: conn, scope: scope} do
    {_pool, setup, assignment} = data_pool(scope, "lens-browser-filters")
    request_fixture(setup) |> attempt_fixture(assignment, %{served_model: "model-other"})
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens")

    for {field, value} <- [{"window", "1h"}, {"sent_model", "upstream-gpt-6-luna"}, {"evidence", "mismatch"}] do
      selector = "#model-history-filter [data-role='#{field}-filter-option'][data-value='#{value}']"
      # The browser's native button.value is present even without a value attribute.
      # LiveViewTest only sees attributes, so explicitly include the real client value.
      view |> element(selector) |> render_click(%{"value" => ""})
      assert_patch(view)
      assigns = await_lens(view)
      assert assigns.params[field] == value
      assert has_element?(view, "#filters_#{field}[value='#{value}']")
      assert has_element?(view, selector <> "[aria-current=true]")
    end

    assert lens_assigns(view).params == %{"window" => "1h", "pool_id" => "", "sent_model" => "upstream-gpt-6-luna", "upstream_identity_id" => "", "evidence" => "mismatch"}
    for %{"data" => data} <- chart_series(view, "lens-signals-plot"), do: assert(length(data) == 12)
  end

  test "history filters and underlying attempt details retain unknown coverage and retry attribution", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{name: "Sample observations", slug: "sample-observations"})
    setup = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    request = request_fixture(setup)
    conflict = %{"version" => 1, "coverage" => "full", "conflict" => true, "first_conflicting_model" => "model-b", "terminal_model" => "model-a", "terminal_status" => "completed"}
    first = attempt_fixture(request, assignment, %{served_model: "model-a", model_observation: conflict})
    last = attempt_fixture(request, assignment, %{attempt_number: 2})

    {:ok, view, _html} = live_lens(conn, ~p"/admin/lens")
    assert page_title(view) == "Lens - Codex Pooler"
    assert has_element?(view, "#admin-nav-audit-logs + #admin-nav-lens[href='/admin/lens'][aria-current=page]", "Lens")
    assert has_element?(view, "#admin-nav-lens .hero-magnifying-glass")
    assert has_element?(view, "#lens-guide-link[href='https://docs.codex-pooler.com/operators/lens/'][target='_blank'][rel='noopener noreferrer']")
    assert has_element?(view, "#lens-signal-help", "Pooler sent model A, but the provider first reported model B")
    assert has_element?(view, "#lens-signal-help", "then model B during the same attempt")
    assert has_element?(view, "[data-role=model-count-mismatches]", "Different from sent")
    assert has_element?(view, "[data-role=model-count-conflicts]", "Name changed in response")
    refute has_element?(view, "#admin-nav-request-logs[aria-current=page]")
    assert has_element?(view, "#model-history-counts + #lens-charts")
    assert has_element?(view, "#lens-signals-plot[phx-hook=ApexTimeSeriesChart][data-chart-stacked=false]")
    assert has_element?(view, "#lens-models [data-role=model-pair]", "upstream-gpt-6-luna")
    assert has_element?(view, "#lens-models [data-role=model-pair]", "model-b")
    refute has_element?(view, "#lens-coverage-plot")
    refute has_element?(view, "#model-history-header button")
    refute has_element?(view, "#lens-updated-at")
    assert has_element?(view, "#lens-signals > header #lens-view-conflicts")
    assert has_element?(view, "#lens-signals > header #lens-view-mismatches")
    assert has_element?(view, "#model-history-filter-advanced #filters_upstream_identity_id")
    assert has_element?(view, "#lens-pool-filter [data-role=pool-filter-icon]")
    assert has_element?(view, "#lens-evidence-filter [data-value=conflict] .hero-exclamation-triangle.text-error")
    assert has_element?(view, "#lens-evidence-filter [data-value=mismatch] .hero-arrows-right-left.text-warning")
    assert has_element?(view, "#lens-model-filter [data-value='upstream-gpt-6-luna']")
    assert length(render(view) |> LazyHTML.from_fragment() |> LazyHTML.query("#model-history-filter [data-role=filter-fields] > div") |> Enum.to_list()) == 4
    signals = chart_series(view, "lens-signals-plot")
    assert [%{"data" => mismatches}, %{"data" => conflicts}] = signals
    assert Enum.sum(mismatches) == 1
    assert Enum.sum(conflicts) == 1
    assert has_element?(view, "#model-history-coverage", "Recording details (info)")
    assert has_element?(view, "#model-history-groups a[href^='/admin/lens?']")
    assert has_element?(view, "[data-role=model-count-total]", "2")
    assert has_element?(view, "[data-role=model-count-conflicts]", "1")
    assert has_element?(view, "[data-role=model-count-uncollected]", "1")
    assert has_element?(view, "#model-history-attempt-#{first.id}")
    refute has_element?(view, "#model-history-attempt-#{last.id}")
    view |> element("#lens-evidence-filter [data-value=all]") |> render_click()
    await_lens(view)
    assert has_element?(view, "#model-history-attempt-#{last.id}")
    view |> element("#lens-view-conflicts") |> render_click()
    assert_patch(view, ~p"/admin/lens?#{%{"window" => "24h", "pool_id" => "", "upstream_identity_id" => "", "sent_model" => "", "evidence" => "conflict"}}")
    await_lens(view)
    assert chart_series(view, "lens-signals-plot") == signals
    assert has_element?(view, "#model-history-attempt-#{first.id}")
    refute has_element?(view, "#model-history-attempt-#{last.id}")
    assert has_element?(view, "#model-history-attempt-#{first.id} a[href*='selected_request_id=#{request.id}']")

    {:ok, detail, _html} = live(conn, ~p"/admin/request-logs?#{%{selected_request_id: request.id}}")
    render_async(detail)
    assert has_element?(detail, "[data-role=model-declaration-conflict]", "attempts 1")
    assert has_element?(detail, "[data-role=model-declaration-conflict]", "model name changed")
    assert has_element?(detail, "#request-log-detail-attempt-1-model-conflict", "Model name changed within response")
    assert has_element?(detail, "#request-log-detail-attempt-1-model-first-conflict", "model-b")
    assert has_element?(detail, "#request-log-detail-attempt-1-model-terminal", "model-a")
    assert has_element?(detail, "#request-log-detail-attempt-2-model-coverage", "Not collected")
  end

  test "affected group links select only signals within that group's scope", %{conn: conn, scope: scope} do
    {pool, setup, assignment} = data_pool(scope, "lens-group-signals")
    signal = request_fixture(setup) |> attempt_fixture(assignment, %{served_model: "model-other"})
    ordinary = add_attempt(setup, assignment)
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?evidence=all")
    assert has_element?(view, "#model-history-attempt-#{ordinary.id}")

    view |> element("#model-history-groups a") |> render_click()
    assert_patch(view, ~p"/admin/lens?#{%{window: "24h", pool_id: pool.id, upstream_identity_id: assignment.upstream_identity_id, sent_model: "upstream-gpt-6-luna", evidence: "signals"}}")
    await_lens(view)
    assert has_element?(view, "#model-history-attempt-#{signal.id}")
    refute has_element?(view, "#model-history-attempt-#{ordinary.id}")
  end

  test "no retained attempts uses the shared empty state and filters stay active", %{conn: conn} do
    {:ok, view, _html} = live_lens(conn, ~p"/admin/lens")
    assert has_element?(view, "#model-history-empty.border-dashed", "No retained attempts")
    assert has_element?(view, "#model-history-empty .hero-magnifying-glass")
    refute has_element?(view, "#lens-charts")

    view |> element("#lens-window-filter [data-value='1h']") |> render_click()
    assert_patch(view, ~p"/admin/lens?#{%{window: "1h", pool_id: "", upstream_identity_id: "", sent_model: "", evidence: "signals"}}")
    await_lens(view)
    assert has_element?(view, "#model-history-empty", "No retained attempts")
    assert lens_assigns(view).history.bucket_seconds == 300
    assert length(lens_assigns(view).history.timeline) == 12
  end

  test "a retained signal without its upstream identity has no misleading broad group link", %{conn: conn, scope: scope} do
    {pool, setup, assignment} = data_pool(scope, "lens-removed-upstream")
    request_fixture(setup) |> attempt_fixture(assignment, %{served_model: "model-other"})
    request_fixture(setup) |> attempt_fixture(assignment, %{served_model: "model-other"}) |> Ecto.Changeset.change(upstream_identity_id: nil) |> Repo.update!()
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{pool.id}")
    document = render(view) |> LazyHTML.from_fragment()
    assert length(Enum.to_list(LazyHTML.query(document, "#model-history-groups tbody tr"))) == 2
    assert length(Enum.to_list(LazyHTML.query(document, "#model-history-groups a"))) == 1
    assert has_element?(view, "#model-history-groups td > span", "Unavailable")
    assert length(lens_assigns(view).history.attempts) == 2
  end

  test "healthy and unknown attempts keep coverage but no affected groups or zero plots", %{conn: conn, scope: scope} do
    {pool, setup, assignment} = data_pool(scope, "lens-no-signals")
    request_fixture(setup) |> attempt_fixture(assignment, %{served_model: "upstream-gpt-6-luna"})
    request_fixture(setup) |> attempt_fixture(assignment, %{model_observation: %{"version" => 1, "coverage" => "full", "conflict" => nil, "terminal_status" => "completed"}})
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{pool.id}")
    assert has_element?(view, "#lens-signals-empty.border-dashed", "No model differences observed")
    assert has_element?(view, "#lens-signals-empty .hero-magnifying-glass")
    assert has_element?(view, "#model-history-coverage", "1 without a model name")
    assert has_element?(view, "[data-role=model-count-total]", "2")
    assert lens_assigns(view).history.groups == []

    request_fixture(setup) |> attempt_fixture(assignment, %{served_model: "model-other"})
    view |> element("#lens-evidence-filter [data-value=conflict]") |> render_click(%{"value" => ""})
    await_lens(view)
    assert has_element?(view, "#model-history-empty.border-dashed", "No matching attempts")
    assert has_element?(view, "#model-history-empty .hero-document-magnifying-glass")
  end

  test "initial HTTP response renders a loading state without running history queries", %{conn: conn} do
    handler = {__MODULE__, make_ref()}
    parent = self()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata[:options][:reporting_projection] == :lens_model_history, do: send(parent, {handler, :history_query})
        end,
        nil
      )

    response = get(conn, ~p"/admin/lens")
    document = response |> html_response(200) |> LazyHTML.from_document()
    assert length(Enum.to_list(LazyHTML.query(document, "#lens-loading"))) == 1
    assert Enum.to_list(LazyHTML.query(document, "#lens-charts")) == []
    refute_received {^handler, :history_query}
  end

  test "live Pool events coalesce, pause holds an armed reload, and resume updates once", %{conn: conn, scope: scope} do
    {pool, setup, assignment} = data_pool(scope, "lens-pause")
    add_attempt(setup, assignment)
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{pool.id}")
    initial = lens_assigns(view)
    assert initial.subscribed_pool_ids == MapSet.new([pool.id])
    add_attempt(setup, assignment)
    assert {:ok, _} = Events.broadcast_request_logs(pool.id, "request_finalized", %{})
    await_condition(fn -> is_reference(lens_assigns(view).history_reload_timer) end)
    timer = lens_assigns(view).history_reload_timer
    send(view.pid, {Events, %{pool_id: pool.id, topics: ["request_logs"]}})
    assert lens_assigns(view).history_reload_timer == timer

    render_hook(view, "set_live_updates", %{"paused" => true})
    fire_reload(view)
    assert lens_assigns(view).history_reload_timer == nil
    assert lens_assigns(view).history_generation == initial.history_generation
    assert has_element?(view, "[data-role=model-count-total]", "1")

    send(view.pid, {Events, %{pool_id: pool.id, topics: ["request_logs"]}})
    send(view.pid, {Events, %{pool_id: pool.id, topics: ["request_logs"]}})
    assert lens_assigns(view).history_generation == initial.history_generation
    render_hook(view, "set_live_updates", %{"paused" => false})
    await_condition(fn -> lens_assigns(view).history_generation > initial.history_generation end)
    final = await_lens(view)
    assert final.history_generation == initial.history_generation + 1
    assert final.history_reload_timer == nil
    assert has_element?(view, "[data-role=model-count-total]", "2")

    send(view.pid, {Events, %{pool_id: Ecto.UUID.generate(), topics: ["request_logs"]}})
    assert lens_assigns(view).history_reload_timer == nil
    assert lens_assigns(view).history_generation == final.history_generation
  end

  test "pause discards an in-flight automatic result and resume reloads the snapshot", %{conn: conn, scope: scope} do
    {pool, setup, assignment} = data_pool(scope, "lens-inflight-pause")
    add_attempt(setup, assignment)
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{pool.id}")
    add_attempt(setup, assignment)
    handler = block_loads(view)
    send(view.pid, {Events, %{pool_id: pool.id, topics: ["request_logs"]}})
    fire_reload(view)
    assert_receive {^handler, task}, 5_000
    on_exit(fn -> send(task, {handler, :release}) end)
    refute task == view.pid
    render_hook(view, "set_live_updates", %{"paused" => true})
    :telemetry.detach(handler)
    send(task, {handler, :release})
    assigns = await_lens(view)
    assert assigns.live_updates_page_held?
    assert has_element?(view, "[data-role=model-count-total]", "1")
    render_hook(view, "set_live_updates", %{"paused" => false})
    await_condition(fn -> lens_assigns(view).history_generation > assigns.history_generation end)
    await_lens(view)
    assert has_element?(view, "[data-role=model-count-total]", "2")
    refute lens_assigns(view).live_updates_paused?
  end

  test "a paused browser join still loads once and allows explicit filters", %{conn: conn, scope: scope} do
    {pool, setup, assignment} = data_pool(scope, "lens-paused-join")
    add_attempt(setup, assignment)
    conn = put_connect_params(conn, %{"live_updates_paused" => true})
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{pool.id}")
    initial = lens_assigns(view)
    assert initial.live_updates_paused?
    assert has_element?(view, "[data-role=model-count-total]", "1")
    send(view.pid, {Events, %{pool_id: pool.id, topics: ["request_logs"]}})
    assert lens_assigns(view).history_reload_timer == nil
    view |> element("#lens-window-filter [data-value='1h']") |> render_click()
    assigns = await_lens(view)
    assert assigns.history_generation == initial.history_generation + 1
    assert assigns.history.filters["window"] == "1h"
    assert assigns.live_updates_paused?
  end

  test "a newer filter replaces a blocked asynchronous load without publishing stale results", %{conn: conn, scope: scope} do
    {first, first_setup, first_assignment} = data_pool(scope, "lens-stale-first")
    {second, second_setup, second_assignment} = data_pool(scope, "lens-stale-second")
    add_attempt(first_setup, first_assignment)
    add_attempt(second_setup, second_assignment)
    add_attempt(second_setup, second_assignment)
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{first.id}")
    handler = block_loads(view)
    send(view.pid, {Events, %{pool_id: first.id, topics: ["request_logs"]}})
    fire_reload(view)
    assert_receive {^handler, first_task}, 5_000
    on_exit(fn -> send(first_task, {handler, :release}) end)
    view |> element("#lens-pool-filter [data-pool-id='#{second.id}']") |> render_click()
    assert has_element?(view, "#lens-loading")
    refute has_element?(view, "#lens-charts")
    send(first_task, {handler, :release})
    assert_receive {^handler, next_task}, 5_000
    on_exit(fn -> send(next_task, {handler, :release}) end)
    refute first_task == next_task
    refute has_element?(view, "#lens-charts")
    :telemetry.detach(handler)
    send(next_task, {handler, :release})
    assigns = await_lens(view)
    assert assigns.history.filters["pool_id"] == second.id
    assert assigns.subscribed_pool_ids == MapSet.new([second.id])
    assert has_element?(view, "[data-role=model-count-total]", "2")
  end

  @tag capture_log: true
  test "failed automatic and filtered loads offer a working retry even while paused", %{conn: conn, scope: scope} do
    {pool, setup, assignment} = data_pool(scope, "lens-failed-load")
    add_attempt(setup, assignment)
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{pool.id}")
    handler = block_loads(view)
    send(view.pid, {Events, %{pool_id: pool.id, topics: ["request_logs"]}})
    fire_reload(view)
    assert_receive {^handler, task}, 5_000
    :telemetry.detach(handler)
    send(task, {handler, :fail})
    await_lens(view)
    assert has_element?(view, "#lens-refresh-error")
    assert has_element?(view, "#lens-charts")
    render_hook(view, "set_live_updates", %{"paused" => true})
    view |> element("#lens-retry") |> render_click()
    await_lens(view)
    refute has_element?(view, "#lens-refresh-error")
    assert lens_assigns(view).live_updates_paused?

    handler = block_loads(view)
    view |> element("#lens-window-filter [data-value='1h']") |> render_click(%{"value" => ""})
    assert_receive {^handler, task}, 5_000
    :telemetry.detach(handler)
    send(task, {handler, :fail})
    await_lens(view)
    assert has_element?(view, "#lens-error.border-dashed", "Lens could not be loaded")
    assert has_element?(view, "#lens-error #lens-retry", "Retry")
    view |> element("#lens-retry") |> render_click()
    await_lens(view)
    assert has_element?(view, "[data-role=model-count-total]", "1")
  end

  test "permission changes replace the visible population even while live updates are paused", %{scope: scope} do
    {kept, setup, assignment} = data_pool(scope, "lens-scope-kept")
    {revoked, other_setup, other_assignment} = data_pool(scope, "lens-scope-revoked")
    add_attempt(setup, assignment)
    add_attempt(other_setup, other_assignment)
    %{user: admin} = operator_fixture(scope, %{"role" => "instance_admin", "pool_ids" => [kept.id, revoked.id], "password_change_required" => "false"})
    {:ok, login} = Accounts.login_user(%{"email" => admin.email, "password" => valid_user_password()})
    conn = log_in_user(build_conn(), admin, login.token)
    {:ok, view, _} = live_lens(conn, ~p"/admin/lens?pool_id=#{revoked.id}")
    assert has_element?(view, "[data-role=model-count-total]", "1")
    render_hook(view, "set_live_updates", %{"paused" => true})
    assert {:ok, _} = Accounts.update_operator(scope, admin, %{"pool_ids" => [kept.id]})
    await_condition(fn -> lens_assigns(view).current_scope.assigned_pool_ids == [kept.id] end)
    assigns = await_lens(view)
    assert assigns.params["pool_id"] == ""
    assert_patch(view, ~p"/admin/lens?#{%{window: "24h", pool_id: "", upstream_identity_id: "", sent_model: "", evidence: "signals"}}")
    assert assigns.subscribed_pool_ids == MapSet.new([kept.id])
    assert has_element?(view, "[data-role=model-count-total]", "1")
    refute has_element?(view, "#lens-pool-filter [data-pool-id='#{revoked.id}']")
  end

  defp data_pool(scope, slug) do
    {:ok, pool} = Pools.create_pool(scope, %{name: slug, slug: slug})
    setup = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    {pool, setup, assignment}
  end

  defp add_attempt(setup, assignment), do: setup |> request_fixture() |> attempt_fixture(assignment)
  defp lens_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp fire_reload(view) do
    if timer = lens_assigns(view).history_reload_timer, do: Process.cancel_timer(timer)
    send(view.pid, :reload_lens)
    lens_assigns(view)
  end

  defp block_loads(view) do
    handler = {__MODULE__, make_ref()}
    parent = self()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata[:repo] == Repo and metadata[:options][:reporting_projection] == :lens_model_history do
            hold_load(parent, handler, view.pid)
          end
        end,
        nil
      )

    handler
  end

  defp hold_load(parent, handler, view_pid) do
    send(parent, {handler, self()})
    if self() == view_pid, do: raise("history query ran on the LiveView")

    receive do
      {^handler, :release} -> :ok
      # Dynamic Repo is process-local: only this task's next real query fails.
      {^handler, :fail} -> Repo.put_dynamic_repo(:lens_unavailable_test_repo)
    after
      15_000 -> raise "Lens test load barrier not released"
    end
  end

  defp await_condition(fun), do: await_condition(fun, System.monotonic_time(:millisecond) + 15_000)

  defp await_condition(fun, deadline) do
    unless fun.() do
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("Lens state did not reach the expected condition")

      receive do
      after
        1 -> await_condition(fun, deadline)
      end
    end
  end

  defp chart_series(view, id) do
    view |> element("##{id}") |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("##{id}") |> LazyHTML.attribute("data-chart-series") |> List.first() |> CodexPooler.JSON.decode!()
  end

  defp live_lens(conn, path) do
    with {:ok, view, html} <- live(conn, path) do
      await_lens(view)
      {:ok, view, html}
    end
  end

  defp await_lens(view), do: await_lens(view, System.monotonic_time(:millisecond) + 15_000)

  defp await_lens(view, deadline) do
    render_async(view, 5_000)
    assigns = :sys.get_state(view.pid).socket.assigns

    if assigns.history_loading? or assigns.history_running? do
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("Lens did not finish its async load")

      receive do
      after
        1 -> await_lens(view, deadline)
      end
    else
      assigns
    end
  end
end
