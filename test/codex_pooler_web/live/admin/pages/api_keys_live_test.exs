defmodule CodexPoolerWeb.Admin.ApiKeysLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Accounts
  alias CodexPooler.Pools

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

  test "renders required form, grouped tables, row, and action selectors", %{
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
      assert has_element?(view, "#api-key-pool-group-#{group_id} thead th", "Key")
      assert has_element?(view, "#api-key-pool-group-#{group_id} thead th", "Status")
      assert has_element?(view, "#api-key-pool-group-#{group_id} thead th", "Usage")
      assert has_element?(view, "#api-key-pool-group-#{group_id} thead th", "Policy")
      assert has_element?(view, "#api-key-pool-group-#{group_id} thead th", "Actions")

      group_header_html = view |> element("#api-key-pool-group-#{group_id} thead") |> render()
      refute group_header_html =~ ">Pool<"
      refute group_header_html =~ "Notes"
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
             "#api-key-footer [data-role='policy-editor-docs-link'][href='https://docs.codex-pooler.com'][target='_blank'][rel='noopener noreferrer'].text-xs",
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
    assert has_element?(view, "#api_key_enforced_reasoning_effort")
    assert has_element?(view, "#api_key_enforced_reasoning_effort option", "Minimal")
    assert has_element?(view, "#api_key_enforced_reasoning_effort option", "Extra high")
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
    assert has_element?(view, "#api-key-usage-summary")
    assert_no_cost_limit_controls(view)

    assert has_element?(view, "#api-key-row-#{primary_key.id}", "Primary selector key")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-status", "active")
    assert has_element?(view, "#api-key-row-#{primary_key.id}-usage", "No usage recorded")
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

  test "renders API key usage summaries in grouped rows", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "row-usage", name: "Row Usage"})

    {:ok, %{api_key: used_key, raw_key: used_raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Used row key"})

    {:ok, %{api_key: unused_key, raw_key: unused_raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Unused row key"})

    first_request =
      request_fixture(%{pool: pool, api_key: used_key}, %{
        correlation_id: "api-key-row-usage-1",
        request_metadata: %{"prompt" => "do not render row prompt"}
      })

    second_request =
      request_fixture(%{pool: pool, api_key: used_key}, %{
        correlation_id: "api-key-row-usage-2"
      })

    ledger_entry_fixture(first_request, %{
      input_tokens: 30_000,
      cached_input_tokens: 10_000,
      output_tokens: 15_000,
      total_tokens: 45_000,
      request_count: 1
    })

    ledger_entry_fixture(second_request, %{
      input_tokens: 3_000,
      cached_input_tokens: 500,
      output_tokens: 2_000,
      total_tokens: 5_000,
      request_count: 1
    })

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-row-#{used_key.id}-usage", "2 requests")
    assert has_element?(view, "#api-key-row-#{used_key.id}-usage", "50k tokens")
    assert has_element?(view, "#api-key-row-#{used_key.id}-usage", "10.5k cached input")
    assert has_element?(view, "#api-key-row-#{unused_key.id}-usage", "No usage recorded")

    html = render(view)
    refute html =~ used_raw_key
    refute html =~ unused_raw_key
    refute html =~ "do not render row prompt"
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
end
