defmodule CodexPoolerWeb.Components.LanguageSwitcher do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Locale

  attr :locale, :map, default: nil
  attr :preference, :string, default: nil
  attr :id, :string, required: true
  attr :align, :string, default: "end", values: ~w(start end)
  attr :placement, :string, default: "bottom", values: ~w(top bottom)
  attr :compact, :boolean, default: true
  attr :variant, :string, default: "toolbar", values: ~w(toolbar footer)
  attr :class, :any, default: nil

  @spec language_switcher(map()) :: Phoenix.LiveView.Rendered.t()
  def language_switcher(assigns) do
    assigns = assign(assigns, :locale, assigns.locale || Locale.default())

    ~H"""
    <.form for={%{}} action={~p"/locale"} method="post" id={@id <> "-form"} class={@class}>
      <details id={@id} data-language-switcher class={["dropdown", @align == "end" && "dropdown-end", @placement == "top" && "dropdown-top"]}>
        <summary class={["btn btn-ghost btn-sm list-none hover:text-base-content [&::-webkit-details-marker]:hidden", if(@variant == "footer", do: "text-base-content/65", else: "text-base-content/60"), @compact && if(@variant == "footer", do: "btn-circle", else: "btn-square"), !@compact && "gap-2"]} aria-label={gettext("Language")} title={@locale.label}>
          <.icon name="hero-language" class={if @variant == "footer", do: "size-4", else: "size-5"} />
          <span class={@compact && "sr-only"}>{@locale.label}</span>
        </summary>
        <ul class={["dropdown-content menu z-50 w-52 max-w-[calc(100vw-2rem)] rounded-box border border-base-300 bg-base-100 p-1 text-left shadow-xl", if(@placement == "top", do: "mb-2", else: "mt-2")]}>
          <li>
            <button type="submit" name="locale" value="auto" aria-current={is_nil(@preference) && "true"}>
              <span class="flex-1">{gettext("Browser default")}</span>
              <.icon :if={is_nil(@preference)} name="hero-check" class="size-4 text-primary" />
            </button>
          </li>
          <li :for={locale <- Locale.locales()}>
            <button type="submit" name="locale" value={locale.tag} aria-current={@preference == locale.tag && "true"}>
              <span class="flex-1" lang={locale.tag}>{locale.label}</span>
              <.icon :if={@preference == locale.tag} name="hero-check" class="size-4 text-primary" />
            </button>
          </li>
        </ul>
      </details>
    </.form>
    """
  end
end
