defmodule CodexPoolerWeb.Admin.LensFilters do
  @moduledoc false
  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LensFilterForm
  alias CodexPoolerWeb.Admin.PoolFilterComponents

  attr :form, :any, required: true
  attr :pool_options, :list, required: true
  attr :model_options, :list, required: true

  def filters(assigns) do
    ~H"""
    <AdminComponents.filter_form id="model-history-filter" for={@form} phx-change="filter" phx-submit="filter" advanced_open={@form.params["upstream_identity_id"] != ""} mobile_single_column>
      <.dropdown id="lens-window-filter" label="Window" field="window" value={@form.params["window"]} options={LensFilterForm.window_options()} />
      <PoolFilterComponents.pool_filter_dropdown id="lens-pool-filter" label="Pool" hidden_id="filters_pool_id" selected_value={@form.params["pool_id"]} options={@pool_options} />
      <.dropdown id="lens-model-filter" label="Sent model" field="sent_model" value={@form.params["sent_model"]} options={@model_options} />
      <.dropdown id="lens-evidence-filter" label="Attempt evidence" field="evidence" value={@form.params["evidence"]} options={LensFilterForm.evidence_options()} />
      <:advanced>
        <.input field={@form[:upstream_identity_id]} type="text" label="Upstream identity id" placeholder="Any upstream identity" phx-debounce="300" />
      </:advanced>
    </AdminComponents.filter_form>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :field, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true

  defp dropdown(assigns) do
    assigns = assign(assigns, :selected, LensFilterForm.selected(assigns.options, assigns.value))

    ~H"""
    <div class="grid min-w-0 gap-2">
      <input type="hidden" id={"filters_#{@field}"} name={"filters[#{@field}]"} value={@value} />
      <details id={@id} class="dropdown min-w-0 w-full" phx-click-away={JS.remove_attribute("open", to: "##{@id}")}>
        <summary data-role={"#{@field}-filter-trigger"} aria-label={@label} class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal">
          <.icon name={@selected.icon} class={["size-4 shrink-0", @selected.icon_class]} />
          <span class="min-w-0 flex-1 truncate">{@selected.label}</span>
        </summary>
        <ul data-role={"#{@field}-filter-menu"} class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl">
          <li :for={option <- @options}>
            <button type="button" phx-click="select_filter" phx-value-field={@field} phx-value-filter-value={option.value} data-role={"#{@field}-filter-option"} data-value={option.value} class={["flex items-center gap-2 text-sm", option.value == @value && "active"]} aria-current={option.value == @value && "true"}>
              <.icon name={option.icon} class={["size-4 shrink-0", option.icon_class]} />
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end
end
