defmodule CodexPoolerWeb.DevRoutes do
  @moduledoc false

  @dev_routes Application.compile_env(:codex_pooler, :dev_routes, false)

  if @dev_routes do
    defmacro live_dashboard_routes do
      quote do
        import Phoenix.LiveDashboard.Router

        scope "/dev" do
          pipe_through :browser

          live_dashboard "/dashboard", metrics: CodexPoolerWeb.Telemetry
          live "/component-showcase/:theme", CodexPoolerWeb.Dev.ComponentShowcaseLive, :index
          forward "/mailbox", Plug.Swoosh.MailboxPreview
        end

        # Loopback JSON surface, deliberately outside the browser pipeline:
        # the Task 10 observer is armed via POST and must not require CSRF.
        scope "/dev" do
          forward "/task10/egress-capture", CodexPooler.Dev.Task10EgressObserver.Plug
          forward "/task14/product-capture", CodexPooler.Dev.Task14ProductObserver.Plug
        end
      end
    end
  else
    defmacro live_dashboard_routes do
      quote(do: :ok)
    end
  end
end
