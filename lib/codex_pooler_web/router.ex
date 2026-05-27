defmodule CodexPoolerWeb.Router do
  use CodexPoolerWeb, :router

  alias CodexPooler.ControlPlaneRoutes
  import CodexPoolerWeb.UserAuth
  alias CodexPoolerWeb.V1.UnsupportedRoutes
  require CodexPoolerWeb.DevRoutes

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CodexPoolerWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{}

    plug :fetch_current_scope_for_user
    plug CodexPoolerWeb.Plugs.AdminBrowserAdmission
  end

  pipeline :api do
    plug :accepts, ["json", "event-stream"]
  end

  pipeline :binary_accept_json do
    plug CodexPoolerWeb.Plugs.BinaryAcceptJson
  end

  scope "/", CodexPoolerWeb do
    pipe_through :api

    get "/mcp", McpController, :get
    post "/mcp", McpController, :post
    delete "/mcp", McpController, :delete
    options "/mcp", McpController, :options
  end

  scope "/", CodexPoolerWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :current_user,
      on_mount: [{CodexPoolerWeb.UserAuth, :mount_current_scope}] do
      live "/bootstrap", AuthLive.Bootstrap, :new
      live "/login", AuthLive.Login, :new
      live "/onboarding/invites/:invite_token", OnboardingLive.Invite, :show
    end

    post "/bootstrap", UserSessionController, :bootstrap
    post "/login", UserSessionController, :create
    delete "/logout", UserSessionController, :delete

    get "/bootstrap/status", UserSessionController, :bootstrap_status
    get "/session", UserSessionController, :session
  end

  scope "/", CodexPoolerWeb do
    pipe_through :api

    get "/healthz", Operations.HealthController, :health
    get "/readyz", Operations.HealthController, :readiness
    get "/metrics", Operations.MetricsController, :show
    get "/api/codex/usage", Runtime.CodexUsageController, :show
    get "/wham/usage", Runtime.CodexUsageController, :show
  end

  scope "/backend-api/codex", CodexPoolerWeb do
    pipe_through :api

    get "/models", Runtime.BackendCodexController, :models
    get "/v1/models", Runtime.BackendCodexController, :v1_models
    post "/images/generations", Runtime.BackendCodexController, :image_generations
    post "/images/edits", Runtime.BackendCodexController, :image_edits
    post "/responses", Runtime.BackendCodexController, :responses
    post "/v1/responses", Runtime.BackendCodexController, :v1_responses
    post "/responses/compact", Runtime.BackendCodexController, :compact_responses
    post "/v1/responses/compact", Runtime.BackendCodexController, :v1_compact_responses
    post "/v1/chat/completions", Runtime.BackendCodexController, :v1_chat_completions
    get "/responses", Runtime.BackendCodexController, :responses_stream
    get "/v1/responses", Runtime.BackendCodexController, :responses_stream

    for %{method: method, local_path: "/backend-api/codex" <> path, action: action} <-
          ControlPlaneRoutes.all() do
      match method, path, Runtime.BackendCodexController, action
    end
  end

  scope "/backend-api", CodexPoolerWeb do
    pipe_through :api

    post "/transcribe", Runtime.BackendCodexController, :transcribe
    post "/files", Runtime.BackendFileController, :create
    post "/files/:file_id/uploaded", Runtime.BackendFileController, :uploaded
    get "/wham/usage", Runtime.CodexUsageController, :show

    for %{
          method: method,
          local_path: "/backend-api" <> path,
          action: action
        } <- ControlPlaneRoutes.all(),
        String.starts_with?(path, "/wham/") do
      match method, path, Runtime.BackendCodexController, action
    end
  end

  scope "/v1", CodexPoolerWeb do
    pipe_through :api

    get "/models", V1.ModelsController, :index
    post "/responses", V1.ResponsesController, :create
    post "/responses/compact", V1.ResponsesController, :compact
    post "/chat/completions", V1.ChatCompletionsController, :create
    get "/usage", V1.UsageController, :index

    get "/files", V1.FilesController, :index
    post "/files", V1.FilesController, :create
    get "/files/:file_id", V1.FilesController, :show
    delete "/files/:file_id", V1.FilesController, :delete

    post "/audio/transcriptions", V1.AudioController, :transcriptions
    post "/images/generations", V1.ImagesController, :generations
    post "/images/edits", V1.ImagesController, :edits

    for {method, path, action} <- UnsupportedRoutes.router_routes() do
      match method, path, V1.UnsupportedController, action
    end
  end

  scope "/v1", CodexPoolerWeb do
    pipe_through [:binary_accept_json, :api]

    get "/files/:file_id/content", V1.FilesController, :content
  end

  scope "/", CodexPoolerWeb do
    pipe_through [:browser, :require_authenticated_user]

    post "/settings/password", UserSessionController, :change_password

    live_session :require_authenticated_user,
      on_mount: [{CodexPoolerWeb.UserAuth, :require_authenticated}] do
      live "/password/change-required", AuthLive.ForcePasswordChange, :edit
    end

    live_session :require_authenticated_password_current,
      on_mount: [{CodexPoolerWeb.UserAuth, :require_authenticated_password_current}] do
      live "/admin/operators", Admin.OperatorsLive, :index
      live "/admin/request-logs", Admin.RequestLogsLive, :index
      live "/admin/pools", Admin.PoolsLive, :index
      live "/admin/stats", Admin.StatsLive, :index
      live "/admin/jobs", Admin.JobsLive, :index
      live "/admin/system", Admin.SystemLive, :index
      live "/admin/upstreams", Admin.UpstreamsLive, :index
      live "/admin/api-keys", Admin.ApiKeysLive, :index
      live "/admin/invites", Admin.InvitesLive, :index
      live "/admin/audit-logs", Admin.AuditLogsLive, :index
      live "/admin/settings", Admin.SettingsLive, :index
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development.
  CodexPoolerWeb.DevRoutes.live_dashboard_routes()

  defp put_secure_browser_headers(conn, _baseline_headers) do
    Phoenix.Controller.put_secure_browser_headers(
      conn,
      CodexPoolerWeb.BrowserSecurity.secure_headers()
    )
  end
end
