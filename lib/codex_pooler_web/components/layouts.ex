defmodule CodexPoolerWeb.Layouts do
  @moduledoc """
  Shared layouts for CodexPooler browser and admin surfaces.
  """
  use CodexPoolerWeb, :html

  @dev_features_build_enabled Application.compile_env(
                                :codex_pooler,
                                :dev_features_build_enabled,
                                false
                              )

  embed_templates "layouts/*"

  @doc """
  `chrome` selects the default, admin, or invite shell so each surface keeps its
  own framing without separate layout modules.
  """
  attr :flash, :map, required: true

  attr :current_scope, :map, default: nil

  attr :auth_surface, :boolean, default: false
  attr :chrome, :atom, default: :default, values: [:default, :admin, :invite]

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= cond do %>
      <% @chrome == :admin -> %>
        <main class="h-svh overflow-hidden bg-base-200 text-base-content">
          {render_slot(@inner_block)}
        </main>
      <% @chrome == :invite -> %>
        <main class="flex min-h-svh flex-col bg-base-200/40 text-base-content">
          <div class="flex-1">
            {render_slot(@inner_block)}
          </div>
          <.public_footer id="invite-footer" />
        </main>
      <% true -> %>
        <main class={[@auth_surface && "flex flex-col bg-base-200/40", "min-h-svh"]}>
          <div class={["mx-auto w-full max-w-5xl space-y-4", @auth_surface && "flex-1"]}>
            {render_slot(@inner_block)}
          </div>
          <.public_footer :if={@auth_surface} id="auth-footer" />
        </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true

  defp public_footer(assigns) do
    assigns = assign(assigns, :app_version, app_version())

    ~H"""
    <footer
      id={@id}
      class="footer footer-center flex flex-col items-center justify-center gap-2 border-t border-base-300/70 bg-base-100/90 px-4 py-4 text-xs text-base-content/65 sm:flex-row sm:gap-3"
    >
      <aside class="flex flex-col items-center gap-2 sm:flex-row sm:gap-3">
        <.link
          href="https://docs.codex-pooler.com"
          target="_blank"
          rel="noopener noreferrer"
          class="font-medium text-base-content/75 hover:text-base-content"
        >
          Codex Pooler {@app_version}
        </.link>
        <span
          class="hidden h-1 w-1 rounded-full bg-base-content/30 sm:inline-block"
          aria-hidden="true"
        />
        <span>&copy; {copyright_year()} iCoreTech, Inc.</span>
      </aside>
      <.link
        href="https://github.com/icoretech/codex-pooler"
        target="_blank"
        rel="noopener noreferrer"
        aria-label="Codex Pooler on GitHub"
        class="btn btn-ghost btn-circle btn-sm text-base-content/65 hover:text-base-content"
      >
        <svg viewBox="0 0 24 24" aria-hidden="true" class="size-4 fill-current">
          <path d="M12 2C6.48 2 2 6.58 2 12.26c0 4.54 2.87 8.39 6.84 9.75.5.09.68-.22.68-.49 0-.24-.01-1.04-.01-1.89-2.78.62-3.37-1.22-3.37-1.22-.46-1.19-1.12-1.5-1.12-1.5-.91-.64.07-.63.07-.63 1.01.07 1.54 1.06 1.54 1.06.89 1.57 2.34 1.12 2.91.86.09-.67.35-1.12.64-1.38-2.22-.26-4.56-1.14-4.56-5.07 0-1.12.39-2.03 1.03-2.75-.1-.26-.45-1.3.1-2.71 0 0 .84-.28 2.75 1.05A9.35 9.35 0 0 1 12 7c.85 0 1.71.12 2.51.34 1.91-1.33 2.75-1.05 2.75-1.05.55 1.41.2 2.45.1 2.71.64.72 1.03 1.63 1.03 2.75 0 3.94-2.34 4.81-4.57 5.06.36.32.68.94.68 1.9 0 1.37-.01 2.47-.01 2.81 0 .27.18.59.69.49A10.13 10.13 0 0 0 22 12.26C22 6.58 17.52 2 12 2Z" />
        </svg>
      </.link>
    </footer>
    """
  end

  defp app_version, do: :codex_pooler |> Application.spec(:vsn) |> to_string()

  defp copyright_year, do: Date.utc_today().year

  if @dev_features_build_enabled do
    defp impeccable_live_script(assigns) do
      ~H"""
      <script
        :if={CodexPoolerWeb.DevFeatures.impeccable_live_enabled?()}
        src={CodexPoolerWeb.DevFeatures.impeccable_live_script_src()}
      >
      </script>
      """
    end
  else
    defp impeccable_live_script(assigns) do
      ~H"""
      """
    end
  end

  attr :id, :string, required: true
  attr :class, :any, default: nil

  def public_logo(assigns) do
    ~H"""
    <div id={@id} class={["inline-flex items-center", @class]}>
      <span class="text-sm font-black leading-none text-primary uppercase sm:text-base">
        CODEX POOLER
      </span>
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="toast toast-top toast-end z-50">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Root HTML applies the persisted theme before page load; this control only
  dispatches the runtime theme change.
  """
  attr :id, :string, default: nil

  attr :class, :any,
    default:
      "card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"

  def theme_toggle(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex h-full w-1/3 cursor-pointer items-center justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex h-full w-1/3 cursor-pointer items-center justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex h-full w-1/3 cursor-pointer items-center justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
