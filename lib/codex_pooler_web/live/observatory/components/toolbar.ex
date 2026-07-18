defmodule CodexPoolerWeb.Observatory.Components.Toolbar do
  @moduledoc """
  Renders the API Key Observatory identity, window, freshness, and session controls.
  """

  use CodexPoolerWeb, :html

  attr :display_name, :string, required: true
  attr :selected_window, :string, values: ~w(1h 5h 24h 7d), required: true
  attr :freshness, :string, required: true
  attr :paused, :boolean, default: false

  def toolbar(assigns) do
    ~H"""
    <header
      id="observatory-toolbar"
      class="observatory-toolbar"
      aria-label="Observatory toolbar"
    >
      <div id="observatory-toolbar-identity" class="observatory-toolbar-identity">
        <div id="observatory-wordmark" class="observatory-wordmark">
          <span>Codex Pooler</span>
          <small>Observatory</small>
        </div>

        <span
          id="observatory-key-chip"
          class="observatory-key-chip"
          title="This dashboard is scoped to one API key"
          aria-label="Dashboard scoped to one API key"
        >
          <span class="observatory-key-icon" aria-hidden="true">
            <.icon name="hero-key" class="size-3" />
          </span>
          <span id="observatory-principal" class="min-w-0 truncate font-semibold">
            {@display_name}
          </span>
        </span>
      </div>

      <div
        id="observatory-toolbar-controls"
        class="observatory-toolbar-controls"
      >
        <div
          id="observatory-window-control"
          class="observatory-window-control"
          role="group"
          aria-label="Time window"
        >
          <button
            :for={{key, label} <- [{"1h", "1h"}, {"5h", "5h"}, {"24h", "24h"}, {"7d", "7d"}]}
            id={"observatory-window-#{key}"}
            type="button"
            class="observatory-window-button"
            phx-click="select-window"
            phx-value-window={key}
            aria-pressed={to_string(@selected_window == key)}
          >
            {label}
          </button>
        </div>

        <button
          :if={@paused}
          id="observatory-resume"
          type="button"
          class="btn btn-sm btn-ghost btn-square observatory-icon-button"
          data-observatory-refresh-action="resume"
          aria-label="Resume auto-refresh"
        >
          <.icon name="hero-play" class="size-4" />
        </button>
        <button
          :if={!@paused}
          id="observatory-pause"
          type="button"
          class="btn btn-sm btn-ghost btn-square observatory-icon-button"
          data-observatory-refresh-action="pause"
          aria-label="Pause auto-refresh"
        >
          <.icon name="hero-pause" class="size-4" />
        </button>

        <div
          id="observatory-theme-toggle"
          class="observatory-window-control observatory-theme-control"
          role="group"
          aria-label="Theme"
        >
          <button
            :for={
              {theme, icon, label} <- [
                {"system", "hero-computer-desktop-micro", "Match system theme"},
                {"light", "hero-sun-micro", "Light theme"},
                {"dark", "hero-moon-micro", "Dark theme"}
              ]
            }
            type="button"
            class="observatory-window-button observatory-theme-button"
            data-phx-theme={theme}
            phx-click={JS.dispatch("phx:set-theme")}
            aria-label={label}
            title={label}
          >
            <.icon name={icon} class="size-4" />
          </button>
        </div>
      </div>

      <div
        id="observatory-freshness"
        class={[
          "observatory-freshness",
          @paused && "is-paused"
        ]}
        aria-live="polite"
        aria-label={if @paused, do: "Refresh paused", else: "Refresh live"}
      >
        <span class="observatory-live-dot" aria-hidden="true" />
        <span data-role="observatory-freshness-label" class="text-base-content/70">
          {@freshness}
        </span>
        <span data-role="observatory-refresh-status" class="sr-only">
          {if @paused, do: "Paused", else: "Live"}
        </span>
        <form id="observatory-logout-form" action="/observatory/logout" method="post">
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button
            type="submit"
            class="btn btn-sm btn-ghost btn-square observatory-logout-button"
            aria-label="Log out"
            title="Log out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
          </button>
        </form>
      </div>
    </header>
    """
  end
end
