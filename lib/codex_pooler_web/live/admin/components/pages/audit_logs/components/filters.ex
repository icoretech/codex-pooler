defmodule CodexPoolerWeb.Admin.AuditLogsComponents.Filters do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.AuditLogsComponents.Presentation
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :filter_form, :any, required: true
  attr :filter_values, :map, required: true
  attr :filter_errors, :list, required: true
  attr :pool_filter_options, :list, required: true

  def audit_log_filters(assigns) do
    ~H"""
    <AdminComponents.filter_form
      id="audit-log-filter-form"
      for={@filter_form}
      advanced_open
      phx-submit="filter"
    >
      <div class="grid gap-2">
        <input
          type="hidden"
          id="filters_pool_id"
          name="filters[pool_id]"
          value={@filter_values["pool_id"] || ""}
        />
        <details
          id="audit-log-pool-filter"
          class="dropdown w-full"
          phx-click-away={JS.remove_attribute("open", to: "#audit-log-pool-filter")}
        >
          <summary
            data-role="pool-filter-trigger"
            aria-label="Pool"
            class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
          >
            <% selected_pool =
              Presentation.selected_pool_filter_option(
                @pool_filter_options,
                @filter_values["pool_id"]
              ) %>
            <.icon
              name={selected_pool.icon}
              class="size-4 shrink-0 text-base-content/60"
            />
            <span class="truncate">{selected_pool.label}</span>
          </summary>
          <ul
            data-role="pool-filter-menu"
            class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
          >
            <li :for={option <- @pool_filter_options}>
              <button
                type="button"
                phx-click="select_pool_filter"
                phx-value-pool-id={option.value}
                data-role="pool-filter-option"
                data-pool-id={option.value}
                class={[
                  "flex items-center gap-2 text-sm",
                  option.value == (@filter_values["pool_id"] || "") && "active"
                ]}
                aria-current={option.value == (@filter_values["pool_id"] || "") && "true"}
              >
                <.icon name={option.icon} class="size-4 shrink-0" />
                <span class="truncate">{option.label}</span>
                <span
                  :if={option.strategy_label}
                  class="ml-auto shrink-0 text-[0.68rem] text-base-content/50"
                >
                  {option.strategy_label}
                </span>
              </button>
            </li>
          </ul>
        </details>
      </div>
      <div class="grid gap-2">
        <input
          type="hidden"
          id="filters_outcome"
          name="filters[outcome]"
          value={@filter_values["outcome"] || ""}
        />
        <details
          id="audit-log-outcome-filter"
          class="dropdown w-full"
          phx-click-away={JS.remove_attribute("open", to: "#audit-log-outcome-filter")}
        >
          <summary
            data-role="outcome-filter-trigger"
            aria-label="Outcome"
            class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
          >
            <span
              data-role="outcome-filter-trigger-icon"
              class={[
                "shrink-0",
                Presentation.outcome_filter_icon_class(@filter_values["outcome"])
              ]}
            >
              <.icon
                name={Presentation.outcome_filter_icon(@filter_values["outcome"])}
                class="size-4"
              />
            </span>
            <span class="truncate">
              {Presentation.outcome_filter_label(@filter_values["outcome"])}
            </span>
          </summary>
          <ul
            data-role="outcome-filter-menu"
            class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
          >
            <li :for={{label, outcome} <- Presentation.outcome_options()}>
              <button
                type="button"
                phx-click="select_outcome_filter"
                phx-value-outcome={outcome}
                data-role="outcome-filter-option"
                data-outcome={outcome}
                class={[
                  "flex items-center gap-2 text-sm",
                  outcome == (@filter_values["outcome"] || "") && "active"
                ]}
                aria-current={outcome == (@filter_values["outcome"] || "") && "true"}
              >
                <span
                  data-role="outcome-filter-icon"
                  class={["shrink-0", Presentation.outcome_filter_icon_class(outcome)]}
                >
                  <.icon name={Presentation.outcome_filter_icon(outcome)} class="size-4" />
                </span>
                <span>{label}</span>
              </button>
            </li>
          </ul>
        </details>
      </div>
      <div class="grid gap-2">
        <input
          type="hidden"
          id="filters_action"
          name="filters[action]"
          value={@filter_values["action"] || ""}
        />
        <details
          id="audit-log-action-filter"
          class="dropdown w-full"
          phx-click-away={JS.remove_attribute("open", to: "#audit-log-action-filter")}
        >
          <summary
            data-role="action-filter-trigger"
            aria-label="Event"
            class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
          >
            <span
              data-role="action-filter-trigger-icon"
              class={[
                "shrink-0",
                Presentation.action_filter_icon_class(@filter_values["action"])
              ]}
            >
              <.icon name={Presentation.action_filter_icon(@filter_values["action"])} class="size-4" />
            </span>
            <span class="truncate">
              {Presentation.action_filter_label(@filter_values["action"])}
            </span>
          </summary>
          <ul
            data-role="action-filter-menu"
            class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
          >
            <li :for={{label, action} <- Presentation.action_options()}>
              <button
                type="button"
                phx-click="select_action_filter"
                phx-value-action={action}
                data-role="action-filter-option"
                data-action={action}
                class={[
                  "flex items-center gap-2 text-sm",
                  action == (@filter_values["action"] || "") && "active"
                ]}
                aria-current={action == (@filter_values["action"] || "") && "true"}
              >
                <span
                  data-role="action-filter-icon"
                  class={["shrink-0", Presentation.action_filter_icon_class(action)]}
                >
                  <.icon name={Presentation.action_filter_icon(action)} class="size-4" />
                </span>
                <span>{label}</span>
              </button>
            </li>
          </ul>
        </details>
      </div>
      <:advanced>
        <.select_filter
          field={@filter_form[:actor_type]}
          options={Presentation.actor_type_options()}
          label="Actor type"
        />
        <.segmented_text_filter
          field={@filter_form[:actor]}
          label="Actor"
          placeholder="email or id"
        />
        <.segmented_text_filter
          field={@filter_form[:target]}
          label="Target"
          placeholder="user or id"
        />
        <AdminComponents.cally_date_filter field={@filter_form[:date_from]} label="Date from" />
        <AdminComponents.cally_date_filter field={@filter_form[:date_to]} label="Date to" />
      </:advanced>
    </AdminComponents.filter_form>

    <div
      :if={@filter_errors != []}
      id="audit-log-filter-errors"
      class="alert alert-warning items-start"
    >
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <div>
        <p class="font-semibold">Some filters were ignored</p>
        <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
          <li :for={error <- @filter_errors}>{error.message}</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true
  attr :label, :string, required: true

  defp select_filter(assigns) do
    assigns =
      assigns
      |> assign(:id, assigns.field.id)
      |> assign(:name, assigns.field.name)
      |> assign(:value, assigns.field.value || "")

    ~H"""
    <div id={"#{@id}-filter"} class="fieldset mb-2">
      <select
        id={@id}
        name={@name}
        class="w-full select"
        aria-label={@label}
      >
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, required: true

  defp segmented_text_filter(assigns) do
    assigns =
      assigns
      |> assign(:id, assigns.field.id)
      |> assign(:name, assigns.field.name)
      |> assign(:value, assigns.field.value || "")

    ~H"""
    <div id={"#{@id}-filter"} class="fieldset mb-2">
      <div class="input input-sm flex w-full items-center gap-2">
        <span class="label !mb-0 min-w-0 shrink truncate !px-2 !normal-case !tracking-normal leading-none text-base-content/60">
          {@label}
        </span>
        <input
          type="text"
          id={@id}
          name={@name}
          value={@value}
          placeholder={@placeholder}
          aria-label={@label}
          class="min-w-0 grow bg-transparent p-0 text-xs font-normal outline-none placeholder:text-base-content/45"
        />
      </div>
    </div>
    """
  end
end
