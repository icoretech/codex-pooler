defmodule CodexPoolerWeb.Admin.InvitesLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Swoosh.TestAssertions

  alias CodexPooler.Access
  alias CodexPooler.Access.Invite
  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Mailer
  alias CodexPooler.Repo

  setup :owner_session

  setup do
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
    Application.delete_env(:swoosh, :local)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
      Application.delete_env(:swoosh, :local)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    :ok
  end

  test "unassigned instance admins do not get Pool creation CTAs on invites", %{scope: scope} do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "unassigned-invite-admin@example.com",
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/invites")

    assert has_element?(view, "#invite-empty-state")
    refute has_element?(view, "#invite-page-create-pool")
    refute has_element?(view, "#invite-page-create-action")
  end

  test "lists Pool invites and links from the sidebar under operators", %{
    conn: conn,
    scope: scope
  } do
    pool = pool_fixture(%{slug: "invites-live", name: "Invites Live"})
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{
        invited_email: "row@example.com",
        expires_at: expires_at
      })

    invite =
      invite
      |> Invite.changeset(%{email_sent_at: DateTime.utc_now()})
      |> Repo.update!()

    {:ok, view, html} = live(conn, ~p"/admin/invites")

    assert has_element?(view, "#admin-invites-live")
    assert has_element?(view, "#invite-page-create-action", "Create Pool invite")
    assert has_element?(view, "#admin-nav-invites[aria-current='page'][href='/admin/invites']")
    assert :binary.match(html, "admin-nav-operators") < :binary.match(html, "admin-nav-invites")

    assert :binary.match(html, "admin-nav-invites") <
             :binary.match(html, "admin-nav-request-logs")

    assert has_element?(view, "#invite-row-#{invite.id}")
    assert has_element?(view, "#invite-row-#{invite.id}", "Invites Live")
    refute has_element?(view, "#invite-row-#{invite.id}", "invites-live")

    assert has_element?(
             view,
             "#invite-row-#{invite.id}",
             "in 1 hour"
           )

    refute has_element?(view, "#invite-row-#{invite.id}", "Expires")
    assert has_element?(view, "#invite-row-#{invite.id}", "row@example.com")
    assert has_element?(view, "#invite-email-sent-#{invite.id}[aria-label='Invite email sent']")
    assert has_element?(view, "#invite-status-#{invite.id}", "active")
    assert html =~ "rounded-full border border-success/20 bg-success/10"
    assert has_element?(view, "#invite-table thead th:nth-child(8).text-center", "Expires")
    assert has_element?(view, "#invite-expires-#{invite.id}.text-center", "in 1 hour")
    assert has_element?(view, "#invite-actions-menu-#{invite.id}")
    assert has_element?(view, "#invite-reissue-#{invite.id}", "Reissue")
    assert has_element?(view, "#invite-revoke-open-#{invite.id}", "Revoke")
    refute has_element?(view, "#invite-revoke-#{invite.id}")
  end

  test "renders the invite creation surface on the invites page", %{
    conn: conn
  } do
    pool = pool_fixture(%{slug: "admin-invites", name: "Admin Invites"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    open_invite_dialog(view)

    assert has_element?(view, "#pool-invite-dialog[open]")
    assert has_element?(view, "#pool-invite-form")
    assert_admin_dialog_docs_link(view, "pool-invite-dialog-footer")

    assert has_element?(
             view,
             "#pool-invite-dialog",
             "Create a one-time invite link for a Codex account and assign it to a Pool."
           )

    assert has_element?(view, "#pool-invite-submit")
    assert has_element?(view, "#invite_pool_id")

    assert has_element?(
             view,
             "#invite_pool_id option[value='#{pool.id}']",
             "Admin Invites"
           )

    invite_pool_select_html = view |> element("#invite_pool_id") |> render()
    refute invite_pool_select_html =~ "admin-invites"
    assert has_element?(view, "#invite_invited_email")
    assert has_element?(view, "label[for='invite_invited_email']", "Codex Account Email")
    assert has_element?(view, "#invite_send_email")
    assert has_element?(view, "#pool-invite-submit[disabled]")

    view
    |> element("#pool-invite-form")
    |> render_change(%{
      "invite" => %{
        "pool_id" => pool.id,
        "invited_email" => "valid.codex@example.com",
        "send_email" => "false"
      }
    })

    assert has_element?(view, "#pool-invite-submit:not([disabled])")
  end

  test "bare create query opens the invite dialog without immediate validation errors", %{
    conn: conn
  } do
    pool_fixture(%{slug: "bare-create-target", name: "Bare Create Target"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites?create=1")

    assert has_element?(view, "#pool-invite-dialog[open]")
    assert has_element?(view, "#pool-invite-form")
    assert has_element?(view, "#pool-invite-submit[disabled]")
    refute has_element?(view, "#pool-invite-form", "can't be blank")
    refute has_element?(view, "#pool-invite-form", "must be an active Pool")
  end

  @tag :invite_prefill_valid
  test "query params open the invite creation dialog with a valid prefill", %{
    conn: conn,
    scope: scope
  } do
    pool = pool_fixture(%{slug: "prefill-target", name: "Prefill Target"})
    other_pool = pool_fixture(%{slug: "prefill-other", name: "Prefill Other"})

    {:ok, %{invite: target_invite}} =
      Access.create_invite(scope, pool, %{invited_email: "target@example.com"})

    {:ok, %{invite: other_invite}} =
      Access.create_invite(scope, other_pool, %{invited_email: "other@example.com"})

    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/invites?create=1&pool_id=#{pool.id}&invited_email=user@example.com"
      )

    assert has_element?(view, "#pool-invite-dialog[open]")
    assert has_element?(view, "#pool-invite-form")
    assert has_element?(view, "#invite_pool_id")

    assert has_element?(
             view,
             "#invite_pool_id option[value='#{pool.id}'][selected]",
             "Prefill Target"
           )

    assert has_element?(view, "#invite_invited_email[value='user@example.com']")
    assert has_element?(view, "#invite_send_email")
    assert has_element?(view, "#pool-invite-submit:not([disabled])")
    assert has_element?(view, "#filters_pool_id[type='hidden'][value='']")
    assert has_element?(view, "#invite-row-#{target_invite.id}")
    assert has_element?(view, "#invite-row-#{other_invite.id}")
    refute has_element?(view, "#invite-url")
    assert Repo.aggregate(Invite, :count) == 2
    assert_no_email_sent()
  end

  @tag :invite_prefill_invalid
  test "query params reject invalid pool and invalid email without selecting a filter", %{
    conn: conn,
    scope: scope
  } do
    pool = pool_fixture(%{slug: "invalid-prefill-target", name: "Invalid Prefill Target"})
    other_pool = pool_fixture(%{slug: "invalid-prefill-other", name: "Invalid Prefill Other"})

    {:ok, %{invite: active_invite}} =
      Access.create_invite(scope, pool, %{invited_email: "active-prefill@example.com"})

    {:ok, %{invite: revoked_invite}} =
      Access.create_invite(scope, other_pool, %{invited_email: "revoked-prefill@example.com"})

    {:ok, _revoked} = Access.revoke_invite(scope, revoked_invite.id)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/invites?create=1&pool_id=#{Ecto.UUID.generate()}&invited_email=not-an-email&send_email=maybe&status=revoked"
      )

    assert has_element?(view, "#pool-invite-dialog[open]")
    assert has_element?(view, "#pool-invite-form")
    assert has_element?(view, "#invite_pool_id")
    refute has_element?(view, "#invite_pool_id option[selected]")
    assert has_element?(view, "#invite_invited_email[value='not-an-email']")
    assert has_element?(view, "#invite_send_email")
    assert has_element?(view, "#pool-invite-submit[disabled]")
    assert has_element?(view, "#filters_pool_id[type='hidden'][value='']")
    assert has_element?(view, "#filters_status[type='hidden'][value='revoked']")
    assert has_element?(view, "#invite-row-#{revoked_invite.id}")
    refute has_element?(view, "#invite-row-#{active_invite.id}")
    refute has_element?(view, "#invite-url")
    assert Repo.aggregate(Invite, :count) == 2
    assert_no_email_sent()
  end

  @tag :invite_prefill_invalid
  test "query params keep the invite dialog open when invited email is blank", %{
    conn: conn
  } do
    pool = pool_fixture(%{slug: "blank-prefill-target", name: "Blank Prefill Target"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites?create=1&pool_id=#{pool.id}")

    assert has_element?(view, "#pool-invite-dialog[open]")
    assert has_element?(view, "#pool-invite-form")

    assert has_element?(
             view,
             "#invite_pool_id option[value='#{pool.id}'][selected]",
             "Blank Prefill Target"
           )

    assert has_element?(view, "#invite_invited_email[value='']")
    assert has_element?(view, "#invite_send_email")
    assert has_element?(view, "#pool-invite-submit[disabled]")
    refute has_element?(view, "#pool-invite-form", "can't be blank")
    refute has_element?(view, "#invite-url")
    assert Repo.aggregate(Invite, :count) == 0
    assert_no_email_sent()
  end

  test "creates a pool-scoped onboarding invite from admin invites", %{
    conn: conn,
    scope: scope
  } do
    pool = pool_fixture(%{slug: "example-pool", name: "Example Pool"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    open_invite_dialog(view)

    html =
      view
      |> element("#pool-invite-form")
      |> render_submit(%{
        "invite" => %{
          "pool_id" => pool.id,
          "invited_email" => "Invitee@Example.COM",
          "send_email" => "true"
        }
      })

    assert has_element?(view, "#pool-onboarding-invite-ready", "Pool onboarding invite ready")
    assert has_element?(view, "#pool-invite-created")
    assert has_element?(view, "#pool-invite-target", "Example Pool")
    refute has_element?(view, "#pool-invite-target", "example-pool")
    assert has_element?(view, "#pool-invite-email-status", "Email sent to invitee@example.com")
    assert has_element?(view, "#invite-url", "/onboarding/invites/")
    assert has_element?(view, "#invite-url.truncate.whitespace-nowrap")
    assert has_element?(view, "#pool-invite-url-control.min-w-0.max-w-full")
    assert has_element?(view, "#invite-url.min-w-0.flex-1")
    assert has_element?(view, "#pool-invite-copy-url.shrink-0")
    assert has_element?(view, "#pool-invite-copy-url[phx-hook='ClipboardCopy']", "Copy")
    assert has_element?(view, "#pool-invite-copy-url[data-copy-label='Copy']")
    assert has_element?(view, "#pool-invite-copy-url[data-copied-label='Copied']")
    assert has_element?(view, "#pool-invite-copy-url [data-copy-label]", "Copy")
    assert_admin_dialog_docs_link(view, "pool-invite-ready-dialog-footer")

    raw_token = invite_token_from_html!(html)
    invite = Repo.one!(Invite)

    assert invite.pool_id == pool.id
    assert invite.invited_email == "invitee@example.com"
    assert invite.token_hash == Access.hash_invite_token(raw_token)
    assert invite.email_sent_at
    refute inspect(invite) =~ raw_token

    assert [event] = audit_events("invite.create", invite.id)
    assert event.actor_user_id == scope.user.id
    assert event.pool_id == pool.id
    assert event.target_type == "invite"
    assert event.details["invite_id"] == invite.id
    assert event.details["pool_id"] == pool.id
    assert event.details["invited_email"] == "invitee@example.com"
    assert event.details["status"] == "active"
    refute inspect(event) =~ raw_token
    refute inspect(event) =~ invite.token_hash

    assert has_element?(view, "#invite-row-#{invite.id}", "invitee@example.com")
    assert render(view) =~ raw_token

    assert_email_sent(fn email ->
      assert email.to == [{"", "invitee@example.com"}]
      assert email.subject == "Codex Pooler Pool invite"

      assert email.text_body =~
               "#{scope.user.display_name} invited you to connect an OpenAI account to Example Pool."

      assert email.text_body =~ "Accept invite: "
      assert email.text_body =~ "/onboarding/invites/#{raw_token}"
      assert email.text_body =~ "What happens next:"
      assert email.html_body =~ "Pool invite for Example Pool"
      assert email.html_body =~ "Accept invite"
      true
    end)
  end

  test "renders raw invite URL only for the create result", %{conn: conn} do
    pool = pool_fixture(%{slug: "transient-invite", name: "Transient Invite"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    open_invite_dialog(view)

    html =
      view
      |> element("#pool-invite-form")
      |> render_submit(%{
        "invite" => %{
          "pool_id" => pool.id,
          "invited_email" => "transient@example.com"
        }
      })

    raw_token = invite_token_from_html!(html)
    assert has_element?(view, "#invite-url", raw_token)

    {:ok, _remounted_view, remounted_html} = live(conn, ~p"/admin/invites")
    refute remounted_html =~ raw_token
    refute remounted_html =~ "/onboarding/invites/#{raw_token}"
    refute remounted_html =~ "id=\"invite-url\""
  end

  test "invalid pool invite submission is controlled and creates no invite", %{
    conn: conn
  } do
    _pool = pool_fixture(%{slug: "invite-validation", name: "Invite Validation"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    open_invite_dialog(view)

    view
    |> element("#pool-invite-form")
    |> render_submit(%{
      "invite" => %{
        "pool_id" => Ecto.UUID.generate(),
        "invited_email" => "denied@example.com"
      }
    })

    assert has_element?(view, "#pool-invite-form")
    refute has_element?(view, "#invite-url")
    assert Repo.aggregate(Invite, :count) == 0

    assert Repo.aggregate(
             from(event in AuditEvent, where: event.action == "invite.create"),
             :count
           ) ==
             0

    assert render(view) =~ "Select an active Pool before creating an invite"
  end

  test "send invite email requires an invited email before creating the invite", %{
    conn: conn
  } do
    pool = pool_fixture(%{slug: "invite-email-required", name: "Invite Email Required"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    open_invite_dialog(view)

    view
    |> element("#pool-invite-form")
    |> render_submit(%{
      "invite" => %{
        "pool_id" => pool.id,
        "invited_email" => "",
        "send_email" => "true"
      }
    })

    assert has_element?(view, "#pool-invite-dialog[open]")
    assert has_element?(view, "#invite_invited_email")
    assert render(view) =~ "Pool invite could not be created"
    assert has_element?(view, "#pool-invite-submit[disabled]")
    assert Repo.aggregate(Invite, :count) == 0
    assert_no_email_sent()
  end

  test "disables invite email delivery when SMTP is unavailable", %{
    conn: conn
  } do
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Local)
    Application.put_env(:swoosh, :local, false)

    pool =
      pool_fixture(%{
        slug: "invite-email-unavailable",
        name: "Invite Email Unavailable"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    assert has_element?(
             view,
             "#invite-pool-filter button[data-pool-id='#{pool.id}']",
             "Bridge ring"
           )

    assert has_element?(
             view,
             "#invite-pool-filter button[data-pool-id='#{pool.id}'] [data-role='pool-filter-icon'].text-success"
           )

    open_invite_dialog(view)

    assert has_element?(view, "#invite_send_email[disabled]")

    assert has_element?(
             view,
             "#pool-invite-email-unavailable",
             "Email delivery is unavailable until SMTP is configured."
           )
  end

  test "filters by status and pool", %{conn: conn, scope: scope} do
    first_pool = pool_fixture(%{slug: "first-invites", name: "First Invites"})
    second_pool = pool_fixture(%{slug: "second-invites", name: "Second Invites"})

    {:ok, %{invite: first}} =
      Access.create_invite(scope, first_pool, %{invited_email: "first@example.com"})

    {:ok, %{invite: second}} =
      Access.create_invite(scope, second_pool, %{invited_email: "second@example.com"})

    {:ok, _revoked} = Access.revoke_invite(scope, second.id)

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    view
    |> element("#invite-status-filter [data-role='status-filter-option'][data-status='revoked']")
    |> render_click()

    assert_patch(view, ~p"/admin/invites?status=revoked")
    assert has_element?(view, "#invite-row-#{second.id}")
    refute has_element?(view, "#invite-row-#{first.id}")

    view
    |> element(
      "#invite-pool-filter [data-role='pool-filter-option'][data-pool-id='#{first_pool.id}']"
    )
    |> render_click()

    assert_patch(view, ~p"/admin/invites?pool_id=#{first_pool.id}&status=revoked")
    refute has_element?(view, "#invite-row-#{first.id}")
    refute has_element?(view, "#invite-row-#{second.id}")
  end

  test "revokes active invites from the confirmation dialog", %{conn: conn, scope: scope} do
    pool = pool_fixture(%{slug: "revoke-live", name: "Revoke Live"})

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "revoke@example.com"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    view
    |> element("#invite-revoke-open-#{invite.id}")
    |> render_click()

    assert has_element?(view, "#invite-revoke-dialog[open]", "Revoke Pool invite")
    assert has_element?(view, "#invite-revoke-dialog", "revoke@example.com")
    assert_admin_dialog_docs_link(view, "invite-revoke-dialog-footer")

    view
    |> element("#invite-revoke-confirm")
    |> render_click()

    assert has_element?(view, "#invite-status-#{invite.id}", "revoked")
    refute has_element?(view, "#invite-revoke-open-#{invite.id}")
    assert Repo.get_by(AuditEvent, action: "invite.revoke", target_id: invite.id)
  end

  test "reissues active invites from the row action menu", %{conn: conn, scope: scope} do
    pool = pool_fixture(%{slug: "reissue-live", name: "Reissue Live"})

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "reissue@example.com"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    view
    |> element("#invite-reissue-#{invite.id}")
    |> render_click()

    reloaded_invite = Repo.reload!(invite)

    replacement =
      Repo.get_by!(Invite,
        pool_id: pool.id,
        invited_email: "reissue@example.com",
        status: "active"
      )

    assert reloaded_invite.status == "revoked"
    assert replacement.id != invite.id
    assert has_element?(view, "#invite-row-#{replacement.id}", "reissue@example.com")

    assert has_element?(
             view,
             "#invite-email-sent-#{replacement.id}[aria-label='Invite email sent']"
           )

    assert_email_sent(fn email ->
      assert email.to == [{"", "reissue@example.com"}]
      assert email.text_body =~ "/onboarding/invites/"
      true
    end)
  end

  test "reloads when an invite changes for a visible pool", %{conn: conn, scope: scope} do
    pool = pool_fixture(%{slug: "live-sync", name: "Live Sync"})

    {:ok, view, _html} = live(conn, ~p"/admin/invites")

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "synced@example.com"})

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#invite-row-#{invite.id}", "synced@example.com")
  end

  defp owner_session(%{conn: conn}) do
    %{user: user, token: token} = CodexPooler.AccountsFixtures.bootstrap_owner_fixture()
    {:ok, conn: log_in_user(conn, user, token), scope: Scope.for_user(user, ["instance_owner"])}
  end

  defp open_invite_dialog(view) do
    view
    |> element("#invite-page-create-action")
    |> render_click()
  end

  defp assert_admin_dialog_docs_link(view, footer_id) do
    assert has_element?(
             view,
             "##{footer_id} [data-role='admin-dialog-docs-link'][href='https://docs.codex-pooler.com'][target='_blank'][rel='noopener noreferrer'].text-xs",
             "Docs"
           )

    assert has_element?(
             view,
             "##{footer_id}-docs-link [data-role='admin-dialog-docs-icon']"
           )
  end

  defp invite_token_from_html!(html) do
    case Regex.run(~r{/onboarding/invites/([A-Za-z0-9_-]+)}, html) do
      [_path, token] -> token
      _match -> flunk("raw invite token was not rendered in the one-time invite URL")
    end
  end

  defp audit_events(action, target_id) do
    Repo.all(
      from(event in AuditEvent,
        where: event.action == ^action and event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
      )
    )
  end
end
