defmodule CodexPoolerWeb.Admin.Components do
  @moduledoc """
  Shared components for the authenticated operator LiveViews.
  """
  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components.Shell

  def admin_shell(assigns), do: Shell.admin_shell(assigns)

  @docs_url "https://docs.codex-pooler.com"

  attr :id, :string, required: true
  attr :eyebrow, :string, default: "Admin"
  attr :title, :string, required: true
  attr :description, :string, default: nil

  slot :actions

  def page_header(assigns) do
    ~H"""
    <header
      id={@id}
      class={[
        @actions != [] &&
          "grid gap-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center",
        @actions == [] && "grid gap-2"
      ]}
    >
      <div class="grid min-w-0 gap-2">
        <p class="text-sm font-semibold uppercase tracking-wide text-primary">{@eyebrow}</p>
        <h1 class="text-3xl font-bold text-base-content">{@title}</h1>
        <p :if={@description} class="w-full text-sm leading-6 text-base-content/70">
          {@description}
        </p>
      </div>
      <div
        :if={@actions != []}
        class="flex shrink-0 flex-wrap items-center justify-start gap-2 sm:justify-end sm:self-center"
      >
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :compact_mobile, :boolean, default: false

  slot :inner_block, required: true

  def metric_strip(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "grid min-w-0 gap-2 md:grid-cols-3",
        @compact_mobile && "grid-cols-2 sm:grid-cols-3 xl:grid-cols-5",
        !@compact_mobile && "grid-cols-1"
      ]}
      aria-label="Page metrics"
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :description, :string, default: nil
  attr :tone, :atom, default: :neutral, values: [:neutral, :primary, :success, :warning, :error]
  attr :compact_mobile, :boolean, default: false

  def metric_card(assigns) do
    ~H"""
    <article
      id={@id}
      data-density={if @compact_mobile, do: "compact", else: "regular"}
      class={[
        "grid items-center rounded-box border border-base-300 bg-base-100 shadow-sm",
        @compact_mobile &&
          "min-h-16 grid-cols-1 gap-1 px-3 py-2 lg:min-h-20 lg:grid-cols-[auto_minmax(0,1fr)] lg:gap-3 lg:px-4 lg:py-3",
        !@compact_mobile &&
          "min-h-20 grid-cols-[auto_minmax(0,1fr)] gap-3 px-4 py-3"
      ]}
    >
      <span class={[metric_icon_class(@tone), @compact_mobile && "hidden lg:grid"]}>
        <.icon name={@icon} class="size-5" />
      </span>
      <div class={[
        "grid min-w-0",
        @compact_mobile && "gap-1 lg:gap-0.5",
        !@compact_mobile && "gap-0.5"
      ]}>
        <p class={[
          "min-w-0 font-medium text-base-content/60",
          @compact_mobile && "line-clamp-2 text-[0.68rem] leading-3 lg:text-xs lg:leading-normal",
          !@compact_mobile && "truncate text-xs"
        ]}>
          {@label}
        </p>
        <p
          class={[
            "min-w-0 max-w-full overflow-hidden break-words font-mono font-semibold tabular-nums text-base-content",
            @compact_mobile && "text-lg leading-tight lg:text-xl",
            !@compact_mobile && "text-xl leading-none"
          ]}
          data-role="metric-card-value"
        >
          {@value}
        </p>
        <p
          :if={@description}
          class={[
            "min-w-0 text-xs text-base-content/55",
            @compact_mobile && "line-clamp-2",
            !@compact_mobile && "text-xs"
          ]}
        >
          {@description}
        </p>
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :count, :string, default: nil
  attr :header, :boolean, default: true
  attr :overflow, :atom, default: :hidden, values: [:hidden, :visible]

  slot :toolbar
  slot :inner_block, required: true
  slot :footer

  def admin_surface(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "min-w-0 rounded-box border border-base-300 bg-base-100 shadow-sm",
        admin_surface_overflow_class(@overflow)
      ]}
    >
      <header
        :if={@header}
        class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 p-4"
      >
        <div class="grid min-w-0 gap-1">
          <h2 class="text-lg font-semibold text-base-content">{@title}</h2>
          <p :if={@description} class="text-sm leading-6 text-base-content/70">{@description}</p>
        </div>
        <span
          :if={@count}
          class="inline-flex shrink-0 items-center rounded-box border border-base-300 bg-base-200 px-3 py-1.5 text-sm font-semibold tabular-nums text-base-content"
        >
          {@count}
        </span>
      </header>

      <div :if={@toolbar != []} class="border-b border-base-300/70 bg-base-100 p-4">
        {render_slot(@toolbar)}
      </div>

      {render_slot(@inner_block)}

      <footer :if={@footer != []} class="border-t border-base-300/70 bg-base-100 px-4 py-3">
        {render_slot(@footer)}
      </footer>
    </section>
    """
  end

  defp admin_surface_overflow_class(:visible), do: "overflow-visible"
  defp admin_surface_overflow_class(_overflow), do: "overflow-hidden"

  attr :id, :string, required: true

  attr :class, :any,
    default: "modal-action mt-0 w-full border-t border-base-300 bg-base-200/80 px-6 py-3"

  attr :docs_link_role, :string, default: "admin-dialog-docs-link"
  attr :docs_link_id, :string, default: nil
  attr :docs_icon_role, :string, default: "admin-dialog-docs-icon"

  slot :actions, required: true

  def dialog_footer(assigns) do
    assigns =
      assigns
      |> assign(:docs_url, @docs_url)
      |> assign(:resolved_docs_link_id, assigns.docs_link_id || "#{assigns.id}-docs-link")

    ~H"""
    <footer id={@id} class={@class}>
      <div class="flex w-full flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <a
          id={@resolved_docs_link_id}
          data-role={@docs_link_role}
          href={@docs_url}
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Open Codex Pooler documentation"
          class="inline-flex w-fit items-center gap-1.5 text-xs font-semibold text-base-content/55 transition-colors hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <span data-role={@docs_icon_role} aria-hidden="true">
            <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
          </span>
          <span>Docs</span>
        </a>
        <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          {render_slot(@actions)}
        </div>
      </div>
    </footer>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :status, :string, default: nil
  attr :status_class, :string, default: nil
  attr :class, :string, default: nil
  attr :close_event, :string, default: nil
  attr :close_label, :string, default: "Close details"
  attr :role, :string, default: nil
  attr :aria_modal, :boolean, default: false

  slot :tabs
  slot :inner_block, required: true
  slot :quick_links

  def object_inspector(assigns) do
    ~H"""
    <aside
      id={@id}
      class={
        @class ||
          "min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-sm"
      }
      aria-label={@title}
      role={@role}
      aria-modal={@aria_modal && "true"}
    >
      <header class="flex items-start justify-between gap-3 border-b border-base-300 px-4 py-4">
        <div class="grid min-w-0 gap-1">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <h2 class="truncate text-lg font-semibold text-base-content">{@title}</h2>
            <span
              :if={@status}
              class={
                @status_class ||
                  "inline-flex items-center rounded-box bg-base-200 px-2 py-1 text-xs font-semibold text-base-content"
              }
            >
              {@status}
            </span>
          </div>
          <p :if={@subtitle} class="break-all text-xs text-base-content/60">{@subtitle}</p>
        </div>
        <button
          :if={@close_event}
          id={"#{@id}-close"}
          type="button"
          class="btn btn-ghost btn-sm btn-square shrink-0"
          aria-label={@close_label}
          phx-click={@close_event}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>

      <nav
        :if={@tabs != []}
        class="flex overflow-x-auto border-b border-base-300 px-4"
        aria-label="Inspector sections"
      >
        {render_slot(@tabs)}
      </nav>

      <div class="grid gap-4 p-4">
        {render_slot(@inner_block)}
      </div>

      <div :if={@quick_links != []} class="border-t border-base-300 p-4">
        {render_slot(@quick_links)}
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :for, :any, required: true
  attr :advanced_open, :boolean, default: false
  attr :compact, :boolean, default: false
  attr :mobile_single_column, :boolean, default: false
  attr :single_row, :boolean, default: false
  attr :rest, :global, include: ~w(phx-change phx-submit phx-target method action autocomplete)

  slot :inner_block, required: true
  slot :advanced
  slot :actions

  def filter_form(assigns) do
    ~H"""
    <.form
      for={@for}
      id={@id}
      class="bg-transparent p-0"
      {@rest}
    >
      <div class={filter_form_layout_class(@compact)}>
        <div
          class={filter_fields_class(@compact, @mobile_single_column, @single_row)}
          data-role="filter-fields"
          data-layout={if(@single_row, do: "single-row")}
        >
          {render_slot(@inner_block)}
        </div>
        <div
          :if={@actions != []}
          data-role="filter-actions"
          class={[
            "flex flex-wrap items-end gap-2 xl:self-end [&_.btn]:h-8 [&_.btn]:min-h-8",
            !@compact && "xl:pb-1"
          ]}
        >
          {render_slot(@actions)}
        </div>
      </div>

      <details
        :if={@advanced != []}
        id={"#{@id}-advanced"}
        class="mt-2 border-t border-base-300/60 pt-2"
        open={@advanced_open}
      >
        <summary class="cursor-pointer px-1 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/55 transition-colors hover:text-base-content">
          Advanced filters
        </summary>
        <div class={advanced_filter_fields_class(@mobile_single_column)}>
          {render_slot(@advanced)}
        </div>
      </details>
    </.form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :inline_label, :boolean, default: true

  def cally_date_filter(assigns) do
    assigns =
      assigns
      |> assign(:id, assigns.field.id)
      |> assign(:name, assigns.field.name)
      |> assign(:value, assigns.field.value || "")
      |> assign(:anchor_name, "--#{String.replace(assigns.field.id, "_", "-")}-cally")

    ~H"""
    <div
      id={"#{@id}-picker"}
      class="fieldset mb-2"
      phx-hook="CallyDatePicker"
      data-placeholder="dd/mm/yyyy"
    >
      <input type="hidden" id={@id} name={@name} value={@value} />
      <label :if={!@inline_label} class="label mb-1" for={"#{@id}-button"}>{@label}</label>
      <button
        id={"#{@id}-button"}
        type="button"
        class="input input-sm flex w-full items-center justify-between gap-2 text-left"
        aria-label={@label}
        popovertarget={"#{@id}-popover"}
        style={"anchor-name: #{@anchor_name};"}
      >
        <span
          :if={@inline_label}
          class="label !mb-0 min-w-0 shrink truncate !px-2 !normal-case !tracking-normal leading-none text-base-content/60"
        >
          {@label}
        </span>
        <span class="min-w-0 flex-1 truncate leading-none" data-role="cally-date-label">
          {if @value == "", do: "dd/mm/yyyy", else: @value}
        </span>
        <.icon name="hero-calendar-days" class="size-4 shrink-0 opacity-65" />
      </button>
      <div
        id={"#{@id}-popover"}
        popover
        class="dropdown rounded-box border border-base-300 bg-base-100 p-3 text-base-content shadow-xl"
        style={"position-anchor: #{@anchor_name};"}
      >
        <calendar-date class="cally" value={@value} locale="en-GB" data-role="cally-calendar">
          <svg
            aria-label="Previous"
            class="size-4 fill-current"
            slot="previous"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="M15.75 19.5 8.25 12l7.5-7.5"></path>
          </svg>
          <svg
            aria-label="Next"
            class="size-4 fill-current"
            slot="next"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="m8.25 4.5 7.5 7.5-7.5 7.5"></path>
          </svg>
          <calendar-month></calendar-month>
        </calendar-date>
        <div class="mt-3 grid grid-cols-2 gap-2 border-t border-base-300 pt-3">
          <button type="button" class="btn btn-secondary btn-sm" data-role="cally-clear">
            Clear
          </button>
          <button type="button" class="btn btn-secondary btn-sm" data-role="cally-cancel">
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :icon, :string, default: "hero-inbox"

  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class="grid place-items-center gap-3 rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center"
    >
      <.icon name={@icon} class="size-8 text-base-content/40" />
      <div class="grid gap-1">
        <p class="font-semibold text-base-content">{@title}</p>
        <p :if={@description} class="max-w-md text-sm text-base-content/70">{@description}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :status, :atom, required: true

  def redacted_status_badge(assigns) do
    ~H"""
    <span id={@id} class={status_badge_class(@status)}>
      <span class="sr-only">{@label}: </span>{status_badge_label(@status)}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :placement, :atom, default: :right, values: [:right, :end]

  def diagnostic_popover(assigns) do
    assigns =
      assigns
      |> assign(:root_class, diagnostic_popover_root_class(assigns.placement))
      |> assign(:content_class, diagnostic_popover_content_class(assigns.placement))

    ~H"""
    <span id={@id} class={@root_class}>
      <button
        id={"#{@id}-button"}
        type="button"
        class="btn btn-ghost btn-xs btn-circle text-warning transition-colors hover:bg-warning/10 hover:text-warning"
        tabindex="0"
        aria-label={@label}
        aria-describedby={"#{@id}-content"}
      >
        <.icon name="hero-exclamation-triangle" class="size-4" />
        <span class="sr-only">{@label}</span>
      </button>
      <span
        id={"#{@id}-content"}
        role="tooltip"
        tabindex="0"
        class={@content_class}
      >
        <span class="font-semibold text-base-content">{@title}</span>
        <span>{@description}</span>
      </span>
    </span>
    """
  end

  defp diagnostic_popover_root_class(:end),
    do: "dropdown dropdown-hover dropdown-end inline-flex"

  defp diagnostic_popover_root_class(_placement),
    do: "dropdown dropdown-hover dropdown-right inline-flex"

  defp diagnostic_popover_content_class(:end),
    do:
      "dropdown-content z-20 mt-2 grid w-72 gap-1 rounded-box border border-base-300 bg-base-100 p-3 text-left text-xs font-normal leading-5 text-base-content/70 shadow-xl"

  defp diagnostic_popover_content_class(_placement),
    do:
      "dropdown-content z-20 ml-2 grid w-72 gap-1 rounded-box border border-base-300 bg-base-100 p-3 text-left text-xs font-normal leading-5 text-base-content/70 shadow-xl"

  attr :id, :string, required: true
  attr :icon, :string, default: "hero-information-circle"
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :tone, :atom, default: :info, values: [:info, :success, :warning, :error]
  attr :role, :string, default: "status"

  def extended_notice(assigns) do
    assigns = assign(assigns, :class, extended_notice_class(assigns.tone))

    ~H"""
    <div id={@id} class={@class} role={@role}>
      <.icon name={@icon} class="size-5" />
      <div class="grid gap-1">
        <p class="font-semibold">{@title}</p>
        <p class="text-sm leading-5">{@description}</p>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "button"
  attr :variant, :atom, default: :secondary, values: [:primary, :secondary, :danger]
  attr :size, :atom, default: :sm, values: [:sm, :md]

  attr :rest, :global,
    include:
      ~w(href navigate patch method disabled form phx-click phx-disable-with phx-value-id phx-value-step)

  def action_button(assigns) do
    assigns = assign(assigns, :class, action_button_class(assigns.variant, assigns.size))

    if assigns.rest[:href] || assigns.rest[:navigate] || assigns.rest[:patch] do
      ~H"""
      <.link id={@id} class={@class} {@rest}>
        <.icon name={@icon} class="size-4" />
        <span>{@label}</span>
      </.link>
      """
    else
      ~H"""
      <button id={@id} type={@type} class={@class} {@rest}>
        <.icon name={@icon} class="size-4" />
        <span>{@label}</span>
      </button>
      """
    end
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :variant, :atom, default: :secondary, values: [:secondary, :danger, :positive, :warning]
  attr :copy_feedback?, :boolean, default: false

  attr :rest, :global,
    include:
      ~w(href navigate patch disabled phx-click phx-hook phx-update phx-value-id phx-value-pool-id title aria-label data-copy-text data-copy-label data-copied-label)

  def dropdown_action_item(assigns) do
    assigns =
      assigns
      |> assign(:class, dropdown_action_item_class(assigns.variant))
      |> assign(:icon_class, ["size-4", assigns.copy_feedback? && "copy-icon"])
      |> assign(
        :label_attrs,
        if(assigns.copy_feedback?, do: %{"data-copy-label" => ""}, else: %{})
      )

    if assigns.rest[:href] || assigns.rest[:navigate] || assigns.rest[:patch] do
      ~H"""
      <.link id={@id} class={@class} {@rest}>
        <.icon name={@icon} class={@icon_class} />
        <span {@label_attrs}>{@label}</span>
      </.link>
      """
    else
      ~H"""
      <button id={@id} type="button" class={@class} {@rest}>
        <.icon name={@icon} class={@icon_class} />
        <span {@label_attrs}>{@label}</span>
      </button>
      """
    end
  end

  defp dropdown_action_item_class(:danger) do
    "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-error transition-colors hover:bg-error/10 disabled:pointer-events-none disabled:cursor-not-allowed disabled:text-base-content/35"
  end

  defp dropdown_action_item_class(:positive) do
    "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-success transition-colors hover:bg-success/10 disabled:pointer-events-none disabled:cursor-not-allowed disabled:text-base-content/35"
  end

  defp dropdown_action_item_class(:warning) do
    "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-warning transition-colors hover:bg-warning/10 disabled:pointer-events-none disabled:cursor-not-allowed disabled:text-base-content/35"
  end

  defp dropdown_action_item_class(_variant) do
    "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-base-content/80 transition-colors hover:bg-base-200 hover:text-base-content disabled:pointer-events-none disabled:cursor-not-allowed disabled:text-base-content/35"
  end

  defp status_badge_class(:ok),
    do:
      "inline-flex items-center rounded-box bg-success/15 px-2 py-1 text-xs font-semibold text-success"

  defp status_badge_class(:warning),
    do:
      "inline-flex items-center rounded-box bg-warning/15 px-2 py-1 text-xs font-semibold text-warning"

  defp status_badge_class(:error),
    do:
      "inline-flex items-center rounded-box bg-error/15 px-2 py-1 text-xs font-semibold text-error"

  defp status_badge_class(_status),
    do:
      "inline-flex items-center rounded-box bg-base-200 px-2 py-1 text-xs font-semibold text-base-content/70"

  defp status_badge_label(:ok), do: "ok"
  defp status_badge_label(:warning), do: "attention needed"
  defp status_badge_label(:error), do: "error"
  defp status_badge_label(_status), do: "redacted"

  defp extended_notice_class(:success), do: "alert alert-success items-start"
  defp extended_notice_class(:warning), do: "alert alert-warning items-start"
  defp extended_notice_class(:error), do: "alert alert-error items-start"
  defp extended_notice_class(_tone), do: "alert alert-info items-start"

  defp action_button_class(:primary, :md), do: "btn btn-primary w-full gap-2 px-5 sm:w-auto"
  defp action_button_class(:primary, :sm), do: "btn btn-primary btn-sm gap-2"
  defp action_button_class(:danger, _size), do: "btn btn-error btn-outline btn-sm gap-2"
  defp action_button_class(_variant, _size), do: "btn btn-secondary btn-sm gap-2"

  defp metric_icon_class(:primary),
    do: "grid size-10 place-items-center rounded-box bg-primary/10 text-primary"

  defp metric_icon_class(:success),
    do: "grid size-10 place-items-center rounded-box bg-success/10 text-success"

  defp metric_icon_class(:warning),
    do: "grid size-10 place-items-center rounded-box bg-warning/10 text-warning"

  defp metric_icon_class(:error),
    do: "grid size-10 place-items-center rounded-box bg-error/10 text-error"

  defp metric_icon_class(_tone),
    do: "grid size-10 place-items-center rounded-box bg-base-200 text-base-content/60"

  defp filter_fields_class(true, _mobile_single_column, _single_row) do
    "grid min-w-0 flex-1 grid-cols-1 items-end gap-2 sm:grid-cols-[minmax(14rem,1fr)_12rem] [&_.fieldset]:mb-0 [&_.input]:input-sm [&_.input]:h-8 [&_.label]:sr-only [&_.select]:h-8 [&_.select]:select-sm"
  end

  defp filter_fields_class(false, _mobile_single_column, true) do
    "grid grid-cols-1 items-end gap-2 sm:grid-cols-2 lg:grid-cols-5 [&_.fieldset]:mb-0 [&_.input]:input-sm [&_.label]:mb-0.5 [&_.label]:px-1 [&_.label]:text-[0.65rem] [&_.label]:font-semibold [&_.label]:uppercase [&_.label]:tracking-wide [&_.label]:text-base-content/45 [&_.select]:select-sm"
  end

  defp filter_fields_class(false, true, false) do
    "grid grid-cols-1 items-end gap-2 sm:grid-cols-2 lg:grid-cols-4 [&_.fieldset]:mb-0 [&_.input]:input-sm [&_.label]:mb-0.5 [&_.label]:px-1 [&_.label]:text-[0.65rem] [&_.label]:font-semibold [&_.label]:uppercase [&_.label]:tracking-wide [&_.label]:text-base-content/45 [&_.select]:select-sm"
  end

  defp filter_fields_class(false, false, false) do
    "grid grid-cols-2 items-end gap-2 lg:grid-cols-4 [&_.fieldset]:mb-0 [&_.input]:input-sm [&_.label]:mb-0.5 [&_.label]:px-1 [&_.label]:text-[0.65rem] [&_.label]:font-semibold [&_.label]:uppercase [&_.label]:tracking-wide [&_.label]:text-base-content/45 [&_.select]:select-sm"
  end

  defp advanced_filter_fields_class(true) do
    "grid grid-cols-1 gap-2 pt-2 sm:grid-cols-[repeat(auto-fit,minmax(10rem,1fr))] [&_.fieldset]:mb-0 [&_.input]:input-sm [&_.label]:mb-0.5 [&_.label]:px-1 [&_.label]:text-[0.65rem] [&_.label]:font-semibold [&_.label]:uppercase [&_.label]:tracking-wide [&_.label]:text-base-content/45 [&_.select]:select-sm"
  end

  defp advanced_filter_fields_class(false) do
    "grid grid-cols-[repeat(auto-fit,minmax(10rem,1fr))] gap-2 pt-2 [&_.fieldset]:mb-0 [&_.input]:input-sm [&_.label]:mb-0.5 [&_.label]:px-1 [&_.label]:text-[0.65rem] [&_.label]:font-semibold [&_.label]:uppercase [&_.label]:tracking-wide [&_.label]:text-base-content/45 [&_.select]:select-sm"
  end

  defp filter_form_layout_class(true), do: "flex flex-wrap items-center gap-2"

  defp filter_form_layout_class(false),
    do: "grid gap-2 xl:grid-cols-[minmax(0,1fr)_auto] xl:items-end"
end
