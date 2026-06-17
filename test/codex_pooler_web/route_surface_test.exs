defmodule CodexPoolerWeb.RouteSurfaceTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.ControlPlaneRoutes

  test "router exposes only the documented Phoenix-native application surface" do
    routes = Phoenix.Router.routes(CodexPoolerWeb.Router)

    application_routes =
      routes
      |> Enum.reject(
        &(String.starts_with?(&1.path, "/dev") or String.starts_with?(&1.path, "/live"))
      )
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.sort()

    assert application_routes ==
             [
               {:delete, "/logout"},
               {:delete, "/mcp"},
               {:delete, "/v1/files/:file_id"},
               {:delete, "/v1/responses/:response_id"},
               {:get, "/"},
               {:get, "/admin/alerts"},
               {:get, "/admin/api-keys"},
               {:get, "/admin/audit-logs"},
               {:get, "/admin/invites"},
               {:get, "/admin/jobs"},
               {:get, "/admin/operators"},
               {:get, "/admin/pools"},
               {:get, "/admin/request-logs"},
               {:get, "/admin/settings"},
               {:get, "/admin/stats"},
               {:get, "/admin/system"},
               {:get, "/admin/upstreams"},
               {:get, "/admin/upstreams/:id"},
               {:get, "/api/codex/usage"},
               {:get, "/backend-api/codex/agent-identities/jwks"},
               {:get, "/backend-api/codex/models"},
               {:get, "/backend-api/codex/responses"},
               {:get, "/backend-api/codex/thread/goal/get"},
               {:get, "/backend-api/codex/v1/models"},
               {:get, "/backend-api/codex/v1/responses"},
               {:get, "/backend-api/wham/agent-identities/jwks"},
               {:get, "/backend-api/wham/usage"},
               {:get, "/bootstrap"},
               {:get, "/bootstrap/status"},
               {:get, "/healthz"},
               {:get, "/login"},
               {:get, "/mcp"},
               {:get, "/metrics"},
               {:get, "/onboarding/invites/:invite_token"},
               {:get, "/password/change-required"},
               {:get, "/readyz"},
               {:get, "/session"},
               {:get, "/v1/files"},
               {:get, "/v1/files/:file_id"},
               {:get, "/v1/files/:file_id/content"},
               {:get, "/v1/models"},
               {:get, "/v1/responses"},
               {:get, "/v1/responses/:response_id"},
               {:get, "/v1/usage"},
               {:get, "/wham/usage"},
               {:options, "/mcp"},
               {:post, "/backend-api/codex/alpha/search"},
               {:post, "/backend-api/codex/analytics-events/events"},
               {:post, "/backend-api/codex/images/edits"},
               {:post, "/backend-api/codex/images/generations"},
               {:post, "/backend-api/codex/memories/trace_summarize"},
               {:post, "/backend-api/codex/realtime/calls"},
               {:post, "/backend-api/codex/responses"},
               {:post, "/backend-api/codex/responses/compact"},
               {:post, "/backend-api/codex/safety/arc"},
               {:post, "/backend-api/codex/thread/goal/clear"},
               {:post, "/backend-api/codex/thread/goal/get"},
               {:post, "/backend-api/codex/thread/goal/set"},
               {:post, "/backend-api/codex/v1/chat/completions"},
               {:post, "/backend-api/codex/v1/responses"},
               {:post, "/backend-api/codex/v1/responses/compact"},
               {:post, "/backend-api/files"},
               {:post, "/backend-api/files/:file_id/uploaded"},
               {:post, "/backend-api/transcribe"},
               {:post, "/bootstrap"},
               {:post, "/login"},
               {:post, "/mcp"},
               {:post, "/settings/password"},
               {:post, "/v1/audio/transcriptions"},
               {:post, "/v1/batches"},
               {:post, "/v1/chat/completions"},
               {:post, "/v1/embeddings"},
               {:post, "/v1/files"},
               {:post, "/v1/fine_tuning/jobs"},
               {:post, "/v1/images/edits"},
               {:post, "/v1/images/generations"},
               {:post, "/v1/images/variations"},
               {:post, "/v1/moderations"},
               {:post, "/v1/responses"},
               {:post, "/v1/responses/:response_id/cancel"},
               {:post, "/v1/responses/compact"}
             ]

    for path <- [
          "/api/codex/rate-limit-reset-credits/consume",
          "/wham/rate-limit-reset-credits/consume",
          "/backend-api/wham/rate-limit-reset-credits/consume"
        ] do
      refute {:post, path} in application_routes
    end

    refute Enum.any?(application_routes, fn {_verb, path} ->
             String.starts_with?(path, "/api/admin") or String.starts_with?(path, "/dashboard")
           end)
  end

  test "Alerts admin route stays inside the authenticated admin LiveView surface" do
    routes =
      CodexPoolerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path, &1.plug, &1.plug_opts})

    assert {:get, "/admin/alerts", Phoenix.LiveView.Plug, :index} =
             Enum.find(routes, fn {verb, path, _plug, _opts} ->
               verb == :get and path == "/admin/alerts"
             end)

    refute Enum.any?(routes, fn {_verb, path, _plug, _opts} ->
             path in ["/api/admin/alerts", "/dashboard/alerts"]
           end)
  end

  test "MCP route is a direct root protocol endpoint outside runtime and browser auth scopes" do
    routes =
      CodexPoolerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path, &1.plug, &1.plug_opts})

    assert {:post, "/mcp", CodexPoolerWeb.McpController, :post} in routes
    assert {:get, "/mcp", CodexPoolerWeb.McpController, :get} in routes
    assert {:delete, "/mcp", CodexPoolerWeb.McpController, :delete} in routes
    assert {:options, "/mcp", CodexPoolerWeb.McpController, :options} in routes

    refute Enum.any?(routes, fn {_verb, path, _plug, _opts} ->
             String.starts_with?(path, "/backend-api/mcp") or path == "/v1/mcp"
           end)
  end

  test "control-plane route contract is explicit and has no wildcard proxy route" do
    routes =
      CodexPoolerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path})

    route_set = MapSet.new(routes)

    for route <- control_plane_routes() do
      assert MapSet.member?(route_set, route),
             "expected explicit control-plane route #{inspect(route)}"
    end

    refute MapSet.member?(route_set, {:post, "/backend-api/codex/not-added"})
    refute MapSet.member?(route_set, {:get, "/backend-api/codex/not-added"})

    refute Enum.any?(routes, fn {_verb, path} ->
             String.contains?(path, "*") or
               (String.starts_with?(path, "/backend-api/codex/") and String.contains?(path, ":"))
           end)
  end

  defp control_plane_routes do
    Enum.map(ControlPlaneRoutes.all(), &{&1.method, &1.local_path})
  end

  test "GET /status falls through to the standard 404 response for anonymous users" do
    conn = get(build_conn(), "/status")

    assert html_response(conn, 404) =~ "Not Found"
  end

  test "OpenAI-compatible /v1 route contract is authenticated and explicitly enumerated" do
    supported_routes = [
      {:get, "/v1/models"},
      {:post, "/v1/responses"},
      {:post, "/v1/responses/compact"},
      {:post, "/v1/chat/completions"},
      {:get, "/v1/usage"},
      {:get, "/v1/files"},
      {:post, "/v1/files"},
      {:get, "/v1/files/:file_id"},
      {:get, "/v1/files/:file_id/content"},
      {:delete, "/v1/files/:file_id"},
      {:get, "/v1/responses"},
      {:post, "/v1/audio/transcriptions"},
      {:post, "/v1/images/generations"},
      {:post, "/v1/images/edits"}
    ]

    unsupported_routes = [
      {:post, "/v1/images/variations"},
      {:post, "/v1/embeddings"},
      {:post, "/v1/batches"},
      {:post, "/v1/moderations"},
      {:post, "/v1/fine_tuning/jobs"},
      {:get, "/v1/responses/:response_id"},
      {:post, "/v1/responses/:response_id/cancel"},
      {:delete, "/v1/responses/:response_id"}
    ]

    route_set =
      CodexPoolerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    for route <- supported_routes ++ unsupported_routes do
      assert MapSet.member?(route_set, route),
             "expected routed /v1 contract for #{inspect(route)}"
    end

    refute MapSet.member?(route_set, {:get, "/v1/realtime"})
    refute MapSet.member?(route_set, {:post, "/v1/realtime"})
  end

  test "GET /status falls through to the standard 404 response for authenticated users" do
    %{user: user, token: token} = bootstrap_owner_fixture()

    conn = build_conn() |> log_in_user(user, token)
    conn = get(conn, "/status")

    assert html_response(conn, 404) =~ "Not Found"
  end

  test "invite browser callback route is absent and fails closed" do
    conn = get(build_conn(), "/api/onboarding/invites/example-token/browser/callback")

    assert html_response(conn, 404) =~ "Not Found"
  end

  test "OpenAI OAuth upstream linking has no hosted callback or admin JSON route" do
    routes =
      CodexPoolerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path, &1.plug, &1.plug_opts})

    route_set =
      routes
      |> Enum.map(fn {verb, path, _plug, _opts} -> {verb, path} end)
      |> MapSet.new()

    assert {:get, "/admin/upstreams"} in route_set
    assert {:get, "/admin/upstreams/:id"} in route_set

    for {_verb, path, _plug, _opts} <- routes do
      refute path in [
               "/auth/callback",
               "/oauth/callback",
               "/admin/upstreams/oauth/callback",
               "/api/admin/upstreams/oauth/callback"
             ]

      refute String.starts_with?(path, "/api/admin")
      refute String.starts_with?(path, "/dashboard")
    end

    assert html_response(
             get(build_conn(), "/auth/callback?state=example-state&code=example-code"),
             404
           ) =~ "Not Found"
  end

  test "operator docs document OpenAI OAuth linking without a hosted callback route" do
    operator_docs = File.read!("docs-site/src/content/docs/operators/upstreams.mdx")

    assert operator_docs =~ "OpenAI OAuth upstream linking"
    assert operator_docs =~ "manual callback workflow"
    assert operator_docs =~ "device-code fallback"
    assert operator_docs =~ "there is no hosted OAuth callback route"
    assert operator_docs =~ "Safe OAuth troubleshooting codes"
    assert operator_docs =~ "never paste callback URLs, authorization codes, tokens, cookies"
  end
end
