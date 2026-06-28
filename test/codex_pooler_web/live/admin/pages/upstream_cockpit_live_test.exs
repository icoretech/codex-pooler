defmodule CodexPoolerWeb.Admin.UpstreamCockpitLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.FakeOpenAIAuthProvider
  alias CodexPooler.Jobs.SavedResetRedemptionWorker
  alias CodexPooler.Pools
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, OAuthFlow, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel
  alias CodexPoolerWeb.DateTimeDisplay

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  @tag :route_navigation
  test "renders cockpit root selectors for a visible upstream identity", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "cockpit-route", name: "Cockpit Route"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{account_label: "Route Contract Codex"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#upstream-cockpit")
    assert has_element?(view, "#upstream-cockpit-header")
    assert has_element?(view, "#upstream-refresh-data")
  end

  test "cockpit uses current identity label and quota readiness for shared assignments", %{
    conn: conn,
    scope: scope
  } do
    {:ok, source_pool} =
      Pools.create_pool(scope, %{slug: "shared-stale-source", name: "Shared Stale Source"})

    {:ok, target_pool} =
      Pools.create_pool(scope, %{slug: "shared-stale-target", name: "Shared Stale Target"})

    %{identity: identity, assignment: stale_assignment} =
      upstream_assignment_fixture(source_pool, %{
        account_label: "Current Shared Codex",
        assignment_label: "old-shared-label@example.com",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "failed",
            "reason" => %{
              "code" => "quota_refresh_auth_unavailable",
              "message" => "old local failure"
            }
          }
        }
      })

    assert {:ok, fresh_assignment} =
             PoolAssignments.create_pool_assignment(target_pool, identity, %{
               assignment_label: "another-old-shared-label@example.com",
               status: "active",
               health_status: "active",
               eligibility_status: "eligible",
               metadata: %{"quota_priming" => %{"status" => "known"}}
             })

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 75,
      used_percent: Decimal.new("25"),
      reset_at: DateTime.add(DateTime.utc_now(), 4, :hour)
    })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    assignments_by_id = Map.new(cockpit.assignments.items, &{&1.id, &1})

    assert Map.fetch!(assignments_by_id, stale_assignment.id).assignment_label ==
             "Current Shared Codex"

    assert Map.fetch!(assignments_by_id, stale_assignment.id).quota_priming_status == "known"
    assert Map.fetch!(assignments_by_id, stale_assignment.id).quota_priming_label == "Quota known"

    assert Map.fetch!(assignments_by_id, fresh_assignment.id).assignment_label ==
             "Current Shared Codex"

    assert cockpit.charts.quota_health.kpis.assignment_count == 2
    assert cockpit.charts.quota_health.kpis.routing_usable_count == 2

    {:ok, view, html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    stale_selector = "#upstream-assignment-#{stale_assignment.id}"

    assert has_element?(view, stale_selector, "Current Shared Codex")
    assert has_element?(view, stale_selector, "Quota known")
    assert has_element?(view, stale_selector, "Quota fresh")

    refute html =~ "old-shared-label@example.com"
    refute html =~ "another-old-shared-label@example.com"
  end

  @tag :route_navigation
  test "upstream index links to cockpit with the upstream identity id", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "cockpit-link", name: "Cockpit Link"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{account_label: "Linked Codex"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-mail[href='/admin/upstreams/#{identity.id}']",
             "Linked Codex"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-mail[href='/admin/upstreams/#{assignment.id}']"
           )
  end

  test "cockpit read model exposes safe OAuth relink summaries without transient secrets", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "cockpit-oauth-flows", name: "Cockpit OAuth Flows"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{account_label: "Cockpit OAuth Account"})

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool,
               upstream_identity: identity,
               metadata: %{"source" => "admin_cockpit_test"}
             )

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    assert cockpit.oauth_flows.count == 1

    summary = hd(cockpit.oauth_flows.items)
    assert summary.id == flow.id
    assert summary.flow_kind == "browser"
    assert summary.purpose == "relink"
    assert summary.status == "pending"
    assert summary.status_label == "Browser authorization pending"
    assert summary.authorization_url == nil
    assert summary.upstream_identity_id == identity.id

    refute Map.has_key?(summary, :state_token_hash)
    refute Map.has_key?(summary, :code_verifier_ciphertext)
    refute inspect(cockpit.oauth_flows) =~ authorization_url
    refute inspect(cockpit.oauth_flows) =~ "admin_cockpit_test"
    refute inspect(cockpit.oauth_flows) =~ "code_verifier"

    {:ok, view, html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    assert has_element?(view, "#upstream-cockpit-oauth-flow-state")

    assert has_element?(
             view,
             "#upstream-cockpit-oauth-flow-#{flow.id}",
             "Browser authorization pending"
           )

    assert has_element?(view, "#upstream-cockpit-oauth-flow-#{flow.id}", "relink")
    refute html =~ authorization_url
    refute html =~ "admin_cockpit_test"
    refute html =~ "code_verifier"
  end

  test "relinks cockpit account through browser OAuth dialog without rendering token secrets", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "cockpit-oauth-browser-ui", name: "Cockpit OAuth Browser"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Cockpit Browser OAuth",
        chatgpt_account_id: "acct_cockpit_browser_ui",
        workspace_id: "workspace-cockpit-ui",
        workspace_label: "Cockpit Workspace"
      })

    access_token = runtime_secret("cockpit-oauth-browser-access")
    refresh_token = runtime_secret("cockpit-oauth-browser-refresh")
    id_token = oauth_id_token("acct_cockpit_browser_ui", "workspace-cockpit-ui")

    provider =
      start_oauth_provider!(%{
        "/oauth/token" =>
          {200,
           FakeOpenAIAuthProvider.token_response(
             access_token: access_token,
             refresh_token: refresh_token,
             id_token: id_token
           )}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    open_oauth_relink_dialog(view, identity.id)
    assert has_element?(view, "#oauth-relink-dialog")
    assert_oauth_dialog_docs_link(view, "oauth-relink-dialog-footer")
    assert has_element?(view, "#oauth-relink-browser-start")
    assert has_element?(view, "#oauth-relink-device-start")

    view
    |> element("#oauth-relink-browser-start")
    |> render_click()

    assert has_element?(view, "#oauth-relink-authorization-url")
    assert has_element?(view, "#oauth-relink-callback-url")
    assert has_element?(view, "#oauth-relink-submit-callback")

    authorization_url = oauth_relink_authorization_url_from_view(view)
    callback_url = callback_url(authorization_state(authorization_url), "cockpit-browser-code")

    view
    |> element("#oauth-relink-callback-form")
    |> render_submit(%{"oauth_relink" => %{"callback_url" => callback_url}})

    assert has_element?(view, "#oauth-relink-status", "OpenAI account relinked")
    assert has_element?(view, "#oauth-relink-cancel", "Close")
    assert Repo.aggregate(UpstreamIdentity, :count) == 1

    reloaded = Repo.get!(UpstreamIdentity, identity.id)
    assert reloaded.chatgpt_account_id == "acct_cockpit_browser_ui"
    assert reloaded.status == "active"
    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1

    assert [token_request] = FakeOpenAIAuthProvider.requests(provider)

    assert FakeOpenAIAuthProvider.decode_form_request(token_request)["code"] ==
             "cockpit-browser-code"

    html = render(view)

    for raw_value <- [access_token, refresh_token, id_token, callback_url, "cockpit-browser-code"] do
      refute html =~ raw_value
    end
  end

  test "relinks cockpit account through device OAuth polling without rendering provider secrets",
       %{
         conn: conn,
         scope: scope
       } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "cockpit-oauth-device-ui", name: "Cockpit OAuth Device"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Cockpit Device OAuth",
        chatgpt_account_id: "acct_cockpit_device_ui",
        workspace_id: "workspace-cockpit-ui",
        workspace_label: "Cockpit Workspace"
      })

    device_auth_id = runtime_secret("cockpit-oauth-device-auth-id")
    authorization_code = runtime_secret("cockpit-oauth-device-authorization-code")
    code_verifier = runtime_secret("cockpit-oauth-device-code-verifier")
    access_token = runtime_secret("cockpit-oauth-device-access")
    refresh_token = runtime_secret("cockpit-oauth-device-refresh")
    id_token = oauth_id_token("acct_cockpit_device_ui", "workspace-cockpit-ui")

    provider =
      start_oauth_provider!(
        device_routes(%{
          "/api/accounts/deviceauth/usercode" =>
            {200,
             FakeOpenAIAuthProvider.device_code_response(
               device_auth_id: device_auth_id,
               user_code: "COCKPIT-CODE",
               interval: 5,
               expires_at: DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.to_iso8601()
             )},
          "/api/accounts/deviceauth/token" =>
            {200,
             FakeOpenAIAuthProvider.authorization_code_response(
               authorization_code: authorization_code,
               code_verifier: code_verifier
             )},
          "/oauth/token" =>
            {200,
             FakeOpenAIAuthProvider.token_response(
               access_token: access_token,
               refresh_token: refresh_token,
               id_token: id_token
             )}
        })
      )

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    open_oauth_relink_dialog(view, identity.id)

    view
    |> element("#oauth-relink-device-start")
    |> render_click()

    assert has_element?(view, "#oauth-relink-device-code", "COCKPIT-CODE")

    assert has_element?(
             view,
             "#oauth-relink-device-code",
             FakeOpenAIAuthProvider.url(provider) <> "/codex/device"
           )

    flow = Repo.one!(OAuthFlow)
    send(view.pid, {:poll_oauth_relink_device, flow.id})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#oauth-relink-status", "OpenAI account relinked")
    assert has_element?(view, "#oauth-relink-cancel", "Close")
    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1

    html = render(view)

    for raw_value <- [
          device_auth_id,
          authorization_code,
          code_verifier,
          access_token,
          refresh_token,
          id_token
        ] do
      refute html =~ raw_value
    end
  end

  test "cockpit OAuth relink rejects mismatched identity claims safely", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "cockpit-oauth-mismatch", name: "Cockpit OAuth Mismatch"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Cockpit Mismatch OAuth",
        chatgpt_account_id: "acct_cockpit_mismatch_target",
        workspace_id: "workspace-cockpit-ui"
      })

    access_token = runtime_secret("cockpit-oauth-mismatch-access")
    refresh_token = runtime_secret("cockpit-oauth-mismatch-refresh")
    id_token = oauth_id_token("acct_cockpit_mismatch_other", "workspace-cockpit-ui")

    start_oauth_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: access_token,
           refresh_token: refresh_token,
           id_token: id_token
         )}
    })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    open_oauth_relink_dialog(view, identity.id)

    view
    |> element("#oauth-relink-browser-start")
    |> render_click()

    authorization_url = oauth_relink_authorization_url_from_view(view)
    callback_url = callback_url(authorization_state(authorization_url), "cockpit-mismatch-code")

    view
    |> element("#oauth-relink-callback-form")
    |> render_submit(%{"oauth_relink" => %{"callback_url" => callback_url}})

    assert has_element?(
             view,
             "#oauth-relink-error",
             "OAuth account does not match the selected upstream account"
           )

    assert Repo.get!(UpstreamIdentity, identity.id).chatgpt_account_id ==
             "acct_cockpit_mismatch_target"

    assert active_secret_count("access_token") == 0
    assert active_secret_count("refresh_token") == 0
    assert Repo.one!(OAuthFlow).status == "failed"

    html = render(view)

    for raw_value <- [
          access_token,
          refresh_token,
          id_token,
          callback_url,
          "cockpit-mismatch-code"
        ] do
      refute html =~ raw_value
    end
  end

  test "cockpit OAuth relink cancel marks pending flow cancelled and closes the dialog", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "cockpit-oauth-cancel", name: "Cockpit OAuth Cancel"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Cockpit Cancel OAuth",
        chatgpt_account_id: "acct_cockpit_cancel",
        workspace_id: "workspace-cockpit-ui"
      })

    start_oauth_provider!(%{"/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    open_oauth_relink_dialog(view, identity.id)

    view
    |> element("#oauth-relink-browser-start")
    |> render_click()

    flow = Repo.one!(OAuthFlow)
    assert has_element?(view, "#oauth-relink-cancel", "Cancel")

    view
    |> element("#oauth-relink-cancel")
    |> render_click()

    assert Repo.get!(OAuthFlow, flow.id).status == "cancelled"
    refute has_element?(view, "#oauth-relink-dialog")
    assert active_secret_count("access_token") == 0
    assert active_secret_count("refresh_token") == 0
  end

  test "cockpit OAuth relink reports expired browser flow without linking secrets", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "cockpit-oauth-expired", name: "Cockpit OAuth Expired"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Cockpit Expired OAuth",
        chatgpt_account_id: "acct_cockpit_expired",
        workspace_id: "workspace-cockpit-ui"
      })

    access_token = runtime_secret("cockpit-oauth-expired-access")
    refresh_token = runtime_secret("cockpit-oauth-expired-refresh")
    id_token = oauth_id_token("acct_cockpit_expired", "workspace-cockpit-ui")

    start_oauth_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: access_token,
           refresh_token: refresh_token,
           id_token: id_token
         )}
    })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    open_oauth_relink_dialog(view, identity.id)

    view
    |> element("#oauth-relink-browser-start")
    |> render_click()

    authorization_url = oauth_relink_authorization_url_from_view(view)
    flow = Repo.one!(OAuthFlow)

    flow
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    callback_url = callback_url(authorization_state(authorization_url), "cockpit-expired-code")

    view
    |> element("#oauth-relink-callback-form")
    |> render_submit(%{"oauth_relink" => %{"callback_url" => callback_url}})

    assert has_element?(view, "#oauth-relink-error", "OAuth flow has expired")
    assert Repo.get!(OAuthFlow, flow.id).status == "expired"
    assert active_secret_count("access_token") == 0
    assert active_secret_count("refresh_token") == 0

    html = render(view)

    for raw_value <- [access_token, refresh_token, id_token, callback_url, "cockpit-expired-code"] do
      refute html =~ raw_value
    end
  end

  @tag :auth_not_found
  test "redirects unauthenticated cockpit access through the existing admin auth flow" do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(build_conn(), ~p"/admin/upstreams/#{Ecto.UUID.generate()}")
  end

  @tag :auth_not_found
  test "unknown upstream identity redirects safely without rendering secret-like data", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "cockpit-missing", name: "Cockpit Missing"})
    %{identity: identity} = upstream_assignment_fixture(pool)
    secret_value = runtime_secret("cockpit-missing")

    {:ok, _secret} =
      Upstreams.store_encrypted_secret(identity, %{
        secret_kind: "access_token",
        plaintext: secret_value
      })

    conn = get(conn, ~p"/admin/upstreams/#{Ecto.UUID.generate()}")

    assert redirected_to(conn) == "/admin/upstreams"
    refute conn.resp_body =~ secret_value
  end

  @tag :layout_sections
  test "renders ordered cockpit shell sections with stable selectors", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "layout-shell", name: "Layout Shell"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    raw_stored_account_id = "layout-shell-account-#{System.unique_integer([:positive])}"

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Layout Shell Codex",
        chatgpt_account_id: raw_stored_account_id,
        plan_label: "Team",
        assignment_label: "Layout Shell assignment",
        assignment_metadata: %{"quota_priming" => %{"status" => "known"}}
      })

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 72,
      used_percent: Decimal.new("28"),
      reset_at: DateTime.add(now, 4, :hour),
      observed_at: now
    })

    request_health_request_fixture(pool, assignment, %{
      status: "succeeded",
      admitted_at: DateTime.add(now, -2, :hour),
      correlation_id: "layout-shell-success"
    })

    assert {:ok, _audit_event} =
             Audit.record_user_event(user, %{
               pool_id: pool.id,
               action: "upstream_account.refresh_enqueue",
               target_type: "upstream_identity",
               target_id: identity.id,
               occurred_at: DateTime.add(now, -1, :minute),
               details: %{"safe" => "layout-shell-audit"}
             })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    for selector <- [
          "#upstream-cockpit",
          "#upstream-cockpit-header",
          "#upstream-status-summary",
          "#upstream-assignments",
          "#quota-health-chart",
          "#request-health-chart",
          "#pool-contribution-chart",
          "#upstream-event-summary",
          "#upstream-actions",
          "#upstream-related-links",
          "#upstream-refresh-data"
        ] do
      assert has_element?(view, selector)
    end

    assert has_element?(view, "#upstream-cockpit-header", "Layout Shell Codex")
    assert has_element?(view, "#upstream-cockpit-header", "stored account id sha256:")
    assert has_element?(view, "#upstream-status-summary", "Identity active")
    assert has_element?(view, "#upstream-assignments", "1 assignment")
    assert has_element?(view, "#quota-health-chart", "Quota health")
    assert has_element?(view, "#request-health-chart", "Request health")
    assert has_element?(view, "#pool-contribution-chart", "Pool contribution")
    assert has_element?(view, "#upstream-event-summary", "Recent events")
    assert has_element?(view, "#upstream-actions", "Available actions")
    assert has_element?(view, "#upstream-refresh-data", "Refresh cockpit data")

    assert has_element?(
             view,
             "#upstream-related-links a[href='/admin/request-logs?upstream_identity_id=#{identity.id}']"
           )

    assert has_element?(
             view,
             "#upstream-related-links a[href='/admin/audit-logs?target=#{identity.id}']"
           )

    rendered = render(view)

    assert_ordered_ids(rendered, [
      "upstream-cockpit-header",
      "upstream-status-summary",
      "upstream-assignments",
      "quota-health-chart",
      "request-health-chart",
      "pool-contribution-chart",
      "upstream-event-summary",
      "upstream-actions",
      "upstream-related-links"
    ])

    refute rendered =~ raw_stored_account_id
  end

  @tag :layout_empty_states
  test "renders sparse cockpit section shells with explicit empty and degraded copy", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "layout-sparse", name: "Layout Sparse"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Sparse Layout Codex",
        assignment_label: "Sparse Layout assignment"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    for selector <- [
          "#upstream-cockpit",
          "#upstream-cockpit-header",
          "#upstream-status-summary",
          "#upstream-assignments",
          "#quota-health-chart",
          "#request-health-chart",
          "#pool-contribution-chart",
          "#upstream-event-summary",
          "#upstream-actions",
          "#upstream-related-links",
          "#upstream-refresh-data"
        ] do
      assert has_element?(view, selector)
    end

    assert has_element?(view, "#upstream-status-summary", "Quota evidence is missing")
    assert has_element?(view, "#upstream-assignments", "1 assignment")

    assert has_element?(
             view,
             "#quota-health-chart",
             "Quota evidence is missing for this upstream assignment."
           )

    assert has_element?(
             view,
             "#request-health-chart",
             "No request traffic has reached this upstream in the last 7 days."
           )

    assert has_element?(
             view,
             "#pool-contribution-chart",
             "No successful request contribution is recorded for assigned Pools in the last 7 days."
           )

    assert has_element?(view, "#upstream-event-summary", "No recent upstream events")

    assert has_element?(
             view,
             "#upstream-actions",
             "Bounded operator actions reuse the upstream account workflows"
           )

    assert has_element?(
             view,
             "#upstream-actions",
             "Assignment and Pool changes stay on linked admin pages"
           )

    assert has_element?(
             view,
             "#upstream-related-links",
             "Use linked admin pages for full request and audit evidence."
           )
  end

  @tag :status_assignments
  test "renders status summary and mixed assignment operational context", %{
    conn: conn,
    scope: scope
  } do
    {:ok, primary_pool} =
      Pools.create_pool(scope, %{
        slug: "status-primary",
        name: "Status Primary"
      })

    {:ok, secondary_pool} =
      Pools.create_pool(scope, %{
        slug: "status-secondary",
        name: "Status Secondary"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{identity: identity, assignment: primary_assignment} =
      upstream_assignment_fixture(primary_pool, %{
        account_label: "Status Mixed Codex",
        chatgpt_account_id: "status-mixed-#{System.unique_integer([:positive])}@example.com",
        plan_label: "Team",
        assignment_label: "Primary assignment serving production traffic",
        assignment_metadata: %{"quota_priming" => %{"status" => "known"}},
        identity_metadata: %{
          "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now, 2, :hour)),
          "token_refresh" => %{
            "status" => "succeeded",
            "finished_at" => DateTime.to_iso8601(DateTime.add(now, -15, :minute))
          }
        }
      })

    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        auth_fresh_at: DateTime.add(now, -4, :hour),
        auth_verified_at: DateTime.add(now, -3, :hour)
      })
      |> Repo.update!()

    primary_assignment
    |> Ecto.Changeset.change(%{last_successful_refresh_at: ~U[2026-05-27 08:15:00.000000Z]})
    |> Repo.update!()

    assert {:ok, disabled_assignment} =
             PoolAssignments.create_pool_assignment(secondary_pool, identity, %{
               assignment_label: "Disabled failover assignment",
               status: "disabled",
               health_status: "disabled",
               eligibility_status: "ineligible",
               metadata: %{"quota_priming" => %{"status" => "blocked"}}
             })

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 40,
      used_percent: Decimal.new("60"),
      reset_at: DateTime.add(now, 4, :hour),
      observed_at: now
    })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#upstream-status-summary", "Identity active")
    assert has_element?(view, "#upstream-status-summary", "Plan Team")
    assert has_element?(view, "#upstream-status-summary", "Auth verified")
    assert has_element?(view, "#upstream-status-summary", "access token expires")
    assert has_element?(view, "#upstream-status-summary", "token refresh succeeded")

    assert has_element?(
             view,
             "#upstream-status-summary",
             "Quota refresh #{datetime_label(~U[2026-05-27 08:15:00.000000Z], scope.user)}"
           )

    assert has_element?(view, "#upstream-status-summary", "Quota fresh")

    primary_selector = "#upstream-assignment-#{primary_assignment.id}"
    disabled_selector = "#upstream-assignment-#{disabled_assignment.id}"

    assert has_element?(view, primary_selector, "Primary assignment serving production traffic")
    assert has_element?(view, primary_selector, "Status Primary (status-primary)")
    assert has_element?(view, "#{primary_selector}-pool-link[href='/admin/pools']")
    assert has_element?(view, primary_selector, "Assignment active")
    assert has_element?(view, primary_selector, "Health active")
    assert has_element?(view, primary_selector, "Routing eligible")
    assert has_element?(view, primary_selector, "Quota known")
    assert has_element?(view, primary_selector, "Quota fresh")
    assert has_element?(view, primary_selector, "Active assignment")

    assert has_element?(view, disabled_selector, "Disabled failover assignment")
    assert has_element?(view, disabled_selector, "Status Secondary (status-secondary)")
    assert has_element?(view, "#{disabled_selector}-pool-link[href='/admin/pools']")
    assert has_element?(view, disabled_selector, "Assignment disabled")
    assert has_element?(view, disabled_selector, "Health disabled")
    assert has_element?(view, disabled_selector, "Routing ineligible")
    assert has_element?(view, disabled_selector, "Quota known")
    assert has_element?(view, disabled_selector, "Disabled or unusable assignment")

    paused = status_fixture!(scope, "paused", %{identity_status: "paused"})
    {:ok, paused_view, _html} = live(conn, ~p"/admin/upstreams/#{paused.identity.id}")
    assert has_element?(paused_view, "#upstream-status-summary", "Identity paused")

    reauth =
      status_fixture!(scope, "reauth", %{
        identity_status: "reauth_required",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "reauth_required",
            "reason" => %{
              "code" => "codex_oauth_refresh_failed",
              "message" => "credential refresh rejected"
            }
          }
        }
      })

    {:ok, reauth_view, _html} = live(conn, ~p"/admin/upstreams/#{reauth.identity.id}")
    assert has_element?(reauth_view, "#upstream-status-summary", "Reauth required")
    assert has_element?(reauth_view, "#upstream-status-summary", "codex_oauth_refresh_failed")
    assert has_element?(reauth_view, "#upstream-status-summary", "credential refresh rejected")

    disabled = status_fixture!(scope, "disabled", %{identity_status: "disabled"})
    {:ok, disabled_view, _html} = live(conn, ~p"/admin/upstreams/#{disabled.identity.id}")
    assert has_element?(disabled_view, "#upstream-status-summary", "Identity disabled")

    missing = status_fixture!(scope, "missing", %{})
    {:ok, missing_view, _html} = live(conn, ~p"/admin/upstreams/#{missing.identity.id}")
    assert has_element?(missing_view, "#upstream-status-summary", "Quota missing")
    assert has_element?(missing_view, "#upstream-status-summary", "Never verified")

    exhausted = status_fixture!(scope, "exhausted", %{})

    upsert_quota_window!(exhausted.identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 0,
      used_percent: Decimal.new("100"),
      reset_at: DateTime.add(now, 3, :hour),
      observed_at: now
    })

    {:ok, exhausted_view, _html} = live(conn, ~p"/admin/upstreams/#{exhausted.identity.id}")
    assert has_element?(exhausted_view, "#upstream-status-summary", "Quota exhausted")

    missing_assignment_cockpit =
      UpstreamCockpitReadModel.from_account_snapshot(%{
        identity: %UpstreamIdentity{
          id: Ecto.UUID.generate(),
          account_label: "Detached status Codex",
          chatgpt_account_id: "detached-status-account",
          onboarding_method: "import",
          status: "active",
          metadata: %{}
        },
        label: "Detached status Codex",
        plan_label: nil,
        plan_reported?: false,
        refresh_status: "not run",
        token_refresh_label: "token refresh not run",
        refresh_job_state: nil,
        quota_refresh_status: "not run",
        auth_fresh_label: "auth imported not reported",
        auth_verified_label: "auth verified not reported",
        access_token_label: "access token expiry not reported",
        reauth_required?: false,
        reauth_reason_code: nil,
        reauth_reason_message: nil,
        assignments: [],
        quota_limits: []
      })

    assert missing_assignment_cockpit.assignments.empty? == true
    assert missing_assignment_cockpit.flags.missing_assignments? == true
  end

  @tag :saved_reset_cockpit
  test "saved reset cockpit metric, policy form, and confirmed manual redemption enqueue", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "saved-reset-cockpit", name: "Saved Reset Cockpit"})

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    first_expires_at = DateTime.add(now, 30, :day)
    first_expires_at_iso = DateTime.to_iso8601(first_expires_at)

    first_expiration_label =
      DateTimeDisplay.format_datetime(
        first_expires_at,
        DateTimeDisplay.preferences_for_user(scope.user)
      )

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Saved Reset Cockpit Codex",
        identity_metadata: %{
          "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now, 2, :hour)),
          "token_refresh" => %{
            "status" => "succeeded",
            "finished_at" => DateTime.to_iso8601(DateTime.add(now, -5, :minute))
          },
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "source" => "codex_usage_api",
            "path_style" => "codex",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(now),
            "available_expires_at" => [first_expires_at_iso],
            "next_expires_at" => first_expires_at_iso
          }
        }
      })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    assert cockpit.saved_resets.label == "1 saved reset"
    assert cockpit.saved_resets.available? == true
    assert cockpit.saved_reset_policy.enabled? == false
    assert cockpit.saved_resets.next_expires_label == "Next expires #{first_expiration_label}"

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    metric_selector = "#upstream-status-summary-saved-resets"

    assert has_element?(
             view,
             "#{metric_selector} [data-role='metric-card-value']",
             "1 saved reset"
           )

    assert has_element?(view, metric_selector, "Auto redeem off")
    assert has_element?(view, metric_selector, "Next expires #{first_expiration_label}")

    assert has_element?(view, "#saved-reset-policy-auto-redeem-enabled")
    assert has_element?(view, "#saved-reset-policy-min-blocked-minutes")
    assert has_element?(view, "#saved-reset-policy-keep-credits")
    assert has_element?(view, "#saved-reset-policy-trigger-mode")
    assert has_element?(view, "#saved-reset-policy-quota-threshold-percent")
    assert has_element?(view, "#saved-reset-policy-submit", "Save policy")

    assert has_element?(
             view,
             "#cockpit-saved-reset-expiration-summary",
             "Banked reset expirations"
           )

    assert has_element?(view, "#cockpit-saved-reset-expiration-table", "Expiration Date")
    assert has_element?(view, "#cockpit-saved-reset-expiration-table", "Time Left")
    assert has_element?(view, "#cockpit-saved-reset-expiration-date-0", first_expiration_label)
    assert has_element?(view, "#cockpit-saved-reset-expiration-time-left-0", "in ")

    view
    |> element("#saved-reset-policy-form")
    |> render_submit(%{
      "saved_reset_policy" => %{
        "auto_redeem_enabled" => "on",
        "trigger_mode" => "threshold",
        "quota_threshold_percent" => "90",
        "min_blocked_minutes" => " 15 ",
        "keep_credits" => " 2 "
      }
    })

    reloaded_identity = Repo.get!(UpstreamIdentity, identity.id)
    assert reloaded_identity.saved_reset_auto_redeem_enabled == true
    assert reloaded_identity.saved_reset_auto_redeem_min_blocked_minutes == 15
    assert reloaded_identity.saved_reset_auto_redeem_keep_credits == 2
    assert reloaded_identity.saved_reset_auto_redeem_trigger_mode == "threshold"
    assert reloaded_identity.saved_reset_auto_redeem_quota_threshold_percent == 90
    assert has_element?(view, metric_selector, "Auto redeem on · near 90% · keep 2")

    action_selector = "#cockpit-redeem-saved-reset-upstream-account-#{identity.id}"
    assert has_element?(view, action_selector, "Redeem saved reset")

    assert render_click(view, "redeem_saved_reset", %{"id" => identity.id, "pool-id" => pool.id}) =~
             "Confirm saved reset redemption before queueing it"

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == ^worker_name(SavedResetRedemptionWorker)
             ),
             :count
           ) == 0

    view |> element(action_selector) |> render_click()

    assert has_element?(view, "#cockpit-saved-reset-redemption-confirmation")
    assert has_element?(view, "#cockpit-saved-reset-redemption-confirm", "Confirm redemption")

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == ^worker_name(SavedResetRedemptionWorker)
             ),
             :count
           ) == 0

    view |> element("#cockpit-saved-reset-redemption-confirm") |> render_click()

    assert [job] =
             Repo.all(
               from job in Oban.Job,
                 where: job.worker == ^worker_name(SavedResetRedemptionWorker)
             )

    assert job.args["pool_upstream_assignment_id"] == assignment.id
    assert job.args["trigger_kind"] == "admin_manual"
    refute Map.has_key?(job.args, "credit_id")
    refute Map.has_key?(job.args, "redeem_request_id")
  end

  @tag :status_assignments_privacy
  test "keeps long labels readable and status sections free of raw secrets", %{
    conn: conn,
    scope: scope
  } do
    long_account_label =
      "Very long upstream account label for operational review " <>
        "#{String.duplicate("segment-", 12)}"

    long_pool_name =
      "Very long Pool label for assignment readability " <>
        "#{String.duplicate("pool-", 12)}"

    long_assignment_label =
      "Very long assignment label that should wrap safely " <>
        "#{String.duplicate("assignment-", 10)}"

    raw_stored_account_id = "privacy-status-#{System.unique_integer([:positive])}@example.com"
    auth_json_secret = runtime_secret("status-auth-json")
    access_token = runtime_secret("status-access-token")
    refresh_token = runtime_secret("status-refresh-token")
    cookie_secret = runtime_secret("status-cookie")
    request_body_secret = runtime_secret("status-request-body")

    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "status-privacy-long-pool",
        name: long_pool_name
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: long_account_label,
        chatgpt_account_id: raw_stored_account_id,
        assignment_label: long_assignment_label,
        plan_label: "Enterprise",
        identity_metadata: %{
          "access_token_expires_at" =>
            DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
          "token_refresh" => %{"status" => "imported"},
          "safe_auth_json_label" => auth_json_secret,
          "cookie" => cookie_secret,
          "request_body" => request_body_secret
        },
        assignment_metadata: %{
          "quota_priming" => %{"status" => "known"},
          "raw_auth_payload" => auth_json_secret
        }
      })

    for {kind, plaintext} <- [
          {"access_token", access_token},
          {"refresh_token", refresh_token},
          {"web_session", cookie_secret},
          {"other", auth_json_secret}
        ] do
      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: kind,
                 plaintext: plaintext
               })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    rendered = render(view)

    assert has_element?(view, "#upstream-cockpit-header", long_account_label)
    assert has_element?(view, "#upstream-status-summary", "stored account id sha256:")
    assert has_element?(view, "#upstream-status-summary", "Plan Enterprise")
    assert has_element?(view, "#upstream-assignment-#{assignment.id}", long_assignment_label)
    assert has_element?(view, "#upstream-assignment-#{assignment.id}", long_pool_name)

    refute rendered =~ raw_stored_account_id
    refute rendered =~ auth_json_secret
    refute rendered =~ access_token
    refute rendered =~ refresh_token
    refute rendered =~ cookie_secret
    refute rendered =~ request_body_secret
    refute rendered =~ "raw_auth_payload"
    refute rendered =~ "safe_auth_json_label"
  end

  @tag :read_model_states
  test "read model builds a rich sanitized cockpit contract", %{scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "rich-cockpit", name: "Rich Cockpit"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    raw_stored_account_id = "acct_rich_cockpit_#{System.unique_integer([:positive])}"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Rich Cockpit Codex",
        chatgpt_account_id: raw_stored_account_id,
        plan_label: "Team",
        identity_metadata: %{
          "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now, 2, :hour)),
          "token_refresh" => %{
            "status" => "succeeded",
            "finished_at" => DateTime.to_iso8601(now)
          }
        },
        assignment_label: "Primary rich assignment",
        assignment_metadata: %{"quota_priming" => %{"status" => "known"}}
      })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 100,
                 credits: 73,
                 used_percent: Decimal.new("27"),
                 reset_at: DateTime.add(now, 3, :hour),
                 source: "codex_usage",
                 source_precision: "authoritative",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)

    assert cockpit.identity.id == identity.id
    assert cockpit.identity.label == "Rich Cockpit Codex"
    assert cockpit.identity.status == "active"
    assert cockpit.identity.safe_account_id_label =~ "stored account id "
    refute cockpit.identity.safe_account_id_label =~ raw_stored_account_id
    refute Map.has_key?(cockpit.identity, :metadata)

    assert cockpit.header.title == "Rich Cockpit Codex"
    assert cockpit.header.status == "active"
    assert cockpit.header.plan_label == "Team"
    assert cockpit.header.reauth_required? == false
    assert cockpit.header.disabled? == false
    assert cockpit.header.token_refresh_label =~ "token refresh succeeded"

    assert cockpit.assignments.count == 1

    assert [%{pool_id: pool_id, pool_label: "Rich Cockpit (rich-cockpit)"}] =
             cockpit.assignments.items

    assert pool_id == pool.id
    assert cockpit.flags.missing_assignments? == false
    assert cockpit.flags.missing_quota? == false
    assert cockpit.flags.missing_requests? == false
    assert cockpit.flags.reauth_required? == false
    assert cockpit.flags.disabled_identity? == false
    assert cockpit.sections.assignments.empty? == false
    assert cockpit.sections.charts.empty? == false
    assert cockpit.sections.recent_events.empty? == true
    assert cockpit.charts.quota_health.empty? == false
    assert cockpit.charts.quota_health.state == "fresh"
    assert cockpit.charts.request_health.empty? == true
    assert cockpit.charts.request_health.state == "empty"
    assert cockpit.recent_events.items == []
    assert cockpit.actions.refresh_token.available? == true
  end

  @tag :read_model_states
  test "read model exposes sparse and missing-assignment states as explicit flags", %{
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "sparse-cockpit", name: "Sparse Cockpit"})
    %{identity: identity} = upstream_assignment_fixture(pool, %{account_label: "Sparse Codex"})

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)

    assert cockpit.flags.missing_quota? == true
    assert cockpit.flags.missing_requests? == false
    assert cockpit.flags.missing_assignments? == false
    assert cockpit.assignments.empty? == false
    assert cockpit.charts.quota_health.empty? == false
    assert cockpit.charts.quota_health.missing? == true
    assert cockpit.charts.pool_contribution.empty? == false
    assert cockpit.charts.pool_contribution.state == "no_successful_requests"

    missing_assignment_cockpit =
      UpstreamCockpitReadModel.from_account_snapshot(%{
        identity: %UpstreamIdentity{
          id: Ecto.UUID.generate(),
          account_label: "Detached Codex",
          chatgpt_account_id: "acct_detached_cockpit",
          onboarding_method: "import",
          status: "active",
          metadata: %{}
        },
        label: "Detached Codex",
        plan_label: nil,
        plan_reported?: false,
        refresh_status: "not run",
        token_refresh_label: "token refresh not run",
        refresh_job_state: nil,
        quota_refresh_status: "not run",
        auth_fresh_label: "auth imported not reported",
        auth_verified_label: "auth verified not reported",
        access_token_label: "access token expiry not reported",
        reauth_required?: false,
        reauth_reason_code: nil,
        reauth_reason_message: nil,
        assignments: [],
        quota_limits: []
      })

    assert missing_assignment_cockpit.flags.missing_assignments? == true
    assert missing_assignment_cockpit.assignments.empty? == true
    assert missing_assignment_cockpit.sections.assignments.empty? == true
  end

  @tag :read_model_states
  test "read model and page expose disabled state safely", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "disabled-cockpit", name: "Disabled Cockpit"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Disabled Codex",
        identity_status: "disabled"
      })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    assert cockpit.flags.disabled_identity? == true
    assert cockpit.header.disabled? == true
    assert cockpit.actions.pause.available? == false
    assert cockpit.actions.refresh_token.available? == false
    assert cockpit.actions.delete.available? == true

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    assert has_element?(view, "#upstream-cockpit-header", "Disabled Codex")
    assert has_element?(view, "#upstream-cockpit-header", "disabled")
  end

  @tag :read_model_states
  test "read model exposes reauth-required state and safe recovery actions", %{scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "reauth-cockpit", name: "Reauth Cockpit"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Reauth Codex",
        identity_status: "reauth_required",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "reauth_required",
            "reason" => %{
              "code" => "codex_oauth_refresh_failed",
              "message" => "credential refresh was rejected"
            }
          }
        }
      })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    assert cockpit.flags.reauth_required? == true
    assert cockpit.header.reauth_required? == true
    assert cockpit.header.reauth_reason_code == "codex_oauth_refresh_failed"
    assert cockpit.header.reauth_reason_message == "credential refresh was rejected"
    assert cockpit.actions.refresh_token.available? == false
    assert cockpit.actions.replace_auth_json.available? == true
    assert cockpit.actions.reinvite.available? == true
  end

  @tag :quota_health
  test "read model builds explicit quota health states for target assignments", %{scope: scope} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fresh_reset = DateTime.add(now, 4, :hour)
    weekly_reset = DateTime.add(now, 7, :day)

    stale_observed_at =
      DateTime.add(now, -Evidence.freshness_ttl_seconds() - 60, :second)

    fresh =
      quota_cockpit!(scope, "fresh", [
        %{
          window_kind: "primary",
          window_minutes: 300,
          active_limit: 100,
          credits: 80,
          used_percent: Decimal.new("20"),
          reset_at: fresh_reset,
          observed_at: now
        }
      ])

    assert fresh.charts.quota_health.state == "fresh"
    assert fresh.charts.quota_health.kpis.assignment_count == 1
    assert fresh.charts.quota_health.kpis.routing_usable_count == 1
    assert fresh.charts.quota_health.kpis.fresh_count == 1
    assert fresh.charts.quota_health.kpis.stale_or_missing_count == 0
    assert fresh.charts.quota_health.kpis.exhausted_count == 0
    assert fresh.charts.quota_health.kpis.weekly_only_count == 0
    assert fresh.charts.quota_health.kpis.missing_evidence_count == 0
    assert fresh.charts.quota_health.empty? == false
    assert fresh.charts.quota_health.degraded? == false
    assert fresh.flags.missing_quota? == false

    assert [%{state: "fresh", state_label: "Fresh", routing_usable?: true} = fresh_item] =
             fresh.charts.quota_health.items

    assert fresh_item.state == fresh.charts.quota_health.state
    assert fresh_item.window_kind == "primary"
    assert fresh_item.pool_label =~ "Quota fresh"
    assert fresh_item.remaining_percent_value == 80.0
    assert fresh_item.used_percent_value == 20.0
    assert fresh_item.bar_value == 80.0
    assert fresh_item.routing_usable? == true
    assert fresh_item.reason_codes == []
    assert fresh_item.primary_5h.routing_usable? == true
    assert fresh_item.primary_5h.reason_codes == ["unknown_unusable"]
    assert fresh_item.weekly == nil

    stale =
      quota_cockpit!(scope, "stale", [
        %{
          window_kind: "primary",
          window_minutes: 300,
          active_limit: 100,
          credits: 70,
          used_percent: Decimal.new("30"),
          reset_at: fresh_reset,
          observed_at: stale_observed_at
        }
      ])

    assert stale.charts.quota_health.state == "stale"
    assert stale.charts.quota_health.kpis.stale_count == 1
    assert stale.charts.quota_health.kpis.routing_usable_count == 0
    assert stale.charts.quota_health.kpis.fresh_count == 0
    assert stale.charts.quota_health.kpis.stale_or_missing_count == 1
    assert stale.charts.quota_health.kpis.exhausted_count == 0
    assert stale.charts.quota_health.kpis.weekly_only_count == 0
    assert stale.charts.quota_health.kpis.missing_evidence_count == 0

    assert [%{state: "stale", state_label: "Stale", routing_usable?: false} = stale_item] =
             stale.charts.quota_health.items

    assert stale_item.state == stale.charts.quota_health.state
    assert "not_fresh" in stale_item.reason_codes
    assert stale_item.reason_codes == ["quota_window_unusable", "not_fresh"]
    assert stale_item.routing_usable? == false
    assert stale_item.freshness_state == "stale"
    assert stale_item.primary_5h.routing_usable? == false
    assert stale_item.primary_5h.reason_codes == ["not_fresh"]
    assert stale_item.weekly == nil

    exhausted =
      quota_cockpit!(scope, "exhausted", [
        %{
          window_kind: "primary",
          window_minutes: 300,
          active_limit: 100,
          credits: 0,
          used_percent: Decimal.new("100"),
          reset_at: fresh_reset,
          observed_at: now
        }
      ])

    assert exhausted.charts.quota_health.state == "exhausted"
    assert exhausted.charts.quota_health.kpis.exhausted_count == 1
    assert exhausted.charts.quota_health.kpis.routing_usable_count == 0
    assert exhausted.charts.quota_health.kpis.fresh_count == 0
    assert exhausted.charts.quota_health.kpis.stale_count == 0
    assert exhausted.charts.quota_health.kpis.weekly_only_count == 0
    assert exhausted.charts.quota_health.kpis.missing_evidence_count == 0

    assert [
             %{state: "exhausted", state_label: "Exhausted", routing_usable?: false} =
               exhausted_item
           ] =
             exhausted.charts.quota_health.items

    assert exhausted_item.state == exhausted.charts.quota_health.state
    assert "exhausted" in exhausted_item.reason_codes
    assert exhausted_item.reason_codes == ["quota_window_unusable", "exhausted"]
    assert exhausted_item.routing_usable? == false
    assert exhausted_item.bar_value == 0.0
    assert exhausted_item.primary_5h.routing_usable? == false
    assert exhausted_item.primary_5h.reason_codes == ["exhausted"]
    assert exhausted_item.weekly == nil

    weekly_only =
      quota_cockpit!(scope, "weekly-only", [
        %{
          window_kind: "secondary",
          window_minutes: 10_080,
          active_limit: 100,
          credits: 45,
          used_percent: Decimal.new("55"),
          reset_at: weekly_reset,
          observed_at: now
        }
      ])

    assert weekly_only.charts.quota_health.state == "weekly_only"
    assert weekly_only.charts.quota_health.kpis.weekly_only_count == 1
    assert weekly_only.charts.quota_health.kpis.routing_usable_count == 1
    assert weekly_only.charts.quota_health.kpis.fresh_count == 0
    assert weekly_only.charts.quota_health.kpis.stale_count == 0
    assert weekly_only.charts.quota_health.kpis.exhausted_count == 0
    assert weekly_only.charts.quota_health.kpis.missing_evidence_count == 0

    assert [
             %{state: "weekly_only", state_label: "Weekly-only", routing_usable?: true} =
               weekly_item
           ] =
             weekly_only.charts.quota_health.items

    assert weekly_item.state == weekly_only.charts.quota_health.state
    assert weekly_item.window_kind == "secondary"
    assert weekly_item.remaining_percent_value == 45.0
    assert weekly_item.routing_usable? == true
    assert weekly_item.reason_codes == ["quota_account_primary_unknown"]
    assert weekly_item.weekly.routing_usable? == true
    assert weekly_item.weekly.reason_codes == ["unknown_unusable"]
    assert weekly_item.primary_5h == nil

    missing = quota_cockpit!(scope, "missing", [])

    assert missing.charts.quota_health.state == "missing_evidence"
    assert missing.charts.quota_health.missing? == true
    assert missing.charts.quota_health.degraded? == true
    assert missing.charts.quota_health.kpis.missing_evidence_count == 1
    assert missing.charts.quota_health.kpis.stale_or_missing_count == 1
    assert missing.charts.quota_health.kpis.routing_usable_count == 0
    assert missing.charts.quota_health.kpis.fresh_count == 0
    assert missing.charts.quota_health.kpis.stale_count == 0
    assert missing.charts.quota_health.kpis.exhausted_count == 0
    assert missing.charts.quota_health.kpis.weekly_only_count == 0
    assert missing.flags.missing_quota? == true

    assert [%{state: "missing_evidence", state_label: "Missing evidence"} = missing_item] =
             missing.charts.quota_health.items

    assert missing_item.state == missing.charts.quota_health.state
    assert missing_item.routing_usable? == false
    assert missing_item.reason_codes == ["quota_evidence_missing"]
    assert missing_item.bar_value == 0.0
    assert missing_item.remaining_percent_value == nil
    assert missing_item.reset_at == nil
    assert missing_item.primary_5h == nil
    assert missing_item.primary_30d == nil
    assert missing_item.weekly == nil
  end

  @tag :routing_lifecycle
  test "cockpit routing usability blocks refresh_failed identities with fresh quota", %{
    conn: conn,
    scope: scope
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "routing-lifecycle-refresh-failed",
        name: "Routing Lifecycle Refresh Failed"
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Routing lifecycle failed Codex",
        assignment_label: "Routing lifecycle active assignment",
        identity_status: "refresh_failed",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "failed",
            "reason" => %{
              "code" => "refresh_token_rejected",
              "message" => "credential refresh failed"
            }
          }
        }
      })

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 88,
      used_percent: Decimal.new("12"),
      reset_at: DateTime.add(now, 4, :hour),
      observed_at: now
    })

    request_health_request_fixture(pool, assignment, %{
      status: "succeeded",
      admitted_at: DateTime.add(now, -30, :minute),
      correlation_id: "routing-lifecycle-refresh-failed-success"
    })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)

    assert cockpit.assignments.count == 1
    assert cockpit.charts.quota_health.kpis.assignment_count == 1
    assert cockpit.charts.quota_health.kpis.fresh_count == 1
    assert cockpit.charts.quota_health.kpis.routing_usable_count == 0

    assert [
             %{
               state: "fresh",
               state_label: "Fresh",
               routing_usable?: false,
               routing_readiness_label: "Auth refresh failed"
             } = quota_item
           ] = cockpit.charts.quota_health.items

    assert quota_item.remaining_percent_value == 88.0
    assert quota_item.primary_5h.routing_usable? == true
    assert "identity_refresh_failed" in quota_item.reason_codes

    contribution = cockpit.charts.pool_contribution
    assert contribution.kpis.assignment_count == 1
    assert contribution.kpis.active_assignment_count == 0
    assert contribution.kpis.disabled_assignment_count == 1
    assert contribution.kpis.successful_requests_7d == 1

    assert [
             %{
               assignment_state: "disabled",
               assignment_state_label: "Auth refresh failed",
               routing_usable?: false,
               successful_request_count_7d: 1,
               share_percent_value: 100.0
             }
           ] = contribution.items

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#quota-health-chart-bars[data-chart-routing-usable='0']")
    assert has_element?(view, "#quota-health-chart-item-#{assignment.id}", "Auth refresh failed")
    assert has_element?(view, "#quota-health-chart-item-#{assignment.id}", "88% remaining")
    assert has_element?(view, "#pool-contribution-chart-bars[data-chart-active='0']")
    assert has_element?(view, "#pool-contribution-chart-bars[data-chart-disabled='1']")

    assert has_element?(
             view,
             "#pool-contribution-chart-item-#{assignment.id}",
             "Auth refresh failed"
           )
  end

  @tag :quota_health
  test "read model treats fresh monthly primary evidence as ready 30d quota", %{scope: scope} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    monthly_reset = DateTime.add(now, 30, :day)

    monthly =
      quota_cockpit!(scope, "monthly-primary", [
        %{
          window_kind: "primary",
          window_minutes: 43_200,
          used_percent: Decimal.new("42.5"),
          reset_at: monthly_reset,
          observed_at: now
        }
      ])

    assert monthly.charts.quota_health.state == "fresh"
    assert monthly.charts.quota_health.kpis.assignment_count == 1
    assert monthly.charts.quota_health.kpis.routing_usable_count == 1
    assert monthly.charts.quota_health.kpis.fresh_count == 1
    assert monthly.charts.quota_health.kpis.missing_evidence_count == 0
    assert monthly.flags.missing_quota? == false

    assert [%{state: "fresh", state_label: "Fresh", routing_usable?: true} = monthly_item] =
             monthly.charts.quota_health.items

    assert monthly_item.window_kind == "primary"
    assert monthly_item.window_minutes == 43_200
    assert monthly_item.remaining == nil
    assert monthly_item.capacity == nil
    assert monthly_item.used == nil
    assert monthly_item.remaining_percent_value == 57.5
    assert monthly_item.used_percent_value == 42.5
    assert monthly_item.bar_value == 57.5
    assert monthly_item.reason_codes == []
    assert monthly_item.primary_5h == nil
    assert monthly_item.primary_30d.routing_usable? == true
    assert monthly_item.primary_30d.window_minutes == 43_200
    assert monthly_item.primary_30d.reason_codes == ["unknown_unusable"]
    assert monthly_item.weekly == nil
  end

  @tag :quota_health_blocked
  test "read model keeps exhausted weekly quota authoritative over a fresh primary", %{
    scope: scope
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fresh_reset = DateTime.add(now, 4, :hour)
    weekly_reset = DateTime.add(now, 7, :day)

    contradiction =
      quota_cockpit!(scope, "fresh-primary-exhausted-weekly", [
        %{
          window_kind: "primary",
          window_minutes: 300,
          active_limit: 100,
          credits: 80,
          used_percent: Decimal.new("20"),
          reset_at: fresh_reset,
          observed_at: now
        },
        %{
          window_kind: "secondary",
          window_minutes: 10_080,
          active_limit: 100,
          credits: 0,
          used_percent: Decimal.new("100"),
          reset_at: weekly_reset,
          observed_at: now
        }
      ])

    assert contradiction.charts.quota_health.state == "exhausted"
    assert contradiction.charts.quota_health.degraded? == true
    assert contradiction.charts.quota_health.kpis.routing_usable_count == 0
    assert contradiction.charts.quota_health.kpis.exhausted_count == 1
    assert contradiction.charts.quota_health.kpis.fresh_count == 0
    assert contradiction.charts.quota_health.kpis.weekly_only_count == 0
    assert contradiction.flags.missing_quota? == false

    assert [
             %{state: "exhausted", state_label: "Exhausted", routing_usable?: false} =
               contradiction_item
           ] =
             contradiction.charts.quota_health.items

    assert contradiction_item.state == contradiction.charts.quota_health.state
    assert "exhausted" in contradiction_item.reason_codes
    assert contradiction_item.reason_codes == ["quota_window_unusable", "exhausted"]
    assert contradiction_item.routing_usable? == false
    assert contradiction_item.primary_5h.routing_usable? == true
    assert contradiction_item.primary_5h.reason_codes == ["unknown_unusable"]
    assert contradiction_item.weekly.routing_usable? == false
    assert contradiction_item.weekly.reason_codes == ["exhausted"]
    assert contradiction_item.weekly.remaining_percent_value == 0.0
  end

  @tag :quota_isolation
  test "quota health ignores quota evidence from unrelated upstreams in the same pool", %{
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "quota-isolation", name: "Quota Isolation"})

    %{identity: target_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Target isolated Codex",
        assignment_label: "Target isolated assignment"
      })

    %{identity: unrelated_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Unrelated quota Codex",
        assignment_label: "Unrelated quota assignment"
      })

    upsert_quota_window!(unrelated_identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 99,
      used_percent: Decimal.new("1"),
      reset_at: DateTime.add(DateTime.utc_now(), 5, :hour),
      observed_at: DateTime.utc_now()
    })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, target_identity.id)

    assert cockpit.charts.quota_health.state == "missing_evidence"
    assert cockpit.charts.quota_health.kpis.assignment_count == 1
    assert cockpit.charts.quota_health.kpis.routing_usable_count == 0
    assert cockpit.charts.quota_health.kpis.missing_evidence_count == 1

    assert [%{state: "missing_evidence", assignment_label: "Target isolated assignment"}] =
             cockpit.charts.quota_health.items

    inspected_quota_health = inspect(cockpit.charts.quota_health)
    refute inspected_quota_health =~ unrelated_identity.id
    refute inspected_quota_health =~ "Unrelated quota Codex"
    refute inspected_quota_health =~ "Unrelated quota assignment"
  end

  @tag :request_health
  test "request health builds 24h KPIs and 7d series for the target upstream only", %{
    scope: scope
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    all_success =
      request_health_cockpit!(scope, "all-success", [
        %{status: "succeeded", admitted_at: DateTime.add(now, -2, :hour)},
        %{status: "succeeded", admitted_at: DateTime.add(now, -2, :day)}
      ])

    assert all_success.charts.request_health.state == "healthy"
    assert all_success.charts.request_health.empty? == false
    assert all_success.charts.request_health.degraded? == false
    assert all_success.charts.request_health.missing? == false
    assert all_success.flags.missing_requests? == false
    assert all_success.charts.request_health.kpis.total_requests_24h == 1
    assert all_success.charts.request_health.kpis.failed_requests_24h == 0
    assert all_success.charts.request_health.kpis.failure_rate_24h == 0.0
    assert all_success.charts.request_health.kpis.total_requests_7d == 2
    assert length(all_success.charts.request_health.items) == 7

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "request-health-mixed", name: "Request Health Mixed"})

    %{identity: target_identity, assignment: target_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Request health target",
        assignment_label: "Request health target assignment"
      })

    %{assignment: unrelated_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Request health unrelated",
        assignment_label: "Request health unrelated assignment"
      })

    target_success_at = DateTime.add(now, -30, :minute)
    target_failure_at = target_success_at
    target_older_failure_at = DateTime.add(now, -2, :day)

    request_health_request_fixture(pool, target_assignment, %{
      status: "succeeded",
      admitted_at: target_success_at,
      correlation_id: "target-request-health-success"
    })

    request_health_request_fixture(pool, target_assignment, %{
      status: "failed",
      admitted_at: target_failure_at,
      correlation_id: "target-request-health-failed"
    })

    request_health_request_fixture(pool, target_assignment, %{
      status: "rejected",
      admitted_at: target_older_failure_at,
      correlation_id: "target-request-health-rejected"
    })

    request_health_request_fixture(pool, unrelated_assignment, %{
      status: "succeeded",
      admitted_at: target_success_at,
      correlation_id: "unrelated-request-health-success"
    })

    request_health_request_fixture(pool, unrelated_assignment, %{
      status: "failed",
      admitted_at: target_failure_at,
      correlation_id: "unrelated-request-health-failed"
    })

    assert {:ok, mixed} = UpstreamCockpitReadModel.load_visible(scope, target_identity.id)

    assert mixed.charts.request_health.state == "degraded"
    assert mixed.charts.request_health.degraded? == true
    assert mixed.charts.request_health.kpis.total_requests_24h == 2
    assert mixed.charts.request_health.kpis.failed_requests_24h == 1
    assert mixed.charts.request_health.kpis.failure_rate_24h == 50.0
    assert mixed.charts.request_health.kpis.total_requests_7d == 3

    today_bucket = request_health_bucket(mixed, target_success_at)
    assert today_bucket.success_count == 1
    assert today_bucket.failure_count == 1
    assert today_bucket.total_count == 2

    older_bucket = request_health_bucket(mixed, target_older_failure_at)
    assert older_bucket.success_count == 0
    assert older_bucket.failure_count == 1
    assert older_bucket.total_count == 1

    inspected_health = inspect(mixed.charts.request_health)
    refute inspected_health =~ "Request health unrelated"
    refute inspected_health =~ "Request health unrelated assignment"
    refute inspected_health =~ "unrelated-request-health"
  end

  @tag :request_health_empty_failure
  test "request health handles empty all-failure and secret-bearing rows deterministically", %{
    conn: conn,
    scope: scope
  } do
    empty = request_health_cockpit!(scope, "empty", [])

    assert empty.charts.request_health.state == "empty"
    assert empty.charts.request_health.empty? == true
    assert empty.charts.request_health.degraded? == false
    assert empty.charts.request_health.missing? == false
    assert empty.flags.missing_requests? == false
    assert empty.charts.request_health.kpis.total_requests_24h == 0
    assert empty.charts.request_health.kpis.failed_requests_24h == 0
    assert empty.charts.request_health.kpis.failure_rate_24h == 0.0
    assert empty.charts.request_health.kpis.total_requests_7d == 0
    assert length(empty.charts.request_health.items) == 7
    assert Enum.all?(empty.charts.request_health.items, &(&1.total_count == 0))

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "request-health-failure", name: "Request Health Failure"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Failure health target",
        assignment_label: "Failure health target assignment"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    prompt_secret = runtime_secret("request-health-prompt")
    body_secret = runtime_secret("request-health-body")
    debug_secret = runtime_secret("request-health-debug")
    attempt_secret = runtime_secret("request-health-attempt")

    request_health_request_fixture(pool, assignment, %{
      status: "failed",
      admitted_at: DateTime.add(now, -1, :hour),
      correlation_id: "failure-request-health-failed",
      request_metadata: %{
        "prompt" => prompt_secret,
        "body" => %{"input" => body_secret},
        "debug" => %{"raw" => debug_secret},
        "authorization" => "Bearer #{debug_secret}"
      },
      attempt_response_metadata: %{
        "body" => %{"frame" => attempt_secret},
        "cookie" => "session=#{attempt_secret}"
      }
    })

    request_health_request_fixture(pool, assignment, %{
      status: "cancelled",
      admitted_at: DateTime.add(now, -2, :hour),
      correlation_id: "failure-request-health-cancelled"
    })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)

    assert cockpit.charts.request_health.state == "failed"
    assert cockpit.charts.request_health.empty? == false
    assert cockpit.charts.request_health.degraded? == true
    assert cockpit.charts.request_health.kpis.total_requests_24h == 2
    assert cockpit.charts.request_health.kpis.failed_requests_24h == 2
    assert cockpit.charts.request_health.kpis.failure_rate_24h == 100.0
    assert cockpit.charts.request_health.kpis.total_requests_7d == 2

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    rendered = render(view)
    inspected_cockpit = inspect(cockpit)
    inspected_health = inspect(cockpit.charts.request_health)

    for forbidden <- [prompt_secret, body_secret, debug_secret, attempt_secret] do
      refute inspected_cockpit =~ forbidden
      refute inspected_health =~ forbidden
      refute rendered =~ forbidden
    end
  end

  @tag :pool_contribution
  test "pool contribution calculates target upstream successful request share by assigned pool",
       %{
         scope: scope
       } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, primary_pool} =
      Pools.create_pool(scope, %{
        slug: "pool-contribution-primary",
        name: "Pool Contribution Primary"
      })

    {:ok, secondary_pool} =
      Pools.create_pool(scope, %{
        slug: "pool-contribution-secondary",
        name: "Pool Contribution Secondary"
      })

    {:ok, unrelated_pool} =
      Pools.create_pool(scope, %{
        slug: "pool-contribution-unrelated",
        name: "Pool Contribution Unrelated"
      })

    %{identity: target_identity, assignment: primary_assignment} =
      upstream_assignment_fixture(primary_pool, %{
        account_label: "Pool contribution target",
        assignment_label: "Primary contribution assignment"
      })

    assert {:ok, secondary_assignment} =
             PoolAssignments.create_pool_assignment(secondary_pool, target_identity, %{
               assignment_label: "Secondary contribution assignment",
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

    %{identity: unrelated_identity, assignment: unrelated_assignment} =
      upstream_assignment_fixture(unrelated_pool, %{
        account_label: "Unrelated contribution Codex",
        assignment_label: "Unrelated contribution assignment"
      })

    upsert_quota_window!(target_identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 73,
      used_percent: Decimal.new("27"),
      reset_at: DateTime.add(now, 4, :hour),
      observed_at: now
    })

    for offset <- [1, 2, 3] do
      request_health_request_fixture(primary_pool, primary_assignment, %{
        status: "succeeded",
        admitted_at: DateTime.add(now, -offset, :hour),
        correlation_id: "target-primary-contribution-#{offset}"
      })
    end

    request_health_request_fixture(secondary_pool, secondary_assignment, %{
      status: "succeeded",
      admitted_at: DateTime.add(now, -2, :day),
      correlation_id: "target-secondary-contribution-success"
    })

    request_health_request_fixture(secondary_pool, secondary_assignment, %{
      status: "failed",
      admitted_at: DateTime.add(now, -1, :hour),
      correlation_id: "target-secondary-contribution-failed"
    })

    request_health_request_fixture(primary_pool, primary_assignment, %{
      status: "succeeded",
      admitted_at: DateTime.add(now, -8, :day),
      correlation_id: "target-primary-contribution-outside-window"
    })

    for offset <- [1, 2, 3, 4, 5] do
      request_health_request_fixture(unrelated_pool, unrelated_assignment, %{
        status: "succeeded",
        admitted_at: DateTime.add(now, -offset, :hour),
        correlation_id: "unrelated-contribution-success-#{offset}"
      })
    end

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, target_identity.id)
    contribution = cockpit.charts.pool_contribution

    assert contribution.state == "contributing"
    assert contribution.empty? == false
    assert contribution.missing? == false
    assert contribution.degraded? == false
    assert contribution.kpis.assignment_count == 2
    assert contribution.kpis.active_assignment_count == 2
    assert contribution.kpis.disabled_assignment_count == 0
    assert contribution.kpis.successful_requests_7d == 4

    items_by_pool_id = Map.new(contribution.items, &{&1.pool_id, &1})

    assert Map.keys(items_by_pool_id) |> Enum.sort() ==
             [primary_pool.id, secondary_pool.id] |> Enum.sort()

    primary_assignment_id = primary_assignment.id
    secondary_assignment_id = secondary_assignment.id

    primary_item = items_by_pool_id[primary_pool.id]
    assert primary_item.assignment_id == primary_assignment_id
    assert primary_item.successful_request_count_7d == 3
    assert primary_item.share_percent_value == 75.0
    assert primary_item.bar_value == 75.0
    assert primary_item.assignment_state == "active"
    assert primary_item.assignment_state_label == "Active assignment"
    assert primary_item.routing_usable? == true

    secondary_item = items_by_pool_id[secondary_pool.id]
    assert secondary_item.assignment_id == secondary_assignment_id
    assert secondary_item.successful_request_count_7d == 1
    assert secondary_item.share_percent_value == 25.0
    assert secondary_item.bar_value == 25.0
    assert secondary_item.assignment_state == "active"
    assert secondary_item.assignment_state_label == "Active assignment"
    assert secondary_item.routing_usable? == true

    inspected_contribution = inspect(contribution)
    refute inspected_contribution =~ unrelated_identity.id
    refute inspected_contribution =~ unrelated_pool.id
    refute inspected_contribution =~ "Unrelated contribution Codex"
    refute inspected_contribution =~ "unrelated-contribution-success"
  end

  @tag :pool_contribution_zero_disabled
  test "pool contribution keeps zero-traffic and disabled assignments visible safely", %{
    conn: conn,
    scope: scope
  } do
    {:ok, active_pool} =
      Pools.create_pool(scope, %{
        slug: "pool-contribution-zero-active",
        name: "Pool Contribution Zero Active"
      })

    {:ok, disabled_pool} =
      Pools.create_pool(scope, %{
        slug: "pool-contribution-zero-disabled",
        name: "Pool Contribution Zero Disabled"
      })

    {:ok, unrelated_pool} =
      Pools.create_pool(scope, %{
        slug: "pool-contribution-zero-unrelated",
        name: "Pool Contribution Zero Unrelated"
      })

    %{identity: identity, assignment: active_assignment} =
      upstream_assignment_fixture(active_pool, %{
        account_label: "Zero contribution target",
        assignment_label: "Zero active assignment"
      })

    assert {:ok, disabled_assignment} =
             PoolAssignments.create_pool_assignment(disabled_pool, identity, %{
               assignment_label: "Zero disabled assignment",
               status: "disabled",
               health_status: "disabled",
               eligibility_status: "ineligible"
             })

    %{assignment: unrelated_assignment} =
      upstream_assignment_fixture(unrelated_pool, %{
        account_label: "Zero unrelated Codex",
        assignment_label: "Zero unrelated assignment"
      })

    prompt_secret = runtime_secret("pool-contribution-prompt")
    body_secret = runtime_secret("pool-contribution-body")
    debug_secret = runtime_secret("pool-contribution-debug")
    attempt_secret = runtime_secret("pool-contribution-attempt")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 69,
      used_percent: Decimal.new("31"),
      reset_at: DateTime.add(now, 4, :hour),
      observed_at: now
    })

    request_health_request_fixture(unrelated_pool, unrelated_assignment, %{
      status: "succeeded",
      admitted_at: DateTime.add(now, -1, :hour),
      correlation_id: "zero-unrelated-contribution-success",
      request_metadata: %{
        "prompt" => prompt_secret,
        "body" => %{"input" => body_secret},
        "debug" => %{"raw" => debug_secret}
      },
      attempt_response_metadata: %{
        "body" => %{"frame" => attempt_secret},
        "cookie" => "session=#{attempt_secret}"
      }
    })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    contribution = cockpit.charts.pool_contribution

    assert contribution.state == "no_successful_requests"
    assert contribution.empty? == false
    assert contribution.missing? == false
    assert contribution.degraded? == true
    assert contribution.kpis.assignment_count == 2
    assert contribution.kpis.active_assignment_count == 1
    assert contribution.kpis.disabled_assignment_count == 1
    assert contribution.kpis.successful_requests_7d == 0

    items_by_pool_id = Map.new(contribution.items, &{&1.pool_id, &1})

    active_assignment_id = active_assignment.id
    disabled_assignment_id = disabled_assignment.id

    active_item = items_by_pool_id[active_pool.id]
    assert active_item.assignment_id == active_assignment_id
    assert active_item.successful_request_count_7d == 0
    assert active_item.share_percent_value == 0.0
    assert active_item.bar_value == 0.0
    assert active_item.assignment_state == "active"
    assert active_item.assignment_state_label == "Active assignment"
    assert active_item.routing_usable? == true

    disabled_item = items_by_pool_id[disabled_pool.id]
    assert disabled_item.assignment_id == disabled_assignment_id
    assert disabled_item.successful_request_count_7d == 0
    assert disabled_item.share_percent_value == 0.0
    assert disabled_item.bar_value == 0.0
    assert disabled_item.assignment_state == "disabled"
    assert disabled_item.assignment_state_label == "Disabled or unusable assignment"
    assert disabled_item.routing_usable? == false

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    rendered = render(view)
    inspected_contribution = inspect(contribution)

    for forbidden <- [prompt_secret, body_secret, debug_secret, attempt_secret] do
      refute inspected_contribution =~ forbidden
      refute rendered =~ forbidden
    end
  end

  @tag :chart_rendering
  test "renders deterministic quota request and pool contribution chart sections", %{
    conn: conn,
    scope: scope
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, primary_pool} =
      Pools.create_pool(scope, %{
        slug: "chart-rendering-primary",
        name: "Chart Rendering Primary"
      })

    {:ok, secondary_pool} =
      Pools.create_pool(scope, %{
        slug: "chart-rendering-secondary",
        name: "Chart Rendering Secondary"
      })

    %{identity: identity, assignment: primary_assignment} =
      upstream_assignment_fixture(primary_pool, %{
        account_label: "Chart rendering target",
        assignment_label: "Primary chart assignment"
      })

    assert {:ok, secondary_assignment} =
             PoolAssignments.create_pool_assignment(secondary_pool, identity, %{
               assignment_label: "Secondary chart assignment",
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 65,
      used_percent: Decimal.new("35"),
      reset_at: DateTime.add(now, 4, :hour),
      observed_at: now
    })

    for offset <- [1, 2] do
      request_health_request_fixture(primary_pool, primary_assignment, %{
        status: "succeeded",
        admitted_at: DateTime.add(now, -offset, :hour),
        correlation_id: "chart-rendering-primary-success-#{offset}"
      })
    end

    request_health_request_fixture(secondary_pool, secondary_assignment, %{
      status: "succeeded",
      admitted_at: DateTime.add(now, -3, :hour),
      correlation_id: "chart-rendering-secondary-success"
    })

    request_health_request_fixture(primary_pool, primary_assignment, %{
      status: "failed",
      admitted_at: DateTime.add(now, -4, :hour),
      correlation_id: "chart-rendering-primary-failed"
    })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#quota-health-chart")
    assert has_element?(view, "#quota-health-chart-bars[data-chart='quota-health']")
    assert has_element?(view, "#quota-health-chart-bars[data-chart-state='fresh']")
    assert has_element?(view, "#quota-health-chart-bars[data-chart-total='2']")
    assert has_element?(view, "#quota-health-chart-bars[data-chart-routing-usable='2']")
    assert has_element?(view, "#quota-health-chart-summary.sr-only", "2 assignments")

    assert has_element?(
             view,
             "#quota-health-chart-item-#{primary_assignment.id}[data-chart-value='65']",
             "Primary chart assignment"
           )

    assert has_element?(
             view,
             "#quota-health-chart-item-#{primary_assignment.id}-bar[value='65'][max='100']"
           )

    assert has_element?(
             view,
             "#quota-health-chart-item-#{secondary_assignment.id}[data-chart-value='65']",
             "Secondary chart assignment"
           )

    assert has_element?(view, "#request-health-chart")
    assert has_element?(view, "#request-health-chart-plot[phx-hook='ApexTimeSeriesChart']")
    assert has_element?(view, "#request-health-chart-plot[phx-update='ignore']")
    assert has_element?(view, "#request-health-chart-plot[data-chart-unit='requests']")
    assert has_element?(view, "#request-health-chart-plot[data-chart-total='4']")
    assert has_element?(view, "#request-health-chart-summary.sr-only", "4 requests")
    assert has_element?(view, "#request-health-chart", "Failure rate 25.0%")
    refute has_element?(view, "#request-health-chart-plot svg")

    assert has_element?(view, "#pool-contribution-chart")
    assert has_element?(view, "#pool-contribution-chart-bars[data-chart='pool-contribution']")
    assert has_element?(view, "#pool-contribution-chart-bars[data-chart-state='contributing']")
    assert has_element?(view, "#pool-contribution-chart-bars[data-chart-total='3']")
    assert has_element?(view, "#pool-contribution-chart-summary.sr-only", "3 successful requests")

    assert has_element?(
             view,
             "#pool-contribution-chart-item-#{primary_assignment.id}[data-chart-value='66.7']",
             "2 successes"
           )

    assert has_element?(
             view,
             "#pool-contribution-chart-item-#{primary_assignment.id}-bar[value='66.7'][max='100']"
           )

    assert has_element?(
             view,
             "#pool-contribution-chart-item-#{secondary_assignment.id}[data-chart-value='33.3']",
             "1 success"
           )
  end

  @tag :quota_health_percent_only
  test "renders percent-only quota evidence with zero absolute capacity as an available bar", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "quota-percent-only-zero-capacity",
        name: "Quota Percent Only Zero Capacity"
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Percent-only zero capacity Codex",
        assignment_label: "Percent-only zero capacity assignment"
      })

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 0,
      credits: 0,
      used_percent: Decimal.new("9"),
      reset_at: DateTime.add(DateTime.utc_now(), 4, :hour)
    })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)

    assert [%{bar_value: 91.0, remaining_percent_value: 91.0, used_percent_value: 9.0}] =
             cockpit.charts.quota_health.items

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(
             view,
             "#quota-health-chart-item-#{assignment.id}[data-chart-value='91']",
             "91% remaining"
           )

    assert has_element?(
             view,
             "#quota-health-chart-item-#{assignment.id}-bar[value='91'][max='100']"
           )

    assert has_element?(view, "#quota-health-chart-item-#{assignment.id}", "9% used")
  end

  @tag :chart_empty_zero
  test "chart sections keep shells and explicit zero semantics for empty all-zero data", %{
    conn: conn,
    scope: scope
  } do
    {:ok, active_pool} =
      Pools.create_pool(scope, %{
        slug: "chart-zero-active",
        name: "Chart Zero Active"
      })

    {:ok, disabled_pool} =
      Pools.create_pool(scope, %{
        slug: "chart-zero-disabled",
        name: "Chart Zero Disabled"
      })

    %{identity: identity, assignment: active_assignment} =
      upstream_assignment_fixture(active_pool, %{
        account_label: "Chart zero target",
        assignment_label: "Zero active assignment"
      })

    assert {:ok, disabled_assignment} =
             PoolAssignments.create_pool_assignment(disabled_pool, identity, %{
               assignment_label: "Zero disabled assignment",
               status: "disabled",
               health_status: "disabled",
               eligibility_status: "ineligible"
             })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#quota-health-chart")
    assert has_element?(view, "#quota-health-chart-bars[data-chart='quota-health']")
    assert has_element?(view, "#quota-health-chart-bars[data-chart-state='missing_evidence']")
    assert has_element?(view, "#quota-health-chart-bars[data-chart-total='2']")
    assert has_element?(view, "#quota-health-chart-bars[data-chart-routing-usable='0']")
    assert has_element?(view, "#quota-health-chart", "Quota evidence is missing")
    assert has_element?(view, "#quota-health-chart-summary.sr-only", "0 routing usable")

    for assignment <- [active_assignment, disabled_assignment] do
      assert has_element?(
               view,
               "#quota-health-chart-item-#{assignment.id}[data-chart-value='0']"
             )

      assert has_element?(
               view,
               "#quota-health-chart-item-#{assignment.id}-bar[value='0'][max='100']"
             )
    end

    assert has_element?(view, "#request-health-chart")
    assert has_element?(view, "#request-health-chart-plot[phx-hook='ApexTimeSeriesChart']")
    assert has_element?(view, "#request-health-chart-plot[data-chart-total='0']")
    assert has_element?(view, "#request-health-chart", "0 requests")
    assert has_element?(view, "#request-health-chart", "No request traffic")
    assert has_element?(view, "#request-health-chart-summary.sr-only", "0 total requests")
    refute has_element?(view, "#request-health-chart-plot svg")

    assert has_element?(view, "#pool-contribution-chart")
    assert has_element?(view, "#pool-contribution-chart-bars[data-chart='pool-contribution']")

    assert has_element?(
             view,
             "#pool-contribution-chart-bars[data-chart-state='no_successful_requests']"
           )

    assert has_element?(view, "#pool-contribution-chart-bars[data-chart-total='0']")
    assert has_element?(view, "#pool-contribution-chart", "0 successful requests")
    assert has_element?(view, "#pool-contribution-chart", "No successful request contribution")
    assert has_element?(view, "#pool-contribution-chart-summary.sr-only", "0 successful requests")

    for assignment <- [active_assignment, disabled_assignment] do
      assert has_element?(
               view,
               "#pool-contribution-chart-item-#{assignment.id}[data-chart-value='0']"
             )

      assert has_element?(
               view,
               "#pool-contribution-chart-item-#{assignment.id}-bar[value='0'][max='100']"
             )
    end
  end

  @tag :recent_events
  test "recent events merge target request failures retries and direct upstream audit rows", %{
    scope: scope,
    user: user
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "recent-events-target", name: "Recent Events Target"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recent events target",
        assignment_label: "Recent events target assignment"
      })

    %{identity: unrelated_identity, assignment: unrelated_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recent events unrelated",
        assignment_label: "Recent events unrelated assignment"
      })

    assert {:ok, newest_audit} =
             Audit.record_user_event(user, %{
               pool_id: pool.id,
               action: "upstream_account.pause",
               target_type: "upstream_identity",
               target_id: identity.id,
               occurred_at: DateTime.add(now, -1, :minute),
               details: %{"safe" => "target-audit-newest"}
             })

    failed_request =
      recent_event_request_fixture(pool, assignment, %{
        status: "failed",
        admitted_at: DateTime.add(now, -2, :minute),
        correlation_id: "recent-events-target-failed"
      })

    retried_request =
      recent_event_request_fixture(pool, assignment, %{
        status: "succeeded",
        admitted_at: DateTime.add(now, -3, :minute),
        correlation_id: "recent-events-target-retried",
        attempt_count: 2
      })

    for index <- 4..9 do
      assert {:ok, _event} =
               Audit.record_user_event(user, %{
                 pool_id: pool.id,
                 action: "upstream_account.refresh_enqueue",
                 target_type: "upstream_identity",
                 target_id: identity.id,
                 occurred_at: DateTime.add(now, -index, :minute),
                 details: %{"safe" => "target-audit-#{index}"}
               })
    end

    assert {:ok, _unrelated_audit} =
             Audit.record_user_event(user, %{
               pool_id: pool.id,
               action: "upstream_account.delete",
               target_type: "upstream_identity",
               target_id: unrelated_identity.id,
               occurred_at: DateTime.add(now, 1, :minute),
               details: %{"safe" => "unrelated-newer-audit"}
             })

    recent_event_request_fixture(pool, unrelated_assignment, %{
      status: "failed",
      admitted_at: DateTime.add(now, 2, :minute),
      correlation_id: "unrelated-newer-failed-request"
    })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    events = cockpit.recent_events.items

    assert cockpit.recent_events.count == 8
    assert cockpit.recent_events.empty? == false
    assert cockpit.recent_events.missing? == false
    assert cockpit.sections.recent_events.empty? == false

    assert Enum.map(events, & &1.timestamp) ==
             Enum.sort_by(
               Enum.map(events, & &1.timestamp),
               &DateTime.to_unix(&1, :microsecond),
               :desc
             )

    assert Enum.all?(events, fn event ->
             MapSet.new(Map.keys(event)) ==
               MapSet.new([:timestamp, :source, :title, :subtitle, :link])
           end)

    assert hd(events) == %{
             timestamp: newest_audit.occurred_at,
             source: "audit_log",
             title: "Upstream account paused",
             subtitle: "Success · upstream identity #{String.slice(identity.id, 0, 8)}",
             link: "/admin/audit-logs?target=#{identity.id}"
           }

    assert Enum.any?(events, fn event ->
             event.source == "request_log" and event.title == "Request failed" and
               event.timestamp == failed_request.request.admitted_at and
               event.link ==
                 "/admin/request-logs?request_id=#{failed_request.request.id}&upstream_identity_id=#{identity.id}"
           end)

    assert Enum.any?(events, fn event ->
             event.source == "request_log" and event.title == "Request retried" and
               event.timestamp == retried_request.request.admitted_at and
               event.subtitle =~ "2 attempts"
           end)

    refute Enum.any?(events, &(&1.timestamp == DateTime.add(now, -9, :minute)))

    inspected_events = inspect(cockpit.recent_events)
    refute inspected_events =~ unrelated_identity.id
    refute inspected_events =~ "Recent events unrelated"
    refute inspected_events =~ "unrelated-newer-audit"
    refute inspected_events =~ "unrelated-newer-failed-request"
  end

  @tag :recent_events_privacy
  test "recent events exclude unrelated rows and never carry raw request or audit details", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "recent-events-privacy", name: "Recent Events Privacy"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recent events privacy target",
        assignment_label: "Recent events privacy assignment"
      })

    %{identity: unrelated_identity, assignment: unrelated_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recent events privacy unrelated",
        assignment_label: "Recent events privacy unrelated assignment"
      })

    prompt_secret = runtime_secret("recent-events-prompt")
    body_secret = runtime_secret("recent-events-body")
    cookie_secret = runtime_secret("recent-events-cookie")
    debug_secret = runtime_secret("recent-events-debug")
    bearer_secret = runtime_secret("recent-events-bearer")
    token_secret = runtime_secret("recent-events-token")
    audit_secret = runtime_secret("recent-events-audit-detail")
    unrelated_secret = runtime_secret("recent-events-unrelated")

    recent_event_request_fixture(pool, assignment, %{
      status: "failed",
      admitted_at: DateTime.add(DateTime.utc_now(), -1, :minute),
      correlation_id: "recent-events-privacy-target",
      request_metadata: %{
        "prompt" => prompt_secret,
        "body" => %{"input" => body_secret},
        "cookie" => "session=#{cookie_secret}",
        "debug" => %{"payload" => debug_secret},
        "authorization" => "Bearer #{bearer_secret}",
        "token" => token_secret
      },
      attempt_response_metadata: %{
        "body" => %{"output" => body_secret},
        "cookie" => "session=#{cookie_secret}",
        "debug" => %{"payload" => debug_secret}
      }
    })

    assert {:ok, _audit} =
             Audit.record_user_event(user, %{
               pool_id: pool.id,
               action: "upstream_account.refresh_enqueue",
               target_type: "upstream_identity",
               target_id: identity.id,
               details: %{
                 "prompt" => prompt_secret,
                 "request_body" => body_secret,
                 "cookie" => cookie_secret,
                 "debug_payload" => debug_secret,
                 "authorization" => "Bearer #{bearer_secret}",
                 "access_token" => token_secret,
                 "safe" => audit_secret
               }
             })

    recent_event_request_fixture(pool, unrelated_assignment, %{
      status: "failed",
      admitted_at: DateTime.utc_now(),
      correlation_id: "recent-events-privacy-unrelated-request",
      request_metadata: %{"safe" => unrelated_secret}
    })

    assert {:ok, _unrelated_audit} =
             Audit.record_user_event(user, %{
               pool_id: pool.id,
               action: "upstream_account.delete",
               target_type: "upstream_identity",
               target_id: unrelated_identity.id,
               details: %{"safe" => unrelated_secret}
             })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    rendered = render(view)
    inspected_cockpit = inspect(cockpit)
    inspected_events = inspect(cockpit.recent_events)

    assert cockpit.recent_events.count == 2
    assert Enum.all?(cockpit.recent_events.items, &(&1.source in ["request_log", "audit_log"]))

    for forbidden <- [
          prompt_secret,
          body_secret,
          cookie_secret,
          debug_secret,
          bearer_secret,
          token_secret,
          audit_secret,
          unrelated_secret,
          unrelated_identity.id,
          "Recent events privacy unrelated",
          "recent-events-privacy-unrelated-request"
        ] do
      refute inspected_cockpit =~ forbidden
      refute inspected_events =~ forbidden
      refute rendered =~ forbidden
    end
  end

  @tag :recent_events_ui
  test "renders compact recent event rows with exact deep links and safe fields", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "recent-events-ui", name: "Recent Events UI"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recent events UI target",
        assignment_label: "Recent events UI assignment"
      })

    prompt_secret = runtime_secret("recent-events-ui-prompt")
    body_secret = runtime_secret("recent-events-ui-body")
    cookie_secret = runtime_secret("recent-events-ui-cookie")
    bearer_secret = runtime_secret("recent-events-ui-bearer")
    audit_secret = runtime_secret("recent-events-ui-audit")

    assert {:ok, _audit} =
             Audit.record_user_event(user, %{
               pool_id: pool.id,
               action: "upstream_account.pause",
               target_type: "upstream_identity",
               target_id: identity.id,
               occurred_at: DateTime.add(now, -1, :minute),
               details: %{
                 "prompt" => prompt_secret,
                 "request_body" => body_secret,
                 "cookie" => cookie_secret,
                 "authorization" => "Bearer #{bearer_secret}",
                 "safe" => audit_secret
               }
             })

    failed_request =
      recent_event_request_fixture(pool, assignment, %{
        status: "failed",
        admitted_at: DateTime.add(now, -2, :minute),
        correlation_id: "recent-events-ui-failed",
        request_metadata: %{
          "prompt" => prompt_secret,
          "body" => %{"input" => body_secret},
          "cookie" => "session=#{cookie_secret}",
          "authorization" => "Bearer #{bearer_secret}"
        }
      })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    [audit_event, request_event] = cockpit.recent_events.items

    assert audit_event.source == "audit_log"
    assert request_event.source == "request_log"

    assert request_event.link ==
             "/admin/request-logs?request_id=#{failed_request.request.id}&upstream_identity_id=#{identity.id}"

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#upstream-event-summary")
    assert has_element?(view, "#upstream-event-summary [data-role='recent-event-row']")

    assert has_element?(view, "#upstream-event-summary-row-1[data-role='recent-event-row']")

    assert has_element?(
             view,
             "#upstream-event-summary-row-1 [data-role='recent-event-source']",
             "audit log"
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-1 [data-role='recent-event-title']",
             audit_event.title
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-1 [data-role='recent-event-subtitle']",
             audit_event.subtitle
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-1 [data-role='recent-event-timestamp']",
             event_timestamp_label(audit_event, user)
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-1 [data-role='recent-event-link'][href='#{audit_event.link}']"
           )

    assert has_element?(view, "#upstream-event-summary-row-2[data-role='recent-event-row']")

    assert has_element?(
             view,
             "#upstream-event-summary-row-2 [data-role='recent-event-source']",
             "request log"
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-2 [data-role='recent-event-title']",
             request_event.title
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-2 [data-role='recent-event-subtitle']",
             request_event.subtitle
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-2 [data-role='recent-event-timestamp']",
             event_timestamp_label(request_event, user)
           )

    assert has_element?(
             view,
             "#upstream-event-summary-row-2 [data-role='recent-event-link'][href='#{request_event.link}']"
           )

    assert has_element?(
             view,
             "#upstream-event-summary-request-logs-link[href='/admin/request-logs?upstream_identity_id=#{identity.id}']"
           )

    assert has_element?(
             view,
             "#upstream-event-summary-audit-logs-link[href='/admin/audit-logs?target=#{identity.id}']"
           )

    assert has_element?(view, "#upstream-event-summary", "manual audit filtering")
    assert has_element?(view, "#upstream-event-summary", identity.id)

    rendered = render(view)

    assert_ordered_ids(rendered, [
      "upstream-event-summary-row-1",
      "upstream-event-summary-row-2"
    ])

    for forbidden <- [prompt_secret, body_secret, cookie_secret, bearer_secret, audit_secret] do
      refute rendered =~ forbidden
    end
  end

  @tag :recent_events_ui_empty
  test "renders recent events empty state with safe footer links", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "recent-events-ui-empty", name: "Recent Events UI Empty"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recent events empty target",
        assignment_label: "Recent events empty assignment"
      })

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    assert cockpit.recent_events.items == []

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#upstream-event-summary")
    assert has_element?(view, "#upstream-event-summary-empty")
    assert has_element?(view, "#upstream-event-summary-empty", "No recent upstream events")
    refute has_element?(view, "#upstream-event-summary [data-role='recent-event-row']")

    assert has_element?(
             view,
             "#upstream-event-summary-request-logs-link[href='/admin/request-logs?upstream_identity_id=#{identity.id}']"
           )

    assert has_element?(
             view,
             "#upstream-event-summary-audit-logs-link[href='/admin/audit-logs?target=#{identity.id}']"
           )

    assert has_element?(view, "#upstream-event-summary", "manual audit filtering")
    assert has_element?(view, "#upstream-event-summary", identity.id)
    refute has_element?(view, "#upstream-event-summary a[href='']")
  end

  @tag :refresh_action
  test "manual refresh reloads cockpit data through the visible read model", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "refresh-action",
        name: "Refresh Action"
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Refresh action target",
        assignment_label: "Refresh action assignment"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#upstream-refresh-data")
    assert has_element?(view, "#upstream-refresh-data-button", "Refresh cockpit data")
    assert has_element?(view, "#upstream-cockpit-header", "Refresh action target")
    assert has_element?(view, "#request-health-chart-plot[data-chart-total='0']")

    identity
    |> Ecto.Changeset.change(%{account_label: "Refresh action reloaded"})
    |> Repo.update!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    failed_request =
      recent_event_request_fixture(pool, assignment, %{
        status: "failed",
        admitted_at: DateTime.add(now, -1, :minute),
        correlation_id: "refresh-action-failed"
      })

    assert has_element?(view, "#upstream-cockpit-header", "Refresh action target")
    assert has_element?(view, "#request-health-chart-plot[data-chart-total='0']")

    view |> element("#upstream-refresh-data-button") |> render_click()

    assert has_element?(view, "#upstream-cockpit-header", "Refresh action reloaded")
    assert has_element?(view, "#request-health-chart-plot[data-chart-total='1']")

    assert has_element?(
             view,
             "#upstream-event-summary [data-role='recent-event-link'][href='/admin/request-logs?request_id=#{failed_request.request.id}&upstream_identity_id=#{identity.id}']"
           )

    assert has_element?(view, "#upstream-refresh-data", "Cockpit data refreshed")
  end

  @tag :refresh_broadcast_degraded
  test "supported upstream broadcasts refresh quota while request metrics stay explicit-refresh only",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "refresh-broadcast-target",
        name: "Refresh Broadcast Target"
      })

    {:ok, unrelated_pool} =
      Pools.create_pool(scope, %{
        slug: "refresh-broadcast-unrelated",
        name: "Refresh Broadcast Unrelated"
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Refresh broadcast target",
        assignment_label: "Refresh broadcast assignment"
      })

    %{identity: unrelated_identity} =
      upstream_assignment_fixture(unrelated_pool, %{
        account_label: "Refresh broadcast unrelated",
        assignment_label: "Refresh broadcast unrelated assignment"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#quota-health-chart-item-#{assignment.id}[data-chart-value='0']")
    assert has_element?(view, "#request-health-chart-plot[data-chart-total='0']")

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    upsert_quota_window!(unrelated_identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 91,
      used_percent: Decimal.new("9"),
      reset_at: DateTime.add(now, 3, :hour),
      observed_at: now
    })

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#quota-health-chart-item-#{assignment.id}[data-chart-value='0']")

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 64,
      used_percent: Decimal.new("36"),
      reset_at: DateTime.add(now, 4, :hour),
      observed_at: now
    })

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#quota-health-chart-item-#{assignment.id}[data-chart-value='64']")

    request_health_request_fixture(pool, assignment, %{
      status: "succeeded",
      admitted_at: DateTime.add(now, -2, :minute),
      correlation_id: "refresh-broadcast-request"
    })

    assert {:ok, _event} =
             Events.broadcast_request_logs(pool.id, "request_log_created", %{
               upstream_identity_id: identity.id
             })

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#request-health-chart-plot[data-chart-total='0']")

    assert has_element?(
             view,
             "#request-health-chart",
             "Request health, recent events, and contribution metrics refresh only when this cockpit is reloaded."
           )

    view |> element("#upstream-refresh-data-button") |> render_click()

    assert has_element?(view, "#request-health-chart-plot[data-chart-total='1']")
  end

  @tag :cockpit_actions
  test "cockpit actions mutate account, refresh the read model, and keep secrets redacted", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "cockpit-actions", name: "Cockpit Actions"})

    raw_stored_account_id = "acct-cockpit-actions-#{System.unique_integer([:positive])}"
    original_access_token = runtime_secret("cockpit-actions-access")
    original_refresh_token = runtime_secret("cockpit-actions-refresh")
    replacement_access_token = jwt_token(%{"exp" => future_unix(), "source" => "cockpit-actions"})
    replacement_refresh_token = runtime_secret("cockpit-actions-replacement-refresh")
    cookie_secret = runtime_secret("cockpit-actions-cookie")
    prompt_secret = runtime_secret("cockpit-actions-prompt")
    request_body_secret = runtime_secret("cockpit-actions-request-body")
    idempotency_key = runtime_secret("cockpit-actions-idempotency")

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Action Target Codex",
        chatgpt_account_id: raw_stored_account_id,
        identity_status: "refresh_failed",
        identity_metadata: %{
          "access_token_expires_at" =>
            DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.to_iso8601(),
          "token_refresh" => %{
            "status" => "failed",
            "reason" => %{
              "code" => "refresh_token_revoked",
              "message" => "refresh token rejected"
            }
          },
          "cookie" => cookie_secret,
          "prompt" => prompt_secret,
          "request_body" => request_body_secret,
          "idempotency_key" => idempotency_key
        }
      })

    for {kind, plaintext} <- [
          {"access_token", original_access_token},
          {"refresh_token", original_refresh_token},
          {"web_session", cookie_secret},
          {"other", prompt_secret}
        ] do
      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: kind,
                 plaintext: plaintext
               })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    assert has_element?(view, "#cockpit-rename-upstream-account-#{identity.id}", "Rename")
    assert has_element?(view, "#cockpit-pause-upstream-account-#{identity.id}", "Pause")
    assert has_element?(view, "#cockpit-refresh-upstream-account-#{identity.id}", "Refresh token")

    assert has_element?(
             view,
             "#cockpit-replace-auth-json-upstream-account-#{identity.id}",
             "Replace auth.json"
           )

    assert has_element?(view, "#cockpit-delete-upstream-account-#{identity.id}", "Delete")
    assert has_element?(view, "#cockpit-reactivate-upstream-account-#{identity.id}", "Reactivate")

    view |> element("#cockpit-rename-upstream-account-#{identity.id}") |> render_click()
    assert has_element?(view, "#cockpit-rename-upstream-account-dialog[open]")
    assert_admin_dialog_docs_link(view, "cockpit-rename-upstream-account-dialog-footer")

    view
    |> element("#cockpit-rename-upstream-account-form")
    |> render_submit(%{"rename" => %{"account_label" => " Renamed Cockpit Codex "}})

    refute has_element?(view, "#cockpit-rename-upstream-account-dialog")
    assert has_element?(view, "#upstream-cockpit-header", "Renamed Cockpit Codex")
    assert Repo.get!(UpstreamIdentity, identity.id).account_label == "Renamed Cockpit Codex"

    view
    |> element("#cockpit-replace-auth-json-upstream-account-#{identity.id}")
    |> render_click()

    assert has_element?(view, "#auth-json-import-dialog[open]")
    assert_admin_dialog_docs_link(view, "auth-json-import-dialog-footer")

    replacement_auth_json =
      auth_json_fixture(
        account_id: raw_stored_account_id,
        access_token: replacement_access_token,
        refresh_token: replacement_refresh_token,
        email: "cockpit-actions-replaced@example.com"
      )

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{
      "auth_json" => %{"pool_id" => pool.id, "content" => replacement_auth_json}
    })

    refute has_element?(view, "#auth-json-import-dialog")
    assert has_element?(view, "#upstream-cockpit-header", "Renamed Cockpit Codex")
    assert Repo.get!(UpstreamIdentity, identity.id).status == "active"

    view |> element("#cockpit-pause-upstream-account-#{identity.id}") |> render_click()
    assert has_element?(view, "#upstream-cockpit-header", "paused")
    assert Repo.get!(UpstreamIdentity, identity.id).status == "paused"

    view |> element("#cockpit-reactivate-upstream-account-#{identity.id}") |> render_click()
    assert has_element?(view, "#upstream-cockpit-header", "active")
    assert Repo.get!(UpstreamIdentity, identity.id).status == "active"

    view |> element("#cockpit-refresh-upstream-account-#{identity.id}") |> render_click()

    assert %Oban.Job{} =
             job =
             Repo.all(Oban.Job)
             |> Enum.find(&(&1.args["trigger_kind"] == "admin_upstream_cockpit_live"))

    assert job.args["upstream_identity_id"] == identity.id

    rendered_before_delete = render(view)

    for forbidden <- [
          raw_stored_account_id,
          original_access_token,
          original_refresh_token,
          replacement_access_token,
          replacement_refresh_token,
          replacement_auth_json,
          cookie_secret,
          prompt_secret,
          request_body_secret,
          idempotency_key
        ] do
      refute rendered_before_delete =~ forbidden
      refute inspect(Repo.all(CodexPooler.Audit.AuditEvent)) =~ forbidden
      refute inspect(Repo.all(Oban.Job)) =~ forbidden
    end

    view |> element("#cockpit-delete-upstream-account-#{identity.id}") |> render_click()
    assert has_element?(view, "#cockpit-delete-upstream-account-dialog[open]")
    assert_admin_dialog_docs_link(view, "cockpit-delete-upstream-account-dialog-footer")

    view
    |> element("#cockpit-delete-upstream-account-form")
    |> render_submit(%{
      "upstream_delete" => %{
        "id" => identity.id,
        "confirmation_label" => "Renamed Cockpit Codex"
      }
    })

    assert_redirect(view, ~p"/admin/upstreams")
    assert Repo.get!(UpstreamIdentity, identity.id).status == "deleted"
  end

  @tag :cockpit_actions_error
  test "cockpit action failures preserve prior state and redact submitted secret material", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "cockpit-action-errors", name: "Cockpit Action Errors"})

    raw_stored_account_id = "acct-cockpit-errors-#{System.unique_integer([:positive])}"
    access_token = runtime_secret("cockpit-errors-access")
    refresh_token = runtime_secret("cockpit-errors-refresh")
    invalid_auth_json_secret = runtime_secret("cockpit-errors-invalid-auth-json")
    cookie_secret = runtime_secret("cockpit-errors-cookie")
    api_key_secret = runtime_secret("cockpit-errors-api-key")

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Error Target Codex",
        chatgpt_account_id: raw_stored_account_id,
        identity_status: "refresh_failed",
        identity_metadata: %{
          "access_token_expires_at" =>
            DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.to_iso8601(),
          "token_refresh" => %{
            "status" => "failed",
            "reason" => %{
              "code" => "refresh_token_revoked",
              "message" => "refresh token rejected"
            }
          },
          "cookie" => cookie_secret,
          "api_key" => api_key_secret
        }
      })

    for {kind, plaintext} <- [
          {"access_token", access_token},
          {"refresh_token", refresh_token},
          {"web_session", cookie_secret},
          {"api_key", api_key_secret}
        ] do
      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: kind,
                 plaintext: plaintext
               })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    view |> element("#cockpit-rename-upstream-account-#{identity.id}") |> render_click()

    view
    |> element("#cockpit-rename-upstream-account-form")
    |> render_submit(%{"rename" => %{"account_label" => " "}})

    assert has_element?(view, "#cockpit-rename-upstream-account-dialog[open]")
    assert has_element?(view, "#cockpit-rename-upstream-account-form", "can't be blank")
    assert has_element?(view, "#upstream-cockpit-header", "Error Target Codex")
    assert Repo.get!(UpstreamIdentity, identity.id).account_label == "Error Target Codex"

    view |> element("#cockpit-rename-upstream-account-cancel") |> render_click()
    refute has_element?(view, "#cockpit-rename-upstream-account-dialog")

    view
    |> element("#cockpit-replace-auth-json-upstream-account-#{identity.id}")
    |> render_click()

    invalid_auth_json = Jason.encode!(%{"OPENAI_API_KEY" => invalid_auth_json_secret})

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{"auth_json" => %{"pool_id" => pool.id, "content" => invalid_auth_json}})

    assert has_element?(view, "#auth-json-import-dialog[open]")

    assert has_element?(
             view,
             "#auth-json-import-form",
             "Codex API-key auth.json is not supported"
           )

    assert Repo.get!(UpstreamIdentity, identity.id).status == "refresh_failed"

    view |> element("#auth-json-import-cancel") |> render_click()
    refute has_element?(view, "#auth-json-import-dialog")

    view |> element("#cockpit-delete-upstream-account-#{identity.id}") |> render_click()
    assert has_element?(view, "#cockpit-delete-upstream-account-dialog[open]")

    view
    |> element("#cockpit-delete-upstream-account-form")
    |> render_submit(%{
      "upstream_delete" => %{
        "id" => identity.id,
        "confirmation_label" => "wrong label"
      }
    })

    assert has_element?(view, "#cockpit-delete-upstream-account-dialog[open]")

    assert has_element?(
             view,
             "#cockpit-delete-upstream-account-form",
             "type the account label exactly"
           )

    assert Repo.get!(UpstreamIdentity, identity.id).status == "refresh_failed"

    html = render_click(view, "pause_account", %{"id" => Ecto.UUID.generate()})
    assert html =~ "Upstream account was not found"
    assert Repo.get!(UpstreamIdentity, identity.id).status == "refresh_failed"

    rendered = render(view)

    for forbidden <- [
          raw_stored_account_id,
          access_token,
          refresh_token,
          invalid_auth_json_secret,
          invalid_auth_json,
          cookie_secret,
          api_key_secret
        ] do
      refute rendered =~ forbidden
      refute inspect(Repo.all(CodexPooler.Audit.AuditEvent)) =~ forbidden
    end
  end

  @tag :privacy_header
  test "read model and rendered cockpit omit encrypted upstream secret plaintext", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "privacy-cockpit", name: "Privacy Cockpit"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Privacy Codex",
        chatgpt_account_id: "privacy-user@example.com"
      })

    sensitive_values = [
      runtime_secret("access-token"),
      runtime_secret("refresh-token"),
      runtime_secret("auth-json"),
      runtime_secret("cookie"),
      runtime_secret("prompt"),
      runtime_secret("request-body"),
      runtime_secret("api-key"),
      runtime_secret("idempotency-key")
    ]

    for {kind, value} <-
          Enum.zip(
            ~w(access_token refresh_token web_session device_code api_key other access_token refresh_token),
            sensitive_values
          ) do
      {:ok, _secret} =
        Upstreams.store_encrypted_secret(identity, %{
          secret_kind: kind,
          plaintext: value
        })
    end

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    inspected_cockpit = inspect(cockpit)

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    rendered = render(view)

    for sensitive_value <- sensitive_values do
      refute inspected_cockpit =~ sensitive_value
      refute rendered =~ sensitive_value
    end

    refute inspected_cockpit =~ "privacy-user@example.com"
    refute rendered =~ "privacy-user@example.com"
    assert cockpit.identity.safe_account_id_label =~ "stored account id "
    assert rendered =~ "stored account id "
  end

  defp status_fixture!(scope, slug_suffix, attrs) do
    unique = System.unique_integer([:positive])

    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "status-#{slug_suffix}-#{unique}",
        name: "Status #{slug_suffix}"
      })

    upstream_assignment_fixture(
      pool,
      Map.merge(
        %{
          account_label: "Status #{slug_suffix} Codex",
          assignment_label: "Status #{slug_suffix} assignment"
        },
        attrs
      )
    )
  end

  defp request_health_cockpit!(scope, slug_suffix, request_specs) do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "request-health-#{slug_suffix}-#{System.unique_integer([:positive])}",
        name: "Request health #{slug_suffix}"
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Request health #{slug_suffix} Codex",
        assignment_label: "Request health #{slug_suffix} assignment"
      })

    Enum.each(request_specs, &request_health_request_fixture(pool, assignment, &1))

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    cockpit
  end

  defp recent_event_request_fixture(pool, assignment, attrs) do
    attempt_count = Map.get(attrs, :attempt_count, 1)
    result = request_health_request_fixture(pool, assignment, attrs)

    if attempt_count > 1 do
      for attempt_number <- 2..attempt_count do
        result.request
        |> attempt_fixture(assignment, %{
          attempt_number: attempt_number,
          status: Map.get(attrs, :extra_attempt_status, "failed"),
          completed_at: DateTime.add(Map.fetch!(attrs, :admitted_at), attempt_number, :second),
          upstream_status_code: Map.get(attrs, :extra_attempt_status_code, 502),
          response_metadata: Map.get(attrs, :extra_attempt_response_metadata, %{})
        })
        |> Ecto.Changeset.change(%{
          started_at: DateTime.add(Map.fetch!(attrs, :admitted_at), attempt_number - 1, :second),
          network_error_code:
            Map.get(attrs, :extra_attempt_network_error_code, "upstream_retryable_failure")
        })
        |> Repo.update!()
      end
    end

    result
  end

  defp request_health_request_fixture(pool, assignment, attrs) do
    %{api_key: api_key} = active_api_key_fixture(pool)
    admitted_at = Map.fetch!(attrs, :admitted_at)
    completed_at = Map.get(attrs, :completed_at, DateTime.add(admitted_at, 1, :second))
    status = Map.fetch!(attrs, :status)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: Map.get(attrs, :requested_model, "gpt-request-health"),
        endpoint: Map.get(attrs, :endpoint, "/backend-api/codex/responses"),
        transport: Map.get(attrs, :transport, "http_json"),
        status: status,
        usage_status: Map.get(attrs, :usage_status, "usage_known"),
        correlation_id:
          Map.get(attrs, :correlation_id, "request-health-#{System.unique_integer([:positive])}"),
        request_metadata: Map.get(attrs, :request_metadata, %{}),
        response_status_code: Map.get(attrs, :response_status_code, response_status_code(status)),
        last_error_code: Map.get(attrs, :last_error_code, request_error_code(status))
      })
      |> Ecto.Changeset.change(%{admitted_at: admitted_at, completed_at: completed_at})
      |> Repo.update!()

    attempt =
      request
      |> attempt_fixture(assignment, %{
        status: attempt_status(status),
        completed_at: completed_at,
        upstream_status_code: response_status_code(status),
        response_metadata: Map.get(attrs, :attempt_response_metadata, %{})
      })
      |> Ecto.Changeset.change(%{
        started_at: admitted_at,
        completed_at: completed_at,
        network_error_code:
          Map.get(attrs, :attempt_network_error_code, request_error_code(status))
      })
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      occurred_at: completed_at,
      usage_status:
        Map.get(attrs, :settlement_usage_status, Map.get(attrs, :usage_status, "usage_known"))
    })

    %{request: request, attempt: attempt}
  end

  defp request_health_bucket(cockpit, datetime) do
    bucket = datetime |> DateTime.to_date() |> Date.to_iso8601()
    Enum.find(cockpit.charts.request_health.items, &(&1.date == bucket))
  end

  defp attempt_status("succeeded"), do: "succeeded"
  defp attempt_status(_status), do: "failed"

  defp response_status_code("succeeded"), do: 200
  defp response_status_code("rejected"), do: 403
  defp response_status_code("cancelled"), do: 499
  defp response_status_code(_status), do: 502

  defp request_error_code("succeeded"), do: nil
  defp request_error_code("rejected"), do: "request_rejected"
  defp request_error_code("cancelled"), do: "request_cancelled"
  defp request_error_code(_status), do: "upstream_request_failed"

  defp quota_cockpit!(scope, slug_suffix, quota_windows) do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "quota-#{slug_suffix}-#{System.unique_integer([:positive])}",
        name: "Quota #{slug_suffix}"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Quota #{slug_suffix} Codex",
        assignment_label: "Quota #{slug_suffix} assignment"
      })

    Enum.each(quota_windows, &upsert_quota_window!(identity, &1))

    assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
    cockpit
  end

  defp upsert_quota_window!(identity, attrs) do
    attrs =
      Map.merge(
        %{
          quota_key: "account",
          source: "codex_usage",
          source_precision: "authoritative",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh"
        },
        attrs
      )

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
  end

  defp assert_ordered_ids(html, ordered_ids) do
    positions =
      Enum.map(ordered_ids, fn id ->
        case :binary.match(html, ~s(id="#{id}")) do
          {position, _length} -> position
          :nomatch -> flunk("expected #{id} to render before checking section order")
        end
      end)

    assert positions == Enum.sort(positions)
  end

  defp event_timestamp_label(%{timestamp: %DateTime{} = timestamp}, user),
    do: datetime_label(timestamp, user)

  defp datetime_label(%DateTime{} = timestamp, user) do
    user
    |> DateTimeDisplay.preferences_for_user()
    |> then(&DateTimeDisplay.format_datetime(timestamp, &1))
  end

  defp auth_json_fixture(opts) do
    email = Keyword.get(opts, :email, "fixture-user@example.com")
    account_id = Keyword.get(opts, :account_id, "acct_fixture_auth_json")

    tokens = %{
      "id_token" =>
        jwt_token(%{
          "email" => email,
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_fixture_auth_json",
            "chatgpt_plan_type" => "pro"
          }
        }),
      "access_token" => Keyword.fetch!(opts, :access_token),
      "refresh_token" => Keyword.fetch!(opts, :refresh_token),
      "account_id" => account_id
    }

    %{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => tokens,
      "last_refresh" => "2026-05-03T00:00:00Z"
    }
    |> Jason.encode!()
  end

  defp jwt_token(payload) do
    header = %{"alg" => "none", "typ" => "JWT"}
    encode = &Base.url_encode64(Jason.encode!(&1), padding: false)

    Enum.join([encode.(header), encode.(payload), Base.url_encode64("sig", padding: false)], ".")
  end

  defp future_unix, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()

  defp runtime_secret(label),
    do: Enum.join(["admin", label, "secret", "do", "not", "render"], "-")

  defp active_secret_count(secret_kind) do
    Repo.aggregate(
      from(secret in EncryptedSecret,
        where: secret.secret_kind == ^secret_kind and secret.status == "active"
      ),
      :count
    )
  end

  defp open_oauth_relink_dialog(view, identity_id) do
    view
    |> element("#cockpit-oauth-relink-upstream-account-#{identity_id}")
    |> render_click()
  end

  defp start_oauth_provider!(routes) do
    {:ok, provider} = FakeOpenAIAuthProvider.start_link(routes)
    Application.put_env(:codex_pooler, CodexAuth, issuer: FakeOpenAIAuthProvider.url(provider))
    on_exit(fn -> FakeOpenAIAuthProvider.stop(provider) end)
    provider
  end

  defp device_routes(extra_routes) do
    Map.merge(
      %{
        "/api/accounts/deviceauth/usercode" =>
          {200,
           FakeOpenAIAuthProvider.device_code_response(
             device_auth_id: "cockpit-device-auth-ui",
             user_code: "COCKPIT-CODE",
             interval: 5,
             expires_at: DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.to_iso8601()
           )}
      },
      extra_routes
    )
  end

  defp oauth_id_token(account_id, workspace_id) do
    FakeOpenAIAuthProvider.id_token(%{
      "email" => "#{account_id}@example.com",
      "https://api.openai.com/auth" => %{
        "chatgpt_account_id" => account_id,
        "chatgpt_user_id" => "user_#{account_id}",
        "chatgpt_plan_type" => "team",
        "workspace_id" => workspace_id,
        "workspace_label" => "Cockpit Workspace",
        "seat_type" => "team-seat"
      }
    })
  end

  defp oauth_relink_authorization_url_from_view(view) do
    case Regex.run(~r/id="oauth-relink-authorization-url"[^>]*href="([^"]+)"/, render(view)) do
      [_match, authorization_url] -> String.replace(authorization_url, "&amp;", "&")
      _missing -> flunk("missing OAuth relink authorization URL")
    end
  end

  defp authorization_state(authorization_url) do
    authorization_url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("state")
  end

  defp callback_url(state, code) do
    "http://localhost:1455/auth/callback?" <>
      URI.encode_query(%{"state" => state, "code" => code})
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end

  defp restore_codex_auth_config! do
    previous = Application.get_env(:codex_pooler, CodexAuth)

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexAuth, previous)
      else
        Application.delete_env(:codex_pooler, CodexAuth)
      end
    end)
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

  defp assert_oauth_dialog_docs_link(view, footer_id) do
    assert has_element?(
             view,
             "##{footer_id} [data-role='admin-dialog-docs-link'][href='https://docs.codex-pooler.com/operators/upstreams/#openai-oauth-upstream-linking'][target='_blank'][rel='noopener noreferrer'].text-xs",
             "Docs"
           )

    assert has_element?(
             view,
             "##{footer_id}-docs-link [data-role='admin-dialog-docs-icon']"
           )
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
