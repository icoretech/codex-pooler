defmodule CodexPoolerWeb.Admin.ApiKeysLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_and_log_in_user

  test "guides operators to create a Pool before API keys", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-page-create-action[href='/admin/pools']", "Create Pool")
    assert has_element?(view, "#api-key-empty-state", "Create a Pool before adding API keys.")
    assert has_element?(view, "#api-key-empty-create-action[href='/admin/pools']", "Create Pool")
    refute has_element?(view, "#api-key-page-create-action[disabled]")
    refute has_element?(view, "#api-key-empty-create-action[disabled]")
  end

  test "unassigned instance admins do not get Pool creation CTAs on API keys", %{scope: scope} do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "unassigned-api-admin@example.com",
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-empty-state")
    refute has_element?(view, "#api-key-page-create-action")
    refute has_element?(view, "#api-key-empty-create-action")
  end

  test "renders required form, grouped registries, row, and action selectors", %{
    conn: conn,
    scope: scope
  } do
    {:ok, primary_pool} =
      Pools.create_pool(scope, %{slug: "primary-pool", name: "Primary Pool"})

    {:ok, backup_pool} =
      Pools.create_pool(scope, %{slug: "backup-pool", name: "Backup Pool"})

    {:ok, %{api_key: primary_key, raw_key: primary_raw_key}} =
      Access.create_api_key(scope, primary_pool, %{
        display_name: "Primary selector key",
        policy: %{
          allowed_model_identifiers: ["gpt-primary"],
          metadata: %{"labels" => [], "operator_notes" => "selector notes"}
        }
      })

    {:ok, %{api_key: primary_extra_key, raw_key: primary_extra_raw_key}} =
      Access.create_api_key(scope, primary_pool, %{
        display_name: "Primary extra key",
        policy: %{allowed_model_identifiers: ["gpt-primary-extra"]}
      })

    {:ok, %{api_key: backup_key, raw_key: backup_raw_key}} =
      Access.create_api_key(scope, backup_pool, %{
        display_name: "Backup selector key",
        policy: %{allowed_model_identifiers: ["gpt-backup"]}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert has_element?(view, "#admin-api-keys-live")
    assert has_element?(view, "#admin-api-keys")
    assert has_element?(view, "#api-key-page-create-action")
    assert has_element?(view, "#api-key-pool-group-primary-pool", "Primary Pool")
    assert has_element?(view, "#api-key-pool-group-primary-pool-table-scroll-region")

    assert has_element?(view, "#api-key-pool-group-primary-pool-count", "2 keys")
    assert has_element?(view, "#api-key-pool-group-backup-pool", "Backup Pool")
    assert has_element?(view, "#api-key-pool-group-backup-pool-table-scroll-region")

    assert has_element?(view, "#api-key-pool-group-backup-pool-count", "1 key")

    for group_id <- ["primary-pool", "backup-pool"] do
      assert has_element?(
               view,
               "#api-key-pool-group-#{group_id}-table-scroll-region > article[id^='api-key-row-']"
             )
    end

    primary_group_html = view |> element("#api-key-pool-group-primary-pool") |> render()
    backup_group_html = view |> element("#api-key-pool-group-backup-pool") |> render()

    assert primary_group_html =~ "Primary selector key"
    assert primary_group_html =~ "Primary extra key"
    refute primary_group_html =~ "Backup selector key"
    assert backup_group_html =~ "Backup selector key"
    refute backup_group_html =~ "Primary selector key"
    refute backup_group_html =~ "Primary extra key"
    refute has_element?(view, "#api-key-row-#{primary_key.id}-pool")

    refute has_element?(view, "#api-key-form")

    open_create_dialog(view)

    assert has_element?(view, "#api-key[open]")
    assert has_element?(view, "#api-key-form")

    assert has_element?(
             view,
             "#api-key-footer [data-role='policy-editor-docs-link'][href='https://docs.codex-pooler.com/operators/api-keys/#create-api-key'][target='_blank'][rel='noopener noreferrer'].text-xs",
             "Docs"
           )

    assert has_element?(view, "#api-key-docs-link [data-role='policy-editor-docs-icon']")
    assert has_element?(view, "#api-key-header")
    assert has_element?(view, "#api-key-sections")
    assert has_element?(view, "#api-key-tabs[role='tablist']")
    assert has_element?(view, "#api-key-step-basics")
    assert has_element?(view, "#api-key-step-models")
    assert has_element?(view, "#api-key-step-limits")
    assert has_element?(view, "#api-key-step-review")
    assert has_element?(view, "#api-key-tab-basics[aria-selected='true']")
    assert has_element?(view, "#api-key-tab-models[role='tab']")
    assert has_element?(view, "#api-key-tab-limits[role='tab']")
    assert has_element?(view, "#api-key-tab-review[role='tab']")
    assert has_element?(view, "#api-key-section-basics[role='tabpanel']")
    assert has_element?(view, "#api-key-section-models[role='tabpanel']")
    assert has_element?(view, "#api-key-section-limits[role='tabpanel']")
    assert has_element?(view, "#api-key-section-review[role='tabpanel']")
    assert has_element?(view, "#api-key-step-basics-panel")
    assert has_element?(view, "#api-key-step-models-panel")
    assert has_element?(view, "#api-key-step-limits-panel")
    assert has_element?(view, "#api-key-step-review-panel")
    assert has_element?(view, "#api_key_display_name")
    assert has_element?(view, "#api_key_pool_id")

    assert has_element?(
             view,
             "#api_key_pool_id option[value='#{primary_pool.id}']",
             "Primary Pool"
           )

    pool_select_html = view |> element("#api_key_pool_id") |> render()
    refute pool_select_html =~ "primary-pool"
    assert has_element?(view, "#api_key_status")
    assert has_element?(view, "#api_key_expires_at")
    assert has_element?(view, "#api_key_operator_notes")
    assert_no_cost_limit_controls(view)

    select_api_key_section(view, :models)
    assert_api_key_section(view, :models)
    assert has_element?(view, "#api-key-model-mode-selected")
    assert has_element?(view, "#api_key_manual_model_identifiers_text")
    assert has_element?(view, "#api_key_enforced_model_identifier")
    assert has_element?(view, "#api-key-reasoning-policy[aria-describedby]")
    assert has_element?(view, "#api-key-reasoning-policy legend", "Reasoning effort policy")
    assert has_element?(view, "#api_key_reasoning_policy_mode_unrestricted[checked]")
    assert has_element?(view, "#api_key_reasoning_policy_mode_allow_up_to[value='allow_up_to']")
    assert has_element?(view, "#api_key_reasoning_policy_mode_always_use[value='always_use']")
    refute has_element?(view, "#api_key_enforced_reasoning_effort")
    refute has_element?(view, "#api_key_maximum_reasoning_effort")

    assert has_element?(view, "#api_key_enforced_service_tier")
    assert has_element?(view, "#api_key_enforced_service_tier option", "Leave unchanged")
    assert has_element?(view, "#api_key_enforced_service_tier option", "Auto - upstream chooses")
    assert has_element?(view, "#api_key_enforced_service_tier option", "Scale - scale capacity")
    refute has_element?(view, "#api_key_enforced_service_tier option[value='ultrafast']")

    select_api_key_section(view, :limits)
    assert_api_key_section(view, :limits)
    assert has_element?(view, "#api_key_default_max_tokens_per_week")
    assert_no_cost_limit_controls(view)

    select_api_key_section(view, :review)
    assert_api_key_section(view, :review)
    assert has_element?(view, "#api-key-review-summary")
    refute has_element?(view, "#api-key-usage-summary")
    assert_no_cost_limit_controls(view)

    assert has_element?(view, "#api-key-row-#{primary_key.id}", "Primary selector key")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-status", "active")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-last-used", "Never used")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-expires", "No expiry")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-models", "gpt-primary")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-notes")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-notes-content", "selector notes")
    assert has_element?(view, "#api-key-actions-menu-#{primary_key.id}")
    assert has_element?(view, "#disable-api-key-#{primary_key.id}")
    assert has_element?(view, "#enable-api-key-#{primary_key.id}")
    assert has_element?(view, "#rotate-api-key-#{primary_key.id}")
    assert has_element?(view, "#revoke-api-key-#{primary_key.id}")
    assert has_element?(view, "#delete-api-key-#{primary_key.id}")
    assert has_element?(view, "#api-key-row-#{primary_extra_key.id}", "Primary extra key")
    assert has_element?(view, "#api-key-row-#{backup_key.id}", "Backup selector key")

    html = render(view)
    refute html =~ primary_raw_key
    refute html =~ primary_extra_raw_key
    refute html =~ backup_raw_key

    key_cell_html = view |> element("#api-key-row-#{primary_key.id}-key") |> render()
    refute key_cell_html =~ "Primary Pool"
  end

  test "orders grouped API keys by lifecycle, name, then newest creation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "sorted-pool", name: "Sorted Pool"})

    create_key = fn name, status ->
      {:ok, %{api_key: api_key}} = Access.create_api_key(scope, pool, %{display_name: name})

      api_key
      |> Ecto.Changeset.change(%{status: status})
      |> Repo.update!()
    end

    zulu_revoked = create_key.("zulu revoked key", "revoked")
    alpha_revoked = create_key.("alpha revoked key", "revoked")
    paused = create_key.("paused key", "paused")
    zulu_active = create_key.("zulu active key", "active")
    alpha_active = create_key.("alpha active key", "active")

    # Duplicate names (key rotations) break the tie on the newest creation.
    twin_older = create_key.("twin rotation key", "active")
    twin_newer = create_key.("twin rotation key", "active")

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    group_html = view |> element("#api-key-pool-group-sorted-pool") |> render()

    positions =
      for api_key <- [
            alpha_active,
            twin_newer,
            twin_older,
            zulu_active,
            paused,
            alpha_revoked,
            zulu_revoked
          ] do
        :binary.match(group_html, "api-key-row-#{api_key.id}") |> elem(0)
      end

    assert positions == Enum.sort(positions)
  end

  test "filters grouped API keys from pool_id query params", %{conn: conn, scope: scope} do
    {:ok, primary_pool} =
      Pools.create_pool(scope, %{slug: "filtered-primary", name: "Filtered Primary"})

    {:ok, backup_pool} =
      Pools.create_pool(scope, %{slug: "filtered-backup", name: "Filtered Backup"})

    {:ok, disabled_pool} =
      Pools.create_pool(scope, %{slug: "filtered-disabled", name: "Filtered Disabled"})

    {:ok, %{api_key: primary_key, raw_key: primary_raw_key}} =
      Access.create_api_key(scope, primary_pool, %{display_name: "Filtered primary key"})

    {:ok, %{api_key: backup_key, raw_key: backup_raw_key}} =
      Access.create_api_key(scope, backup_pool, %{display_name: "Filtered backup key"})

    {:ok, %{api_key: disabled_key, raw_key: disabled_raw_key}} =
      Access.create_api_key(scope, disabled_pool, %{display_name: "Filtered disabled key"})

    assert {:ok, disabled_pool} = Pools.change_pool_status(scope, disabled_pool, "disabled")

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys?pool_id=#{primary_pool.id}")

    assert has_element?(view, "#api-key-active-pool-filter", "Filtered Primary")
    assert has_element?(view, "#api-key-clear-pool-filter", "Show all Pools")
    assert has_element?(view, "#api-key-pool-group-filtered-primary", "Filtered Primary")
    refute has_element?(view, "#api-key-pool-group-filtered-backup")
    assert has_element?(view, "#api-key-row-#{primary_key.id}", "Filtered primary key")
    refute has_element?(view, "#api-key-row-#{backup_key.id}")
    refute has_element?(view, "#api-key-row-#{disabled_key.id}")

    view
    |> element("#api-key-clear-pool-filter")
    |> render_click()

    assert_patch(view, ~p"/admin/api-keys")
    refute has_element?(view, "#api-key-active-pool-filter")
    assert has_element?(view, "#api-key-pool-group-filtered-primary", "Filtered Primary")
    assert has_element?(view, "#api-key-pool-group-filtered-backup", "Filtered Backup")
    assert has_element?(view, "#api-key-row-#{primary_key.id}", "Filtered primary key")
    assert has_element?(view, "#api-key-row-#{backup_key.id}", "Filtered backup key")
    refute has_element?(view, "#api-key-row-#{disabled_key.id}")

    {:ok, disabled_filter_view, _html} =
      live(conn, ~p"/admin/api-keys?pool_id=#{disabled_pool.id}")

    refute has_element?(disabled_filter_view, "#api-key-active-pool-filter")
    assert has_element?(disabled_filter_view, "#api-key-row-#{primary_key.id}")
    assert has_element?(disabled_filter_view, "#api-key-row-#{backup_key.id}")
    refute has_element?(disabled_filter_view, "#api-key-row-#{disabled_key.id}")

    html = render(disabled_filter_view)
    refute html =~ primary_raw_key
    refute html =~ backup_raw_key
    refute html =~ disabled_raw_key
  end

  test "renders explicit API key lifecycle metadata in grouped rows", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "row-lifecycle", name: "Row Lifecycle"})

    {:ok, %{api_key: used_key, raw_key: used_raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Used lifecycle key"})

    {:ok, %{api_key: unused_key, raw_key: unused_raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Unused lifecycle key"})

    {:ok, %{api_key: expired_key, raw_key: expired_raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Expired lifecycle key"})

    last_used_at = ~U[2026-07-01 10:30:00.000000Z]
    future_expiry = ~U[2099-08-02 12:45:00.000000Z]
    past_expiry = ~U[2020-01-02 03:04:00.000000Z]

    Repo.update_all(from(key in APIKey, where: key.id == ^used_key.id),
      set: [last_used_at: last_used_at, expires_at: future_expiry]
    )

    Repo.update_all(from(key in APIKey, where: key.id == ^expired_key.id),
      set: [expires_at: past_expiry]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-row-#{used_key.id}-last-used", "2026")
    assert has_element?(view, "#api-key-row-#{used_key.id}-expires", "2099")
    assert has_element?(view, "#api-key-row-#{unused_key.id}-last-used", "Never used")
    assert has_element?(view, "#api-key-row-#{unused_key.id}-expires", "No expiry")
    assert has_element?(view, "#api-key-row-#{expired_key.id}-expires", "Expired")
    assert has_element?(view, "#api-key-row-#{expired_key.id}-expires", "2020")
    refute has_element?(view, "[id$='-usage']")

    html = render(view)
    refute html =~ used_raw_key
    refute html =~ unused_raw_key
    refute html =~ expired_raw_key
    refute html =~ "Recorded usage"
  end

  test "mount and policy flows never read ledger entries", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "query-proof", name: "Query Proof Pool"})

    {:ok, %{api_key: api_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Query proof key",
        default_policy: %{max_tokens_per_week: 1_000}
      })

    {{:ok, view, _html}, mount_queries} =
      capture_repo_queries(fn -> live(conn, ~p"/admin/api-keys") end)

    assert_no_ledger_reads(mount_queries)

    {_html, edit_queries} =
      capture_repo_queries(view.pid, fn ->
        view |> element("#edit-api-key-#{api_key.id}") |> render_click()
      end)

    assert_no_ledger_reads(edit_queries)

    {_html, review_queries} =
      capture_repo_queries(view.pid, fn ->
        view |> element("#api-key-tab-review") |> render_click()
      end)

    assert_no_ledger_reads(review_queries)
    assert has_element?(view, "#api-key-review-summary", "Query Proof Pool")
    refute view |> element("#api-key-review-summary") |> render() =~ pool.id
    assert has_element?(view, "#api-key-review-summary", "1,000")
    refute has_element?(view, "#api-key-usage-summary")

    {_html, save_queries} =
      capture_repo_queries(view.pid, fn ->
        view |> element("#api-key-form") |> render_submit()
      end)

    assert_no_ledger_reads(save_queries)

    view |> element("#edit-api-key-#{api_key.id}") |> render_click()

    {_html, cancel_queries} =
      capture_repo_queries(view.pid, fn ->
        view |> element("#api-key-cancel-edit") |> render_click()
      end)

    assert_no_ledger_reads(cancel_queries)
  end

  test "reloads API keys only for visible Pool lifecycle events while preserving wizard state", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "event-scope", name: "Event Scope Pool"})

    {:ok, invisible_pool} =
      Pools.create_pool(scope, %{slug: "event-hidden", name: "Event Hidden Pool"})

    assert {:ok, _invisible_pool} = Pools.change_pool_status(scope, invisible_pool, "disabled")

    {:ok, %{api_key: api_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Event scope key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    view
    |> element("#edit-api-key-#{api_key.id}")
    |> render_click()

    draft_name = "Updated event scope key"

    view
    |> element("#api-key-form")
    |> render_change(%{"api_key" => %{"display_name" => draft_name}})

    view
    |> element("#api-key-tab-review")
    |> render_click()

    assert has_element?(view, "#api-key-tab-review[aria-selected='true']")
    assert has_element?(view, "#api_key_display_name[value='#{draft_name}']")

    {_result, traffic_queries} =
      capture_repo_queries(view.pid, fn ->
        broadcast_traffic_events(pool.id, 100)
        _ = :sys.get_state(view.pid)
      end)

    assert traffic_queries == []
    assert_no_ledger_reads(traffic_queries)
    assert has_element?(view, "#api-key-tab-review[aria-selected='true']")
    assert has_element?(view, "#api_key_display_name[value='#{draft_name}']")

    {_result, invisible_queries} =
      capture_repo_queries(view.pid, fn ->
        assert {:ok, _event} = Events.broadcast_pools(invisible_pool.id, "pool_changed")
        _ = :sys.get_state(view.pid)
      end)

    assert invisible_queries == []

    for malformed_topics <- [[%{}], ["pools", %{}], ["pools", 123], ["pools", "unknown"]] do
      {_result, malformed_queries} =
        capture_repo_queries(view.pid, fn ->
          send(view.pid, {Events, %{pool_id: pool.id, topics: malformed_topics}})
          _ = :sys.get_state(view.pid)
        end)

      assert malformed_queries == []
      assert Process.alive?(view.pid)
      assert has_element?(view, "#api-key-tab-review[aria-selected='true']")
      assert has_element?(view, "#api_key_display_name[value='#{draft_name}']")
    end

    {_result, visible_queries} =
      capture_repo_queries(view.pid, fn ->
        assert {:ok, _event} = Events.broadcast_pools(pool.id, "pool_changed")
        _ = :sys.get_state(view.pid)
      end)

    assert length(visible_queries) == 12
    assert_no_ledger_reads(visible_queries)
    assert has_element?(view, "#api-key-tab-review[aria-selected='true']")
    assert has_element?(view, "#api_key_display_name[value='#{draft_name}']")

    view
    |> element("#api-key-form")
    |> render_submit()

    assert {:ok, %{api_key: %{display_name: ^draft_name}}} =
             Access.get_api_key_with_policy(scope, api_key.id)

    view
    |> element("#edit-api-key-#{api_key.id}")
    |> render_click()

    view
    |> element("#api-key-cancel-edit")
    |> render_click()

    refute has_element?(view, "#api-key-form")
    assert has_element?(view, "#api-key-row-#{api_key.id}", draft_name)
  end

  defp open_create_dialog(view) do
    view |> element("#api-key-page-create-action") |> render_click()
  end

  defp select_api_key_section(view, section) do
    view |> element("#api-key-tab-#{section}") |> render_click()
  end

  defp assert_api_key_section(view, section) do
    assert has_element?(view, "#api-key-tab-#{section}[aria-selected='true']")
    assert has_element?(view, "#api-key-section-#{section}[role='tabpanel']")
  end

  defp assert_no_cost_limit_controls(view) do
    assert_no_cost_control(view, :default, ["max_", "cost_", "microunits"])
    assert_no_cost_control(view, :default, ["max_", "cost_", "usd"])
    assert_no_cost_control(view, :default, ["max_", "cost_", "per_", "day"])
    assert_no_cost_control(view, :default, ["max_", "cost_", "per_", "week"])
    assert_no_cost_control(view, :model, ["max_", "cost_", "microunits"])
    assert_no_cost_control(view, :model, ["max_", "cost_", "usd"])
    assert_no_cost_control(view, :model, ["max_", "cost_", "per_", "day"])
    assert_no_cost_control(view, :model, ["max_", "cost_", "per_", "week"])
    refute render(view) =~ Enum.join(["Cost ", "microunits"])
    refute render(view) =~ Enum.join(["trusted_", "pricing_", "unavailable"])
  end

  defp assert_no_cost_control(view, scope, suffix_parts) do
    refute has_element?(view, api_key_cost_control_id(scope, suffix_parts))
  end

  defp api_key_cost_control_id(scope, suffix_parts) do
    Enum.join(["#api_key_", to_string(scope), "_"], "") <> Enum.join(suffix_parts, "")
  end

  defp broadcast_traffic_events(pool_id, count) do
    task =
      Task.async(fn ->
        receive do
          :broadcast_traffic_events ->
            Enum.each(1..count, fn index ->
              broadcast_traffic_event(pool_id, index)
            end)
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :broadcast_traffic_events)
    assert :ok = Task.await(task, 5_000)
  end

  defp broadcast_traffic_event(pool_id, index) when rem(index, 2) == 0 do
    assert {:ok, _event} = Events.broadcast_usage(pool_id, "traffic_updated", %{})
  end

  defp broadcast_traffic_event(pool_id, _index) do
    assert {:ok, _event} = Events.broadcast_request_logs(pool_id, "traffic_updated", %{})
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    capture_repo_queries(fun, fn _pid -> true end, page_reads_only?: false)
  end

  defp capture_repo_queries(query_pid, fun) when is_pid(query_pid) and is_function(fun, 0) do
    capture_repo_queries(fun, &(&1 == query_pid), page_reads_only?: true)
  end

  defp capture_repo_queries(fun, query_pid?, opts)
       when is_function(fun, 0) and is_function(query_pid?, 1) do
    page_reads_only? = Keyword.fetch!(opts, :page_reads_only?)
    test_pid = self()
    handler_id = {__MODULE__, :repo_query, test_pid, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and query_pid?.(self()) do
            send(test_pid, {handler_id, metadata[:source], page_reads_only?})
          end
        end,
        nil
      )

    try do
      result = fun.()
      _ = if match?(%Phoenix.LiveViewTest.View{}, result), do: :sys.get_state(result.pid)
      {result, drain_repo_query_sources(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_sources(handler_id, sources) do
    receive do
      {^handler_id, source, true} when source in [nil, ""] ->
        drain_repo_query_sources(handler_id, sources)

      {^handler_id, source, _page_reads_only?} ->
        drain_repo_query_sources(handler_id, [to_string(source) | sources])
    after
      0 -> Enum.reverse(sources)
    end
  end

  defp assert_no_ledger_reads(sources) do
    refute Enum.any?(sources, &String.contains?(&1, "ledger_entries"))
  end
end
