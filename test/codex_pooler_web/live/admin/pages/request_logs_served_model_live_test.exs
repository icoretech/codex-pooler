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

    assert has_element?(view, "#request-log-model-guide-link[href='https://www.codex-pooler.com/docs/operators/lens/#read-the-request-log-warnings'][target='_blank'][rel='noopener noreferrer']", "Model warnings explained")

    assert has_element?(
             view,
             "#request-log-row-#{substituted.id} [data-role='request-issues-cell'] [data-role='served-model']",
             "gpt-6-luna"
           )

    assert has_element?(view, "#request-log-#{substituted.id}-served-model.text-warning .hero-exclamation-triangle")
    assert has_element?(view, "#request-log-#{substituted.id}-served-model[aria-label*='Upstream declared model: gpt-6-luna']")
    assert has_element?(view, "#request-log-#{substituted.id}-model-details [data-role='model-identity-line'] > [data-role='model-name']", "gpt-6-astra")
    refute has_element?(view, "#request-log-#{substituted.id}-served-model", "served")

    assert has_element?(
             view,
             "#request-log-#{substituted.id}-model-details[title*='gpt-6-astra served gpt-6-luna']"
           )

    refute has_element?(view, "#request-log-#{echoed.id}-served-model")
    refute has_element?(view, "#request-log-#{undeclared.id}-served-model")
    assert has_element?(view, "#request-log-row-#{echoed.id} [data-role='no-request-issues']", "—")
    refute has_element?(view, "#request-log-#{substituted.id}-model-details [data-role='served-model']")
    refute render(view) =~ @sensitive_marker
  end

  test "one issues cell contains all failure summaries and both model warnings", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, "combined-request-issues")

    %{request: request} =
      request_log_fixture(pool, %{
        correlation_id: "req-combined-issues",
        requested_model: "sample-model",
        upstream_model_id: "sample-model",
        served_model: "sample-alternative",
        status: "failed",
        response_status_code: 502,
        last_error_code: "stream_incomplete",
        network_error_code: "upstream_network_error",
        request_metadata: %{"retryable_summary" => %{"code" => "upstream_status"}},
        model_observation: %{"version" => 1, "coverage" => "full", "conflict" => true, "first_conflicting_model" => "sample-third-model", "terminal_status" => "failed"}
      })

    {:ok, view, _html} = live_request_logs(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")
    row = "#request-log-row-#{request.id}"
    issues = "#{row} > td:nth-child(5)[data-role='request-issues-cell']"

    for code <- ~w(stream_incomplete upstream_status upstream_network_error) do
      assert has_element?(view, "#{issues} [data-role='error-line']", code)
    end

    assert view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#{issues} [data-role='error-line'] .hero-exclamation-triangle.text-error") |> Enum.count() == 3

    assert has_element?(view, "#{issues} [data-role='served-model']", "Model mismatch: sample-alternative")
    assert has_element?(view, "#{issues} [data-role='model-declaration-conflict']", "model name changed · attempt 1")
    assert has_element?(view, "#{row} > td:nth-child(4) [data-role='route']", "/backend-api/codex/responses")
    assert has_element?(view, "#{row} > td:nth-child(6) [data-role='token-totals']", "3")
    assert has_element?(view, "#{row} [data-role='status-text']", "Failed")
    refute has_element?(view, "#{row}-errors")
    refute has_element?(view, "#{row} [data-role='model-details'] [data-role='model-declaration-conflict']")
    refute render(view) =~ @sensitive_marker

    view |> element(row) |> render_click()
    assert has_element?(view, "#request-log-detail-request-id", request.id)
    assert has_element?(view, "#request-log-detail-attempt-1-model-conflict", "Model name changed within response")
  end

  test "issues column follows the filtered rows, including warnings on successful requests", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, "conditional-request-issues")
    %{request: clean} = request_log_fixture(pool, %{correlation_id: "req-no-issues", upstream_model_id: "sample-model", served_model: "sample-model"})

    affected =
      for {name, issue} <- [
            {"retry", %{network_error_code: "upstream_network_error"}},
            {"mismatch", %{served_model: "sample-alternative"}},
            {"conflict", %{model_observation: %{"version" => 1, "coverage" => "full", "conflict" => true, "first_conflicting_model" => "sample-alternative", "terminal_status" => "completed"}}}
          ] do
        %{request: request} = request_log_fixture(pool, Map.merge(%{correlation_id: "req-issue-#{name}", upstream_model_id: "sample-model", served_model: "sample-model"}, issue))
        request
      end

    {:ok, view, _html} = live_request_logs(conn, ~p"/admin/request-logs?pool_id=#{pool.id}&request_id=#{clean.id}")
    refute has_element?(view, "#request-log-issues-heading")
    refute has_element?(view, ".request-log-issues-column")
    refute has_element?(view, "[data-role='request-issues-cell']")

    for request <- affected do
      view |> element("#request-log-filter-form") |> render_submit(%{"filters" => %{"pool_id" => pool.id, "request_id" => request.id}})
      _ = assert_patch(view)
      _ = await_request_logs(view)

      assert has_element?(view, ".admin-request-explorer[data-has-issues='true']")
      assert has_element?(view, "#request-log-issues-heading", "Errors · Warnings")
      assert has_element?(view, ".request-log-issues-column")
      assert has_element?(view, "#request-log-row-#{request.id} [data-role='request-issues']")
      assert has_element?(view, "#request-log-row-#{request.id} [data-role='status-text']", "Succeeded")
    end

    view |> element("#request-log-filter-form") |> render_submit(%{"filters" => %{"pool_id" => pool.id, "request_id" => clean.id}})
    _ = assert_patch(view)
    _ = await_request_logs(view)

    assert has_element?(view, ".admin-request-explorer[data-has-issues='false']")
    assert has_element?(view, "#request-log-row-#{clean.id} [data-role='cost']")
    refute has_element?(view, "#request-log-issues-heading")
    refute has_element?(view, ".request-log-issues-column")
    refute has_element?(view, "[data-role='request-issues-cell']")
  end

  @tag model_provenance: true
  test "historical public failure keeps its error but does not claim a different provider model", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, "projected-model-history")
    setup = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    request = request_fixture(setup, %{status: "failed", last_error_code: "invalid_request_error", response_status_code: 200})
    attempt_fixture(request, assignment, %{transport: "websocket", status: "failed", served_model: "unknown", network_error_code: "invalid_request_error", response_metadata: %{"upstream_websocket_bridge" => true, "public_openai_responses_stream" => %{"mode" => "normalized", "created_seen" => false, "visible_seen" => false, "delta_count" => 0, "terminal_seen" => true, "terminal_kind" => "failed"}}})
    {:ok, view, _} = live_request_logs(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")
    assert has_element?(view, "#request-log-row-#{request.id} [data-role=error-line]", "invalid_request_error")
    refute has_element?(view, "#request-log-#{request.id}-served-model")
    view |> element("#request-log-row-#{request.id}") |> render_click()
    assert has_element?(view, "#request-log-detail-attempt-1-model-first", "Unavailable")
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
        requested_model: Map.get(attrs, :requested_model, "gpt-6-astra"),
        endpoint: "/backend-api/codex/responses",
        status: Map.get(attrs, :status, "succeeded"),
        correlation_id: Map.fetch!(attrs, :correlation_id),
        transport: "websocket",
        request_metadata: Map.put(Map.get(attrs, :request_metadata, %{}), "prompt", @sensitive_marker),
        response_status_code: Map.get(attrs, :response_status_code, 200),
        last_error_code: Map.get(attrs, :last_error_code),
        usage_status: "usage_known"
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: Map.get(attrs, :status, "succeeded"),
        usage_status: "usage_known",
        upstream_status_code: Map.get(attrs, :response_status_code, 200),
        network_error_code: Map.get(attrs, :network_error_code),
        upstream_model_id: Map.fetch!(attrs, :upstream_model_id),
        served_model: Map.get(attrs, :served_model),
        model_observation: Map.get(attrs, :model_observation)
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
