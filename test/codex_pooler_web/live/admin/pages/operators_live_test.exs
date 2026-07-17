defmodule CodexPoolerWeb.Admin.OperatorsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures, only: [pool_fixture: 1]

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.User
  alias CodexPooler.Pools
  alias CodexPooler.Pools.OperatorPoolAssignment
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AvatarComponents

  setup :register_and_log_in_user

  @tag :create_generated_operator
  test "creates a generated-password operator and renders required selectors", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    assert has_element?(view, "#admin-operators-live")
    assert has_element?(view, "#operators-page-header")
    assert has_element?(view, "#operator-page-create-action")
    refute has_element?(view, "#operator-create-form")

    open_create_dialog(view)

    assert has_element?(view, "#operator-create-dialog[open]")
    assert has_element?(view, "#operator-create-form")
    assert has_element?(view, "#operator_email")
    assert has_element?(view, "#operator_display_name")
    assert has_element?(view, "#operator_password_mode")
    assert has_element?(view, "#operator_password")
    assert has_element?(view, "#operator_password_change_required")
    assert has_element?(view, "#operator_send_email")
    assert has_element?(view, "#operator_role")
    assert has_element?(view, "#operator_pool_ids_group")
    assert has_element?(view, "#operator-create-cancel + #operator-create-submit")
    assert_admin_dialog_docs_link(view, "operator-create-dialog-footer")
    assert has_element?(view, "#operators-table-scroll-region")
    assert has_element?(view, "#operators-table[phx-update='stream']")
    assert has_element?(view, "#operators-table-scroll-region thead th", "TOTP")
    assert has_element?(view, "#operators-table-scroll-region thead th", "Last login")
    refute has_element?(view, "#operators-table-scroll-region thead th", "Activity")
    assert has_element?(view, "#operator-empty-row td[colspan='6']")
    assert has_element?(view, "#operator-actions-menu-#{user.id}")
    assert has_element?(view, "#operator-row-#{user.id}-totp", "TOTP not set up")
    assert has_element?(view, "#operator-row-#{user.id}-totp [aria-label='TOTP not set up']")

    assert has_element?(
             view,
             "#operator-row-#{user.id}-password-policy",
             "No password change required"
           )

    refute has_element?(view, "#operator-row-#{user.id}-password-policy", "current")
    assert has_element?(view, "#operator-row-#{user.id}-last-login-at")
    refute has_element?(view, "#operator-row-#{user.id}-last-login-label")

    assert has_element?(
             view,
             "#operator-row-#{user.id}-avatar img[src='#{AvatarComponents.gravatar_url(user.email, size: 80)}']"
           )

    assert has_element?(view, "#reset-operator-password-#{user.id}[disabled]")
    refute has_element?(view, "#resend-operator-email-#{user.id}")

    html =
      view
      |> element("#operator-create-form")
      |> render_submit(%{
        "operator" => %{
          "email" => "generated.operator@example.com",
          "display_name" => "Generated Operator",
          "password_mode" => "generated",
          "password" => "",
          "password_change_required" => "true",
          "send_email" => "true"
        }
      })

    temporary_password = extract_temporary_password!(html)
    operator = Accounts.get_user_by_email("generated.operator@example.com")

    assert %User{} = operator
    assert operator.password_change_required
    refute operator.password_hash == temporary_password

    assert Accounts.get_user_by_email_and_password(operator.email, temporary_password).id ==
             operator.id

    assert has_element?(
             view,
             "#operator-create-temporary-password-receipt",
             "Copy this temporary password now"
           )

    assert has_element?(view, "#operator-create-dialog[open]")
    assert has_element?(view, "#operator-create-temporary-password-value", temporary_password)
    assert has_element?(view, "#operator-create-copy-temporary-password")
    assert_admin_dialog_docs_link(view, "operator-create-temporary-password-receipt-footer")
    assert has_element?(view, "#operator-row-#{operator.id}", "Generated Operator")
    assert has_element?(view, "#operator-row-#{operator.id}-last-login-at", "not yet")
    assert_email_sent(to: {"", operator.email}, subject: "Codex Pooler operator access")
  end

  test "renders active TOTP shield state for enrolled operators", %{conn: conn, user: user} do
    {:ok, %{setting: setting}} = Accounts.enable_totp_for_user(user)

    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    assert setting.status == "active"
    assert has_element?(view, "#operator-row-#{user.id}-totp", "TOTP enabled")
    assert has_element?(view, "#operator-row-#{user.id}-totp [aria-label='TOTP enabled']")
  end

  test "filters operators with the pool-style search and status controls", %{
    conn: conn,
    scope: scope
  } do
    %{user: active_operator} =
      operator_fixture(scope, %{
        "email" => "alpha.filter@example.com",
        "display_name" => "Alpha Filter"
      })

    %{user: disabled_operator} =
      operator_fixture(scope, %{
        "email" => "beta.filter@example.com",
        "display_name" => "Beta Filter"
      })

    assert {:ok, _disabled} = Accounts.deactivate_operator(scope, disabled_operator, %{})

    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    assert has_element?(view, "#operator-filter-form")
    assert has_element?(view, "#operator_filters_query[placeholder='Search operators...']")
    assert has_element?(view, "#operator-filter-query-clear")
    assert has_element?(view, "#operator-status-filter [data-role='status-filter-trigger']")
    assert has_element?(view, "#operator-status-filter [data-status='disabled']", "Disabled")
    refute has_element?(view, "#operator-status-filter [data-status='locked']")

    view
    |> element("#operator-filter-form")
    |> render_change(%{
      "operator_filters" => %{"query" => "alpha", "status" => "all"}
    })

    assert has_element?(view, "#operator-row-#{active_operator.id}", "Alpha Filter")
    refute has_element?(view, "#operator-row-#{disabled_operator.id}", "Beta Filter")

    view |> element("#operator-filter-query-clear") |> render_click()
    assert has_element?(view, "#operator-row-#{disabled_operator.id}", "Beta Filter")

    view |> element("#operator-status-filter [data-status='disabled']") |> render_click()

    assert has_element?(view, "#operator-row-#{disabled_operator.id}", "disabled")
    refute has_element?(view, "#operator-row-#{active_operator.id}", "Alpha Filter")
  end

  test "defers pool option reloads while an operator dialog is open", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    open_create_dialog(view)
    assert has_element?(view, "#operator_pool_ids_group")

    {:ok, late_pool} =
      Pools.create_pool(scope, %{slug: "late-operator-pool", name: "Late Operator Pool"})

    assert {:ok, _result} =
             Accounts.create_operator(
               scope,
               %{
                 "email" => "concurrent.operator@example.com",
                 "display_name" => "Concurrent Operator",
                 "password" => "ConcurrentPass123!",
                 "send_email" => "false"
               },
               %{}
             )

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#operator-create-dialog[open]")
    refute has_element?(view, "#operator_pool_id_#{late_pool.id}_option")

    view |> element("#operator-create-cancel") |> render_click()
    refute has_element?(view, "#operator-create-dialog[open]")

    open_create_dialog(view)
    assert has_element?(view, "#operator_pool_id_#{late_pool.id}_option")
  end

  test "live-updates when operators change elsewhere", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    refute render(view) =~ "Live Updated Operator"

    assert {:ok, %{user: operator}} =
             Accounts.create_operator(
               scope,
               %{
                 "email" => "live.updated.operator@example.com",
                 "display_name" => "Live Updated Operator",
                 "password" => "LiveUpdatedPass123!",
                 "send_email" => "false"
               },
               %{}
             )

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#operator-row-#{operator.id}", "Live Updated Operator")
  end

  test "creates an instance admin with selected Pool assignments", %{conn: conn} do
    pool = pool_fixture(%{slug: "live-operator-pool", name: "Live Operator Pool"})
    {:ok, view, _html} = live(conn, ~p"/admin/operators")
    open_create_dialog(view)

    assert has_element?(view, "#operator_pool_id_#{pool.id}_option", "Live Operator Pool")

    view
    |> element("#operator-create-form")
    |> render_submit(%{
      "operator" => %{
        "email" => "assigned.live.operator@example.com",
        "display_name" => "Assigned Live Operator",
        "password_mode" => "manual",
        "password" => "ManualTempPass123!",
        "password_change_required" => "true",
        "send_email" => "false",
        "role" => "instance_admin",
        "pool_ids" => [pool.id]
      }
    })

    operator = Accounts.get_user_by_email("assigned.live.operator@example.com")

    assert %User{} = operator

    assert Repo.get_by(OperatorPoolAssignment,
             user_id: operator.id,
             pool_id: pool.id,
             status: "active"
           )

    assert Accounts.operator_lifecycle(operator) == %{
             role: "instance_admin",
             assigned_pool_ids: [pool.id]
           }

    assert has_element?(view, "#operator-row-#{operator.id}", "Assigned Live Operator")
  end

  test "creates a manual-password operator and sends the text credential email", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/operators")
    open_create_dialog(view)

    view
    |> element("#operator-create-form")
    |> render_submit(%{
      "operator" => %{
        "email" => "manual.operator@example.com",
        "display_name" => "Manual Operator",
        "password_mode" => "manual",
        "password" => "ManualTempPass123!",
        "password_change_required" => "true",
        "send_email" => "true"
      }
    })

    operator = Accounts.get_user_by_email("manual.operator@example.com")

    assert %User{} = operator
    assert operator.password_change_required

    assert Accounts.get_user_by_email_and_password(operator.email, "ManualTempPass123!").id ==
             operator.id

    assert has_element?(view, "#operator-create-dialog[open]")
    assert has_element?(view, "#operator-create-temporary-password-value", "ManualTempPass123!")

    assert_email_sent(fn email ->
      assert email.to == [{"", operator.email}]
      assert email.subject == "Codex Pooler operator access"
      assert email.text_body =~ "Temporary password: ManualTempPass123!"
      assert length(String.split(email.text_body, "ManualTempPass123!")) == 2
      refute email.html_body
      true
    end)
  end

  test "creates an operator with current password when password change is unchecked", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/operators")
    open_create_dialog(view)

    view
    |> element("#operator-create-form")
    |> render_submit(%{
      "operator" => %{
        "email" => "current-password.operator@example.com",
        "display_name" => "Current Password Operator",
        "password_mode" => "manual",
        "password" => "ManualTempPass123!",
        "password_change_required" => "false",
        "send_email" => "false"
      }
    })

    operator = Accounts.get_user_by_email("current-password.operator@example.com")

    assert %User{} = operator
    refute operator.password_change_required

    assert has_element?(
             view,
             "#operator-row-#{operator.id}-password-policy",
             "No password change required"
           )

    refute has_element?(view, "#operator-row-#{operator.id}-password-policy", "current")
  end

  test "denies operator management UI for non-owner operators", %{scope: scope, user: owner} do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "admin-only@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, html} = live(admin_conn, ~p"/admin/operators")

    assert html =~ "Only instance owners can manage operators."
    refute has_element?(view, "#operator-page-create-action")
    refute has_element?(view, "#operators-table")
    refute has_element?(view, "#operator-row-#{owner.id}")
  end

  test "forged instance-admin operator events deny without operator side effects", %{
    scope: scope,
    user: owner
  } do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "forged-admin@example.com",
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    %{user: target_operator} =
      operator_fixture(scope, %{
        "email" => "forged-target@example.com",
        "display_name" => "Forged Target",
        "role" => "instance_admin"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/operators")

    assert render_click(view, "open_create_operator") =~
             "Only instance owners can manage operators."

    assert render_click(view, "edit_operator", %{"id" => target_operator.id}) =~
             "Operator was not found"

    assert render_click(view, "deactivate_operator", %{"id" => target_operator.id}) =~
             "Only instance owners can manage operators."

    assert render_click(view, "reset_operator_password", %{"id" => target_operator.id}) =~
             "Operator was not found"

    assert render_submit(view, "create_operator", %{
             "operator" => %{
               "email" => "forged-created@example.com",
               "display_name" => "Forged Created",
               "password_mode" => "manual",
               "password" => "ForgedPassword123!",
               "password_change_required" => "false",
               "send_email" => "false",
               "role" => "instance_owner",
               "pool_ids" => []
             }
           }) =~ "Only instance owners can manage operators."

    assert render_submit(view, "save_operator", %{
             "operator_edit" => %{
               "id" => target_operator.id,
               "email" => target_operator.email,
               "display_name" => "Forged Escalated",
               "password_change_required" => "false",
               "role" => "instance_owner",
               "pool_ids" => []
             }
           }) =~ "Only instance owners can manage operators."

    assert render_submit(view, "save_temporary_password", %{
             "operator_reset" => %{
               "id" => target_operator.id,
               "operation" => "reset",
               "password_mode" => "manual",
               "password" => "ForgedReset123!",
               "password_change_required" => "false"
             }
           }) =~ "Only instance owners can manage operators."

    refute Accounts.get_user_by_email("forged-created@example.com")

    assert Accounts.operator_lifecycle(admin) == %{
             role: "instance_admin",
             assigned_pool_ids: []
           }

    assert Accounts.operator_lifecycle(target_operator) == %{
             role: "instance_admin",
             assigned_pool_ids: []
           }

    target_operator = Accounts.get_user!(target_operator.id)
    assert target_operator.status == "active"
    assert target_operator.display_name == "Forged Target"
    assert owner.status == "active"
  end

  test "edits operator role and selected Pool assignments", %{conn: conn, scope: scope} do
    original_pool = pool_fixture(%{slug: "live-edit-original", name: "Live Edit Original"})
    new_pool = pool_fixture(%{slug: "live-edit-new", name: "Live Edit New"})

    %{user: operator} =
      operator_fixture(scope, %{
        "email" => "role-edit.operator@example.com",
        "role" => "instance_admin",
        "pool_ids" => [original_pool.id]
      })

    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    view |> element("#edit-operator-#{operator.id}") |> render_click()

    assert has_element?(view, "#operator_edit_pool_id_#{original_pool.id}[checked]")
    assert has_element?(view, "#operator_edit_pool_id_#{new_pool.id}")

    view
    |> element("#operator-edit-form")
    |> render_submit(%{
      "operator_edit" => %{
        "id" => operator.id,
        "email" => "role-edit.operator@example.com",
        "display_name" => "Role Edited Operator",
        "password_change_required" => "true",
        "role" => "instance_owner",
        "pool_ids" => [new_pool.id]
      }
    })

    assert Accounts.operator_lifecycle(operator) == %{
             role: "instance_owner",
             assigned_pool_ids: []
           }

    refute Repo.get_by(OperatorPoolAssignment,
             user_id: operator.id,
             pool_id: original_pool.id,
             status: "active"
           )

    refute Repo.get_by(OperatorPoolAssignment,
             user_id: operator.id,
             pool_id: new_pool.id,
             status: "active"
           )

    assert has_element?(view, "#operator-row-#{operator.id}", "Role Edited Operator")
  end

  test "edits operator email, display name, and password-change requirement", %{
    conn: conn,
    scope: scope
  } do
    %{user: operator} = operator_fixture(scope, %{"email" => "edit.operator@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    view |> element("#edit-operator-#{operator.id}") |> render_click()

    assert has_element?(view, "#operator-edit-dialog[open]")
    assert has_element?(view, "#operator-edit-form")
    assert has_element?(view, "#operator_edit_email")
    assert has_element?(view, "#operator_edit_display_name")
    assert has_element?(view, "#operator_edit_password_change_required")
    assert has_element?(view, "#operator_edit_role")
    assert has_element?(view, "#operator_edit_pool_ids_group")
    assert has_element?(view, "#operator-edit-cancel + #operator-edit-submit")
    assert_admin_dialog_docs_link(view, "operator-edit-dialog-footer")

    view
    |> element("#operator-edit-form")
    |> render_submit(%{
      "operator_edit" => %{
        "email" => "edited.operator@example.com",
        "display_name" => "Edited Operator",
        "password_change_required" => "false",
        "password" => "IgnoredPass123!"
      }
    })

    edited = Repo.get!(User, operator.id)
    assert edited.email == "edited.operator@example.com"
    assert edited.display_name == "Edited Operator"
    refute edited.password_change_required
    assert has_element?(view, "#operator-row-#{operator.id}", "Edited Operator")

    assert has_element?(
             view,
             "#operator-row-#{operator.id}-password-policy",
             "No password change required"
           )
  end

  test "deactivates an operator and prevents future login", %{conn: conn, scope: scope} do
    %{user: operator, temporary_password: temporary_password} =
      operator_fixture(scope, %{"email" => "deactivate.operator@example.com"})

    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    view |> element("#deactivate-operator-#{operator.id}") |> render_click()

    assert has_element?(view, "#operator-row-#{operator.id}-status", "disabled")

    assert has_element?(
             view,
             "#operator-row-#{operator.id} .avatar.avatar-offline"
           )

    assert Repo.get!(User, operator.id).status == "disabled"

    assert {:error, :invalid_credentials} =
             Accounts.login_user(%{"email" => operator.email, "password" => temporary_password})
  end

  @tag :last_active_admin
  test "rejects deactivating the last active operator", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    assert has_element?(view, "#deactivate-operator-#{user.id}[disabled]")
    assert has_element?(view, "#operator-row-#{user.id}-status", "active")
    assert Repo.get!(User, user.id).status == "active"
  end

  test "resets an operator password and emails the generated temporary password", %{
    conn: conn,
    scope: scope
  } do
    %{user: operator, temporary_password: original_password} =
      operator_fixture(scope, %{"email" => "reset.operator@example.com"})

    {:ok, view, _html} = live(conn, ~p"/admin/operators")

    view |> element("#reset-operator-password-#{operator.id}") |> render_click()

    assert has_element?(view, "#operator-password-dialog[open]")
    assert has_element?(view, "#operator-reset-password-form")
    assert has_element?(view, "#operator-reset-password-cancel + #operator-reset-password-submit")
    assert has_element?(view, "#operator-password-dialog", "reset.operator@example.com")
    assert_admin_dialog_docs_link(view, "operator-password-dialog-footer")

    html =
      view
      |> element("#operator-reset-password-form")
      |> render_submit(%{
        "operator_reset" => %{
          "password_mode" => "generated",
          "password" => "",
          "password_change_required" => "false",
          "send_email" => "true"
        }
      })

    reset_password = extract_temporary_password!(html)

    refute Accounts.get_user_by_email_and_password(operator.email, original_password)

    assert Accounts.get_user_by_email_and_password(operator.email, reset_password).id ==
             operator.id

    refute Repo.get!(User, operator.id).password_change_required

    assert has_element?(view, "#operator-temporary-password-dialog-receipt")
    assert has_element?(view, "#operator-temporary-password-dialog-value", reset_password)
    assert has_element?(view, "#operator-copy-temporary-password")
    assert has_element?(view, "#operator-password-dialog-close")
    assert_admin_dialog_docs_link(view, "operator-temporary-password-dialog-receipt-footer")

    assert_email_sent(fn email ->
      assert email.to == [{"", operator.email}]
      assert email.subject == "Codex Pooler temporary password"
      assert email.text_body =~ "Temporary password: #{reset_password}"
      refute email.text_body =~ "You will be asked to change this password after sign in."
      refute email.html_body
      true
    end)
  end

  test "password reset disconnects an active target operator LiveView", %{
    conn: conn,
    scope: scope
  } do
    %{user: operator, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "connected.operator@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: operator_token}} =
             Accounts.login_user(%{"email" => operator.email, "password" => temporary_password})

    operator_conn = log_in_user(build_conn(), operator, operator_token)
    {:ok, operator_view, _html} = live(operator_conn, ~p"/admin/upstreams")

    {:ok, admin_view, _html} = live(conn, ~p"/admin/operators")

    admin_view |> element("#reset-operator-password-#{operator.id}") |> render_click()

    admin_view
    |> element("#operator-reset-password-form")
    |> render_submit(%{
      "operator_reset" => %{
        "password_mode" => "generated",
        "password" => "",
        "send_email" => "false"
      }
    })

    assert_redirect(operator_view, ~p"/login")
  end

  defp extract_temporary_password!(html) do
    case Regex.run(~r/<code[^>]*>\s*([^<\s]+)\s*<\/code>/, html) do
      [_match, temporary_password] -> temporary_password
      _match -> flunk("temporary password was not rendered in the one-time receipt")
    end
  end

  defp open_create_dialog(view) do
    view |> element("#operator-page-create-action") |> render_click()
  end

  defp assert_admin_dialog_docs_link(view, footer_id) do
    docs_url =
      case footer_id do
        "operator-create-dialog-footer" ->
          "https://docs.codex-pooler.com/operators/operators/#create-operator"

        "operator-create-temporary-password-receipt-footer" ->
          "https://docs.codex-pooler.com/operators/operators/#password-reset"

        "operator-edit-dialog-footer" ->
          "https://docs.codex-pooler.com/operators/operators/#action-menu"

        "operator-password-dialog-footer" ->
          "https://docs.codex-pooler.com/operators/operators/#password-reset"

        "operator-temporary-password-dialog-receipt-footer" ->
          "https://docs.codex-pooler.com/operators/operators/#password-reset"
      end

    assert has_element?(
             view,
             "##{footer_id} [data-role='admin-dialog-docs-link'][href='#{docs_url}'][target='_blank'][rel='noopener noreferrer'].text-xs",
             "Docs"
           )

    assert has_element?(
             view,
             "##{footer_id}-docs-link [data-role='admin-dialog-docs-icon']"
           )
  end
end
