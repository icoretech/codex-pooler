defmodule CodexPoolerWeb.Admin.SettingsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.TOTPSetting
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.DateTimeDisplay
  alias CodexPoolerWeb.UserAuth

  import CodexPooler.AccountsFixtures, only: [operator_fixture: 2, valid_user_password: 0]

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "renders settings tabs with appearance controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(view, "#admin-settings-live")
    assert has_element?(view, "#admin-nav-settings[aria-current='page']")
    assert has_element?(view, "#settings-tabs[role='tablist']")
    assert has_element?(view, "#settings-tab-appearance[aria-selected='true']", "Appearance")
    assert has_element?(view, "#settings-tab-account", "Account")
    assert has_element?(view, "#settings-tab-security", "Security")
    assert has_element?(view, "#settings-appearance-panel")
    assert has_element?(view, "#settings-theme-toggle")
    refute has_element?(view, "#system-settings-panel")
    refute has_element?(view, "#instance-settings-form")
    refute has_element?(view, "#instance-settings-gateway")
  end

  test "instance admins keep self-service settings access", %{scope: scope} do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "settings-admin@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)

    {:ok, view, _html} = live(admin_conn, ~p"/admin/settings?tab=account")

    assert has_element?(view, "#admin-settings-live")
    assert has_element?(view, "#admin-nav-settings[aria-current='page']")
    assert has_element?(view, "#settings-tab-account[aria-selected='true']")
    assert has_element?(view, "#settings-account-form")
    assert has_element?(view, "#settings-mcp-panel")
    refute has_element?(view, "#system-settings-panel")
    refute has_element?(view, "#admin-nav-jobs")
    refute has_element?(view, "#admin-nav-system")
  end

  test "renders account and security tabs through patch params", %{conn: conn, user: user} do
    {:ok, account_view, _html} = live(conn, ~p"/admin/settings?tab=account")

    assert has_element?(account_view, "#settings-tab-account[aria-selected='true']")
    assert has_element?(account_view, "#settings-account-panel")
    assert has_element?(account_view, "#settings-account-form")
    assert has_element?(account_view, "#settings-account-email[value='#{user.email}']")
    assert has_element?(account_view, "#settings-account-display-name")
    assert has_element?(account_view, "#settings-account-datetime-format")
    assert has_element?(account_view, "#settings-account-timezone")

    {:ok, security_view, _html} = live(conn, ~p"/admin/settings?tab=security")

    assert has_element?(security_view, "#settings-tab-security[aria-selected='true']")
    assert has_element?(security_view, "#settings-security-panel")
    assert has_element?(security_view, "#settings-totp-status", "TOTP not set up")
    assert has_element?(security_view, "#settings-enable-totp")
    assert has_element?(security_view, "#settings-password-form")
    assert has_element?(security_view, "#settings-current-password")
    assert has_element?(security_view, "#settings-new-password")
    assert has_element?(security_view, "#settings-new-password-confirmation")
    assert has_element?(security_view, "#settings-session-panel")
    assert has_element?(security_view, "#settings-session-list")
    assert has_element?(security_view, "#settings-current-session-badge", "This session")
  end

  test "updates the signed-in operator identity", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=account")

    view
    |> element("#settings-account-form")
    |> render_submit(%{
      "user" => %{
        "email" => " Updated.Owner@Example.COM ",
        "display_name" => "Updated Owner"
      }
    })

    updated = Accounts.get_user!(user.id)
    assert updated.email == "updated.owner@example.com"
    assert updated.display_name == "Updated Owner"
    assert has_element?(view, "#settings-account-email[value='updated.owner@example.com']")
    assert has_element?(view, "#admin-sidebar-operator-label", "Updated Owner")
  end

  test "renders datetime preference selects from the shared formatter options", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/settings?tab=account")

    assert has_element?(view, "#settings-account-datetime-format")
    assert has_element?(view, "#settings-account-timezone")

    assert select_options(html, "settings-account-datetime-format") ==
             DateTimeDisplay.format_options()

    timezone_options = DateTimeDisplay.timezone_options()
    assert select_options(html, "settings-account-timezone") == timezone_options
    assert List.first(timezone_options) == {"Etc/UTC", "Etc/UTC"}
    assert {"Europe/Rome", "Europe/Rome"} in timezone_options
  end

  test "saves datetime preferences through the account form and reloads selected", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=account")

    html =
      view
      |> element("#settings-account-form")
      |> render_submit(%{
        "user" => %{
          "email" => user.email,
          "display_name" => user.display_name,
          "datetime_format" => "long",
          "timezone" => "Europe/Rome"
        }
      })

    assert html =~ "Account settings updated"

    updated = Accounts.get_user!(user.id)
    assert updated.datetime_format == "long"
    assert updated.timezone == "Europe/Rome"
    assert has_element?(view, "#settings-account-datetime-format option[selected][value='long']")
    assert has_element?(view, "#settings-account-timezone option[selected][value='Europe/Rome']")

    {:ok, remounted_view, _html} = live(conn, ~p"/admin/settings?tab=account")

    assert has_element?(
             remounted_view,
             "#settings-account-datetime-format option[selected][value='long']"
           )

    assert has_element?(
             remounted_view,
             "#settings-account-timezone option[selected][value='Europe/Rome']"
           )
  end

  test "rejects forged datetime preference values without persisting", %{conn: conn, user: user} do
    assert {:ok, _updated} =
             Accounts.update_current_operator_profile(user, %{
               "email" => user.email,
               "display_name" => user.display_name,
               "datetime_format" => "short",
               "timezone" => "Europe/Rome"
             })

    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=account")

    html =
      view
      |> element("#settings-account-form")
      |> render_submit(%{
        "user" => %{
          "email" => user.email,
          "display_name" => user.display_name,
          "datetime_format" => "custom",
          "timezone" => "Europe/NotAZone"
        }
      })

    assert html =~ "is invalid"
    assert html =~ "must be a valid IANA time zone"

    reloaded = Accounts.get_user!(user.id)
    assert reloaded.datetime_format == "short"
    assert reloaded.timezone == "Europe/Rome"
  end

  test "renders account MCP setup panel with gate status and safe setup instructions", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=account")

    assert has_element?(view, "#settings-mcp-panel", "MCP access")
    assert has_element?(view, "#settings-mcp-global-status", "Global MCP service disabled")
    assert has_element?(view, "#settings-mcp-account-status", "Disabled for this operator")
    assert has_element?(view, "#settings-mcp-global-settings-link", "Open system settings")
    assert has_element?(view, "#settings-mcp-toggle-form")
    assert has_element?(view, "#settings-mcp-enabled-toggle")
    assert has_element?(view, "#settings-mcp-key-list")
    assert has_element?(view, "#settings-mcp-create-form")
    assert has_element?(view, "#settings-mcp-create-label")
    assert has_element?(view, "#settings-mcp-endpoint", "/mcp")
    assert has_element?(view, "#settings-mcp-protocol", "2025-11-25")
    assert has_element?(view, "#settings-mcp-auth-shape", "Authorization: Bearer <MCP token>")

    assert has_element?(
             view,
             "#settings-mcp-origin-policy",
             "Absent Origin headers from CLI clients are accepted"
           )

    assert has_element?(view, "#settings-mcp-usage-warning", "Usage is not tracked per key")
  end

  test "creates MCP key and reveals raw token only for the create result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=account")

    created_html =
      view
      |> element("#settings-mcp-create-form")
      |> render_submit(%{"mcp_key" => %{"label" => "Desktop MCP"}})

    [raw_token] = Regex.run(~r/mcp-cxp-[0-9a-f]{12}-[A-Za-z0-9_-]+/, created_html)
    assert has_element?(view, "#settings-mcp-created-token-dialog")
    assert has_element?(view, "#settings-mcp-created-token-value", raw_token)
    assert has_element?(view, "#settings-mcp-key-list", "Desktop MCP")

    close_html =
      view
      |> element("#settings-mcp-created-token-close")
      |> render_click()

    refute close_html =~ raw_token

    {:ok, remounted_view, remounted_html} = live(conn, ~p"/admin/settings?tab=account")
    assert has_element?(remounted_view, "#settings-mcp-key-list", "Desktop MCP")
    refute remounted_html =~ raw_token
  end

  test "renames MCP key without re-revealing raw token", %{conn: conn, user: user} do
    {:ok, %{key: key, raw_token: raw_token}} =
      MCP.create_operator_token(user, %{label: "Old MCP"})

    {:ok, view, html} = live(conn, ~p"/admin/settings?tab=account")
    refute html =~ raw_token

    rename_html =
      view
      |> element("#settings-mcp-key-#{key.id}-rename-form")
      |> render_submit(%{"mcp_key" => %{"id" => key.id, "label" => "Renamed MCP"}})

    assert Repo.reload!(key).label == "Renamed MCP"
    assert has_element?(view, "#settings-mcp-key-row-#{key.id}", "Renamed MCP")
    refute rename_html =~ raw_token
  end

  test "deletes MCP key permanently after exact confirmation copy", %{conn: conn, user: user} do
    enable_global_mcp!()
    assert {:ok, _settings} = MCP.set_operator_mcp_enabled(user, true)

    {:ok, %{key: key, raw_token: raw_token}} =
      MCP.create_operator_token(user, %{label: "Delete MCP"})

    assert {:ok, _auth} = MCP.authenticate_token(raw_token)

    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=account")

    dialog_html =
      view
      |> element("#settings-mcp-key-#{key.id}-delete")
      |> render_click()

    expected_delete_copy =
      "Deleting this MCP key is permanent. Existing clients using it will fail immediately. Usage is not tracked per key"

    assert dialog_html =~ expected_delete_copy
    assert has_element?(view, "#settings-mcp-delete-form", expected_delete_copy)

    view
    |> element("#settings-mcp-delete-form")
    |> render_submit(%{"mcp_key_delete" => %{"id" => key.id}})

    refute Repo.get(OperatorMCPKey, key.id)
    assert {:error, %{code: :mcp_token_missing}} = MCP.authenticate_token(raw_token)
    refute has_element?(view, "#settings-mcp-key-row-#{key.id}")
  end

  test "operator MCP toggle preserves keys while disabling valid clients", %{
    conn: conn,
    user: user
  } do
    enable_global_mcp!()

    {:ok, %{key: key, raw_token: raw_token}} =
      MCP.create_operator_token(user, %{label: "Toggle MCP"})

    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=account")
    assert has_element?(view, "#settings-mcp-key-row-#{key.id}", "Toggle MCP")
    assert {:error, %{code: :mcp_account_disabled}} = MCP.authenticate_token(raw_token)

    enable_html =
      view
      |> element("#settings-mcp-toggle-form")
      |> render_submit(%{"mcp_account" => %{"enabled" => "true"}})

    assert enable_html =~ "MCP enabled for this operator"
    assert has_element?(view, "#settings-mcp-account-status", "Enabled for this operator")
    assert {:ok, _auth} = MCP.authenticate_token(raw_token)

    disable_html =
      view
      |> element("#settings-mcp-toggle-form")
      |> render_submit(%{"mcp_account" => %{"enabled" => "false"}})

    assert disable_html =~ "MCP disabled for this operator"
    assert has_element?(view, "#settings-mcp-key-row-#{key.id}", "Toggle MCP")
    assert {:error, %{code: :mcp_account_disabled}} = MCP.authenticate_token(raw_token)
  end

  test "enables totp and renders one-time setup material only after creation", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=security")

    view
    |> element("#settings-enable-totp")
    |> render_click()

    setting = Repo.get_by!(TOTPSetting, user_id: user.id)
    assert setting.status == "active"
    assert has_element?(view, "#settings-totp-status", "TOTP enabled")
    assert has_element?(view, "#settings-totp-secret")
    assert has_element?(view, "#settings-totp-recovery-codes li")
    refute render(view) =~ "TOTP not set up"

    {:ok, remounted_view, remounted_html} = live(conn, ~p"/admin/settings?tab=security")

    assert has_element?(remounted_view, "#settings-totp-status", "TOTP enabled")
    refute remounted_html =~ "settings-totp-secret"
    refute remounted_html =~ "settings-totp-recovery-codes"
  end

  test "changes the signed-in operator password from the security tab", %{
    conn: conn,
    user: user
  } do
    current_token = get_session(conn, :user_token)

    assert {:ok, %{token: parallel_token}} =
             Accounts.login_user(%{"email" => user.email, "password" => valid_user_password()})

    Phoenix.PubSub.subscribe(
      CodexPooler.PubSub,
      UserAuth.user_sessions_topic(user.id)
    )

    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=security")

    html =
      view
      |> element("#settings-password-form")
      |> render_submit(%{
        "user" => %{
          "current_password" => valid_user_password(),
          "new_password" => "new-settings-pass-456",
          "new_password_confirmation" => "new-settings-pass-456"
        }
      })

    assert html =~ "Password updated"
    refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    assert Accounts.get_user_by_email_and_password(user.email, "new-settings-pass-456")
    assert Accounts.get_user_by_session_token(current_token)
    refute Accounts.get_user_by_session_token(parallel_token)

    assert_receive {:disconnect_user_sessions,
                    %{user_id: user_id, except_live_socket_id: except_live_socket_id}}

    assert user_id == user.id
    assert except_live_socket_id == UserAuth.live_socket_id_for_token(current_token)
  end

  test "rejects password changes without the current password and confirmation", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=security")

    mismatch_html =
      view
      |> element("#settings-password-form")
      |> render_submit(%{
        "user" => %{
          "current_password" => valid_user_password(),
          "new_password" => "new-settings-pass-456",
          "new_password_confirmation" => "different-settings-pass-456"
        }
      })

    assert mismatch_html =~ "Passwords do not match."

    wrong_current_html =
      view
      |> element("#settings-password-form")
      |> render_submit(%{
        "user" => %{
          "current_password" => "wrong-password",
          "new_password" => "new-settings-pass-456",
          "new_password_confirmation" => "new-settings-pass-456"
        }
      })

    assert wrong_current_html =~ "Current password is incorrect."
    assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    refute Accounts.get_user_by_email_and_password(user.email, "new-settings-pass-456")
  end

  test "renders active browser sessions and logs out other sessions", %{conn: conn, user: user} do
    Accounts.delete_user_session_token(get_session(conn, :user_token))

    assert {:ok, %{token: current_token}} =
             Accounts.login_user(
               %{"email" => user.email, "password" => valid_user_password()},
               %{
                 user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Codex",
                 ip_address: "198.51.100.20"
               }
             )

    conn = log_in_user(build_conn(), user, current_token)

    assert {:ok, %{token: parallel_token}} =
             Accounts.login_user(
               %{"email" => user.email, "password" => valid_user_password()},
               %{
                 user_agent:
                   "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) Gecko/20100101 Firefox/150.0",
                 ip_address: "203.0.113.55"
               }
             )

    Phoenix.PubSub.subscribe(
      CodexPooler.PubSub,
      UserAuth.user_sessions_topic(user.id)
    )

    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=security")

    assert has_element?(view, "#settings-session-panel", "Browser sessions")
    assert has_element?(view, "#settings-session-list li", "This session")
    assert has_element?(view, "#settings-session-list li", "198.51.100.20")
    assert has_element?(view, "#settings-session-list li", "203.0.113.55")
    assert has_element?(view, "#settings-session-list li[data-session-device='desktop']")
    assert has_element?(view, "#settings-session-list li", "Firefox/150.0")
    assert has_element?(view, "#settings-logout-other-sessions")

    html =
      view
      |> element("#settings-logout-other-sessions")
      |> render_click()

    assert html =~ "Other sessions signed out"
    assert Accounts.get_user_by_session_token(current_token)
    refute Accounts.get_user_by_session_token(parallel_token)
    refute has_element?(view, "#settings-session-list li", "Firefox/150.0")

    assert_receive {:disconnect_user_sessions,
                    %{user_id: user_id, except_live_socket_id: except_live_socket_id}}

    assert user_id == user.id
    assert except_live_socket_id == UserAuth.live_socket_id_for_token(current_token)
  end

  test "logs out one selected browser session", %{conn: conn, user: user} do
    current_token = get_session(conn, :user_token)

    assert {:ok, %{token: other_token}} =
             Accounts.login_user(
               %{"email" => user.email, "password" => valid_user_password()},
               %{user_agent: "Other Browser", ip_address: "203.0.113.60"}
             )

    other_session_id = Accounts.session_id_for_token(other_token)

    other_session =
      user
      |> Accounts.list_user_sessions(current_token)
      |> Enum.find(&(&1.id == other_session_id))

    assert other_session

    Phoenix.PubSub.subscribe(CodexPooler.PubSub, UserAuth.user_sessions_topic(user.id))

    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=security")

    html =
      view
      |> element("#settings-session-revoke-#{other_session.id}")
      |> render_click()

    assert html =~ "Browser session signed out"
    assert Accounts.get_user_by_session_token(current_token)
    refute Accounts.get_user_by_session_token(other_token)
    refute has_element?(view, "#settings-session-#{other_session.id}")

    assert_receive {:disconnect_user_sessions, %{user_id: user_id, session_id: session_id}}
    assert user_id == user.id
    assert session_id == other_session.id
  end

  test "signing out the current browser session redirects to login", %{conn: conn, user: user} do
    current_token = get_session(conn, :user_token)

    [current_session] =
      user
      |> Accounts.list_user_sessions(current_token)
      |> Enum.filter(& &1.current?)

    {:ok, view, _html} = live(conn, ~p"/admin/settings?tab=security")

    view
    |> element("#settings-session-revoke-#{current_session.id}")
    |> render_click()

    refute Accounts.get_user_by_session_token(current_token)
    assert_redirect(view, ~p"/login")
  end

  defp select_options(html, select_id) do
    select_id = Regex.escape(select_id)

    assert [_, select_html] =
             Regex.run(~r/<select[^>]*id="#{select_id}"[^>]*>(.*?)<\/select>/s, html)

    ~r/<option(?:\s+[^>]*)*\svalue="([^"]*)"[^>]*>(.*?)<\/option>/s
    |> Regex.scan(select_html)
    |> Enum.map(fn [_option, value, label] -> {label, value} end)
  end

  defp enable_global_mcp! do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})

    updated
  end
end
