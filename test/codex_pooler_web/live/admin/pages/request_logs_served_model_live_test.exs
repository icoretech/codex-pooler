defmodule CodexPoolerWeb.Admin.RequestLogsServedModelLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  # Failure-detection budget for an asynchronous load the test awaits: a green
  # run returns as soon as the view has settled.
  @detection_timeout_ms 15_000

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Pools

  setup :register_and_log_in_user

  @sensitive_marker "served-model-log-prompt-must-not-render"

  # The provider can answer with a model other than the one the attempt sent
  # (codex issue 46632 recorded `gpt-6-astra` served as `gpt-5.6-luna`). The
  # list flags only that case; the drawer always shows both attempt facts.
  test "list rows flag a served model that differs from the one sent upstream", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "served-model-list")

    %{request: substituted} =
      request_log_fixture(pool, %{
        correlation_id: "req-served-substituted",
        upstream_model_id: "gpt-6-astra",
        served_model: "gpt-6-luna"
      })

    %{request: echoed} =
      request_log_fixture(pool, %{
        correlation_id: "req-served-echoed",
        upstream_model_id: "gpt-6-astra",
        served_model: "GPT-6-Astra"
      })

    %{request: undeclared} =
      request_log_fixture(pool, %{
        correlation_id: "req-served-undeclared",
        upstream_model_id: "gpt-6-astra",
        served_model: nil
      })

    {:ok, view, _html} = live_request_logs(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    assert has_element?(view, "#request-log-model-guide-link[href='https://docs.codex-pooler.com/operators/lens/#read-the-request-log-warnings'][target='_blank'][rel='noopener noreferrer']", "Model warnings explained")

    assert has_element?(
             view,
             "#request-log-#{substituted.id}-model-details [data-role='model-identity-line'] > [data-role='served-model']",
             "gpt-6-luna"
           )

    assert has_element?(view, "#request-log-#{substituted.id}-served-model .hero-exclamation-triangle.text-error")
    assert has_element?(view, "#request-log-#{substituted.id}-served-model[aria-label*='Upstream declared model: gpt-6-luna']")
    assert has_element?(view, "#request-log-#{substituted.id}-model-details [data-role='model-identity-line'] > [data-role='model-name']", "gpt-6-astra")
    refute has_element?(view, "#request-log-#{substituted.id}-served-model", "served")

    assert has_element?(
             view,
             "#request-log-#{substituted.id}-model-details[title*='gpt-6-astra served gpt-6-luna']"
           )

    refute has_element?(view, "#request-log-#{echoed.id}-served-model")
    refute has_element?(view, "#request-log-#{undeclared.id}-served-model")
    refute render(view) =~ @sensitive_marker
  end

  test "drawer separates the requested, sent, and served models", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, "served-model-drawer")

    %{request: substituted} =
      request_log_fixture(pool, %{
        correlation_id: "req-drawer-served-substituted",
        upstream_model_id: "gpt-6-astra",
        served_model: "gpt-6-luna"
      })

    %{request: undeclared} =
      request_log_fixture(pool, %{
        correlation_id: "req-drawer-served-undeclared",
        upstream_model_id: "gpt-6-astra",
        served_model: nil
      })

    view = open_selected_request(conn, pool, substituted)
    assert has_element?(view, "#request-log-detail-model", "gpt-6-astra")
    assert has_element?(view, "#request-log-detail-upstream-model", "Sent upstream")
    assert has_element?(view, "#request-log-detail-upstream-model", "gpt-6-astra")
    assert has_element?(view, "#request-log-detail-served-model", "Upstream served")
    assert has_element?(view, "#request-log-detail-served-model", "gpt-6-luna")
    refute render(view) =~ @sensitive_marker

    view = open_selected_request(conn, pool, undeclared)
    assert has_element?(view, "#request-log-detail-upstream-model", "gpt-6-astra")
    refute has_element?(view, "#request-log-detail-served-model")
  end

  defp create_pool!(scope, slug) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: slug, name: slug})
    pool
  end

  defp request_log_fixture(pool, attrs) do
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Served model log key"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Served model upstream",
        assignment_label: "Served model assignment"
      })

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-6-astra",
        endpoint: "/backend-api/codex/responses",
        status: "succeeded",
        correlation_id: Map.fetch!(attrs, :correlation_id),
        transport: "websocket",
        request_metadata: %{"prompt" => @sensitive_marker},
        response_status_code: 200,
        usage_status: "usage_known"
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: "succeeded",
        usage_status: "usage_known",
        upstream_status_code: 200,
        upstream_model_id: Map.fetch!(attrs, :upstream_model_id),
        served_model: Map.get(attrs, :served_model)
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
      details: %{"pricing_status" => "priced"}
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

  defp await_request_logs(view),
    do: await_request_logs(view, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp await_request_logs(view, deadline) do
    _ = render_async(view, 5_000)
    state = :sys.get_state(view.pid)

    if state.socket.assigns.request_logs_loading? or
         state.socket.assigns.request_logs_running? do
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("request logs did not finish loading: #{inspect(:sys.get_state(view.pid))}")

      receive do
      after
        1 -> await_request_logs(view, deadline)
      end
    else
      state
    end
  end
end
