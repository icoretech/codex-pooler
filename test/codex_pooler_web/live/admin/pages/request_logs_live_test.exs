defmodule CodexPoolerWeb.Admin.RequestLogsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Accounts
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.RequestLogsPresentation

  @request_logs_reload_event [:codex_pooler, :admin, :request_logs, :reload]

  setup :register_and_log_in_user

  test "renders required selectors and sanitized request log rows with priced cost $0.123456 and unpriced_missing_model status",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "admin-logs", name: "Admin Logs"})
    sensitive_marker = "request-log-secret-do-not-render"

    %{request: request} =
      request_log_fixture(pool, %{
        api_key_display_name: "Admin key",
        correlation_id: "req-live-1",
        requested_model: "gpt-live-mini",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "succeeded",
        latency_ms: 87,
        request_metadata: %{
          "body" => %{"input" => "body #{sensitive_marker}"},
          (["access", "_", "token"] |> Enum.join()) => sensitive_marker,
          "quota_decision" => %{"summary" => "allowed by fresh quota"},
          "routing" => %{"strategy" => "bridge_ring", "selected_bridge_candidate_rank" => 1},
          "file" => %{
            "id" => "file-12345678-1234-1234-1234-123456789abc",
            "status" => "uploaded"
          },
          "operation" => "uploaded",
          "candidate_exclusions" => [
            %{
              "reasons" => [
                %{"code" => "routing_circuit_open", "route_class" => "proxy_http"}
              ]
            }
          ]
        },
        input_tokens: 1113,
        cached_input_tokens: 2000,
        output_tokens: 4000,
        total_tokens: 7113,
        settled_cost_micros: 123_456,
        settlement_details: %{
          "pricing_status" => "priced",
          "settled_cost_micros" => "123456",
          "cached_input_cost_micros" => "12"
        }
      })

    %{request: unpriced_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-live-unpriced",
        requested_model: "gpt-live-unpriced",
        status: "succeeded",
        input_tokens: 1,
        output_tokens: 1,
        total_tokens: 2,
        settled_cost_micros: 0,
        settlement_details: %{
          "pricing_status" => "unpriced_missing_model",
          "settled_cost_micros" => nil
        }
      })

    %{request: fast_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-live-fast",
        requested_model: "gpt-5.3-codex-spark",
        requested_service_tier: "priority",
        actual_service_tier: "auto",
        status: "succeeded"
      })

    %{request: model_fast_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-live-model-fast",
        requested_model: "gpt-5.4",
        requested_service_tier: "default",
        actual_service_tier: "default",
        status: "succeeded"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(view, "#admin-request-logs-live")
    assert has_element?(view, "#request-log-filter-form[phx-change='filter']")
    assert has_element?(view, "#request-log-filter-form[phx-submit='filter']")
    assert has_element?(view, "#filters_pool_id")
    assert has_element?(view, "#filters_status")
    assert has_element?(view, "#filters_status")
    assert has_element?(view, "#filters_upstream_identity_id")
    assert has_element?(view, "#filters_model")
    assert has_element?(view, "#filters_date_from")
    assert has_element?(view, "#filters_date_to")
    assert has_element?(view, "#filters_request_id")
    assert has_element?(view, "#request-log-pool-filter [aria-label='Pool']")
    assert has_element?(view, "#request-log-status-filter [aria-label='Status']")

    assert has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-trigger']",
             "Bridge ring"
           )

    assert has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-trigger'] [data-role='pool-filter-icon'].text-success"
           )

    assert has_element?(view, "#request-log-upstream-filter [aria-label='Upstream account']")
    assert has_element?(view, "#request-log-model-filter [aria-label='Model']")
    refute has_element?(view, "#request-log-filter-form-advanced #request-log-upstream-filter")
    refute has_element?(view, "#request-log-filter-form-advanced #request-log-model-filter")

    assert has_element?(view, "#filters_date_from[type='hidden'][name='filters[date_from]']")
    assert has_element?(view, "#filters_date_to[type='hidden'][name='filters[date_to]']")
    refute has_element?(view, "input#filters_date_from[type='date']")
    refute has_element?(view, "input#filters_date_to[type='date']")
    assert has_element?(view, "#filters_date_from-picker[phx-hook='CallyDatePicker']")
    assert has_element?(view, "#filters_date_to-picker[phx-hook='CallyDatePicker']")
    refute has_element?(view, "#filters_date_from-picker > label[for='filters_date_from-button']")
    refute has_element?(view, "#filters_date_to-picker > label[for='filters_date_to-button']")

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #filters_date_from-picker button[popovertarget='filters_date_from-popover'][aria-label='Date from']",
             "dd/mm/yyyy"
           )

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #filters_date_from-picker button .label",
             "Date from"
           )

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #filters_date_to-picker button[popovertarget='filters_date_to-popover'][aria-label='Date to']",
             "dd/mm/yyyy"
           )

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #filters_date_to-picker button .label",
             "Date to"
           )

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #filters_date_from-popover calendar-date.cally[data-role='cally-calendar'] calendar-month"
           )

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #filters_date_from-popover [data-role='cally-cancel']",
             "Cancel"
           )

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #request-log-request-id-filter #filters_request_id"
           )

    refute has_element?(
             view,
             "#request-log-filter-form-advanced #request-log-request-id-filter label[for='filters_request_id']"
           )

    assert has_element?(view, "#filters_request_id[placeholder='Correlation or row id']")

    assert has_element?(
             view,
             "#request-log-filter-form-advanced #request-log-request-id-clear[aria-label='Clear request id filter']"
           )

    assert has_element?(view, "#request-log-request-id-clear.hidden")

    {:ok, filtered_view, _html} = live(conn, ~p"/admin/request-logs?request_id=req-live-1")

    assert has_element?(filtered_view, "#request-log-filter-form-advanced[open]")
    assert has_element?(filtered_view, "#filters_request_id[value='req-live-1']")
    refute has_element?(filtered_view, "#request-log-request-id-clear.hidden")

    refute has_element?(view, "#request-log-filter-submit")
    refute has_element?(view, "#request-log-filter-reset")

    assert has_element?(
             view,
             ~s(#request-log-filter-form > div > div[class*="grid-cols-1"][class*="sm:grid-cols-2"][class*="lg:grid-cols-4"])
           )

    assert has_element?(
             view,
             ~s|#request-log-filter-form-advanced > div[class*="auto-fit"][class*="minmax(10rem,1fr)"]|
           )

    refute has_element?(view, "#request-log-summary")
    refute has_element?(view, "#request-log-page-size")

    assert has_element?(
             view,
             "#request-log-page-header",
             "Audit recent gateway traffic, routing decisions, upstream outcomes, quota evidence, token usage, and cost settlement."
           )

    refute has_element?(view, "#request-log-page-header", "Review recent requests")
    assert has_element?(view, "#admin-request-logs")
    assert has_element?(view, "#request-logs-table")
    assert has_element?(view, "#mobile-request-logs-table")
    assert has_element?(view, "#mobile-request-logs-table-body")
    assert has_element?(view, "#admin-request-logs", "Usage")
    assert has_element?(view, "#admin-request-logs", "$0.12")
    assert has_element?(view, "#request-log-row-#{request.id}", "Admin key")
    assert has_element?(view, "#mobile-request-log-row-#{request.id}", "Admin key")
    assert has_element?(view, "#mobile-request-log-row-#{request.id}", "gpt-live-mini")
    assert has_element?(view, "#request-log-row-#{request.id} [data-role='pool-name']", pool.name)
    assert has_element?(view, "#request-log-row-#{request.id} [data-role='pool-icon']")
    assert has_element?(view, "#request-log-row-#{request.id} [data-role='api-key-icon']")

    assert has_element?(
             view,
             "#mobile-request-log-row-#{request.id} [data-role='pool-name']",
             pool.name
           )

    assert has_element?(view, "#mobile-request-log-row-#{request.id} [data-role='pool-icon']")
    assert has_element?(view, "#mobile-request-log-row-#{request.id} [data-role='api-key-icon']")

    assert has_element?(
             view,
             "#mobile-request-log-row-#{request.id}",
             "/backend-api/codex/responses"
           )

    assert has_element?(view, "#mobile-request-log-#{request.id}-protocol", "WebSocket")
    assert has_element?(view, "#request-log-row-#{request.id}", "gpt-live-mini")
    assert has_element?(view, "#request-log-row-#{request.id}", "/backend-api/codex/responses")
    assert has_element?(view, "#request-log-#{request.id}-protocol", "WebSocket")

    assert has_element?(
             view,
             "#request-log-row-#{request.id} [data-role='token-totals']",
             "7.1k tokens"
           )

    assert has_element?(
             view,
             "#request-log-row-#{request.id} [data-role='route'] + [data-role='latency']",
             "87ms"
           )

    assert has_element?(
             view,
             "#mobile-request-log-row-#{request.id} [data-role='route'] + [data-role='latency']",
             "87ms"
           )

    assert has_element?(view, "#request-log-row-#{request.id}", "(2k cached)")

    assert has_element?(
             view,
             "#request-log-row-#{request.id} [data-role='cached-cost']",
             "($0.00 cached)"
           )

    assert has_element?(view, "#request-log-row-#{request.id}", "$0.12")
    refute has_element?(view, "#request-log-row-#{request.id}", "$0.123456")

    assert has_element?(
             view,
             "#request-log-row-#{unpriced_request.id} [data-role='token-totals']",
             "2 tokens"
           )

    assert has_element?(
             view,
             "#request-log-row-#{unpriced_request.id} [data-role='cost']",
             "cost n/a"
           )

    refute has_element?(
             view,
             "#request-log-row-#{unpriced_request.id} [data-role='usage-placeholder']"
           )

    refute has_element?(view, "#request-log-row-#{unpriced_request.id}", "unpriced_missing_model")

    assert has_element?(view, "#request-log-#{unpriced_request.id}-protocol", "HTTP JSON")

    assert has_element?(view, "#request-log-row-#{fast_request.id}", "gpt-5.3-codex-spark")
    refute has_element?(view, "#request-log-#{fast_request.id}-fast-mode")
    refute has_element?(view, "#request-log-#{fast_request.id}-requested-tier")

    assert has_element?(view, "#request-log-row-#{model_fast_request.id}", "gpt-5.4")
    assert has_element?(view, "#request-log-row-#{model_fast_request.id}", "default")

    assert has_element?(
             view,
             "#request-log-#{fast_request.id}-protocol [data-role='fast-mode-indicator']"
           )

    assert has_element?(
             view,
             "#request-log-#{model_fast_request.id}-protocol [data-role='fast-mode-indicator'][data-speed-tier='fast']"
           )

    refute has_element?(view, "#request-log-#{request.id}-fast-mode")

    html = render(view)
    refute html =~ sensitive_marker
    refute html =~ Enum.join(["Authorization", ": ", "Bearer"])
    refute html =~ "body #{sensitive_marker}"
  end

  test "renders priced success and no-usage upstream 400 cost policy states", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "admin-log-cost-policy", name: "Cost Policy Logs"})

    %{request: priced_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-priced-success",
        requested_model: "gpt-priced-success",
        status: "succeeded",
        usage_status: "usage_known",
        input_tokens: 3,
        cached_input_tokens: 1,
        output_tokens: 2,
        total_tokens: 5,
        settled_cost_micros: 61,
        settlement_usage_status: "usage_known",
        settlement_details: %{"pricing_status" => "priced", "settled_cost_micros" => "61"}
      })

    %{request: failed_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-upstream-400-no-usage",
        requested_model: "gpt-upstream-400",
        status: "failed",
        usage_status: "usage_unknown",
        response_status_code: 400,
        last_error_code: "upstream_status",
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        settled_cost_micros: 0,
        settlement_usage_status: "usage_unknown",
        settlement_details: %{
          "pricing_status" => "priced",
          "settled_cost_micros" => nil,
          "usage_source" => "upstream_status"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(view, "#request-log-row-#{priced_request.id}", "$0.00")
    refute has_element?(view, "#request-log-row-#{priced_request.id}", "$0.000061")
    refute has_element?(view, "#request-log-row-#{priced_request.id}", "unpriced")

    assert has_element?(
             view,
             "#request-log-row-#{failed_request.id}",
             "gpt-upstream-400"
           )

    assert has_element?(
             view,
             "#request-log-row-#{failed_request.id} [data-role='status-icon'][aria-label='Status: Failed']"
           )

    refute has_element?(view, "#request-log-row-#{failed_request.id}", "deny:")

    assert has_element?(
             view,
             "#request-log-row-#{failed_request.id} [data-role='usage-placeholder']",
             "—"
           )

    refute has_element?(view, "#request-log-row-#{failed_request.id} [data-role='cost']")
    refute has_element?(view, "#request-log-row-#{failed_request.id}", "cost n/a")

    refute has_element?(
             view,
             "#request-log-row-#{failed_request.id} [data-role='usage-placeholder']",
             "unpriced"
           )
  end

  test "filters by Pool and status without mixing Pool rows", %{conn: conn, scope: scope} do
    {:ok, first_pool} = Pools.create_pool(scope, %{slug: "logs-first", name: "Logs First"})
    {:ok, second_pool} = Pools.create_pool(scope, %{slug: "logs-second", name: "Logs Second"})
    hidden_pool = pool_fixture(%{slug: "logs-hidden", name: "Logs Hidden"})

    %{request: first_request} =
      request_log_fixture(first_pool, %{
        correlation_id: "req-first",
        status: "succeeded",
        requested_model: "gpt-first-pool"
      })

    %{request: second_request} =
      request_log_fixture(second_pool, %{
        correlation_id: "req-second",
        status: "failed",
        requested_model: "gpt-second-pool"
      })

    %{request: hidden_request} =
      request_log_fixture(hidden_pool, %{
        correlation_id: "req-hidden",
        status: "failed",
        requested_model: "gpt-hidden-pool"
      })

    assert {:ok, _hidden_pool} = Pools.change_pool_status(scope, hidden_pool, "disabled")

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs")
    assert has_element?(view, "#filters_pool_id[type='hidden'][value='']")

    assert has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-trigger']",
             "All Pools"
           )

    assert has_element?(view, "#request-log-row-#{first_request.id}", "gpt-first-pool")
    assert has_element?(view, "#request-log-row-#{second_request.id}", "gpt-second-pool")
    assert has_element?(view, "#request-log-row-#{hidden_request.id}", "gpt-hidden-pool")

    assert has_element?(
             view,
             "#request-log-pool-filter button[data-pool-id='#{hidden_pool.id}']",
             "Logs Hidden"
           )

    assert has_element?(
             view,
             "#request-log-pool-filter button[data-pool-id='#{hidden_pool.id}'] [data-role='pool-filter-icon'].text-warning"
           )

    view
    |> element("#request-log-filter-form")
    |> render_submit(%{"filters" => %{"pool_id" => second_pool.id, "status" => "failed"}})

    assert has_element?(view, "#request-log-row-#{second_request.id}", "gpt-second-pool")
    refute has_element?(view, "#request-log-row-#{first_request.id}")

    view
    |> element("#request-log-pool-filter button[data-pool-id='#{hidden_pool.id}']")
    |> render_click()

    assert_patch(view, ~p"/admin/request-logs?pool_id=#{hidden_pool.id}&status=failed")
    assert has_element?(view, "#filters_pool_id[type='hidden'][value='#{hidden_pool.id}']")
    assert has_element?(view, "#request-log-row-#{hidden_request.id}", "gpt-hidden-pool")
    refute has_element?(view, "#request-log-row-#{first_request.id}")
  end

  test "upstream account filter uses all registered accounts from a custom selector", %{
    conn: conn,
    scope: scope
  } do
    {:ok, first_pool} =
      Pools.create_pool(scope, %{slug: "logs-upstream-first", name: "Logs Upstream First"})

    {:ok, second_pool} =
      Pools.create_pool(scope, %{slug: "logs-upstream-second", name: "Logs Upstream Second"})

    hidden_pool = pool_fixture(%{slug: "logs-upstream-hidden", status: "disabled"})

    %{request: first_request, identity: first_identity} =
      request_log_fixture(first_pool, %{
        account_label: "first-upstream@example.com",
        assignment_label: "First upstream assignment",
        correlation_id: "req-upstream-first",
        requested_model: "gpt-upstream-first"
      })

    %{request: second_request, identity: second_identity} =
      request_log_fixture(second_pool, %{
        account_label: "second-upstream@example.com",
        assignment_label: "Second upstream assignment",
        correlation_id: "req-upstream-second",
        requested_model: "gpt-upstream-second"
      })

    %{identity: hidden_identity} =
      upstream_assignment_fixture(hidden_pool, %{
        account_label: "hidden-upstream@example.com",
        assignment_label: "Hidden upstream assignment"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs")

    assert has_element?(view, "#filters_upstream_identity_id[type='hidden'][value='']")

    assert has_element?(
             view,
             "#request-log-upstream-filter [data-role='upstream-filter-trigger']",
             "Any account"
           )

    refute has_element?(view, "select#filters_upstream_identity_id")

    assert has_element?(
             view,
             "#request-log-upstream-filter [data-role='upstream-filter-option'][data-upstream-id='#{first_identity.id}']",
             "first-upstream@example.com"
           )

    assert has_element?(
             view,
             "#request-log-upstream-filter [data-role='upstream-filter-option'][data-upstream-id='#{second_identity.id}']",
             "second-upstream@example.com"
           )

    refute has_element?(
             view,
             "#request-log-upstream-filter [data-role='upstream-filter-option'][data-upstream-id='#{hidden_identity.id}']",
             "hidden-upstream@example.com"
           )

    {:ok, invalid_filter_view, _html} =
      live(conn, ~p"/admin/request-logs?upstream_identity_id=#{hidden_identity.id}")

    assert has_element?(
             invalid_filter_view,
             "#request-log-filter-errors",
             "Upstream account filter did not match a visible upstream account"
           )

    view
    |> element(
      "#request-log-upstream-filter [data-role='upstream-filter-option'][data-upstream-id='#{second_identity.id}']"
    )
    |> render_click()

    assert has_element?(
             view,
             "#filters_upstream_identity_id[type='hidden'][value='#{second_identity.id}']"
           )

    assert has_element?(view, "#request-log-row-#{second_request.id}", "gpt-upstream-second")
    refute has_element?(view, "#request-log-row-#{first_request.id}")
  end

  test "filter controls use custom selectors with status icons and table-derived models", %{
    conn: conn,
    scope: scope
  } do
    {:ok, first_pool} =
      Pools.create_pool(scope, %{slug: "custom-filter-first", name: "Custom Filter First"})

    {:ok, second_pool} =
      Pools.create_pool(scope, %{slug: "custom-filter-second", name: "Custom Filter Second"})

    %{request: succeeded_request} =
      request_log_fixture(first_pool, %{
        correlation_id: "req-custom-filter-success",
        requested_model: "gpt-custom-success",
        status: "succeeded"
      })

    %{request: failed_request} =
      request_log_fixture(first_pool, %{
        correlation_id: "req-custom-filter-failed",
        requested_model: "gpt-custom-failed",
        status: "failed"
      })

    %{request: second_pool_request} =
      request_log_fixture(second_pool, %{
        correlation_id: "req-custom-filter-second",
        requested_model: "gpt-custom-second",
        status: "cancelled"
      })

    %{request: older_request} =
      request_log_fixture(first_pool, %{
        correlation_id: "req-custom-filter-older",
        requested_model: "gpt-custom-older-off-page",
        status: "succeeded"
      })

    %{request: metadata_request} =
      request_log_fixture(first_pool, %{
        correlation_id: "req-custom-filter-metadata",
        account_label: "models-upstream@example.com",
        assignment_label: "Models upstream",
        requested_model: "/backend-api/codex/models",
        endpoint: "/backend-api/codex/models",
        status: "succeeded"
      })

    older_admitted_at = DateTime.add(DateTime.utc_now(), -1, :hour)

    older_request
    |> Ecto.Changeset.change(%{
      admitted_at: older_admitted_at,
      completed_at: older_admitted_at
    })
    |> Repo.update!()

    for index <- 1..50 do
      request_log_fixture(first_pool, %{
        correlation_id: "req-custom-filter-page-#{index}",
        requested_model: "gpt-custom-page-#{index}",
        status: "succeeded"
      })
    end

    visible_admitted_at = DateTime.add(DateTime.utc_now(), 1, :second)

    for request <- [succeeded_request, failed_request, second_pool_request, metadata_request] do
      request
      |> Ecto.Changeset.change(%{
        admitted_at: visible_admitted_at,
        completed_at: visible_admitted_at
      })
      |> Repo.update!()
    end

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs")

    assert has_element?(view, "#filters_pool_id[type='hidden'][value='']")

    assert has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-trigger']",
             "All Pools"
           )

    assert has_element?(view, "#request-log-pool-filter [data-role='pool-filter-trigger']")
    refute has_element?(view, "select#filters_pool_id")
    assert has_element?(view, "#request-log-row-#{second_pool_request.id}", "gpt-custom-second")

    assert has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-menu']",
             first_pool.name
           )

    assert has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-menu']",
             second_pool.name
           )

    refute has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-trigger']",
             first_pool.slug
           )

    refute has_element?(
             view,
             "#request-log-pool-filter [data-role='pool-filter-menu']",
             first_pool.slug
           )

    view
    |> element(
      "#request-log-pool-filter [data-role='pool-filter-option'][data-pool-id='#{second_pool.id}']"
    )
    |> render_click()

    assert has_element?(view, "#filters_pool_id[type='hidden'][value='#{second_pool.id}']")
    assert has_element?(view, "#request-log-row-#{second_pool_request.id}", "gpt-custom-second")
    refute has_element?(view, "#request-log-row-#{failed_request.id}")

    view
    |> element(
      "#request-log-pool-filter [data-role='pool-filter-option'][data-pool-id='#{first_pool.id}']"
    )
    |> render_click()

    assert has_element?(view, "#request-log-row-#{succeeded_request.id}", "gpt-custom-success")

    assert has_element?(
             view,
             "#request-log-row-#{metadata_request.id} [data-role='model-name']",
             "—"
           )

    assert has_element?(
             view,
             "#request-log-row-#{metadata_request.id} [data-role='upstream-account']",
             "Models upstream"
           )

    refute has_element?(view, "#request-log-row-#{second_pool_request.id}")

    assert has_element?(view, "#filters_status[type='hidden']")
    assert has_element?(view, "#request-log-status-filter [data-role='status-filter-trigger']")
    refute has_element?(view, "select#filters_status")

    for status <- ~w(in_progress succeeded failed rejected cancelled) do
      assert has_element?(
               view,
               "#request-log-status-filter [data-role='status-filter-option'][data-status='#{status}'] [data-role='status-filter-icon']"
             )
    end

    assert has_element?(view, "#filters_model[type='hidden']")
    assert has_element?(view, "#request-log-model-filter [data-role='model-filter-trigger']")
    refute has_element?(view, "input#filters_model[type='text']")
    refute has_element?(view, "select#filters_model")

    assert has_element?(
             view,
             "#request-log-model-filter [data-role='model-filter-menu']",
             "gpt-custom-success"
           )

    assert has_element?(
             view,
             "#request-log-model-filter [data-role='model-filter-menu']",
             "gpt-custom-failed"
           )

    assert has_element?(
             view,
             "#request-log-model-filter [data-role='model-filter-menu']",
             "gpt-custom-older-off-page"
           )

    refute has_element?(view, "#request-log-row-#{older_request.id}")

    refute has_element?(
             view,
             "#request-log-model-filter [data-role='model-filter-menu']",
             "gpt-custom-second"
           )

    refute has_element?(
             view,
             "#request-log-model-filter [data-role='model-filter-menu']",
             "/backend-api/codex/models"
           )

    view
    |> element(
      "#request-log-model-filter [data-role='model-filter-option'][data-model='gpt-custom-failed']"
    )
    |> render_click()

    assert has_element?(view, "#filters_model[type='hidden'][value='gpt-custom-failed']")
    assert has_element?(view, "#request-log-row-#{failed_request.id}", "gpt-custom-failed")
    refute has_element?(view, "#request-log-row-#{succeeded_request.id}")
    refute has_element?(view, "#request-log-row-#{second_pool_request.id}")

    view
    |> element(
      "#request-log-status-filter [data-role='status-filter-option'][data-status='failed']"
    )
    |> render_click()

    assert has_element?(view, "#filters_status[type='hidden'][value='failed']")
    assert has_element?(view, "#request-log-row-#{failed_request.id}", "gpt-custom-failed")
    refute has_element?(view, "#request-log-row-#{succeeded_request.id}")
  end

  test "shows empty state when filters match no metadata rows", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "empty-logs", name: "Empty Logs"})

    request_log_fixture(pool, %{status: "succeeded"})

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}&status=failed")

    assert has_element?(view, "#admin-request-logs")
    assert has_element?(view, "#request-log-empty-state")
    assert has_element?(view, "#request-log-empty-state.border-dashed")

    assert has_element?(
             view,
             "#request-log-empty-state",
             "Send a request through a Pool or adjust the filters to find existing log rows."
           )
  end

  test "refreshes selected pool rows when request log events arrive", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "realtime-logs", name: "Realtime Logs"})
    reload_ref = attach_request_log_reload_telemetry()

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")
    assert_request_log_reload(reload_ref, :initial_load, :selected_pool)
    assert has_element?(view, "#request-log-empty-state")
    _ = :sys.get_state(view.pid)

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-realtime",
        status: "succeeded",
        requested_model: "gpt-realtime-model"
      })

    assert {:ok, _event} =
             Events.broadcast_request_logs(pool.id, "request_log_created", %{
               request_id: request.id,
               status: request.status
             })

    assert_request_log_reload(reload_ref, :event_refresh, :selected_pool)

    assert has_element?(view, "#request-log-row-#{request.id}", "gpt-realtime-model")
  end

  test "refreshes all-pool rows through active filters when request log events arrive", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "all-realtime-logs", name: "All Realtime Logs"})

    reload_ref = attach_request_log_reload_telemetry()

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?status=failed")
    assert_request_log_reload(reload_ref, :initial_load, :all_pools)
    assert has_element?(view, "#request-log-empty-state")
    _ = :sys.get_state(view.pid)

    %{request: succeeded_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-all-realtime-succeeded",
        status: "succeeded",
        requested_model: "gpt-all-realtime-hidden"
      })

    assert {:ok, _event} =
             Events.broadcast_request_logs(pool.id, "request_log_created", %{
               request_id: succeeded_request.id,
               status: succeeded_request.status
             })

    assert_request_log_reload(reload_ref, :event_refresh, :all_pools)
    refute has_element?(view, "#request-log-row-#{succeeded_request.id}")
    assert has_element?(view, "#request-log-empty-state")

    %{request: failed_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-all-realtime-failed",
        status: "failed",
        requested_model: "gpt-all-realtime-visible"
      })

    assert {:ok, _event} =
             Events.broadcast_request_logs(pool.id, "request_log_created", %{
               request_id: failed_request.id,
               status: failed_request.status
             })

    assert_request_log_reload(reload_ref, :event_refresh, :all_pools)

    assert has_element?(view, "#request-log-row-#{failed_request.id}", "gpt-all-realtime-visible")
    refute has_element?(view, "#request-log-row-#{succeeded_request.id}")
  end

  test "coalesces request log event bursts into one light refresh", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "coalesced-realtime-logs", name: "Coalesced Logs"})

    reload_ref = attach_request_log_reload_telemetry()

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")
    assert_request_log_reload(reload_ref, :initial_load, :selected_pool)
    refute_request_log_reload(reload_ref, :initial_load)
    assert has_element?(view, "#request-log-empty-state")

    requests =
      for index <- 1..5 do
        request_log_fixture(pool, %{
          correlation_id: "req-coalesced-#{index}",
          status: "succeeded",
          requested_model: "gpt-coalesced-#{index}"
        }).request
      end

    {_result, query_events} =
      capture_repo_queries(fn ->
        for request <- requests do
          assert {:ok, _event} =
                   Events.broadcast_request_logs(pool.id, "request_log_created", %{
                     request_id: request.id,
                     status: request.status
                   })
        end

        assert_request_log_reload(reload_ref, :event_refresh, :selected_pool)
        refute_request_log_reload(reload_ref, :event_refresh)
      end)

    assert has_element?(view, "#request-log-row-#{List.last(requests).id}", "gpt-coalesced-5")
    assert source_select_count(query_events, "requests") in 1..3
    assert source_select_count(query_events, "pools") == 0
    assert source_select_count(query_events, "upstream_identities") == 0
    assert source_select_count(query_events, "pool_upstream_assignments") == 0
  end

  test "model details helper renders reasoning and effective tier with requested-vs-effective when different",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "model-details", name: "Model Details"})

    %{request: full_details_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-model-full",
        requested_model: "gpt-5.1",
        reasoning_effort: "high",
        service_tier: "default",
        actual_service_tier: "default",
        status: "succeeded"
      })

    %{request: tier_diff_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-model-tier-diff",
        requested_model: "gpt-5.1",
        reasoning_effort: "low",
        service_tier: "default",
        requested_service_tier: "flex",
        actual_service_tier: "default",
        status: "succeeded"
      })

    %{request: fast_tier_diff_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-model-fast-tier-diff",
        requested_model: "gpt-5.3-codex-spark",
        service_tier: "auto",
        requested_service_tier: "priority",
        actual_service_tier: "auto",
        status: "succeeded"
      })

    %{request: no_suffix_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-model-bare",
        requested_model: "gpt-4o",
        status: "succeeded"
      })

    %{request: in_progress_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-model-in-progress",
        requested_model: "gpt-5.5",
        reasoning_effort: "high",
        status: "in_progress"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(
             view,
             "#request-log-#{full_details_request.id}-model-details",
             "gpt-5.1 high / default"
           )

    assert has_element?(
             view,
             "#request-log-#{full_details_request.id}-model-details [data-role='model-name']",
             "gpt-5.1"
           )

    refute has_element?(view, "#request-log-#{full_details_request.id}-reasoning")
    refute has_element?(view, "#request-log-#{full_details_request.id}-service-tier")

    refute has_element?(view, "#request-log-#{full_details_request.id}-model-details", "(")

    assert has_element?(
             view,
             "#request-log-#{tier_diff_request.id}-model-details",
             "gpt-5.1 low / default"
           )

    assert has_element?(
             view,
             "#request-log-#{tier_diff_request.id}-model-details [data-role='model-name']",
             "gpt-5.1"
           )

    refute has_element?(view, "#request-log-#{tier_diff_request.id}-reasoning")
    refute has_element?(view, "#request-log-#{tier_diff_request.id}-service-tier")

    assert has_element?(
             view,
             "#request-log-#{tier_diff_request.id}-requested-tier",
             "requested: flex"
           )

    refute has_element?(view, "#request-log-#{full_details_request.id}-requested-tier")
    refute has_element?(view, "#request-log-#{fast_tier_diff_request.id}-requested-tier")

    assert has_element?(
             view,
             "#request-log-#{fast_tier_diff_request.id}-protocol [data-role='fast-mode-indicator']"
           )

    assert has_element?(view, "#request-log-#{no_suffix_request.id}-model-details", "gpt-4o")

    assert has_element?(
             view,
             "#request-log-#{in_progress_request.id}-model-details",
             "gpt-5.5 high / default"
           )
  end

  test "plan badge helper uses upstream account plan fields and generated styles",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "plan-badge", name: "Plan Badge"})

    %{request: plan_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-plan",
        requested_model: "gpt-4o",
        upstream_account_plan_label: "pro",
        upstream_account_plan_family: "chatgpt",
        status: "succeeded"
      })

    %{request: no_plan_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-no-plan",
        requested_model: "gpt-4o",
        status: "succeeded"
      })

    %{request: custom_plan_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-custom-plan",
        requested_model: "gpt-4o",
        upstream_account_plan_label: "Team Plus",
        upstream_account_plan_family: "workspace_plus",
        status: "succeeded"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(view, "#request-log-#{plan_request.id}-plan-badge", "Pro")
    assert has_element?(view, "#request-log-#{plan_request.id}-plan-badge", "chatgpt")
    refute has_element?(view, "#request-log-#{plan_request.id}-plan-badge", "Fast mode")

    assert has_element?(
             view,
             "#request-log-#{custom_plan_request.id}-plan-badge",
             "Team Plus"
           )

    assert has_element?(
             view,
             "#request-log-#{custom_plan_request.id}-plan-badge",
             "workspace_plus"
           )

    assert has_element?(
             view,
             "#request-log-#{no_plan_request.id}-plan-badge",
             "—"
           )
  end

  test "token helper renders cached tokens in data-role with muted styling",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "cached-tokens", name: "Cached Tokens"})

    %{request: cached_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-cached",
        requested_model: "gpt-4o",
        input_tokens: 100,
        cached_input_tokens: 40,
        output_tokens: 50,
        total_tokens: 150,
        settled_cost_micros: 1_000,
        settlement_details: %{
          "pricing_status" => "priced",
          "settled_cost_micros" => "1000",
          "cached_input_cost_micros" => "100"
        },
        status: "succeeded"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(
             view,
             "#request-log-#{cached_request.id}-cached-tokens",
             "(40 cached)"
           )

    assert has_element?(
             view,
             "#request-log-row-#{cached_request.id} [data-role='token-totals']",
             "150 tokens"
           )

    html = render(view)
    assert html =~ "data-role=\"cached-tokens\""
    refute has_element?(view, "#request-log-#{cached_request.id}-cached-tokens", "total: 150")
  end

  test "renders compression savings from safe metadata with token-first and byte fallback",
       %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "compression-savings-logs",
        name: "Compression Savings Logs"
      })

    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Compression key"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    sentinel = "SENTINEL_TOOL_OUTPUT_SHOULD_NOT_RENDER"
    compressed_sentinel = "SENTINEL_COMPRESSED_OUTPUT_SHOULD_NOT_STORE"

    assert {:ok, %{request: token_request}} =
             Accounting.record_metadata_request(%{pool: pool, api_key: api_key}, %{
               endpoint: "/backend-api/codex/responses",
               requested_model: "gpt-compression-token-ui",
               transport: "http_json",
               status: "succeeded",
               correlation_id: "compression-token-ui",
               request_metadata: %{"body" => %{"input" => sentinel}}
             })

    assert {:ok, _token_attempt} =
             Accounting.create_attempt(token_request, assignment, %{
               status: "succeeded",
               response_metadata:
                 ui_compression_metadata(%{
                   route_class: "proxy_http",
                   transport: "http_json",
                   original_bytes: 4096,
                   compressed_bytes: 1024,
                   original_tokens: 1000,
                   compressed_tokens: 400,
                   tokenizer_input_skipped_count: 1,
                   raw_candidate: sentinel,
                   original_output: sentinel,
                   compressed_output: compressed_sentinel
                 })
             })

    ledger_entry_fixture(token_request, %{
      input_tokens: 80,
      cached_input_tokens: 0,
      output_tokens: 20,
      total_tokens: 100,
      settled_cost_micros: 1_000,
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "1000"}
    })

    assert {:ok, %{request: byte_request}} =
             Accounting.record_metadata_request(%{pool: pool, api_key: api_key}, %{
               endpoint: "/backend-api/codex/responses",
               requested_model: "gpt-compression-byte-ui",
               transport: "websocket",
               status: "succeeded",
               correlation_id: "compression-byte-ui",
               request_metadata: %{"websocket_frame" => sentinel}
             })

    assert {:ok, _byte_attempt} =
             Accounting.create_attempt(byte_request, assignment, %{
               status: "succeeded",
               response_metadata:
                 ui_compression_metadata(%{
                   route_class: "proxy_websocket",
                   transport: "websocket",
                   original_bytes: 8192,
                   compressed_bytes: 4096,
                   raw_candidate: sentinel,
                   original_output: sentinel,
                   compressed_output: compressed_sentinel
                 })
             })

    ledger_entry_fixture(byte_request, %{
      input_tokens: 40,
      cached_input_tokens: 0,
      output_tokens: 10,
      total_tokens: 50,
      settled_cost_micros: 500,
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "500"}
    })

    assert {:ok, %{request: zero_request}} =
             Accounting.record_metadata_request(%{pool: pool, api_key: api_key}, %{
               endpoint: "/backend-api/codex/responses",
               requested_model: "gpt-compression-zero-ui",
               transport: "http_json",
               status: "succeeded",
               correlation_id: "compression-zero-ui"
             })

    assert {:ok, _zero_attempt} =
             Accounting.create_attempt(zero_request, assignment, %{
               status: "succeeded",
               response_metadata:
                 ui_compression_metadata(%{
                   route_class: "proxy_http",
                   transport: "http_json",
                   original_bytes: 4096,
                   compressed_bytes: 4096,
                   raw_candidate: sentinel,
                   original_output: sentinel,
                   compressed_output: compressed_sentinel
                 })
             })

    ledger_entry_fixture(zero_request, %{
      input_tokens: 30,
      cached_input_tokens: 0,
      output_tokens: 10,
      total_tokens: 40,
      settled_cost_micros: 400,
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "400"}
    })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(
             view,
             "#request-log-#{token_request.id}-compression-savings[data-compression-unit='tokens'][data-compression-status='compressed'][data-compression-reason='rewritten']",
             "600 (60%)"
           )

    assert has_element?(
             view,
             "#request-log-#{token_request.id}-compression-savings .hero-arrows-pointing-in"
           )

    assert has_element?(
             view,
             "#request-log-#{token_request.id}-compression-savings[title*='tokenizer input skipped: 1']"
           )

    assert has_element?(
             view,
             "#request-log-#{token_request.id}-compression-savings[title*='not total request tokens']"
           )

    assert has_element?(
             view,
             "#mobile-request-log-#{token_request.id}-compression-savings[data-compression-unit='tokens']",
             "600 (60%)"
           )

    assert has_element?(
             view,
             "#mobile-request-log-#{token_request.id}-compression-savings .hero-arrows-pointing-in"
           )

    assert has_element?(
             view,
             "#mobile-request-log-#{token_request.id}-compression-savings[title*='tokenizer input skipped: 1']"
           )

    refute has_element?(view, "#request-log-#{byte_request.id}-compression-savings")
    refute has_element?(view, "#mobile-request-log-#{byte_request.id}-compression-savings")

    refute has_element?(view, "#request-log-#{zero_request.id}-compression-savings")
    refute has_element?(view, "#mobile-request-log-#{zero_request.id}-compression-savings")

    html = render(view)
    refute html =~ sentinel
    refute html =~ compressed_sentinel
  end

  test "transport and route helpers render in separate columns",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "transport-route", name: "Transport Route"})

    %{request: ws_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-ws-route",
        requested_model: "gpt-4o",
        endpoint: "/backend-api/codex/responses/compact",
        transport: "websocket",
        user_agent: "Codex CLI/1.2.3",
        latency_ms: 4_225,
        status: "succeeded"
      })

    desktop_user_agent =
      "Codex Desktop/0.128.0-alpha.1 (Mac OS 26.4.1; arm64) unknown (Codex Desktop; 26.429.61741)"

    %{request: desktop_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-desktop-route",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        user_agent: desktop_user_agent,
        status: "succeeded"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(view, "#request-log-#{ws_request.id}-protocol", "WebSocket")

    assert has_element?(
             view,
             "#request-log-#{ws_request.id}-route",
             "/backend-api/codex/responses/compact"
           )

    assert has_element?(
             view,
             "#request-log-#{ws_request.id}-route",
             "/backend-api/codex/responses/compact"
           )

    assert has_element?(
             view,
             "#request-log-#{ws_request.id}-route + #request-log-#{ws_request.id}-latency",
             "4.2s"
           )

    assert has_element?(
             view,
             "#request-log-#{ws_request.id}-latency[title='Elapsed upstream attempt time 4,225 ms']"
           )

    assert has_element?(view, "#request-log-#{ws_request.id}-user-agent", "Codex CLI 1.2.3")

    assert has_element?(
             view,
             "#request-log-#{ws_request.id}-user-agent[data-client-kind='codex']"
           )

    assert has_element?(view, "#request-log-#{ws_request.id}-user-agent .hero-command-line")

    assert has_element?(
             view,
             "#request-log-#{ws_request.id}-user-agent [data-role='user-agent-text']",
             "Codex CLI 1.2.3"
           )

    assert has_element?(
             view,
             "#request-log-#{desktop_request.id}-user-agent",
             "Codex Desktop 0.128.0-alpha.1"
           )

    assert has_element?(
             view,
             "#request-log-#{desktop_request.id}-user-agent[data-client-kind='codex_desktop']"
           )

    assert has_element?(
             view,
             "#request-log-#{desktop_request.id}-user-agent .hero-computer-desktop"
           )

    assert has_element?(
             view,
             "#mobile-request-log-#{desktop_request.id}-route",
             "/backend-api/codex/responses"
           )

    assert has_element?(
             view,
             "#mobile-request-log-#{desktop_request.id}-user-agent",
             "Codex Desktop 0.128.0-alpha.1"
           )

    assert has_element?(
             view,
             "#mobile-request-log-#{desktop_request.id}-user-agent[data-client-kind='codex_desktop']"
           )

    refute has_element?(view, "#request-log-#{desktop_request.id}-user-agent", "unknown")
    refute has_element?(view, "#request-log-#{desktop_request.id}-user-agent", "Mac OS")
    refute has_element?(view, "#request-log-#{desktop_request.id}-user-agent", "26.429.61741")

    refute has_element?(
             view,
             "#request-log-#{ws_request.id}-protocol",
             "/backend-api/codex/responses/compact"
           )
  end

  test "route metadata identifies OpenAI-compatible translated origins on desktop and mobile",
       %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "translated-origin", name: "Translated Origin"})

    sensitive_marker = "translated-origin-secret-prompt"

    %{request: translated_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-translated-origin",
        endpoint: "/backend-api/codex/responses",
        transport: "http_sse",
        request_metadata: %{
          "openai_compatibility" => %{
            "surface" => "openai_v1",
            "source_endpoint" => "/v1/chat/completions",
            "translated_endpoint" => "/backend-api/codex/responses"
          },
          "body" => %{"messages" => [%{"content" => sensitive_marker}]}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(
             view,
             "#request-log-row-#{translated_request.id} [data-role='route']",
             "/backend-api/codex/responses"
           )

    assert has_element?(
             view,
             "#request-log-row-#{translated_request.id} [data-role='route-metadata']",
             "translated from /v1/chat/completions"
           )

    assert has_element?(
             view,
             "#mobile-request-log-row-#{translated_request.id} [data-role='route-metadata']",
             "translated from /v1/chat/completions"
           )

    html = render(view)
    refute html =~ sensitive_marker
  end

  test "normalized table headers put transport, route, and usage in separate columns",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "header-order", name: "Header Order"})

    %{request: _request} =
      request_log_fixture(pool, %{
        correlation_id: "req-header-order",
        status: "succeeded"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    html = render(view)

    [_, desktop_table_head] =
      Regex.run(
        ~r/<thead>(.*?)<\/thead>\s*<tbody id="request-logs-table">/s,
        html
      )

    header_texts =
      Regex.scan(~r/<th[^>]*>([^<]+)<\/th>/, desktop_table_head, capture: :all_but_first)
      |> Enum.map(fn [text] -> String.trim(text) end)

    expected_headers = [
      "Timestamp",
      "Upstream account",
      "Plan",
      "Model / API Key",
      "Transport",
      "Route",
      "Usage",
      "Errors"
    ]

    assert header_texts == expected_headers

    assert has_element?(view, "#admin-request-logs thead th", "Timestamp")
    assert has_element?(view, "#admin-request-logs thead th", "Plan")
    assert has_element?(view, "#admin-request-logs thead th", "Transport")
  end

  test "normalized row renders all 9 column values with stable selectors",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "normalized-row", name: "Normalized Row"})

    %{request: request, identity: _identity} =
      request_log_fixture(pool, %{
        account_label: "operator@example.com",
        api_key_display_name: "Normalized key",
        correlation_id: "req-normalized",
        requested_model: "gpt-5.1",
        reasoning_effort: "high",
        service_tier: "default",
        actual_service_tier: "default",
        endpoint: "/backend-api/codex/responses/compact",
        transport: "websocket",
        status: "succeeded",
        latency_ms: 142,
        upstream_account_label: "operator@example.com",
        upstream_account_email: "operator@example.com",
        upstream_account_plan_label: "Pro",
        upstream_account_plan_family: "chatgpt",
        input_tokens: 200,
        cached_input_tokens: 50,
        output_tokens: 100,
        total_tokens: 300,
        settled_cost_micros: 234_567,
        settlement_details: %{
          "pricing_status" => "priced",
          "settled_cost_micros" => "234567",
          "cached_input_cost_micros" => "50"
        },
        request_metadata: %{
          "gateway_denial" => %{"code" => "sanitized_denial", "message" => "circuit open"}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    row_selector = "#request-log-row-#{request.id}"
    expected_datetime = Calendar.strftime(request.admitted_at, "%Y-%m-%d %H:%M:%S UTC")
    expected_record_id = String.slice(request.id, 0, 8)

    # 1. Timestamp
    refute has_element?(view, "#{row_selector} td.font-mono [data-role='timestamp']")

    assert has_element?(
             view,
             "#{row_selector} [data-role='timestamp-datetime']",
             expected_datetime
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='record-id'][title='#{request.id}']",
             expected_record_id
           )

    refute has_element?(view, "#{row_selector} [data-role='record-id'].font-mono")

    refute has_element?(
             view,
             "#{row_selector} [data-role='record-id']",
             "id #{expected_record_id}"
           )

    refute has_element?(view, "#{row_selector} [data-role='timestamp-date']")
    refute has_element?(view, "#{row_selector} [data-role='timestamp-time']")

    # 2. Upstream account email
    assert has_element?(
             view,
             "#{row_selector} [data-role='upstream-account']",
             "operator@example.com"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='pool-name']",
             "Normalized Row"
           )

    assert has_element?(view, "#{row_selector} [data-role='pool-icon']")

    # 3. Plan badge
    assert has_element?(view, "#{row_selector} [data-role='plan-badge']", "Pro")

    assert has_element?(
             view,
             "#{row_selector} [data-role='plan-badge']",
             "chatgpt"
           )

    # 4. API key
    assert has_element?(
             view,
             "#{row_selector} [data-role='api-key']",
             "Normalized key"
           )

    assert has_element?(view, "#{row_selector} [data-role='api-key-icon']")

    # 5. Model details
    assert has_element?(
             view,
             "#{row_selector} [data-role='model-details']",
             "gpt-5.1 high / default"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='model-name']",
             "gpt-5.1"
           )

    assert has_element?(view, "#{row_selector} [data-role='model-reasoning']", "high")
    assert has_element?(view, "#{row_selector} [data-role='model-service-tier']", "default")
    refute has_element?(view, "#{row_selector} [data-role='model-service-tier']", "tier:")
    refute has_element?(view, "#{row_selector} [data-role='model-details']", "(")

    # 6. Transport
    assert has_element?(
             view,
             "#{row_selector} [data-role='protocol-badge']",
             "WebSocket"
           )

    refute has_element?(
             view,
             "#{row_selector} [data-role='protocol-badge']",
             "/backend-api/codex/responses/compact"
           )

    # 7. Route
    assert has_element?(
             view,
             "#{row_selector} [data-role='route']",
             "/backend-api/codex/responses/compact"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='route'] + [data-role='latency']",
             "142ms"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='latency'][title='Elapsed upstream attempt time 142 ms']"
           )

    refute has_element?(view, "#{row_selector} [data-role='route']", "WebSocket")

    # 8. Status icon
    assert has_element?(
             view,
             "#{row_selector} [data-role='status-icon'][aria-label='Status: Succeeded']"
           )

    refute has_element?(view, "#{row_selector} [data-role='status']", "succeeded")

    # 9. Usage (token detail first, cost detail second)
    assert has_element?(
             view,
             "#{row_selector} [data-role='token-lines']"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='usage-token-line']",
             "300 tokens"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='usage-token-line']",
             "300 tokens (50 cached)"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='token-totals']",
             "300 tokens"
           )

    refute has_element?(view, "#{row_selector} [data-role='token-totals']", "input: 200")
    refute has_element?(view, "#{row_selector} [data-role='token-totals']", "cached: 50")
    refute has_element?(view, "#{row_selector} [data-role='token-totals']", "cost:")

    assert has_element?(
             view,
             "#{row_selector} [data-role='cached-tokens']",
             "(50 cached)"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='usage-token-line'] [data-role='cached-tokens']",
             "(50 cached)"
           )

    refute has_element?(view, "#{row_selector} [data-role='cached-tokens']", "cache $")
    refute has_element?(view, "#{row_selector} [data-role='usage-token-line']", "·")

    assert has_element?(
             view,
             "#{row_selector} [data-role='usage-cost-line'] [data-role='cost']",
             "$0.23"
           )

    assert has_element?(view, "#{row_selector} [data-role='cost'][title='Total cost $0.23']")

    refute has_element?(view, "#{row_selector} [data-role='cost']", "$0.234567")
    refute has_element?(view, "#{row_selector} [data-role='cost']", "cost:")

    assert has_element?(
             view,
             "#{row_selector} [data-role='usage-cost-line']",
             "$0.23 ($0.00 cached)"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='usage-cost-line'] [data-role='cached-cost']",
             "($0.00 cached)"
           )

    refute has_element?(view, "#{row_selector} [data-role='usage-cost-line']", "·")
    refute has_element?(view, "#{row_selector} [data-role='cached-cost'].sr-only")

    # 10. Errors
    assert has_element?(view, "#{row_selector} [data-role='errors']", "sanitized_denial")
  end

  test "renders stored request timestamps with current operator datetime preferences", %{
    scope: scope
  } do
    {:ok, user} =
      Accounts.update_current_operator_profile(scope.user, %{
        "datetime_format" => "default",
        "timezone" => "Europe/Rome"
      })

    {:ok, pool} = Pools.create_pool(scope, %{slug: "rome-logs", name: "Rome Logs"})

    stored_timestamp = ~U[2026-05-27 13:45:06.000000Z]

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-rome-time",
        admitted_at: stored_timestamp,
        completed_at: stored_timestamp,
        request_metadata: %{
          "candidate_exclusions" => [
            %{
              "reasons" => [
                %{
                  "code" => "quota_weekly_exhausted",
                  "reason_codes" => ["exhausted"],
                  "reset_at" => "2026-05-27T13:45:06Z"
                }
              ]
            }
          ]
        }
      })

    {:ok, view, _html} =
      live(
        build_conn() |> log_in_user(user, session_token(user)),
        ~p"/admin/request-logs?pool_id=#{pool.id}"
      )

    assert has_element?(
             view,
             "#request-log-row-#{request.id} [data-role='timestamp-datetime']",
             "2026-05-27 15:45:06 Europe/Rome"
           )

    assert has_element?(
             view,
             "#request-log-#{request.id}-errors",
             "resets 2026-05-27 15:45:06 Europe/Rome"
           )
  end

  test "missing request timestamp keeps not recorded display", %{scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "missing-time-logs", name: "Missing Time Logs"})

    %{request: request} = request_log_fixture(pool, %{correlation_id: "req-missing-time"})

    request_logs = Accounting.list_request_logs(pool, limit: 1)

    request_logs = %{
      request_logs
      | items: Enum.map(request_logs.items, &Map.replace!(&1, :admitted_at, nil))
    }

    html =
      render_component(&RequestLogsPresentation.request_logs_table/1,
        request_logs: request_logs,
        datetime_preferences: %{datetime_format: "default", timezone: "Etc/UTC"}
      )

    assert html =~ ~s(id="request-log-row-#{request.id}")
    assert html =~ "not recorded"
  end

  test "upstream account column reflects the current account label after a rename",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "renamed-row", name: "Renamed Row"})

    %{request: request, identity: identity} =
      request_log_fixture(pool, %{
        account_label: "Original upstream account",
        assignment_label: "Original assignment label",
        upstream_account_label: "Original upstream account"
      })

    identity
    |> Ecto.Changeset.change(account_label: "Renamed upstream account")
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    row_selector = "#request-log-row-#{request.id}"

    assert has_element?(
             view,
             "#{row_selector} [data-role='upstream-account']",
             "Renamed upstream account"
           )
  end

  @tag :feature_control_plane_request_logs
  test "renders metadata-only control-plane request log rows without leaking request or control-plane secrets",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "control-plane-logs", name: "Control Plane Logs"})

    %{request: proxied_request, attempt: proxied_attempt} =
      request_log_fixture(pool, %{
        api_key_display_name: "Control plane key",
        account_label: "control-plane-upstream@example.com",
        assignment_label: "Control plane assignment",
        requested_model: "/backend-api/codex/safety/arc",
        endpoint: "/backend-api/codex/safety/arc",
        transport: "http_json",
        status: "failed",
        response_status_code: 502,
        last_error_code: "upstream_status",
        latency_ms: 321,
        request_metadata: %{
          "endpoint" => "/backend-api/codex/safety/arc",
          "routing" => %{
            "route_class" => "proxy_control"
          },
          "request" => %{
            "body_bytes" => 187,
            "content_type" => "application/json"
          },
          "control_plane" => %{
            "analytics_forwarding" => "enabled"
          }
        }
      })

    proxied_attempt
    |> Ecto.Changeset.change(%{
      response_metadata: %{
        "message" => "Bearer client-secret",
        "cookie" => "session=secret",
        "sdp" => "v=0",
        "idempotency_key" => "raw-idempotency-key-secret",
        "trace" => "trace-secret-payload",
        "analytics" => "analytics-secret-payload",
        "arc" => "arc-secret-payload"
      }
    })
    |> Repo.update!()

    %{api_key: disabled_api_key} =
      active_api_key_fixture(pool, %{display_name: "Control plane disabled key"})

    assert {:ok, %{request: disabled_request}} =
             Accounting.record_metadata_request(%{pool: pool, api_key: disabled_api_key}, %{
               endpoint: "/backend-api/codex/analytics-events/events",
               transport: "http_json",
               status: "succeeded",
               correlation_id: "req-control-plane-disabled",
               response_status_code: 204,
               request_metadata: %{
                 "endpoint" => "/backend-api/codex/analytics-events/events",
                 "routing" => %{
                   "route_class" => "proxy_control"
                 },
                 "request" => %{
                   "body_bytes" => 99,
                   "content_type" => "application/json"
                 },
                 "control_plane" => %{
                   "analytics_forwarding" => "disabled"
                 }
               }
             })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(
             view,
             "#request-log-row-#{proxied_request.id}",
             "/backend-api/codex/safety/arc"
           )

    assert has_element?(
             view,
             "#request-log-row-#{proxied_request.id} [data-role='route-metadata']",
             "proxy_control"
           )

    assert has_element?(
             view,
             "#request-log-row-#{proxied_request.id} [data-role='route-metadata']",
             "application/json"
           )

    assert has_element?(
             view,
             "#request-log-row-#{proxied_request.id} [data-role='route-metadata']",
             "187 bytes"
           )

    assert has_element?(
             view,
             "#mobile-request-log-row-#{proxied_request.id} [data-role='route-metadata']",
             "proxy_control"
           )

    assert has_element?(
             view,
             "#mobile-request-log-row-#{proxied_request.id} [data-role='route-metadata']",
             "application/json"
           )

    assert has_element?(
             view,
             "#mobile-request-log-row-#{proxied_request.id} [data-role='route-metadata']",
             "187 bytes"
           )

    assert has_element?(
             view,
             "#request-log-row-#{disabled_request.id} [data-role='route']",
             "/backend-api/codex/analytics-events/events"
           )

    assert has_element?(
             view,
             "#request-log-row-#{disabled_request.id} [data-role='route-metadata']",
             "proxy_control"
           )

    assert has_element?(
             view,
             "#request-log-row-#{disabled_request.id} [data-role='route-metadata']",
             "application/json"
           )

    assert has_element?(
             view,
             "#request-log-row-#{disabled_request.id} [data-role='route-metadata']",
             "99 bytes"
           )

    assert has_element?(
             view,
             "#mobile-request-log-row-#{disabled_request.id} [data-role='route-metadata']",
             "proxy_control"
           )

    assert has_element?(
             view,
             "#mobile-request-log-row-#{disabled_request.id} [data-role='route-metadata']",
             "99 bytes"
           )

    refute has_element?(view, "#request-log-row-#{disabled_request.id}", "cost n/a")

    html = render(view)

    for forbidden <- [
          "ship sanitized control route tests",
          "analytics-secret-payload",
          "arc-secret-payload",
          "trace-secret-payload",
          "v=0",
          "Bearer client-secret",
          "session=secret",
          "raw-idempotency-key-secret"
        ] do
      refute html =~ forbidden
    end
  end

  test "legacy nil snapshot row falls back to selected upstream account and plan placeholder",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "legacy-row", name: "Legacy Row"})

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-legacy",
        requested_model: "gpt-4o",
        status: "failed",
        last_error_code: "no_eligible_backend",
        upstream_account_email: nil,
        upstream_account_plan_label: nil,
        upstream_account_plan_family: nil
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    row_selector = "#request-log-row-#{request.id}"

    assert has_element?(
             view,
             "#{row_selector} [data-role='upstream-account']",
             "Request log assignment"
           )

    assert has_element?(view, "#{row_selector} [data-role='plan-badge']", "—")

    assert has_element?(
             view,
             "#{row_selector} [data-role='status-icon'][aria-label='Status: Failed']"
           )

    assert has_element?(view, "#{row_selector} [data-role='errors']", "no_eligible_backend")
  end

  test "empty errors row renders — in errors column",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "empty-errors", name: "Empty Errors"})

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-empty-errors",
        requested_model: "gpt-4o",
        status: "succeeded",
        last_error_code: nil,
        request_metadata: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    row_selector = "#request-log-row-#{request.id}"

    assert has_element?(view, "#{row_selector} [data-role='errors']", "—")
  end

  test "active routing demotions do not render as request errors on successful rows", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "routing-state-errors", name: "Routing State Errors"})

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-routing-state",
        requested_model: "gpt-routing-state",
        status: "succeeded",
        request_metadata: %{
          "routing" => %{
            "strategy" => "bridge_ring",
            "demotion_reason" => "upstream_stream_error"
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    row_selector = "#request-log-row-#{request.id}"

    assert has_element?(
             view,
             "#{row_selector} [data-role='status-icon'][aria-label='Status: Succeeded']"
           )

    assert has_element?(view, "#{row_selector} [data-role='errors']", "—")
    refute has_element?(view, "#{row_selector} [data-role='errors']", "upstream_stream_error")
  end

  test "row with no ledger entry renders safely without token counts",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "no-ledger", name: "No Ledger"})

    %{api_key: api_key} =
      active_api_key_fixture(pool, %{display_name: "No ledger key"})

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "req-no-ledger",
        requested_model: "gpt-4o",
        status: "succeeded"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    row_selector = "#request-log-row-#{request.id}"

    assert has_element?(view, row_selector)
    assert has_element?(view, "#{row_selector} [data-role='usage-placeholder']", "—")
    refute has_element?(view, "#{row_selector} [data-role='token-totals']")
    refute has_element?(view, "#{row_selector} [data-role='cached-tokens']")
    refute has_element?(view, "#{row_selector} [data-role='cost']")
    refute has_element?(view, "#{row_selector} [data-role='cached-cost']")
    refute has_element?(view, row_selector, "cost n/a")
    refute has_element?(view, row_selector, "cached n/a")
  end

  test "errors helper renders sanitized summaries without raw secrets",
       %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "errors-display", name: "Errors Display"})
    secret_value = "secret-api-key-do-not-render"

    %{request: error_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-errors",
        requested_model: "gpt-4o",
        status: "failed",
        last_error_code: "upstream_status",
        response_status_code: 500,
        request_metadata: %{
          "gateway_denial" => %{"code" => "no_eligible_backend", "message" => "all circuits open"}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(view, "#request-log-#{error_request.id}-errors", "upstream_status")
    assert has_element?(view, "#request-log-#{error_request.id}-errors", "no_eligible_backend")

    html = render(view)
    refute html =~ secret_value
  end

  test "owner_drained rows keep persisted in-progress and failed statuses while showing sanitized attempt errors",
       %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "owner-drained-logs", name: "Owner Drained Logs"})

    in_progress_secret = "owner-drained-in-progress-secret-do-not-render"
    failed_secret = "owner-drained-failed-secret-do-not-render"

    %{request: in_progress_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-owner-drained-in-progress",
        requested_model: "gpt-owner-drained-in-progress",
        status: "in_progress",
        request_metadata: %{
          "body" => %{"input" => "raw websocket prompt #{in_progress_secret}"},
          "authorization" => "Bearer #{in_progress_secret}"
        },
        attempt_status: "failed",
        last_error_code: nil,
        attempt_network_error_code: "owner_drained",
        attempt_response_metadata: %{
          "body" => %{"input" => "raw websocket frame #{in_progress_secret}"},
          "authorization" => "Bearer #{in_progress_secret}"
        }
      })

    %{request: failed_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-owner-drained-failed",
        requested_model: "gpt-owner-drained-failed",
        status: "failed",
        request_metadata: %{
          "body" => %{"input" => "terminal raw prompt #{failed_secret}"},
          "authorization" => "Bearer #{failed_secret}"
        },
        attempt_status: "failed",
        last_error_code: nil,
        attempt_network_error_code: "owner_drained",
        attempt_response_metadata: %{
          "body" => %{"input" => "terminal raw frame #{failed_secret}"},
          "authorization" => "Bearer #{failed_secret}"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    in_progress_row = "#request-log-row-#{in_progress_request.id}"
    failed_row = "#request-log-row-#{failed_request.id}"

    assert has_element?(
             view,
             "#{in_progress_row} [data-role='status-icon'][aria-label='Status: In progress']"
           )

    assert has_element?(view, "#{in_progress_row} [data-role='errors']", "owner_drained")
    refute has_element?(view, "#{in_progress_row} [data-role='errors']", in_progress_secret)

    refute has_element?(
             view,
             "#{in_progress_row} [data-role='status-icon'][aria-label='Status: Failed']"
           )

    refute has_element?(view, in_progress_row, "Status: Failed")

    assert has_element?(
             view,
             "#{failed_row} [data-role='status-icon'][aria-label='Status: Failed']"
           )

    assert has_element?(view, "#{failed_row} [data-role='errors']", "owner_drained")
    refute has_element?(view, "#{failed_row} [data-role='errors']", failed_secret)

    refute has_element?(
             view,
             "#{failed_row} [data-role='status-icon'][aria-label='Status: In progress']"
           )

    refute has_element?(view, failed_row, "Status: In progress")

    html = render(view)
    refute html =~ in_progress_secret
    refute html =~ failed_secret
    refute html =~ "raw websocket prompt"
    refute html =~ "raw websocket frame"
  end

  test "quota exhaustion rows render as errors with reset time and concise copy", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "quota-exhausted-logs", name: "Quota Exhausted Logs"})

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-quota-exhausted",
        requested_model: "gpt-5.5",
        status: "rejected",
        usage_status: "not_applicable",
        last_error_code: "quota_exhausted",
        response_status_code: 503,
        request_metadata: %{
          "gateway_denial" => %{
            "code" => "quota_exhausted",
            "message" => "upstream quota is exhausted until its reset time"
          },
          "candidate_exclusions" => [
            %{
              "reasons" => [
                %{
                  "code" => "quota_weekly_exhausted",
                  "reason_codes" => ["exhausted"],
                  "reset_at" => "2026-05-11T02:55:14Z"
                }
              ]
            }
          ]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    row_selector = "#request-log-row-#{request.id}"

    assert has_element?(
             view,
             "#{row_selector} [data-role='status-icon'][aria-label='Status: Rejected']"
           )

    assert has_element?(view, "#request-log-#{request.id}-errors", "quota exhausted")

    assert has_element?(
             view,
             "#request-log-#{request.id}-errors",
             "resets 2026-05-11 02:55:14 UTC"
           )

    assert has_element?(view, "#request-log-#{request.id}-errors [data-role='error-line']")

    errors_html = view |> element("#request-log-#{request.id}-errors") |> render()
    refute errors_html =~ " · "
    refute errors_html =~ "quota_evidence_unavailable"
    refute errors_html =~ "quota_account_primary_missing"
  end

  test "invalid filters render validation feedback and do not crash", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "invalid-logs", name: "Invalid Logs"})
    request_log_fixture(pool, %{correlation_id: "req-invalid"})

    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/request-logs?pool_id=#{pool.id}&status=bogus&date_from=not-a-date"
      )

    assert has_element?(view, "#request-log-filter-errors", "Status filter is not supported")
    assert has_element?(view, "#request-log-filter-errors", "Date from must be a valid date")
    assert has_element?(view, "tr[id^='request-log-row-']")
  end

  test "scoped admins see only currently assigned request log history while owners keep archived history",
       %{scope: scope} do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{slug: "log-scope-assigned", name: "Log Scope Assigned"})

    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{slug: "log-scope-hidden", name: "Log Scope Hidden"})

    %{request: assigned_request} =
      request_log_fixture(assigned_pool, %{
        correlation_id: "req-log-scope-assigned",
        requested_model: "gpt-log-scope-assigned"
      })

    %{request: hidden_request} =
      request_log_fixture(hidden_pool, %{
        correlation_id: "req-log-scope-hidden",
        requested_model: "gpt-log-scope-hidden"
      })

    %{conn: admin_conn} = assigned_admin_conn(scope, assigned_pool, "log-scope-admin@example.com")

    {:ok, view, _html} = live(admin_conn, ~p"/admin/request-logs")

    assert has_element?(view, "#request-log-row-#{assigned_request.id}", "gpt-log-scope-assigned")
    refute has_element?(view, "#request-log-row-#{hidden_request.id}")

    assert has_element?(
             view,
             "#request-log-pool-filter button[data-pool-id='#{assigned_pool.id}']"
           )

    refute has_element?(view, "#request-log-pool-filter button[data-pool-id='#{hidden_pool.id}']")

    {:ok, hidden_filter_view, _html} =
      live(
        admin_conn,
        ~p"/admin/request-logs?pool_id=#{hidden_pool.id}&request_id=#{hidden_request.id}"
      )

    assert has_element?(
             hidden_filter_view,
             "#request-log-filter-errors",
             "Pool filter did not match an available Pool"
           )

    refute has_element?(hidden_filter_view, "#request-log-row-#{hidden_request.id}")

    assert {:ok, archived_pool} = Pools.change_pool_status(scope, assigned_pool, "archived")

    {:ok, revoked_admin_view, _html} = live(admin_conn, ~p"/admin/request-logs")
    refute has_element?(revoked_admin_view, "#request-log-row-#{assigned_request.id}")

    refute has_element?(
             revoked_admin_view,
             "#request-log-pool-filter button[data-pool-id='#{assigned_pool.id}']"
           )

    {:ok, owner_view, _html} =
      live(
        build_conn() |> log_in_user(scope.user, session_token(scope.user)),
        ~p"/admin/request-logs"
      )

    assert has_element?(
             owner_view,
             "#request-log-row-#{assigned_request.id}",
             "gpt-log-scope-assigned"
           )

    assert has_element?(
             owner_view,
             "#request-log-pool-filter button[data-pool-id='#{archived_pool.id}']"
           )
  end

  defp attach_request_log_reload_telemetry do
    test_pid = self()
    telemetry_ref = make_ref()
    handler_id = {__MODULE__, :request_log_reload, telemetry_ref}

    :ok =
      :telemetry.attach(
        handler_id,
        @request_logs_reload_event,
        fn _event, measurements, metadata, _config ->
          send(test_pid, {telemetry_ref, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    telemetry_ref
  end

  defp assert_request_log_reload(telemetry_ref, stage, scope) do
    assert_receive {^telemetry_ref, %{count: 1}, %{stage: ^stage, scope: ^scope}}, 1_000
  end

  defp refute_request_log_reload(telemetry_ref, stage) do
    refute_receive {^telemetry_ref, _measurements, %{stage: ^stage}}, 100
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    test_pid = self()
    handler_id = {__MODULE__, :repo_query, test_pid, System.unique_integer([:positive])}

    handler = fn _event, _measurements, metadata, _config ->
      if metadata[:repo] == Repo do
        send(test_pid, {handler_id, repo_query_event(metadata)})
      end
    end

    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], handler, nil)

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp repo_query_event(metadata) do
    %{
      source: normalize_query_metadata(metadata[:source]),
      query: normalize_query_metadata(metadata[:query])
    }
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_repo_query_events(handler_id, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp source_select_count(events, source) do
    Enum.count(events, fn event ->
      event.source == source and
        event.query |> String.trim_leading() |> String.upcase() |> String.starts_with?("SELECT")
    end)
  end

  defp normalize_query_metadata(nil), do: "unknown"
  defp normalize_query_metadata(value) when is_binary(value), do: value
  defp normalize_query_metadata(value), do: to_string(value)

  defp request_log_fixture(pool, attrs) do
    %{api_key: api_key} =
      active_api_key_fixture(pool, %{
        display_name: Map.get(attrs, :api_key_display_name, "Request log key")
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: Map.get(attrs, :account_label, "Request log upstream"),
        assignment_label: Map.get(attrs, :assignment_label, "Request log assignment")
      })

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: Map.get(attrs, :requested_model, "gpt-request-log"),
        endpoint: Map.get(attrs, :endpoint, "/backend-api/codex/responses"),
        status: Map.get(attrs, :status, "succeeded"),
        correlation_id:
          Map.get(
            attrs,
            :correlation_id,
            "req-live-#{System.unique_integer([:positive])}"
          ),
        transport: Map.get(attrs, :transport, "http_json"),
        user_agent: Map.get(attrs, :user_agent),
        request_metadata: Map.get(attrs, :request_metadata, %{}),
        last_error_code: Map.get(attrs, :last_error_code),
        response_status_code: Map.get(attrs, :response_status_code, 200),
        usage_status: Map.get(attrs, :usage_status, "usage_known"),
        upstream_account_label: Map.get(attrs, :upstream_account_label),
        upstream_account_email: Map.get(attrs, :upstream_account_email),
        upstream_account_plan_label: Map.get(attrs, :upstream_account_plan_label),
        upstream_account_plan_family: Map.get(attrs, :upstream_account_plan_family),
        reasoning_effort: Map.get(attrs, :reasoning_effort),
        service_tier: Map.get(attrs, :service_tier),
        requested_service_tier: Map.get(attrs, :requested_service_tier),
        actual_service_tier: Map.get(attrs, :actual_service_tier)
      })

    request =
      if Map.has_key?(attrs, :admitted_at) do
        request
        |> Ecto.Changeset.change(%{admitted_at: Map.get(attrs, :admitted_at)})
        |> Repo.update!()
      else
        request
      end

    attempt =
      attempt_fixture(request, assignment, %{
        status: Map.get(attrs, :attempt_status, "succeeded"),
        latency_ms: Map.get(attrs, :latency_ms),
        usage_status:
          Map.get(attrs, :attempt_usage_status, Map.get(attrs, :usage_status, "usage_known")),
        upstream_status_code: Map.get(attrs, :response_status_code, 200),
        network_error_code:
          Map.get(attrs, :attempt_network_error_code, Map.get(attrs, :last_error_code)),
        response_metadata: Map.get(attrs, :attempt_response_metadata, %{})
      })

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      input_tokens: Map.get(attrs, :input_tokens, 1),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 1),
      total_tokens: Map.get(attrs, :total_tokens, 2),
      settled_cost_micros: Map.get(attrs, :settled_cost_micros, 0),
      usage_status:
        Map.get(attrs, :settlement_usage_status, Map.get(attrs, :usage_status, "usage_known")),
      details: Map.get(attrs, :settlement_details, %{})
    })

    %{request: request, attempt: attempt, identity: identity, assignment: assignment}
  end

  defp ui_compression_metadata(attrs) do
    metadata =
      %{
        "enabled" => true,
        "attempted" => true,
        "status" => "compressed",
        "reason" => "rewritten",
        "route_class" => Map.fetch!(attrs, :route_class),
        "transport" => Map.fetch!(attrs, :transport),
        "candidate_count" => 1,
        "compressed_count" => 1,
        "skipped_count" => 0,
        "original_bytes" => Map.fetch!(attrs, :original_bytes),
        "compressed_bytes" => Map.fetch!(attrs, :compressed_bytes),
        "strategies" => ["log_output"],
        "raw_candidate" => Map.fetch!(attrs, :raw_candidate),
        "original_output" => Map.fetch!(attrs, :original_output),
        "compressed_output" => Map.fetch!(attrs, :compressed_output)
      }

    metadata =
      metadata
      |> maybe_put("original_tokens", Map.get(attrs, :original_tokens))
      |> maybe_put("compressed_tokens", Map.get(attrs, :compressed_tokens))
      |> maybe_put(
        "tokenizer_input_skipped_count",
        Map.get(attrs, :tokenizer_input_skipped_count)
      )

    %{"payload_compression" => metadata}
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp assigned_admin_conn(scope, pool, email) do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => email,
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    %{conn: log_in_user(build_conn(), admin, token), user: admin}
  end

  defp session_token(user) do
    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => user.email, "password" => valid_user_password()})

    token
  end
end
