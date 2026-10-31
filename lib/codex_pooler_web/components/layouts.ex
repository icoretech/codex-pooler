defmodule CodexPoolerWeb.Layouts do
  @moduledoc """
  Shared layouts for CodexPooler browser and admin surfaces.
  """
  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Components.LanguageSwitcher, only: [language_switcher: 1]

  @dev_features_build_enabled Application.compile_env(
                                :codex_pooler,
                                :dev_features_build_enabled,
                                false
                              )

  embed_templates "layouts/*"

  @spec live_title_suffix(String.t() | nil) :: String.t()
  defp live_title_suffix(title) when title in [nil, "", "Codex Pooler"], do: ""
  defp live_title_suffix(_title), do: " - Codex Pooler"

  @doc """
  `chrome` selects the default, admin, or invite shell so each surface keeps its
  own framing without separate layout modules.
  """
  attr :flash, :map, required: true

  attr :current_scope, :map, default: nil

  attr :auth_surface, :boolean, default: false
  attr :chrome, :atom, default: :default, values: [:default, :admin, :invite, :observatory]
  attr :locale, :map, default: nil
  attr :locale_preference, :string, default: nil

  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
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
          <.public_footer id="invite-footer" locale={@locale} locale_preference={@locale_preference} />
        </main>
      <% @chrome == :observatory -> %>
        <main
          id="observatory-shell"
          class="min-h-svh overflow-x-clip bg-base-200/40 text-base-content"
        >
          <div class="observatory-shell-content mx-auto w-full min-w-0">
            {render_slot(@inner_block)}
          </div>
        </main>
      <% true -> %>
        <main class={[@auth_surface && "flex flex-col bg-base-200/40", "min-h-svh"]}>
          <div class={["mx-auto w-full max-w-5xl space-y-4", @auth_surface && "flex-1"]}>
            {render_slot(@inner_block)}
          </div>
          <.public_footer id="auth-footer" locale={@locale} locale_preference={@locale_preference} />
        </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true
  attr :locale, :map, default: nil
  attr :locale_preference, :string, default: nil

  defp public_footer(assigns) do
    assigns = assign(assigns, :app_version, app_version())

    ~H"""
    <footer
      id={@id}
      class="flex items-center justify-between gap-3 border-t border-base-300/70 bg-base-100/90 px-4 py-2 text-xs text-base-content/65 sm:justify-center sm:py-4"
    >
      <aside class="flex min-w-0 items-center gap-2 whitespace-nowrap sm:gap-3">
        <.link
          href="https://www.codex-pooler.com/"
          target="_blank"
          rel="noopener noreferrer"
          class="font-medium text-base-content/75 hover:text-base-content"
        >
          <span class="sr-only sm:not-sr-only">Codex Pooler {@app_version}</span><span class="sm:hidden" aria-hidden="true">v{@app_version}</span>
        </.link>
        <span
          class="h-1 w-1 shrink-0 rounded-full bg-base-content/30"
          aria-hidden="true"
        />
        <span>&copy; {copyright_year()} iCoreTech<span class="sr-only sm:not-sr-only">, Inc.</span></span>
      </aside>
      <div class="flex shrink-0 items-center gap-1 sm:gap-3">
        <.link
          href="https://github.com/icoretech/codex-pooler"
          target="_blank"
          rel="noopener noreferrer"
          aria-label={gettext("Codex Pooler on GitHub")}
          class="btn btn-ghost btn-circle btn-sm text-base-content/65 hover:text-base-content"
        >
          <.github_icon class="size-4 fill-current" />
        </.link>
        <.language_switcher id={@id <> "-language-switcher"} locale={@locale} preference={@locale_preference} placement="top" variant="footer" />
      </div>
    </footer>
    """
  end

  defp app_version, do: :codex_pooler |> Application.spec(:vsn) |> to_string()

  defp copyright_year, do: Date.utc_today().year

  if @dev_features_build_enabled do
    defp impeccable_live_script(assigns) do
      # The src carries the running helper's port and session token, so it is
      # resolved per render rather than baked in; nil means "render nothing"
      # (toggle off, no helper, or the injector already owns the document).
      assigns = assign(assigns, :src, CodexPoolerWeb.DevFeatures.impeccable_live_script_src())

      ~H"""
      <script :if={@src} src={@src}>
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
    <%!-- Below `sm` the stack sits at the bottom so it clears the top header and the page connection notices; a bottom-sheet dialog (z 999) would hide it there, so while one is open it goes back to the top. From `sm` it sits at the top as before. --%>
    <div id={@id} aria-live="polite" class="toast toast-end z-50 sm:toast-top max-sm:[body:has(dialog[open])_&]:top-4 max-sm:[body:has(dialog[open])_&]:bottom-auto">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
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
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
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

  attr :class, :any, default: "card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"

  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_toggle(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex h-full w-1/3 cursor-pointer items-center justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("System theme")}
        title={gettext("System theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex h-full w-1/3 cursor-pointer items-center justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Light theme")}
        title={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex h-full w-1/3 cursor-pointer items-center justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Dark theme")}
        title={gettext("Dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
