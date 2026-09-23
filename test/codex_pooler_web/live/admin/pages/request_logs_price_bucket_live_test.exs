defmodule CodexPoolerWeb.Admin.RequestLogsPriceBucketLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  # Failure-detection budget for an asynchronous load the test awaits: a green
  # run returns as soon as the view has settled.
  @detection_timeout_ms 15_000

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Pools

  setup :register_and_log_in_user

  # Pricing resolution falls back to the default bucket when a long-context
  # turn has no long-context snapshot (findings#236 item 1). The settled
  # bucket alone reads `default`, exactly like an ordinary turn, so the
  # substitution is what an operator needs on the row.
  @long_context_fallback %{
    "status" => "priced",
    "price_bucket" => "default",
    "price_bucket_fallback" => %{
      "requested" => "long_context",
      "selected" => "default",
      "reason" => "long_context_pricing_absent"
    }
  }

  @sensitive_marker "price-bucket-log-prompt-must-not-render"

  test "the drawer names the requested bucket only when another one was priced", %{
    conn: conn,
    scope: scope
  } do
    pool = create_pool!(scope, "price-bucket-drawer")

    %{request: substituted} =
      request_log_fixture(pool, %{
        correlation_id: "req-bucket-substituted",
        pricing_metadata: @long_context_fallback
      })

    %{request: honored} =
      request_log_fixture(pool, %{
        correlation_id: "req-bucket-honored",
        pricing_metadata: %{"status" => "priced", "price_bucket" => "long_context"}
      })

    %{request: no_pricing} =
      request_log_fixture(pool, %{correlation_id: "req-bucket-none", pricing_metadata: nil})

    view = open_selected_request(conn, pool, substituted)
    assert has_element?(view, "#request-log-detail-price-bucket", "Price bucket")
    assert has_element?(view, "#request-log-detail-price-bucket", "default (long_context requested)")
    refute render(view) =~ @sensitive_marker

    # A bucket that was honored is not a substitution, and neither is a turn
    # that never reached pricing resolution.
    for request <- [honored, no_pricing] do
      view = open_selected_request(conn, pool, request)
      refute has_element?(view, "#request-log-detail-price-bucket")
    end
  end

  defp create_pool!(scope, slug) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: slug, name: slug})
    pool
  end

  defp request_log_fixture(pool, attrs) do
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Price bucket log key"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Price bucket upstream",
        assignment_label: "Price bucket assignment"
      })

    request_metadata =
      case Map.fetch!(attrs, :pricing_metadata) do
        nil -> %{"prompt" => @sensitive_marker}
        pricing -> %{"prompt" => @sensitive_marker, "pricing" => pricing}
      end

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-price-bucket-log",
        endpoint: "/backend-api/codex/responses",
        status: "succeeded",
        correlation_id: Map.fetch!(attrs, :correlation_id),
        transport: "http_sse",
        request_metadata: request_metadata,
        response_status_code: 200,
        usage_status: "usage_known"
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
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "40"}
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
