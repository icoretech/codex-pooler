defmodule CodexPoolerWeb do
  @moduledoc """
  Shared Phoenix macro surface for codex-pooler web modules.

  Keep these quoted blocks limited to framework setup, verified routes,
  translations, and the small set of imports every matching module needs.
  Product behavior belongs in controllers, LiveViews, components, or contexts.
  """

  @static_paths ~w(
    assets
    fonts
    images
    favicon.ico
    favicon-16x16.png
    favicon-32x32.png
    apple-touch-icon.png
    icon-192.png
    icon-512.png
    site.webmanifest
    robots.txt
  )
  @digested_static_path_prefixes ~w(apple-touch-icon favicon icon- robots site)

  def static_paths, do: @static_paths
  def digested_static_path_prefixes, do: @digested_static_path_prefixes

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller, except: [put_secure_browser_headers: 2]
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: CodexPoolerWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def admin_live_view do
    quote do
      use Phoenix.LiveView

      on_mount CodexPoolerWeb.Live.AdminNotificationCenterHooks

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: CodexPoolerWeb.Gettext

      import Phoenix.HTML
      import CodexPoolerWeb.CoreComponents

      alias CodexPoolerWeb.Layouts
      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: CodexPoolerWeb.Endpoint,
        router: CodexPoolerWeb.Router,
        statics: CodexPoolerWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
