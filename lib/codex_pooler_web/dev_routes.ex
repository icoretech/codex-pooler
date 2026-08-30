defmodule CodexPoolerWeb.DevRoutes do
  @moduledoc false

  @dev_routes Application.compile_env(:codex_pooler, :dev_routes, false)
  @observer_routes Application.compile_env(:codex_pooler, :dev_features_build_enabled, false)

  defmacro live_dashboard_routes do
    quote do
      unquote(dashboard_routes())
      unquote(observer_routes())
    end
  end

  defp dashboard_routes do
    if @dev_routes and Code.ensure_loaded?(Phoenix.LiveDashboard.Router) do
      quote do
        import Phoenix.LiveDashboard.Router

        scope "/dev" do
          pipe_through :browser

          live_dashboard "/dashboard", metrics: CodexPoolerWeb.Telemetry
          live "/component-showcase/:theme", CodexPoolerWeb.Dev.ComponentShowcaseLive, :index
          forward "/mailbox", Plug.Swoosh.MailboxPreview
        end
      end
    else
      quote(do: :ok)
    end
  end

  if @observer_routes do
    defp observer_routes do
      quote do
        # Loopback JSON surface, deliberately outside the browser pipeline:
        # Development observers are armed via POST and must not require CSRF.
        scope "/dev" do
          forward "/permanent-full-mode/egress-capture",
                  CodexPooler.Dev.PermanentFullModeEgressObserver.Plug

          forward "/multi-agent-round/product-capture",
                  CodexPooler.Dev.MultiAgentRoundProductObserver.Plug

          forward "/native-compaction/authorization-capture",
                  CodexPooler.Dev.NativeCompactionAuthorizationObserver.Plug
        end
      end
    end
  else
    defp observer_routes, do: quote(do: :ok)
  end
end
