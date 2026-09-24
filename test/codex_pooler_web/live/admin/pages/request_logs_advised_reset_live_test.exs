defmodule CodexPoolerWeb.Admin.RequestLogsAdvisedResetLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  # A terminal usage-limit refusal records the reset it advised the client
  # (findings#206 row 206-553): a routed refusal in `gateway_denial`, a
  # relayed provider `429` in the attempt's `response_metadata.usage_limit`.
  # The list's failure line and the drawer show that advice with one rendering
  # for both (row 206-577), and a routed refusal's advice wins over an
  # exclusion's own window reset.

  # Failure-detection budget for an asynchronous load the test awaits: a green
  # run returns as soon as the view has settled.
  @detection_timeout_ms 15_000

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Pools

  setup :register_and_log_in_user

  @sensitive_marker "advised-reset-log-prompt-must-not-render"
  @advised ~U[2026-05-11 02:55:14Z]
  @advised_text "2026-05-11 02:55:14 UTC"

  test "a relayed provider usage-limit 429 shows the reset it advised in the list and the drawer", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, "advised-reset-relayed")

    %{request: request} =
      request_log_fixture(pool, "req-advised-relayed",
        request: %{status: "failed", last_error_code: "upstream_rate_limited", response_status_code: 429},
        attempt: %{
          status: "failed",
          upstream_status_code: 429,
          network_error_code: "upstream_rate_limited",
          response_metadata: %{"usage_limit" => %{"resets_at" => DateTime.to_unix(@advised), "resets_in_seconds" => 3_600}}
        }
      )

    view = open_selected_request(conn, pool, request)

    assert has_element?(view, "#request-log-#{request.id}-errors", "upstream_rate_limited")
    assert has_element?(view, "#request-log-#{request.id}-errors", "resets #{@advised_text}")
    assert has_element?(view, "#request-log-detail-advised-reset", "Advised retry")
    assert has_element?(view, "#request-log-detail-advised-reset", @advised_text)
    assert has_element?(view, "#request-log-detail-advised-reset", "Retry-After 3600 s")
    refute render(view) =~ @sensitive_marker
  end

  test "a routed refusal shows its advised reset ahead of an exclusion's window reset", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, "advised-reset-routed")

    %{request: request} =
      request_log_fixture(pool, "req-advised-routed",
        request: %{
          status: "rejected",
          last_error_code: "quota_exhausted",
          response_status_code: 429,
          usage_status: "not_applicable",
          request_metadata: %{
            "prompt" => @sensitive_marker,
            "gateway_denial" => %{
              "code" => "quota_exhausted",
              "message" => "upstream quota is exhausted until its reset time",
              "resets_at" => DateTime.to_unix(@advised),
              "resets_in_seconds" => 900
            },
            "candidate_exclusions" => [
              %{"reasons" => [%{"code" => "quota_window_unusable", "reason_codes" => ["exhausted"], "reset_at" => "2026-05-12T09:00:00Z"}]}
            ]
          }
        },
        attempt: nil
      )

    view = open_selected_request(conn, pool, request)

    assert has_element?(view, "#request-log-#{request.id}-errors", "quota exhausted")
    assert has_element?(view, "#request-log-#{request.id}-errors", "resets #{@advised_text}")
    refute has_element?(view, "#request-log-#{request.id}-errors", "2026-05-12")
    assert has_element?(view, "#request-log-detail-advised-reset", @advised_text)
    assert has_element?(view, "#request-log-detail-advised-reset", "Retry-After 900 s")
    refute render(view) =~ @sensitive_marker
  end

  test "a refusal that advised nothing has no advised reset row", %{conn: conn, scope: scope} do
    pool = create_pool!(scope, "advised-reset-none")

    %{request: request} =
      request_log_fixture(pool, "req-advised-none",
        request: %{status: "failed", last_error_code: "upstream_rate_limited", response_status_code: 429},
        attempt: %{status: "failed", upstream_status_code: 429, network_error_code: "upstream_rate_limited"}
      )

    view = open_selected_request(conn, pool, request)

    assert has_element?(view, "#request-log-#{request.id}-errors", "upstream_rate_limited")
    refute has_element?(view, "#request-log-#{request.id}-errors", "resets")
    refute has_element?(view, "#request-log-detail-advised-reset")
  end

  defp create_pool!(scope, slug) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: slug, name: slug})
    pool
  end

  defp request_log_fixture(pool, correlation_id, opts) do
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Advised reset log key"})
    %{assignment: assignment} = upstream_assignment_fixture(pool, %{account_label: "Advised reset upstream", assignment_label: "Advised reset assignment"})

    request =
      request_fixture(
        %{pool: pool, api_key: api_key},
        Map.merge(
          %{
            requested_model: "gpt-6-luna",
            endpoint: "/backend-api/codex/responses",
            correlation_id: correlation_id,
            transport: "http_sse",
            usage_status: "usage_unknown",
            request_metadata: %{"prompt" => @sensitive_marker}
          },
          Keyword.fetch!(opts, :request)
        )
      )

    case Keyword.fetch!(opts, :attempt) do
      nil -> :ok
      attempt_attrs -> attempt_fixture(request, assignment, Map.put(attempt_attrs, :usage_status, "usage_unknown"))
    end

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
