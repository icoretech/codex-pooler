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
        <.github_icon class="size-4 fill-current" />
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
