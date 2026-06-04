defmodule CodexPoolerWeb.AuthControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{Session, User}
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures

  setup do
    reset_bootstrap_state_fixture!()
    :ok
  end

  test "bootstrap and login pages expose stable form selectors", %{conn: conn} do
    conn = get(conn, ~p"/bootstrap")
    bootstrap_html = html_response(conn, 200)

    assert bootstrap_html =~ ~s(id="bootstrap-form")
    assert bootstrap_html =~ ~s(name="user[email]")

    post(conn, ~p"/bootstrap", %{
      "user" => valid_bootstrap_attributes(%{"email" => "owner@example.com"})
    })

    conn = get(build_conn(), ~p"/login")
    login_html = html_response(conn, 200)

    assert login_html =~ ~s(id="login-form")
    assert login_html =~ ~s(name="user[email]")
    assert login_html =~ ~s(name="user[password]")
    refute login_html =~ ~s(name="user[totp_code]")
    refute login_html =~ ~s(name="user[recovery_code]")
  end

  test "invalid login redirects back with the shared safe error alert", %{conn: conn} do
    bootstrap_owner_fixture(%{"email" => "owner@example.com"})

    conn =
      post(conn, ~p"/login", %{
        "user" => %{"email" => "owner@example.com", "password" => "wrong-password"}
      })

    assert redirected_to(conn) == ~p"/login"

    conn = conn |> recycle() |> get(~p"/login")
    html = html_response(conn, 200)

    assert html =~ ~s(id="flash-error")
    assert html =~ ~s(role="alert")
    assert html =~ "Invalid email or password."
    refute html =~ "wrong-password"
  end

  test "bootstrap form creates owner session and second bootstrap redirects to login", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/bootstrap", %{
        "user" => valid_bootstrap_attributes(%{"email" => "owner@example.com"})
      })

    assert redirected_to(conn) == ~p"/admin/pools"
    assert get_session(conn, :user_token)

    retry =
      post(build_conn(), ~p"/bootstrap", %{
        "user" => valid_bootstrap_attributes(%{"email" => "second@example.com"})
      })

    assert redirected_to(retry) == ~p"/login"
  end

  test "bootstrap ignores stale return_to and lands on pools", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{user_return_to: "/admin/upstreams"})
      |> post(~p"/bootstrap", %{
        "user" => valid_bootstrap_attributes(%{"email" => "owner@example.com"})
      })

    assert redirected_to(conn) == ~p"/admin/pools"
    assert get_session(conn, :user_token)
  end

  test "login/logout and optional session probe use DB-backed sessions", %{conn: conn} do
    bootstrap_owner_fixture(%{"email" => "owner@example.com"})

    anonymous = get(conn, ~p"/session?optional=1")
    assert json_response(anonymous, 200) == %{"authenticated" => false, "status" => "ok"}

    conn =
      post(conn, ~p"/login", %{
        "user" => %{"email" => "owner@example.com", "password" => valid_user_password()}
      })

    assert redirected_to(conn) == ~p"/admin/pools"
    assert token = get_session(conn, :user_token)
    assert Accounts.get_user_by_session_token(token)

    authed = get(conn, ~p"/session?optional=1")

    assert %{"authenticated" => true, "user" => %{"email" => "owner@example.com"}} =
             json_response(authed, 200)

    conn = delete(conn, ~p"/logout")
    assert redirected_to(conn) == ~p"/login"
    refute Accounts.get_user_by_session_token(token)
  end

  test "browser login records the forwarded IP when the peer is a trusted proxy", %{conn: conn} do
    setup_trusted_proxies(["10.42.0.0/16"])
    %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

    conn =
      conn
      |> Map.put(:remote_ip, {10, 42, 0, 50})
      |> put_req_header("x-forwarded-for", "203.0.113.55, 10.42.0.50")
      |> post(~p"/login", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == ~p"/admin/pools"
    session = Repo.get!(Session, Accounts.session_id_for_token(get_session(conn, :user_token)))

    assert session.ip_address == "203.0.113.55"
  end

  test "authenticated root redirects to pools", %{conn: conn} do
    bootstrap_owner_fixture(%{"email" => "owner@example.com"})

    conn =
      post(conn, ~p"/login", %{
        "user" => %{"email" => "owner@example.com", "password" => valid_user_password()}
      })

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/admin/pools"
  end

  test "TOTP-required login continues on a second-factor screen", %{conn: conn} do
    %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
    {:ok, %{secret: secret}} = Accounts.enable_totp_for_user(user)

    pending_mfa =
      post(conn, ~p"/login", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(pending_mfa) == ~p"/login?mfa=1"
    assert get_session(pending_mfa, :pending_mfa_user_id) == user.id
    assert get_session(pending_mfa, :pending_mfa_email) == user.email
    refute get_session(pending_mfa, :user_token)

    mfa_page = pending_mfa |> recycle() |> get(~p"/login?mfa=1")
    html = html_response(mfa_page, 200)

    assert html =~ ~s(id="login-mfa-form")
    assert html =~ ~s(id="login-totp-panel")
    assert html =~ ~s(id="user_totp_code_otp")
    assert html =~ ~s(phx-hook="OtpInput")
    assert html =~ ~s(name="user[totp_code]")
    assert html =~ ~s(data-otp-value)
    assert html =~ ~s(id="user_totp_code_digit_0")
    assert html =~ ~s(id="user_totp_code_digit_5")
    assert html =~ ~s(data-otp-slot="0")
    assert html =~ ~s(data-otp-slot="5")
    assert html =~ ~s(autocomplete="one-time-code")
    assert html =~ ~s(inputmode="numeric")
    assert html =~ ~s(maxlength="6")
    refute html =~ ~s(name="user[email]")
    refute html =~ ~s(name="user[password]")
    refute html =~ ~s(name="user[recovery_code]")

    conn =
      post(recycle(pending_mfa), ~p"/login", %{
        "user" => %{"totp_code" => Accounts.current_totp_code(secret)}
      })

    assert redirected_to(conn) == ~p"/admin/pools"
    assert get_session(conn, :user_token)
    refute get_session(conn, :pending_mfa_user_id)
    refute get_session(conn, :pending_mfa_email)
  end

  test "TOTP-required login can finish with an unused recovery code", %{conn: conn} do
    %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
    {:ok, %{recovery_codes: [recovery_code | _]}} = Accounts.enable_totp_for_user(user)

    missing_totp =
      post(conn, ~p"/login", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(missing_totp) == ~p"/login?mfa=1"

    recovery_page = missing_totp |> recycle() |> get(~p"/login?mfa=1&method=recovery")
    recovery_html = html_response(recovery_page, 200)

    assert recovery_html =~ ~s(id="login-recovery-panel")
    assert recovery_html =~ ~s(name="user[recovery_code]")
    refute recovery_html =~ ~s(name="user[totp_code]")

    conn =
      post(recycle(missing_totp), ~p"/login", %{
        "user" => %{
          "recovery_code" => recovery_code
        }
      })

    assert redirected_to(conn) == ~p"/admin/pools"
    assert get_session(conn, :user_token)

    reused =
      post(build_conn() |> init_test_session(%{pending_mfa_user_id: user.id}), ~p"/login", %{
        "user" => %{"recovery_code" => recovery_code}
      })

    assert redirected_to(reused) == ~p"/login?mfa=1"
  end

  test "password change API requires current password, preserves the current session, revokes parallel sessions, and accepts the new password",
       %{
         conn: conn
       } do
    %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

    assert {:ok, %{token: parallel_token}} =
             Accounts.login_user(%{"email" => user.email, "password" => valid_user_password()})

    conn =
      post(conn, ~p"/login", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    current_token = get_session(conn, :user_token)
    assert Accounts.get_user_by_session_token(current_token)
    assert Accounts.get_user_by_session_token(parallel_token)

    Phoenix.PubSub.subscribe(
      CodexPooler.PubSub,
      CodexPoolerWeb.UserAuth.user_sessions_topic(user.id)
    )

    conn =
      post(conn, ~p"/settings/password", %{
        "user" => %{
          "current_password" => valid_user_password(),
          "new_password" => "new-bootstrap-pass-456"
        }
      })

    assert json_response(conn, 200) == %{"authenticated" => true, "status" => "ok"}
    assert get_session(conn, :user_token) == current_token
    assert Accounts.get_user_by_session_token(current_token)
    refute Accounts.get_user_by_session_token(parallel_token)

    assert_receive {:disconnect_user_sessions,
                    %{user_id: user_id, except_live_socket_id: except_live_socket_id}}

    assert user_id == user.id

    assert except_live_socket_id ==
             CodexPoolerWeb.UserAuth.live_socket_id_for_token(current_token)

    conn = delete(conn, ~p"/logout")
    assert redirected_to(conn) == ~p"/login"

    old_password =
      post(build_conn(), ~p"/login", %{
        "user" => %{"email" => "owner@example.com", "password" => valid_user_password()}
      })

    assert redirected_to(old_password) == ~p"/login"

    new_password =
      post(build_conn(), ~p"/login", %{
        "user" => %{"email" => "owner@example.com", "password" => "new-bootstrap-pass-456"}
      })

    assert redirected_to(new_password) == ~p"/admin/pools"
    assert get_session(new_password, :user_token)
  end

  test "login preserves safe return_to and ignores external return_to", %{conn: conn} do
    bootstrap_owner_fixture(%{"email" => "owner@example.com"})

    internal_conn =
      conn
      |> init_test_session(%{})
      |> put_session(:user_return_to, "/admin/pools")

    conn =
      post(internal_conn, ~p"/login", %{
        "user" => %{"email" => "owner@example.com", "password" => valid_user_password()}
      })

    assert redirected_to(conn) == ~p"/admin/pools"

    external_conn =
      build_conn()
      |> init_test_session(%{})
      |> put_session(:user_return_to, "https://example.com/evil")

    conn =
      post(external_conn, ~p"/login", %{
        "user" => %{"email" => "owner@example.com", "password" => valid_user_password()}
      })

    assert redirected_to(conn) == ~p"/admin/pools"
  end

  test "password change API rejects anonymous and invalid password requests", %{conn: conn} do
    %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

    anonymous =
      post(conn, ~p"/settings/password", %{
        "user" => %{"new_password" => "new-bootstrap-pass-456"}
      })

    assert redirected_to(anonymous) == ~p"/login"

    conn =
      post(build_conn(), ~p"/login", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    current_token = get_session(conn, :user_token)

    missing_current_password =
      post(conn, ~p"/settings/password", %{
        "user" => %{"new_password" => "new-bootstrap-pass-456"}
      })

    assert %{"error" => %{"code" => "invalid_current_password"}} =
             json_response(missing_current_password, 422)

    assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    assert Accounts.get_user_by_session_token(current_token)
    refute Accounts.get_user_by_email_and_password(user.email, "new-bootstrap-pass-456")

    wrong_current_password =
      post(conn, ~p"/settings/password", %{
        "user" => %{
          "current_password" => "wrong-current-password",
          "new_password" => "new-bootstrap-pass-456"
        }
      })

    assert %{"error" => %{"code" => "invalid_current_password"}} =
             json_response(wrong_current_password, 422)

    assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    assert Accounts.get_user_by_session_token(current_token)
    refute Accounts.get_user_by_email_and_password(user.email, "new-bootstrap-pass-456")

    invalid =
      post(conn, ~p"/settings/password", %{
        "user" => %{"current_password" => valid_user_password(), "new_password" => "short"}
      })

    assert %{"error" => %{"code" => "invalid_password"}} = json_response(invalid, 422)
    assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
  end

  describe "forced password change auth flow" do
    @tag :forced_password_change
    test "normal login redirects active operators to pools when the flag is false", %{
      conn: conn
    } do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: false})

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/admin/pools"
      assert token = get_session(conn, :user_token)
      assert Accounts.get_user_by_session_token(token)
    end

    @tag :forced_password_change
    test "login redirects operators who must change their password", %{conn: conn} do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: true})

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/password/change-required"
      assert token = get_session(conn, :user_token)
      assert Accounts.get_user_by_session_token(token)
    end

    @tag :forced_password_change
    test "logout stays available while a password change is required", %{conn: conn} do
      %{user: user, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: true})

      conn = log_in_user(conn, user, token)
      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute Accounts.get_user_by_session_token(get_session(conn, :user_token))
    end

    @tag :forced_password_change
    test "forced password changes require confirmation before mutating the password", %{
      conn: conn
    } do
      %{user: user, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: true})

      conn = log_in_user(conn, user, token)
      {:ok, view, _html} = live(conn, ~p"/password/change-required")

      assert has_element?(view, "#password-change-logo span.uppercase", "CODEX POOLER")
      refute has_element?(view, "#password-change-logo img")

      assert has_element?(view, "#password-change-required-form")
      assert has_element?(view, "#password-change-form")
      assert has_element?(view, "h1.uppercase.text-primary", "Choose a private password")
      assert has_element?(view, "#auth-footer", "Codex Pooler")

      assert has_element?(
               view,
               "#auth-footer a[href='https://docs.codex-pooler.com']",
               "Codex Pooler"
             )

      for params <- [
            %{"new_password" => "new-bootstrap-pass-456"},
            %{"new_password" => "new-bootstrap-pass-456", "new_password_confirmation" => ""},
            %{
              "new_password" => "new-bootstrap-pass-456",
              "new_password_confirmation" => "different-pass-456"
            }
          ] do
        html =
          view
          |> element("#password-change-form")
          |> render_submit(%{"user" => params})

        assert html =~ "Passwords do not match."
        assert Repo.reload!(user).password_change_required
        assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
        refute Accounts.get_user_by_email_and_password(user.email, "new-bootstrap-pass-456")
      end
    end

    @tag :forced_password_change
    test "forced password changes submit the change-required form, clear the flag, revoke parallel sessions, and land on pools",
         %{conn: conn} do
      %{user: user, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: true})

      assert {:ok, %{token: parallel_token}} =
               Accounts.login_user(%{"email" => user.email, "password" => valid_user_password()})

      conn = log_in_user(conn, user, token)

      Phoenix.PubSub.subscribe(
        CodexPooler.PubSub,
        CodexPoolerWeb.UserAuth.user_sessions_topic(user.id)
      )

      {:ok, view, _html} = live(conn, ~p"/password/change-required")

      assert has_element?(view, "#password-change-required-form")
      assert has_element?(view, "#password-change-form")

      view
      |> element("#password-change-form")
      |> render_submit(%{
        "user" => %{
          "new_password" => "new-bootstrap-pass-456",
          "new_password_confirmation" => "new-bootstrap-pass-456"
        }
      })

      assert_redirect(view, ~p"/admin/pools")

      assert_receive {:disconnect_user_sessions,
                      %{user_id: user_id, except_live_socket_id: except_live_socket_id}}

      assert user_id == user.id
      assert except_live_socket_id == CodexPoolerWeb.UserAuth.live_socket_id_for_token(token)

      reloaded_user = Repo.get!(User, user.id)
      refute reloaded_user.password_change_required

      assert token = get_session(conn, :user_token)
      assert Accounts.get_user_by_session_token(token)
      refute Accounts.get_user_by_session_token(parallel_token)
    end

    @tag :forced_password_change
    test "password-change-required users can still reach the change-required page", %{conn: conn} do
      %{user: user, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: true})

      conn = log_in_user(conn, user, token)

      assert {:ok, _view, _html} = live(conn, ~p"/password/change-required")
    end

    @tag :forced_password_change
    test "password-change-required users cannot access /admin/operators and are redirected to change-required",
         %{conn: conn} do
      %{user: user, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: true})

      conn = log_in_user(conn, user, token)

      assert {:error, {:redirect, %{to: "/password/change-required"}}} =
               live(conn, ~p"/admin/operators")
    end
  end

  describe "inactive operator auth" do
    @tag :inactive_operator_login
    test "inactive users cannot log in", %{conn: _conn} do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      inactive_user = update_user(user, %{status: "disabled"})

      conn =
        post(build_conn(), ~p"/login", %{
          "user" => %{"email" => inactive_user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end
  end

  defp update_user(%User{} = user, attrs) do
    user
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp setup_trusted_proxies(trusted_proxies) do
    settings = %OperationalSettings{trusted_proxies: trusted_proxies}
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end
end
