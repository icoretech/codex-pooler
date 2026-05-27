defmodule CodexPoolerWeb.Admin.UpstreamsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Secrets, as: Secrets

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Mailer
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.PrimingState
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountCard

  setup :register_and_log_in_user

  setup do
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
    Application.delete_env(:swoosh, :local)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
      Application.delete_env(:swoosh, :local)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    Repo.delete_all(Oban.Job)
    :ok
  end

  test "shared dropdown action item renders button and link modes" do
    button_attrs =
      Map.merge(
        %{id: "test-dropdown-button", icon: "hero-check", label: "Button action"},
        %{"phx-click" => "select", "phx-value-pool-id" => "pool-1"}
      )

    button_html =
      render_component(&AdminComponents.dropdown_action_item/1, button_attrs)

    assert button_html =~ ~s(<button)
    assert button_html =~ ~s(id="test-dropdown-button")
    assert button_html =~ ~s(type="button")
    assert button_html =~ ~s(phx-click="select")
    assert button_html =~ ~s(phx-value-pool-id="pool-1")

    link_html =
      render_component(&AdminComponents.dropdown_action_item/1,
        id: "test-dropdown-link",
        icon: "hero-link",
        label: "Link action",
        navigate: ~p"/admin/invites?create=1"
      )

    assert link_html =~ ~s(<a)
    assert link_html =~ ~s(id="test-dropdown-link")
    assert link_html =~ ~s(href="/admin/invites?create=1")
    assert link_html =~ ~s(data-phx-link="redirect")
  end

  test "guides operators to create a Pool before upstream accounts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-page-create-pool[href='/admin/pools']",
             "Create Pool"
           )

    refute has_element?(view, "#upstream-account-form")
    refute has_element?(view, "#upstream-page-import-auth-json-action")
    refute has_element?(view, "#auth-json-import-dialog")
    refute has_element?(view, "#pool-invite-form")

    assert has_element?(view, "#upstream-account-empty-state", "No Pools Found")

    assert has_element?(
             view,
             "#upstream-account-empty-state",
             "Create a Pool before importing upstream auth.json."
           )

    assert has_element?(view, "#upstream-empty-create-pool[href='/admin/pools']", "Create Pool")
  end

  test "renders a clear empty state when a Pool exists without upstream accounts", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _pool} = Pools.create_pool(scope, %{slug: "empty-upstreams", name: "Empty Upstreams"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    refute has_element?(view, "#upstream-account-form")
    refute has_element?(view, "#upstream-account-submit")
    assert has_element?(view, "#upstream-page-import-auth-json-action", "Import auth.json")
    refute has_element?(view, "#upstream-page-create-invite-action")
    refute has_element?(view, "#auth-json-import-dialog")
    refute has_element?(view, "#pool-invite-dialog")
    refute has_element?(view, "#pool-invite-form")
    refute has_element?(view, "#upstream-account-page-create-pool")

    assert has_element?(view, "#upstream-account-empty-state", "No upstream accounts")
    assert has_element?(view, "#upstream-account-empty-state .hero-cloud-arrow-up")

    assert has_element?(
             view,
             "#upstream-account-empty-state",
             "Import upstream auth.json to connect an account to a Pool."
           )
  end

  test "renders required forms, account cards, limits, badges, and action selectors", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "admin-upstreams", name: "Admin Upstreams"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Primary Codex",
        assignment_label: "Primary assignment",
        plan_label: "Team",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "test"
          }
        }
      })

    %{identity: browser_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Browser linked Codex",
        onboarding_method: "invite",
        identity_metadata: %{"onboarding_method" => "browser"}
      })

    {:ok, _secret} =
      Upstreams.store_encrypted_secret(identity, %{
        secret_kind: "access_token",
        plaintext: runtime_secret("selector")
      })

    now = DateTime.utc_now()

    assert {:ok, [_primary, _weekly, _spark_primary, _spark_weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 100,
                 credits: 64,
                 used_percent: Decimal.new("36"),
                 reset_at: DateTime.add(now, 4, :hour),
                 source: "codex_usage",
                 source_precision: "authoritative",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 500,
                 credits: 450,
                 used_percent: Decimal.new("10"),
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage",
                 source_precision: "authoritative",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 quota_key: "gpt_5_3_codex_spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 100,
                 credits: 45,
                 used_percent: Decimal.new("55"),
                 display_label: "GPT-5.3-Codex-Spark",
                 limit_name: "codex_other",
                 metered_feature: "codex_bengalfox",
                 source: "codex_usage",
                 source_precision: "authoritative",
                 quota_scope: "model",
                 model: "gpt-5.3-codex-spark",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 quota_key: "gpt_5_3_codex_spark",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 100,
                 credits: 90,
                 used_percent: Decimal.new("10"),
                 display_label: "GPT-5.3-Codex-Spark",
                 limit_name: "codex_other",
                 metered_feature: "codex_bengalfox",
                 source: "codex_usage",
                 source_precision: "authoritative",
                 quota_scope: "model",
                 model: "gpt-5.3-codex-spark",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    assert {:ok, [_used_percent_weekly]} =
             QuotaWindows.upsert_quota_windows(browser_identity, [
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("25"),
                 reset_at: DateTime.add(now, 5, :day),
                 source: "codex_usage",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#admin-upstreams-live")

    assert has_element?(
             view,
             "#upstream-account-page-header",
             "Import upstream auth.json, check readiness, and keep account access current."
           )

    refute has_element?(view, "#upstream-account-form")
    refute has_element?(view, "#account_account_label")
    refute has_element?(view, "#account_account_identifier")
    refute has_element?(view, "#upstream-account-submit")
    assert has_element?(view, "#upstream-page-import-auth-json-action")
    refute has_element?(view, "#auth-json-import-refresh-token-warning")
    refute has_element?(view, "#upstream-page-create-invite-action")
    refute has_element?(view, "#pool-invite-submit")
    refute has_element?(view, "#upstream-account-table")
    assert has_element?(view, "#upstream-account-grid")
    assert has_element?(view, "[data-role='upstream-account-card']")
    assert has_element?(view, "#upstream-account-#{identity.id}-plan-label", "Team")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-mail[href='/admin/upstreams/#{identity.id}']",
             "Primary Codex"
           )

    refute has_element?(view, "#upstream-account-#{identity.id}-cockpit-link")

    open_auth_json_import_dialog(view)

    assert has_element?(view, "#auth-json-import-dialog[open]")
    assert has_element?(view, "#auth-json-import-form")
    assert has_element?(view, "#auth-json-import-paste-panel")
    assert has_element?(view, "#auth-json-import-file-dropzone")
    assert has_element?(view, "#auth_json_pool_id")
    assert has_element?(view, "#auth_json_content")

    html = render(view)

    assert html =~ "Codex CLI or Codex Desktop auth.json"
    assert html =~ "Paste contents"
    assert html =~ "Use this when the file is already open."
    assert html =~ "Drop auth.json"
    assert html =~ "Upload auth.json up to 64 KB."
    assert html =~ "Codex Pooler becomes the refresh-token authority"
    assert html =~ "credential lineage"
    assert html =~ ~r/Do not keep using the same\s+auth\.json/
    assert html =~ "another Codex install, machine, or automation"
    assert html =~ ~r/refresh-token\s+rotation/
    assert html =~ "reauth_required"

    assert html =~
             ~r/id="auth-json-import-file-dropzone"[\s\S]+id="auth-json-import-refresh-token-warning"/

    refute has_element?(view, "#auth-json-import-refresh-token-warning input")
    refute has_element?(view, "#auth-json-import-refresh-token-warning input[type='checkbox']")
    assert has_element?(view, "#auth-json-import-file-input input[type='file']")
    assert has_element?(view, "#auth-json-import-submit")

    view |> element("#auth-json-import-cancel") |> render_click()
    refute has_element?(view, "#auth-json-import-dialog")

    assert has_element?(view, "#upstream-account-#{identity.id}", "Primary Codex")
    assert has_element?(view, "#upstream-account-#{identity.id}-mail", "Primary Codex")
    assert has_element?(view, "#upstream-account-#{identity.id}-state", "active")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id} header[data-role='upstream-account-card-header'].flex-row.items-start.justify-between"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id} [data-role='upstream-account-actions'].shrink-0.self-start #upstream-account-actions-menu-#{identity.id}"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id} header #upstream-account-#{identity.id}-routing-readiness",
             "Routing candidate · 1 Pool"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limits-summary.text-xs",
             "Lowest remaining: GPT-5.3-Codex-Spark 5h 45%"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn.text-right #upstream-account-#{identity.id}-token-burn-label",
             "TOKEN BURN"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn-value",
             "0"
           )

    refute has_element?(view, "#upstream-account-#{identity.id}", "refresh succeeded")

    refute has_element?(view, "#upstream-account-#{identity.id}", "Upstream account")
    refute has_element?(view, "#upstream-account-#{identity.id} .font-mono", identity.id)
    refute has_element?(view, "#upstream-account-#{identity.id}-secret")
    refute has_element?(view, "#upstream-account-#{identity.id}-source")
    refute has_element?(view, "#upstream-account-#{browser_identity.id}-source")

    refute render(view) =~ "manual import"

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{assignment.id}",
             "Admin Upstreams (admin-upstreams)"
           )

    assert has_element?(view, "#pause-upstream-account-#{identity.id}")
    assert has_element?(view, "#rename-upstream-account-#{identity.id}")
    assert has_element?(view, "#reactivate-upstream-account-#{identity.id}")
    refute has_element?(view, "#disconnect-upstream-account-#{identity.id}")
    assert has_element?(view, "#delete-upstream-account-#{identity.id}")
    assert has_element?(view, "#refresh-upstream-account-#{identity.id}")
    assert has_element?(view, "#upstream-account-actions-menu-#{identity.id}")
    refute has_element?(view, "#refresh-upstream-account-#{identity.id}[disabled]")

    assert has_element?(view, "#upstream-account-#{identity.id}-limits")
    refute has_element?(view, "#upstream-account-#{identity.id}-limits", "windows")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-primary_5h [data-role='upstream-limit-title']",
             "5h"
           )

    refute has_element?(view, "#upstream-account-#{identity.id}-limit-primary_5h", "5h remaining")

    assert has_element?(view, "#upstream-account-#{identity.id}-limit-primary_5h", "64%")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-primary_5h",
             "64 / 100 credits"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-weekly [data-role='upstream-limit-title']",
             "Weekly"
           )

    refute has_element?(view, "#upstream-account-#{identity.id}-limit-weekly", "Weekly remaining")

    assert has_element?(view, "#upstream-account-#{identity.id}-limit-weekly", "90%")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-weekly-reset",
             "reset in 5d 23h"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-weekly-progress.admin-live-progress[value='90']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300 [data-role='upstream-limit-title']",
             "GPT-5.3-Codex-Spark 5h"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300",
             "45%"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300-progress[value='45']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-secondary-10080 [data-role='upstream-limit-title']",
             "GPT-5.3-Codex-Spark Weekly"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-secondary-10080-reset"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-secondary-10080-progress[value='90']"
           )

    assert has_element?(view, "#upstream-account-#{browser_identity.id}-limit-weekly", "75%")

    refute has_element?(view, "#upstream-account-#{browser_identity.id}-limit-primary_5h")
    refute has_element?(view, "#upstream-account-#{browser_identity.id}-limit-weekly-count")
    assert has_element?(view, "#upstream-account-#{browser_identity.id}-limit-weekly-reset")

    assert has_element?(
             view,
             "#upstream-account-#{browser_identity.id}-limit-weekly-progress[value='75']"
           )
  end

  test "renames upstream account labels from the account actions menu", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "rename-upstream", name: "Rename Upstream"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Original Codex",
        account_identifier: "rename@example.com"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}", "Original Codex")
    assert has_element?(view, "#rename-upstream-account-#{identity.id}", "Rename")

    view
    |> element("#rename-upstream-account-#{identity.id}")
    |> render_click()

    assert has_element?(view, "#rename-upstream-account-dialog[open]", "Rename upstream account")
    assert has_element?(view, "#rename-upstream-account-form")
    assert has_element?(view, "#rename_account_label[value='Original Codex']")

    view
    |> element("#rename-upstream-account-form")
    |> render_submit(%{"rename" => %{"account_label" => " Renamed Codex "}})

    refute has_element?(view, "#rename-upstream-account-dialog")
    assert has_element?(view, "#upstream-account-#{identity.id}", "Renamed Codex")
    refute has_element?(view, "#upstream-account-#{identity.id}", "Original Codex")

    assert Repo.get!(UpstreamIdentity, identity.id).account_label == "Renamed Codex"
  end

  test "keeps rename dialog open when the label is blank", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "rename-validation", name: "Rename Validation"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Validation Codex",
        account_identifier: "validation@example.com"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    view
    |> element("#rename-upstream-account-#{identity.id}")
    |> render_click()

    view
    |> element("#rename-upstream-account-form")
    |> render_submit(%{"rename" => %{"account_label" => " "}})

    assert has_element?(view, "#rename-upstream-account-dialog[open]")
    assert has_element?(view, "#rename-upstream-account-form", "can't be blank")
    assert Repo.get!(UpstreamIdentity, identity.id).account_label == "Validation Codex"
  end

  test "renders explicit quota priming readiness states instead of blank routing candidates", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "quota-states", name: "Quota States"})

    cases = [
      {"unknown", "Quota pending", "Priming pending"},
      {"refreshing", "Quota reconciling", "Reconciling quota"},
      {"known", "Routing candidate", "Quota known"},
      {"weekly_only_probe", "Weekly quota probe", "Weekly-only probe"},
      {"stale", "Quota stale", "Quota stale"},
      {"expired", "Quota expired", "Quota expired"},
      {"failed", "Quota failed", "Quota failed"},
      {"blocked", "Quota blocked", "Priming blocked"}
    ]

    for {status, readiness_label, assignment_label} <- cases do
      %{identity: identity, assignment: assignment} =
        upstream_assignment_fixture(pool, %{
          account_label: "Quota #{status}",
          assignment_label: "Quota #{status} assignment",
          assignment_metadata: %{
            "quota_priming" => %{
              "status" => status,
              "trigger_kind" => "account_link",
              "enqueued_at" => "2026-05-22T00:00:00Z",
              "reason" => %{
                "code" => "#{status}_reason",
                "message" => "Synthetic #{status} state"
              }
            }
          }
        })

      assert {:ok, _windows} = maybe_insert_quota_window(identity, status)

      {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}-routing-readiness",
               readiness_label
             )

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}-assignment-#{assignment.id}-quota-priming",
               assignment_label
             )

      if status in ["unknown", "refreshing", "stale", "expired", "failed", "blocked"] do
        refute has_element?(
                 view,
                 "#upstream-account-#{identity.id}-routing-readiness",
                 "Routing candidate"
               )
      end
    end
  end

  test "requires authentication for admin upstreams", %{} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/upstreams")
  end

  test "refreshes when an upstream account is linked outside the LiveView", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "realtime-upstreams", name: "Realtime Upstreams"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    _ = :sys.get_state(view.pid)

    {:ok, %{identity: identity}} =
      Upstreams.import_codex_auth_json(
        scope,
        pool,
        auth_json_fixture(
          account_id: "acct_realtime",
          access_token: jwt_token(%{"exp" => future_unix(), "nonce" => "realtime"}),
          refresh_token: runtime_secret("realtime-refresh"),
          id_token:
            jwt_token(%{
              "email" => "realtime@example.com",
              "https://api.openai.com/auth" => %{
                "chatgpt_account_id" => "acct_realtime",
                "chatgpt_user_id" => "user_realtime"
              }
            })
        )
      )

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#upstream-account-#{identity.id}", "realtime@example.com")
    refute has_element?(view, "#upstream-account-#{identity.id}", "acct_realtime")
  end

  test "refreshes quota limits when upstream quota windows change outside the LiveView", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "realtime-upstream-quota", name: "Realtime Upstream Quota"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Realtime Quota Codex",
        assignment_label: "Realtime quota assignment"
      })

    now = DateTime.utc_now()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "gpt_5_3_codex_spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("0"),
                 display_label: "GPT-5.3-Codex-Spark",
                 quota_scope: "model",
                 model: "gpt-5.3-codex-spark",
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_usage",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300",
             "100%"
           )

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "gpt_5_3_codex_spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("20"),
                 display_label: "GPT-5.3-Codex-Spark",
                 quota_scope: "model",
                 model: "gpt-5.3-codex-spark",
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_usage",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300",
             "80%"
           )
  end

  test "refreshes routing readiness when quota priming state completes outside the LiveView", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "realtime-quota-priming", name: "Realtime Quota Priming"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Realtime Priming Codex",
        assignment_label: "Realtime priming assignment",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "refreshing",
            "trigger_kind" => "test",
            "started_at" => "2026-05-22T00:00:00Z"
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Quota reconciling"
           )

    assert {:ok, _assignment} =
             PrimingState.record(pool, assignment, %{
               "status" => "weekly_only_probe",
               "trigger_kind" => "test",
               "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             })

    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Weekly quota probe"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Quota reconciling"
           )
  end

  test "distinguishes quota refresh recency from token refresh status", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "refresh-copy", name: "Refresh Copy"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Refresh Copy Codex",
        assignment_label: "Refresh copy assignment"
      })

    refreshed_at = ~U[2026-05-22 21:52:00Z]

    assignment
    |> PoolUpstreamAssignment.changeset(%{last_successful_refresh_at: refreshed_at})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}",
             "quota refresh 2026-05-22 21:52 UTC"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}",
             "token refresh not run"
           )
  end

  test "renders safe auth age and token refresh diagnostics without exposing tokens", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-health", name: "Auth Health"})

    access_token = runtime_secret("auth-health-access")
    refresh_token = runtime_secret("auth-health-refresh")

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Auth Health Codex",
        identity_status: "refresh_failed"
      })

    auth_fresh_at = ~U[2026-05-01 09:15:00Z]
    auth_verified_at = ~U[2026-05-02 10:30:00Z]
    token_finished_at = ~U[2026-05-03 11:45:00Z]
    access_expires_at = ~U[2026-05-04 12:00:00Z]

    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        auth_fresh_at: auth_fresh_at,
        auth_verified_at: auth_verified_at,
        metadata: %{
          "access_token_expires_at" => DateTime.to_iso8601(access_expires_at),
          "token_refresh" => %{
            "status" => "failed",
            "finished_at" => DateTime.to_iso8601(token_finished_at),
            "reason" => %{
              "code" => "codex_oauth_refresh_failed",
              "message" => "upstream OAuth refresh failed"
            }
          }
        }
      })
      |> Repo.update!()

    {:ok, _secret} =
      Upstreams.store_encrypted_secret(identity, %{
        secret_kind: "access_token",
        plaintext: access_token
      })

    {:ok, _secret} =
      Upstreams.store_encrypted_secret(identity, %{
        secret_kind: "refresh_token",
        plaintext: refresh_token
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    auth_selector = "#upstream-account-#{identity.id}-auth-health"

    assert has_element?(view, auth_selector, "Auth health")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-auth-fresh",
             "2026-05-01 09:15 UTC"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-auth-verified",
             "2026-05-02 10:30 UTC"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-access-token",
             "access token expired 2026-05-04 12:00 UTC"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-refresh",
             "token refresh failed: upstream OAuth refresh failed (codex_oauth_refresh_failed)"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}",
             "token refresh failed: upstream OAuth refresh failed (codex_oauth_refresh_failed)"
           )

    html = render(view)
    refute html =~ access_token
    refute html =~ refresh_token
  end

  test "does not duplicate token refresh failure prefixes", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "failed-prefix", name: "Failed Prefix"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Failed Prefix Codex",
        identity_status: "refresh_failed",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "failed",
            "reason" => %{
              "code" => "codex_oauth_refresh_failed",
              "message" => "token refresh failed: codex_oauth_refresh_failed"
            }
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-refresh",
             "token refresh failed: codex_oauth_refresh_failed (codex_oauth_refresh_failed)"
           )

    refute render(view) =~
             "token refresh failed: token refresh failed: codex_oauth_refresh_failed"
  end

  test "renders reported account plan metadata as read-only", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "reported-plan", name: "Reported Plan"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Reported Plan Codex",
        plan_label: "Team"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}-plan-label", "Team")

    refute has_element?(view, "[name='account[plan_label]']")
    refute has_element?(view, "[name='account[plan_family]']")
  end

  test "renders account plan labels from upstream metadata", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "colored-plans", name: "Colored Plans"})

    %{identity: free_identity} =
      upstream_assignment_fixture(pool, %{account_label: "Free Codex", plan_label: "Free"})

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{account_label: "Pro Codex", plan_label: "Pro"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{free_identity.id}-plan-label", "Free")
    assert has_element?(view, "#upstream-account-#{pro_identity.id}-plan-label", "Pro")
  end

  test "renders missing account plan metadata without persisting fallback copy", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "missing-plan", name: "Missing Plan"})
    %{identity: identity} = upstream_assignment_fixture(pool)

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    refute render(view) =~ "Not reported by account"

    assert has_element?(view, "#upstream-account-#{identity.id}-plan-label")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-plan-label-button[aria-label='Account did not report plan or quota details']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-plan-label-content",
             "This account did not report plan or quota details"
           )

    refute has_element?(view, "[name='account[plan_label]']")
    refute has_element?(view, "[name='account[plan_family]']")
    assert Repo.get!(UpstreamIdentity, identity.id).plan_label == nil
  end

  @tag :token_refresh
  test "refresh action enqueues a unique token refresh job and renders sanitized visibility", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "refresh-job", name: "Refresh Job"})
    refresh_token = runtime_secret("refresh-live")

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Refreshable Codex",
        identity_status: "refresh_due"
      })

    {:ok, _secret} =
      Upstreams.store_encrypted_secret(identity, %{
        secret_kind: "refresh_token",
        plaintext: refresh_token
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}-refresh-status", "not run")

    view
    |> element("#refresh-upstream-account-#{identity.id}")
    |> render_click()

    [job] = Repo.all(Oban.Job)
    assert job.worker == worker_name(TokenRefreshWorker)
    assert job.args["upstream_identity_id"] == identity.id
    assert job.args["trigger_kind"] == "admin_upstreams_live"

    assert [event] = audit_events("upstream_account.refresh_enqueue", identity.id)
    assert event.actor_user_id == scope.user.id
    assert event.pool_id == pool.id
    assert event.target_type == "upstream_identity"
    assert event.details["upstream_identity_id"] == identity.id
    assert event.details["pool_assignment_ids"] == [assignment.id]
    assert event.details["trigger_kind"] == "admin_upstreams_live"
    assert event.details["job_conflict"] == false
    refute inspect(event) =~ refresh_token

    assert has_element?(view, "#upstream-account-#{identity.id}-refresh-status", "job available")
    refute render(view) =~ refresh_token
  end

  @tag :token_refresh
  test "refresh action reports duplicate queued work without exposing secrets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "refresh-duplicate", name: "Refresh Duplicate"})

    refresh_token = runtime_secret("refresh-duplicate")

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Duplicate Refresh",
        identity_status: "active"
      })

    {:ok, _secret} =
      Upstreams.store_encrypted_secret(identity, %{
        secret_kind: "refresh_token",
        plaintext: refresh_token
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    view |> element("#refresh-upstream-account-#{identity.id}") |> render_click()
    view |> element("#refresh-upstream-account-#{identity.id}") |> render_click()

    assert Repo.aggregate(Oban.Job, :count) == 1
    assert [_queued, conflict] = audit_events("upstream_account.refresh_enqueue", identity.id)
    assert conflict.details["job_conflict"] == true
    refute inspect(conflict) =~ refresh_token
    assert has_element?(view, "#upstream-account-#{identity.id}-refresh-status", "job available")
    refute render(view) =~ refresh_token
  end

  @tag :token_refresh
  test "refresh button is disabled for terminal local lifecycle states", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "refresh-terminal", name: "Refresh Terminal"})

    for status <- ["paused", "deleted"] do
      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "#{status}@example.com",
          account_label: "Terminal #{status}",
          identity_status: status,
          assignment_status: status,
          eligibility_status: "ineligible"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

      if status == "paused" do
        assert has_element?(view, "#refresh-upstream-account-#{identity.id}[disabled]")
      else
        refute has_element?(view, "#upstream-account-#{identity.id}")
      end
    end
  end

  test "auth.json paste validation keeps raw content out of assigns while typing", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "auth-json-paste-validate", name: "Paste Validate"})

    sensitive_token = runtime_secret("auth-json-paste-validate")

    pasted_auth_json =
      auth_json_fixture(
        access_token: jwt_token(%{"exp" => future_unix(), "source" => "paste-validate"}),
        refresh_token: sensitive_token
      )

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    open_auth_json_import_dialog(view)

    view
    |> element("#auth-json-import-form")
    |> render_change(%{"auth_json" => %{"pool_id" => pool.id, "content" => pasted_auth_json}})

    assert has_element?(view, "#auth-json-import-dialog[open]")
    refute render(view) =~ pasted_auth_json
    refute render(view) =~ sensitive_token
  end

  test "imports Codex auth.json through authenticated admin UI without echoing secrets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-live", name: "auth.json Live"})
    access_token = jwt_token(%{"exp" => future_unix()})
    refresh_token = runtime_secret("auth-json-refresh")
    auth_json = auth_json_fixture(access_token: access_token, refresh_token: refresh_token)

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_auth_json_import_dialog(view)

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{
      "auth_json" => %{
        "pool_id" => pool.id,
        "content" => auth_json
      }
    })

    identity = Repo.one!(UpstreamIdentity)
    assignment = Repo.one!(PoolUpstreamAssignment)

    assert identity.chatgpt_account_id == "acct_fixture_auth_json"
    assert identity.metadata["auth_json_imported"] == true
    assert assignment.pool_id == pool.id
    assert assignment.status == "active"
    assert has_element?(view, "#upstream-account-#{identity.id}", "fixture-user@example.com")
    refute has_element?(view, "#upstream-account-#{identity.id}", "acct_fixture_auth_json")
    refute has_element?(view, "#upstream-account-#{identity.id}", "auth.json import")
    refute has_element?(view, "#upstream-account-#{identity.id}", "stored account id")
    refute has_element?(view, "#upstream-account-#{identity.id}-source")

    assert {:ok, ^access_token} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert {:ok, ^refresh_token} =
             Secrets.decrypt_active_secret(identity, "refresh_token")

    html = render(view)
    refute html =~ access_token
    refute html =~ refresh_token
    refute html =~ auth_json
    refute html =~ "raw_auth_json"
    refute inspect(Repo.all(AuditEvent)) =~ access_token
    refute inspect(Repo.all(AuditEvent)) =~ refresh_token
  end

  test "imports Codex auth.json from a dialog file upload without keeping the file around", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-file", name: "auth.json File"})
    access_token = jwt_token(%{"exp" => future_unix(), "source" => "file"})
    refresh_token = runtime_secret("auth-json-file-refresh")
    auth_json = auth_json_fixture(access_token: access_token, refresh_token: refresh_token)

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    open_auth_json_import_dialog(view)

    upload =
      file_input(view, "#auth-json-import-form", :auth_json, [
        %{
          name: "auth.json",
          content: auth_json,
          type: "application/json"
        }
      ])

    assert render_upload(upload, "auth.json") =~ "100%"

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{"auth_json" => %{"pool_id" => pool.id, "content" => ""}})

    identity = Repo.one!(UpstreamIdentity)
    assert identity.metadata["auth_json_imported"] == true
    assert has_element?(view, "#upstream-account-#{identity.id}", "fixture-user@example.com")
    refute has_element?(view, "#auth-json-import-dialog")

    html = render(view)
    refute html =~ access_token
    refute html =~ refresh_token
    refute html =~ auth_json
  end

  test "auth.json file submit waits for upload completion without echoing secrets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "auth-json-file-wait", name: "auth.json File Wait"})

    access_token = jwt_token(%{"exp" => future_unix(), "source" => "file-wait"})
    refresh_token = runtime_secret("auth-json-file-wait-refresh")
    auth_json = auth_json_fixture(access_token: access_token, refresh_token: refresh_token)

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    open_auth_json_import_dialog(view)

    upload =
      file_input(view, "#auth-json-import-form", :auth_json, [
        %{
          name: "auth.json",
          content: auth_json,
          type: "application/json"
        }
      ])

    assert render_upload(upload, "auth.json", 49) =~ "49%"

    html =
      view
      |> element("#auth-json-import-form")
      |> render_submit(%{"auth_json" => %{"pool_id" => pool.id, "content" => ""}})

    assert html =~ "Upload is still in progress"
    assert has_element?(view, "#auth-json-import-dialog[open]")
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0

    refute html =~ access_token
    refute html =~ refresh_token
    refute html =~ auth_json
  end

  test "duplicate Codex auth.json import reuses account assignment and active secrets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-dupe", name: "auth.json Dupe"})
    first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "first"})
    second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "second"})
    first_refresh = runtime_secret("auth-json-first-refresh")
    second_refresh = runtime_secret("auth-json-second-refresh")

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    first_auth_json = auth_json_fixture(access_token: first_access, refresh_token: first_refresh)

    second_auth_json =
      auth_json_fixture(access_token: second_access, refresh_token: second_refresh)

    open_auth_json_import_dialog(view)

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{"auth_json" => %{"pool_id" => pool.id, "content" => first_auth_json}})

    open_auth_json_import_dialog(view)

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{"auth_json" => %{"pool_id" => pool.id, "content" => second_auth_json}})

    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1

    identity = Repo.one!(UpstreamIdentity)

    assert {:ok, ^second_access} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert {:ok, ^second_refresh} =
             Secrets.decrypt_active_secret(identity, "refresh_token")

    html = render(view)
    refute html =~ first_access
    refute html =~ second_access
    refute html =~ first_refresh
    refute html =~ second_refresh
  end

  test "renders one upstream account card with Pool assignments from two Pools", %{
    conn: conn,
    scope: scope
  } do
    {:ok, source_pool} = Pools.create_pool(scope, %{slug: "shared-source", name: "Shared Source"})
    {:ok, target_pool} = Pools.create_pool(scope, %{slug: "shared-target", name: "Shared Target"})

    first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "shared-source"})
    second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "shared-target"})
    first_refresh = runtime_secret("shared-source-refresh")
    second_refresh = runtime_secret("shared-target-refresh")

    assert {:ok, %{identity: identity, assignment: source_assignment}} =
             Upstreams.import_codex_auth_json(
               scope,
               source_pool,
               auth_json_fixture(access_token: first_access, refresh_token: first_refresh)
             )

    assert {:ok, %{identity: same_identity, assignment: target_assignment}} =
             Upstreams.import_codex_auth_json(
               scope,
               target_pool,
               auth_json_fixture(access_token: second_access, refresh_token: second_refresh)
             )

    assert same_identity.id == identity.id

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 2
    assert has_element?(view, "#upstream-account-#{identity.id}", "fixture-user@example.com")
    assert has_element?(view, "#upstream-account-#{identity.id}", "2 Pools")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{source_assignment.id}",
             "Shared Source (shared-source)"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{target_assignment.id}",
             "Shared Target (shared-target)"
           )

    html = render(view)
    refute html =~ first_access
    refute html =~ second_access
    refute html =~ first_refresh
    refute html =~ second_refresh
    refute html =~ "raw_auth_json"
  end

  test "invalid Codex auth.json keeps submitted content out of the rendered form", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "auth-json-invalid", name: "auth.json Invalid"})

    sensitive_token = runtime_secret("auth-json-invalid")
    invalid_auth_json = Jason.encode!(%{"OPENAI_API_KEY" => sensitive_token})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_auth_json_import_dialog(view)

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{
      "auth_json" => %{
        "pool_id" => pool.id,
        "content" => invalid_auth_json
      }
    })

    assert has_element?(view, "#auth-json-import-dialog[open]")
    assert has_element?(view, "#auth-json-import-form")
    refute render(view) =~ sensitive_token
    refute render(view) =~ invalid_auth_json
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
    assert Repo.aggregate(EncryptedSecret, :count) == 0
  end

  test "rejects auth.json import when paste and file upload are both provided", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "auth-json-double-source", name: "Double Source"})

    pasted_auth_json =
      auth_json_fixture(
        access_token: jwt_token(%{"exp" => future_unix(), "source" => "paste"}),
        refresh_token: runtime_secret("auth-json-paste-refresh")
      )

    uploaded_auth_json =
      auth_json_fixture(
        access_token: jwt_token(%{"exp" => future_unix(), "source" => "upload"}),
        refresh_token: runtime_secret("auth-json-upload-refresh")
      )

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    open_auth_json_import_dialog(view)

    upload =
      file_input(view, "#auth-json-import-form", :auth_json, [
        %{name: "auth.json", content: uploaded_auth_json, type: "application/json"}
      ])

    assert render_upload(upload, "auth.json") =~ "100%"

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{
      "auth_json" => %{"pool_id" => pool.id, "content" => pasted_auth_json}
    })

    assert has_element?(view, "#auth-json-import-dialog[open]")

    assert has_element?(
             view,
             "#auth-json-import-form",
             "Use either pasted JSON or one uploaded file"
           )

    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    refute render(view) =~ pasted_auth_json
    refute render(view) =~ uploaded_auth_json
  end

  test "rejects auth.json upload extension and size before import", %{conn: conn, scope: scope} do
    {:ok, _pool} =
      Pools.create_pool(scope, %{slug: "auth-json-upload-limits", name: "Upload Limits"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    open_auth_json_import_dialog(view)

    rejected_extension =
      file_input(view, "#auth-json-import-form", :auth_json, [
        %{name: "auth.txt", content: "{}", type: "text/plain"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(rejected_extension, "auth.txt")
    assert render(view) =~ "Upload auth.json as a .json file"

    too_large_content = String.duplicate("x", 64_001)

    too_large =
      file_input(view, "#auth-json-import-form", :auth_json, [
        %{name: "auth.json", content: too_large_content, type: "application/json"}
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(too_large, "auth.json")
    assert render(view) =~ "File must be 64 KB or smaller"
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    refute render(view) =~ "auth.txt"
    refute render(view) =~ too_large_content
  end

  @tag :recovery_actions_render
  test "blocked upstream accounts render recovery actions and safe default links", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "recovery-actions", name: "Recovery Actions"})

    recovery_statuses = ["paused", "refresh_due", "refresh_failed", "reauth_required"]

    identities =
      for status <- recovery_statuses do
        email = "#{status}-#{System.unique_integer([:positive])}@example.com"

        %{identity: identity} =
          upstream_assignment_fixture(pool, %{
            chatgpt_account_id: email,
            account_label: "Recover #{status}",
            identity_status: status,
            identity_metadata: blocked_auth_metadata(status)
          })

        {identity, email}
      end

    fallback_email = "fallback-#{System.unique_integer([:positive])}@example.com"

    %{identity: fallback_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct-not-an-email",
        account_label: fallback_email,
        identity_status: "paused",
        identity_metadata: blocked_auth_metadata("failed")
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    for {identity, email} <- identities do
      encoded_email = URI.encode_www_form(email)

      assert has_element?(
               view,
               "#replace-auth-json-upstream-account-#{identity.id}",
               "Replace auth.json"
             )

      assert has_element?(
               view,
               "#replace-auth-json-upstream-account-#{identity.id} .hero-document-arrow-up"
             )

      assert has_element?(
               view,
               "#reinvite-upstream-account-#{identity.id}[href*='create=1'][href*='pool_id=#{pool.id}'][href*='invited_email=#{encoded_email}']",
               "Reinvite account"
             )

      assert has_element?(view, "#reinvite-upstream-account-#{identity.id} .hero-user-plus")
    end

    encoded_fallback_email = URI.encode_www_form(fallback_email)

    assert has_element?(
             view,
             "#reinvite-upstream-account-#{fallback_identity.id}[href*='invited_email=#{encoded_fallback_email}']",
             "Reinvite account"
           )

    refute render(view) =~ "invited_email=&"

    {first_identity, _email} = hd(identities)

    view
    |> element("#replace-auth-json-upstream-account-#{first_identity.id}")
    |> render_click()

    assert has_element?(view, "#auth-json-import-dialog[open]")

    assert has_element?(
             view,
             "#auth_json_pool_id option[value='#{pool.id}'][selected]",
             "Recovery Actions (recovery-actions)"
           )

    reauth_identity =
      identities
      |> Enum.map(&elem(&1, 0))
      |> Enum.find(&(&1.status == "reauth_required"))

    warning_selector = "#upstream-account-#{reauth_identity.id}-reauth-warning"
    assert has_element?(view, warning_selector, "Replace auth.json")
    assert has_element?(view, warning_selector, "Reinvite account")
  end

  @tag :recovery_actions_edge_cases
  test "recovery actions stay safe for no-assignment, deleted, usable auth, and invalid pool cases",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "recovery-edge", name: "Recovery Edge"})

    no_assignment_id = Ecto.UUID.generate()

    no_assignment_html =
      render_component(&UpstreamAccountCard.account_card/1,
        account: recovery_component_account(no_assignment_id, "paused", []),
        account_index: 0
      )

    assert no_assignment_html =~ ~s(id="replace-auth-json-upstream-account-#{no_assignment_id}")
    assert no_assignment_html =~ ~s(id="reinvite-upstream-account-#{no_assignment_id}")

    assert no_assignment_html =~
             ~r/<button[^>]+id="reinvite-upstream-account-#{no_assignment_id}"[^>]+disabled/

    refute no_assignment_html =~ ~r/<a[^>]+id="reinvite-upstream-account-#{no_assignment_id}"/

    deleted_id = Ecto.UUID.generate()

    deleted_html =
      render_component(&UpstreamAccountCard.account_card/1,
        account: recovery_component_account(deleted_id, "deleted", []),
        account_index: 0
      )

    refute deleted_html =~ "replace-auth-json-upstream-account-#{deleted_id}"
    refute deleted_html =~ "reinvite-upstream-account-#{deleted_id}"

    usable_id = Ecto.UUID.generate()

    usable_html =
      render_component(&UpstreamAccountCard.account_card/1,
        account:
          recovery_component_account(
            usable_id,
            "paused",
            [
              recovery_component_assignment(pool.id, "Recovery Edge")
            ],
            refresh_status: "succeeded",
            access_token_label: "access token expires 2026-05-04 12:00 UTC"
          ),
        account_index: 0
      )

    refute usable_html =~ "replace-auth-json-upstream-account-#{usable_id}"
    refute usable_html =~ "reinvite-upstream-account-#{usable_id}"

    %{identity: invalid_email_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct-not-email",
        account_label: "Not an email label",
        identity_status: "paused",
        identity_metadata: blocked_auth_metadata("failed")
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#reinvite-upstream-account-#{invalid_email_identity.id}[href*='create=1'][href*='pool_id=#{pool.id}']",
             "Reinvite account"
           )

    refute render(view) =~ "invited_email="

    invalid_pool_id = Ecto.UUID.generate()
    render_click(view, "open_import_auth_json", %{"pool-id" => invalid_pool_id})

    assert has_element?(view, "#auth-json-import-dialog[open]")
    refute has_element?(view, "#auth_json_pool_id option[value='#{invalid_pool_id}'][selected]")
    refute has_element?(view, "#auth_json_pool_id option[selected]")
  end

  test "reauthentication warning renders redacted lifecycle details", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "secret-labels", name: "Secret Labels"})

    %{identity: missing} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "missing@example.com",
        account_label: "Missing Secret"
      })

    %{identity: refresh_due} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "refresh-due@example.com",
        account_label: "Refresh Due",
        identity_status: "refresh_due"
      })

    %{identity: reauth} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "reauth@example.com",
        account_label: "Reauth Required",
        identity_status: "reauth_required",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "reauth_required",
            "reason" => %{
              "code" => "refresh_token_revoked",
              "message" => "Refresh token was revoked or expired"
            }
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    refute has_element?(view, "#upstream-account-#{missing.id}-secret")
    refute has_element?(view, "#upstream-account-#{refresh_due.id}-secret")
    refute has_element?(view, "#upstream-account-#{reauth.id}-secret")

    warning_selector = "#upstream-account-#{reauth.id}-reauth-warning"
    assert has_element?(view, warning_selector, "Reauthentication required")
    assert has_element?(view, warning_selector, "excluded from routing")
    assert has_element?(view, warning_selector, "Refresh token was revoked or expired")
    assert has_element?(view, warning_selector, "refresh_token_revoked")
    assert has_element?(view, warning_selector, "Replace auth.json")
    assert has_element?(view, warning_selector, "Reinvite account")
  end

  defp blocked_auth_metadata(status) do
    %{
      "access_token_expires_at" =>
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601(),
      "token_refresh" => %{
        "status" => status,
        "reason" => %{
          "code" => "blocked_recovery_fixture",
          "message" => "Synthetic blocked recovery state"
        }
      }
    }
  end

  defp recovery_component_assignment(pool_id, pool_label) do
    %{
      id: Ecto.UUID.generate(),
      pool_id: pool_id,
      pool_label: pool_label,
      assignment_label: "Recovery assignment",
      status: "active",
      eligibility_status: "eligible",
      quota_priming_status: "unknown",
      quota_priming_label: "Priming pending"
    }
  end

  defp recovery_component_account(identity_id, status, assignments, opts \\ []) do
    %{
      identity: %UpstreamIdentity{
        id: identity_id,
        account_label: "Recovery component #{identity_id}",
        chatgpt_account_id: nil,
        status: status
      },
      label: "Recovery component #{identity_id}",
      plan_label: nil,
      plan_reported?: false,
      refresh_status: Keyword.get(opts, :refresh_status, "failed"),
      token_refresh_label: "token refresh failed",
      refresh_job_state: nil,
      quota_refresh_status: "not run",
      auth_fresh_label: "auth imported not reported",
      auth_verified_label: "auth verified not reported",
      access_token_label:
        Keyword.get(opts, :access_token_label, "access token expired 2026-05-04 12:00 UTC"),
      reauth_required?: status == "reauth_required",
      reauth_reason_code: nil,
      reauth_reason_message: nil,
      assignments: assignments,
      quota_limits: []
    }
  end

  defp maybe_insert_quota_window(identity, "known") do
    QuotaWindows.upsert_quota_windows(identity, [
      %{
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("10"),
        reset_at: DateTime.add(DateTime.utc_now(), 900, :second),
        source: "codex_usage",
        freshness_state: "fresh",
        observed_at: DateTime.utc_now()
      }
    ])
  end

  defp maybe_insert_quota_window(identity, "weekly_only_probe") do
    QuotaWindows.upsert_quota_windows(identity, [
      %{
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("10"),
        reset_at: DateTime.add(DateTime.utc_now(), 900, :second),
        source: "codex_usage",
        freshness_state: "fresh",
        observed_at: DateTime.utc_now()
      }
    ])
  end

  defp maybe_insert_quota_window(_identity, _status), do: {:ok, []}

  defp runtime_secret(label),
    do: Enum.join(["admin", label, "secret", "do", "not", "render"], "-")

  defp auth_json_fixture(opts) do
    tokens = %{
      "id_token" => Keyword.get(opts, :id_token, id_token_fixture()),
      "access_token" => Keyword.fetch!(opts, :access_token),
      "refresh_token" => Keyword.fetch!(opts, :refresh_token),
      "account_id" => Keyword.get(opts, :account_id, "acct_fixture_auth_json")
    }

    %{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => tokens,
      "last_refresh" => "2026-05-03T00:00:00Z"
    }
    |> Jason.encode!()
  end

  defp id_token_fixture do
    jwt_token(%{
      "email" => "fixture-user@example.com",
      "https://api.openai.com/auth" => %{
        "chatgpt_account_id" => "acct_fixture_auth_json",
        "chatgpt_user_id" => "user_fixture_auth_json",
        "chatgpt_plan_type" => "pro"
      }
    })
  end

  defp jwt_token(payload) do
    header = %{"alg" => "none", "typ" => "JWT"}
    encode = &Base.url_encode64(Jason.encode!(&1), padding: false)

    Enum.join([encode.(header), encode.(payload), Base.url_encode64("sig", padding: false)], ".")
  end

  defp future_unix, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()

  defp active_secret_count(secret_kind) do
    Repo.aggregate(
      from(secret in EncryptedSecret,
        where: secret.secret_kind == ^secret_kind and secret.status == "active"
      ),
      :count
    )
  end

  defp open_auth_json_import_dialog(view) do
    view
    |> element("#upstream-page-import-auth-json-action")
    |> render_click()
  end

  defp audit_events(action, target_id) do
    Repo.all(
      from(event in AuditEvent,
        where: event.action == ^action and event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
      )
    )
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
