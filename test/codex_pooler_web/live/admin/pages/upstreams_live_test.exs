defmodule CodexPoolerWeb.Admin.UpstreamsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Secrets, as: Secrets

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias CodexPooler.Events.PostgresBridge
  alias CodexPooler.FakeOpenAIAuthProvider
  alias CodexPooler.Jobs.SavedResetRedemptionWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Mailer
  alias CodexPooler.Pools
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.OAuthFlows
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.PrimingState
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility

  alias CodexPooler.Upstreams.Schemas.{
    EncryptedSecret,
    OAuthFlow,
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.DateTimeDisplay

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

  test "renders current admin nav icon labels", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/upstreams")

    for {id, label} <- [
          {"admin-nav-pools", "Pools"},
          {"admin-nav-upstreams", "Upstreams"},
          {"admin-nav-api-keys", "API keys"},
          {"admin-nav-stats", "Stats"},
          {"admin-nav-operators", "Operators"},
          {"admin-nav-invites", "Invites"},
          {"admin-nav-request-logs", "Request logs"},
          {"admin-nav-audit-logs", "Audit logs"},
          {"admin-nav-jobs", "System Jobs"},
          {"admin-nav-system", "System Settings"},
          {"admin-nav-observatory", "Observatory"},
          {"admin-nav-alerts", "Alerts"},
          {"admin-nav-settings", "Settings"},
          {"admin-sidebar-logout", "Log out"}
        ] do
      assert has_element?(view, "##{id}[aria-label='#{label}'][title='#{label}']")
    end

    refute html =~ "account capacity"
    refute html =~ "pool lifecycle"
    refute html =~ "gateway request trail"
    refute html =~ "system job state"
  end

  test "renders token burn completeness states without false zero claims", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Token burn completeness Pool"})
    %{api_key: api_key} = api_key_fixture(pool)
    now = DateTime.utc_now()

    accounts =
      for state <- [:idle, :complete, :partial, :unknown], into: %{} do
        %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
        {state, %{identity: identity, assignment: assignment}}
      end

    seed_settlement = fn %{identity: identity, assignment: assignment}, attrs ->
      request = request_fixture(%{pool: pool, api_key: api_key})

      ledger_entry_fixture(
        request,
        Map.merge(
          %{
            pool_upstream_assignment_id: assignment.id,
            upstream_identity_id: identity.id,
            occurred_at: DateTime.add(now, -60, :second)
          },
          attrs
        )
      )
    end

    seed_settlement.(accounts.complete, %{total_tokens: 0, settled_cost_micros: 0})
    seed_settlement.(accounts.partial, %{total_tokens: 20, settled_cost_micros: 200})

    seed_settlement.(accounts.partial, %{
      usage_status: "usage_unknown",
      total_tokens: 999_999,
      settled_cost_micros: 999_999
    })

    for _ <- 1..82 do
      seed_settlement.(accounts.unknown, %{
        usage_status: "usage_unknown",
        total_tokens: 999_999,
        settled_cost_micros: 999_999
      })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    for {state, %{identity: identity}} <- accounts do
      card_id = "upstream-account-#{identity.id}"

      assert has_element?(
               view,
               "##{card_id}-token-burn[data-usage-state='#{state}']"
             )

      assert has_element?(
               view,
               "##{card_id}-token-burn-value-popover[data-usage-state='#{state}']"
             )
    end

    complete_card_id = "upstream-account-#{accounts.complete.identity.id}"

    assert has_element?(
             view,
             "##{complete_card_id}-token-burn-value[title*='complete usage']",
             "x0"
           )

    partial_card_id = "upstream-account-#{accounts.partial.identity.id}"

    assert has_element?(
             view,
             "##{partial_card_id}-token-burn-value[title*='1 usage record missing']",
             "x1"
           )

    assert has_element?(
             view,
             "##{partial_card_id}-token-burn-content [data-role='upstream-token-burn-missing-usage']",
             "1 usage record missing"
           )

    unknown_card_id = "upstream-account-#{accounts.unknown.identity.id}"
    unknown_tokens_trigger_id = "#{unknown_card_id}-tokens-panel-trigger"

    assert has_element?(
             view,
             "##{unknown_card_id}-token-burn-value[title*='82 requests'][title*='82 usage records missing']",
             "usage unavailable"
           )

    assert has_element?(
             view,
             "##{unknown_card_id}-token-burn-content [data-role='upstream-token-burn-state'][data-usage-state='unknown']",
             "Usage unavailable"
           )

    assert has_element?(
             view,
             "##{unknown_card_id}-token-burn-content [data-role='upstream-token-burn-usage-unavailable']",
             "82 usage records missing"
           )

    assert has_element?(
             view,
             "##{unknown_tokens_trigger_id}[aria-controls='#{unknown_card_id}-tokens-panel'][aria-expanded='false']"
           )

    view
    |> element("##{unknown_tokens_trigger_id}")
    |> render_click()

    assert has_element?(view, "##{unknown_tokens_trigger_id}[aria-expanded='true']")
    assert has_element?(view, "##{unknown_card_id}-tokens-panel[aria-hidden='false']")
  end

  test "renders anchored and floating Spark reset semantics from the shared quota projection", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Spark reset semantics Pool"})
    %{identity: anchored} = upstream_assignment_fixture(pool, %{account_label: "Anchored Spark"})
    %{identity: floating} = upstream_assignment_fixture(pool, %{account_label: "Floating Spark"})

    observed_at =
      DateTime.utc_now()
      |> DateTime.add(-5, :minute)
      |> DateTime.truncate(:microsecond)

    anchored_window = spark_weekly_quota_window(observed_at, %{"reset_state" => "anchored"})

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(anchored, [anchored_window])

    for offset <- [0, 60, 300] do
      floating_observed_at = DateTime.add(observed_at, offset, :second)

      assert {:ok, _window} =
               EvidenceStore.record_evidence(
                 floating,
                 spark_weekly_quota_window(floating_observed_at, %{
                   "reset_after_seconds" => 604_800
                 }),
                 floating_observed_at,
                 floating_observed_at
               )
    end

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    anchored_reset_id =
      "upstream-account-#{anchored.id}-limit-model-codex_spark-secondary-10080-reset"

    floating_reset_id =
      "upstream-account-#{floating.id}-limit-model-codex_spark-secondary-10080-reset"

    assert has_element?(view, "##{anchored_reset_id}[title^='resets ']")
    assert has_element?(view, "##{floating_reset_id}", "starts on use")

    assert has_element?(
             view,
             "##{floating_reset_id}[title='provider reports a rolling seven-day window until use starts']"
           )
  end

  @tag :provider_reset_convergence
  test "converges anchored and floating Spark cards with weekly-only account routing", %{
    conn: conn,
    scope: scope
  } do
    pool = pool_fixture(%{name: "Provider reset convergence Pool"})

    %{identity: anchored_identity} =
      upstream_assignment_fixture(pool, %{account_label: "Anchored Spark convergence"})

    %{identity: floating_identity} =
      upstream_assignment_fixture(pool, %{account_label: "Floating Spark convergence"})

    %{identity: legacy_identity, assignment: legacy_assignment} =
      upstream_assignment_fixture(pool, %{account_label: "Weekly-only convergence"})

    as_of = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    old_reset = DateTime.add(as_of, -3, :day)
    current_reset = DateTime.add(as_of, 6, :day)
    anchored_spark_observed_at = DateTime.add(as_of, -5, :minute)
    floating_spark_observed_at = DateTime.add(as_of, -10, :minute)
    legacy_observed_at = DateTime.add(as_of, -2 * Evidence.freshness_ttl_seconds(), :second)

    current_observed_at =
      DateTime.add(legacy_observed_at, Evidence.freshness_ttl_seconds(), :second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(anchored_identity, [
               spark_weekly_quota_window(anchored_spark_observed_at, %{
                 "reset_state" => "anchored"
               })
             ])

    for offset <- [0, 60, 300] do
      observed_at = DateTime.add(floating_spark_observed_at, offset, :second)

      assert {:ok, _window} =
               EvidenceStore.record_evidence(
                 floating_identity,
                 spark_weekly_quota_window(observed_at, %{
                   "reset_after_seconds" => 604_800
                 }),
                 observed_at,
                 observed_at
               )
    end

    insert_account_quota_window!(
      legacy_identity,
      "primary",
      "codex_response_headers",
      legacy_observed_at,
      old_reset,
      "100"
    )

    current_weekly =
      insert_account_quota_window!(
        legacy_identity,
        "secondary",
        "codex_usage_api",
        current_observed_at,
        current_reset,
        "0"
      )

    legacy_identity =
      legacy_identity
      |> UpstreamIdentity.changeset(%{
        metadata: %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "source" => "codex_response_headers",
            "path_style" => "codex_api",
            "observed_at" => DateTime.to_iso8601(as_of),
            "usage_path" => "/api/codex/usage",
            "reason" => nil
          }
        },
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: as_of
      })
      |> Repo.update!()

    effective_windows = QuotaWindows.list_quota_windows(legacy_identity, as_of)
    [effective_weekly] = effective_windows

    assert effective_weekly.id == current_weekly.id
    assert effective_weekly.window_kind == "secondary"
    assert effective_weekly.source == "codex_usage_api"

    assert %{eligible?: true, routing_state: :weekly_only_probe, selection: selection} =
             QuotaWindows.routing_quota_eligibility(legacy_identity, at: as_of)

    assert selection.primary == nil
    assert selection.secondary.id == current_weekly.id
    assert [routing_weekly] = selection.routing_windows
    assert routing_weekly.id == current_weekly.id

    auto_context = %{
      trigger: :blocked_weekly_exhaustion,
      pool_upstream_assignment_id: legacy_assignment.id,
      upstream_identity_id: legacy_identity.id,
      candidate_assignment_ids: [legacy_assignment.id],
      candidate_identity_ids: [legacy_identity.id],
      route_class: "proxy_http"
    }

    assert {:noop, "gateway_auto_trigger_not_current"} =
             AutoEligibility.validate_locked_gateway_auto(
               legacy_identity,
               legacy_assignment,
               auto_context,
               as_of
             )

    accounts = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    anchored_account = Enum.find(accounts, &(&1.identity.id == anchored_identity.id))
    floating_account = Enum.find(accounts, &(&1.identity.id == floating_identity.id))
    legacy_account = Enum.find(accounts, &(&1.identity.id == legacy_identity.id))

    assert anchored_spark =
             Enum.find(
               anchored_account.quota_limits,
               &(&1.key == "model-codex_spark-secondary-10080")
             )

    assert anchored_spark.reset_semantics == :anchored
    assert String.starts_with?(anchored_spark.reset_title, "resets ")

    assert floating_spark =
             Enum.find(
               floating_account.quota_limits,
               &(&1.key == "model-codex_spark-secondary-10080")
             )

    assert floating_spark.reset_semantics == :floating
    assert floating_spark.reset_label == "starts on use"

    assert floating_spark.reset_title ==
             "provider reports a rolling seven-day window until use starts"

    assert legacy_account.quota_readiness.state == "weekly_only_probe"
    assert legacy_account.quota_readiness.label == "Weekly quota probe"
    assert legacy_account.quota_readiness.routing_ready_now?

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    anchored_reset_id =
      "upstream-account-#{anchored_identity.id}-limit-model-codex_spark-secondary-10080-reset"

    floating_reset_id =
      "upstream-account-#{floating_identity.id}-limit-model-codex_spark-secondary-10080-reset"

    legacy_card_id = "upstream-account-#{legacy_identity.id}"

    legacy_reset_title =
      "resets #{DateTimeDisplay.format_datetime(old_reset, DateTimeDisplay.preferences_for_user(scope.user))}"

    assert has_element?(view, "##{anchored_reset_id}[title^='resets ']")

    assert has_element?(
             view,
             "##{floating_reset_id}[title='provider reports a rolling seven-day window until use starts']",
             "starts on use"
           )

    assert has_element?(view, "##{legacy_card_id}-quota-readiness-state", "weekly_only_probe")
    assert has_element?(view, "##{legacy_card_id}-quota-readiness-label", "Weekly quota probe")
    assert has_element?(view, "##{legacy_card_id}-routing-readiness-state", "ready")
    assert has_element?(view, "##{legacy_card_id}-routing-readiness-label", "Routing ready")
    assert has_element?(view, "##{legacy_card_id}-limit-weekly-reset[title^='resets ']")
    refute has_element?(view, "##{legacy_card_id} [title='#{legacy_reset_title}']")
    refute has_element?(view, "##{legacy_card_id}", "Quota refresh needed")
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
    assert has_element?(view, "#upstream-page-actions.grid")

    assert has_element?(
             view,
             "#upstream-page-create-invite-action[href='/admin/invites?create=1'][aria-label='Invite account'].btn.btn-secondary",
             "Invite"
           )

    assert has_element?(
             view,
             "#upstream-page-actions > #upstream-page-import-auth-json-action[aria-label='Import auth.json'].btn.btn-accent",
             "Import"
           )

    assert has_element?(
             view,
             "#upstream-page-actions > #upstream-page-oauth-link-action[aria-label='Link OpenAI account'].btn.btn-primary",
             "Link"
           )

    refute has_element?(view, "#upstream-page-actions-menu")

    assert upstream_page_action_order(render(view)) == [
             "upstream-page-oauth-link-action",
             "upstream-page-create-invite-action",
             "upstream-page-import-auth-json-action"
           ]

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

    refute has_element?(view, "#upstream-add-capacity-card")
  end

  test "switches account cards between usage, 5m token usage, and Pools without exposing provider metadata",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, first_pool} =
      Pools.create_pool(scope, %{slug: "tokens-panel-first", name: "Tokens Panel First"})

    {:ok, second_pool} =
      Pools.create_pool(scope, %{slug: "tokens-panel-second", name: "Tokens Panel Second"})

    %{identity: identity, assignment: first_assignment} =
      upstream_assignment_fixture(first_pool, %{
        account_label: "Tokens Panel Account",
        assignment_label: "First routing lane"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    second_assignment =
      %PoolUpstreamAssignment{}
      |> PoolUpstreamAssignment.changeset(%{
        pool_id: second_pool.id,
        upstream_identity_id: identity.id,
        assignment_label: "Second routing lane",
        status: "active",
        health_status: "active",
        eligibility_status: "eligible",
        metadata: %{},
        created_at: now,
        updated_at: now
      })
      |> Repo.insert!()

    provider_sentinel = "provider-private-#{System.unique_integer([:positive])}"

    busy_model =
      model_fixture(first_pool, %{
        exposed_model_id: "gpt-example-busy",
        metadata: %{
          "source_assignment_models" => %{
            first_assignment.id => %{
              "supports_responses" => true,
              "provider" => %{"private" => provider_sentinel}
            }
          },
          "source_assignment_missing_sync_run_ids" => %{
            first_assignment.id => Ecto.UUID.generate()
          }
        }
      })

    model_fixture(first_pool, %{
      exposed_model_id: "gpt-example-quiet",
      metadata: %{
        "source_assignment_models" => %{
          first_assignment.id => %{"supports_responses" => true}
        }
      }
    })

    model_fixture(first_pool, %{
      exposed_model_id: "gpt-example-ancient",
      metadata: %{
        "source_assignment_models" => %{
          first_assignment.id => %{"supports_responses" => true}
        }
      }
    })

    %{api_key: api_key} = api_key_fixture(first_pool)

    request =
      request_fixture(%{pool: first_pool, api_key: api_key}, %{
        model_id: busy_model.id,
        requested_model: busy_model.exposed_model_id
      })

    ledger_entry_fixture(request, %{
      pool_upstream_assignment_id: first_assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: 1400,
      settled_cost_micros: 250_000,
      occurred_at: DateTime.add(now, -60, :second)
    })

    stale_request =
      request_fixture(%{pool: first_pool, api_key: api_key}, %{
        model_id: busy_model.id,
        requested_model: busy_model.exposed_model_id
      })

    ledger_entry_fixture(stale_request, %{
      pool_upstream_assignment_id: first_assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: 999_000,
      occurred_at: DateTime.add(now, -20 * 60, :second)
    })

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")

    card_id = "upstream-account-#{identity.id}"
    tokens_panel_id = "#{card_id}-tokens-panel"
    pools_panel_id = "#{card_id}-pools-panel"
    tokens_trigger_id = "#{card_id}-tokens-panel-trigger"
    pools_trigger_id = "#{card_id}-pools-panel-trigger"

    assert has_element?(view, "##{card_id}-panel-switcher[data-panel-view='usage']")

    assert has_element?(view, "##{tokens_panel_id}[aria-hidden='true'][inert]")

    assert has_element?(
             view,
             "##{tokens_trigger_id}[type='button'][phx-click='toggle_account_tokens_panel'][phx-value-id='#{identity.id}'][aria-controls='#{tokens_panel_id}'][aria-expanded='false']",
             "Tokens/5m"
           )

    assert has_element?(view, "##{pools_trigger_id}[aria-expanded='false']", "Pools")

    view
    |> element("##{tokens_trigger_id}")
    |> render_click()

    assert has_element?(view, "##{card_id}-panel-switcher[data-panel-view='tokens']")
    assert has_element?(view, "##{tokens_panel_id}[aria-hidden='false']")
    assert has_element?(view, "##{card_id}-usage-panel[aria-hidden='true'][inert]")
    assert has_element?(view, "##{pools_panel_id}[aria-hidden='true'][inert]")

    assert has_element?(
             view,
             "##{tokens_trigger_id}[aria-expanded='true'][aria-label='Show quota status']"
           )

    # The panel is a leaderboard of the account's models over the trailing
    # five minutes: settled tokens only, older usage never leaks in.
    assert has_element?(
             view,
             "##{tokens_panel_id} ##{card_id}-token-model-gpt-example-busy" <>
               " [data-role='upstream-account-token-model-tokens']",
             "1.4k"
           )

    assert has_element?(
             view,
             "##{tokens_panel_id} ##{card_id}-token-model-gpt-example-quiet" <>
               " [data-role='upstream-account-token-model-tokens']",
             "0"
           )

    assert has_element?(
             view,
             "##{tokens_panel_id} ##{card_id}-token-model-gpt-example-busy" <>
               " [data-role='upstream-account-token-model-cost']",
             "$0.25"
           )

    assert has_element?(
             view,
             "##{tokens_panel_id} ##{card_id}-token-model-gpt-example-quiet" <>
               " [data-role='upstream-account-token-model-cost']",
             "$0.00"
           )

    assert has_element?(
             view,
             "##{tokens_panel_id} ##{card_id}-tokens-summary",
             "3 models, $0.25"
           )

    # The leaderboard ranks by usage first, then descending name: the busy
    # model leads despite sorting after the others alphabetically, and among
    # the zero rows the higher name (newer generation) comes before the lower.
    panel_html = view |> element("##{tokens_panel_id}") |> render()

    busy_position = :binary.match(panel_html, "token-model-gpt-example-busy") |> elem(0)
    quiet_position = :binary.match(panel_html, "token-model-gpt-example-quiet") |> elem(0)
    ancient_position = :binary.match(panel_html, "token-model-gpt-example-ancient") |> elem(0)
    assert busy_position < quiet_position
    assert quiet_position < ancient_position

    # The old capability/serving-signal chip noise stays gone.
    refute render(view) =~ "Unverified"
    refute has_element?(view, "[data-role='upstream-account-routing-model']")

    _ = second_assignment

    refute html =~ provider_sentinel

    view
    |> element("##{pools_trigger_id}")
    |> render_click()

    assert has_element?(view, "##{card_id}-panel-switcher[data-panel-view='pools']")
    assert has_element?(view, "##{tokens_panel_id}[aria-hidden='true'][inert]")
    assert has_element?(view, "##{pools_panel_id}[aria-hidden='false']")

    view
    |> element("##{tokens_trigger_id}")
    |> render_click()

    assert has_element?(view, "##{card_id}-panel-switcher[data-panel-view='tokens']")

    view
    |> element("##{tokens_trigger_id}[aria-expanded='true']")
    |> render_click()

    assert has_element?(view, "##{card_id}-panel-switcher[data-panel-view='usage']")
    assert has_element?(view, "##{tokens_trigger_id}[aria-expanded='false']")
  end

  test "page read model exposes safe OAuth flow summaries without transient secrets", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "oauth-flow-summaries", name: "OAuth Flow Summaries"})

    assert {:ok, %{flow: browser_flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool,
               metadata: %{"source" => "admin_upstreams_test"}
             )

    device_auth_id = runtime_secret("oauth-flow-device-auth-id")

    assert {:ok, device_flow} =
             OAuthFlows.create_oauth_flow(%{
               pool_id: pool.id,
               requested_by_user_id: scope.user.id,
               flow_kind: "device",
               purpose: "link",
               status: "pending",
               device_auth_id: device_auth_id,
               device_user_code: "ABCD-EFGH",
               verification_uri: "https://auth.example.com/device",
               interval_seconds: 7,
               poll_after_at: DateTime.add(DateTime.utc_now(), 7, :second),
               expires_at: DateTime.add(DateTime.utc_now(), 10, :minute),
               metadata: %{"raw_provider_payload" => runtime_secret("oauth-flow-provider")}
             })

    oauth_flows =
      UpstreamAccountsReadModel.oauth_flow_state(
        scope,
        [pool],
        DateTimeDisplay.preferences_for_user(scope.user)
      )

    assert oauth_flows.count == 2

    browser_summary = flow_summary(oauth_flows, browser_flow.id)
    assert browser_summary.flow_kind == "browser"
    assert browser_summary.purpose == "link"
    assert browser_summary.status == "pending"
    assert browser_summary.status_label == "Browser authorization pending"
    assert browser_summary.authorization_url == nil
    assert browser_summary.device == nil

    device_summary = flow_summary(oauth_flows, device_flow.id)
    assert device_summary.flow_kind == "device"
    assert device_summary.device.user_code == "ABCD-EFGH"
    assert device_summary.device.verification_uri == "https://auth.example.com/device"
    assert device_summary.device.interval_seconds == 7

    refute Map.has_key?(browser_summary, :state_token_hash)
    refute Map.has_key?(browser_summary, :code_verifier_ciphertext)
    refute Map.has_key?(device_summary, :device_auth_id_ciphertext)
    refute inspect(oauth_flows) =~ authorization_url
    refute inspect(oauth_flows) =~ device_auth_id
    refute inspect(oauth_flows) =~ "raw_provider_payload"
    refute inspect(oauth_flows) =~ "code_verifier"
    refute inspect(oauth_flows) =~ "device_auth_id"

    {{:ok, view, html}, repo_queries} =
      capture_repo_queries(fn -> live(conn, ~p"/admin/upstreams") end)

    refute has_element?(view, "#upstream-oauth-flow-state")
    refute Enum.any?(repo_queries, &(&1.source == "upstream_oauth_flows"))

    refute html =~ authorization_url
    refute html =~ device_auth_id
    refute html =~ "raw_provider_payload"
    refute html =~ "code_verifier"
    refute html =~ "device_auth_id"
  end

  test "links upstream account through browser OAuth dialog without rendering token secrets", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} = Pools.create_pool(scope, %{slug: "oauth-browser-ui", name: "OAuth Browser UI"})

    access_token = runtime_secret("oauth-browser-access")
    refresh_token = runtime_secret("oauth-browser-refresh")
    id_token = oauth_id_token("acct_admin_browser")

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

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_oauth_link_dialog(view)
    assert has_element?(view, "#oauth-link-dialog")
    assert_oauth_dialog_docs_link(view, "oauth-link-dialog-footer")

    assert has_element?(
             view,
             "#oauth_link_pool_id option[value='#{pool.id}']",
             "OAuth Browser UI"
           )

    assert has_element?(view, "#oauth-link-browser-start")
    assert has_element?(view, "#oauth-link-device-start")

    select_oauth_link_pool(view, pool.id)

    view
    |> element("#oauth-link-browser-start")
    |> render_click()

    assert has_element?(view, "#oauth-link-authorization-url")
    assert has_element?(view, "#oauth-link-callback-url")
    assert has_element?(view, "#oauth-link-submit-callback")

    authorization_url = authorization_url_from_view(view)

    callback_url =
      provider_callback_url(authorization_state(authorization_url), "browser-admin-ui-code")

    view
    |> element("#oauth-link-callback-form")
    |> render_submit(%{"oauth_link" => %{"callback_url" => callback_url}})

    assert has_element?(view, "#oauth-link-status", "OpenAI account linked")
    assert has_element?(view, "#oauth-link-cancel", "Close")

    identity = Repo.one!(UpstreamIdentity)
    assert identity.chatgpt_account_id == "acct_admin_browser"
    assert has_element?(view, "#upstream-account-#{identity.id}")

    assert [token_request] = FakeOpenAIAuthProvider.requests(provider)

    assert FakeOpenAIAuthProvider.decode_form_request(token_request)["code"] ==
             "browser-admin-ui-code"

    html = render(view)

    for raw_value <- [
          access_token,
          refresh_token,
          id_token,
          callback_url,
          "browser-admin-ui-code"
        ] do
      refute html =~ raw_value
    end
  end

  test "relinks upstream account from the account card dropdown through browser OAuth", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "oauth-relink-card-ui", name: "OAuth Relink Card UI"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_card_relink",
        account_label: "Card Relink Codex",
        identity_status: "reauth_required",
        identity_metadata: blocked_auth_metadata("failed")
      })

    access_token = runtime_secret("oauth-card-relink-access")
    refresh_token = runtime_secret("oauth-card-relink-refresh")
    id_token = oauth_id_token("acct_card_relink")

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

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#oauth-relink-upstream-account-#{identity.id}",
             "Relink account"
           )

    view
    |> element("#oauth-relink-upstream-account-#{identity.id}")
    |> render_click()

    assert has_element?(view, "#oauth-link-dialog", "Relink OpenAI account")
    assert has_element?(view, "#oauth-link-relink-target", "Card Relink Codex")
    refute has_element?(view, "#oauth_link_pool_id")

    view
    |> element("#oauth-link-browser-start")
    |> render_click()

    assert has_element?(view, "#oauth-link-authorization-url")
    assert has_element?(view, "#oauth-link-submit-callback", "Complete relink")

    authorization_url = authorization_url_from_view(view)

    callback_url =
      provider_callback_url(authorization_state(authorization_url), "browser-relink-card-code")

    view
    |> element("#oauth-link-callback-form")
    |> render_submit(%{"oauth_link" => %{"callback_url" => callback_url}})

    assert has_element?(view, "#oauth-link-status", "OpenAI account relinked")
    assert has_element?(view, "#oauth-link-cancel", "Close")
    assert has_element?(view, "#upstream-account-#{identity.id}")

    flow = Repo.one!(OAuthFlow)
    assert flow.purpose == "relink"
    assert flow.upstream_identity_id == identity.id
    assert flow.result_upstream_identity_id == identity.id

    assert Repo.get!(UpstreamIdentity, identity.id).chatgpt_account_id == "acct_card_relink"

    assert [token_request] = FakeOpenAIAuthProvider.requests(provider)

    assert FakeOpenAIAuthProvider.decode_form_request(token_request)["code"] ==
             "browser-relink-card-code"

    html = render(view)

    for raw_value <- [
          access_token,
          refresh_token,
          id_token,
          callback_url,
          "browser-relink-card-code"
        ] do
      refute html =~ raw_value
    end
  end

  test "shows OAuth relink only with account recovery actions", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "relink-recovery-visibility",
        name: "Relink Recovery Visibility"
      })

    %{identity: active_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Healthy Relink Codex",
        chatgpt_account_id: "acct_relink_visibility_active",
        identity_status: "active"
      })

    %{identity: recovery_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recovery Relink Codex",
        chatgpt_account_id: "acct_relink_visibility_recovery",
        identity_status: "reauth_required",
        identity_metadata: blocked_auth_metadata("failed")
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    for action_id <- [
          "replace-auth-json-upstream-account-#{active_identity.id}",
          "oauth-relink-upstream-account-#{active_identity.id}",
          "reinvite-upstream-account-#{active_identity.id}"
        ] do
      refute has_element?(view, "##{action_id}")
    end

    for action_id <- [
          "replace-auth-json-upstream-account-#{recovery_identity.id}",
          "oauth-relink-upstream-account-#{recovery_identity.id}",
          "reinvite-upstream-account-#{recovery_identity.id}"
        ] do
      assert has_element?(view, "##{action_id}")
    end
  end

  test "browser OAuth callback errors stay safe and keep the raw callback out of HTML", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "oauth-browser-error-ui", name: "OAuth Browser Error UI"})

    start_oauth_provider!(%{"/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}})

    raw_code = runtime_secret("oauth-browser-wrong-state-code")
    raw_callback_url = callback_url("wrong-state", raw_code)

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_oauth_link_dialog(view)
    select_oauth_link_pool(view, pool.id)

    view
    |> element("#oauth-link-browser-start")
    |> render_click()

    view
    |> element("#oauth-link-callback-form")
    |> render_submit(%{"oauth_link" => %{"callback_url" => raw_callback_url}})

    assert has_element?(
             view,
             "#oauth-link-error",
             "OAuth callback state does not match a pending flow"
           )

    assert Repo.aggregate(UpstreamIdentity, :count) == 0

    html = render(view)
    refute html =~ raw_callback_url
    refute html =~ raw_code
  end

  test "links upstream account through device OAuth polling without rendering hidden provider values",
       %{
         conn: conn,
         scope: scope
       } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} = Pools.create_pool(scope, %{slug: "oauth-device-ui", name: "OAuth Device UI"})

    device_auth_id = runtime_secret("oauth-device-auth-id")
    authorization_code = runtime_secret("oauth-device-authorization-code")
    code_verifier = runtime_secret("oauth-device-code-verifier")
    access_token = runtime_secret("oauth-device-access")
    refresh_token = runtime_secret("oauth-device-refresh")
    id_token = oauth_id_token("acct_admin_device")

    provider =
      start_oauth_provider!(
        device_routes(%{
          "/api/accounts/deviceauth/usercode" =>
            {200,
             FakeOpenAIAuthProvider.device_code_response(
               device_auth_id: device_auth_id,
               user_code: "CODE-UI",
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

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_oauth_link_dialog(view)
    select_oauth_link_pool(view, pool.id)

    view
    |> element("#oauth-link-device-start")
    |> render_click()

    assert has_element?(view, "#oauth-link-device-code", "CODE-UI")

    assert has_element?(
             view,
             "#oauth-link-device-code",
             FakeOpenAIAuthProvider.url(provider) <> "/codex/device"
           )

    flow = Repo.one!(OAuthFlow)
    send(view.pid, {:poll_oauth_device, flow.id})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#oauth-link-status", "OpenAI account linked")
    assert has_element?(view, "#oauth-link-cancel", "Close")

    identity = Repo.one!(UpstreamIdentity)
    assert identity.chatgpt_account_id == "acct_admin_device"
    assert has_element?(view, "#upstream-account-#{identity.id}")

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

  test "OAuth link cancel marks the pending flow cancelled and closes the dialog", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, pool} = Pools.create_pool(scope, %{slug: "oauth-cancel-ui", name: "OAuth Cancel UI"})
    start_oauth_provider!(%{"/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_oauth_link_dialog(view)
    select_oauth_link_pool(view, pool.id)

    view
    |> element("#oauth-link-browser-start")
    |> render_click()

    flow = Repo.one!(OAuthFlow)
    assert has_element?(view, "#oauth-link-cancel", "Cancel")

    view
    |> element("#oauth-link-cancel")
    |> render_click()

    assert Repo.get!(OAuthFlow, flow.id).status == "cancelled"
    refute has_element?(view, "#oauth-link-dialog")
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
  end

  test "OAuth link rejects tampered pool selection outside visible pools", %{
    conn: conn,
    scope: scope
  } do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()

    {:ok, _pool} =
      Pools.create_pool(scope, %{slug: "oauth-pool-tamper-ui", name: "OAuth Pool Tamper UI"})

    start_oauth_provider!(%{"/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_oauth_link_dialog(view)
    select_oauth_link_pool(view, Ecto.UUID.generate())

    view
    |> element("#oauth-link-browser-start")
    |> render_click()

    assert has_element?(view, "#oauth-link-error")
    assert Repo.aggregate(OAuthFlow, :count) == 0
  end

  test "distinguishes sibling workspace slots on upstream account cards", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "workspace-slots", name: "Workspace Slots"})
    account_id = "acct_workspace_slots_#{System.unique_integer([:positive])}"
    first_workspace_id = "workspace-card-alpha-#{System.unique_integer([:positive])}"
    second_workspace_id = "workspace-card-beta-#{System.unique_integer([:positive])}"

    %{identity: first_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Shared account slot",
        chatgpt_account_id: account_id,
        workspace_id: first_workspace_id,
        workspace_label: "Alpha workspace"
      })

    %{identity: second_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Shared account slot",
        chatgpt_account_id: account_id,
        workspace_id: second_workspace_id,
        workspace_label: "Beta workspace"
      })

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{first_identity.id}-workspace[data-role='upstream-workspace-context']",
             "Workspace Alpha workspace"
           )

    assert has_element?(
             view,
             "#upstream-account-#{second_identity.id}-workspace[data-role='upstream-workspace-context']",
             "Workspace Beta workspace"
           )

    refute html =~ first_workspace_id
    refute html =~ second_workspace_id
  end

  @tag :subject_identity_display
  test "hides subject refs and raw subjects on upstream account cards", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "subject-workspace-slots",
        name: "Subject Workspace Slots"
      })

    unique = System.unique_integer([:positive])
    account_id = "acct_subject_slots_#{unique}"
    workspace_id = "workspace-subject-slots-#{unique}"
    first_raw_subject = "user_subject_slots_alpha_#{unique}"
    second_raw_subject = "user_subject_slots_beta_#{unique}"

    %{identity: initial_first_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Shared subject account",
        chatgpt_account_id: "#{account_id}_initial_alpha",
        workspace_id: "#{workspace_id}-initial-alpha",
        workspace_label: "Shared workspace"
      })

    %{identity: initial_second_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Shared subject account",
        chatgpt_account_id: "#{account_id}_initial_beta",
        workspace_id: "#{workspace_id}-initial-beta",
        workspace_label: "Shared workspace"
      })

    first_identity =
      update_identity_subject_slot!(
        initial_first_identity,
        account_id,
        workspace_id,
        first_raw_subject
      )

    second_identity =
      update_identity_subject_slot!(
        initial_second_identity,
        account_id,
        workspace_id,
        second_raw_subject
      )

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")

    refute has_element?(
             view,
             "#upstream-account-#{first_identity.id}-subject-ref[data-role='upstream-subject-ref']"
           )

    refute has_element?(
             view,
             "#upstream-account-#{second_identity.id}-subject-ref[data-role='upstream-subject-ref']"
           )

    refute html =~ first_raw_subject
    refute html =~ second_raw_subject
  end

  test "leaves legacy workspace context blank on upstream account cards", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "legacy-workspace-slot", name: "Legacy Workspace Slot"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Legacy workspace account",
        chatgpt_account_id: "acct_workspace_legacy_#{System.unique_integer([:positive])}"
      })

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")

    selector =
      "#upstream-account-#{identity.id}-workspace[data-role='upstream-workspace-context']"

    refute has_element?(view, selector)
    refute html =~ "Workspace legacy"
    refute html =~ "Workspace reference legacy"
  end

  test "opens saved reset dialog from the header badge and toggles the Pools mini panel", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "saved-reset-card", name: "Saved Reset Card"})
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    first_expires_at = DateTime.add(observed_at, 30, :day)
    second_expires_at = DateTime.add(first_expires_at, 2, :day)
    first_seen_at = DateTime.add(observed_at, -2, :day)
    second_seen_at = DateTime.add(observed_at, -1, :day)
    legacy_expires_at = DateTime.add(first_expires_at, 4, :day)
    first_expires_at_iso = DateTime.to_iso8601(first_expires_at)
    second_expires_at_iso = DateTime.to_iso8601(second_expires_at)
    first_seen_at_iso = DateTime.to_iso8601(first_seen_at)
    second_seen_at_iso = DateTime.to_iso8601(second_seen_at)
    legacy_expires_at_iso = DateTime.to_iso8601(legacy_expires_at)
    datetime_preferences = DateTimeDisplay.preferences_for_user(scope.user)

    first_expiration_label =
      DateTimeDisplay.format_datetime(first_expires_at, datetime_preferences)

    second_expiration_label =
      DateTimeDisplay.format_datetime(second_expires_at, datetime_preferences)

    first_seen_label = DateTimeDisplay.format_datetime(first_seen_at, datetime_preferences)
    second_seen_label = DateTimeDisplay.format_datetime(second_seen_at, datetime_preferences)

    first_seen_date =
      DateTimeDisplay.format_datetime_parts(first_seen_at, datetime_preferences).date

    second_seen_date =
      DateTimeDisplay.format_datetime_parts(second_seen_at, datetime_preferences).date

    legacy_expiration_label =
      DateTimeDisplay.format_datetime(legacy_expires_at, datetime_preferences)

    %{identity: active_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Saved Reset Codex",
        identity_metadata: %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 2,
            "source" => "codex_usage_api",
            "path_style" => "codex",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(observed_at),
            "available_expires_at" => [
              first_expires_at_iso,
              second_expires_at_iso
            ],
            "available_expirations" => [
              %{"expires_at" => first_expires_at_iso, "first_seen_at" => first_seen_at_iso},
              %{"expires_at" => second_expires_at_iso, "first_seen_at" => second_seen_at_iso}
            ],
            "next_expires_at" => first_expires_at_iso
          }
        }
      })

    active_identity
    |> UpstreamIdentity.changeset(%{
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_min_blocked_minutes: 45,
      saved_reset_auto_redeem_keep_credits: 1
    })
    |> Repo.update!()

    %{identity: inactive_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Manual Saved Reset Codex",
        identity_metadata: %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "source" => "codex_usage_api",
            "path_style" => "codex",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(observed_at)
          }
        }
      })

    %{identity: legacy_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Legacy Saved Reset Codex",
        identity_metadata: %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "source" => "codex_usage_api",
            "path_style" => "codex",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(observed_at),
            "available_expires_at" => [legacy_expires_at_iso],
            "next_expires_at" => legacy_expires_at_iso
          }
        }
      })

    %{identity: empty_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Empty Saved Reset Codex",
        identity_metadata: %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 0,
            "source" => "codex_usage_api",
            "path_style" => "codex",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(observed_at)
          }
        }
      })

    accounts = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    active_account = Enum.find(accounts, &(&1.identity.id == active_identity.id))
    inactive_account = Enum.find(accounts, &(&1.identity.id == inactive_identity.id))

    assert active_account.saved_resets.label == "2 saved resets"
    assert active_account.saved_resets.available? == true
    assert active_account.saved_reset_policy.enabled? == true
    assert active_account.saved_reset_policy.keep_credits == 1

    assert active_account.saved_resets.available_expires_at == [
             first_expires_at_iso,
             second_expires_at_iso
           ]

    assert active_account.saved_resets.available_expirations == [
             %{expires_at: first_expires_at_iso, first_seen_at: first_seen_at_iso},
             %{expires_at: second_expires_at_iso, first_seen_at: second_seen_at_iso}
           ]

    assert inactive_account.saved_resets.label == "1 saved reset"
    assert inactive_account.saved_reset_policy.enabled? == false

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    active_badge_id = "upstream-account-#{active_identity.id}-saved-reset-count"

    active_badge_selector =
      "##{active_badge_id}[data-role='upstream-saved-reset-count-badge'][aria-label='Open saved reset bank: 2 saved resets'][aria-controls='saved-reset-policy-dialog'][aria-haspopup='dialog'][phx-click='open_saved_reset_policy'][phx-value-id='#{active_identity.id}']"

    assert has_element?(view, active_badge_selector, "2")
    assert has_element?(view, "#{active_badge_selector} .hero-battery-100.size-3.text-current")

    refute has_element?(view, "#upstream-saved-reset-count-popover-#{active_identity.id}")

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-open[data-role='upstream-saved-reset-meter-open'][aria-controls='saved-reset-policy-dialog'][aria-haspopup='dialog'][phx-click='open_saved_reset_policy'][phx-value-id='#{active_identity.id}']"
           )

    refute has_element?(view, "#upstream-account-#{active_identity.id}-saved-reset-panel")
    refute has_element?(view, "#saved-reset-policy-dialog")

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-panel-switcher[data-panel-view='usage']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-usage-panel[aria-hidden='false']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel[aria-hidden='true'][inert]",
             "routing lane"
           )

    active_pools_trigger_selector =
      "#upstream-account-#{active_identity.id}-pools-panel-trigger[phx-click='toggle_account_pools_panel'][phx-value-id='#{active_identity.id}'][aria-controls='upstream-account-#{active_identity.id}-pools-panel'][aria-expanded='false']"

    assert has_element?(view, active_pools_trigger_selector, "Pools")

    refute has_element?(view, "#upstream-account-#{active_identity.id}-saved-reset-manage")

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-usage-panel #upstream-account-#{active_identity.id}-saved-reset-meter[data-role='upstream-saved-reset-meter']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter [data-role='upstream-saved-reset-meter-title']",
             "Banked Resets"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter [data-role='upstream-saved-reset-meter-count']",
             "x2"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-policy[data-role='upstream-saved-reset-meter-policy']",
             "Auto redeem active"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-policy [class*='--color-reset-bank']",
             "active"
           )

    refute has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-policy .hero-cog-6-tooth"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-bar[role='meter'][aria-valuenow='2'][aria-valuemax='5']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-reset .hero-clock"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-reset .hero-clock"
           )

    refute has_element?(
             view,
             "#upstream-account-#{active_identity.id}-saved-reset-meter-reset",
             "Next expires"
           )

    active_card = view |> element("#upstream-account-#{active_identity.id}") |> render()
    active_badge_class = html_element_class(active_card, active_badge_id)

    assert Regex.match?(
             ~r/data-role="upstream-saved-reset-meter-count"[^>]*>\s*x2\s*<\/span>/,
             active_card
           )

    active_usage_panel_class =
      html_element_class(active_card, "upstream-account-#{active_identity.id}-usage-panel")

    active_saved_meter_segment_1_class =
      html_element_class(
        active_card,
        "upstream-account-#{active_identity.id}-saved-reset-meter-segment-1"
      )

    active_saved_meter_class =
      html_element_class(active_card, "upstream-account-#{active_identity.id}-saved-reset-meter")

    active_saved_meter_segment_2_class =
      html_element_class(
        active_card,
        "upstream-account-#{active_identity.id}-saved-reset-meter-segment-2"
      )

    active_saved_meter_segment_3_class =
      html_element_class(
        active_card,
        "upstream-account-#{active_identity.id}-saved-reset-meter-segment-3"
      )

    assert active_badge_class =~ "bg-success/15"
    assert active_badge_class =~ "text-success"
    assert active_badge_class =~ "border-success/40"
    refute active_badge_class =~ "bg-(--color-reset-bank)/10"
    refute active_badge_class =~ "text-(--color-reset-bank)"
    refute active_badge_class =~ "border-dashed"
    refute active_usage_panel_class =~ "max-h-"
    refute active_usage_panel_class =~ "overflow-hidden"
    assert active_usage_panel_class =~ "transition-opacity"
    refute active_usage_panel_class =~ "translate-y"
    refute active_usage_panel_class =~ "transition-[max-height"
    assert active_saved_meter_class =~ "md:col-span-2"
    assert active_saved_meter_segment_1_class =~ "bg-(--color-reset-bank)/80"
    assert active_saved_meter_segment_2_class =~ "bg-(--color-reset-bank)/80"
    assert active_saved_meter_segment_3_class =~ "bg-base-300/70"
    refute active_saved_meter_segment_1_class =~ "bg-success"
    refute active_saved_meter_segment_2_class =~ "bg-success"

    active_pools_trigger_class =
      html_element_class(
        active_card,
        "upstream-account-#{active_identity.id}-pools-panel-trigger"
      )

    assert active_pools_trigger_class =~ "absolute"
    assert active_pools_trigger_class =~ "border-transparent"
    assert active_pools_trigger_class =~ "hover:border-primary/25"

    assert upstream_header_badge_order(active_card) == [
             active_badge_id,
             "upstream-account-#{active_identity.id}-plan-label"
           ]

    view |> element(active_pools_trigger_selector) |> render_click()

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-panel-switcher[data-panel-view='pools']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel[aria-hidden='false']",
             "1 routing lane"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel-trigger[aria-expanded='true'][aria-label='Show quota status']",
             "Pools"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel #upstream-account-#{active_identity.id}-pools-routing-summary",
             "Quota missing"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-assignment-pool']",
             "Saved Reset Card"
           )

    refute has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-assignment-pool']",
             "saved-reset-card"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-route'][role='meter'][aria-valuemin='0'][aria-valuemax='3'][aria-valuenow='2']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-assignment-eligibility']",
             "Eligible"
           )

    refute has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-assignment-eligibility'].rounded-full"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-route-segment'][title='Assignment active']",
             "Assignment"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-route-segment'][title='Health active']",
             "Health"
           )

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-route-segment'][title='Priming pending']",
             "Quota"
           )

    refute has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-assignment-status']"
           )

    refute has_element?(
             view,
             "#upstream-account-#{active_identity.id}-pools-panel [data-role='upstream-account-pool-assignment-quota']"
           )

    active_card = view |> element("#upstream-account-#{active_identity.id}") |> render()

    assert html_element_class(
             active_card,
             "upstream-account-#{active_identity.id}-pools-panel-trigger"
           ) =~ "border-primary/35"

    refute html_element_class(active_card, "upstream-account-#{active_identity.id}-pools-panel") =~
             "max-h-"

    assert html_element_class(active_card, "upstream-account-#{active_identity.id}-usage-panel") =~
             "max-h-0"

    refute has_element?(view, "#upstream-account-#{active_identity.id}-saved-reset-panel")

    view
    |> element(
      "#upstream-account-#{active_identity.id}-pools-panel-trigger[aria-expanded='true']"
    )
    |> render_click()

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-panel-switcher[data-panel-view='usage']"
           )

    inactive_badge_id = "upstream-account-#{inactive_identity.id}-saved-reset-count"

    inactive_badge_selector =
      "##{inactive_badge_id}[data-role='upstream-saved-reset-count-badge'][aria-label='Open saved reset bank: 1 saved reset'][aria-controls='saved-reset-policy-dialog'][aria-haspopup='dialog'][phx-click='open_saved_reset_policy'][phx-value-id='#{inactive_identity.id}']"

    assert has_element?(view, inactive_badge_selector, "1")

    assert has_element?(
             view,
             "#upstream-account-#{inactive_identity.id}-saved-reset-meter-policy[data-role='upstream-saved-reset-meter-policy']",
             "Auto redeem inactive"
           )

    refute has_element?(
             view,
             "#upstream-account-#{inactive_identity.id}-saved-reset-meter-policy [class*='--color-reset-bank']",
             "inactive"
           )

    refute has_element?(view, "#upstream-account-#{inactive_identity.id}-saved-reset-meter-reset")

    assert has_element?(
             view,
             "#{inactive_badge_selector} .hero-battery-100.size-3[class*='--color-reset-bank']"
           )

    refute has_element?(view, "#upstream-account-#{inactive_identity.id}-saved-reset-panel")
    refute has_element?(view, "#upstream-account-#{legacy_identity.id}-saved-reset-panel")

    assert has_element?(
             view,
             "#upstream-account-#{inactive_identity.id}-saved-reset-meter-bar[role='meter'][aria-valuenow='1'][aria-valuemax='5']"
           )

    inactive_card = view |> element("#upstream-account-#{inactive_identity.id}") |> render()
    inactive_badge_class = html_element_class(inactive_card, inactive_badge_id)

    inactive_saved_meter_segment_1_class =
      html_element_class(
        inactive_card,
        "upstream-account-#{inactive_identity.id}-saved-reset-meter-segment-1"
      )

    assert inactive_badge_class =~ "bg-(--color-reset-bank)/10"
    assert inactive_badge_class =~ "text-(--color-reset-bank)"
    assert inactive_badge_class =~ "border-(--color-reset-bank)/40"
    refute inactive_badge_class =~ "border-dashed"
    assert inactive_saved_meter_segment_1_class =~ "bg-(--color-reset-bank)/80"

    assert upstream_header_badge_order(inactive_card) == [
             inactive_badge_id,
             "upstream-account-#{inactive_identity.id}-plan-label"
           ]

    refute has_element?(view, "#upstream-account-#{empty_identity.id}-saved-reset-count")
    refute has_element?(view, "#upstream-account-#{empty_identity.id}-saved-reset-panel")
    refute has_element?(view, "#upstream-account-#{empty_identity.id}-saved-reset-meter")

    view |> element(active_badge_selector) |> render_click()

    assert has_element?(view, "#saved-reset-policy-dialog")
    assert has_element?(view, "#saved-reset-policy-dialog", "Auto redeem")
    assert has_element?(view, "#saved-reset-bank-count", "×2")
    assert has_element?(view, "#saved-reset-bank-meter[role='meter'][aria-valuenow='2']")
    assert has_element?(view, "#saved-reset-next-expiry", "next expires in")

    assert has_element?(
             view,
             "#saved-reset-expirations-disclosure[open] summary",
             "All expirations"
           )

    assert has_element?(
             view,
             "#saved-reset-policy-advanced-disclosure summary",
             "Advanced policy settings"
           )

    assert has_element?(
             view,
             "#saved-reset-expiration[data-role='saved-reset-expiration-list']"
           )

    assert has_element?(view, "#saved-reset-expiration-date-0", first_expiration_label)
    assert has_element?(view, "#saved-reset-expiration-date-1", second_expiration_label)

    assert has_element?(
             view,
             "#saved-reset-expiration-first-seen-0[title='#{first_seen_label}']",
             "banked #{first_seen_date}"
           )

    assert has_element?(
             view,
             "#saved-reset-expiration-first-seen-1[title='#{second_seen_label}']",
             "banked #{second_seen_date}"
           )

    assert has_element?(
             view,
             "#saved-reset-expiration-life-0[data-role='saved-reset-expiration-life'] .saved-reset-life-fill"
           )

    assert has_element?(view, "#saved-reset-expiration-held-0", "held 2d")
    assert has_element?(view, "#saved-reset-expiration-time-left-0 .hero-clock")

    send(view.pid, :reload_upstreams_from_events)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#saved-reset-policy-dialog")
    assert has_element?(view, "#saved-reset-expiration-date-0", first_expiration_label)

    view
    |> element("#saved-reset-policy-cancel")
    |> render_click()

    refute has_element?(view, "#saved-reset-policy-dialog")

    assert has_element?(
             view,
             "#upstream-account-#{active_identity.id}-usage-panel[aria-hidden='false']"
           )

    legacy_badge_selector =
      "#upstream-account-#{legacy_identity.id}-saved-reset-count[aria-label='Open saved reset bank: 1 saved reset'][phx-click='open_saved_reset_policy']"

    assert has_element?(view, legacy_badge_selector, "1")

    view |> element(legacy_badge_selector) |> render_click()

    assert has_element?(view, "#saved-reset-policy-dialog")
    assert has_element?(view, "#saved-reset-expiration-date-0", legacy_expiration_label)
    assert has_element?(view, "#saved-reset-expiration-first-seen-0", "not recorded")

    view
    |> element("#saved-reset-policy-cancel")
    |> render_click()

    view |> element(inactive_badge_selector) |> render_click()

    assert has_element?(view, "#saved-reset-policy-dialog")

    assert has_element?(
             view,
             "#saved-reset-expiration-empty",
             "No expiration dates reported for the available saved resets yet."
           )
  end

  test "edits saved reset policy from the upstream account dropdown without redeeming resets", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "saved-reset-policy", name: "Saved Reset Policy"})

    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Saved Reset Policy Codex",
        identity_metadata: %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 2,
            "source" => "codex_usage_api",
            "path_style" => "codex",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(observed_at)
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    action_selector = "#saved-reset-policy-upstream-account-#{identity.id}"
    assert has_element?(view, action_selector, "Saved resets")

    view |> element(action_selector) |> render_click()

    assert has_element?(view, "#saved-reset-policy-dialog")
    assert has_element?(view, "#saved-reset-policy-auto-redeem-enabled")
    assert has_element?(view, "#saved-reset-policy-trigger-mode")
    assert has_element?(view, "#saved-reset-policy-quota-threshold-percent")
    assert has_element?(view, "#saved-reset-policy-min-blocked-minutes")
    assert has_element?(view, "#saved-reset-policy-keep-credits")
    assert has_element?(view, "#saved-reset-policy-auto-redeem-control")

    assert has_element?(
             view,
             "#saved-reset-redemption-action[data-role='saved-reset-redemption-action']",
             "Redeem"
           )

    html = render(view)
    refute html =~ "phx-value-expiration-index"
    refute html =~ "phx-value-expiration-label"
    refute has_element?(view, "#saved-reset-expiration-empty-action")
    refute has_element?(view, "#saved-reset-expiration-redeem-unreported")
    assert has_element?(view, "#saved-reset-policy-submit")

    assert has_element?(
             view,
             "#saved-reset-policy-dialog-panel > div:first-child",
             "Account-level quota recovery capacity"
           )

    refute render(view) =~ "Saved resets are earned reset credits reported by Codex"
    refute has_element?(view, "#saved-reset-policy-explanation")
    refute has_element?(view, "#saved-reset-policy-account-summary")

    view
    |> element("#saved-reset-policy-form")
    |> render_change(%{
      "saved_reset_policy" => %{
        "auto_redeem_enabled" => "true",
        "trigger_mode" => "threshold",
        "quota_threshold_percent" => "101",
        "min_blocked_minutes" => "-1",
        "keep_credits" => "-1"
      }
    })

    assert has_element?(view, "#saved-reset-policy-dialog")
    assert has_element?(view, "#saved-reset-policy-quota-threshold-percent.input-error")
    assert has_element?(view, "#saved-reset-policy-min-blocked-minutes.input-error")
    assert has_element?(view, "#saved-reset-policy-keep-credits.input-error")
    assert has_element?(view, "#saved-reset-policy-dialog", "must be greater than or equal to 0")
    assert has_element?(view, "#saved-reset-policy-dialog", "must be less than or equal to 100")

    view
    |> element("#saved-reset-policy-form")
    |> render_submit(%{
      "saved_reset_policy" => %{
        "auto_redeem_enabled" => "true",
        "trigger_mode" => "threshold",
        "quota_threshold_percent" => "92",
        "min_blocked_minutes" => "15",
        "keep_credits" => "1"
      }
    })

    reloaded_identity = Repo.get!(UpstreamIdentity, identity.id)
    assert reloaded_identity.saved_reset_auto_redeem_enabled == true
    assert reloaded_identity.saved_reset_auto_redeem_min_blocked_minutes == 15
    assert reloaded_identity.saved_reset_auto_redeem_keep_credits == 1
    assert reloaded_identity.saved_reset_auto_redeem_trigger_mode == "threshold"
    assert reloaded_identity.saved_reset_auto_redeem_quota_threshold_percent == 92
    refute has_element?(view, "#saved-reset-policy-dialog")

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == ^worker_name(SavedResetRedemptionWorker)
             ),
             :count
           ) == 0
  end

  test "confirms manual saved reset redemption from the upstream account dialog", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "saved-reset-dialog-manual",
        name: "Saved Reset Dialog Manual"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_started_at = now |> DateTime.add(-5, :minute) |> DateTime.to_iso8601()
    reset_expires_at = now |> DateTime.add(13, :day) |> DateTime.to_iso8601()
    reset_first_seen_at = now |> DateTime.add(-1, :day) |> DateTime.to_iso8601()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        account_label: "Manual Saved Reset Dialog Codex",
        metadata: %{
          "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now, 2, :hour)),
          "token_refresh" => %{
            "status" => "succeeded",
            "finished_at" => DateTime.to_iso8601(DateTime.add(now, -5, :minute))
          },
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "source" => "codex_usage_api",
            "path_style" => "codex_api",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(now),
            "available_expirations" => [
              %{"expires_at" => reset_expires_at, "first_seen_at" => reset_first_seen_at}
            ],
            "next_expires_at" => reset_expires_at
          },
          "saved_reset_redemption" => %{
            "status" => "redeeming",
            "attempt_id" => Ecto.UUID.generate(),
            "generation" => 1,
            "trigger_kind" => "admin_manual",
            "started_at" => stale_started_at,
            "finished_at" => nil,
            "result" => nil
          }
        }
      })

    [account] =
      scope
      |> UpstreamAccountsReadModel.list_visible_accounts([pool])
      |> Enum.filter(&(&1.identity.id == identity.id))

    assert account.saved_resets.redemption_stale? == true
    assert account.saved_resets.in_progress? == false
    assert account.saved_reset_redemption_action.available? == true

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    view
    |> element("#saved-reset-policy-upstream-account-#{identity.id}")
    |> render_click()

    assert has_element?(view, "#saved-reset-policy-dialog")
    assert has_element?(view, "#saved-reset-expiration-row-0")
    refute has_element?(view, "#saved-reset-expiration-redeem-0")
    refute has_element?(view, "#saved-reset-expiration-mobile-redeem-0")

    assert has_element?(
             view,
             "#saved-reset-redemption-action[data-role='saved-reset-redemption-action']",
             "Redeem"
           )

    action_html = view |> element("#saved-reset-redemption-action") |> render()
    refute action_html =~ "phx-value-expiration-index"
    refute action_html =~ "phx-value-expiration-label"

    view
    |> element("#saved-reset-redemption-action")
    |> render_click()

    assert has_element?(
             view,
             "#saved-reset-redemption-confirmation[data-role='saved-reset-redemption-confirmation']"
           )

    assert has_element?(view, "#saved-reset-redemption-confirm", "Queue redemption")
    assert has_element?(view, "#saved-reset-redemption-cancel", "Keep resets in bank")

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == ^worker_name(SavedResetRedemptionWorker)
             ),
             :count
           ) == 0

    view
    |> element("#saved-reset-redemption-confirm")
    |> render_click()

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

  test "stale saved reset confirmation reloads account state before enqueueing", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "saved-reset-dialog-stale-manual",
        name: "Saved Reset Dialog Stale Manual"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_expires_at = now |> DateTime.add(13, :day) |> DateTime.to_iso8601()

    %{identity: identity} =
      active_upstream_assignment_fixture(pool, %{
        account_label: "Stale Manual Saved Reset Dialog Codex",
        metadata: %{
          "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now, 2, :hour)),
          "token_refresh" => %{
            "status" => "succeeded",
            "finished_at" => DateTime.to_iso8601(DateTime.add(now, -5, :minute))
          },
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "source" => "codex_usage_api",
            "path_style" => "codex_api",
            "usage_path" => "/api/codex/usage",
            "observed_at" => DateTime.to_iso8601(now),
            "available_expirations" => [
              %{"expires_at" => reset_expires_at, "first_seen_at" => nil}
            ],
            "next_expires_at" => reset_expires_at
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    view
    |> element("#saved-reset-policy-upstream-account-#{identity.id}")
    |> render_click()

    view
    |> element("#saved-reset-redemption-action")
    |> render_click()

    assert has_element?(view, "#saved-reset-redemption-confirmation")

    update_identity_metadata!(identity, fn metadata ->
      put_in(metadata, ["saved_resets", "available_count"], 0)
    end)

    view
    |> element("#saved-reset-redemption-confirm")
    |> render_click()

    assert has_element?(view, "#saved-reset-policy-dialog", "no saved resets are available")
    assert has_element?(view, "#saved-reset-redemption-confirmation")

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == ^worker_name(SavedResetRedemptionWorker)
             ),
             :count
           ) == 0
  end

  @tag :upstream_filters
  test "renders URL-backed upstream filter controls without legacy select fallbacks", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "filter-controls", name: "Filter Controls"})

    upstream_assignment_fixture(pool, %{
      account_label: "Filter Controls Codex",
      account_identifier: "filter-controls@example.com"
    })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-filter-form")
    assert has_element?(view, "#filters_query[name='filters[query]'][value='']")
    assert has_element?(view, "#upstream-filter-query-clear[aria-label='Clear upstream search']")

    assert has_element?(
             view,
             "#filters_pool_id[name='filters[pool_id]'][type='hidden'][value='']"
           )

    assert has_element?(view, "#upstream-pool-filter")
    assert has_element?(view, "#upstream-pool-filter [data-role='pool-filter-trigger']")
    assert has_element?(view, "#upstream-pool-filter button[data-pool-id='']", "All Pools")

    assert has_element?(
             view,
             "#upstream-pool-filter button[data-pool-id='#{pool.id}']",
             "Filter Controls"
           )

    assert has_element?(view, "#filters_status[name='filters[status]'][type='hidden'][value='']")
    assert has_element?(view, "#upstream-status-filter")
    assert has_element?(view, "#upstream-status-filter [data-role='status-filter-trigger']")
    assert has_element?(view, "#upstream-status-filter button[data-status='']", "Any status")
    assert has_element?(view, "#upstream-status-filter button[data-status='active']", "Active")
    assert has_element?(view, "#upstream-status-filter button[data-status='paused']", "Paused")
    refute has_element?(view, "select#filters_pool_id")
    refute has_element?(view, "select#filters_status")
  end

  @tag :upstream_filters
  test "filters upstream cards through search submit, Pool dropdown, and status dropdown", %{
    conn: conn,
    scope: scope
  } do
    {:ok, primary_pool} =
      Pools.create_pool(scope, %{slug: "filter-primary", name: "Filter Primary"})

    {:ok, secondary_pool} =
      Pools.create_pool(scope, %{slug: "filter-secondary", name: "Filter Secondary"})

    %{identity: alpha_identity} =
      upstream_assignment_fixture(primary_pool, %{
        account_label: "Alpha Searchable Codex",
        chatgpt_account_id: "acct_filter_alpha"
      })

    %{identity: beta_identity} =
      upstream_assignment_fixture(secondary_pool, %{
        account_label: "Beta Pool Codex",
        chatgpt_account_id: "acct_filter_beta"
      })

    %{identity: paused_identity} =
      upstream_assignment_fixture(secondary_pool, %{
        account_label: "Paused Pool Codex",
        chatgpt_account_id: "acct_filter_paused",
        identity_status: "paused",
        assignment_status: "paused",
        eligibility_status: "ineligible"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{alpha_identity.id}")
    assert has_element?(view, "#upstream-account-#{beta_identity.id}")
    assert has_element?(view, "#upstream-account-#{paused_identity.id}")

    view
    |> element("#upstream-filter-form")
    |> render_change(%{
      "filters" => %{"query" => "Alpha Searchable", "pool_id" => "", "status" => ""}
    })

    assert_patch(view, ~p"/admin/upstreams?query=Alpha+Searchable")
    assert has_element?(view, "#filters_query[value='Alpha Searchable']")
    assert has_element?(view, "#upstream-account-#{alpha_identity.id}")
    refute has_element?(view, "#upstream-account-#{beta_identity.id}")
    refute has_element?(view, "#upstream-account-#{paused_identity.id}")

    view
    |> element("#upstream-filter-query-clear")
    |> render_click()

    assert_patch(view, ~p"/admin/upstreams")
    assert has_element?(view, "#filters_query[value='']")
    assert has_element?(view, "#upstream-account-#{alpha_identity.id}")
    assert has_element?(view, "#upstream-account-#{beta_identity.id}")
    assert has_element?(view, "#upstream-account-#{paused_identity.id}")

    view
    |> element("#upstream-filter-form")
    |> render_submit(%{"filters" => %{"query" => "", "pool_id" => "", "status" => ""}})

    assert_patch(view, ~p"/admin/upstreams")
    assert has_element?(view, "#upstream-account-#{alpha_identity.id}")
    assert has_element?(view, "#upstream-account-#{beta_identity.id}")
    assert has_element?(view, "#upstream-account-#{paused_identity.id}")

    view
    |> element("#upstream-pool-filter button[data-pool-id='#{secondary_pool.id}']")
    |> render_click()

    assert_patch(view, ~p"/admin/upstreams?pool_id=#{secondary_pool.id}")
    assert has_element?(view, "#filters_pool_id[value='#{secondary_pool.id}']")
    refute has_element?(view, "#upstream-account-#{alpha_identity.id}")
    assert has_element?(view, "#upstream-account-#{beta_identity.id}")
    assert has_element?(view, "#upstream-account-#{paused_identity.id}")

    view
    |> element("#upstream-status-filter button[data-status='paused']")
    |> render_click()

    assert_patch(view, ~p"/admin/upstreams?pool_id=#{secondary_pool.id}&status=paused")
    assert has_element?(view, "#filters_status[value='paused']")
    refute has_element?(view, "#upstream-account-#{alpha_identity.id}")
    refute has_element?(view, "#upstream-account-#{beta_identity.id}")
    assert has_element?(view, "#upstream-account-#{paused_identity.id}")
  end

  @tag :upstream_filters
  test "search matches safe upstream metadata but not secret-bearing metadata", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "metadata-search", name: "Metadata Search Pool"})

    {:ok, other_pool} =
      Pools.create_pool(scope, %{slug: "metadata-search-other", name: "Other Metadata Pool"})

    secret_marker = runtime_secret("metadata-search-marker")

    %{identity: matched_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Safe Metadata Codex",
        chatgpt_account_id: "acct_safe_metadata_search",
        assignment_label: "Safe Metadata Assignment",
        identity_status: "refresh_due",
        plan_family: "team-enterprise",
        plan_label: "Enterprise Team",
        identity_metadata: %{
          "auth_json_imported" => true,
          "stored_account_id" => "acct_safe_metadata_search",
          "token_refresh" => %{
            "status" => "failed",
            "secret_marker" => secret_marker
          }
        },
        assignment_metadata: %{
          "quota_priming" => %{"status" => "known"},
          "secret_token_marker" => secret_marker
        }
      })

    %{identity: other_identity} =
      upstream_assignment_fixture(other_pool, %{
        account_label: "Unmatched Metadata Codex",
        chatgpt_account_id: "acct_unmatched_metadata_search"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    refute render(view) =~ secret_marker

    for query <- [
          "Safe Metadata Codex",
          "acct_safe_metadata_search",
          "Enterprise Team",
          "team-enterprise",
          "Safe Metadata Assignment",
          "Metadata Search Pool",
          "refresh_due"
        ] do
      view
      |> element("#upstream-filter-form")
      |> render_submit(%{"filters" => %{"query" => query, "pool_id" => "", "status" => ""}})

      assert has_element?(view, "#upstream-account-#{matched_identity.id}")
      refute has_element?(view, "#upstream-account-#{other_identity.id}")
    end

    view
    |> element("#upstream-filter-form")
    |> render_submit(%{"filters" => %{"query" => secret_marker, "pool_id" => "", "status" => ""}})

    refute has_element?(view, "#upstream-account-#{matched_identity.id}")
    refute has_element?(view, "#upstream-account-#{other_identity.id}")
  end

  @tag :upstream_filters
  test "invalid Pool and deleted status URL params normalize to default visible accounts", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "invalid-filter", name: "Invalid Filter"})

    %{identity: active_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Visible Filter Codex",
        chatgpt_account_id: "acct_visible_filter"
      })

    %{identity: deleted_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Deleted Filter Codex",
        chatgpt_account_id: "acct_deleted_filter",
        identity_status: "deleted",
        assignment_status: "deleted",
        eligibility_status: "ineligible"
      })

    invalid_pool_id = Ecto.UUID.generate()

    {:ok, view, _html} =
      live(conn, ~p"/admin/upstreams?pool_id=#{invalid_pool_id}&status=deleted")

    assert has_element?(view, "#filters_pool_id[value='']")
    assert has_element?(view, "#filters_status[value='']")
    assert has_element?(view, "#upstream-account-#{active_identity.id}", "Visible Filter Codex")
    refute has_element?(view, "#upstream-account-#{deleted_identity.id}")
  end

  @tag :upstream_filters
  test "malformed nested URL params normalize to default filters without crashing", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "nested-filter", name: "Nested Filter"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Nested Filter Codex",
        chatgpt_account_id: "acct_nested_filter"
      })

    {:ok, view, _html} =
      live(conn, ~p"/admin/upstreams?query[x]=boom&pool_id[x]=boom&status[x]=boom")

    assert has_element?(view, "#filters_query[value='']")
    assert has_element?(view, "#filters_pool_id[value='']")
    assert has_element?(view, "#filters_status[value='']")
    assert has_element?(view, "#upstream-account-#{identity.id}", "Nested Filter Codex")
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
        workspace_label: "Primary workspace",
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
    api_key_auth = active_api_key_fixture(pool, %{scope: scope})

    recent_request =
      request_fixture(api_key_auth, %{correlation_id: "upstream-token-burn-recent"})

    recent_attempt = attempt_fixture(recent_request, assignment)

    ledger_entry_fixture(recent_request, %{
      attempt_id: recent_attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: 700,
      occurred_at: DateTime.add(now, -2, :minute)
    })

    baseline_request =
      request_fixture(api_key_auth, %{correlation_id: "upstream-token-burn-baseline"})

    baseline_attempt = attempt_fixture(baseline_request, assignment)

    ledger_entry_fixture(baseline_request, %{
      attempt_id: baseline_attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: 300,
      occurred_at: DateTime.add(now, -30, :minute)
    })

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
             "Link upstream accounts, monitor routing capacity, and manage credential, quota, and saved-reset recovery."
           )

    refute has_element?(view, "#upstream-account-form")
    refute has_element?(view, "#account_account_label")
    refute has_element?(view, "#account_account_identifier")
    refute has_element?(view, "#upstream-account-submit")
    assert has_element?(view, "#upstream-page-import-auth-json-action")
    refute has_element?(view, "#auth-json-import-refresh-token-warning")
    assert has_element?(view, "#upstream-page-create-invite-action")
    refute has_element?(view, "#pool-invite-submit")
    refute has_element?(view, "#upstream-account-table")
    assert has_element?(view, "#upstream-account-grid")
    assert has_element?(view, "#admin-upstreams-live.min-w-0")
    assert has_element?(view, "#upstream-account-grid.min-w-0.items-start")

    assert has_element?(
             view,
             "#upstream-account-grid.\\[\\@media\\(width\\>\\=112rem\\)\\]\\:grid-cols-4"
           )

    assert has_element?(view, "#upstream-account-#{identity.id}.min-w-0")
    assert has_element?(view, "[data-role='upstream-account-card']")
    assert has_element?(view, "#upstream-account-#{identity.id}-plan-label", "Team")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-mail[href='/admin/upstreams/#{identity.id}']",
             "Primary Codex"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id} h3.text-base.leading-5 #upstream-account-#{identity.id}-mail",
             "Primary Codex"
           )

    assert render(view) =~
             ~r/id="upstream-account-#{identity.id}-workspace"[^>]*class="[^"]*rounded-full[^"]*shrink-0 max-w-48 truncate"/

    refute has_element?(view, "#upstream-account-#{identity.id}-cockpit-link")

    open_auth_json_import_dialog(view)

    assert has_element?(view, "#auth-json-import-dialog[open]")
    assert has_element?(view, "#auth-json-import-form")
    assert has_element?(view, "#auth-json-import-paste-panel")
    assert has_element?(view, "#auth-json-import-file-dropzone")
    assert has_element?(view, "#auth_json_pool_id")
    assert has_element?(view, "#auth_json_content")
    assert_admin_dialog_docs_link(view, "auth-json-import-dialog-footer")

    html = render(view)

    assert html =~ "Codex CLI or Codex Desktop auth.json"
    assert html =~ "Paste contents"
    assert html =~ "Use this when the file is already open."
    assert html =~ "Drop auth.json"
    assert html =~ "Upload auth.json up to 64 KB."
    assert has_element?(view, "#auth-json-import-file-input input[type='file']")
    assert has_element?(view, "#auth-json-import-submit")

    view |> element("#auth-json-import-cancel") |> render_click()
    refute has_element?(view, "#auth-json-import-dialog")

    assert has_element?(view, "#upstream-account-#{identity.id}", "Primary Codex")
    assert has_element?(view, "#upstream-account-#{identity.id}-mail", "Primary Codex")

    refute has_element?(
             view,
             "#upstream-account-#{identity.id} header #upstream-account-#{identity.id}-state"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id} header[data-role='upstream-account-card-header'].flex-row.items-center.justify-between.py-3"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id} [data-role='upstream-account-actions'].shrink-0.self-center #upstream-account-actions-menu-#{identity.id}"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-header-actions.items-center.self-center #upstream-account-#{identity.id}-plan-label.self-center",
             "Team"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id} footer[data-role='upstream-account-card-footer'] #upstream-account-#{identity.id}-routing-readiness",
             "Routing ready"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-quota-readiness-contract",
             "Quota ready"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness [data-role='upstream-routing-cell']",
             "Routing"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness [data-role='upstream-pool-count-cell']",
             "1 Pool"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness [data-role='upstream-token-status-cell']",
             "Tokens/5m"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness [data-role='upstream-token-status-cell']",
             "700 tokens"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id} header #upstream-account-#{identity.id}-routing-readiness"
           )

    assert has_element?(view, "#upstream-account-#{identity.id}", "Status")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limits-summary.text-xs",
             "Active"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn.text-right #upstream-account-#{identity.id}-token-burn-label",
             "TOKEN BURN"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn-value.cursor-pointer[aria-haspopup='true'][aria-describedby='upstream-account-#{identity.id}-token-burn-content']",
             "x5"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn-value-popover[data-role='upstream-token-burn-popover'].dropdown-bottom"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn-value-popover.dropdown-hover"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn-content",
             "last 5 minutes"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn-content",
             "700 tokens"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-burn-content",
             "300 tokens"
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
             "Admin Upstreams"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{assignment.id}",
             "admin-upstreams"
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
    assert has_element?(view, "#upstream-account-#{identity.id}-limits.md\\:grid-cols-2")
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
             "5d 23h"
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
             "#upstream-account-#{identity.id}-limit-model-codex_spark-secondary-10080 [data-role='upstream-limit-title'].truncate",
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
    assert has_element?(view, "#upstream-account-#{browser_identity.id}-limits.grid.gap-3")
    refute has_element?(view, "#upstream-account-#{browser_identity.id}-limits.md\\:grid-cols-2")

    refute has_element?(view, "#upstream-account-#{browser_identity.id}-limit-primary_5h")
    refute has_element?(view, "#upstream-account-#{browser_identity.id}-limit-weekly-count")
    assert has_element?(view, "#upstream-account-#{browser_identity.id}-limit-weekly-reset")

    assert has_element?(
             view,
             "#upstream-account-#{browser_identity.id}-limit-weekly-progress[value='75']"
           )
  end

  @tag :upstream_quota_dashboard_regression
  @tag :upstream_quota_evidence_stability
  test "upstream cards keep persisted observed quota rows visible", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "regression-visible-quota-rows",
        name: "Regression Visible Quota Rows"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Regression Visible Rows Codex",
        assignment_label: "Regression Visible Rows assignment"
      })

    now = DateTime.utc_now()

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 credits: 64,
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_rate_limit_event",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 credits: 450,
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_rate_limit_event",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 quota_key: "codex_spark",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: "gpt-5.3-codex-spark",
                 display_label: "GPT-5.3-Codex-Spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("0"),
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_rate_limit_event",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 quota_key: "provider_codex_spark",
                 quota_scope: "upstream_model",
                 quota_family: "codex_model",
                 upstream_model: "provider-gpt-5.3-codex-spark",
                 display_label: "Provider GPT-5.3-Codex-Spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("0"),
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_rate_limit_event",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-primary_5h [data-role='upstream-limit-title']",
             "5h"
           )

    assert has_element?(view, "#upstream-account-#{identity.id}-limit-primary_5h", "not reported")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-weekly [data-role='upstream-limit-title']",
             "Weekly"
           )

    assert has_element?(view, "#upstream-account-#{identity.id}-limit-weekly", "not reported")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300",
             "100%"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-upstream_model-provider_codex_spark-primary-300",
             "100%"
           )
  end

  @tag :upstream_quota_evidence_stability
  test "quota cards distinguish colliding logical quota identities while collapsing source evidence",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "quota-card-presentation-identities",
        name: "Quota Card Presentation Identities"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Quota Card Presentation Codex",
        assignment_label: "Quota card presentation assignment"
      })

    now = DateTime.utc_now()

    model_alpha = %{
      quota_key: "shared_capacity",
      quota_scope: "model",
      quota_family: "alpha",
      model: "alpha",
      display_label: "Shared capacity",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("10"),
      reset_at: DateTime.add(now, 5, :hour),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: now
    }

    assert {:ok, [_model_alpha, _model_beta, _upstream_model_alpha, _upstream_model_beta]} =
             QuotaWindows.upsert_quota_windows(identity, [
               model_alpha,
               %{
                 model_alpha
                 | quota_family: "beta",
                   model: "beta",
                   used_percent: Decimal.new("20")
               },
               Map.merge(model_alpha, %{
                 quota_scope: "upstream_model",
                 upstream_model: "alpha",
                 model: nil,
                 used_percent: Decimal.new("30")
               }),
               Map.merge(model_alpha, %{
                 quota_scope: "upstream_model",
                 quota_family: "beta",
                 upstream_model: "beta",
                 model: nil,
                 used_percent: Decimal.new("40")
               })
             ])

    assert {:ok, [_same_logical_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 model_alpha
                 | source: "codex_response_headers",
                   observed_at: DateTime.add(now, 1, :minute)
               }
             ])

    assert identity
           |> QuotaWindows.list_evidence()
           |> Enum.count(&(&1.quota_key == "shared_capacity")) == 5

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])

    additional_limits =
      Enum.reject(account.quota_limits, &is_atom(&1.key))

    assert length(additional_limits) == 4

    assert Enum.map(additional_limits, & &1.key) ==
             Enum.uniq(Enum.map(additional_limits, & &1.key))

    assert Enum.map(additional_limits, & &1.label) ==
             Enum.uniq(Enum.map(additional_limits, & &1.label))

    assert Enum.sort(Enum.map(additional_limits, & &1.label)) == [
             "Shared capacity 5h (Model scope, Family alpha, Model alpha)",
             "Shared capacity 5h (Model scope, Family beta, Model beta)",
             "Shared capacity 5h (Upstream model scope, Family alpha, Upstream model alpha)",
             "Shared capacity 5h (Upstream model scope, Family beta, Upstream model beta)"
           ]

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")

    limit_ids =
      Regex.scan(~r/id="(upstream-account-#{identity.id}-limit-[^"]+)"/, html,
        capture: :all_but_first
      )
      |> List.flatten()

    assert limit_ids == Enum.uniq(limit_ids)

    for limit <- additional_limits do
      selector = "#upstream-account-#{identity.id}-limit-#{limit.key}"

      assert has_element?(view, selector)
      assert has_element?(view, "#{selector} [data-role='upstream-limit-title']", limit.label)
    end
  end

  @tag :upstream_quota_evidence_stability
  @tag :quota_runtime_source_transition
  test "credit-backed quota rows render striped progress bars", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "credit-backed-striped",
        name: "Credit Backed Striped"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Credit Backed Striped Codex",
        assignment_label: "Credit backed striped assignment"
      })

    now = DateTime.utc_now() |> DateTime.add(-60, :second)

    assert {:ok, [_credit_primary, _percent_weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 43_200,
                 active_limit: 4_192,
                 credits: 3_414,
                 used_percent: Decimal.new("18.5"),
                 reset_at: DateTime.add(now, 11, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("10"),
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    monthly_selector = "#upstream-account-#{identity.id}-limit-primary_30d"
    weekly_selector = "#upstream-account-#{identity.id}-limit-weekly"

    assert has_element?(view, "#{monthly_selector}-progress.progress-striped")
    assert has_element?(view, "#{weekly_selector}-progress")
    refute has_element?(view, "#{weekly_selector}-progress.progress-striped")
  end

  test "Spark zero-use quota stays visible while evidence sources change", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "spark-source-transition",
        name: "Spark Source Transition"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Spark Source Transition Codex",
        assignment_label: "Spark source transition assignment"
      })

    now = DateTime.utc_now() |> DateTime.add(-300, :second)
    usage_reset_at = DateTime.add(now, 5, :hour)

    zero_use_spark = %{
      quota_key: "codex_spark",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      display_label: "GPT-5.3-Codex-Spark",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("0"),
      reset_at: usage_reset_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: now
    }

    assert {:ok, [_usage_window]} =
             QuotaWindows.upsert_quota_windows(identity, [zero_use_spark])

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    selector = "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300"

    assert has_element?(view, selector, "100%")
    assert has_element?(view, "#{selector}-progress[value='100']")

    headers_observed_at = DateTime.add(now, 60, :second)

    assert {:ok, [_headers_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 zero_use_spark
                 | source: "codex_response_headers",
                   reset_at: DateTime.add(headers_observed_at, 5, :hour),
                   observed_at: headers_observed_at
               }
             ])

    assert [stored_headers_window] =
             identity
             |> QuotaWindows.list_quota_windows()
             |> Enum.filter(&(&1.quota_key == "codex_spark" and &1.window_kind == "primary"))

    assert stored_headers_window.source == "codex_response_headers"

    execute_scheduled_upstreams_reload(view)

    assert has_element?(view, selector, "100%")
    assert has_element?(view, "#{selector}-progress[value='100']")

    usage_observed_at = DateTime.add(now, 120, :second)

    assert {:ok, [_next_usage_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 zero_use_spark
                 | reset_at: DateTime.add(usage_observed_at, 5, :hour),
                   observed_at: usage_observed_at
               }
             ])

    assert stored_windows =
             identity
             |> QuotaWindows.list_evidence()
             |> Enum.filter(&(&1.quota_key == "codex_spark" and &1.window_kind == "primary"))

    assert Enum.sort(Enum.map(stored_windows, & &1.source)) ==
             ["codex_response_headers", "codex_usage_api"]

    execute_scheduled_upstreams_reload(view)

    assert has_element?(view, selector, "100%")
    assert has_element?(view, "#{selector}-progress[value='100']")
  end

  @tag :upstream_quota_dashboard_regression
  test "usage API observed zero-use evidence renders the account quota as fully remaining",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "regression-zero-zero-quota",
        name: "Regression Zero Zero Quota"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Regression Zero Zero Codex",
        assignment_label: "Regression Zero Zero assignment"
      })

    now = DateTime.utc_now()

    assert {:ok, [_primary_window, _weekly_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("0"),
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("15"),
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    primary = Enum.find(account.quota_limits, &(&1.key == :primary_5h))
    weekly = Enum.find(account.quota_limits, &(&1.key == :weekly))

    assert Decimal.equal?(primary.percent, Decimal.new("100"))
    assert primary.percent_value == 100
    assert primary.percent_label == "100%"
    assert weekly.percent == Decimal.new("85.000")
    assert weekly.percent_value == 85
    assert weekly.percent_label == "85%"

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    violations =
      [
        account.quota_readiness.state == "weekly_only_probe" ||
          "expected zero/zero primary plus nonzero weekly evidence to project weekly_only_probe readiness",
        account.quota_readiness.label == "Weekly quota probe" ||
          "expected zero/zero primary plus nonzero weekly evidence to render Weekly quota probe",
        account.quota_readiness.tone == :warning ||
          "expected zero/zero primary plus nonzero weekly evidence to render warning tone",
        account.quota_readiness.routing_ready_now? ||
          "expected zero/zero primary plus nonzero weekly evidence to stay routing-eligible",
        has_element?(
          view,
          "#upstream-account-#{identity.id}-limit-primary_5h [data-role='upstream-limit-title']",
          "5h"
        ) ||
          "expected zero/zero usage API account evidence to keep the 5h quota row visible",
        has_element?(
          view,
          "#upstream-account-#{identity.id}-limit-primary_5h",
          "100%"
        ) ||
          "expected observed zero-use account evidence to render the 5h quota as 100% remaining",
        has_element?(
          view,
          "#upstream-account-#{identity.id}-limit-primary_5h-progress[value='100']"
        ) ||
          "expected observed zero-use account evidence to render a full 5h quota meter",
        has_element?(view, "#upstream-account-#{identity.id}-limit-primary_5h-reset") ||
          "expected observed zero-use account evidence to retain the provider reset countdown",
        has_element?(view, "#upstream-account-#{identity.id}-limit-weekly", "85%") ||
          "expected nonzero weekly usage API account evidence to render 85% remaining",
        not has_element?(
          view,
          "#upstream-account-#{identity.id}-routing-readiness [data-role='upstream-routing-cell']",
          "Quota ready"
        ) ||
          "expected zero/zero primary plus nonzero weekly evidence not to render clean Quota ready"
      ]
      |> Enum.reject(&(&1 == true))

    assert violations == [],
           "expected observed zero-use account quota card semantics; violations: #{Enum.join(violations, "; ")}"
  end

  test "account quota rows show reset-bearing observed zero-use evidence as fully remaining", %{
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "zero-percent-only-upstream", name: "Zero Percent Pool"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Zero Percent Codex",
        assignment_label: "Zero Percent assignment"
      })

    now = DateTime.utc_now()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("0"),
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    weekly = Enum.find(account.quota_limits, &(&1.key == :weekly))

    assert Decimal.equal?(weekly.percent, Decimal.new("100"))
    assert weekly.percent_value == 100
    assert weekly.percent_label == "100%"
  end

  @tag :upstream_quota_dashboard_regression
  test "account quota rows keep nonzero percent-only usage visible", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "nonzero-percent-only-upstream",
        name: "Nonzero Percent Pool"
      })

    %{identity: first_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Nonzero Percent 17 Codex",
        assignment_label: "Nonzero Percent 17 assignment"
      })

    %{identity: second_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Nonzero Percent 15 Codex",
        assignment_label: "Nonzero Percent 15 assignment"
      })

    now = DateTime.utc_now()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(first_identity, [
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("17"),
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(second_identity, [
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("15"),
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    accounts =
      scope
      |> UpstreamAccountsReadModel.list_visible_accounts([pool])
      |> Map.new(&{&1.identity.id, &1})

    first_weekly = accounts |> Map.fetch!(first_identity.id) |> quota_limit!(:weekly)
    second_weekly = accounts |> Map.fetch!(second_identity.id) |> quota_limit!(:weekly)

    assert first_weekly.percent == Decimal.new("83.000")
    assert first_weekly.percent_value == 83
    assert first_weekly.percent_label == "83%"

    assert second_weekly.percent == Decimal.new("85.000")
    assert second_weekly.percent_value == 85
    assert second_weekly.percent_label == "85%"

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{first_identity.id}-limit-weekly", "83%")
    assert has_element?(view, "#upstream-account-#{second_identity.id}-limit-weekly", "85%")
  end

  @tag :upstream_quota_evidence_stability
  test "model quota rows show reset-bearing observed zero usage evidence", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "zero-model-percent-upstream",
        name: "Zero Model Percent Pool"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Zero Model Codex",
        assignment_label: "Zero Model assignment"
      })

    now = DateTime.utc_now()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "codex_spark",
                 quota_scope: "model",
                 quota_family: "codex_spark",
                 model: "gpt-5.3-codex-spark",
                 display_label: "GPT-5.3-Codex-Spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("0"),
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])

    spark =
      account
      |> Map.fetch!(:quota_limits)
      |> Enum.find(fn %{key: key} ->
        is_binary(key) and String.starts_with?(key, "model-codex_spark-primary-300")
      end)

    assert Decimal.equal?(spark.percent, Decimal.new("100"))
    assert spark.percent_value == 100
    assert spark.percent_label == "100%"

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    selector = "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300"

    assert has_element?(view, selector, "100%")
    assert has_element?(view, "#{selector}-progress[value='100']")
    assert has_element?(view, "#{selector}-reset")
  end

  @tag :upstream_quota_evidence_stability
  test "monthly credit-only account quota shows known credits without fabricated capacity", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "credit-only-monthly-upstream",
        name: "Credit Only Monthly Pool"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Credit Only Monthly Codex",
        assignment_label: "Credit Only Monthly assignment"
      })

    now = DateTime.utc_now()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 quota_scope: "account",
                 quota_family: "account",
                 window_kind: "primary",
                 window_minutes: 43_200,
                 credits: 3817,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(now, 15, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    monthly = Enum.find(account.quota_limits, &(&1.key == :primary_30d))

    assert monthly.percent_label == "not reported"
    assert monthly.count_label == "3,817 credits"

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}-limit-primary_30d", "30d")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-primary_30d",
             "not reported"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-primary_30d-count",
             "3,817 credits"
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
    assert_admin_dialog_docs_link(view, "rename-upstream-account-dialog-footer")

    view
    |> element("#rename-upstream-account-form")
    |> render_submit(%{"rename" => %{"account_label" => " Renamed Codex "}})

    refute has_element?(view, "#rename-upstream-account-dialog")
    assert has_element?(view, "#upstream-account-#{identity.id}", "Renamed Codex")
    refute has_element?(view, "#upstream-account-#{identity.id}", "Original Codex")

    assert Repo.get!(UpstreamIdentity, identity.id).account_label == "Renamed Codex"
  end

  test "confirms upstream account deletion from the account actions menu", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "delete-upstream", name: "Delete Upstream"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Delete Codex",
        account_identifier: "delete@example.com"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    view
    |> element("#delete-upstream-account-#{identity.id}")
    |> render_click()

    assert has_element?(view, "#delete-upstream-account-dialog[open]", "Delete Codex")
    assert has_element?(view, "#delete-upstream-account-form")
    assert_admin_dialog_docs_link(view, "delete-upstream-account-dialog-footer")
    assert Repo.get!(UpstreamIdentity, identity.id).status == "active"

    view
    |> element("#delete-upstream-account-form")
    |> render_submit(%{
      "upstream_delete" => %{
        "id" => identity.id,
        "confirmation_label" => "wrong label"
      }
    })

    assert has_element?(view, "#delete-upstream-account-dialog[open]")
    assert has_element?(view, "#delete-upstream-account-form", "type the account label exactly")
    assert Repo.get!(UpstreamIdentity, identity.id).status == "active"

    view
    |> element("#delete-upstream-account-form")
    |> render_submit(%{
      "upstream_delete" => %{
        "id" => identity.id,
        "confirmation_label" => "Delete Codex"
      }
    })

    refute has_element?(view, "#delete-upstream-account-dialog")
    assert Repo.get!(UpstreamIdentity, identity.id).status == "deleted"
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
      {"unknown", "Quota missing", "Quota missing", "Priming pending"},
      {"refreshing", "Quota missing", "Quota missing", "Reconciling quota"},
      {"known", "Routing ready", "Quota ready", "Quota known"},
      {"weekly_only_probe", "Routing ready", "Weekly quota probe", "Weekly-only probe"},
      {"stale", "Quota missing", "Quota missing", "Quota stale"},
      {"expired", "Quota missing", "Quota missing", "Quota expired"},
      {"failed", "Quota missing", "Quota missing", "Quota failed"},
      {"blocked", "Quota missing", "Quota missing", "Priming blocked"}
    ]

    for {status, routing_label, quota_label, assignment_label} <- cases do
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
               routing_label
             )

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}-quota-readiness-contract",
               quota_label
             )

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}-assignment-#{assignment.id}-quota-priming",
               assignment_label
             )

      refute has_element?(
               view,
               "#upstream-account-#{identity.id}-routing-readiness",
               "Routing candidate"
             )
    end
  end

  test "projects live quota readiness separately from auth and priming metadata", %{scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "quota-readiness", name: "Quota Readiness"})

    %{identity: weekly_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Weekly probe Codex",
        assignment_label: "Weekly probe assignment",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "weekly_only_probe",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z",
            "reason" => %{
              "code" => "weekly_only_probe_reason",
              "message" => "Synthetic weekly-only probe state"
            }
          }
        }
      })

    assert {:ok, [_window]} = maybe_insert_quota_window(weekly_identity, "weekly_only_probe")

    %{identity: exhausted_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Exhausted Codex",
        assignment_label: "Exhausted assignment",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z",
            "reason" => %{
              "code" => "known_reason",
              "message" => "Synthetic known state"
            }
          }
        }
      })

    now = DateTime.utc_now()

    assert {:ok, [_primary_window, _weekly_window]} =
             QuotaWindows.upsert_quota_windows(exhausted_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("10"),
                 reset_at: DateTime.add(now, 900, :second),
                 source: "codex_usage",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(now, 900, :second),
                 source: "codex_usage",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    accounts = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    accounts_by_identity = Map.new(accounts, &{&1.identity.id, &1})

    assert_quota_readiness_snapshot(Map.fetch!(accounts_by_identity, weekly_identity.id),
      state: "weekly_only_probe",
      label: "Weekly quota probe",
      tone: :warning,
      routing_ready_now?: true,
      priming_status: "weekly_only_probe",
      priming_label: "Weekly-only probe",
      primary_window?: false,
      weekly_window?: true
    )

    assert_quota_readiness_snapshot(Map.fetch!(accounts_by_identity, exhausted_identity.id),
      state: "exhausted",
      label: "Quota exhausted",
      tone: :error,
      routing_ready_now?: false,
      priming_status: "known",
      priming_label: "Quota known",
      primary_window?: true,
      weekly_window?: true
    )
  end

  test "renders live quota readiness on upstream account cards", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "live-card-readiness", name: "Live Card Readiness"})

    %{identity: exhausted_identity, assignment: exhausted_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Exhausted card Codex",
        assignment_label: "Exhausted card assignment",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z"
          }
        }
      })

    now = DateTime.utc_now()

    assert {:ok, [_primary_window, _weekly_window]} =
             QuotaWindows.upsert_quota_windows(exhausted_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("10"),
                 reset_at: DateTime.add(now, 900, :second),
                 source: "codex_usage",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(now, 900, :second),
                 source: "codex_usage",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    %{identity: ready_identity, assignment: ready_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Ready card Codex",
        assignment_label: "Ready card assignment",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z"
          }
        }
      })

    assert {:ok, [_ready_window]} = maybe_insert_quota_window(ready_identity, "known")

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{exhausted_identity.id}[data-routing-tone='error']"
           )

    refute has_element?(
             view,
             "#upstream-account-#{exhausted_identity.id}[data-routing-tone='success']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{exhausted_identity.id}-routing-readiness",
             "Quota exhausted"
           )

    refute has_element?(
             view,
             "#upstream-account-#{exhausted_identity.id}-routing-readiness",
             "Routing candidate"
           )

    assert has_element?(
             view,
             "#upstream-account-#{exhausted_identity.id}-assignment-#{exhausted_assignment.id}-quota-priming",
             "Quota known"
           )

    assert has_element?(
             view,
             "#upstream-account-#{ready_identity.id}[data-routing-tone='success']"
           )

    assert has_element?(
             view,
             "#upstream-account-#{ready_identity.id}-routing-readiness",
             "Routing ready"
           )

    assert has_element?(
             view,
             "#upstream-account-#{ready_identity.id}-quota-readiness-contract",
             "Quota ready"
           )

    assert has_element?(
             view,
             "#upstream-account-#{ready_identity.id}-assignment-#{ready_assignment.id}-quota-priming",
             "Quota known"
           )
  end

  test "renders the upstream routing readiness matrix with stable selectors", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "routing-status-matrix", name: "Routing Status Matrix"})

    cases = [
      %{
        readiness_state: "ready",
        quota_state: "ready",
        expected_tone: "success",
        expected_label: "Routing ready",
        expected_quota_label: "Quota ready",
        priming_status: "known",
        priming_label: "Quota known"
      },
      %{
        readiness_state: "weekly_only_probe",
        quota_state: "weekly_only_probe",
        expected_tone: "success",
        expected_label: "Routing ready",
        expected_quota_label: "Weekly quota probe",
        priming_status: "weekly_only_probe",
        priming_label: "Weekly-only probe"
      },
      %{
        readiness_state: "exhausted",
        quota_state: "exhausted",
        expected_tone: "error",
        expected_label: "Quota exhausted",
        expected_quota_label: "Quota exhausted",
        priming_status: "known",
        priming_label: "Quota known"
      },
      %{
        readiness_state: "stale",
        quota_state: "stale",
        expected_tone: "warning",
        expected_label: "Quota refresh needed",
        expected_quota_label: "Quota refresh needed",
        priming_status: "known",
        priming_label: "Quota known"
      },
      %{
        readiness_state: "missing",
        quota_state: "missing",
        expected_tone: "warning",
        expected_label: "Quota missing",
        expected_quota_label: "Quota missing",
        priming_status: "unknown",
        priming_label: "Priming pending"
      }
    ]

    for routing_case <- cases do
      %{identity: identity, assignment: assignment} =
        upstream_assignment_fixture(pool, %{
          account_label: "Routing #{routing_case.readiness_state} Codex",
          assignment_label: "Routing #{routing_case.readiness_state} assignment",
          assignment_metadata: %{
            "quota_priming" => %{
              "status" => routing_case.priming_status,
              "trigger_kind" => "account_link",
              "enqueued_at" => "2026-05-22T00:00:00Z",
              "reason" => %{
                "code" => "#{routing_case.priming_status}_reason",
                "message" => "Synthetic #{routing_case.priming_label} state"
              }
            }
          }
        })

      assert {:ok, _windows} = insert_routing_quota_windows(identity, routing_case.quota_state)

      {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}[data-routing-tone='#{routing_case.expected_tone}']"
             ),
             routing_case.readiness_state

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}-routing-readiness",
               routing_case.expected_label
             )

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}-quota-readiness-contract",
               routing_case.expected_quota_label
             )

      assert has_element?(
               view,
               "#upstream-account-#{identity.id}-assignment-#{assignment.id}-quota-priming",
               routing_case.priming_label
             )

      refute has_element?(
               view,
               "#upstream-account-#{identity.id}-routing-readiness",
               "Routing candidate"
             )
    end
  end

  test "keeps assignment priming visible while live readiness comes from quota windows", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "priming-separation", name: "Priming Separation"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Priming separated Codex",
        assignment_label: "Priming separated assignment",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z",
            "reason" => %{
              "code" => "known_reason",
              "message" => "Synthetic known state"
            }
          }
        }
      })

    assert {:ok, _windows} = insert_routing_quota_windows(identity, "stale")

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}[data-routing-tone='warning']")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Quota refresh needed"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{assignment.id}-quota-priming",
             "Quota known"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Quota known"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Routing candidate"
           )
  end

  test "keeps blocked quota readiness separate from missing routing readiness" do
    blocked_id = Ecto.UUID.generate()
    blocked_assignment = recovery_component_assignment(Ecto.UUID.generate(), "Blocked Pool")

    blocked_account =
      recovery_component_account(blocked_id, "active", [blocked_assignment])
      |> Map.put(:quota_readiness, %{
        state: "blocked",
        label: "Quota blocked",
        tone: :warning,
        routing_ready_now?: false,
        reason_codes: ["quota_window_unusable", "not_fresh"],
        primary_window: nil,
        weekly_window: nil
      })

    blocked_html =
      render_component(&AccountCard.account_card/1,
        account: blocked_account,
        account_index: 0
      )

    assert blocked_html =~ ~s(id="upstream-account-#{blocked_id}")
    assert blocked_html =~ ~s(id="upstream-account-#{blocked_id}-routing-readiness")

    card_class = html_element_class(blocked_html, "upstream-account-#{blocked_id}")

    assert card_class =~ "border-base-300"
    assert blocked_html =~ ~s(data-routing-tone="warning")
    refute card_class =~ "shadow-sm"

    assert [_match, routing_contract] =
             Regex.run(
               ~r/<section id="upstream-account-#{blocked_id}-routing-readiness-contract">(.*?)<\/section>/s,
               blocked_html
             )

    assert routing_contract =~ "Routing unavailable"
    refute routing_contract =~ "Quota blocked"

    assert [_match, quota_contract] =
             Regex.run(
               ~r/<section id="upstream-account-#{blocked_id}-quota-readiness-contract">(.*?)<\/section>/s,
               blocked_html
             )

    assert quota_contract =~ "Quota blocked"

    refute blocked_html =~ "Routing candidate"
  end

  test "keeps status and auth diagnostics separate from quota readiness", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "card-auth-separation", name: "Card Auth Separation"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Auth separated Codex",
        identity_status: "refresh_due",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "failed",
            "reason" => %{
              "code" => "synthetic_refresh_failure",
              "message" => "synthetic refresh failed"
            }
          }
        },
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z"
          }
        }
      })

    assert {:ok, [_window]} = maybe_insert_quota_window(identity, "known")

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}[data-routing-tone='warning']")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Token refresh due"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-quota-readiness-contract",
             "Quota ready"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limits-summary",
             "Refresh due"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-token-refresh",
             "token refresh failed: synthetic refresh failed (synthetic_refresh_failure)"
           )
  end

  test "renders lifecycle-blocked routing for refresh-failed accounts with fresh quota", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "refresh-failed-routing",
        name: "Refresh Failed Routing"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Refresh Failed Routing Codex",
        identity_status: "refresh_failed",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "failed",
            "reason" => %{
              "code" => "codex_oauth_refresh_failed",
              "message" => "upstream OAuth refresh failed"
            }
          }
        },
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z"
          }
        }
      })

    assert {:ok, [_window]} = maybe_insert_quota_window(identity, "known")

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    assert account.quota_readiness.label == "Quota ready"
    assert account.quota_readiness.routing_ready_now? == true
    assert account.routing_readiness.label == "Auth refresh failed"
    assert account.routing_readiness.routing_ready_now? == false
    assert account.routing_readiness.reason_code == "identity_refresh_failed"

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}[data-routing-tone='error']")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness [data-role='upstream-routing-cell']",
             "Auth refresh failed"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness [data-role='upstream-routing-cell']",
             "Quota ready"
           )

    reconciliation_selector = "#upstream-account-#{identity.id}-reconciliation-status"
    assert_single_element(view, reconciliation_selector, "Token refresh failed")
    assert has_element?(view, reconciliation_selector, "excluded from runtime routing")

    assert has_element?(
             view,
             reconciliation_selector,
             "token refresh succeeds or credentials are relinked"
           )

    assert has_element?(view, reconciliation_selector, "upstream OAuth refresh failed")
    assert has_element?(view, reconciliation_selector, "codex_oauth_refresh_failed")
    refute has_element?(view, "#upstream-account-#{identity.id}-reconciliation-recovery")
    refute has_element?(view, "#upstream-account-#{identity.id}-refresh-failed-warning")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-quota-readiness-contract",
             "Quota ready"
           )
  end

  test "account card reconciliation status supersedes stale weekly quota with safe recovery", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "stale-weekly-recovery", name: "Stale Weekly Recovery"})

    raw_provider_marker = "raw-provider-marker-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Stale Weekly Recovery Codex",
        identity_status: "reauth_required",
        assignment_metadata: %{
          "last_reconciliation" => %{
            "status" => "failed",
            "finished_at" => DateTime.add(now, -60, :second) |> DateTime.to_iso8601(),
            "steps" => [
              %{
                "status" => "failed",
                "code" => "quota_refresh_auth_unavailable",
                "message" => raw_provider_marker
              }
            ]
          }
        }
      })

    assignment
    |> PoolUpstreamAssignment.changeset(%{
      last_successful_refresh_at: DateTime.add(now, -600, :second)
    })
    |> Repo.update!()

    assert {:ok, [_weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 100,
                 credits: 75,
                 used_percent: Decimal.new("25"),
                 reset_at: DateTime.add(now, 4, :hour),
                 freshness_state: "stale",
                 observed_at: DateTime.add(now, -900, :second),
                 last_sync_at: DateTime.add(now, -900, :second)
               }
             ])

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")
    prefix = "upstream-account-#{identity.id}"

    assert has_element?(
             view,
             "##{prefix}-reconciliation-status[data-reconciliation-status='failed']"
           )

    assert_single_element(view, "##{prefix}-reconciliation-title", "Reauthentication required")

    assert has_element?(
             view,
             "##{prefix}-reconciliation-reason",
             "quota refresh authentication unavailable"
           )

    refute has_element?(view, "##{prefix}-reconciliation-recovery")
    assert has_element?(view, "##{prefix}-last-successful-refresh")
    assert has_element?(view, "##{prefix}-quota-evidence-age")
    refute has_element?(view, "##{prefix}-reauth-warning")
    refute html =~ raw_provider_marker
  end

  test "projects a happy-path account as quota ready", %{scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "quota-ready", name: "Quota Ready"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Ready Codex",
        assignment_label: "Ready assignment",
        assignment_metadata: %{
          "quota_priming" => %{
            "status" => "known",
            "trigger_kind" => "account_link",
            "enqueued_at" => "2026-05-22T00:00:00Z",
            "reason" => %{
              "code" => "known_reason",
              "message" => "Synthetic known state"
            }
          }
        }
      })

    assert {:ok, [_window]} = maybe_insert_quota_window(identity, "known")

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])

    assert_quota_readiness_snapshot(account,
      state: "ready",
      label: "Quota ready",
      tone: :success,
      routing_ready_now?: true,
      priming_status: "known",
      priming_label: "Quota known",
      primary_window?: true,
      weekly_window?: false
    )

    assert account.routing_readiness.routing_ready_now? == true
    assert account.routing_readiness.label == "Routing ready"
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

    execute_scheduled_upstreams_reload(view)

    assert has_element?(view, "#upstream-account-#{identity.id}", "realtime@example.com")
    refute has_element?(view, "#upstream-account-#{identity.id}", "acct_realtime")
  end

  test "coalesces upstream event bursts before reloading", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "upstream-event-burst", name: "Upstream Event Burst"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert {:ok, _event} =
             Events.broadcast_upstreams(pool.id, "quota_priming_updated", %{"sequence" => 1})

    state = :sys.get_state(view.pid)
    timer = state.socket.assigns[:upstreams_reload_timer]
    assert is_reference(timer)

    assert {:ok, _event} =
             Events.broadcast_upstreams(pool.id, "quota_priming_updated", %{"sequence" => 2})

    state = :sys.get_state(view.pid)
    assert state.socket.assigns[:upstreams_reload_timer] == timer

    Process.cancel_timer(timer, async: false, info: false)
    send(view.pid, :reload_upstreams_from_events)

    state = :sys.get_state(view.pid)
    assert is_nil(state.socket.assigns[:upstreams_reload_timer])
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
                 active_limit: 100,
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

    execute_scheduled_upstreams_reload(view)

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300",
             "80%"
           )
  end

  @tag :upstream_quota_evidence_stability
  test "refresh keeps model limits visible when a weak zero quota update arrives", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "realtime-weak-zero-model-quota",
        name: "Realtime Weak Zero Model Quota"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Realtime Weak Zero Model Codex",
        assignment_label: "Realtime weak zero model assignment"
      })

    now = DateTime.utc_now() |> DateTime.add(-300, :second)
    primary_reset_at = DateTime.add(now, 2, :hour)
    weekly_reset_at = DateTime.add(now, 5, :day)
    weak_observed_at = DateTime.add(now, 60, :second)
    weak_primary_reset_at = DateTime.add(weak_observed_at, 5, :hour)
    weak_weekly_reset_at = DateTime.add(weak_observed_at, 7, :day)

    assert {:ok, [_primary, _weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "codex_spark",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: "gpt-5.3-codex-spark",
                 display_label: "GPT-5.3-Codex-Spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("1"),
                 reset_at: primary_reset_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               },
               %{
                 quota_key: "codex_spark",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: "gpt-5.3-codex-spark",
                 display_label: "GPT-5.3-Codex-Spark",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("15"),
                 reset_at: weekly_reset_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    primary_selector =
      "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300"

    weekly_selector =
      "#upstream-account-#{identity.id}-limit-model-codex_spark-secondary-10080"

    assert has_element?(view, primary_selector, "99%")
    assert has_element?(view, weekly_selector, "85%")

    assert {:ok, [_primary, _weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "codex_spark",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: "gpt-5.3-codex-spark",
                 display_label: "GPT-5.3-Codex-Spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("0"),
                 reset_at: weak_primary_reset_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: weak_observed_at
               },
               %{
                 quota_key: "codex_spark",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: "gpt-5.3-codex-spark",
                 display_label: "GPT-5.3-Codex-Spark",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("0"),
                 reset_at: weak_weekly_reset_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: weak_observed_at
               }
             ])

    execute_scheduled_upstreams_reload(view)

    assert has_element?(view, primary_selector, "99%")
    assert has_element?(view, weekly_selector, "85%")
    refute has_element?(view, primary_selector, "not reported")
    refute has_element?(view, weekly_selector, "not reported")
  end

  @tag :upstream_quota_evidence_stability
  test "refresh keeps account limits visible when a weak zero quota update arrives", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "realtime-weak-zero-quota",
        name: "Realtime Weak Zero Quota"
      })

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Realtime Weak Zero Codex",
        assignment_label: "Realtime weak zero assignment"
      })

    now = DateTime.utc_now()
    reset_at = DateTime.add(now, 2, :hour)
    weak_observed_at = DateTime.add(now, 60, :second)
    weak_reset_at = DateTime.add(weak_observed_at, 4, :hour)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 quota_scope: "account",
                 quota_family: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("11"),
                 reset_at: reset_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: now
               }
             ])

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}-limit-primary_5h", "89%")

    assert {:ok, [_merged]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 quota_scope: "account",
                 quota_family: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 0,
                 credits: 0,
                 used_percent: Decimal.new("0"),
                 reset_at: weak_reset_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: weak_observed_at
               }
             ])

    execute_scheduled_upstreams_reload(view)

    assert has_element?(view, "#upstream-account-#{identity.id}-limit-primary_5h", "89%")

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-primary_5h",
             "not reported"
           )
  end

  test "refreshes quota limits when worker quota notifications arrive through postgres relay", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "postgres-relay-quota", name: "Postgres Relay Quota"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Postgres Relay Codex",
        assignment_label: "Postgres relay assignment"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, [window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "gpt_5_3_codex_spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 100,
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

    later_reset = DateTime.add(now, 7, :hour)

    window
    |> AccountQuotaWindow.changeset(%{used_percent: Decimal.new("20"), reset_at: later_reset})
    |> Repo.update!()

    event = %Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool.id,
      topics: ["upstreams"],
      reason: "upstream_quota_windows_updated",
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{
        "assignment_id" => assignment.id,
        "upstream_identity_id" => identity.id,
        "upstream_status" => identity.status,
        "assignment_status" => assignment.status
      }
    }

    assert {:ok, payload} = Events.event_to_postgres_payload(event)
    assert :ok = PostgresBridge.relay_payload(payload)
    execute_scheduled_upstreams_reload(view)

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-limit-model-codex_spark-primary-300",
             "80%"
           )
  end

  test "refreshes assignment priming metadata without driving card routing readiness", %{
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
             "Quota missing"
           )

    assert {:ok, _assignment} =
             PrimingState.record(pool, assignment, %{
               "status" => "weekly_only_probe",
               "trigger_kind" => "test",
               "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             })

    execute_scheduled_upstreams_reload(view)

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{assignment.id}-quota-priming",
             "Weekly-only probe"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Quota missing"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-routing-readiness",
             "Weekly quota probe"
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
    datetime_preferences = DateTimeDisplay.preferences_for_user(scope.user)

    assignment
    |> PoolUpstreamAssignment.changeset(%{last_successful_refresh_at: refreshed_at})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}",
             "quota refresh #{DateTimeDisplay.format_datetime(refreshed_at, datetime_preferences)}"
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
    datetime_preferences = DateTimeDisplay.preferences_for_user(scope.user)

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
             DateTimeDisplay.format_datetime(auth_fresh_at, datetime_preferences)
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-auth-verified",
             DateTimeDisplay.format_datetime(auth_verified_at, datetime_preferences)
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-access-token",
             "access token expired #{DateTimeDisplay.format_datetime(access_expires_at, datetime_preferences)}"
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

  test "renders projection-backed auth expiration beneath the account header", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-expiration", name: "Auth Expiration"})

    future_expires_at = DateTime.add(DateTime.utc_now(), 2, :hour)
    past_expires_at = DateTime.add(DateTime.utc_now(), -2, :hour)

    %{identity: future_identity} =
      active_upstream_assignment_fixture(pool, %{
        account_label: "Future Auth Expiration",
        metadata: %{"access_token_expires_at" => DateTime.to_iso8601(future_expires_at)}
      })

    %{identity: past_identity} =
      active_upstream_assignment_fixture(pool, %{
        account_label: "Past Auth Expiration",
        metadata: %{"access_token_expires_at" => DateTime.to_iso8601(past_expires_at)}
      })

    %{identity: missing_identity} =
      active_upstream_assignment_fixture(pool, %{account_label: "Missing Auth Expiration"})

    %{identity: malformed_identity} =
      active_upstream_assignment_fixture(pool, %{
        account_label: "Malformed Auth Expiration",
        metadata: %{"access_token_expires_at" => "not-a-timestamp"}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(
             view,
             "#upstream-account-#{future_identity.id}-auth-expiration[title]",
             "Auth expires"
           )

    assert has_element?(
             view,
             "#upstream-account-#{past_identity.id}-auth-expiration[title]",
             "Auth expired"
           )

    for identity <- [missing_identity, malformed_identity] do
      selector = "#upstream-account-#{identity.id}-auth-expiration"

      assert has_element?(view, selector, "Expiration unavailable")
      refute has_element?(view, "#{selector}[title]")
      refute has_element?(view, selector, "No expiration")
    end

    assert has_element?(
             view,
             "#upstream-account-#{future_identity.id} header #upstream-account-#{future_identity.id}-mail"
           )

    assert has_element?(
             view,
             "#upstream-account-#{future_identity.id} header #upstream-account-#{future_identity.id}-header-actions"
           )

    refute has_element?(
             view,
             "#upstream-account-#{future_identity.id} header #upstream-account-#{future_identity.id}-routing-readiness"
           )
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
             "#upstream-account-#{identity.id}-plan-label.dropdown-end.dropdown-bottom"
           )

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
             "Shared Source"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{source_assignment.id}",
             "shared-source"
           )

    assert has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{target_assignment.id}",
             "Shared Target"
           )

    refute has_element?(
             view,
             "#upstream-account-#{identity.id}-assignment-#{target_assignment.id}",
             "shared-target"
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

  test "personal access token auth.json is rejected without echoing the token", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "auth-json-pat", name: "auth.json PAT"})

    personal_access_token = "at-admin-pat-do-not-render-#{System.unique_integer([:positive])}"

    unsupported_auth_json =
      Jason.encode!(%{
        "auth_mode" => "personalAccessToken",
        "personalAccessToken" => personal_access_token
      })

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    open_auth_json_import_dialog(view)

    html =
      view
      |> element("#auth-json-import-form")
      |> render_submit(%{
        "auth_json" => %{
          "pool_id" => pool.id,
          "content" => unsupported_auth_json
        }
      })

    assert has_element?(view, "#auth-json-import-dialog[open]")

    assert has_element?(
             view,
             "#auth-json-import-form",
             "Codex personal access token auth.json is not supported in this cycle"
           )

    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
    assert Repo.aggregate(EncryptedSecret, :count) == 0
    refute html =~ personal_access_token
    refute render(view) =~ personal_access_token
    refute render(view) =~ unsupported_auth_json
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

  @tag :recovery_actions
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
            chatgpt_account_id: "acct-#{status}-#{System.unique_integer([:positive])}",
            account_email: email,
            account_label: "Recover #{status}",
            identity_status: status,
            identity_metadata: blocked_auth_metadata(status)
          })

        {identity, email}
      end

    fallback_email = "fallback-#{System.unique_integer([:positive])}@example.com"

    %{identity: fallback_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: fallback_email,
        account_label: "Fallback account label",
        identity_status: "paused",
        identity_metadata: blocked_auth_metadata("failed")
      })

    account_email = "stored-#{System.unique_integer([:positive])}@example.com"

    %{identity: account_email_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct-renamed-not-an-email",
        account_email: account_email,
        account_label: "Renamed account label",
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
               "#oauth-relink-upstream-account-#{identity.id}",
               "Relink account"
             )

      assert has_element?(view, "#oauth-relink-upstream-account-#{identity.id} .hero-link")

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

    encoded_account_email = URI.encode_www_form(account_email)

    assert has_element?(
             view,
             "#reinvite-upstream-account-#{account_email_identity.id}[href*='invited_email=#{encoded_account_email}']",
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
             "Recovery Actions"
           )

    pool_select_html = view |> element("#auth_json_pool_id") |> render()
    refute pool_select_html =~ "recovery-actions"

    reauth_identity =
      identities
      |> Enum.map(&elem(&1, 0))
      |> Enum.find(&(&1.status == "reauth_required"))

    reconciliation_selector = "#upstream-account-#{reauth_identity.id}-reconciliation-status"
    assert has_element?(view, reconciliation_selector, "Reauthentication required")
    refute has_element?(view, "#upstream-account-#{reauth_identity.id}-reconciliation-recovery")
    refute has_element?(view, "#upstream-account-#{reauth_identity.id}-reauth-warning")
  end

  @tag :provider_auth_recovery
  test "provider auth reauth state alone exposes authorized recovery controls without leaking evidence",
       %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "provider-auth-recovery", name: "Provider Auth Recovery"})

    private_marker = "provider-auth-private-marker-#{System.unique_integer([:positive])}"

    %{identity: reauth_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct-provider-auth-recovery",
        account_label: "Provider auth recovery",
        identity_status: "reauth_required",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "reauth_required",
            "trigger_kind" => "account_reconciliation",
            "reason" => %{
              "code" => "provider_usage_auth_rejected",
              "message" => "provider usage authentication was rejected"
            }
          },
          "private_provider_evidence" => private_marker
        }
      })

    %{identity: active_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct-provider-auth-active",
        account_label: "Active provider auth",
        identity_status: "active"
      })

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{reauth_identity.id}-reconciliation-status")

    assert has_element?(
             view,
             "#oauth-relink-upstream-account-#{reauth_identity.id}",
             "Relink account"
           )

    assert has_element?(
             view,
             "#replace-auth-json-upstream-account-#{reauth_identity.id}",
             "Replace auth.json"
           )

    refute has_element?(view, "#oauth-relink-upstream-account-#{active_identity.id}")
    refute has_element?(view, "#replace-auth-json-upstream-account-#{active_identity.id}")
    refute html =~ private_marker

    logged_out_conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/login"}}} = live(logged_out_conn, ~p"/admin/upstreams")
  end

  @tag :recovery_actions
  @tag :recovery_actions_edge_cases
  test "recovery actions stay safe for no-assignment, deleted, usable auth, and invalid pool cases",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "recovery-edge", name: "Recovery Edge"})

    no_assignment_id = Ecto.UUID.generate()

    no_assignment_html =
      render_component(&AccountCard.account_card/1,
        account: recovery_component_account(no_assignment_id, "paused", []),
        account_index: 0
      )

    assert no_assignment_html =~ ~s(id="replace-auth-json-upstream-account-#{no_assignment_id}")
    assert no_assignment_html =~ ~s(id="oauth-relink-upstream-account-#{no_assignment_id}")
    assert no_assignment_html =~ ~s(id="reinvite-upstream-account-#{no_assignment_id}")

    assert no_assignment_html =~
             ~r/<button[^>]+id="oauth-relink-upstream-account-#{no_assignment_id}"[^>]+ disabled(?:[\s=>])/

    assert no_assignment_html =~
             ~r/<button[^>]+id="reinvite-upstream-account-#{no_assignment_id}"[^>]+disabled/

    refute no_assignment_html =~ ~r/<a[^>]+id="reinvite-upstream-account-#{no_assignment_id}"/

    deleted_id = Ecto.UUID.generate()

    deleted_html =
      render_component(&AccountCard.account_card/1,
        account: recovery_component_account(deleted_id, "deleted", []),
        account_index: 0
      )

    refute deleted_html =~ "replace-auth-json-upstream-account-#{deleted_id}"
    refute deleted_html =~ "oauth-relink-upstream-account-#{deleted_id}"
    refute deleted_html =~ "reinvite-upstream-account-#{deleted_id}"

    usable_id = Ecto.UUID.generate()

    usable_html =
      render_component(&AccountCard.account_card/1,
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
    refute usable_html =~ "oauth-relink-upstream-account-#{usable_id}"
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

    reconciliation_selector = "#upstream-account-#{reauth.id}-reconciliation-status"
    assert has_element?(view, reconciliation_selector, "Reauthentication required")
    assert has_element?(view, reconciliation_selector, "excluded from routing")
    assert has_element?(view, reconciliation_selector, "Refresh token was revoked or expired")
    assert has_element?(view, reconciliation_selector, "refresh_token_revoked")
    refute has_element?(view, "#upstream-account-#{reauth.id}-reconciliation-recovery")
    refute has_element?(view, "#upstream-account-#{reauth.id}-reauth-warning")
  end

  test "active accounts ignore stale reauthentication token refresh metadata", %{scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "stale-token-refresh", name: "Stale Token Refresh"})

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Recovered Account",
        identity_status: "active",
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

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])

    assert account.identity.id == identity.id
    assert account.reauth_required? == false
    assert account.refresh_status == "not run"
    assert account.token_refresh_label == "token refresh not run"
    assert account.reauth_reason_code == nil
    assert account.reauth_reason_message == nil
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
      identity_observability: %{
        reconciliation: %{
          status: nil,
          code: nil,
          message: nil,
          finished_at: nil,
          attempt_age: nil
        },
        last_successful_quota_refresh_at: nil,
        last_successful_quota_refresh_age: nil,
        quota_evidence_at: nil,
        quota_evidence_age: nil,
        credential_expiry: %{state: "unavailable", expires_at: nil, age: nil}
      },
      access_token_label:
        Keyword.get(opts, :access_token_label, "access token expired 2026-05-04 12:00 UTC"),
      reauth_required?: status == "reauth_required",
      reauth_reason_code: nil,
      reauth_reason_message: nil,
      token_burn: %{
        level: 0,
        label: "x0",
        title: "last 5m: 0 tokens; previous 1h: 0 tokens",
        recent_tokens: 0,
        baseline_tokens: 0
      },
      assignments: assignments,
      quota_readiness: %{
        state: "missing_evidence",
        label: "Quota missing",
        tone: :warning,
        routing_ready_now?: false,
        reason_codes: [],
        primary_window: nil,
        primary_30d_window: nil,
        weekly_window: nil
      },
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

  defp insert_routing_quota_windows(identity, "ready"),
    do: maybe_insert_quota_window(identity, "known")

  defp insert_routing_quota_windows(identity, "weekly_only_probe"),
    do: maybe_insert_quota_window(identity, "weekly_only_probe")

  defp insert_routing_quota_windows(_identity, "missing"), do: {:ok, []}

  defp insert_routing_quota_windows(identity, "stale") do
    now = DateTime.utc_now()

    QuotaWindows.upsert_quota_windows(identity, [
      %{
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("10"),
        reset_at: DateTime.add(now, 900, :second),
        source: "codex_usage",
        freshness_state: "stale",
        observed_at: now
      }
    ])
  end

  defp insert_routing_quota_windows(identity, "exhausted") do
    now = DateTime.utc_now()

    QuotaWindows.upsert_quota_windows(identity, [
      %{
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("10"),
        reset_at: DateTime.add(now, 900, :second),
        source: "codex_usage",
        freshness_state: "fresh",
        observed_at: now
      },
      %{
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(now, 900, :second),
        source: "codex_usage",
        freshness_state: "fresh",
        observed_at: now
      }
    ])
  end

  defp insert_routing_quota_windows(identity, status),
    do: maybe_insert_quota_window(identity, status)

  defp quota_limit!(account, key) do
    Enum.find(account.quota_limits, &(&1.key == key)) ||
      flunk("expected quota limit #{inspect(key)} for upstream account #{account.identity.id}")
  end

  defp assert_quota_readiness_snapshot(account, opts) do
    assert account.identity.status == "active"
    assert account.quota_readiness.state == Keyword.fetch!(opts, :state)
    assert account.quota_readiness.label == Keyword.fetch!(opts, :label)
    assert account.quota_readiness.tone == Keyword.fetch!(opts, :tone)
    assert account.quota_readiness.routing_ready_now? == Keyword.fetch!(opts, :routing_ready_now?)

    case Keyword.fetch!(opts, :primary_window?) do
      true -> assert match?(%AccountQuotaWindow{}, account.quota_readiness.primary_window)
      false -> assert is_nil(account.quota_readiness.primary_window)
    end

    assert is_nil(account.quota_readiness.primary_30d_window)

    case Keyword.fetch!(opts, :weekly_window?) do
      true -> assert match?(%AccountQuotaWindow{}, account.quota_readiness.weekly_window)
      false -> assert is_nil(account.quota_readiness.weekly_window)
    end

    [assignment] = account.assignments
    assert assignment.quota_priming_status == Keyword.fetch!(opts, :priming_status)
    assert assignment.quota_priming_label == Keyword.fetch!(opts, :priming_label)
    assert Enum.map(account.quota_limits, & &1.label) == ["5h", "30d", "Weekly"]
  end

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

  defp open_oauth_link_dialog(view) do
    view
    |> element("#upstream-page-oauth-link-action")
    |> render_click()
  end

  defp select_oauth_link_pool(view, pool_id) do
    view
    |> element("#oauth-link-start-form")
    |> render_change(%{"oauth_link" => %{"pool_id" => pool_id}})
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
             device_auth_id: "device-auth-ui",
             user_code: "CODE-UI",
             interval: 5,
             expires_at: DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.to_iso8601()
           )}
      },
      extra_routes
    )
  end

  defp oauth_id_token(account_id) do
    FakeOpenAIAuthProvider.id_token(%{
      "email" => "#{account_id}@example.com",
      "https://api.openai.com/auth" => %{
        "chatgpt_account_id" => account_id,
        "chatgpt_user_id" => "user_#{account_id}",
        "chatgpt_plan_type" => "team",
        "workspace_id" => "workspace-admin-ui",
        "workspace_label" => "Admin UI Workspace",
        "seat_type" => "team-seat"
      }
    })
  end

  defp authorization_url_from_view(view) do
    case Regex.run(~r/id="oauth-link-authorization-url"[^>]*href="([^"]+)"/, render(view)) do
      [_match, authorization_url] -> String.replace(authorization_url, "&amp;", "&")
      _missing -> flunk("missing OAuth authorization URL")
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

  defp provider_callback_url(state, code) do
    "http://localhost:1455/auth/callback?" <>
      URI.encode_query([
        {"code", code},
        {"scope",
         "openid profile email offline_access api.connectors.read api.connectors.invoke"},
        {"provider_extra", "ignored"},
        {"state", state}
      ])
  end

  defp execute_scheduled_upstreams_reload(view) do
    state = :sys.get_state(view.pid)
    timer = state.socket.assigns[:upstreams_reload_timer]

    assert is_reference(timer)
    Process.cancel_timer(timer, async: false, info: false)
    send(view.pid, :reload_upstreams_from_events)
    _ = :sys.get_state(view.pid)
  end

  defp flow_summary(oauth_flows, flow_id) do
    Enum.find(oauth_flows.items, &(&1.id == flow_id)) || flunk("missing OAuth flow summary")
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

  defp upstream_page_action_order(html) do
    ~r/id="(upstream-page-(?:create-invite|import-auth-json|oauth-link)-action)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp upstream_header_badge_order(html) do
    ~r/id="(upstream-account-[^"]+-(?:saved-reset-count|plan-label))"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp html_element_class(html, id) do
    assert [_match, class] = Regex.run(~r/id="#{Regex.escape(id)}"[^>]*class="([^"]+)"/, html)
    class
  end

  defp assert_admin_dialog_docs_link(view, footer_id) do
    docs_url =
      case footer_id do
        "auth-json-import-dialog-footer" ->
          "https://docs.codex-pooler.com/operators/upstreams/#import-authjson"

        "rename-upstream-account-dialog-footer" ->
          "https://docs.codex-pooler.com/operators/upstreams/#card-action-menu"

        "delete-upstream-account-dialog-footer" ->
          "https://docs.codex-pooler.com/operators/upstreams/#card-action-menu"
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

  def handle_repo_query_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    if metadata[:repo] == Repo do
      send(test_pid, {handler_id, %{source: normalize_repo_query_value(metadata[:source])}})
    end
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_repo_query_event/4,
        {handler_id, test_pid}
      )

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, event} ->
        drain_repo_query_events(handler_id, [event | events])
    after
      10 -> Enum.reverse(events)
    end
  end

  defp normalize_repo_query_value(value) when is_binary(value), do: value
  defp normalize_repo_query_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_repo_query_value(value), do: to_string(value)

  defp update_identity_subject_slot!(identity, account_id, workspace_id, raw_subject) do
    identity
    |> UpstreamIdentity.changeset(%{
      chatgpt_account_id: account_id,
      workspace_id: workspace_id,
      workspace_label: "Shared workspace",
      chatgpt_user_id: raw_subject
    })
    |> Repo.update!()
  end

  defp update_identity_metadata!(identity, fun) when is_function(fun, 1) do
    identity = Repo.get!(UpstreamIdentity, identity.id)

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: fun.(identity.metadata || %{}),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp audit_events(action, target_id) do
    Repo.all(
      from(event in AuditEvent,
        where: event.action == ^action and event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
      )
    )
  end

  defp spark_weekly_quota_window(observed_at, metadata) do
    %{
      quota_key: "gpt_5_3_codex_spark",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      display_label: "GPT-5.3-Codex-Spark",
      limit_name: "GPT-5.3-Codex-Spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("0"),
      reset_at: DateTime.add(observed_at, 7, :day),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: observed_at,
      metadata: metadata
    }
  end

  defp insert_account_quota_window!(
         identity,
         window_kind,
         source,
         observed_at,
         reset_at,
         used_percent
       ) do
    {:ok, window} =
      EvidenceStore.record_evidence(
        identity,
        %{
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: window_kind,
          window_minutes: if(window_kind == "primary", do: 300, else: 10_080),
          used_percent: Decimal.new(used_percent),
          reset_at: reset_at,
          source: source,
          source_precision: "observed",
          freshness_state: "fresh",
          observed_at: observed_at,
          last_sync_at: observed_at,
          metadata: %{}
        },
        observed_at,
        observed_at
      )

    window
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp assert_single_element(view, selector, text) do
    rendered = view |> element(selector, text) |> render()
    assert rendered != ""
  end
end
