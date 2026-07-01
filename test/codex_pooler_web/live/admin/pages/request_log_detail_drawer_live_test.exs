defmodule CodexPoolerWeb.Admin.RequestLogDetailDrawerLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.{Accounts, Pools, Repo}

  setup :register_and_log_in_user

  test "mounts request detail drawer shell while closed", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, %{slug: "closed-drawer-logs", name: "Closed Drawer Logs"})

    request_log_fixture(pool, %{correlation_id: "req-closed-drawer"})

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(view, "#request-log-detail-drawer-root")
    assert has_element?(view, "#request-log-detail-sidebar[role='dialog']")
    refute has_element?(view, "#request-log-detail-drawer[checked]")
    assert has_element?(view, "#request-log-detail-sidebar", "Select a request")
    refute has_element?(view, "#request-log-detail-request-id")
  end

  test "opens and closes sanitized request detail drawer through URL state", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, %{slug: "drawer-url-logs", name: "Drawer URL Logs"})

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-drawer-url",
        requested_model: "gpt-drawer-url",
        reasoning_effort: "high",
        status: "failed",
        last_error_code: "upstream_network_error",
        retry_count: 1,
        attempt_status: "failed",
        attempt_network_error_code: "upstream_network_error",
        attempt_response_metadata: %{
          "reasoning" => %{
            "applied_effort" => "max",
            "effective_effort" => "max",
            "source" => "api_key_policy",
            "rewrite" => "high_to_max"
          },
          "transport_failure" => %{
            "exception" => "Mint.TransportError",
            "reason_class" => "transport",
            "reason" => "closed",
            "phase" => "request"
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}&status=failed")

    render_click(element(view, "#request-log-#{request.id}-open-details"))

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "pool_id" => pool.id,
             "selected_request_id" => request.id,
             "status" => "failed"
           }

    assert has_element?(view, "#request-log-detail-drawer[checked]")
    request_label = "Request #{String.slice(request.id, 0, 8)}"
    assert has_element?(view, "#request-log-detail-sidebar", request_label)

    assert has_element?(view, "#request-log-detail-request-id", request.id)
    assert has_element?(view, "#request-log-detail-correlation-id", "req-drawer-url")
    assert has_element?(view, "#request-log-detail-requested-reasoning", "high")
    assert has_element?(view, "#request-log-detail-applied-reasoning", "max")
    assert has_element?(view, "#request-log-detail-upstream-reasoning", "max")
    assert has_element?(view, "#request-log-detail-attempts", "Attempt 1")
    assert has_element?(view, "#request-log-detail-transport-failure-1", "Mint.TransportError")
    assert has_element?(view, "#request-log-detail-transport-failure-1", "closed")

    render_click(element(view, "#request-log-detail-sidebar-close"))

    patched_path = assert_patch(view)
    close_query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert close_query == %{"pool_id" => pool.id, "status" => "failed"}
    refute has_element?(view, "#request-log-detail-drawer[checked]")
    refute has_element?(view, "#request-log-detail-request-id")
  end

  test "selected request detail remains visible after refresh removes row from table", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, %{slug: "drawer-refresh-logs", name: "Drawer Refresh Logs"})

    older_at = DateTime.add(DateTime.utc_now(), -2, :hour)

    %{request: selected_request} =
      request_log_fixture(pool, %{
        correlation_id: "req-refresh-selected",
        requested_model: "gpt-refresh-selected",
        admitted_at: older_at
      })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/request-logs?pool_id=#{pool.id}&selected_request_id=#{selected_request.id}"
      )

    assert has_element?(view, "#request-log-detail-drawer[checked]")
    assert has_element?(view, "#request-log-detail-correlation-id", "req-refresh-selected")
    assert has_element?(view, "#request-log-row-#{selected_request.id}")

    for index <- 1..50 do
      request_log_fixture(pool, %{
        correlation_id: "req-refresh-newer-#{index}",
        requested_model: "gpt-refresh-newer-#{index}"
      })
    end

    send(view.pid, :refresh_request_logs_from_events)
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#request-log-row-#{selected_request.id}")
    assert has_element?(view, "#request-log-detail-drawer[checked]")
    assert has_element?(view, "#request-log-detail-correlation-id", "req-refresh-selected")
  end

  test "missing or unauthorized selected request closes and clears URL state", %{
    conn: owner_conn,
    scope: owner_scope
  } do
    visible_pool =
      create_pool!(owner_scope, %{slug: "drawer-visible-logs", name: "Drawer Visible Logs"})

    hidden_pool = pool_fixture(%{slug: "drawer-hidden-logs", name: "Drawer Hidden Logs"})

    %{request: hidden_request} =
      request_log_fixture(hidden_pool, %{
        correlation_id: "req-hidden-drawer",
        requested_model: "gpt-hidden-drawer"
      })

    %{conn: admin_conn} = assigned_admin_conn(owner_scope, visible_pool, unique_user_email())

    assert {:error, {:live_redirect, %{to: "/admin/request-logs"}}} =
             live(admin_conn, ~p"/admin/request-logs?selected_request_id=#{hidden_request.id}")

    missing_request_id = Ecto.UUID.generate()

    assert {:error, {:live_redirect, %{to: "/admin/request-logs"}}} =
             live(owner_conn, ~p"/admin/request-logs?selected_request_id=#{missing_request_id}")

    {:ok, view, _html} = live(owner_conn, ~p"/admin/request-logs")

    refute has_element?(view, "#request-log-detail-drawer[checked]")
    refute has_element?(view, "#request-log-detail-correlation-id", "req-hidden-drawer")
  end

  test "request detail drawer redacts raw sensitive metadata and shows compact transport failure fields",
       %{conn: conn, scope: scope} do
    pool = create_pool!(scope, %{slug: "drawer-redaction-logs", name: "Drawer Redaction Logs"})

    sensitive_marker = "drawer-sensitive-value-should-not-render"

    raw_transport_detail =
      "tcp reset for https://upstream.example.com/path?token=#{sensitive_marker}"

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-drawer-redaction",
        requested_model: "gpt-drawer-redaction",
        status: "failed",
        last_error_code: "upstream_network_error",
        request_metadata: %{
          "body" => %{"input" => "raw prompt #{sensitive_marker}"},
          "headers" => %{"authorization" => "Bearer #{sensitive_marker}"},
          "auth_json" => %{"refresh_token" => sensitive_marker},
          "url" => "https://upstream.example.com/path?token=#{sensitive_marker}",
          "quota_decision" => %{"summary" => "allowed by quota evidence"},
          "routing" => %{
            "strategy" => "bridge_ring",
            "route_class" => "proxy_http",
            "selected_bridge_candidate_rank" => 2
          }
        },
        attempt_status: "failed",
        attempt_network_error_code: "upstream_network_error",
        attempt_response_metadata: %{
          "transport_failure" => %{
            "exception" => "Mint.TransportError",
            "reason_class" => "transport",
            "reason" => "closed",
            "phase" => "request",
            "raw_reason_detail" => raw_transport_detail
          },
          "headers" => %{"authorization" => "Bearer #{sensitive_marker}"},
          "body" => %{"output" => "raw body #{sensitive_marker}"}
        }
      })

    {:ok, view, _html} =
      live(conn, ~p"/admin/request-logs?selected_request_id=#{request.id}")

    assert has_element?(view, "#request-log-detail-drawer[checked]")
    assert has_element?(view, "#request-log-detail-transport-failure-1", "Mint.TransportError")
    assert has_element?(view, "#request-log-detail-transport-failure-1", "transport")
    assert has_element?(view, "#request-log-detail-transport-failure-1", "closed")
    assert has_element?(view, "#request-log-detail-transport-failure-1", "request")
    assert has_element?(view, "#request-log-detail-quota-summary", "allowed by quota evidence")
    assert has_element?(view, "#request-log-detail-routing-strategy", "bridge_ring")
    assert has_element?(view, "#request-log-detail-selected-rank", "2")

    drawer_html = view |> element("#request-log-detail-sidebar") |> render()

    refute drawer_html =~ sensitive_marker
    refute drawer_html =~ raw_transport_detail
    refute drawer_html =~ "raw prompt"
    refute drawer_html =~ "raw body"
    refute drawer_html =~ "Bearer"
    refute drawer_html =~ "auth_json"
    refute drawer_html =~ "refresh_token"
    refute drawer_html =~ "https://upstream.example.com"
    refute drawer_html =~ "raw_reason_detail"
  end

  defp create_pool!(scope, attrs) do
    {:ok, pool} = Pools.create_pool(scope, attrs)
    pool
  end

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
          Map.get(attrs, :correlation_id, "req-live-#{System.unique_integer([:positive])}"),
        transport: Map.get(attrs, :transport, "http_json"),
        request_metadata: Map.get(attrs, :request_metadata, %{}),
        last_error_code: Map.get(attrs, :last_error_code),
        response_status_code: Map.get(attrs, :response_status_code, 200),
        usage_status: Map.get(attrs, :usage_status, "usage_known"),
        reasoning_effort: Map.get(attrs, :reasoning_effort)
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
end
