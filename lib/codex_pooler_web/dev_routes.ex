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

  # Branch on the compile-time flag outside the function body, like the observer
  # routes below: `@dev_routes and ...` inside it compiles to a `case` on a literal,
  # and Dialyzer in the dev environment (flag `true`) reports its `false` clause.
  if @dev_routes do
    defp dashboard_routes do
      if Code.ensure_loaded?(Phoenix.LiveDashboard.Router) do
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
  else
    defp dashboard_routes, do: quote(do: :ok)
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

          forward "/native-compaction/trace", CodexPooler.Dev.NativeCompactionTrace.Plug

          forward "/native-compaction/preaccounting",
                  CodexPooler.Dev.NativeCompactionPreaccounting.Plug

          forward "/native-compaction/pre-attempt-drain",
                  CodexPooler.Dev.NativePreAttemptDrain.Plug
        end
      end
    end
  else
    defp observer_routes, do: quote(do: :ok)
  end
end
