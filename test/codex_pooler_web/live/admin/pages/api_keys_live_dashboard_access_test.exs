defmodule CodexPoolerWeb.Admin.ApiKeysLiveDashboardAccessTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Accounts
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "dashboard access defaults off in Basics, Review, persistence, and the key card", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "Default dashboard policy")
    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    open_create_dialog(view)

    assert has_element?(view, "#api_key_dashboard_access")
    refute has_element?(view, "#api_key_dashboard_access[checked]")

    select_api_key_section(view, "review")
    assert has_element?(view, "#api-key-review-summary", "Dashboard access")
    assert has_element?(view, "#api-key-review-summary", "Disabled")

    view
    |> element("#api-key-form")
    |> render_submit(%{
      "api_key" => %{
        "display_name" => "Default dashboard key",
        "pool_id" => pool.id
      }
    })

    api_key = Repo.one!(APIKey)

    refute api_key.dashboard_access

    assert has_element?(
             view,
             "#api-key-row-#{api_key.id}-dashboard-access",
             "Dashboard disabled"
           )
  end

  test "keeps mobile API key actions in the original right-hand column without overlap", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "Mobile API key action placement")

    {:ok, %{api_key: api_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Mobile layout key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    row_selector = "#api-key-row-#{api_key.id}"

    assert has_element?(
             view,
             "#{row_selector}[class~='grid-cols-[minmax(0,1fr)_auto]']"
           )

    refute has_element?(view, "#{row_selector}[class~='grid-cols-1']")

    assert has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'][class~='relative'][class~='z-10'][class~='flex'][class~='items-center'][class~='gap-2'][class~='justify-self-end']"
           )

    refute has_element?(view, "#{row_selector} > [data-role='api-key-actions'][class~='w-full']")

    refute has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'][class~='flex-wrap']"
           )

    refute has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'][class~='justify-start']"
           )

    assert has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'] > [data-role='api-key-actions-menu'][class~='dropdown'][class~='dropdown-end'][class~='relative'][class~='inline-block'][class~='focus-within:z-50']"
           )

    assert has_element?(view, "#{row_selector}-dashboard-access", "Dashboard disabled")
    assert has_element?(view, "#{row_selector}-status", "active")

    assert has_element?(
             view,
             "#{row_selector} [data-role='api-key-action-menu'][class~='menu'][class~='dropdown-content'][class~='w-56']"
           )

    refute has_element?(
             view,
             "#{row_selector} [data-role='api-key-action-menu'][class~='static']"
           )
  end

  test "keeps desktop API key rows anchored with the original action overlay", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "Desktop API key action placement")

    {:ok, %{api_key: api_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Desktop layout key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    row_selector = "#api-key-row-#{api_key.id}"

    assert has_element?(
             view,
             "#{row_selector}[class~='xl:grid-cols-[minmax(12rem,0.9fr)_minmax(12rem,0.85fr)_minmax(14rem,1fr)_auto]']"
           )

    refute has_element?(
             view,
             "#{row_selector}[class~='xl:grid-cols-[minmax(0,0.9fr)_minmax(0,0.85fr)_minmax(0,1fr)_auto]']"
           )

    assert has_element?(view, "#{row_selector}-dashboard-access", "Dashboard disabled")
    assert has_element?(view, "#{row_selector}-status", "active")

    assert has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'][class~='relative'][class~='z-10'][class~='flex'][class~='items-center'][class~='gap-2'][class~='justify-self-end']"
           )

    refute has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'][class~='xl:w-auto']"
           )

    refute has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'][class~='xl:flex-nowrap']"
           )

    refute has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'][class~='xl:justify-self-end']"
           )

    assert has_element?(
             view,
             "#{row_selector} > [data-role='api-key-actions'] > [data-role='api-key-actions-menu'][class~='dropdown'][class~='dropdown-end'][class~='relative'][class~='inline-block'][class~='focus-within:z-50']"
           )

    assert has_element?(view, "#{row_selector}-dashboard-access", "Dashboard disabled")
    assert has_element?(view, "#{row_selector}-status", "active")

    assert has_element?(
             view,
             "#{row_selector} [data-role='api-key-action-menu'][class~='dropdown-content'][class~='w-56']"
           )

    refute has_element?(
             view,
             "#{row_selector} [data-role='api-key-action-menu'][class~='static']"
           )
  end

  test "create enabled then edit disabled revokes sessions and audits only old/new booleans", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "Dashboard lifecycle policy")
    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    open_create_dialog(view)

    view
    |> element("#api-key-form")
    |> render_change(%{"api_key" => %{"dashboard_access" => "true"}})

    assert has_element?(view, "#api_key_dashboard_access[checked]")

    select_api_key_section(view, "review")
    assert has_element?(view, "#api-key-review-summary", "Enabled")

    created_html =
      view
      |> element("#api-key-form")
      |> render_submit(%{
        "api_key" => %{
          "display_name" => "Dashboard lifecycle key",
          "pool_id" => pool.id
        }
      })

    api_key = Repo.one!(APIKey)
    raw_key = extract_raw_key!(created_html)

    assert api_key.dashboard_access

    assert has_element?(
             view,
             "#api-key-row-#{api_key.id}-dashboard-access",
             "Dashboard enabled"
           )

    create_audit =
      Repo.get_by!(AuditEvent, action: "api_key.create", target_id: api_key.id)

    assert create_audit.details["dashboard_access"] == true
    assert dashboard_detail_keys(create_audit) == ["dashboard_access"]
    refute inspect(create_audit.details) =~ raw_key

    assert {:ok, %{token: dashboard_token}} = Access.issue_dashboard_session(raw_key)
    assert {:ok, _principal} = Access.authenticate_dashboard_session(dashboard_token)

    view |> element("#api-key-secret-dialog-close") |> render_click()
    view |> element("#edit-api-key-#{api_key.id}") |> render_click()

    assert has_element?(view, "#api_key_dashboard_access[checked]")

    view
    |> element("#api-key-form")
    |> render_change(%{"api_key" => %{"dashboard_access" => "false"}})

    select_api_key_section(view, "review")
    assert has_element?(view, "#api-key-review-summary", "Disabled")

    view
    |> element("#api-key-form")
    |> render_submit(%{"api_key" => %{"dashboard_access" => "false"}})

    refute Repo.get!(APIKey, api_key.id).dashboard_access

    assert has_element?(
             view,
             "#api-key-row-#{api_key.id}-dashboard-access",
             "Dashboard disabled"
           )

    assert Repo.aggregate(
             from(session in APIKeyDashboardSession,
               where: session.api_key_id == ^api_key.id
             ),
             :count,
             :id
           ) == 0

    assert {:error, :invalid_dashboard_session} =
             Access.authenticate_dashboard_session(dashboard_token)

    update_audit =
      Repo.get_by!(AuditEvent, action: "api_key.update", target_id: api_key.id)

    assert update_audit.details["previous_dashboard_access"] == true
    assert update_audit.details["dashboard_access"] == false

    assert dashboard_detail_keys(update_audit) == [
             "dashboard_access",
             "previous_dashboard_access"
           ]

    refute inspect(update_audit.details) =~ raw_key
    refute inspect(update_audit.details) =~ dashboard_token
  end

  test "malformed dashboard access is rejected without persistence", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "Malformed dashboard policy")
    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    open_create_dialog(view)

    view
    |> element("#api-key-form")
    |> render_submit(%{
      "api_key" => %{
        "display_name" => "Malformed dashboard key",
        "pool_id" => pool.id,
        "dashboard_access" => "enabled-ish"
      }
    })

    assert has_element?(view, "#api-key[open]")

    assert has_element?(
             view,
             "#api-key-review-errors",
             "Dashboard access must be enabled or disabled"
           )

    assert Repo.aggregate(APIKey, :count) == 0
  end

  test "assigned admin can update an assigned key but a forged hidden key id is denied", %{
    scope: scope
  } do
    assigned_pool = create_pool!(scope, "Assigned dashboard policy")
    hidden_pool = create_pool!(scope, "Hidden dashboard policy")

    {:ok, %{api_key: assigned_key}} =
      Access.create_api_key(scope, assigned_pool, %{display_name: "Assigned dashboard key"})

    {:ok, %{api_key: hidden_key}} =
      Access.create_api_key(scope, hidden_pool, %{display_name: "Hidden dashboard key"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-row-#{assigned_key.id}")
    refute has_element?(view, "#api-key-row-#{hidden_key.id}")

    view |> element("#edit-api-key-#{assigned_key.id}") |> render_click()

    view
    |> element("#api-key-form")
    |> render_submit(%{"api_key" => %{"dashboard_access" => "true"}})

    assert Repo.get!(APIKey, assigned_key.id).dashboard_access

    render_submit(view, "save_api_key", %{
      "api_key" => %{
        "id" => hidden_key.id,
        "display_name" => hidden_key.display_name,
        "pool_id" => hidden_pool.id,
        "dashboard_access" => "true"
      }
    })

    refute Repo.get!(APIKey, hidden_key.id).dashboard_access
    refute has_element?(view, "#api-key-row-#{hidden_key.id}")
  end

  defp create_pool!(scope, name) do
    suffix = System.unique_integer([:positive])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "dashboard-policy-#{suffix}",
               name: name
             })

    pool
  end

  defp open_create_dialog(view) do
    view |> element("#api-key-page-create-action") |> render_click()
  end

  defp select_api_key_section(view, section) do
    view |> element("#api-key-tab-#{section}") |> render_click()
  end

  defp extract_raw_key!(html) do
    case Regex.run(~r/sk-cxp-[A-Za-z0-9_-]+-[A-Za-z0-9_-]+/, html) do
      [raw_key] -> raw_key
      _match -> flunk("raw API key was not rendered in the one-time secret panel")
    end
  end

  defp dashboard_detail_keys(%AuditEvent{details: details}) do
    details
    |> Map.keys()
    |> Enum.filter(&String.contains?(&1, "dashboard"))
    |> Enum.sort()
  end
end
