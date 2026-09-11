defmodule CodexPoolerWeb.Admin.RequestLogsServiceTierLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Pools

  setup :register_and_log_in_user

  # The ChatGPT Codex backend reports `default` on the terminal event of a
  # `priority` request, and accounting prices the reported tier. These rows
  # carry the persisted columns that settlement writes for that case.
  @echo_mismatch %{
    requested_service_tier: "priority",
    actual_service_tier: "default",
    service_tier: "standard",
    settlement_details: %{"pricing_status" => "priced", "settled_cost_micros" => "40"}
  }

  @sensitive_marker "service-tier-log-prompt-must-not-render"

  test "list rows say which tier was requested when the upstream reported another", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "tier-echo-list")

    %{request: sse_mismatch} =
      request_log_fixture(
        pool,
        Map.merge(@echo_mismatch, %{correlation_id: "req-tier-sse", transport: "http_sse"})
      )

    %{request: websocket_mismatch} =
      request_log_fixture(
        pool,
        Map.merge(@echo_mismatch, %{correlation_id: "req-tier-ws", transport: "websocket"})
      )

    %{request: priority_reported} =
      request_log_fixture(pool, %{
        correlation_id: "req-tier-priority-reported",
        transport: "http_sse",
        requested_service_tier: "priority",
        actual_service_tier: "priority",
        service_tier: "priority",
        settlement_details: %{"pricing_status" => "priced"}
      })

    %{request: no_tier} =
      request_log_fixture(pool, %{correlation_id: "req-tier-none", transport: "websocket"})

    {:ok, view, _html} = live_request_logs(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    for request <- [sse_mismatch, websocket_mismatch] do
      model_cell = "#request-log-#{request.id}-model-details"

      assert has_element?(view, "#{model_cell} [data-role='model-service-tier']", "tier default")

      assert has_element?(
               view,
               "#request-log-#{request.id}-requested-tier[data-role='requested-service-tier']",
               "priority requested"
             )

      assert has_element?(view, "#{model_cell}[title*='tier default priority requested']")

      refute has_element?(
               view,
               "#request-log-#{request.id}-protocol [data-role='fast-mode-indicator']"
             )
    end

    assert has_element?(view, "#request-log-#{sse_mismatch.id}-protocol", "HTTP SSE")
    assert has_element?(view, "#request-log-#{websocket_mismatch.id}-protocol", "WebSocket")

    assert has_element?(
             view,
             "#request-log-#{priority_reported.id}-model-details [data-role='model-service-tier']",
             "tier priority"
           )

    refute has_element?(view, "#request-log-#{priority_reported.id}-requested-tier")

    assert has_element?(
             view,
             "#request-log-#{priority_reported.id}-protocol [data-role='fast-mode-indicator'][data-speed-tier='fast']"
           )

    refute has_element?(view, "#request-log-#{no_tier.id}-requested-tier")

    refute has_element?(
             view,
             "#request-log-#{no_tier.id}-protocol [data-role='fast-mode-indicator']"
           )

    refute render(view) =~ @sensitive_marker
  end

  test "drawer separates the requested, upstream-reported, and billed tiers", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "tier-echo-drawer")

    %{request: sse_mismatch} =
      request_log_fixture(
        pool,
        Map.merge(@echo_mismatch, %{correlation_id: "req-drawer-tier-sse", transport: "http_sse"})
      )

    %{request: websocket_mismatch} =
      request_log_fixture(
        pool,
        Map.merge(@echo_mismatch, %{
          correlation_id: "req-drawer-tier-ws",
          transport: "websocket"
        })
      )

    %{request: priority_reported} =
      request_log_fixture(pool, %{
        correlation_id: "req-drawer-tier-priority",
        transport: "websocket",
        requested_service_tier: "priority",
        actual_service_tier: "priority",
        service_tier: "priority",
        settlement_details: %{"pricing_status" => "priced"}
      })

    %{request: unrequested} =
      request_log_fixture(pool, %{
        correlation_id: "req-drawer-tier-unrequested",
        transport: "http_sse",
        actual_service_tier: "default",
        service_tier: "standard",
        settlement_details: %{"pricing_status" => "priced"}
      })

    %{request: unpriced_mismatch} =
      request_log_fixture(
        pool,
        Map.merge(@echo_mismatch, %{
          correlation_id: "req-drawer-tier-unpriced",
          transport: "http_sse",
          settlement_details: %{"pricing_status" => "unpriced_missing_model"}
        })
      )

    %{request: no_tier} =
      request_log_fixture(pool, %{correlation_id: "req-drawer-tier-none", transport: "http_sse"})

    for request <- [sse_mismatch, websocket_mismatch] do
      view = open_selected_request(conn, pool, request)

      assert has_element?(view, "#request-log-detail-requested-tier", "Requested tier")
      assert has_element?(view, "#request-log-detail-requested-tier", "priority")
      assert has_element?(view, "#request-log-detail-upstream-reported-tier", "Upstream reported")
      assert has_element?(view, "#request-log-detail-upstream-reported-tier", "default")
      assert has_element?(view, "#request-log-detail-priced-tier", "Priced as")
      assert has_element?(view, "#request-log-detail-priced-tier", "standard")
      refute render(view) =~ @sensitive_marker
    end

    view = open_selected_request(conn, pool, priority_reported)
    assert has_element?(view, "#request-log-detail-requested-tier", "priority")
    assert has_element?(view, "#request-log-detail-upstream-reported-tier", "priority")
    assert has_element?(view, "#request-log-detail-priced-tier", "priority")

    view = open_selected_request(conn, pool, unrequested)
    assert has_element?(view, "#request-log-detail-requested-tier", "Not set")
    assert has_element?(view, "#request-log-detail-upstream-reported-tier", "default")
    assert has_element?(view, "#request-log-detail-priced-tier", "standard")

    # Without a priced settlement no tier was billed, so the row is omitted.
    view = open_selected_request(conn, pool, unpriced_mismatch)
    assert has_element?(view, "#request-log-detail-requested-tier", "priority")
    assert has_element?(view, "#request-log-detail-upstream-reported-tier", "default")
    refute has_element?(view, "#request-log-detail-priced-tier")

    view = open_selected_request(conn, pool, no_tier)
    refute has_element?(view, "#request-log-detail-requested-tier")
    refute has_element?(view, "#request-log-detail-upstream-reported-tier")
    refute has_element?(view, "#request-log-detail-priced-tier")
  end

  defp create_pool!(scope, slug) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: slug, name: slug})
    pool
  end

  defp request_log_fixture(pool, attrs) do
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Tier log key"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Tier log upstream",
        assignment_label: "Tier log assignment"
      })

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-tier-log",
        endpoint: "/backend-api/codex/responses",
        status: "succeeded",
        correlation_id: Map.fetch!(attrs, :correlation_id),
        transport: Map.fetch!(attrs, :transport),
        request_metadata: %{"prompt" => @sensitive_marker},
        response_status_code: 200,
        usage_status: "usage_known",
        service_tier: Map.get(attrs, :service_tier),
        requested_service_tier: Map.get(attrs, :requested_service_tier),
        actual_service_tier: Map.get(attrs, :actual_service_tier)
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: "succeeded",
        usage_status: "usage_known",
        upstream_status_code: 200
      })

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      input_tokens: 2,
      cached_input_tokens: 0,
      output_tokens: 1,
      total_tokens: 3,
      settled_cost_micros: 40,
      usage_status: "usage_known",
      details: Map.get(attrs, :settlement_details, %{})
    })

    %{request: request}
  end

  defp open_selected_request(conn, pool, request) do
    {:ok, view, _html} =
      live_request_logs(
        conn,
        ~p"/admin/request-logs?pool_id=#{pool.id}&selected_request_id=#{request.id}"
      )

    assert has_element?(view, "#request-log-detail-request-id", request.id)
    view
  end

  defp live_request_logs(conn, path) do
    with {:ok, view, html} <- live(conn, path) do
      _ = await_request_logs(view)
      {:ok, view, html}
    end
  end

  defp await_request_logs(view, attempts \\ 200)

  defp await_request_logs(view, attempts) when attempts > 0 do
    _ = render_async(view, 5_000)
    state = :sys.get_state(view.pid)

    if state.socket.assigns.request_logs_loading? or
         state.socket.assigns.request_logs_running? do
      receive do
      after
        1 -> await_request_logs(view, attempts - 1)
      end
    else
      state
    end
  end

  defp await_request_logs(view, 0) do
    flunk("request logs did not finish loading: #{inspect(:sys.get_state(view.pid))}")
  end
end
